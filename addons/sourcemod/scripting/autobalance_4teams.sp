#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <clientprefs>
#include <morecolors>
#include <tf2_stocks>

#define CHECK_INTERVAL 5.0
#define TEAM_RED 2
#define TEAM_BLUE 3
#define TEAM_GREEN 4
#define TEAM_YELLOW 5
#define GAME_TEAM_COUNT 4

static const int g_GameTeams[GAME_TEAM_COUNT] =
{
    TEAM_RED,
    TEAM_BLUE,
    TEAM_GREEN,
    TEAM_YELLOW
};

Handle g_hImmunityCookie;
bool g_bClearImmunity[MAXPLAYERS + 1];
ConVar g_hLogEnabled;
ConVar g_hMpAutoteamBalance;
ConVar g_hMpTeamsUnbalanceLimit;
char g_sLogPath[PLATFORM_MAX_PATH];

public Plugin myinfo =
{
    name = "autobalance_4teams",
    author = "Hombre",
    description = "Moves players when 4 teams are imbalanced.",
    version = "1.2",
    url = ""
};

public void OnPluginStart()
{
    g_hLogEnabled = CreateConVar("sm_autobalance_log", "1", "Enable autobalance debug logging.", _, true, 0.0, true, 1.0);
    BuildPath(Path_SM, g_sLogPath, sizeof(g_sLogPath), "logs/autobalance.log");

    g_hImmunityCookie = RegClientCookie(
        "autobalance_immune",
        "Autobalance immunity for current map",
        CookieAccess_Private);

    ApplyServerBalanceCvars(true);
    CreateTimer(CHECK_INTERVAL, Timer_Autobalance, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnPluginEnd()
{
    ApplyServerBalanceCvars(false);
}

public void OnMapStart()
{
    ResetImmunityForConnectedClients();
}

public void OnClientCookiesCached(int client)
{
    if (!IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    if (g_bClearImmunity[client])
    {
        SetClientCookie(client, g_hImmunityCookie, "0");
        g_bClearImmunity[client] = false;
    }
}

public Action Timer_Autobalance(Handle timer)
{
    int teamCounts[6];

    for (int i = 0; i < GAME_TEAM_COUNT; i++)
    {
        int team = g_GameTeams[i];
        int count = CountTeamPlayersRaw(team);
        teamCounts[team] = count;
    }

    int activeTeams[GAME_TEAM_COUNT];
    int activeCount = 0;
    activeTeams[activeCount++] = TEAM_RED;
    activeTeams[activeCount++] = TEAM_BLUE;

    // Minimal mode-guard:
    // If either green/yellow has players, treat mode as 4-team and include both.
    if (teamCounts[TEAM_GREEN] > 0 || teamCounts[TEAM_YELLOW] > 0)
    {
        activeTeams[activeCount++] = TEAM_GREEN;
        activeTeams[activeCount++] = TEAM_YELLOW;
    }

    int biggestTeam = 0;
    int smallestTeam = 0;
    int biggestCount = -1;
    int smallestCount = 99999;

    for (int i = 0; i < activeCount; i++)
    {
        int team = activeTeams[i];
        int count = teamCounts[team];
        if (count > biggestCount)
        {
            biggestCount = count;
            biggestTeam = team;
        }

        if (count < smallestCount)
        {
            smallestCount = count;
            smallestTeam = team;
        }
    }

    if (biggestTeam == 0 || smallestTeam == 0 || biggestTeam == smallestTeam)
    {
        return Plugin_Continue;
    }

    int diff = biggestCount - smallestCount;
    if (diff < 2)
    {
        return Plugin_Continue;
    }

    bool forceBalance = (diff > 2);
    char fromTeamName[16];
    char toTeamName[16];
    AB_GetTeamName(biggestTeam, fromTeamName, sizeof(fromTeamName));
    AB_GetTeamName(smallestTeam, toTeamName, sizeof(toTeamName));
    LogBalance(
        "Imbalance: RED=%d BLU=%d GREEN=%d YELLOW=%d | from=%s(%d) to=%s(%d) force=%s",
        teamCounts[TEAM_RED], teamCounts[TEAM_BLUE], teamCounts[TEAM_GREEN], teamCounts[TEAM_YELLOW],
        fromTeamName, biggestCount, toTeamName, smallestCount,
        forceBalance ? "yes" : "no"
    );
    PrintToServer(
        "[autobalance_4teams] Imbalance: RED=%d BLU=%d GREEN=%d YELLOW=%d | from=%s(%d) to=%s(%d) force=%s",
        teamCounts[TEAM_RED], teamCounts[TEAM_BLUE], teamCounts[TEAM_GREEN], teamCounts[TEAM_YELLOW],
        fromTeamName, biggestCount, toTeamName, smallestCount,
        forceBalance ? "yes" : "no"
    );

    int totalScore = 0;
    int totalPlayers = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsEligiblePlayer(i, biggestTeam))
        {
            continue;
        }

        totalScore += GetClientScore(i);
        totalPlayers++;
    }

    if (totalPlayers == 0)
    {
        LogBalance("No eligible players on %s team.", fromTeamName);
        return Plugin_Continue;
    }

    float avg = float(totalScore) / float(totalPlayers);

    int candidates[MAXPLAYERS];
    int candidateCount = 0;

    // Pass 1: strict checks (except when force-balance mode is active).
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsEligiblePlayer(i, biggestTeam))
        {
            continue;
        }

        TFClassType cls = TF2_GetPlayerClass(i);
        if (cls == TFClass_Engineer || cls == TFClass_Medic)
        {
            continue;
        }

        if (!forceBalance)
        {
            if (IsPlayerAlive(i))
            {
                continue;
            }

            if (float(GetClientScore(i)) >= avg)
            {
                continue;
            }
        }

        candidates[candidateCount++] = i;
    }

    // Pass 2: if strict mode found none, relax score/alive constraints but keep class exclusions.
    if (candidateCount == 0 && !forceBalance)
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsEligiblePlayer(i, biggestTeam))
            {
                continue;
            }

            TFClassType cls = TF2_GetPlayerClass(i);
            if (cls == TFClass_Engineer || cls == TFClass_Medic)
            {
                continue;
            }

            candidates[candidateCount++] = i;
        }
    }

    if (candidateCount == 0)
    {
        LogBalance(
            "No candidates on %s team. avg=%.2f total=%d force=%d",
            fromTeamName, avg, totalPlayers, forceBalance ? 1 : 0
        );
        return Plugin_Continue;
    }

    int pick = candidates[GetRandomInt(0, candidateCount - 1)];
    int newTeam = smallestTeam;

    LogBalance("Autobalancing %N (%d) from %s to %s. score=%d avg=%.2f candidates=%d",
        pick,
        GetClientUserId(pick),
        fromTeamName,
        toTeamName,
        GetClientScore(pick),
        avg,
        candidateCount);

    PrintToServer(
        "[autobalance_4teams] move %N (%d) %s -> %s | score=%d avg=%.2f candidates=%d",
        pick,
        GetClientUserId(pick),
        fromTeamName,
        toTeamName,
        GetClientScore(pick),
        avg,
        candidateCount
    );

    ChangeClientTeam(pick, newTeam);
    SetClientImmunity(pick, true);

    CreateTimer(0.1, Timer_Respawn, GetClientUserId(pick), TIMER_FLAG_NO_MAPCHANGE);

    char teamColorName[24];
    AB_GetTeamColorName(newTeam, teamColorName, sizeof(teamColorName));
    CPrintToChatEx(pick, pick, "{lightgreen}[Server]{default} You've been autobalanced to %s{default}!", teamColorName);
    return Plugin_Continue;
}

public Action Timer_Respawn(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client > 0 && IsClientInGame(client))
    {
        TF2_RespawnPlayer(client);
    }

    return Plugin_Stop;
}

static bool IsEligiblePlayer(int client, int team)
{
    if (client <= 0 || client > MaxClients)
    {
        return false;
    }
    if (!IsClientInGame(client) || IsFakeClient(client))
    {
        return false;
    }
    if (GetClientTeam(client) != team)
    {
        return false;
    }
    if (IsClientImmune(client))
    {
        return false;
    }

    return true;
}

static bool IsClientImmune(int client)
{
    if (!AreClientCookiesCached(client))
    {
        return false;
    }

    char value[4];
    GetClientCookie(client, g_hImmunityCookie, value, sizeof(value));
    return (value[0] == '1');
}

static void SetClientImmunity(int client, bool immune)
{
    if (!IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    SetClientCookie(client, g_hImmunityCookie, immune ? "1" : "0");
    if (!immune)
    {
        g_bClearImmunity[client] = false;
    }
}

static void ResetImmunityForConnectedClients()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
        {
            continue;
        }

        if (AreClientCookiesCached(i))
        {
            SetClientCookie(i, g_hImmunityCookie, "0");
            g_bClearImmunity[i] = false;
        }
        else
        {
            g_bClearImmunity[i] = true;
        }
    }
}

static int CountTeamPlayersRaw(int team)
{
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
        {
            continue;
        }

        if (GetClientTeam(i) != team)
        {
            continue;
        }

        count++;
    }

    return count;
}

static int GetClientScore(int client)
{
    return GetClientFrags(client);
}

static void AB_GetTeamName(int team, char[] buffer, int maxlen)
{
    switch (team)
    {
        case TEAM_RED: strcopy(buffer, maxlen, "RED");
        case TEAM_BLUE: strcopy(buffer, maxlen, "BLU");
        case TEAM_GREEN: strcopy(buffer, maxlen, "GREEN");
        case TEAM_YELLOW: strcopy(buffer, maxlen, "YELLOW");
        default: strcopy(buffer, maxlen, "UNKNOWN");
    }
}

static void AB_GetTeamColorName(int team, char[] buffer, int maxlen)
{
    switch (team)
    {
        case TEAM_RED: strcopy(buffer, maxlen, "{red}Red");
        case TEAM_BLUE: strcopy(buffer, maxlen, "{blue}Blue");
        case TEAM_GREEN: strcopy(buffer, maxlen, "{green}Green");
        case TEAM_YELLOW: strcopy(buffer, maxlen, "{yellow}Yellow");
        default: strcopy(buffer, maxlen, "{default}Unknown");
    }
}

static void LogBalance(const char[] fmt, any ...)
{
    if (g_hLogEnabled == null || !g_hLogEnabled.BoolValue)
    {
        return;
    }

    char buffer[256];
    VFormat(buffer, sizeof(buffer), fmt, 2);
    LogToFileEx(g_sLogPath, "%s", buffer);
}

static void ApplyServerBalanceCvars(bool pluginLoaded)
{
    if (g_hMpAutoteamBalance == null)
    {
        g_hMpAutoteamBalance = FindConVar("mp_autoteambalance");
    }

    if (g_hMpTeamsUnbalanceLimit == null)
    {
        g_hMpTeamsUnbalanceLimit = FindConVar("mp_teams_unbalance_limit");
    }

    if (g_hMpAutoteamBalance != null)
    {
        g_hMpAutoteamBalance.IntValue = pluginLoaded ? 0 : 1;
    }

    if (g_hMpTeamsUnbalanceLimit != null)
    {
        g_hMpTeamsUnbalanceLimit.IntValue = 1;
    }
}
