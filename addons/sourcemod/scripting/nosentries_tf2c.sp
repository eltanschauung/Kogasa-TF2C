#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>
#define CHECK_INTERVAL 2.0
ConVar g_hSentries;
public Plugin myinfo =
{
    name = "Disable Sentries",
    author = "Hombre",
    description = "Removes sentry guns when disabled via cvar.",
    version = "1.0",
    url = "https://kogasa.tf"
};
public void OnPluginStart()
{
    g_hSentries = CreateConVar("sentries", "1", "If 0, remove all sentry guns every 2 seconds.");
    RegAdminCmd("sm_killsentries", Command_KillSentries, ADMFLAG_GENERIC, "Kills all sentry guns.");
}
public void OnMapStart()
{
    CreateTimer(CHECK_INTERVAL, Timer_Check, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}
public Action Command_KillSentries(int client, int args)
{
    killAllSentries();
    ReplyToCommand(client, "[NoSentries] All sentry guns were removed.");
    return Plugin_Handled;
}
public Action Timer_Check(Handle timer)
{
    if (g_hSentries != null && g_hSentries.IntValue == 0)
    {
        killAllSentries();
    }
    return Plugin_Continue;
}
public void killAllSentries()
{
    int maxEnts = GetMaxEntities();
    char classname[64];
    for (int ent = MaxClients + 1; ent < maxEnts; ent++)
    {
        if (!IsValidEntity(ent))
        {
            continue;
        }
        GetEdictClassname(ent, classname, sizeof(classname));
        bool isSentry = IsSentryEntity(ent, classname);
        if (isSentry)
        {
            AcceptEntityInput(ent, "Kill");
        }
    }
}
static bool IsSentryEntity(int ent, const char[] classname)
{
    if (StrEqual(classname, "obj_sentrygun") || StrEqual(classname, "tf_obj_sentrygun"))
    {
        return true;
    }
    if (HasEntProp(ent, Prop_Send, "m_bMiniBuilding") && GetEntProp(ent, Prop_Send, "m_bMiniBuilding") != 0)
    {
        return true;
    }
    if (StrContains(classname, "sentry", false) != -1
        && HasEntProp(ent, Prop_Send, "m_flModelScale")
        && GetEntPropFloat(ent, Prop_Send, "m_flModelScale") < 1.0)
    {
        return true;
    }
    return false;
}