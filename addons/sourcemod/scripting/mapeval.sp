#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <multicolors>
#include <nextmap>
#undef REQUIRE_PLUGIN
#include <nativevotes>
#define REQUIRE_PLUGIN

#define PLUGIN_VERSION "0.1-tf2c"
#define MAP_EVAL_CONFIG_FILE "configs/mapeval.cfg"
#define MAPEVAL_VOTE_TIME 8

static const float RANDOM_NOMINATION_DELAY = 5.0;

#define NOMINATE_STATUS_ENABLED (1 << 0)
#define NOMINATE_STATUS_DISABLED (1 << 1)
#define NOMINATE_STATUS_EXCLUDE_CURRENT (1 << 2)
#define NOMINATE_STATUS_EXCLUDE_PREVIOUS (1 << 3)
#define NOMINATE_STATUS_EXCLUDE_NOMINATED (1 << 4)
#define MAXTEAMS 10

enum NominateResult
{
    Nominate_Added,
    Nominate_Replaced,
    Nominate_AlreadyInVote,
    Nominate_InvalidMap,
    Nominate_VoteFull
};

public Plugin myinfo =
{
    name = "mapeval",
    author = "Hombre",
    description = "NativeVotes map vote based on mapeval.cfg",
    version = PLUGIN_VERSION,
    url = "https://kogasa.tf"
};

// Please note that this is a drop-in replacement for nominations and mapchooser

NativeVote g_AvoteVote = null;
ArrayList g_MapVoteOptions = null;
StringMap g_MapVoteCounts = null;
bool g_MapVoteVoted[MAXPLAYERS + 1] = { false, ... };
char g_MapVoteChoice[MAXPLAYERS + 1][PLATFORM_MAX_PATH];
bool g_MapVoteFinalize = false;

ConVar g_CvarNominateExcludeOld = null;
ConVar g_CvarNominateExcludeCurrent = null;
ConVar g_CvarNominateMaxMatches = null;
ConVar g_CvarNominations = null;

Menu g_NominateMenu = null;
ArrayList g_NominateMapList = null;
int g_NominateMapListSerial = -1;
StringMap g_NominateStatus = null;
Handle g_RandomNominateTimer[MAXPLAYERS + 1];
int g_RandomNominateUserId[MAXPLAYERS + 1];
char g_RandomNominateMap[MAXPLAYERS + 1][PLATFORM_MAX_PATH];

StringMap g_MapEvalGamemodes = null;
char g_CurrentMap[PLATFORM_MAX_PATH];
char g_GameMode[32];

ConVar g_CvarVoteDone = null;
ConVar g_CvarEndVote = null;
ConVar g_CvarStartRounds = null;
ConVar g_CvarMaxRounds = null;
ConVar g_CvarWinLimit = null;
ConVar g_CvarExcludeMaps = null;
ConVar g_CvarStartTime = null;
ConVar g_CvarTimelimit = null;
ConVar g_CvarNextMap = null;
bool g_AutoVoteStarted = false;
int g_TotalRounds = 0;
ArrayList g_OldMapList = null;
Handle g_hTimeLeftTimer = null;
Handle g_hClearNextMapTimer = null;

public void OnPluginStart()
{
    LoadTranslations("common.phrases");
    LoadTranslations("nominations.phrases");

    g_MapVoteOptions = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
    g_MapVoteCounts = new StringMap();
    g_MapEvalGamemodes = new StringMap();
    g_OldMapList = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));

    g_CvarVoteDone = CreateConVar("mapeval_vote_done", "0", "Set to 1 after a MapEval mapvote sets nextmap.", FCVAR_NOTIFY);
    g_CvarEndVote = FindConVar("sm_mapvote_endvote");
    if (g_CvarEndVote == null)
    {
        g_CvarEndVote = CreateConVar("mapeval_endvote", "1", "Specifies if MapEval should run an end of map vote.", _, true, 0.0, true, 1.0);
    }
    g_CvarStartRounds = FindConVar("sm_mapvote_startround");
    if (g_CvarStartRounds == null)
    {
        g_CvarStartRounds = CreateConVar("mapeval_startround", "2", "Specifies when to start the vote based on rounds remaining. Use 0 on TF2 to start vote during bonus round time", _, true, 0.0);
    }
    g_CvarMaxRounds = FindConVar("mp_maxrounds");
    g_CvarWinLimit = FindConVar("mp_winlimit");
    g_CvarExcludeMaps = FindConVar("sm_mapvote_exclude");
    if (g_CvarExcludeMaps == null)
    {
        g_CvarExcludeMaps = CreateConVar("sm_mapvote_exclude", "5", "Specifies how many past maps to exclude from the vote.", _, true, 0.0);
    }
    g_CvarStartTime = FindConVar("sm_mapvote_start");
    if (g_CvarStartTime == null)
    {
        g_CvarStartTime = CreateConVar("mapeval_start", "3.0", "Specifies when to start the vote based on time remaining (minutes).", _, true, 1.0);
    }
    g_CvarTimelimit = FindConVar("mp_timelimit");
    g_CvarNextMap = FindConVar("sm_nextmap");
    g_CvarNominateExcludeOld = CreateConVar("sm_nominate_excludeold", "1", "Specifies if MapChooser excluded maps should also be excluded from nominations", 0, true, 0.0, true, 1.0);
    g_CvarNominateExcludeCurrent = CreateConVar("sm_nominate_excludecurrent", "1", "Specifies if the current map should be excluded from nominations", 0, true, 0.0, true, 1.0);
    g_CvarNominateMaxMatches = CreateConVar("sm_nominate_maxfound", "0", "Maximum number of nomination matches to add to the menu. 0 = infinite.", _, true, 0.0);
    g_CvarNominations = CreateConVar("mapeval_nominations", "0", "If 1, all clients can nominate; if 0, only admins can nominate.", _, true, 0.0, true, 1.0);

    g_NominateMapList = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
    g_NominateStatus = new StringMap();

    RegAdminCmd("sm_mapvote2", Command_MapVote, ADMFLAG_GENERIC, "Start a NativeVotes map vote using mapeval.cfg.");
    RegConsoleCmd("sm_maps", Command_Maps, "Show the current mapvote options.");
    RegConsoleCmd("sm_avote", Command_AvotePersonal, "Open a personal map vote menu.");
    RegConsoleCmd("sm_av", Command_AvotePersonal, "Open a personal map vote menu.");
    RegConsoleCmd("sm_nominate", Command_Nominate);
    RegConsoleCmd("sm_n", Command_Nominate);
    RegConsoleCmd("sm_nom", Command_Nominate);
    RegConsoleCmd("sm_nr", Command_Nominate);
    AddCommandListener(Command_ReVote, "sm_revote");
    RegAdminCmd("sm_setnextmap", Command_SetNextmap, ADMFLAG_CHANGEMAP, "sm_setnextmap <map>");
    RegAdminCmd("sm_nominate_addmap", Command_NominateAddmap, ADMFLAG_CHANGEMAP, "sm_nominate_addmap <mapname> - Forces a map to be on the next mapvote.");

    for (int i = 1; i <= MaxClients; i++)
    {
        g_RandomNominateTimer[i] = INVALID_HANDLE;
        g_RandomNominateUserId[i] = 0;
        g_RandomNominateMap[i][0] = '\0';
    }

    if (g_CvarMaxRounds != null || g_CvarWinLimit != null)
    {
        HookEvent("teamplay_win_panel", Event_TeamPlayWinPanel);
        HookEvent("arena_win_panel", Event_TeamPlayWinPanel);
        HookEvent("teamplay_restart_round", Event_TFRestartRound);
    }

    UpdateCurrentMap();
    UpdateGameModeFromMap();
    LoadMapEvalConfig();
    RefreshNominateMapList();
    SelectMapVoteOptions();
}

public void OnMapStart()
{
    g_TotalRounds = 0;
    g_AutoVoteStarted = false;

    UpdateCurrentMap();
    UpdateGameModeFromMap();
    LoadMapEvalConfig();
    RefreshNominateMapList();
    SelectMapVoteOptions();
    SetupTimeleftTimer();
    if (g_CvarVoteDone != null)
    {
        g_CvarVoteDone.SetBool(false);
    }
    if (g_CvarNextMap != null)
    {
        g_CvarNextMap.SetString("");
    }
    ScheduleClearNextMap();
}

public void OnMapEnd()
{
    if (g_OldMapList == null)
    {
        return;
    }

    if (g_CvarNextMap != null)
    {
        g_CvarNextMap.SetString("");
    }

    char map[PLATFORM_MAX_PATH];
    GetCurrentMap(map, sizeof(map));

    int idx = g_OldMapList.FindString(map);
    if (idx != -1)
    {
        g_OldMapList.Erase(idx);
    }
    g_OldMapList.PushString(map);
    TrimOldMapList();
}

public void OnConfigsExecuted()
{
    RefreshNominateMapList();
    SetupTimeleftTimer();
    ScheduleClearNextMap();
}

public void OnMapTimeLeftChanged()
{
    SetupTimeleftTimer();
}

static void ScheduleClearNextMap()
{
    if (g_hClearNextMapTimer != null)
    {
        KillTimer(g_hClearNextMapTimer);
        g_hClearNextMapTimer = null;
    }

    g_hClearNextMapTimer = CreateTimer(0.2, Timer_ClearNextMap, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_ClearNextMap(Handle timer)
{
    g_hClearNextMapTimer = null;

    if (g_CvarNextMap != null && (g_CvarVoteDone == null || !g_CvarVoteDone.BoolValue))
    {
        g_CvarNextMap.SetString("");
    }
    return Plugin_Stop;
}

public void Event_TFRestartRound(Event event, const char[] name, bool dontBroadcast)
{
    g_TotalRounds = 0;
}

public void Event_TeamPlayWinPanel(Event event, const char[] name, bool dontBroadcast)
{
    if (g_CvarEndVote != null && !g_CvarEndVote.BoolValue)
    {
        return;
    }

    if (g_AutoVoteStarted || (g_CvarVoteDone != null && g_CvarVoteDone.BoolValue))
    {
        return;
    }

    if (event.GetInt("round_complete") != 1 && !StrEqual(name, "arena_win_panel"))
    {
        return;
    }

    g_TotalRounds++;

    int startRounds = (g_CvarStartRounds != null) ? g_CvarStartRounds.IntValue : 2;
    if (startRounds < 0)
    {
        startRounds = 0;
    }
    if (startRounds == 0)
    {
        startRounds = 1;
    }

    CheckMaxRounds(g_TotalRounds, startRounds);

    int winningTeam = event.GetInt("winning_team");
    if (winningTeam == 3)
    {
        CheckWinLimit(event.GetInt("blue_score"), startRounds);
    }
    else if (winningTeam == 2)
    {
        CheckWinLimit(event.GetInt("red_score"), startRounds);
    }
}

public void OnClientDisconnect(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    if (g_RandomNominateTimer[client] != INVALID_HANDLE)
    {
        delete g_RandomNominateTimer[client];
        g_RandomNominateTimer[client] = INVALID_HANDLE;
    }
    g_RandomNominateUserId[client] = 0;
    g_RandomNominateMap[client][0] = '\0';
}

public void OnNominationRemoved(const char[] map, int owner)
{
    int status;
    char resolvedMap[PLATFORM_MAX_PATH];
    FindMap(map, resolvedMap, sizeof(resolvedMap));

    if (g_NominateStatus == null || !g_NominateStatus.GetValue(resolvedMap, status))
    {
        return;
    }

    if ((status & NOMINATE_STATUS_EXCLUDE_NOMINATED) != NOMINATE_STATUS_EXCLUDE_NOMINATED)
    {
        return;
    }

    g_NominateStatus.SetValue(resolvedMap, NOMINATE_STATUS_ENABLED);
}

public Action Command_Maps(int client, int args)
{
    if (g_MapVoteOptions == null || g_MapVoteOptions.Length == 0)
    {
        ReplyToCommand(client, "[SM] No mapvote options are available.");
        return Plugin_Handled;
    }

    char mapName[PLATFORM_MAX_PATH];
    for (int i = 0; i < g_MapVoteOptions.Length; i++)
    {
        g_MapVoteOptions.GetString(i, mapName, sizeof(mapName));
        char displayName[PLATFORM_MAX_PATH];
        GetMapDisplayName(mapName, displayName, sizeof(displayName));
        if (IsMapInTier(mapName, "tier1"))
        {
            CPrintToChat(client, "[SM] {green}%s{default}", displayName);
        }
        else if (IsMapInTier(mapName, "tier2"))
        {
            CPrintToChat(client, "[SM] {axis}%s{default}", displayName);
        }
        else
        {
            CPrintToChat(client, "[SM] %s", displayName);
        }
    }

    return Plugin_Handled;
}

public Action Command_MapVote(int client, int args)
{
    StartMapEvalVote(true, client);
    return Plugin_Handled;
}

static bool StartMapEvalVote(bool finalize, int replyClient)
{
    if (!LibraryExists("nativevotes") || !NativeVotes_IsVoteTypeSupported(NativeVotesType_NextLevelMult))
    {
        if (replyClient)
        {
            ReplyToCommand(replyClient, "[SM] NativeVotes is unavailable.");
        }
        return false;
    }

    if (NativeVotes_IsVoteInProgress() || IsVoteInProgress())
    {
        if (replyClient)
        {
            ReplyToCommand(replyClient, "[SM] A vote is already in progress.");
        }
        return false;
    }

    EnsureMapVoteOptions();
    if (g_MapVoteOptions == null || g_MapVoteOptions.Length == 0)
    {
        if (replyClient)
        {
            ReplyToCommand(replyClient, "[SM] No mapvote options are available.");
        }
        return false;
    }

    g_MapVoteFinalize = finalize;

    if (g_AvoteVote != null)
    {
        g_AvoteVote.Close();
        g_AvoteVote = null;
    }

    MenuAction actions = view_as<MenuAction>(MENU_ACTIONS_ALL);
    g_AvoteVote = new NativeVote(Handler_AvoteVote, NativeVotesType_NextLevelMult, actions);
    NativeVotes_SetTitle(g_AvoteVote, "Select next map");

    char mapName[PLATFORM_MAX_PATH];
    for (int i = 0; i < g_MapVoteOptions.Length; i++)
    {
        g_MapVoteOptions.GetString(i, mapName, sizeof(mapName));
        NativeVotes_AddItem(g_AvoteVote, mapName, mapName);
    }

    int clients[MAXPLAYERS];
    int clientCount = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
        {
            clients[clientCount++] = i;
        }
    }

    if (clientCount == 0 || !NativeVotes_Display(g_AvoteVote, clients, clientCount, MAPEVAL_VOTE_TIME))
    {
        if (replyClient)
        {
            ReplyToCommand(replyClient, "[SM] Failed to display vote.");
        }
        g_AvoteVote.Close();
        g_AvoteVote = null;
        g_MapVoteFinalize = false;
        return false;
    }

    return true;
}

static void StartAutoMapVote()
{
    if (g_AutoVoteStarted || (g_CvarVoteDone != null && g_CvarVoteDone.BoolValue))
    {
        return;
    }

    if (g_CvarEndVote != null && !g_CvarEndVote.BoolValue)
    {
        return;
    }

    if (StartMapEvalVote(true, 0))
    {
        g_AutoVoteStarted = true;
        if (g_hTimeLeftTimer != null && IsValidHandle(g_hTimeLeftTimer))
        {
            delete g_hTimeLeftTimer;
        }
        g_hTimeLeftTimer = null;
    }
}

static void CheckWinLimit(int winnerScore, int startRounds)
{
    if (g_CvarWinLimit == null)
    {
        return;
    }

    int winlimit = g_CvarWinLimit.IntValue;
    if (winlimit <= 0)
    {
        return;
    }

    if (winnerScore >= (winlimit - startRounds))
    {
        StartAutoMapVote();
    }
}

static void CheckMaxRounds(int roundcount, int startRounds)
{
    if (g_CvarMaxRounds == null)
    {
        return;
    }

    int maxrounds = g_CvarMaxRounds.IntValue;
    if (maxrounds <= 0)
    {
        return;
    }

    if (roundcount >= (maxrounds - startRounds))
    {
        StartAutoMapVote();
    }
}

static void SetupTimeleftTimer()
{
    if (g_hTimeLeftTimer != null && IsValidHandle(g_hTimeLeftTimer))
    {
        delete g_hTimeLeftTimer;
    }
    g_hTimeLeftTimer = null;

    int timeLeft = 0;
    if (!GetMapTimeLeft(timeLeft) || timeLeft <= 0)
    {
        return;
    }

    if (g_CvarTimelimit != null && g_CvarTimelimit.FloatValue <= 0.0)
    {
        return;
    }

    g_hTimeLeftTimer = CreateTimer(30.0, Timer_Timeleft, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_Timeleft(Handle timer, any data)
{
    if (g_CvarEndVote != null && !g_CvarEndVote.BoolValue)
    {
        return Plugin_Continue;
    }

    if (g_AutoVoteStarted || (g_CvarVoteDone != null && g_CvarVoteDone.BoolValue))
    {
        return Plugin_Continue;
    }

    int timeLeft = 0;
    if (!GetMapTimeLeft(timeLeft) || timeLeft <= 0)
    {
        return Plugin_Continue;
    }

    float startMinutes = (g_CvarStartTime != null) ? g_CvarStartTime.FloatValue : 3.0;
    int startTime = RoundToNearest(startMinutes * 60.0);
    if (startTime < 1)
    {
        startTime = 1;
    }

    if (timeLeft <= startTime)
    {
        StartAutoMapVote();
    }

    return Plugin_Continue;
}

public Action Command_AvotePersonal(int client, int args)
{
    if (!client)
    {
        return Plugin_Handled;
    }

    EnsureMapVoteOptions();
    if (g_MapVoteOptions == null || g_MapVoteOptions.Length == 0)
    {
        ReplyToCommand(client, "[SM] No mapvote options are available.");
        return Plugin_Handled;
    }

    Menu menu = new Menu(MenuHandler_AvotePersonal, MENU_ACTIONS_DEFAULT | MenuAction_DisplayItem);
    menu.SetTitle("Select next map");

    char mapName[PLATFORM_MAX_PATH];
    for (int i = 0; i < g_MapVoteOptions.Length; i++)
    {
        g_MapVoteOptions.GetString(i, mapName, sizeof(mapName));
        menu.AddItem(mapName, mapName);
    }

    menu.ExitButton = true;
    menu.Display(client, 20);
    return Plugin_Handled;
}

public Action Command_Nominate(int client, int args)
{
    if (!client)
    {
        return Plugin_Handled;
    }

    char commandName[32];
    GetCmdArg(0, commandName, sizeof(commandName));

    if (!CheckCommandAccess(client, "sm_nominate", ADMFLAG_GENERIC, false) && (g_CvarNominations == null || !g_CvarNominations.BoolValue))
    {
        return Command_AvotePersonal(client, 0);
    }

    if (g_NominateMapList == null || g_NominateMapList.Length == 0)
    {
        ReplyToCommand(client, "[SM] No maps available to nominate.");
        return Plugin_Handled;
    }

    ReplySource source = GetCmdReplySource();

    if (args == 0)
    {
        if (StrEqual(commandName, "sm_nr", false))
        {
            QueueRandomNomination(client);
            return Plugin_Handled;
        }

        OpenNominationMenu(client);
        return Plugin_Handled;
    }

    char mapname[PLATFORM_MAX_PATH];
    GetCmdArg(1, mapname, sizeof(mapname));
    if (StrEqual(mapname, "random", false))
    {
        QueueRandomNomination(client);
        return Plugin_Handled;
    }

    ArrayList results = new ArrayList();
    int matches = FindMatchingMaps(g_NominateMapList, results, mapname);

    if (matches <= 0)
    {
        ReplyToCommand(client, "%t", "Map was not found", mapname);
    }
    else if (matches == 1)
    {
        char mapResult[PLATFORM_MAX_PATH];
        g_NominateMapList.GetString(results.Get(0), mapResult, sizeof(mapResult));
        AttemptNominate(client, mapResult, sizeof(mapResult));
    }
    else
    {
        if (source == SM_REPLY_TO_CONSOLE)
        {
            AttemptNominate(client, mapname, sizeof(mapname));
            delete results;
            return Plugin_Handled;
        }

        Menu menu = new Menu(MenuHandler_NominateSelect, MENU_ACTIONS_DEFAULT | MenuAction_DrawItem | MenuAction_DisplayItem);
        menu.SetTitle("Select map");

        char mapResult[PLATFORM_MAX_PATH];
        for (int i = 0; i < results.Length; i++)
        {
            g_NominateMapList.GetString(results.Get(i), mapResult, sizeof(mapResult));

            char displayName[PLATFORM_MAX_PATH];
            GetMapDisplayName(mapResult, displayName, sizeof(displayName));

            menu.AddItem(mapResult, displayName);
        }

        menu.Display(client, 30);
    }

    delete results;

    return Plugin_Handled;
}

public Action Command_ReVote(int client, const char[] command, int argc)
{
    if (client <= 0)
    {
        return Plugin_Continue;
    }

    if (g_AvoteVote == null || !NativeVotes_IsVoteInProgress())
    {
        return Plugin_Continue;
    }

    if (!NativeVotes_IsClientInVotePool(client))
    {
        return Plugin_Continue;
    }

    if (NativeVotes_RedrawClientVote(client))
    {
        return Plugin_Stop;
    }

    return Plugin_Continue;
}

public Action Command_SetNextmap(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[SM] Usage: sm_setnextmap <map>");
        return Plugin_Handled;
    }

    char map[PLATFORM_MAX_PATH];
    char displayName[PLATFORM_MAX_PATH];
    GetCmdArg(1, map, sizeof(map));

    if (FindMap(map, displayName, sizeof(displayName)) == FindMap_NotFound)
    {
        ReplyToCommand(client, "[SM] %t", "Map was not found", map);
        return Plugin_Handled;
    }

    GetMapDisplayName(displayName, displayName, sizeof(displayName));

    ShowActivity2(client, "[SM] ", "%t", "Changed Next Map", displayName);
    LogAction(client, -1, "\"%L\" changed nextmap to \"%s\"", client, map);

    SetNextMap(map);
    if (g_CvarVoteDone != null)
    {
        g_CvarVoteDone.SetBool(true);
    }
    return Plugin_Handled;
}

public Action Command_NominateAddmap(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[SM] Usage: sm_nominate_addmap <mapname>");
        return Plugin_Handled;
    }

    char mapname[PLATFORM_MAX_PATH];
    char resolvedMap[PLATFORM_MAX_PATH];
    GetCmdArg(1, mapname, sizeof(mapname));

    if (FindMap(mapname, resolvedMap, sizeof(resolvedMap)) == FindMap_NotFound)
    {
        ReplyToCommand(client, "%t", "Map was not found", mapname);
        return Plugin_Handled;
    }

    char displayName[PLATFORM_MAX_PATH];
    GetMapDisplayName(resolvedMap, displayName, sizeof(displayName));

    int status;
    if (g_NominateStatus == null || !g_NominateStatus.GetValue(resolvedMap, status))
    {
        ReplyToCommand(client, "%t", "Map Not In Pool", displayName);
        return Plugin_Handled;
    }

    NominateResult result = NominateMap(resolvedMap, true, 0);

    if (result > Nominate_Replaced)
    {
        ReplyToCommand(client, "%t", "Map Already In Vote", displayName);
        return Plugin_Handled;
    }

    g_NominateStatus.SetValue(resolvedMap, NOMINATE_STATUS_DISABLED | NOMINATE_STATUS_EXCLUDE_NOMINATED);

    ReplyToCommand(client, "%t", "Map Inserted", displayName);
    LogAction(client, -1, "\"%L\" inserted map \"%s\".", client, mapname);

    return Plugin_Handled;
}

static NominateResult NominateMap(const char[] map, bool force, int owner)
{
    if (owner == -1)
    {
        return Nominate_InvalidMap;
    }

    if (!IsMapValid(map))
    {
        return Nominate_InvalidMap;
    }

    EnsureMapVoteOptions();
    if (g_MapVoteOptions == null || g_MapVoteOptions.Length == 0)
    {
        return Nominate_VoteFull;
    }

    if (g_MapVoteOptions.FindString(map) != -1)
    {
        return Nominate_AlreadyInVote;
    }

    int replaceIndex = -1;
    char replaceMap[PLATFORM_MAX_PATH];
    for (int i = 0; i < g_MapVoteOptions.Length; i++)
    {
        g_MapVoteOptions.GetString(i, replaceMap, sizeof(replaceMap));

        int votes = 0;
        if (g_MapVoteCounts != null)
        {
            g_MapVoteCounts.GetValue(replaceMap, votes);
        }

        if (votes == 0 && IsMapInTier(replaceMap, "tier2"))
        {
            replaceIndex = i;
            break;
        }
    }

    if (replaceIndex == -1)
    {
        for (int i = 0; i < g_MapVoteOptions.Length; i++)
        {
            g_MapVoteOptions.GetString(i, replaceMap, sizeof(replaceMap));

            int votes = 0;
            if (g_MapVoteCounts != null)
            {
                g_MapVoteCounts.GetValue(replaceMap, votes);
            }

            if (votes == 0 && IsMapInTier(replaceMap, "tier1"))
            {
                replaceIndex = i;
                break;
            }
        }
    }

    if (replaceIndex == -1)
    {
        for (int i = 0; i < g_MapVoteOptions.Length; i++)
        {
            g_MapVoteOptions.GetString(i, replaceMap, sizeof(replaceMap));

            int votes = 0;
            if (g_MapVoteCounts != null)
            {
                g_MapVoteCounts.GetValue(replaceMap, votes);
            }

            if (votes == 0)
            {
                replaceIndex = i;
                break;
            }
        }
    }

    if (replaceIndex == -1)
    {
        return force ? Nominate_VoteFull : Nominate_VoteFull;
    }

    g_MapVoteOptions.SetString(replaceIndex, map);

    if (g_MapVoteCounts != null)
    {
        g_MapVoteCounts.Remove(replaceMap);
        g_MapVoteCounts.SetValue(map, 0);
    }

    UpdateNominateStatus(replaceMap, false);
    UpdateNominateStatus(map, true);

    return Nominate_Replaced;
}

public int Handler_AvoteVote(NativeVote vote, MenuAction action, int param1, int param2)
{
    switch (action)
    {
        case MenuAction_Select:
        {
            int client = param1;
            int item = param2;
            char mapName[PLATFORM_MAX_PATH];
            NativeVotes_GetItem(vote, item, mapName, sizeof(mapName));
            RecordMapVote(client, mapName);
        }
        case MenuAction_VoteEnd, MenuAction_VoteCancel:
        {
            if (g_MapVoteFinalize)
            {
                char mapName[PLATFORM_MAX_PATH];
                if (GetMapVoteWinner(mapName, sizeof(mapName)))
                {
                    SetNextMapFromVote(mapName);
                    NativeVotes_DisplayPassEx(vote, NativeVotesPass_NextLevel, mapName);
                    return 0;
                }
            }

            NativeVotes_DisplayFail(vote, NativeVotesFail_Generic);
            if (g_CvarNextMap != null)
            {
                g_CvarNextMap.SetString("");
            }
        }
        case MenuAction_End:
        {
            vote.Close();
            g_AvoteVote = null;
            g_MapVoteFinalize = false;
            if (g_AutoVoteStarted && g_CvarVoteDone != null && !g_CvarVoteDone.BoolValue)
            {
                g_AutoVoteStarted = false;
            }
        }
    }

    return 0;
}

public int MenuHandler_AvotePersonal(Menu menu, MenuAction action, int param1, int param2)
{
    switch (action)
    {
        case MenuAction_Select:
        {
            int client = param1;
            char mapName[PLATFORM_MAX_PATH];
            menu.GetItem(param2, mapName, sizeof(mapName));
            RecordMapVote(client, mapName);
            ReplyToCommand(client, "[SM] Your vote for %s has been recorded.", mapName);
        }
        case MenuAction_DisplayItem:
        {
            char mapName[PLATFORM_MAX_PATH];
            menu.GetItem(param2, mapName, sizeof(mapName));
            if (g_MapVoteVoted[param1] && StrEqual(g_MapVoteChoice[param1], mapName, false))
            {
                char display[PLATFORM_MAX_PATH + 8];
                Format(display, sizeof(display), "%s (voted)", mapName);
                return RedrawMenuItem(display);
            }
        }
        case MenuAction_End:
        {
            delete menu;
        }
    }

    return 0;
}

static void SetNextMapFromVote(const char[] mapName)
{
    SetNextMap(mapName);
    CPrintToChatAll("[SM] Next map set to {gold}%s", mapName);
    if (g_CvarVoteDone != null)
    {
        g_CvarVoteDone.SetBool(true);
    }
}

static void ResetMapVoteState()
{
    if (g_MapVoteOptions == null)
    {
        g_MapVoteOptions = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
    }
    else
    {
        g_MapVoteOptions.Clear();
    }

    if (g_MapVoteCounts == null)
    {
        g_MapVoteCounts = new StringMap();
    }
    else
    {
        g_MapVoteCounts.Clear();
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        g_MapVoteVoted[i] = false;
        g_MapVoteChoice[i][0] = 0;
    }
}

static void SelectMapVoteOptions()
{
    ResetMapVoteState();

    ArrayList tier1Lists = new ArrayList();
    ArrayList tier2Lists = new ArrayList();
    BuildAvoteTierLists(tier1Lists, tier2Lists);
    if (tier1Lists.Length == 0 && tier2Lists.Length == 0)
    {
        delete tier1Lists;
        delete tier2Lists;
        LogError("[MapEval] No tiers available in mapeval.cfg.");
        return;
    }

    ArrayList tier1Pool = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
    ArrayList tier2Pool = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
    StringMap seen = new StringMap();
    BuildPoolFromLists(tier1Lists, tier1Pool, seen, g_CurrentMap);
    BuildPoolFromLists(tier2Lists, tier2Pool, seen, g_CurrentMap);

    char mapName[PLATFORM_MAX_PATH];
    int maxPicks = 5;
    while ((tier1Pool.Length > 0 || tier2Pool.Length > 0) && g_MapVoteOptions.Length < maxPicks)
    {
        bool preferTier1 = (GetRandomInt(1, 100) <= 60);
        ArrayList pool = preferTier1 ? tier1Pool : tier2Pool;
        if (pool.Length == 0)
        {
            pool = preferTier1 ? tier2Pool : tier1Pool;
        }
        if (pool.Length == 0)
        {
            break;
        }

        int idx = GetRandomInt(0, pool.Length - 1);
        pool.GetString(idx, mapName, sizeof(mapName));
        pool.Erase(idx);
        g_MapVoteOptions.PushString(mapName);
    }

    delete tier1Lists;
    delete tier2Lists;
    delete tier1Pool;
    delete tier2Pool;
    delete seen;

    if (g_MapVoteOptions.Length == 0)
    {
        LogError("[MapEval] No eligible maps found for mapvote2.");
    }
}

static void BuildPoolFromLists(ArrayList lists, ArrayList pool, StringMap seen, const char[] currentMap)
{
    if (lists == null || pool == null)
    {
        return;
    }

    char mapName[PLATFORM_MAX_PATH];
    for (int i = 0; i < lists.Length; i++)
    {
        ArrayList maps = view_as<ArrayList>(lists.Get(i));
        if (maps == null)
        {
            continue;
        }

        for (int j = 0; j < maps.Length; j++)
        {
            maps.GetString(j, mapName, sizeof(mapName));
            TrimString(mapName);
            if (!mapName[0])
            {
                continue;
            }
            if (currentMap[0] && StrEqual(mapName, currentMap, false))
            {
                continue;
            }
            if (!IsMapValid(mapName))
            {
                continue;
            }
            if (seen != null)
            {
                int dummy;
                if (seen.GetValue(mapName, dummy))
                {
                    continue;
                }
                seen.SetValue(mapName, 1);
            }
            pool.PushString(mapName);
        }
    }
}

static void UpdateNominateStatus(const char[] mapName, bool nominated)
{
    if (g_NominateStatus == null)
    {
        return;
    }

    int status;
    if (!g_NominateStatus.GetValue(mapName, status))
    {
        return;
    }

    if (nominated)
    {
        g_NominateStatus.SetValue(mapName, NOMINATE_STATUS_DISABLED | NOMINATE_STATUS_EXCLUDE_NOMINATED);
        return;
    }

    status &= ~NOMINATE_STATUS_EXCLUDE_NOMINATED;
    if ((status & (NOMINATE_STATUS_EXCLUDE_CURRENT | NOMINATE_STATUS_EXCLUDE_PREVIOUS)) == 0)
    {
        status = NOMINATE_STATUS_ENABLED;
    }
    else
    {
        status |= NOMINATE_STATUS_DISABLED;
    }

    g_NominateStatus.SetValue(mapName, status);
}

static int FindMatchingMaps(ArrayList mapList, ArrayList results, const char[] input)
{
    if (mapList == null)
    {
        return -1;
    }

    int mapCount = mapList.Length;
    if (!mapCount)
    {
        return -1;
    }

    int matches = 0;
    char map[PLATFORM_MAX_PATH];
    int maxMatches = (g_CvarNominateMaxMatches != null) ? g_CvarNominateMaxMatches.IntValue : 0;

    for (int i = 0; i < mapCount; i++)
    {
        mapList.GetString(i, map, sizeof(map));
        if (StrContains(map, input) != -1)
        {
            results.Push(i);
            matches++;

            if (maxMatches > 0 && matches >= maxMatches)
            {
                break;
            }
        }
    }

    return matches;
}

static void AttemptNominate(int client, const char[] map, int size)
{
    EnsureMapVoteOptions();

    char mapname[PLATFORM_MAX_PATH];
    if (FindMap(map, mapname, size) == FindMap_NotFound)
    {
        ReplyToCommand(client, "%t", "Map was not found", mapname);
        return;
    }

    char displayName[PLATFORM_MAX_PATH];
    GetMapDisplayName(mapname, displayName, sizeof(displayName));

    int status;
    if (g_NominateStatus == null || !g_NominateStatus.GetValue(mapname, status))
    {
        ReplyToCommand(client, "%t", "Map Not In Pool", displayName);
        return;
    }

    if ((status & NOMINATE_STATUS_DISABLED) == NOMINATE_STATUS_DISABLED)
    {
        if ((status & NOMINATE_STATUS_EXCLUDE_CURRENT) == NOMINATE_STATUS_EXCLUDE_CURRENT)
        {
            ReplyToCommand(client, "[SM] %t", "Can't Nominate Current Map");
        }

        if ((status & NOMINATE_STATUS_EXCLUDE_PREVIOUS) == NOMINATE_STATUS_EXCLUDE_PREVIOUS)
        {
            ReplyToCommand(client, "[SM] %t", "Map in Exclude List");
        }

        if ((status & NOMINATE_STATUS_EXCLUDE_NOMINATED) == NOMINATE_STATUS_EXCLUDE_NOMINATED)
        {
            ReplyToCommand(client, "[SM] %t", "Map Already Nominated");
        }

        return;
    }

    if (g_MapVoteOptions == null || g_MapVoteOptions.Length == 0)
    {
        ReplyToCommand(client, "[SM] No mapvote options are available.");
        return;
    }

    if (g_MapVoteOptions.FindString(mapname) != -1)
    {
        ReplyToCommand(client, "%t", "Map Already In Vote", displayName);
        return;
    }

    int replaceIndex = -1;
    char replaceMap[PLATFORM_MAX_PATH];
    for (int i = 0; i < g_MapVoteOptions.Length; i++)
    {
        g_MapVoteOptions.GetString(i, replaceMap, sizeof(replaceMap));

        int votes = 0;
        if (g_MapVoteCounts != null)
        {
            g_MapVoteCounts.GetValue(replaceMap, votes);
        }

        if (votes == 0 && IsMapInTier(replaceMap, "tier2"))
        {
            replaceIndex = i;
            break;
        }
    }

    if (replaceIndex == -1)
    {
        for (int i = 0; i < g_MapVoteOptions.Length; i++)
        {
            g_MapVoteOptions.GetString(i, replaceMap, sizeof(replaceMap));

            int votes = 0;
            if (g_MapVoteCounts != null)
            {
                g_MapVoteCounts.GetValue(replaceMap, votes);
            }

            if (votes == 0 && IsMapInTier(replaceMap, "tier1"))
            {
                replaceIndex = i;
                break;
            }
        }
    }

    if (replaceIndex == -1)
    {
        for (int i = 0; i < g_MapVoteOptions.Length; i++)
        {
            g_MapVoteOptions.GetString(i, replaceMap, sizeof(replaceMap));

            int votes = 0;
            if (g_MapVoteCounts != null)
            {
                g_MapVoteCounts.GetValue(replaceMap, votes);
            }

            if (votes == 0)
            {
                replaceIndex = i;
                break;
            }
        }
    }

    if (replaceIndex == -1)
    {
        ReplyToCommand(client, "[SM] %t", "Max Nominations");
        return;
    }

    g_MapVoteOptions.SetString(replaceIndex, mapname);

    if (g_MapVoteCounts != null)
    {
        g_MapVoteCounts.Remove(replaceMap);
        g_MapVoteCounts.SetValue(mapname, 0);
    }

    UpdateNominateStatus(replaceMap, false);
    UpdateNominateStatus(mapname, true);

    char name[MAX_NAME_LENGTH];
    GetClientName(client, name, sizeof(name));

    PrintToChatAll("[SM] %t", "Map Nominated", name, displayName);
}

static void QueueRandomNomination(int client)
{
    if (g_NominateMapList == null || g_NominateMapList.Length == 0)
    {
        ReplyToCommand(client, "[SM] No maps available to nominate.");
        return;
    }

    ArrayList candidates = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
    char map[PLATFORM_MAX_PATH];
    for (int i = 0; i < g_NominateMapList.Length; i++)
    {
        g_NominateMapList.GetString(i, map, sizeof(map));
        FindMap(map, map, sizeof(map));

        int status;
        if (g_NominateStatus == null || !g_NominateStatus.GetValue(map, status))
        {
            continue;
        }
        if ((status & NOMINATE_STATUS_DISABLED) == NOMINATE_STATUS_DISABLED)
        {
            continue;
        }

        candidates.PushString(map);
    }

    if (candidates.Length == 0)
    {
        delete candidates;
        ReplyToCommand(client, "[SM] No eligible maps to nominate.");
        return;
    }

    int pick = GetRandomInt(0, candidates.Length - 1);
    candidates.GetString(pick, map, sizeof(map));
    delete candidates;

    if (g_RandomNominateTimer[client] != INVALID_HANDLE)
    {
        delete g_RandomNominateTimer[client];
        g_RandomNominateTimer[client] = INVALID_HANDLE;
    }

    char displayName[PLATFORM_MAX_PATH];
    GetMapDisplayName(map, displayName, sizeof(displayName));
    strcopy(g_RandomNominateMap[client], sizeof(g_RandomNominateMap[]), map);
    g_RandomNominateUserId[client] = GetClientUserId(client);
    g_RandomNominateTimer[client] = CreateTimer(RANDOM_NOMINATION_DELAY, Timer_RandomNominate, client);

    CPrintToChat(client, "[SM] Random map: {green}%s", displayName);
    CPrintToChat(client, "[SM] Use {gold}!nr{default} again within 5 seconds to roll for another map instead.");
}

public Action Timer_RandomNominate(Handle timer, any client)
{
    int index = view_as<int>(client);
    if (index <= 0 || index > MaxClients)
    {
        return Plugin_Stop;
    }

    g_RandomNominateTimer[index] = INVALID_HANDLE;

    if (g_RandomNominateUserId[index] != GetClientUserId(index))
    {
        g_RandomNominateMap[index][0] = '\0';
        return Plugin_Stop;
    }
    if (g_RandomNominateMap[index][0] == '\0')
    {
        return Plugin_Stop;
    }

    AttemptNominate(index, g_RandomNominateMap[index], sizeof(g_RandomNominateMap[]));
    g_RandomNominateMap[index][0] = '\0';
    return Plugin_Stop;
}

static void OpenNominationMenu(int client)
{
    if (g_NominateMenu == null)
    {
        ReplyToCommand(client, "[SM] No maps available to nominate.");
        return;
    }

    g_NominateMenu.SetTitle("%T", "Nominate Title", client);
    g_NominateMenu.Display(client, MENU_TIME_FOREVER);
}

static void BuildNominationMenu()
{
    delete g_NominateMenu;
    g_NominateMenu = null;

    if (g_NominateStatus == null)
    {
        g_NominateStatus = new StringMap();
    }
    else
    {
        g_NominateStatus.Clear();
    }

    if (g_NominateMapList == null || g_NominateMapList.Length == 0)
    {
        return;
    }

    g_NominateMenu = new Menu(MenuHandler_NominateSelect, MENU_ACTIONS_DEFAULT | MenuAction_DrawItem | MenuAction_DisplayItem);

    char map[PLATFORM_MAX_PATH];
    ArrayList excludeMaps = null;
    char currentMap[PLATFORM_MAX_PATH];

    if (g_CvarNominateExcludeOld != null && g_CvarNominateExcludeOld.BoolValue)
    {
        excludeMaps = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
        GetExcludeMapList(excludeMaps);
    }

    if (g_CvarNominateExcludeCurrent != null && g_CvarNominateExcludeCurrent.BoolValue)
    {
        GetCurrentMap(currentMap, sizeof(currentMap));
    }

    for (int i = 0; i < g_NominateMapList.Length; i++)
    {
        int status = NOMINATE_STATUS_ENABLED;

        g_NominateMapList.GetString(i, map, sizeof(map));
        FindMap(map, map, sizeof(map));

        char displayName[PLATFORM_MAX_PATH];
        GetMapDisplayName(map, displayName, sizeof(displayName));

        if (g_CvarNominateExcludeCurrent != null && g_CvarNominateExcludeCurrent.BoolValue)
        {
            if (StrEqual(map, currentMap))
            {
                status = NOMINATE_STATUS_DISABLED | NOMINATE_STATUS_EXCLUDE_CURRENT;
            }
        }

        if (excludeMaps != null && status == NOMINATE_STATUS_ENABLED)
        {
            if (excludeMaps.FindString(map) != -1)
            {
                status = NOMINATE_STATUS_DISABLED | NOMINATE_STATUS_EXCLUDE_PREVIOUS;
            }
        }

        g_NominateMenu.AddItem(map, displayName);
        g_NominateStatus.SetValue(map, status);
    }

    g_NominateMenu.ExitButton = true;

    delete excludeMaps;
}

static void TrimOldMapList()
{
    if (g_OldMapList == null || g_CvarExcludeMaps == null)
    {
        return;
    }

    int max = g_CvarExcludeMaps.IntValue;
    if (max < 0)
    {
        max = 0;
    }

    while (g_OldMapList.Length > max)
    {
        g_OldMapList.Erase(0);
    }
}

static void GetExcludeMapList(ArrayList array)
{
    if (array == null || g_OldMapList == null)
    {
        return;
    }

    TrimOldMapList();

    char map[PLATFORM_MAX_PATH];
    for (int i = 0; i < g_OldMapList.Length; i++)
    {
        g_OldMapList.GetString(i, map, sizeof(map));
        array.PushString(map);
    }
}

public int MenuHandler_NominateSelect(Menu menu, MenuAction action, int param1, int param2)
{
    switch (action)
    {
        case MenuAction_Select:
        {
            char mapname[PLATFORM_MAX_PATH];
            menu.GetItem(param2, mapname, sizeof(mapname));
            AttemptNominate(param1, mapname, sizeof(mapname));
        }
        case MenuAction_DrawItem:
        {
            char map[PLATFORM_MAX_PATH];
            menu.GetItem(param2, map, sizeof(map));

            int status;
            if (g_NominateStatus == null || !g_NominateStatus.GetValue(map, status))
            {
                LogError("Menu selection of item not in status map.");
                return ITEMDRAW_DEFAULT;
            }

            if ((status & NOMINATE_STATUS_DISABLED) == NOMINATE_STATUS_DISABLED)
            {
                return ITEMDRAW_DISABLED;
            }

            return ITEMDRAW_DEFAULT;
        }
        case MenuAction_DisplayItem:
        {
            char mapname[PLATFORM_MAX_PATH];
            menu.GetItem(param2, mapname, sizeof(mapname));

            int status;
            if (g_NominateStatus == null || !g_NominateStatus.GetValue(mapname, status))
            {
                LogError("Menu selection of item not in status map.");
                return 0;
            }

            if ((status & NOMINATE_STATUS_DISABLED) == NOMINATE_STATUS_DISABLED)
            {
                char displayName[PLATFORM_MAX_PATH];
                GetMapDisplayName(mapname, displayName, sizeof(displayName));

                if ((status & NOMINATE_STATUS_EXCLUDE_CURRENT) == NOMINATE_STATUS_EXCLUDE_CURRENT)
                {
                    Format(mapname, sizeof(mapname), "%s (%T)", displayName, "Current Map", param1);
                    return RedrawMenuItem(mapname);
                }

                if ((status & NOMINATE_STATUS_EXCLUDE_PREVIOUS) == NOMINATE_STATUS_EXCLUDE_PREVIOUS)
                {
                    Format(mapname, sizeof(mapname), "%s (%T)", displayName, "Recently Played", param1);
                    return RedrawMenuItem(mapname);
                }

                if ((status & NOMINATE_STATUS_EXCLUDE_NOMINATED) == NOMINATE_STATUS_EXCLUDE_NOMINATED)
                {
                    Format(mapname, sizeof(mapname), "%s (%T)", displayName, "Nominated", param1);
                    return RedrawMenuItem(mapname);
                }
            }
        }
        case MenuAction_End:
        {
            if (menu != g_NominateMenu)
            {
                delete menu;
            }
        }
    }

    return 0;
}

static void RefreshNominateMapList()
{
    if (g_NominateMapList == null)
    {
        g_NominateMapList = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
    }

    Handle result = ReadMapList(g_NominateMapList,
        g_NominateMapListSerial,
        "nominations",
        MAPLIST_FLAG_CLEARARRAY | MAPLIST_FLAG_MAPSFOLDER);

    if (result == INVALID_HANDLE && g_NominateMapListSerial == -1)
    {
        LogError("Unable to create a valid nominations map list.");
        g_NominateMapList.Clear();
    }

    BuildNominationMenu();
}

static void RecordMapVote(int client, const char[] mapName)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    if (g_MapVoteOptions == null || g_MapVoteOptions.FindString(mapName) == -1)
    {
        return;
    }

    if (g_MapVoteVoted[client])
    {
        if (StrEqual(g_MapVoteChoice[client], mapName, false))
        {
            return;
        }

        if (g_MapVoteChoice[client][0])
        {
            AdjustMapVoteCount(g_MapVoteChoice[client], -1);
        }
    }

    g_MapVoteVoted[client] = true;
    strcopy(g_MapVoteChoice[client], sizeof(g_MapVoteChoice[]), mapName);
    AdjustMapVoteCount(mapName, 1);
}

static void AdjustMapVoteCount(const char[] mapName, int delta)
{
    if (g_MapVoteCounts == null || !mapName[0])
    {
        return;
    }

    int count = 0;
    g_MapVoteCounts.GetValue(mapName, count);
    count += delta;
    if (count < 0)
    {
        count = 0;
    }
    g_MapVoteCounts.SetValue(mapName, count);
}

static void EnsureMapVoteOptions()
{
    if (g_MapVoteOptions != null && g_MapVoteOptions.Length > 0)
    {
        return;
    }

    UpdateCurrentMap();
    UpdateGameModeFromMap();
    SelectMapVoteOptions();
}

static bool GetMapVoteWinner(char[] outMap, int outMax)
{
    EnsureMapVoteOptions();
    if (g_MapVoteOptions == null || g_MapVoteOptions.Length == 0)
    {
        return false;
    }

    int bestVotes = -1;
    ArrayList ties = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
    char mapName[PLATFORM_MAX_PATH];

    for (int i = 0; i < g_MapVoteOptions.Length; i++)
    {
        g_MapVoteOptions.GetString(i, mapName, sizeof(mapName));

        int votes = 0;
        if (g_MapVoteCounts != null)
        {
            g_MapVoteCounts.GetValue(mapName, votes);
        }

        if (votes > bestVotes)
        {
            bestVotes = votes;
            ties.Clear();
            ties.PushString(mapName);
        }
        else if (votes == bestVotes)
        {
            ties.PushString(mapName);
        }
    }

    if (ties.Length == 0)
    {
        delete ties;
        return false;
    }

    int idx = GetRandomInt(0, ties.Length - 1);
    ties.GetString(idx, outMap, outMax);
    delete ties;
    return true;
}

static void BuildAvoteTierLists(ArrayList tier1Lists, ArrayList tier2Lists)
{
    if (tier1Lists == null || tier2Lists == null)
    {
        return;
    }

    tier1Lists.Clear();
    tier2Lists.Clear();

    if (g_MapEvalGamemodes == null)
    {
        return;
    }

    StringMap tiers = null;
    bool addedCurrent = false;
    if (g_GameMode[0] != 0)
    {
        int tiersValue;
        if (g_MapEvalGamemodes.GetValue(g_GameMode, tiersValue))
        {
            tiers = view_as<StringMap>(tiersValue);
        }
    }

    if (tiers != null)
    {
        AddTierLists(tiers, tier1Lists, tier2Lists);
        addedCurrent = true;
    }

    StringMapSnapshot snapshot = g_MapEvalGamemodes.Snapshot();
    int count = snapshot.Length;
    char gamemode[64];
    for (int i = 0; i < count; i++)
    {
        snapshot.GetKey(i, gamemode, sizeof(gamemode));
        if (addedCurrent && StrEqual(gamemode, g_GameMode, false))
        {
            continue;
        }

        int tiersValue;
        if (!g_MapEvalGamemodes.GetValue(gamemode, tiersValue))
        {
            continue;
        }

        tiers = view_as<StringMap>(tiersValue);
        if (tiers != null)
        {
            AddTierLists(tiers, tier1Lists, tier2Lists);
        }
    }

    delete snapshot;
}

static void AddTierLists(StringMap tiers, ArrayList tier1Lists, ArrayList tier2Lists)
{
    if (tiers == null || tier1Lists == null || tier2Lists == null)
    {
        return;
    }

    StringMapSnapshot tierSnapshot = tiers.Snapshot();
    int tierCount = tierSnapshot.Length;
    char tierName[64];
    for (int i = 0; i < tierCount; i++)
    {
        tierSnapshot.GetKey(i, tierName, sizeof(tierName));

        int mapsValue;
        if (!tiers.GetValue(tierName, mapsValue))
        {
            continue;
        }

        ArrayList maps = view_as<ArrayList>(mapsValue);
        if (maps != null && maps.Length > 0)
        {
            if (StrEqual(tierName, "tier1", false))
            {
                tier1Lists.Push(view_as<int>(maps));
            }
            else
            {
                tier2Lists.Push(view_as<int>(maps));
            }
        }
    }

    delete tierSnapshot;
}

static bool MapListContains(ArrayList maps, const char[] mapName)
{
    if (maps == null || !mapName[0])
    {
        return false;
    }

    char entry[PLATFORM_MAX_PATH];
    for (int i = 0; i < maps.Length; i++)
    {
        maps.GetString(i, entry, sizeof(entry));
        TrimString(entry);
        if (entry[0] && StrEqual(entry, mapName, false))
        {
            return true;
        }
    }

    return false;
}

static bool IsMapInTier(const char[] mapName, const char[] tierName)
{
    if (g_MapEvalGamemodes == null || !mapName[0] || !tierName[0])
    {
        return false;
    }

    StringMapSnapshot snapshot = g_MapEvalGamemodes.Snapshot();
    int count = snapshot.Length;
    char gamemode[64];
    for (int i = 0; i < count; i++)
    {
        snapshot.GetKey(i, gamemode, sizeof(gamemode));

        int tiersValue;
        if (!g_MapEvalGamemodes.GetValue(gamemode, tiersValue))
        {
            continue;
        }

        StringMap tiers = view_as<StringMap>(tiersValue);
        if (tiers == null)
        {
            continue;
        }

        int mapsValue;
        if (!tiers.GetValue(tierName, mapsValue))
        {
            continue;
        }

        ArrayList maps = view_as<ArrayList>(mapsValue);
        if (MapListContains(maps, mapName))
        {
            delete snapshot;
            return true;
        }
    }

    delete snapshot;
    return false;
}

static void ClearMapEvalConfig()
{
    if (g_MapEvalGamemodes == null)
    {
        return;
    }

    StringMapSnapshot snapshot = g_MapEvalGamemodes.Snapshot();
    int count = snapshot.Length;
    char gamemode[64];
    for (int i = 0; i < count; i++)
    {
        snapshot.GetKey(i, gamemode, sizeof(gamemode));

        int tiersValue;
        if (!g_MapEvalGamemodes.GetValue(gamemode, tiersValue))
        {
            continue;
        }

        StringMap tiers = view_as<StringMap>(tiersValue);
        if (tiers == null)
        {
            continue;
        }

        StringMapSnapshot tierSnapshot = tiers.Snapshot();
        int tierCount = tierSnapshot.Length;
        char tierName[64];
        for (int t = 0; t < tierCount; t++)
        {
            tierSnapshot.GetKey(t, tierName, sizeof(tierName));

            int mapsValue;
            if (!tiers.GetValue(tierName, mapsValue))
            {
                continue;
            }

            ArrayList maps = view_as<ArrayList>(mapsValue);
            if (maps != null)
            {
                delete maps;
            }
        }

        delete tierSnapshot;
        tiers.Clear();
        delete tiers;
    }

    delete snapshot;
    g_MapEvalGamemodes.Clear();
}

static void LoadMapEvalConfig()
{
    if (g_MapEvalGamemodes == null)
    {
        g_MapEvalGamemodes = new StringMap();
    }

    ClearMapEvalConfig();

    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), MAP_EVAL_CONFIG_FILE);

    if (!FileExists(path))
    {
        LogError("[MapEval] Config file not found: %s", path);
        return;
    }

    KeyValues kv = new KeyValues("mapEval");
    if (!kv.ImportFromFile(path))
    {
        LogError("[MapEval] Failed to parse config file: %s", path);
        delete kv;
        return;
    }

    if (!kv.GotoFirstSubKey())
    {
        delete kv;
        return;
    }

    do
    {
        char gamemode[64];
        kv.GetSectionName(gamemode, sizeof(gamemode));
        if (!gamemode[0])
        {
            continue;
        }

        StringMap tiers = new StringMap();

        if (kv.GotoFirstSubKey(false))
        {
            do
            {
                char tierName[64];
                kv.GetSectionName(tierName, sizeof(tierName));
                if (!tierName[0])
                {
                    continue;
                }

                ArrayList maps = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));

                if (kv.GotoFirstSubKey(false))
                {
                    do
                    {
                        char mapName[PLATFORM_MAX_PATH];
                        kv.GetSectionName(mapName, sizeof(mapName));
                        if (mapName[0])
                        {
                            maps.PushString(mapName);
                        }
                    }
                    while (kv.GotoNextKey(false));

                    kv.GoBack();
                }

                tiers.SetValue(tierName, view_as<int>(maps));
            }
            while (kv.GotoNextKey(false));

            kv.GoBack();
        }

        g_MapEvalGamemodes.SetValue(gamemode, view_as<int>(tiers));
    }
    while (kv.GotoNextKey());

    delete kv;
}

static void UpdateCurrentMap()
{
    g_CurrentMap[0] = 0;
    GetCurrentMap(g_CurrentMap, sizeof(g_CurrentMap));
}

static void UpdateGameModeFromMap()
{
    g_GameMode[0] = 0;

    char mapName[PLATFORM_MAX_PATH];
    strcopy(mapName, sizeof(mapName), g_CurrentMap);
    ReplaceStringEx(mapName, sizeof(mapName), "workshop/", "");

    if (StrContains(mapName, "koth_", false) == 0)
    {
        strcopy(g_GameMode, sizeof(g_GameMode), "koth");
    }
    else if (StrContains(mapName, "plr_", false) == 0 || StrContains(mapName, "pl_", false) == 0)
    {
        strcopy(g_GameMode, sizeof(g_GameMode), "pl");
    }
    else if (StrContains(mapName, "cp_", false) == 0)
    {
        strcopy(g_GameMode, sizeof(g_GameMode), "cp");
    }
    else if (StrContains(mapName, "ctf_", false) == 0)
    {
        strcopy(g_GameMode, sizeof(g_GameMode), "ctf");
    }
    else
    {
        strcopy(g_GameMode, sizeof(g_GameMode), "other");
    }
}
