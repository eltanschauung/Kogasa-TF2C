#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <morecolors>

ConVar g_cvarEnabled;
ConVar g_cvarVoice;
ConVar g_cvarDisconnect;
ConVar g_cvarTeam;
ConVar g_cvarCvar;

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

	g_cvarEnabled = CreateConVar("sm_tidychat_on", "1", "0/1 On/off");
	g_cvarVoice = CreateConVar("sm_tidychat_voice", "1", "0/1 Tidy (Voice) messages");
	g_cvarDisconnect = CreateConVar("sm_tidychat_disconnect", "1", "0/1 Tidy disconnect messsages");
	g_cvarTeam = CreateConVar("sm_tidychat_team", "1", "0/1 Tidy team join messages");
	g_cvarCvar = CreateConVar("sm_tidychat_cvar", "1", "0/1 Tidy cvar messages");
	
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
            int client = GetClientOfUserId(GetEventInt(event, "userid"));
            if ((!client) || IsFakeClient(client)) return Plugin_Handled;
            int team = GetEventInt(event, "team");
            char name2[64];
            char output[256];
            char team2[64];
            GetClientName(client, name2, sizeof(name2));
            switch (team)
            {
                case (1): Format(team2, sizeof(team2), "entered {lightsteelblue}Keine's Class");
                case (2): Format(team2, sizeof(team2), "joined team {red}Fujiwara");
                case (3): Format(team2, sizeof(team2), "joined team {blue}Houraisan");
                case (4): Format(team2, sizeof(team2), "joined team {green}Konpaku");
                case (5): Format(team2, sizeof(team2), "joined team {yellow}Kirisame");
                default: return Plugin_Stop;
            } 
            Format(output, sizeof(output), "%s %s", name2, team2);
            CPrintToChatAll(output);
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
