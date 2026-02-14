#include <sourcemod>
#include <tf2>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.4"

public Plugin myinfo =
{
    name = "skipmotd",
    author = "Original by MasterOfTheXP, modified by GC, simplified by Codex",
    description = "Forces MOTD skip, auto-joins least-pop team, and random class.",
    version = PLUGIN_VERSION,
    url = "http://mstr.ca/"
};

bool g_MotdBlocked[MAXPLAYERS + 1];

public void OnPluginStart()
{
    CreateConVar("sm_nomotd_version", PLUGIN_VERSION, "No MOTD version", FCVAR_NOTIFY|FCVAR_SPONLY);

    for (int i = 1; i <= MaxClients; i++)
    {
        g_MotdBlocked[i] = IsClientInGame(i);
    }

    HookUserMessage(GetUserMessageId("Train"), UserMessageHook, true);
}

public void OnClientDisconnect(int client)
{
    g_MotdBlocked[client] = false;
}

public Action UserMessageHook(UserMsg msg_id, Handle bf, const int[] players, int playersNum, bool reliable, bool init)
{
    if (playersNum == 1 && IsClientConnected(players[0]) && !g_MotdBlocked[players[0]] && !IsFakeClient(players[0]))
    {
        g_MotdBlocked[players[0]] = true;
        CreateTimer(0.0, Timer_ForceJoin, GetClientUserId(players[0]), TIMER_FLAG_NO_MAPCHANGE);
    }

    return Plugin_Continue;
}

public Action Timer_ForceJoin(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0)
    {
        return Plugin_Handled;
    }

    // Skip MOTD
    ShowVGUIPanel(client, "info", _, false);

    // Join least-pop team (fall back to auto if tied)
    int team = GetLeastPopulatedTeam();
    if (team == 2)
    {
        FakeClientCommand(client, "jointeam red");
    }
    else if (team == 3)
    {
        FakeClientCommand(client, "jointeam blue");
    }
    else
    {
        FakeClientCommand(client, "jointeam auto");
    }

    // Random class from allowed list
    static const char classes[][] =
    {
        "scout",
        "soldier",
        "demoman",
        "pyro",
        "engineer"
    };
    char className[16];
    strcopy(className, sizeof(className), classes[GetRandomInt(0, sizeof(classes) - 1)]);
    FakeClientCommand(client, "joinclass %s", className);
    ShowVGUIPanel(client, "class_blue", _, false);
    ShowVGUIPanel(client, "class_red", _, false);

    return Plugin_Handled;
}

static int GetLeastPopulatedTeam()
{
    int red = 0;
    int blue = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
        {
            continue;
        }
        int team = GetClientTeam(i);
        if (team == 2)
        {
            red++;
        }
        else if (team == 3)
        {
            blue++;
        }
    }

    if (red < blue)
    {
        return 2;
    }
    if (blue < red)
    {
        return 3;
    }
    return 0;
}
