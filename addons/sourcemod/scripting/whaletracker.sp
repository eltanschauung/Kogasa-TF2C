#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <morecolors>

#define PLUGIN_VERSION "lite-2.2"
#define DB_CONFIG_DEFAULT "default"
#define SAVE_QUERY_MAXLEN 16384
#define STEAMID64_LEN 32
#define UPDATE_INTERVAL 10.0
#define CONNECT_DELAY 10.0
#define DEATHFLAG_DEADRINGER 32

public APLRes AskPluginLoad2(Handle self, bool late, char[] error, int err_max)
{
    RegPluginLibrary("whaletracker");
    CreateNative("WhaleTracker_GetCumulativeKills", Native_WhaleTracker_GetCumulativeKills);
    CreateNative("WhaleTracker_AreStatsLoaded", Native_WhaleTracker_AreStatsLoaded);
    return APLRes_Success;
}

public Plugin myinfo =
{
    name = "whaletracker",
    author = "Hombre",
    description = "Publishes online-now data only.",
    version = PLUGIN_VERSION,
    url = ""
};

Database g_hDatabase = null;
bool g_bDatabaseReady = false;
Handle g_hOnlineTimer = null;
Handle g_hConnectTimer = null;
bool g_bHasWhaleTrackerTable = true;

ConVar g_CvarDatabase = null;
ConVar g_CvarPublicIp = null;
ConVar g_CvarPublicPort = null;
ConVar g_hHostIpCvar = null;
ConVar g_hHostPortCvar = null;
ConVar g_hVisibleMaxPlayers = null;

char g_sHostIp[64];
char g_sPublicHostIp[64];
int g_iHostPort = 27015;
char g_sOnlineMapName[128];
int g_CumKills[MAXPLAYERS + 1];
int g_CumDeaths[MAXPLAYERS + 1];
int g_CumAssists[MAXPLAYERS + 1];
bool g_bTrackEligible[MAXPLAYERS + 1];
int g_iDamageGate[MAXPLAYERS + 1];
bool g_bCumLoadQueued[MAXPLAYERS + 1];
bool g_bCumLoaded[MAXPLAYERS + 1];

public void OnPluginStart()
{
    g_CvarDatabase = CreateConVar("sm_whaletracker_database", DB_CONFIG_DEFAULT, "Databases.cfg entry to use for WhaleTracker online now.");
    g_CvarPublicIp = CreateConVar("sm_whaletracker_public_ip", "", "Optional public IP override for WhaleTracker online now.");
    g_CvarPublicPort = CreateConVar("sm_whaletracker_public_port", "0", "Optional public port override for WhaleTracker online now.");

    g_hVisibleMaxPlayers = FindConVar("sv_visiblemaxplayers");

    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
    HookEvent("player_hurt", Event_PlayerHurt, EventHookMode_Post);
    ResetAllTotals();

    RegConsoleCmd("sm_stats", Command_ShowStats, "Show your WhaleTracker statistics.");
    RegConsoleCmd("sm_whalestats", Command_ShowStats, "Show your WhaleTracker statistics.");
}

public void OnMapStart()
{
    RefreshCurrentOnlineMapName();

    if (g_hConnectTimer != null && IsValidHandle(g_hConnectTimer))
    {
        CloseHandle(g_hConnectTimer);
    }
    g_hConnectTimer = CreateTimer(CONNECT_DELAY, Timer_ConnectAfterMapStart, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnMapEnd()
{
    if (g_hOnlineTimer != null && IsValidHandle(g_hOnlineTimer))
    {
        CloseHandle(g_hOnlineTimer);
    }
    g_hOnlineTimer = null;

    if (g_hDatabase != null)
    {
        delete g_hDatabase;
        g_hDatabase = null;
    }
    g_bDatabaseReady = false;
}

public void OnPluginEnd()
{
    if (g_hConnectTimer != null && IsValidHandle(g_hConnectTimer))
    {
        CloseHandle(g_hConnectTimer);
    }
    g_hConnectTimer = null;

    if (g_hOnlineTimer != null && IsValidHandle(g_hOnlineTimer))
    {
        CloseHandle(g_hOnlineTimer);
    }
    g_hOnlineTimer = null;

    if (g_hDatabase != null)
    {
        delete g_hDatabase;
        g_hDatabase = null;
    }
    g_bDatabaseReady = false;
}

public void OnClientPutInServer(int client)
{
    ResetClientTotals(client);
    if (g_bDatabaseReady)
    {
        LoadClientCumulativeStats(client);
    }
}

public void OnClientDisconnect(int client)
{
    ResetClientTotals(client);
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int assister = GetClientOfUserId(event.GetInt("assister"));
    int deathFlags = event.GetInt("death_flags");

    if (deathFlags & DEATHFLAG_DEADRINGER)
    {
        return;
    }

    if (IsTrackingEnabled(attacker) && attacker != victim)
    {
        g_CumKills[attacker]++;
    }

    if (IsTrackingEnabled(assister) && assister != victim)
    {
        g_CumAssists[assister]++;
    }

    if (IsTrackingEnabled(victim))
    {
        g_CumDeaths[victim]++;
    }
}

public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (attacker == victim)
    {
        return;
    }

    int damage = event.GetInt("damageamount");
    if (damage <= 0)
    {
        return;
    }

    CheckDamageGate(attacker, damage);
}

public Action Timer_ConnectAfterMapStart(Handle timer, any data)
{
    g_hConnectTimer = null;
    RefreshHostAddress();
    ConnectToDatabase();
    return Plugin_Stop;
}

static void ConnectToDatabase()
{
    if (g_hDatabase != null)
    {
        delete g_hDatabase;
        g_hDatabase = null;
    }
    g_bDatabaseReady = false;

    char configName[64];
    g_CvarDatabase.GetString(configName, sizeof(configName));

    if (!SQL_CheckConfig(configName))
    {
        LogError("[WhaleTracker] Database config '%s' not found.", configName);
        return;
    }

    SQL_TConnect(SQL_OnDatabaseConnected, configName);
}

public void SQL_OnDatabaseConnected(Handle owner, Handle hndl, const char[] error, any data)
{
    if (hndl == null)
    {
        LogError("[WhaleTracker] Database connection failed: %s", error[0] ? error : "unknown error");
        return;
    }

    g_hDatabase = view_as<Database>(hndl);
    g_bDatabaseReady = true;

    if (!g_hDatabase.SetCharset("utf8mb4"))
    {
        LogError("[WhaleTracker] Failed to set database charset to utf8mb4, names may be truncated.");
    }

    EnsureOnlineSchema();
    EnsureOnlineColumns();
    EnsureServersSchema();
    EnsureCumulativeSchema();

    if (g_hOnlineTimer == null)
    {
        g_hOnlineTimer = CreateTimer(UPDATE_INTERVAL, Timer_UpdateOnlineStats, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    }

    for (int client = 1; client <= MaxClients; client++)
    {
        if (IsClientInGame(client) && !IsFakeClient(client))
        {
            LoadClientCumulativeStats(client);
        }
    }

    char hostIp[64];
    GetPreferredHostIp(hostIp, sizeof(hostIp));
    LogMessage("[WhaleTracker] Online now active for %s:%d", hostIp, g_iHostPort);
}

static void EnsureOnlineSchema()
{
    if (!g_bDatabaseReady || g_hDatabase == null)
    {
        return;
    }

    char query[4096];
    Format(query, sizeof(query),
        "CREATE TABLE IF NOT EXISTS `whaletracker_online` ("
        ... "`steamid` VARCHAR(32) PRIMARY KEY,"
        ... "`personaname` VARCHAR(128) DEFAULT '',"
        ... "`class` TINYINT DEFAULT 0,"
        ... "`team` TINYINT DEFAULT 0,"
        ... "`alive` TINYINT DEFAULT 0,"
        ... "`is_spectator` TINYINT DEFAULT 0,"
        ... "`kills` INTEGER DEFAULT 0,"
        ... "`deaths` INTEGER DEFAULT 0,"
        ... "`assists` INTEGER DEFAULT 0,"
        ... "`damage` INTEGER DEFAULT 0,"
        ... "`damage_taken` INTEGER DEFAULT 0,"
        ... "`healing` INTEGER DEFAULT 0,"
        ... "`headshots` INTEGER DEFAULT 0,"
        ... "`backstabs` INTEGER DEFAULT 0,"
        ... "`shots` INTEGER DEFAULT 0,"
        ... "`hits` INTEGER DEFAULT 0,"
        ... "`playtime` INTEGER DEFAULT 0,"
        ... "`total_ubers` INTEGER DEFAULT 0,"
        ... "`classes_mask` INTEGER DEFAULT 0,"
        ... "`time_connected` INTEGER DEFAULT 0,"
        ... "`visible_max` INTEGER DEFAULT 0,"
        ... "`shots_shotguns` INTEGER DEFAULT 0,"
        ... "`hits_shotguns` INTEGER DEFAULT 0,"
        ... "`shots_scatterguns` INTEGER DEFAULT 0,"
        ... "`hits_scatterguns` INTEGER DEFAULT 0,"
        ... "`shots_pistols` INTEGER DEFAULT 0,"
        ... "`hits_pistols` INTEGER DEFAULT 0,"
        ... "`shots_rocketlaunchers` INTEGER DEFAULT 0,"
        ... "`hits_rocketlaunchers` INTEGER DEFAULT 0,"
        ... "`shots_grenadelaunchers` INTEGER DEFAULT 0,"
        ... "`hits_grenadelaunchers` INTEGER DEFAULT 0,"
        ... "`shots_stickylaunchers` INTEGER DEFAULT 0,"
        ... "`hits_stickylaunchers` INTEGER DEFAULT 0,"
        ... "`shots_snipers` INTEGER DEFAULT 0,"
        ... "`hits_snipers` INTEGER DEFAULT 0,"
        ... "`shots_revolvers` INTEGER DEFAULT 0,"
        ... "`hits_revolvers` INTEGER DEFAULT 0,"
        ... "`host_ip` VARCHAR(64) DEFAULT '',"
        ... "`host_port` INTEGER DEFAULT 0,"
        ... "`playercount` INTEGER DEFAULT 0,"
        ... "`map_name` VARCHAR(128) DEFAULT '',"
        ... "`last_update` INTEGER DEFAULT 0"
        ... ")");

    SQL_TQuery(g_hDatabase, SQL_GenericCallback, query);
}

static void EnsureOnlineColumns()
{
    if (!g_bDatabaseReady || g_hDatabase == null)
    {
        return;
    }

    static const char columnQueries[][] =
    {
        "ALTER TABLE `whaletracker_online` ADD COLUMN `weapon1_name` VARCHAR(64) DEFAULT ''",
        "ALTER TABLE `whaletracker_online` ADD COLUMN `weapon1_accuracy` FLOAT DEFAULT 0",
        "ALTER TABLE `whaletracker_online` ADD COLUMN `weapon1_shots` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker_online` ADD COLUMN `weapon1_hits` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker_online` ADD COLUMN `weapon2_name` VARCHAR(64) DEFAULT ''",
        "ALTER TABLE `whaletracker_online` ADD COLUMN `weapon2_accuracy` FLOAT DEFAULT 0",
        "ALTER TABLE `whaletracker_online` ADD COLUMN `weapon2_shots` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker_online` ADD COLUMN `weapon2_hits` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker_online` ADD COLUMN `weapon3_name` VARCHAR(64) DEFAULT ''",
        "ALTER TABLE `whaletracker_online` ADD COLUMN `weapon3_accuracy` FLOAT DEFAULT 0",
        "ALTER TABLE `whaletracker_online` ADD COLUMN `weapon3_shots` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker_online` ADD COLUMN `weapon3_hits` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker_online` ADD COLUMN `shots_scout` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker_online` ADD COLUMN `hits_scout` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker_online` ADD COLUMN `shots_sniper` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker_online` ADD COLUMN `hits_sniper` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker_online` ADD COLUMN `shots_soldier` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker_online` ADD COLUMN `hits_soldier` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker_online` ADD COLUMN `shots_demoman` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker_online` ADD COLUMN `hits_demoman` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker_online` ADD COLUMN `shots_medic` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker_online` ADD COLUMN `hits_medic` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker_online` ADD COLUMN `shots_heavy` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker_online` ADD COLUMN `hits_heavy` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker_online` ADD COLUMN `shots_pyro` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker_online` ADD COLUMN `hits_pyro` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker_online` ADD COLUMN `shots_spy` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker_online` ADD COLUMN `hits_spy` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker_online` ADD COLUMN `shots_engineer` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker_online` ADD COLUMN `hits_engineer` INTEGER DEFAULT 0"
    };

    for (int i = 0; i < sizeof(columnQueries); i++)
    {
        SQL_TQuery(g_hDatabase, SQL_SchemaCallback, columnQueries[i]);
    }
}

static void EnsureServersSchema()
{
    if (!g_bDatabaseReady || g_hDatabase == null)
    {
        return;
    }

    char query[512];
    Format(query, sizeof(query),
        "CREATE TABLE IF NOT EXISTS `whaletracker_servers` ("
        ... "`ip` VARCHAR(64) NOT NULL,"
        ... "`port` INTEGER NOT NULL,"
        ... "`playercount` INTEGER DEFAULT 0,"
        ... "`visible_max` INTEGER DEFAULT 0,"
        ... "`map` VARCHAR(128) DEFAULT '',"
        ... "`city` VARCHAR(128) DEFAULT '',"
        ... "`country` VARCHAR(8) DEFAULT '',"
        ... "`flags` VARCHAR(256) DEFAULT '',"
        ... "`last_update` INTEGER DEFAULT 0,"
        ... "PRIMARY KEY (`ip`, `port`)"
        ... ")");

    SQL_TQuery(g_hDatabase, SQL_GenericCallback, query);
}

static void EnsureCumulativeSchema()
{
    if (!g_bDatabaseReady || g_hDatabase == null)
    {
        return;
    }

    g_bHasWhaleTrackerTable = true;

    char query[4096];
    Format(query, sizeof(query),
        "CREATE TABLE IF NOT EXISTS `whaletracker` ("
        ... "`steamid` VARCHAR(32) PRIMARY KEY,"
        ... "`first_seen` INTEGER DEFAULT 0,"
        ... "`kills` INTEGER DEFAULT 0,"
        ... "`deaths` INTEGER DEFAULT 0,"
        ... "`healing` INTEGER DEFAULT 0,"
        ... "`total_ubers` INTEGER DEFAULT 0,"
        ... "`medic_drops` INTEGER DEFAULT 0,"
        ... "`uber_drops` INTEGER DEFAULT 0,"
        ... "`airshots` INTEGER DEFAULT 0,"
        ... "`headshots` INTEGER DEFAULT 0,"
        ... "`backstabs` INTEGER DEFAULT 0,"
        ... "`assists` INTEGER DEFAULT 0,"
        ... "`playtime` INTEGER DEFAULT 0,"
        ... "`damage_dealt` INTEGER DEFAULT 0,"
        ... "`damage_taken` INTEGER DEFAULT 0,"
        ... "`shots_scatterguns` INTEGER DEFAULT 0,"
        ... "`hits_scatterguns` INTEGER DEFAULT 0,"
        ... "`shots_pistols` INTEGER DEFAULT 0,"
        ... "`hits_pistols` INTEGER DEFAULT 0,"
        ... "`shots_rocketlaunchers` INTEGER DEFAULT 0,"
        ... "`hits_rocketlaunchers` INTEGER DEFAULT 0,"
        ... "`shots_grenadelaunchers` INTEGER DEFAULT 0,"
        ... "`hits_grenadelaunchers` INTEGER DEFAULT 0,"
        ... "`shots_stickylaunchers` INTEGER DEFAULT 0,"
        ... "`hits_stickylaunchers` INTEGER DEFAULT 0,"
        ... "`shots_snipers` INTEGER DEFAULT 0,"
        ... "`hits_snipers` INTEGER DEFAULT 0,"
        ... "`shots_revolvers` INTEGER DEFAULT 0,"
        ... "`hits_revolvers` INTEGER DEFAULT 0,"
        ... "`favorite_class` TINYINT DEFAULT 0,"
        ... "`last_seen` INTEGER DEFAULT 0,"
        ... "`personaname` VARCHAR(128) DEFAULT '',"
        ... "`cached_personaname` VARCHAR(255) DEFAULT NULL,"
        ... "`cached_personaname_lower` VARCHAR(255) DEFAULT NULL"
        ... ")");
    SQL_TQuery(g_hDatabase, SQL_GenericCallback, query);
    EnsureWhaleTrackerColumns();
}

static void EnsureWhaleTrackerColumns()
{
    if (!g_bDatabaseReady || g_hDatabase == null)
    {
        return;
    }

    static const char columnQueries[][] =
    {
        "ALTER TABLE `whaletracker` ADD COLUMN `playtime` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker` ADD COLUMN `healing` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker` ADD COLUMN `headshots` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker` ADD COLUMN `backstabs` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker` ADD COLUMN `damage_dealt` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker` ADD COLUMN `damage_taken` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker` ADD COLUMN `medic_drops` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker` ADD COLUMN `uber_drops` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker` ADD COLUMN `airshots` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker` ADD COLUMN `total_ubers` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker` ADD COLUMN `first_seen` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker` ADD COLUMN `last_seen` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker` ADD COLUMN `personaname` VARCHAR(128) DEFAULT ''",
        "ALTER TABLE `whaletracker` ADD COLUMN `cached_personaname` VARCHAR(255) DEFAULT NULL",
        "ALTER TABLE `whaletracker` ADD COLUMN `cached_personaname_lower` VARCHAR(255) DEFAULT NULL",
        "ALTER TABLE `whaletracker` ADD COLUMN `shots_scatterguns` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker` ADD COLUMN `hits_scatterguns` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker` ADD COLUMN `shots_pistols` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker` ADD COLUMN `hits_pistols` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker` ADD COLUMN `shots_rocketlaunchers` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker` ADD COLUMN `hits_rocketlaunchers` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker` ADD COLUMN `shots_grenadelaunchers` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker` ADD COLUMN `hits_grenadelaunchers` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker` ADD COLUMN `shots_stickylaunchers` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker` ADD COLUMN `hits_stickylaunchers` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker` ADD COLUMN `shots_snipers` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker` ADD COLUMN `hits_snipers` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker` ADD COLUMN `shots_revolvers` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker` ADD COLUMN `hits_revolvers` INTEGER DEFAULT 0",
        "ALTER TABLE `whaletracker` ADD COLUMN `favorite_class` TINYINT DEFAULT 0"
    };

    for (int i = 0; i < sizeof(columnQueries); i++)
    {
        SQL_TQuery(g_hDatabase, SQL_SchemaCallback, columnQueries[i]);
    }
}


public Action Timer_UpdateOnlineStats(Handle timer, any data)
{
    if (!g_bDatabaseReady || g_hDatabase == null)
    {
        return Plugin_Continue;
    }

    int now = GetTime();
    int playerCount = GetClientCount(true);

    int visibleMax = MaxClients;
    if (g_hVisibleMaxPlayers != null)
    {
        int conVarValue = g_hVisibleMaxPlayers.IntValue;
        if (conVarValue > 0 && visibleMax > conVarValue)
        {
            visibleMax = conVarValue;
        }
    }

    char mapName[128];
    if (g_sOnlineMapName[0])
    {
        strcopy(mapName, sizeof(mapName), g_sOnlineMapName);
    }
    else
    {
        strcopy(mapName, sizeof(mapName), "unknown");
    }

    char escapedMapName[256];
    SQL_EscapeString(g_hDatabase, mapName, escapedMapName, sizeof(escapedMapName));

    char hostIp[64];
    GetPreferredHostIp(hostIp, sizeof(hostIp));

    char escapedHostIp[64];
    SQL_EscapeString(g_hDatabase, hostIp, escapedHostIp, sizeof(escapedHostIp));

    char steamId[STEAMID64_LEN];
    char name[MAX_NAME_LENGTH];
    char escapedName[MAX_NAME_LENGTH * 2];
    char query[SAVE_QUERY_MAXLEN];
    char cumQuery[SAVE_QUERY_MAXLEN];
    static const char updateClause[] =
        " ON DUPLICATE KEY UPDATE "
        ... "personaname=VALUES(personaname),"
        ... "class=VALUES(class),"
        ... "team=VALUES(team),"
        ... "alive=VALUES(alive),"
        ... "is_spectator=VALUES(is_spectator),"
        ... "kills=GREATEST(kills, VALUES(kills)),"
        ... "deaths=GREATEST(deaths, VALUES(deaths)),"
        ... "assists=GREATEST(assists, VALUES(assists)),"
        ... "damage=VALUES(damage),"
        ... "damage_taken=VALUES(damage_taken),"
        ... "healing=VALUES(healing),"
        ... "headshots=VALUES(headshots),"
        ... "backstabs=VALUES(backstabs),"
        ... "shots=VALUES(shots),"
        ... "hits=VALUES(hits),"
        ... "playtime=VALUES(playtime),"
        ... "total_ubers=VALUES(total_ubers),"
        ... "classes_mask=VALUES(classes_mask),"
        ... "time_connected=VALUES(time_connected),"
        ... "visible_max=VALUES(visible_max),"
        ... "shots_shotguns=VALUES(shots_shotguns),"
        ... "hits_shotguns=VALUES(hits_shotguns),"
        ... "shots_scatterguns=VALUES(shots_scatterguns),"
        ... "hits_scatterguns=VALUES(hits_scatterguns),"
        ... "shots_pistols=VALUES(shots_pistols),"
        ... "hits_pistols=VALUES(hits_pistols),"
        ... "shots_rocketlaunchers=VALUES(shots_rocketlaunchers),"
        ... "hits_rocketlaunchers=VALUES(hits_rocketlaunchers),"
        ... "shots_grenadelaunchers=VALUES(shots_grenadelaunchers),"
        ... "hits_grenadelaunchers=VALUES(hits_grenadelaunchers),"
        ... "shots_stickylaunchers=VALUES(shots_stickylaunchers),"
        ... "hits_stickylaunchers=VALUES(hits_stickylaunchers),"
        ... "shots_snipers=VALUES(shots_snipers),"
        ... "hits_snipers=VALUES(hits_snipers),"
        ... "shots_revolvers=VALUES(shots_revolvers),"
        ... "hits_revolvers=VALUES(hits_revolvers),"
        ... "host_ip=VALUES(host_ip),"
        ... "host_port=VALUES(host_port),"
        ... "playercount=VALUES(playercount),"
        ... "map_name=VALUES(map_name),"
        ... "last_update=VALUES(last_update)";
    int updateLen = strlen(updateClause);

    static const char cumUpdateClause[] =
        " ON DUPLICATE KEY UPDATE "
        ... "kills=GREATEST(kills, VALUES(kills)),"
        ... "deaths=GREATEST(deaths, VALUES(deaths)),"
        ... "assists=GREATEST(assists, VALUES(assists)),"
        ... "playtime=GREATEST(playtime, VALUES(playtime)),"
        ... "damage_dealt=GREATEST(damage_dealt, VALUES(damage_dealt)),"
        ... "damage_taken=GREATEST(damage_taken, VALUES(damage_taken)),"
        ... "healing=GREATEST(healing, VALUES(healing)),"
        ... "headshots=GREATEST(headshots, VALUES(headshots)),"
        ... "backstabs=GREATEST(backstabs, VALUES(backstabs)),"
        ... "medic_drops=GREATEST(medic_drops, VALUES(medic_drops)),"
        ... "total_ubers=GREATEST(total_ubers, VALUES(total_ubers)),"
        ... "last_seen=VALUES(last_seen),"
        ... "personaname=VALUES(personaname),"
        ... "cached_personaname=VALUES(cached_personaname),"
        ... "cached_personaname_lower=VALUES(cached_personaname_lower),"
        ... "first_seen=IF(first_seen=0 OR first_seen IS NULL, VALUES(first_seen), first_seen)";
    int cumUpdateLen = strlen(cumUpdateClause);

    int rowCount = 0;
    int pos = Format(query, sizeof(query),
        "INSERT INTO whaletracker_online "
        ... "(steamid, personaname, class, team, alive, is_spectator, kills, deaths, assists, damage, damage_taken, healing, headshots, backstabs, shots, hits, playtime, total_ubers, classes_mask, time_connected, visible_max, "
        ... "shots_shotguns, hits_shotguns, shots_scatterguns, hits_scatterguns, shots_pistols, hits_pistols, shots_rocketlaunchers, hits_rocketlaunchers, shots_grenadelaunchers, hits_grenadelaunchers, shots_stickylaunchers, hits_stickylaunchers, shots_snipers, hits_snipers, shots_revolvers, hits_revolvers, host_ip, host_port, playercount, map_name, last_update) VALUES ");

    int cumRowCount = 0;
    int cumPos = 0;
    if (g_bHasWhaleTrackerTable)
    {
        cumPos = Format(cumQuery, sizeof(cumQuery),
            "INSERT INTO whaletracker "
            ... "(steamid, first_seen, last_seen, personaname, cached_personaname, cached_personaname_lower, "
            ... "kills, deaths, assists, playtime, damage_dealt, damage_taken, healing, headshots, backstabs, "
            ... "medic_drops, total_ubers) VALUES ");
    }

    char row[1024];
    char cumRow[512];
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
        {
            continue;
        }

        if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId)))
        {
            continue;
        }

        if (g_bHasWhaleTrackerTable && !g_bCumLoaded[client] && !g_bCumLoadQueued[client])
        {
            LoadClientCumulativeStats(client);
        }

        GetClientName(client, name, sizeof(name));
        SQL_EscapeString(g_hDatabase, name, escapedName, sizeof(escapedName));

        int classId = GetClientClassId(client);
        int team = GetClientTeam(client);
        bool alive = IsPlayerAlive(client);
        bool spectator = (team != 2 && team != 3) || classId == 0;

        int kills = g_CumKills[client];
        int deaths = g_CumDeaths[client];
        int assists = g_CumAssists[client];
        int damage = GetEntPropIntSafe(client, "m_iDamageDone");
        int damageTaken = GetEntPropIntSafe(client, "m_iDamageTaken");
        int healing = GetEntPropIntSafe(client, "m_iHealPoints");

        int timeConnected = RoundToFloor(GetClientTime(client));
        int playtime = timeConnected;
        Format(row, sizeof(row),
            "%s('%s','%s',%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,0,0,0,0,%d,0,0,%d,%d,"
            ... "0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,'%s',%d,%d,'%s',%d)",
            (rowCount > 0) ? "," : "",
            steamId,
            escapedName,
            classId,
            team,
            alive ? 1 : 0,
            spectator ? 1 : 0,
            kills,
            deaths,
            assists,
            damage,
            damageTaken,
            healing,
            playtime,
            timeConnected,
            visibleMax,
            escapedHostIp,
            g_iHostPort,
            playerCount,
            escapedMapName,
            now);

        int rowLen = strlen(row);
        if (pos + rowLen + 1 + updateLen >= sizeof(query))
        {
            StrCat(query, sizeof(query), updateClause);
            SQL_TQuery(g_hDatabase, SQL_GenericCallback, query);
            pos = Format(query, sizeof(query),
                "INSERT INTO whaletracker_online "
                ... "(steamid, personaname, class, team, alive, is_spectator, kills, deaths, assists, damage, damage_taken, healing, headshots, backstabs, shots, hits, playtime, total_ubers, classes_mask, time_connected, visible_max, "
                ... "shots_shotguns, hits_shotguns, shots_scatterguns, hits_scatterguns, shots_pistols, hits_pistols, shots_rocketlaunchers, hits_rocketlaunchers, shots_grenadelaunchers, hits_grenadelaunchers, shots_stickylaunchers, hits_stickylaunchers, shots_snipers, hits_snipers, shots_revolvers, hits_revolvers, host_ip, host_port, playercount, map_name, last_update) VALUES ");
            rowCount = 0;
            Format(row, sizeof(row),
                "('%s','%s',%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,0,0,0,0,%d,0,0,%d,%d,"
                ... "0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,'%s',%d,%d,'%s',%d)",
                steamId,
                escapedName,
                classId,
                team,
                alive ? 1 : 0,
                spectator ? 1 : 0,
                kills,
                deaths,
                assists,
                damage,
                damageTaken,
                healing,
                playtime,
                timeConnected,
                visibleMax,
                escapedHostIp,
                g_iHostPort,
                playerCount,
                escapedMapName,
                now);
            rowLen = strlen(row);
        }

        StrCat(query, sizeof(query), row);
        pos += rowLen;
        rowCount++;

        if (g_bHasWhaleTrackerTable && g_bCumLoaded[client])
        {
            int headshots = 0;
            int backstabs = 0;
            int medicDrops = 0;
            int totalUbers = 0;

            Format(cumRow, sizeof(cumRow),
                "%s('%s',%d,%d,'%s','%s','%s',%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d)",
                (cumRowCount > 0) ? "," : "",
                steamId,
                now,
                now,
                escapedName,
                escapedName,
                escapedName,
                kills,
                deaths,
                assists,
                playtime,
                damage,
                damageTaken,
                healing,
                headshots,
                backstabs,
                medicDrops,
                totalUbers);

            int cumRowLen = strlen(cumRow);
            if (cumPos + cumRowLen + 1 + cumUpdateLen >= sizeof(cumQuery))
            {
                StrCat(cumQuery, sizeof(cumQuery), cumUpdateClause);
                SQL_TQuery(g_hDatabase, SQL_GenericCallback, cumQuery);
                cumPos = Format(cumQuery, sizeof(cumQuery),
                    "INSERT INTO whaletracker "
                    ... "(steamid, first_seen, last_seen, personaname, cached_personaname, cached_personaname_lower, "
                    ... "kills, deaths, assists, playtime, damage_dealt, damage_taken, healing, headshots, backstabs, "
                    ... "medic_drops, total_ubers) VALUES ");
                cumRowCount = 0;
                Format(cumRow, sizeof(cumRow),
                    "('%s',%d,%d,'%s','%s','%s',%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d)",
                    steamId,
                    now,
                    now,
                    escapedName,
                    escapedName,
                    escapedName,
                    kills,
                    deaths,
                    assists,
                    playtime,
                    damage,
                    damageTaken,
                    healing,
                    headshots,
                    backstabs,
                    medicDrops,
                    totalUbers);
                cumRowLen = strlen(cumRow);
            }

            StrCat(cumQuery, sizeof(cumQuery), cumRow);
            cumPos += cumRowLen;
            cumRowCount++;
        }

    }

    if (rowCount > 0)
    {
        StrCat(query, sizeof(query), updateClause);
        SQL_TQuery(g_hDatabase, SQL_GenericCallback, query);
    }

    if (g_bHasWhaleTrackerTable && cumRowCount > 0)
    {
        StrCat(cumQuery, sizeof(cumQuery), cumUpdateClause);
        SQL_TQuery(g_hDatabase, SQL_GenericCallback, cumQuery);
    }

    Format(query, sizeof(query), "DELETE FROM whaletracker_online WHERE last_update < %d", now - 20);
    SQL_TQuery(g_hDatabase, SQL_GenericCallback, query);

    char serverQuery[512];
    Format(serverQuery, sizeof(serverQuery),
        "REPLACE INTO whaletracker_servers (ip, port, playercount, visible_max, map, city, country, flags, last_update) "
        ... "VALUES ('%s', %d, %d, %d, '%s', '', '', '', %d)",
        escapedHostIp,
        g_iHostPort,
        playerCount,
        visibleMax,
        escapedMapName,
        now);
    SQL_TQuery(g_hDatabase, SQL_GenericCallback, serverQuery);

    return Plugin_Continue;
}

static int GetEntPropIntSafe(int entity, const char[] prop)
{
    if (!HasEntProp(entity, Prop_Send, prop))
    {
        return 0;
    }

    return GetEntProp(entity, Prop_Send, prop);
}

static int GetClientClassId(int client)
{
    if (!IsClientInGame(client))
    {
        return 0;
    }

    if (!HasEntProp(client, Prop_Send, "m_iClass"))
    {
        return 0;
    }

    int classId = GetEntProp(client, Prop_Send, "m_iClass");
    if (classId < 0 || classId > 10)
    {
        return 0;
    }
    return classId;
}

static bool IsRealClient(int client)
{
    return client > 0
        && client <= MaxClients
        && IsClientInGame(client)
        && !IsFakeClient(client);
}

static bool IsValidTrackedClient(int client)
{
    return client > 0
        && client <= MaxClients
        && IsClientInGame(client)
        && !IsFakeClient(client)
        && GetClientTeam(client) > 1;
}

static bool IsTrackingEnabled(int client)
{
    return IsValidTrackedClient(client) && g_bTrackEligible[client];
}

static void CheckDamageGate(int client, int damage)
{
    if (!IsValidTrackedClient(client) || g_bTrackEligible[client])
    {
        return;
    }

    g_iDamageGate[client] += damage;
    if (g_iDamageGate[client] >= 200)
    {
        g_bTrackEligible[client] = true;
    }
}

static void ResetClientTotals(int client)
{
    if (client <= 0 || client > MaxClients)
    {
        return;
    }

    g_CumKills[client] = 0;
    g_CumDeaths[client] = 0;
    g_CumAssists[client] = 0;
    g_bTrackEligible[client] = false;
    g_iDamageGate[client] = 0;
    g_bCumLoadQueued[client] = false;
    g_bCumLoaded[client] = false;
}

static void ResetAllTotals()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        g_CumKills[i] = 0;
        g_CumDeaths[i] = 0;
        g_CumAssists[i] = 0;
        g_bTrackEligible[i] = false;
        g_iDamageGate[i] = 0;
        g_bCumLoadQueued[i] = false;
        g_bCumLoaded[i] = false;
    }
}


static void LoadClientCumulativeStats(int client)
{
    if (!g_bDatabaseReady || g_hDatabase == null || !g_bHasWhaleTrackerTable)
    {
        return;
    }

    if (!IsRealClient(client) || g_bCumLoadQueued[client])
    {
        return;
    }

    char steamId[STEAMID64_LEN];
    if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId)))
    {
        return;
    }

    char escapedSteamId[STEAMID64_LEN * 2];
    SQL_EscapeString(g_hDatabase, steamId, escapedSteamId, sizeof(escapedSteamId));

    char query[256];
    Format(query, sizeof(query),
        "SELECT kills, deaths, assists FROM whaletracker WHERE steamid = '%s' LIMIT 1",
        escapedSteamId);

    g_bCumLoadQueued[client] = true;
    SQL_TQuery(g_hDatabase, SQL_OnLoadCumulativeStats, query, GetClientUserId(client));
}

public void SQL_OnLoadCumulativeStats(Handle owner, Handle hndl, const char[] error, any data)
{
    int client = GetClientOfUserId(data);
    if (client > 0 && client <= MaxClients)
    {
        g_bCumLoadQueued[client] = false;
    }

    if (error[0])
    {
        if (StrContains(error, "doesn't exist", false) != -1 || StrContains(error, "no such table", false) != -1)
        {
            g_bHasWhaleTrackerTable = true;
            EnsureCumulativeSchema();
            return;
        }
        LogError("[WhaleTracker] Failed to load cumulative stats: %s", error);
        return;
    }

    if (hndl == null || client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        return;
    }

    DBResultSet results = view_as<DBResultSet>(hndl);
    if (!results.FetchRow())
    {
        g_bCumLoaded[client] = true;
        return;
    }

    int kills = results.FetchInt(0);
    int deaths = results.FetchInt(1);
    int assists = results.FetchInt(2);

    if (kills > g_CumKills[client])
    {
        g_CumKills[client] = kills;
    }
    if (deaths > g_CumDeaths[client])
    {
        g_CumDeaths[client] = deaths;
    }
    if (assists > g_CumAssists[client])
    {
        g_CumAssists[client] = assists;
    }

    g_bCumLoaded[client] = true;
}

static void RefreshHostAddress()
{
    char overrideIp[64];
    g_CvarPublicIp.GetString(overrideIp, sizeof(overrideIp));

    if (overrideIp[0])
    {
        strcopy(g_sPublicHostIp, sizeof(g_sPublicHostIp), overrideIp);
    }
    else
    {
        if (g_hHostIpCvar == null)
        {
            g_hHostIpCvar = FindConVar("ip");
            if (g_hHostIpCvar == null)
            {
                g_hHostIpCvar = FindConVar("hostip");
            }
        }

        if (g_hHostIpCvar != null)
        {
            g_hHostIpCvar.GetString(g_sHostIp, sizeof(g_sHostIp));
        }
        else
        {
            g_sHostIp[0] = '\0';
        }

        if (!g_sHostIp[0])
        {
            strcopy(g_sHostIp, sizeof(g_sHostIp), "0.0.0.0");
        }

        strcopy(g_sPublicHostIp, sizeof(g_sPublicHostIp), g_sHostIp);
    }

    if (g_hHostPortCvar == null)
    {
        g_hHostPortCvar = FindConVar("hostport");
    }
    g_iHostPort = (g_hHostPortCvar != null) ? g_hHostPortCvar.IntValue : 27015;

    int overridePort = g_CvarPublicPort.IntValue;
    if (overridePort > 0)
    {
        g_iHostPort = overridePort;
    }
}

static void GetPreferredHostIp(char[] buffer, int maxlen)
{
    if (g_sPublicHostIp[0])
    {
        strcopy(buffer, maxlen, g_sPublicHostIp);
    }
    else
    {
        strcopy(buffer, maxlen, g_sHostIp[0] ? g_sHostIp : "0.0.0.0");
    }
}

static void RefreshCurrentOnlineMapName()
{
    g_sOnlineMapName[0] = '\0';

    char rawName[128];
    GetCurrentMap(rawName, sizeof(rawName));
    if (!rawName[0])
    {
        strcopy(g_sOnlineMapName, sizeof(g_sOnlineMapName), "unknown");
        return;
    }

    ReplaceStringEx(rawName, sizeof(rawName), "workshop/", "");
    SplitString(rawName, ".", rawName, sizeof(rawName));
    strcopy(g_sOnlineMapName, sizeof(g_sOnlineMapName), rawName[0] ? rawName : "unknown");
}


public void SQL_GenericCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (error[0])
    {
        LogError("[WhaleTracker] SQL error: %s", error);
    }
}

public void SQL_SchemaCallback(Database db, DBResultSet results, const char[] error, any data)
{
    if (!error[0])
    {
        return;
    }

    if (StrContains(error, "Duplicate column name", false) != -1
        || StrContains(error, "already exists", false) != -1)
    {
        return;
    }

    LogError("[WhaleTracker] SQL schema error: %s", error);
}

public Action Command_ShowStats(int client, int args)
{
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
    {
        return Plugin_Handled;
    }

    int target = client;
    if (args >= 1)
    {
        char targetArg[64];
        GetCmdArgString(targetArg, sizeof(targetArg));
        TrimString(targetArg);
        if (targetArg[0])
        {
            int candidate = FindTarget(client, targetArg, true, false);
            if (candidate > 0 && IsClientInGame(candidate) && !IsFakeClient(candidate))
            {
                target = candidate;
            }
            else
            {
                CPrintToChat(client, "{green}[WhaleTracker]{default} Could not find player '%s'.", targetArg);
                return Plugin_Handled;
            }
        }
    }

    if (!g_bDatabaseReady || g_hDatabase == null)
    {
        CPrintToChat(client, "{green}[WhaleTracker]{default} Stats database is not available yet.");
        return Plugin_Handled;
    }

    char steamId[STEAMID64_LEN];
    if (!GetClientAuthId(target, AuthId_SteamID64, steamId, sizeof(steamId)))
    {
        CPrintToChat(client, "{green}[WhaleTracker]{default} Unable to read SteamID.");
        return Plugin_Handled;
    }

    char escapedSteamId[STEAMID64_LEN * 2];
    SQL_EscapeString(g_hDatabase, steamId, escapedSteamId, sizeof(escapedSteamId));

    char query[512];
    Format(query, sizeof(query),
        "SELECT "
        ... "o.kills, o.deaths, o.assists "
        ... "FROM whaletracker_online o "
        ... "WHERE o.steamid = '%s' LIMIT 1",
        escapedSteamId);

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(GetClientUserId(target));
    SQL_TQuery(g_hDatabase, SQL_OnStatsQuery, query, pack);
    return Plugin_Handled;
}

public void SQL_OnStatsQuery(Handle owner, Handle hndl, const char[] error, any data)
{
    DataPack pack = view_as<DataPack>(data);
    pack.Reset();
    int viewer = GetClientOfUserId(pack.ReadCell());
    int target = GetClientOfUserId(pack.ReadCell());
    delete pack;

    if (viewer <= 0 || !IsClientInGame(viewer))
    {
        return;
    }

    if (error[0])
    {
        CPrintToChat(viewer, "{green}[WhaleTracker]{default} Stats query failed: %s", error);
        return;
    }

    if (hndl == null)
    {
        CPrintToChat(viewer, "{green}[WhaleTracker]{default} Stats not available.");
        return;
    }

    DBResultSet results = view_as<DBResultSet>(hndl);
    if (!results.FetchRow())
    {
        CPrintToChat(viewer, "{green}[WhaleTracker]{default} No stats found.");
        return;
    }

    int kills = results.FetchInt(0);
    int deaths = results.FetchInt(1);
    int assists = results.FetchInt(2);

    char name[MAX_NAME_LENGTH];
    if (target > 0 && IsClientInGame(target))
    {
        GetClientName(target, name, sizeof(name));
    }
    else
    {
        strcopy(name, sizeof(name), "Player");
    }

    CPrintToChat(viewer, "{green}[WhaleTracker]{default} {lightgreen}%s", name);
    CPrintToChat(viewer, "{yellow}Kills:{default} %d {yellow}Deaths:{default} %d", kills, deaths);
    CPrintToChat(viewer, "{yellow}Assists:{default} %d", assists);
    CPrintToChat(viewer, "{green}[WhaleTracker]{default} Visit kogasa.tf/stats to see a full webpage for server stats and more!");
}

public any Native_WhaleTracker_GetCumulativeKills(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    if (client <= 0 || client > MaxClients)
    {
        return 0;
    }
    return g_CumKills[client];
}

public any Native_WhaleTracker_AreStatsLoaded(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    return (client > 0 && client <= MaxClients && g_bCumLoaded[client]);
}
