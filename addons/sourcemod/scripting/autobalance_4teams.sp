#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <clientprefs>
#include <morecolors>
#include <tf2_stocks>

#define CHECK_INTERVAL      5.0
#define IMMUNITY_DURATION   300.0   // seconds a player stays immune after being balanced
#define TEAM_RED            2
#define TEAM_BLUE           3
#define TEAM_GREEN          4
#define TEAM_YELLOW         5
#define GAME_TEAM_COUNT     4

static const int g_GameTeams[GAME_TEAM_COUNT] =
{
    TEAM_RED,
    TEAM_BLUE,
    TEAM_GREEN,
    TEAM_YELLOW
};

float   g_fImmunityExpiry[MAXPLAYERS + 1];  // GetGameTime() at which immunity expires; 0.0 = not immune
ConVar  g_hLogEnabled;
ConVar  g_hMpAutoteamBalance;
ConVar  g_hMpTeamsUnbalanceLimit;
int     g_iSavedAutoteamBalance;
int     g_iSavedUnbalanceLimit;
char    g_sLogPath[PLATFORM_MAX_PATH];

public Plugin myinfo =
{
    name        = "autobalance_4teams",
    author      = "Hombre",
    description = "Moves players when 4 teams are imbalanced.",
    version     = "1.3",
    url         = "https://kogasa.tf"
};

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

public void OnPluginStart()
{
    g_hLogEnabled = CreateConVar("sm_autobalance_log", "1", "Enable autobalance debug logging.", _, true, 0.0, true, 1.0);
    BuildPath(Path_SM, g_sLogPath, sizeof(g_sLogPath), "logs/autobalance.log");
    LogToFileEx(g_sLogPath, "[autobalance_4teams] Plugin started.");

    ApplyServerBalanceCvars(true);

    CreateTimer(CHECK_INTERVAL, Timer_Autobalance, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnPluginEnd()
{
    ApplyServerBalanceCvars(false);
}

public void OnMapStart()
{
    // Reset all immunity timers at the start of every map.
    for (int i = 1; i <= MaxClients; i++)
    {
        g_fImmunityExpiry[i] = 0.0;
    }
}

// ---------------------------------------------------------------------------
// Main balance timer
// ---------------------------------------------------------------------------

public Action Timer_Autobalance(Handle timer)
{
    int teamCounts[6];

    for (int i = 0; i < GAME_TEAM_COUNT; i++)
    {
        int team = g_GameTeams[i];
        teamCounts[team] = CountTeamPlayersRaw(team);
    }

    // Build the list of active teams (always RED + BLU; add GREEN/YELLOW if populated).
    int activeTeams[GAME_TEAM_COUNT];
    int activeCount = 0;
    activeTeams[activeCount++] = TEAM_RED;
    activeTeams[activeCount++] = TEAM_BLUE;

    if (teamCounts[TEAM_GREEN] > 0 || teamCounts[TEAM_YELLOW] > 0)
    {
        activeTeams[activeCount++] = TEAM_GREEN;
        activeTeams[activeCount++] = TEAM_YELLOW;
    }

    // Sort active teams by count descending (simple insertion sort; max 4 elements).
    int sortedTeams[GAME_TEAM_COUNT];
    int sortedCounts[GAME_TEAM_COUNT];
    for (int i = 0; i < activeCount; i++)
    {
        sortedTeams[i]  = activeTeams[i];
        sortedCounts[i] = teamCounts[activeTeams[i]];
    }

    for (int i = 1; i < activeCount; i++)
    {
        int keyTeam  = sortedTeams[i];
        int keyCount = sortedCounts[i];
        int j = i - 1;
        while (j >= 0 && sortedCounts[j] < keyCount)
        {
            sortedTeams[j + 1]  = sortedTeams[j];
            sortedCounts[j + 1] = sortedCounts[j];
            j--;
        }
        sortedTeams[j + 1]  = keyTeam;
        sortedCounts[j + 1] = keyCount;
    }

    int biggestTeam   = sortedTeams[0];
    int biggestCount  = sortedCounts[0];
    int smallestTeam  = sortedTeams[activeCount - 1];
    int smallestCount = sortedCounts[activeCount - 1];

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
    AB_GetTeamName(biggestTeam,  fromTeamName, sizeof(fromTeamName));
    AB_GetTeamName(smallestTeam, toTeamName,   sizeof(toTeamName));

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

    // ------------------------------------------------------------------
    // Candidate selection.
    //
    // If forceBalance is active (diff > 2), switch immediately:
    // pick from any human on the oversized team, regardless of alive
    // state or immunity.
    //
    // Otherwise keep normal two-pass selection:
    //  Pass 1 (strict)    : dead, below-average score, non-Engi/Medic
    //  Pass 2 (relax s/a) : any alive/score state, non-Engi/Medic
    // ------------------------------------------------------------------

    int totalScore   = 0;
    int totalPlayers = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!(forceBalance ? IsEligiblePlayerForce(i, biggestTeam) : IsEligiblePlayer(i, biggestTeam)))
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

    if (forceBalance)
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsEligiblePlayerForce(i, biggestTeam)) continue;

            candidates[candidateCount++] = i;
        }
    }
    else
    {
        // Pass 1: strict — dead, below average, no Engi/Medic.
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsEligiblePlayer(i, biggestTeam)) continue;

            TFClassType cls = TF2_GetPlayerClass(i);
            if (cls == TFClass_Engineer || cls == TFClass_Medic) continue;
            if (IsPlayerAlive(i)) continue;
            if (float(GetClientScore(i)) >= avg) continue;

            candidates[candidateCount++] = i;
        }

        // Pass 2: relax score/alive, still exclude Engi/Medic.
        if (candidateCount == 0)
        {
            for (int i = 1; i <= MaxClients; i++)
            {
                if (!IsEligiblePlayer(i, biggestTeam)) continue;

                TFClassType cls = TF2_GetPlayerClass(i);
                if (cls == TFClass_Engineer || cls == TFClass_Medic) continue;

                candidates[candidateCount++] = i;
            }
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

    // Weight selection toward lowest-scoring candidates.
    // Build a cumulative-weight array where each candidate's weight is
    // (maxScore - score + 1) so the lowest scorer is most likely.
    int maxScore = 0;
    for (int i = 0; i < candidateCount; i++)
    {
        int s = GetClientScore(candidates[i]);
        if (s > maxScore) maxScore = s;
    }

    int weights[MAXPLAYERS];
    int totalWeight = 0;
    for (int i = 0; i < candidateCount; i++)
    {
        weights[i]   = maxScore - GetClientScore(candidates[i]) + 1;
        totalWeight += weights[i];
    }

    int roll = GetRandomInt(0, totalWeight - 1);
    int pick = candidates[0];
    int running = 0;
    for (int i = 0; i < candidateCount; i++)
    {
        running += weights[i];
        if (roll < running)
        {
            pick = candidates[i];
            break;
        }
    }

    LogBalance(
        "Autobalancing %N (%d) from %s to %s. score=%d avg=%.2f candidates=%d",
        pick, GetClientUserId(pick),
        fromTeamName, toTeamName,
        GetClientScore(pick), avg, candidateCount
    );
    PrintToServer(
        "[autobalance_4teams] move %N (%d) %s -> %s | score=%d avg=%.2f candidates=%d",
        pick, GetClientUserId(pick),
        fromTeamName, toTeamName,
        GetClientScore(pick), avg, candidateCount
    );

    ChangeClientTeam(pick, smallestTeam);
    SetClientImmunity(pick, true);

    CreateTimer(0.1, Timer_Respawn, GetClientUserId(pick), TIMER_FLAG_NO_MAPCHANGE);

    char teamColorName[24];
    AB_GetTeamColorName(smallestTeam, teamColorName, sizeof(teamColorName));
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

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static bool IsEligiblePlayer(int client, int team)
{
    if (client <= 0 || client > MaxClients) return false;
    if (!IsClientInGame(client) || IsFakeClient(client)) return false;
    if (GetClientTeam(client) != team) return false;
    if (IsClientImmune(client)) return false;

    return true;
}

static bool IsEligiblePlayerForce(int client, int team)
{
    if (client <= 0 || client > MaxClients) return false;
    if (!IsClientInGame(client) || IsFakeClient(client)) return false;
    if (GetClientTeam(client) != team) return false;

    return true;
}

static bool IsClientImmune(int client)
{
    float expiry = g_fImmunityExpiry[client];
    if (expiry <= 0.0) return false;

    if (GetGameTime() >= expiry)
    {
        g_fImmunityExpiry[client] = 0.0;   // Immunity has expired; clear it.
        return false;
    }

    return true;
}

static void SetClientImmunity(int client, bool immune)
{
    if (!IsClientInGame(client) || IsFakeClient(client)) return;

    g_fImmunityExpiry[client] = immune ? (GetGameTime() + IMMUNITY_DURATION) : 0.0;
}

static int CountTeamPlayersRaw(int team)
{
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i)) continue;
        if (GetClientTeam(i) != team) continue;
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
        case TEAM_RED:    strcopy(buffer, maxlen, "RED");
        case TEAM_BLUE:   strcopy(buffer, maxlen, "BLU");
        case TEAM_GREEN:  strcopy(buffer, maxlen, "GREEN");
        case TEAM_YELLOW: strcopy(buffer, maxlen, "YELLOW");
        default:          strcopy(buffer, maxlen, "UNKNOWN");
    }
}

static void AB_GetTeamColorName(int team, char[] buffer, int maxlen)
{
    switch (team)
    {
        case TEAM_RED:    strcopy(buffer, maxlen, "{red}Red");
        case TEAM_BLUE:   strcopy(buffer, maxlen, "{blue}Blue");
        case TEAM_GREEN:  strcopy(buffer, maxlen, "{green}Green");
        case TEAM_YELLOW: strcopy(buffer, maxlen, "{yellow}Yellow");
        default:          strcopy(buffer, maxlen, "{default}Unknown");
    }
}

static void LogBalance(const char[] fmt, any ...)
{
    if (g_hLogEnabled == null || !g_hLogEnabled.BoolValue)
    {
        return;
    }

    char buffer[512];
    VFormat(buffer, sizeof(buffer), fmt, 2);
    LogToFileEx(g_sLogPath, "%s", buffer);
}

static void ApplyServerBalanceCvars(bool pluginLoaded)
{
    if (g_hMpAutoteamBalance == null)
        g_hMpAutoteamBalance = FindConVar("mp_autoteambalance");

    if (g_hMpTeamsUnbalanceLimit == null)
        g_hMpTeamsUnbalanceLimit = FindConVar("mp_teams_unbalance_limit");

    if (pluginLoaded)
    {
        // Save originals before we overwrite them.
        if (g_hMpAutoteamBalance != null)
        {
            g_iSavedAutoteamBalance = g_hMpAutoteamBalance.IntValue;
            g_hMpAutoteamBalance.IntValue = 0;
        }

        if (g_hMpTeamsUnbalanceLimit != null)
        {
            g_iSavedUnbalanceLimit = g_hMpTeamsUnbalanceLimit.IntValue;
            g_hMpTeamsUnbalanceLimit.IntValue = 1;
        }
    }
    else
    {
        // Restore originals on unload.
        if (g_hMpAutoteamBalance != null)
            g_hMpAutoteamBalance.IntValue = g_iSavedAutoteamBalance;

        if (g_hMpTeamsUnbalanceLimit != null)
            g_hMpTeamsUnbalanceLimit.IntValue = g_iSavedUnbalanceLimit;
    }
}
