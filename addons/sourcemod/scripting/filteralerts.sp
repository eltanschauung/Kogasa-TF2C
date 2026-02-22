#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <morecolors>

native int Filters_GetChatName(int client, char[] buffer, int maxlen);

ConVar g_cvarEnabled;
ConVar g_cvarVoice;
ConVar g_cvarDisconnect;
ConVar g_cvarTeam;
ConVar g_cvarCvar;
Database g_hDb = null;
bool g_bDbReady = false;
bool g_bSuppressNextTeamAlert[MAXPLAYERS + 1];
float g_fSuppressTeamAlertsUntil = 0.0;

public APLRes AskPluginLoad2(Handle plugin, bool late, char[] error, int err_max)
{
	MarkNativeAsOptional("Filters_GetChatName");
	return APLRes_Success;
}

void FilterAlerts_SQLConnect()
{
	if (g_hDb != null)
	{
		delete g_hDb;
		g_hDb = null;
		g_bDbReady = false;
	}

	Database.Connect(FilterAlerts_OnSqlConnect, "default");
}

public void FilterAlerts_OnSqlConnect(Database db, const char[] error, any data)
{
	if (db == null)
	{
		LogError("[filteralerts] DB connection failed: %s", error);
		g_bDbReady = false;
		return;
	}

	g_hDb = db;
	g_bDbReady = true;
}

static void BuildTeamJoinText(int team, char[] buffer, int maxlen)
{
	switch (team)
	{
		case 1: Format(buffer, maxlen, "entered {lightsteelblue}Keine's Class");
		case 2: Format(buffer, maxlen, "joined team {red}Fujiwara");
		case 3: Format(buffer, maxlen, "joined team {blue}Houraisan");
		case 4: Format(buffer, maxlen, "joined team {green}Konpaku");
		case 5: Format(buffer, maxlen, "joined team {yellow}Kirisame");
		default: buffer[0] = '\0';
	}
}

static void BuildFallbackNameColorTag(int team, char[] buffer, int maxlen)
{
	switch (team)
	{
		case 1: strcopy(buffer, maxlen, "{lightsteelblue}");
		case 2: strcopy(buffer, maxlen, "{red}");
		case 3: strcopy(buffer, maxlen, "{blue}");
		case 4: strcopy(buffer, maxlen, "{green}");
		case 5: strcopy(buffer, maxlen, "{yellow}");
		default: strcopy(buffer, maxlen, "{default}");
	}
}

static void PrintTeamJoinAlert(int client, int team, const char[] dbColor, const char[] dbPrename)
{
	if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
	{
		return;
	}

	char teamText[64];
	BuildTeamJoinText(team, teamText, sizeof(teamText));
	if (!teamText[0])
	{
		return;
	}

	char nameText[MAX_NAME_LENGTH];
	if (dbPrename[0] != '\0')
	{
		strcopy(nameText, sizeof(nameText), dbPrename);
	}
	else
	{
		GetClientName(client, nameText, sizeof(nameText));
	}

	char nameColor[32];
	if (dbColor[0] != '\0' && CColorExists(dbColor))
	{
		Format(nameColor, sizeof(nameColor), "{%s}", dbColor);
	}
	else
	{
		BuildFallbackNameColorTag(team, nameColor, sizeof(nameColor));
	}

	char coloredName[192];
	coloredName[0] = '\0';
	if (GetFeatureStatus(FeatureType_Native, "Filters_GetChatName") == FeatureStatus_Available
		&& Filters_GetChatName(client, coloredName, sizeof(coloredName)) && coloredName[0] != '\0')
	{
		char outputNative[320];
		Format(outputNative, sizeof(outputNative), "%s %s", coloredName, teamText);
		CPrintToChatAllEx(client, "%s", outputNative);
		return;
	}

	char output[256];
	Format(output, sizeof(output), "%s%s{default} %s", nameColor, nameText, teamText);
	CPrintToChatAllEx(client, "%s", output);
}

public void FilterAlerts_TeamColorCallback(Database db, DBResultSet results, const char[] error, any data)
{
	DataPack pack = view_as<DataPack>(data);
	pack.Reset();
	int userId = pack.ReadCell();
	int team = pack.ReadCell();
	delete pack;

	int client = GetClientOfUserId(userId);
	if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
	{
		return;
	}

	char color[32];
	color[0] = '\0';
	char prename[64];
	prename[0] = '\0';

	if (error[0] != '\0')
	{
		LogError("[filteralerts] Team color query failed: %s", error);
		PrintTeamJoinAlert(client, team, color, prename);
		return;
	}

	if (results != null && results.FetchRow())
	{
		results.FetchString(0, color, sizeof(color));
		TrimString(color);
		results.FetchString(1, prename, sizeof(prename));
		TrimString(prename);
	}

	PrintTeamJoinAlert(client, team, color, prename);
}

#define PLUGIN_VERSION "0.5"
public Plugin myinfo = 
{
	name = "filteralerts",
	author = "Bad Hombre",
	description = "Koggy fork of Tidy Chat",
	version = PLUGIN_VERSION,
	url = "https://forums.alliedmods.net/showthread.php?t=101340",
};

public void OnPluginStart()
{
	CreateConVar("sm_tidychat_version", PLUGIN_VERSION, "Tidy Chat Version", FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY);
	CreateNative("FilterAlerts_MarkAutobalance", Native_FilterAlerts_MarkAutobalance);
	CreateNative("FilterAlerts_SuppressTeamAlertWindow", Native_FilterAlerts_SuppressTeamAlertWindow);

	g_cvarEnabled = CreateConVar("sm_tidychat_on", "1", "0/1 On/off");
	g_cvarVoice = CreateConVar("sm_tidychat_voice", "1", "0/1 Tidy (Voice) messages");
	g_cvarDisconnect = CreateConVar("sm_tidychat_disconnect", "1", "0/1 Tidy disconnect messsages");
		g_cvarTeam = CreateConVar("sm_tidychat_team", "1", "0/1 Tidy team join messages");
		g_cvarCvar = CreateConVar("sm_tidychat_cvar", "1", "0/1 Tidy cvar messages");
		FilterAlerts_SQLConnect();
	
	// Mod independant hooks
	HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);
	HookEvent("player_team", Event_PlayerTeam, EventHookMode_Pre);
	HookEvent("server_cvar", Event_Cvar, EventHookMode_Pre);
	HookEvent("player_changename", Event_PlayerChangeName, EventHookMode_Pre);
	HookUserMessage(GetUserMessageId("SayText2"), UserMessageHook, true);

	// Hook voice subtitle usermessage if it exists (works on SDK2013/TF2C too)
	UserMsg voiceMsg = GetUserMessageId("VoiceSubtitle");
	if (voiceMsg != INVALID_MESSAGE_ID)
	{
		HookUserMessage(voiceMsg, UserMsg_VoiceSubtitle, true);
	}
}

public any Native_FilterAlerts_MarkAutobalance(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client > 0 && client <= MaxClients)
	{
		g_bSuppressNextTeamAlert[client] = true;
	}
	return 1;
}

public any Native_FilterAlerts_SuppressTeamAlertWindow(Handle plugin, int numParams)
{
	float seconds = view_as<float>(GetNativeCell(1));
	if (seconds <= 0.0)
	{
		return 0;
	}

	float until = GetGameTime() + seconds;
	if (until > g_fSuppressTeamAlertsUntil)
	{
		g_fSuppressTeamAlertsUntil = until;
	}
	return 1;
}

public Action UserMessageHook(UserMsg msg_hd, BfRead bf, const int[] players, int playersNum, bool reliable, bool init)
{
	// SayText2 layout: byte author, bool chat, string msg, string p1..p4
	bf.ReadByte();
	bf.ReadByte();

	char msg[96];
	char p1[96];
	char p2[96];
	char p3[96];
	char p4[96];
	bf.ReadString(msg, sizeof(msg));
	bf.ReadString(p1, sizeof(p1));
	bf.ReadString(p2, sizeof(p2));
	bf.ReadString(p3, sizeof(p3));
	bf.ReadString(p4, sizeof(p4));

	if (GetClientCount(false) < 7)
	{
		if (StrContains(msg, "Name_Change", false) != -1 || StrContains(p1, "Name_Change", false) != -1)
		{
			return Plugin_Handled;
		}
	}

	return Plugin_Continue;
}

public Action Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (client > 0 && client <= MaxClients)
	{
		g_bSuppressNextTeamAlert[client] = false;
	}

	if(g_cvarEnabled.BoolValue && g_cvarDisconnect.BoolValue)
	{
		event.BroadcastDisabled = true;
	}
	
	return Plugin_Continue;
}

public Action Event_PlayerChangeName(Event event, const char[] name, bool dontBroadcast)
{
        int client = GetClientOfUserId(GetEventInt(event, "userid"));
        if (client == 0 || IsFakeClient(client)) {
                event.BroadcastDisabled = true;
        }

        return Plugin_Continue;
}

public Action Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	if(g_cvarEnabled.BoolValue && g_cvarTeam.BoolValue)
		{
			if(!event.GetBool("silent"))
			{
	            if (g_fSuppressTeamAlertsUntil > 0.0)
	            {
	            	if (GetGameTime() < g_fSuppressTeamAlertsUntil)
	            	{
	            		event.BroadcastDisabled = true;
	            		return Plugin_Handled;
	            	}
	            	g_fSuppressTeamAlertsUntil = 0.0;
	            }
	            int client = GetClientOfUserId(GetEventInt(event, "userid"));
	            if ((!client) || IsFakeClient(client)) return Plugin_Handled;
	            if (g_bSuppressNextTeamAlert[client])
	            {
	            	g_bSuppressNextTeamAlert[client] = false;
	            	event.BroadcastDisabled = true;
	            	return Plugin_Handled;
	            }
	            int team = GetEventInt(event, "team");
	            if (team < 1 || team > 5)
	            {
                return Plugin_Stop;
            }

            if (!g_bDbReady || g_hDb == null)
            {
                PrintTeamJoinAlert(client, team, "", "");
                return Plugin_Handled;
            }

            char steamId64[32];
            if (!GetClientAuthId(client, AuthId_SteamID64, steamId64, sizeof(steamId64)))
            {
                PrintTeamJoinAlert(client, team, "", "");
                return Plugin_Handled;
            }

            char escapedSteam[64];
            SQL_EscapeString(g_hDb, steamId64, escapedSteam, sizeof(escapedSteam));

            char query[256];
            Format(query, sizeof(query),
                "SELECT "
                ... "(SELECT color FROM filters_namecolors WHERE steamid = '%s' LIMIT 1) AS color, "
                ... "(SELECT newname FROM prename_rules WHERE pattern = '%s' LIMIT 1) AS prename",
                escapedSteam, escapedSteam);

            DataPack pack = new DataPack();
            pack.WriteCell(GetClientUserId(client));
            pack.WriteCell(team);
            g_hDb.Query(FilterAlerts_TeamColorCallback, query, pack);
            return Plugin_Handled;
		}
	}
	
	return Plugin_Continue;
}

public Action Event_Cvar(Event event, const char[] name, bool dontBroadcast)
{
	if(g_cvarEnabled.BoolValue && g_cvarCvar.BoolValue)
	{
		event.BroadcastDisabled = true;
	}
	
	return Plugin_Continue;
}

public Action UserMsg_VoiceSubtitle(UserMsg msg_id, BfRead msg, const int[] players, int playersNum, bool reliable, bool init)
{
	if (g_cvarEnabled.BoolValue && g_cvarVoice.BoolValue)
	{
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

public void OnPluginEnd()
{
	if (g_hDb != null)
	{
		delete g_hDb;
		g_hDb = null;
	}
	g_bDbReady = false;
}
