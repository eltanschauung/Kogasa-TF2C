#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define SOUND_ROCKETPACK_CHARGE "weapons/rocket_pack_boosters_charge.wav"
#define SOUND_ROCKETPACK_FIRE "weapons/rocket_pack_boosters_fire.wav"
#define SOUND_ROCKETPACK_RETRACT "weapons/rocket_pack_boosters_retract.wav"
#define SOUND_ROCKETPACK_SHUTDOWN "weapons/rocket_pack_boosters_shutdown.wav"
#define SOUND_ROCKETPACK_LAND "weapons/rocket_pack_land.wav"
#define SOUND_ROCKETPACK_EXTEND "weapons/rocket_pack_boosters_extend.wav"

public Plugin myinfo =
{
    name = "precachesounds",
    author = "Hombre",
    description = "Precache rocket pack sounds on map start.",
    version = "1.0",
    url = ""
};

public void OnMapStart()
{
    PrecacheSound(SOUND_ROCKETPACK_CHARGE, true);
    PrecacheSound(SOUND_ROCKETPACK_FIRE, true);
    PrecacheSound(SOUND_ROCKETPACK_RETRACT, true);
    PrecacheSound(SOUND_ROCKETPACK_SHUTDOWN, true);
    PrecacheSound(SOUND_ROCKETPACK_LAND, true);
    PrecacheSound(SOUND_ROCKETPACK_EXTEND, true);
}
