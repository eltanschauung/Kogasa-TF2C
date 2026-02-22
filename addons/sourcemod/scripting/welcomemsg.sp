#include <sourcemod>
#include <morecolors>

#pragma semicolon 1
#pragma newdecls required

#define WELCOME_DELAY 30.0
#define NEWS_AFTER_WELCOME_DELAY 15.0
Handle g_hWelcomeTimer[MAXPLAYERS + 1];
Handle g_hNewsTimer[MAXPLAYERS + 1];

public Plugin myinfo =
{
	name = "welcomemsg",
	author = "Hombre",
	description = "Welcomes players and provides server info.",
	version = "1.0",
	url = "https://kogasa.tf"
};

public void OnPluginStart()
{
	RegConsoleCmd("sm_welcome", Command_Welcome);
	RegConsoleCmd("sm_info", Command_Welcome);
	RegConsoleCmd("sm_news", Command_News);
	RegConsoleCmd("sm_rules", Command_Rules);
	RegConsoleCmd("sm_hats", Command_Hats);
	RegConsoleCmd("sm_hat", Command_Hats);
	RegConsoleCmd("sm_calladmin", Command_CallAdmin);
	RegConsoleCmd("sm_changes", Command_Changes);
	RegConsoleCmd("sm_r", Command_Changes);
}

public void OnClientPostAdminCheck(int client)
{
	if (!IsClientInGame(client) || IsFakeClient(client))
	{
		return;
	}

	if (g_hWelcomeTimer[client] != null)
	{
		delete g_hWelcomeTimer[client];
		g_hWelcomeTimer[client] = null;
	}

	g_hWelcomeTimer[client] = CreateTimer(WELCOME_DELAY, Timer_Welcome, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public void OnClientDisconnect(int client)
{
	if (g_hWelcomeTimer[client] != null)
	{
		delete g_hWelcomeTimer[client];
		g_hWelcomeTimer[client] = null;
	}

	if (g_hNewsTimer[client] != null)
	{
		delete g_hNewsTimer[client];
		g_hNewsTimer[client] = null;
	}
}

public Action Timer_Welcome(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	if (client == 0 || !IsClientInGame(client) || IsFakeClient(client))
	{
		return Plugin_Stop;
	}

	g_hWelcomeTimer[client] = null;
	SendWelcomeMessage(client);

	return Plugin_Stop;
}

public Action Command_News(int client, int args)
{
	if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
	{
		return Plugin_Handled;
	}

	SendNewsMessage(client);

	return Plugin_Handled;
}

public Action Command_Welcome(int client, int args)
{
	if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
	{
		return Plugin_Handled;
	}

	SendWelcomeMessage(client);

	return Plugin_Handled;
}

public Action Command_Rules(int client, int args)
{
	if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
	{
		return Plugin_Handled;
	}

	CPrintToChat(client, "{gold}1. No cheating or friendlies\n{violet}2. You're not allowed to make chat servers or funnel people into different games\n{sandybrown}3. Don't spray disgusting things like furry stuff");

	return Plugin_Handled;
}

public Action Command_Hats(int client, int args)
{
	if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
	{
		return Plugin_Handled;
	}

	CPrintToChat(client, "{gold}The Original, Iron Bomber -> Suku Tenshi");
	CPrintToChat(client, "{gold}Purification Rod -> Marisa's Hat");
	CPrintToChat(client, "{gold}The Winger, Pocket Pistol -> Cirno's Wings");
	CPrintToChat(client, "{gold}Backburner, Dragon Fury, Zatoichi, Fry Pan -> Neru's Halo");
	CPrintToChat(client, "{gold}Sticky Launcher,  Scattergun, Twin Barrel -> Punishing Bird");
	CPrintToChat(client, "{gold}Flamethrower, Degreaser -> Midori/Momoi Halo");

	return Plugin_Handled;
}

public Action Command_Changes(int client, int args)
{
	if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
	{
		return Plugin_Handled;
	}

	CPrintToChat(client, "Buffed: {green}Ambassador | Syringe Guns | Shortstop | Candy Cane | Fan o War | Baby Face | B. Scatter | S. Jumper | Scottish Res. | Booties");
	CPrintToChat(client, "{green}Base Jumper | Gunboats | A. Strike | Beggars |  Gloves of Running | Huo Long | Huntsman");
	CPrintToChat(client, "Nerfed or removed:{red} AA Cannon | RPG | Cyclops | L'Escampette | Demo Shields | Hunting Revolver | Tranq. Gun | Mine Layer | Vaccinator | Short Circuit | B. Beast | Natascha | Sentries");

	return Plugin_Handled;
}

public Action Command_CallAdmin(int client, int args)
{
	if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
	{
		return Plugin_Handled;
	}

	CPrintToChat(client, "[SM] An admin has been alerted to join! Please wait warmly.");

	return Plugin_Handled;
}

void SendWelcomeMessage(int client)
{
	CPrintToChat(client, "Welcome to the {axis}Gensokyo {default}%N!\nThis is a {lightgreen}4chan type server{default} with normal TF2 weapons and other awesome features.\nJoin our Steam chat to keep up with playtimes:", client);
	CPrintToChat(client, "{gold}steamcommunity.com/chat/invite/Es09gkBm");
	CPrintToChat(client, "Note: use !opt to mute {yellow}Homer Simpson sounds");

	if (g_hNewsTimer[client] != null)
	{
		delete g_hNewsTimer[client];
		g_hNewsTimer[client] = null;
	}

	g_hNewsTimer[client] = CreateTimer(NEWS_AFTER_WELCOME_DELAY, Timer_NewsAfterWelcome, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_NewsAfterWelcome(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	if (client == 0 || !IsClientInGame(client) || IsFakeClient(client))
	{
		return Plugin_Stop;
	}

	g_hNewsTimer[client] = null;
	SendNewsMessage(client);
	return Plugin_Stop;
}

void SendNewsMessage(int client)
{
	CPrintToChat(client, "{gold}News: {default}Added new Rocket Launchers, reworked the R.P.G., added the Old Panic Attack, added the Crusader's Crossbow, a Medic shotgun and added medigun partner speed, added Whalescramble");
}
