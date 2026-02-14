#include <sourcemod>

#pragma semicolon 1
#pragma newdecls required

#define POP_THRESHOLD 14
#define CHECK_DELAY 0.1
#define MAPSTART_RECHECK_DELAY 10.0

enum PopState
{
	PopState_Unknown = 0,
	PopState_Low,
	PopState_High
};

PopState g_PopState = PopState_Unknown;
Handle g_hRecheckTimer = null;
Handle g_hMapStartTimer = null;
bool g_bForceLowpop = false;

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
	RegAdminCmd("sm_respawn", Command_RespawnToggle, ADMFLAG_GENERIC, "Toggle forcing lowpop config regardless of player count.");
}

public void OnMapStart()
{
	UpdatePopConfig();

	if (g_hMapStartTimer != null)
	{
		delete g_hMapStartTimer;
		g_hMapStartTimer = null;
	}

	g_hMapStartTimer = CreateTimer(MAPSTART_RECHECK_DELAY, Timer_MapStartRecheck, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnClientPutInServer(int client)
{
	if (IsFakeClient(client))
	{
		return;
	}

	QueueRecheck();
}

public void OnClientPostAdminCheck(int client)
{
	if (IsFakeClient(client))
	{
		return;
	}

	QueueRecheck();
}

public void OnClientDisconnect(int client)
{
	if (IsFakeClient(client))
	{
		return;
	}

	QueueRecheck();
}

static void QueueRecheck()
{
	if (g_hRecheckTimer != null)
	{
		return;
	}

	g_hRecheckTimer = CreateTimer(CHECK_DELAY, Timer_Recheck, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_Recheck(Handle timer)
{
	g_hRecheckTimer = null;
	UpdatePopConfig();
	return Plugin_Stop;
}

public Action Timer_MapStartRecheck(Handle timer)
{
	g_hMapStartTimer = null;
	UpdatePopConfig();
	return Plugin_Stop;
}

static void UpdatePopConfig()
{
	int humans = GetClientCount(false);
	PopState nextState = g_bForceLowpop ? PopState_Low : ((humans <= POP_THRESHOLD) ? PopState_Low : PopState_High);

	if (nextState == g_PopState)
	{
		return;
	}

	g_PopState = nextState;
	if (g_PopState == PopState_Low)
	{
		ServerCommand("exec d_lowpop.cfg");
	}
	else
	{
		ServerCommand("exec d_highpop.cfg");
	}
	ServerExecute();
}

public Action Command_RespawnToggle(int client, int args)
{
	g_bForceLowpop = !g_bForceLowpop;
	g_PopState = PopState_Unknown;
	UpdatePopConfig();

	ReplyToCommand(client, "[SM] Low-pop override %s.", g_bForceLowpop ? "enabled" : "disabled");
	return Plugin_Handled;
}
