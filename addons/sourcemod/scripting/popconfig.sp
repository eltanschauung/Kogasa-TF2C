#include <sourcemod>

#pragma semicolon 1
#pragma newdecls required

#define CHECK_INTERVAL 5.0

ConVar g_hPopThreshold;
bool g_bForceLow;
int g_iState = -1; // -1 unknown, 0 low, 1 high
Handle g_hCheckTimer = null;

public Plugin myinfo =
{
	name = "popconfig",
	author = "Hombre",
	description = "Execs d_lowpop.cfg or d_highpop.cfg based on playercount.",
	version = "1.0",
	url = ""
};

public void OnPluginStart()
{
	g_hPopThreshold = CreateConVar("pop_threshold", "14", "Player count threshold for lowpop/highpop config switching.", _, true, 0.0);
	RegAdminCmd("sm_respawn", Command_RespawnToggle, ADMFLAG_GENERIC, "Toggle forcing lowpop config regardless of player count.");
	UpdatePopConfig();
	EnsureCheckTimer();
}

public void OnMapStart()
{
	EnsureCheckTimer();
	UpdatePopConfig();
}

public Action Timer_CheckPop(Handle timer)
{
	UpdatePopConfig();
	return Plugin_Continue;
}

public Action Command_RespawnToggle(int client, int args)
{
	g_bForceLow = !g_bForceLow;
	g_iState = -1;
	UpdatePopConfig();
	ReplyToCommand(client, "[SM] Low-pop override %s.", g_bForceLow ? "enabled" : "disabled");
	return Plugin_Handled;
}

static void UpdatePopConfig()
{
	int players = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && GetClientTeam(i) >= 2)
		{
			players++;
		}
	}

	int threshold = g_hPopThreshold.IntValue;
	int state = (g_bForceLow || players <= threshold) ? 0 : 1;
	if (state == g_iState)
	{
		return;
	}

	g_iState = state;
	ServerCommand(state == 0 ? "exec d_lowpop.cfg" : "exec d_highpop.cfg");
	ServerExecute();
}

static void EnsureCheckTimer()
{
	if (g_hCheckTimer == null)
	{
		g_hCheckTimer = CreateTimer(CHECK_INTERVAL, Timer_CheckPop, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	}
}
