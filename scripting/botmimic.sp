/**
 * Bot Mimic - Record your movments and have bots playing it back.
 * by Peace-Maker
 * visit http://wcfan.de
 *
 * Changelog post-2.1 by Drixevel:
 * 2.1.1r	-	11.08.2019: Forked, Removed SMLIB support.
 * 2.1.2r	-	16.08.2019: Updated syntax, added a delay for recordings to be finished on death.
 * 
 * Changelog pre-2.1 by Peace-Maker:
 * 2.0   - 22.07.2013: Released rewrite
 * 2.0.1 - 01.08.2013: Actually made DHooks an optional dependency.
 * 2.1   - 02.10.2014: Added bookmarks and pausing/resuming while recording. Fixed crashes and problems with CS:GO.
 */

#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <cstrike>
#include <sdkhooks>
#include <botmimic>

#undef REQUIRE_EXTENSIONS
#include <dhooks>

#define PLUGIN_VERSION "2.1.2r"

#define BM_MAGIC 0xdeadbeef

// New in 0x02: bookmarkCount and bookmarks list.
#define BINARY_FORMAT_VERSION 0x02

// Path for the recordings to be saved.
#define DEFAULT_RECORD_FOLDER "data/botmimic/"

// Flags set in FramInfo.additionalFields to inform, that there's more info afterwards.
#define ADDITIONAL_FIELD_TELEPORTED_ORIGIN (1<<0)
#define ADDITIONAL_FIELD_TELEPORTED_ANGLES (1<<1)
#define ADDITIONAL_FIELD_TELEPORTED_VELOCITY (1<<2)

enum FrameInfo {
	playerButtons = 0,
	playerImpulse,
	Float:actualVelocity[3],
	Float:predictedVelocity[3],
	Float:predictedAngles[2], // Ignore roll
	CSWeaponID:newWeapon,
	playerSubtype,
	playerSeed,
	additionalFields // see ADDITIONAL_FIELD_* defines
}

#define AT_ORIGIN 0
#define AT_ANGLES 1
#define AT_VELOCITY 2
#define AT_FLAGS 3

enum AdditionalTeleport {
	Float:atOrigin[3],
	Float:atAngles[3],
	Float:atVelocity[3],
	atFlags
}

enum FileHeader {
	FH_binaryFormatVersion = 0,
	FH_recordEndTime,
	String:FH_recordName[MAX_RECORD_NAME_LENGTH],
	FH_tickCount,
	FH_bookmarkCount,
	Float:FH_initialPosition[3],
	Float:FH_initialAngles[3],
	Handle:FH_bookmarks,
	Handle:FH_frames
}

enum Bookmarks {
	BKM_frame,
	BKM_additionalTeleportTick,
	String:BKM_name[MAX_BOOKMARK_NAME_LENGTH]
};

// Used to fire the OnPlayerMimicBookmark effciently during playback
enum BookmarkWhileMimicing {
	BWM_frame, // The frame this bookmark was saved in
	BWM_index // The index into the FH_bookmarks array in the fileheader for the corresponding bookmark (to get the name)
};

// Where did he start recording. The bot is teleported to this position on replay.
float g_fInitialPosition[MAXPLAYERS + 1][3];
float g_fInitialAngles[MAXPLAYERS + 1][3];
// Array of frames
Handle g_hRecording[MAXPLAYERS + 1];
Handle g_hRecordingAdditionalTeleport[MAXPLAYERS + 1];
Handle g_hRecordingBookmarks[MAXPLAYERS + 1];
int g_iCurrentAdditionalTeleportIndex[MAXPLAYERS + 1];
// Is the recording currently paused?
bool g_bRecordingPaused[MAXPLAYERS + 1];
bool g_bSaveFullSnapshot[MAXPLAYERS + 1];
// How many calls to OnPlayerRunCmd were recorded?
int g_iRecordedTicks[MAXPLAYERS + 1];
// What's the last active weapon
int g_iRecordPreviousWeapon[MAXPLAYERS + 1];
// Count ticks till we save the position again
int g_iOriginSnapshotInterval[MAXPLAYERS + 1];
// The name of this recording
char g_sRecordName[MAXPLAYERS + 1][MAX_RECORD_NAME_LENGTH];
char g_sRecordPath[MAXPLAYERS + 1][PLATFORM_MAX_PATH];
char g_sRecordCategory[MAXPLAYERS + 1][PLATFORM_MAX_PATH];
char g_sRecordSubDir[MAXPLAYERS + 1][PLATFORM_MAX_PATH];

StringMap g_hLoadedRecords;
StringMap g_hLoadedRecordsAdditionalTeleport;
StringMap g_hLoadedRecordsCategory;
ArrayList g_hSortedRecordList;
ArrayList g_hSortedCategoryList;

Handle g_hBotMimicsRecord[MAXPLAYERS + 1];
int g_iBotMimicTick[MAXPLAYERS + 1];
bool g_bBotMimicStart[MAXPLAYERS + 1];
int g_iBotMimicRecordTickCount[MAXPLAYERS + 1];
int g_iBotActiveWeapon[MAXPLAYERS + 1] = {-1,...};
bool g_bValidTeleportCall[MAXPLAYERS + 1];
new g_iBotMimicNextBookmarkTick[MAXPLAYERS + 1][BookmarkWhileMimicing];

Handle g_hfwdOnStartRecording;
Handle g_hfwdOnRecordingPauseStateChanged;
Handle g_hfwdOnRecordingBookmarkSaved;
Handle g_hfwdOnStopRecording;
Handle g_hfwdOnRecordSaved;
Handle g_hfwdOnRecordDeleted;
Handle g_hfwdOnPlayerStartsMimicing;
Handle g_hfwdOnPlayerStopsMimicing;
Handle g_hfwdOnPlayerMimicLoops;
Handle g_hfwdOnPlayerMimicBookmark;

// DHooks
Handle g_hTeleport;

Handle g_hCVOriginSnapshotInterval;
Handle g_hCVRespawnOnDeath;

public Plugin:myinfo = 
{
	name = "Bot Mimic [Redux]",
	author = "Jannik \"Peace-Maker\" Hartung, Redux by Drixevel",
	description = "Bots mimic your movements!",
	version = PLUGIN_VERSION,
	url = "http://www.wcfan.de/"
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	RegPluginLibrary("botmimic");
	
	CreateNative("BotMimic_StartRecording", StartRecording);
	CreateNative("BotMimic_PauseRecording", PauseRecording);
	CreateNative("BotMimic_ResumeRecording", ResumeRecording);
	CreateNative("BotMimic_IsRecordingPaused", IsRecordingPaused);
	CreateNative("BotMimic_StopRecording", StopRecording);
	CreateNative("BotMimic_SaveBookmark", SaveBookmark);
	CreateNative("BotMimic_DeleteRecord", DeleteRecord);
	CreateNative("BotMimic_IsPlayerRecording", IsPlayerRecording);
	CreateNative("BotMimic_IsPlayerMimicing", IsPlayerMimicing);
	CreateNative("BotMimic_GetRecordPlayerMimics", GetRecordPlayerMimics);
	CreateNative("BotMimic_PlayRecordFromFile", PlayRecordFromFile);
	CreateNative("BotMimic_PlayRecordByName", PlayRecordByName);
	CreateNative("BotMimic_ResetPlayback", ResetPlayback);
	CreateNative("BotMimic_GoToBookmark", GoToBookmark);
	CreateNative("BotMimic_StopPlayerMimic", StopPlayerMimic);
	CreateNative("BotMimic_GetFileHeaders", GetFileHeaders);
	CreateNative("BotMimic_ChangeRecordName", ChangeRecordName);
	CreateNative("BotMimic_GetLoadedRecordCategoryList", GetLoadedRecordCategoryList);
	CreateNative("BotMimic_GetLoadedRecordList", GetLoadedRecordList);
	CreateNative("BotMimic_GetFileCategory", GetFileCategory);
	CreateNative("BotMimic_GetRecordBookmarks", GetRecordBookmarks);
	
	g_hfwdOnStartRecording = CreateGlobalForward("BotMimic_OnStartRecording", ET_Hook, Param_Cell, Param_String, Param_String, Param_String, Param_String);
	g_hfwdOnRecordingPauseStateChanged = CreateGlobalForward("BotMimic_OnRecordingPauseStateChanged", ET_Ignore, Param_Cell, Param_Cell);
	g_hfwdOnRecordingBookmarkSaved = CreateGlobalForward("BotMimic_OnRecordingBookmarkSaved", ET_Ignore, Param_Cell, Param_String);
	g_hfwdOnStopRecording = CreateGlobalForward("BotMimic_OnStopRecording", ET_Hook, Param_Cell, Param_String, Param_String, Param_String, Param_String, Param_CellByRef);
	g_hfwdOnRecordSaved = CreateGlobalForward("BotMimic_OnRecordSaved", ET_Ignore, Param_Cell, Param_String, Param_String, Param_String, Param_String);
	g_hfwdOnRecordDeleted = CreateGlobalForward("BotMimic_OnRecordDeleted", ET_Ignore, Param_String, Param_String, Param_String);
	g_hfwdOnPlayerStartsMimicing = CreateGlobalForward("BotMimic_OnPlayerStartsMimicing", ET_Hook, Param_Cell, Param_String, Param_String, Param_String);
	g_hfwdOnPlayerStopsMimicing = CreateGlobalForward("BotMimic_OnPlayerStopsMimicing", ET_Ignore, Param_Cell, Param_String, Param_String, Param_String);
	g_hfwdOnPlayerMimicLoops = CreateGlobalForward("BotMimic_OnPlayerMimicLoops", ET_Ignore, Param_Cell);
	g_hfwdOnPlayerMimicBookmark = CreateGlobalForward("BotMimic_OnPlayerMimicBookmark", ET_Ignore, Param_Cell, Param_String);
	
	return APLRes_Success;
}

public OnPluginStart()
{
	CreateConVar("sm_botmimic_version", PLUGIN_VERSION, "Bot Mimic version", FCVAR_NOTIFY|FCVAR_DONTRECORD);
	
	// Save the position of clients every 10000 ticks
	// This is to avoid bots getting stuck in walls due to slightly lower jumps, if they don't touch the ground.
	g_hCVOriginSnapshotInterval = CreateConVar("sm_botmimic_snapshotinterval", "10000", "Save the position of clients every x ticks. This is to avoid bots getting stuck in walls during a long playback and lots of jumps.", _, true, 0.0);
	g_hCVRespawnOnDeath = CreateConVar("sm_botmimic_respawnondeath", "1", "Respawn the bot when he dies during playback?", _, true, 0.0, true, 1.0);
	
	AutoExecConfig();
	
	// Maps path to .rec -> record enum
	g_hLoadedRecords = new StringMap();
	g_hLoadedRecordsAdditionalTeleport = new StringMap();
	
	// Maps path to .rec -> record category
	g_hLoadedRecordsCategory = new StringMap();
	
	// Save all paths to .rec files in the trie sorted by time
	g_hSortedRecordList = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
	g_hSortedCategoryList = new ArrayList(ByteCountToCells(64));
	
	HookEvent("player_spawn", Event_OnPlayerSpawn);
	HookEvent("player_death", Event_OnPlayerDeath);
	
	if (LibraryExists("dhooks"))
		OnLibraryAdded("dhooks");
}

/**
 * Public forwards
 */
public void OnLibraryAdded(const char[] name)
{
	if (StrEqual(name, "dhooks") && g_hTeleport == null)
	{
		// Optionally setup a hook on CBaseEntity::Teleport to keep track of sudden place changes
		Handle hGameData = LoadGameConfigFile("sdktools.games");
		
		if (hGameData == null)
			return;
		
		int iOffset = GameConfGetOffset(hGameData, "Teleport");
		delete hGameData;
		
		if (iOffset == -1)
			return;
		
		g_hTeleport = DHookCreate(iOffset, HookType_Entity, ReturnType_Void, ThisPointer_CBaseEntity, DHooks_OnTeleport);
		
		if (g_hTeleport == null)
			return;
		
		DHookAddParam(g_hTeleport, HookParamType_VectorPtr);
		DHookAddParam(g_hTeleport, HookParamType_ObjectPtr);
		DHookAddParam(g_hTeleport, HookParamType_VectorPtr);
		
		if (GetEngineVersion() == Engine_CSGO)
			DHookAddParam(g_hTeleport, HookParamType_Bool);
		
		for (int i = 1; i <= MaxClients; i++)
			if (IsClientInGame(i))
				OnClientPutInServer(i);
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "dhooks"))
		g_hTeleport = null;
}

public OnMapStart()
{
	// Clear old records for old map
	int iSize = g_hSortedRecordList.Length;
	char sPath[PLATFORM_MAX_PATH];
	new iFileHeader[FileHeader];
	Handle hAdditionalTeleport;
	
	for (int i = 0; i < iSize; i++)
	{
		g_hSortedRecordList.GetString(i, sPath, sizeof(sPath));
		g_hLoadedRecords.GetArray(sPath, iFileHeader[0], _:FileHeader);
		
		delete iFileHeader[FH_frames];
		delete iFileHeader[FH_bookmarks];
		
		if (g_hLoadedRecordsAdditionalTeleport.GetValue(sPath, hAdditionalTeleport))
			delete hAdditionalTeleport;
	}
	
	g_hLoadedRecords.Clear();
	g_hLoadedRecordsAdditionalTeleport.Clear();
	g_hLoadedRecordsCategory.Clear();
	g_hSortedRecordList.Clear();
	g_hSortedCategoryList.Clear();
	
	// Create our record directory
	BuildPath(Path_SM, sPath, sizeof(sPath), DEFAULT_RECORD_FOLDER);
	
	if (!DirExists(sPath))
		CreateDirectory(sPath, 511);
	
	// Check for categories
	Handle hDir = OpenDirectory(sPath);
	
	if (hDir == null)
		return;
	
	char sFile[64]; FileType fileType;
	while (ReadDirEntry(hDir, sFile, sizeof(sFile), fileType))
	{
		switch (fileType)
		{
			// Check all directories for records on this map
			case FileType_Directory:
			{
				// INFINITE RECURSION ANYONE?
				if (StrEqual(sFile, ".") || StrEqual(sFile, ".."))
					continue;
				
				BuildPath(Path_SM, sPath, sizeof(sPath), "%s%s", DEFAULT_RECORD_FOLDER, sFile);
				ParseRecordsInDirectory(sPath, sFile, false);
			}
		}
		
	}
	
	delete hDir;
}

public OnClientPutInServer(client)
{
	if (g_hTeleport != null)
		DHookEntity(g_hTeleport, false, client);
}

public OnClientDisconnect(client)
{
	if (g_hRecording[client] != null)
		BotMimic_StopRecording(client);
	
	if (g_hBotMimicsRecord[client] != null)
		BotMimic_StopPlayerMimic(client);
}

public Action:OnPlayerRunCmd(client, &buttons, &impulse, Float:vel[3], Float:angles[3], &weapon, &subtype, &cmdnum, &tickcount, &seed, mouse[2])
{
	// client is recording his movements
	if (g_hRecording[client] != null && !g_bRecordingPaused[client])
	{
		new iFrame[FrameInfo];
		iFrame[playerButtons] = buttons;
		iFrame[playerImpulse] = impulse;
		
		new Float:vVel[3];
		GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", vVel);
		iFrame[actualVelocity] = vVel;
		iFrame[predictedVelocity] = vel;
		CopyArrayToArray(angles, iFrame[predictedAngles], 2);
		iFrame[newWeapon] = CSWeapon_NONE;
		iFrame[playerSubtype] = subtype;
		iFrame[playerSeed] = seed;
		
		// Save the origin, angles and velocity in this frame.
		if (g_bSaveFullSnapshot[client])
		{
			new iAT[AdditionalTeleport], Float:fBuffer[3];
			GetClientAbsOrigin(client, fBuffer);
			CopyArrayToArray(fBuffer, iAT[atOrigin], 3);
			GetClientEyeAngles(client, fBuffer);
			CopyArrayToArray(fBuffer, iAT[atAngles], 3);
			GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", fBuffer);
			CopyArrayToArray(fBuffer, iAT[atVelocity], 3);
			
			iAT[atFlags] = ADDITIONAL_FIELD_TELEPORTED_ORIGIN|ADDITIONAL_FIELD_TELEPORTED_ANGLES|ADDITIONAL_FIELD_TELEPORTED_VELOCITY;
			PushArrayArray(g_hRecordingAdditionalTeleport[client], iAT[0], _:AdditionalTeleport);
			g_bSaveFullSnapshot[client] = false;
		}
		else
		{
			// Save the current position 
			new iInterval = GetConVarInt(g_hCVOriginSnapshotInterval);
			if (iInterval > 0 && g_iOriginSnapshotInterval[client] > iInterval)
			{
				new Float:origin[3], iAT[AdditionalTeleport];
				GetClientAbsOrigin(client, origin);
				CopyArrayToArray(origin, iAT[atOrigin], 3);
				iAT[atFlags] |= ADDITIONAL_FIELD_TELEPORTED_ORIGIN;
				PushArrayArray(g_hRecordingAdditionalTeleport[client], iAT[0], _:AdditionalTeleport);
				g_iOriginSnapshotInterval[client] = 0;
			}
		}
		
		g_iOriginSnapshotInterval[client]++;
		
		// Check for additional Teleports
		if (GetArraySize(g_hRecordingAdditionalTeleport[client]) > g_iCurrentAdditionalTeleportIndex[client])
		{
			new iAT[AdditionalTeleport];
			GetArrayArray(g_hRecordingAdditionalTeleport[client], g_iCurrentAdditionalTeleportIndex[client], iAT[0], _:AdditionalTeleport);
			// Remember, we were teleported this frame!
			iFrame[additionalFields] |= iAT[atFlags];
			g_iCurrentAdditionalTeleportIndex[client]++;
		}
		
		new iNewWeapon = -1;
		
		// Did he change his weapon?
		if (weapon)
			iNewWeapon = weapon;
		// Picked up a new one?
		else
		{
			new iWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
			
			// He's holding a weapon and
			// we just started recording. Always save the first weapon!
			// This is a new weapon, he didn't held before.
			if (iWeapon != -1 && (g_iRecordedTicks[client] == 0 || g_iRecordPreviousWeapon[client] != iWeapon))
				iNewWeapon = iWeapon;
		}
		
		if (iNewWeapon != -1)
		{
			// Save it
			if (IsValidEntity(iNewWeapon) && IsValidEdict(iNewWeapon))
			{
				g_iRecordPreviousWeapon[client] = iNewWeapon;
				
				char sClassName[64];
				GetEdictClassname(iNewWeapon, sClassName, sizeof(sClassName));
				ReplaceString(sClassName, sizeof(sClassName), "weapon_", "", false);
				
				char sWeaponAlias[64];
				CS_GetTranslatedWeaponAlias(sClassName, sWeaponAlias, sizeof(sWeaponAlias));
				new CSWeaponID:weaponId = CS_AliasToWeaponID(sWeaponAlias);
				
				iFrame[newWeapon] = weaponId;
			}
		}
		
		PushArrayArray(g_hRecording[client], iFrame[0], _:FrameInfo);
		g_iRecordedTicks[client]++;
	}
	
	// Bot is mimicing something
	else if (g_hBotMimicsRecord[client] != null)
	{
		// Is this a valid living bot?
		if (!IsPlayerAlive(client) || GetClientTeam(client) < CS_TEAM_T)
			return Plugin_Continue;
		
		if (g_iBotMimicTick[client] >= g_iBotMimicRecordTickCount[client])
		{
			g_iBotMimicTick[client] = 0;
			g_iCurrentAdditionalTeleportIndex[client] = 0;
		}
		
		new iFrame[FrameInfo];
		GetArrayArray(g_hBotMimicsRecord[client], g_iBotMimicTick[client], iFrame[0], _:FrameInfo);
		
		buttons = iFrame[playerButtons];
		impulse = iFrame[playerImpulse];
		CopyArrayToArray(iFrame[predictedVelocity], vel, 3);
		CopyArrayToArray(iFrame[predictedAngles], angles, 2);
		subtype = iFrame[playerSubtype];
		seed = iFrame[playerSeed];
		weapon = 0;
		
		decl Float:fActualVelocity[3];
		CopyArrayToArray(iFrame[actualVelocity], fActualVelocity, 3);
		
		// We're supposed to teleport stuff?
		if (iFrame[additionalFields] & (ADDITIONAL_FIELD_TELEPORTED_ORIGIN|ADDITIONAL_FIELD_TELEPORTED_ANGLES|ADDITIONAL_FIELD_TELEPORTED_VELOCITY))
		{
			new iAT[AdditionalTeleport], Handle:hAdditionalTeleport; char sPath[PLATFORM_MAX_PATH];
			GetFileFromFrameHandle(g_hBotMimicsRecord[client], sPath, sizeof(sPath));
			g_hLoadedRecordsAdditionalTeleport.GetValue(sPath, hAdditionalTeleport);
			GetArrayArray(hAdditionalTeleport, g_iCurrentAdditionalTeleportIndex[client], iAT[0], _:AdditionalTeleport);
			
			new Float:fOrigin[3], Float:fAngles[3], Float:fVelocity[3];
			CopyArrayToArray(iAT[atOrigin], fOrigin, 3);
			CopyArrayToArray(iAT[atAngles], fAngles, 3);
			CopyArrayToArray(iAT[atVelocity], fVelocity, 3);
			
			// The next call to Teleport is ok.
			g_bValidTeleportCall[client] = true;
			
			// THATS STUPID!
			// Only pass the arguments, if they were set..
			if (iAT[atFlags] & ADDITIONAL_FIELD_TELEPORTED_ORIGIN)
			{
				if (iAT[atFlags] & ADDITIONAL_FIELD_TELEPORTED_ANGLES)
				{
					if (iAT[atFlags] & ADDITIONAL_FIELD_TELEPORTED_VELOCITY)
						TeleportEntity(client, fOrigin, fAngles, fVelocity);
					else
						TeleportEntity(client, fOrigin, fAngles, NULL_VECTOR);
				}
				else
				{
					if (iAT[atFlags] & ADDITIONAL_FIELD_TELEPORTED_VELOCITY)
						TeleportEntity(client, fOrigin, NULL_VECTOR, fVelocity);
					else
						TeleportEntity(client, fOrigin, NULL_VECTOR, NULL_VECTOR);
				}
			}
			else
			{
				if (iAT[atFlags] & ADDITIONAL_FIELD_TELEPORTED_ANGLES)
				{
					if (iAT[atFlags] & ADDITIONAL_FIELD_TELEPORTED_VELOCITY)
						TeleportEntity(client, NULL_VECTOR, fAngles, fVelocity);
					else
						TeleportEntity(client, NULL_VECTOR, fAngles, NULL_VECTOR);
				}
				else
				{
					if (iAT[atFlags] & ADDITIONAL_FIELD_TELEPORTED_VELOCITY)
						TeleportEntity(client, NULL_VECTOR, NULL_VECTOR, fVelocity);
				}
			}
			
			g_iCurrentAdditionalTeleportIndex[client]++;
		}
		
		// This is the first tick. Teleport him to the initial position
		if (g_iBotMimicTick[client] == 0 || g_bBotMimicStart[client])
		{
			g_bBotMimicStart[client] = false;
			g_bValidTeleportCall[client] = true;
			TeleportEntity(client, g_fInitialPosition[client], g_fInitialAngles[client], fActualVelocity);
			CSGO_StripAllWeapons(client);
			
			Call_StartForward(g_hfwdOnPlayerMimicLoops);
			Call_PushCell(client);
			Call_Finish();
		}
		else
		{
			g_bValidTeleportCall[client] = true;
			TeleportEntity(client, NULL_VECTOR, angles, fActualVelocity);
		}
		
		if (iFrame[newWeapon] != CSWeapon_NONE)
		{
			char sAlias[64];
			CS_WeaponIDToAlias(iFrame[newWeapon], sAlias, sizeof(sAlias));
			
			Format(sAlias, sizeof(sAlias), "weapon_%s", sAlias);
			
			if (g_iBotMimicTick[client] > 0 && HasWeapon(client, sAlias))
			{
				weapon = GetWeapon(client, sAlias);
				g_iBotActiveWeapon[client] = weapon;
				SetEntPropEnt(client, Prop_Send, "m_hActiveWeapon", weapon);
				EquipWeapon(client, weapon);
			}
			else
			{
				weapon = GivePlayerItem(client, sAlias);
				if (weapon != INVALID_ENT_REFERENCE)
				{
					g_iBotActiveWeapon[client] = weapon;
					
					// Grenades shouldn't be equipped.
					if (StrContains(sAlias, "grenade") == -1 && StrContains(sAlias, "flashbang") == -1 && StrContains(sAlias, "decoy") == -1 && StrContains(sAlias, "molotov") == -1)
						EquipPlayerWeapon(client, weapon);
					
					SetEntPropEnt(client, Prop_Send, "m_hActiveWeapon", weapon);
					EquipWeapon(client, weapon);
				}
			}
		}
		
		// See if there's a bookmark on this tick
		if (g_iBotMimicTick[client] == g_iBotMimicNextBookmarkTick[client][BWM_frame])
		{
			// Get the file header of the current playing record.
			char sPath[PLATFORM_MAX_PATH];
			GetFileFromFrameHandle(g_hBotMimicsRecord[client], sPath, sizeof(sPath));
			new iFileHeader[FileHeader];
			g_hLoadedRecords.GetArray(sPath, iFileHeader[0], _:FileHeader);
	
			new iBookmark[Bookmarks];
			GetArrayArray(iFileHeader[FH_bookmarks], g_iBotMimicNextBookmarkTick[client][BWM_index], iBookmark[0], _:Bookmarks);
			
			// Cache the next tick in which we should fire the forward.
			UpdateNextBookmarkTick(client);
			
			// Call the forward
			Call_StartForward(g_hfwdOnPlayerMimicBookmark);
			Call_PushCell(client);
			Call_PushString(iBookmark[BKM_name]);
			Call_Finish();
		}
		
		g_iBotMimicTick[client]++;
		
		return Plugin_Changed;
	}
	
	return Plugin_Continue;
}

/**
 * Event Callbacks
 */
public void Event_OnPlayerSpawn(Event event, const char[] name, bool  dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	
	if (client == 0)
		return;
	
	// Restart moving on spawn!
	if (g_hBotMimicsRecord[client] != null)
	{
		g_iBotMimicTick[client] = 0;
		g_iCurrentAdditionalTeleportIndex[client] = 0;
	}
}

public void Event_OnPlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int userid = event.GetInt("userid");
	
	if (GetClientOfUserId(userid) == 0)
		return;
	
	CreateTimer(0.2, Timer_DelayDeath, userid, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_DelayDeath(Handle timer, any data)
{
	int client = GetClientOfUserId(data);
	
	if (client == 0)
		return;
	
	// This one has been recording currently
	if (g_hRecording[client] != null)
		BotMimic_StopRecording(client, true);
	// This bot has been playing one
	else if (g_hBotMimicsRecord[client] != null)
	{
		// Respawn the bot after death!
		g_iBotMimicTick[client] = 0;
		g_iCurrentAdditionalTeleportIndex[client] = 0;
		
		if (GetConVarBool(g_hCVRespawnOnDeath) && GetClientTeam(client) >= CS_TEAM_T)
			CreateTimer(1.0, Timer_DelayedRespawn, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	}
}

/**
 * Timer Callbacks
 */
public Action:Timer_DelayedRespawn(Handle:timer, any:userid)
{
	int client = GetClientOfUserId(userid);
	
	if (client == 0)
		return Plugin_Stop;
	
	if (g_hBotMimicsRecord[client] != null && IsClientInGame(client) && !IsPlayerAlive(client) && IsFakeClient(client) && GetClientTeam(client) >= CS_TEAM_T)
		CS_RespawnPlayer(client);
	
	return Plugin_Stop;
}


/**
 * SDKHooks Callbacks
 */
// Don't allow mimicing players any other weapon than the one recorded!!
public Action:Hook_WeaponCanSwitchTo(client, weapon)
{
	if (g_hBotMimicsRecord[client] == null)
		return Plugin_Continue;
	
	if (g_iBotActiveWeapon[client] != weapon)
		return Plugin_Stop;
	
	return Plugin_Continue;
}

/**
 * DHooks Callbacks
 */
public MRESReturn:DHooks_OnTeleport(client, Handle:hParams)
{
	// This one is currently mimicing something.
	if (g_hBotMimicsRecord[client] != null)
	{
		// We didn't allow that teleporting. STOP THAT.
		if (!g_bValidTeleportCall[client])
			return MRES_Supercede;
		
		g_bValidTeleportCall[client] = false;
		return MRES_Ignored;
	}
	
	// Don't care if he's not recording.
	if (g_hRecording[client] == null)
		return MRES_Ignored;
	
	new Float:origin[3], Float:angles[3], Float:velocity[3];
	bool bOriginNull = DHookIsNullParam(hParams, 1);
	bool bAnglesNull = DHookIsNullParam(hParams, 2);
	bool bVelocityNull = DHookIsNullParam(hParams, 3);
	
	if (!bOriginNull)
		DHookGetParamVector(hParams, 1, origin);
	
	if (!bAnglesNull)
	{
		for (int i=0;i<3;i++)
			angles[i] = DHookGetParamObjectPtrVar(hParams, 2, i*4, ObjectValueType_Float);
	}
	
	if (!bVelocityNull)
		DHookGetParamVector(hParams, 3, velocity);
	
	if (bOriginNull && bAnglesNull && bVelocityNull)
		return MRES_Ignored;
	
	new iAT[AdditionalTeleport];
	CopyArrayToArray(origin, iAT[atOrigin], 3);
	CopyArrayToArray(angles, iAT[atAngles], 3);
	CopyArrayToArray(velocity, iAT[atVelocity], 3);
	
	// Remember, 
	if (!bOriginNull)
		iAT[atFlags] |= ADDITIONAL_FIELD_TELEPORTED_ORIGIN;
	if (!bAnglesNull)
		iAT[atFlags] |= ADDITIONAL_FIELD_TELEPORTED_ANGLES;
	if (!bVelocityNull)
		iAT[atFlags] |= ADDITIONAL_FIELD_TELEPORTED_VELOCITY;
	
	PushArrayArray(g_hRecordingAdditionalTeleport[client], iAT[0], _:AdditionalTeleport);
	
	return MRES_Ignored;
}

/**
 * Natives
 */
public int StartRecording(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return;
	}
	
	if (g_hRecording[client] != null)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Player is already recording.");
		return;
	}
	
	if (g_hBotMimicsRecord[client] != null)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Player is currently mimicing another record.");
		return;
	}
	
	g_hRecording[client] = CreateArray(_:FrameInfo);
	g_hRecordingAdditionalTeleport[client] = CreateArray(_:AdditionalTeleport);
	g_hRecordingBookmarks[client] = CreateArray(_:Bookmarks);
	GetClientAbsOrigin(client, g_fInitialPosition[client]);
	GetClientEyeAngles(client, g_fInitialAngles[client]);
	g_iRecordedTicks[client] = 0;
	g_iOriginSnapshotInterval[client] = 0;
	
	GetNativeString(2, g_sRecordName[client], MAX_RECORD_NAME_LENGTH);
	GetNativeString(3, g_sRecordCategory[client], PLATFORM_MAX_PATH);
	GetNativeString(4, g_sRecordSubDir[client], PLATFORM_MAX_PATH);
	
	if (g_sRecordCategory[client][0] == '\0')
		strcopy(g_sRecordCategory[client], sizeof(g_sRecordCategory[]), DEFAULT_CATEGORY);
	
	// Path:
	// data/botmimic/%CATEGORY%/map_name/%SUBDIR%/record.rec
	// subdir can be omitted, default category is "default"
	
	// All demos reside in the default path (data/botmimic)
	BuildPath(Path_SM, g_sRecordPath[client], PLATFORM_MAX_PATH, "%s%s", DEFAULT_RECORD_FOLDER, g_sRecordCategory[client]);
	
	// Remove trailing slashes
	if (g_sRecordPath[client][strlen(g_sRecordPath[client]) - 1] == '\\' || g_sRecordPath[client][strlen(g_sRecordPath[client]) - 1] == '/')
		g_sRecordPath[client][strlen(g_sRecordPath[client]) - 1] = '\0';
	
	Action result;
	Call_StartForward(g_hfwdOnStartRecording);
	Call_PushCell(client);
	Call_PushString(g_sRecordName[client]);
	Call_PushString(g_sRecordCategory[client]);
	Call_PushString(g_sRecordSubDir[client]);
	Call_PushString(g_sRecordPath[client]);
	Call_Finish(result);
	
	if (result >= Plugin_Handled)
		BotMimic_StopRecording(client, false);
}

public PauseRecording(Handle:plugin, numParams)
{
	int client = GetNativeCell(1);
	
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return;
	}
	
	if (g_hRecording[client] == null)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Player is not recording.");
		return;
	}
	
	if (g_bRecordingPaused[client])
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Recording is already paused.");
		return;
	}
	
	g_bRecordingPaused[client] = true;
	
	Call_StartForward(g_hfwdOnRecordingPauseStateChanged);
	Call_PushCell(client);
	Call_PushCell(true);
	Call_Finish();
}

public ResumeRecording(Handle:plugin, numParams)
{
	int client = GetNativeCell(1);
	
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return;
	}
	
	if (g_hRecording[client] == null)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Player is not recording.");
		return;
	}
	
	if (!g_bRecordingPaused[client])
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Recording is not paused.");
		return;
	}
	
	// Save the new full position, angles and velocity.
	g_bSaveFullSnapshot[client] = true;
	
	g_bRecordingPaused[client] = false;
	
	Call_StartForward(g_hfwdOnRecordingPauseStateChanged);
	Call_PushCell(client);
	Call_PushCell(false);
	Call_Finish();
}

public IsRecordingPaused(Handle:plugin, numParams)
{
	int client = GetNativeCell(1);
	
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return false;
	}
	
	if (g_hRecording[client] == null)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Player is not recording.");
		return false;
	}
	
	return g_bRecordingPaused[client];
}

public StopRecording(Handle:plugin, numParams)
{
	int client = GetNativeCell(1);
	
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return;
	}
	
	// Not recording..
	if (g_hRecording[client] == null)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Player is not recording.");
		return;
	}
	
	bool save = GetNativeCell(2);
	
	new Action:result;
	Call_StartForward(g_hfwdOnStopRecording);
	Call_PushCell(client);
	Call_PushString(g_sRecordName[client]);
	Call_PushString(g_sRecordCategory[client]);
	Call_PushString(g_sRecordSubDir[client]);
	Call_PushString(g_sRecordPath[client]);
	Call_PushCellRef(save);
	Call_Finish(result);
	
	// Don't stop recording?
	if (result >= Plugin_Handled)
		return;
	
	if (save)
	{
		new iEndTime = GetTime();
		
		char sMapName[64]; char sPath[PLATFORM_MAX_PATH];
		GetCurrentMap(sMapName, sizeof(sMapName));
		
		// Check if the default record folder exists?
		BuildPath(Path_SM, sPath, sizeof(sPath), DEFAULT_RECORD_FOLDER);
		// Remove trailing slashes
		if (sPath[strlen(sPath)-1] == '\\' || sPath[strlen(sPath)-1] == '/')
			sPath[strlen(sPath)-1] = '\0';
		
		if (!CheckCreateDirectory(sPath, 511))
			return;
		
		// Check if the category folder exists?
		BuildPath(Path_SM, sPath, sizeof(sPath), "%s%s", DEFAULT_RECORD_FOLDER, g_sRecordCategory[client]);
		if (!CheckCreateDirectory(sPath, 511))
			return;
		
		// Check, if there is a folder for this map already
		Format(sPath, sizeof(sPath), "%s/%s", g_sRecordPath[client], sMapName);
		if (!CheckCreateDirectory(sPath, 511))
			return;
		
		// Check if the subdirectory exists
		if (g_sRecordSubDir[client][0] != '\0')
		{
			Format(sPath, sizeof(sPath), "%s/%s", sPath, g_sRecordSubDir[client]);
			
			if (!CheckCreateDirectory(sPath, 511))
				return;
		}
		
		Format(sPath, sizeof(sPath), "%s/%d.rec", sPath, iEndTime);
		
		// Add to our loaded record list
		new iHeader[FileHeader];
		iHeader[FH_binaryFormatVersion] = BINARY_FORMAT_VERSION;
		iHeader[FH_recordEndTime] = iEndTime;
		iHeader[FH_tickCount] = GetArraySize(g_hRecording[client]);
		strcopy(iHeader[FH_recordName], MAX_RECORD_NAME_LENGTH, g_sRecordName[client]);
		CopyArrayToArray(g_fInitialPosition[client], iHeader[FH_initialPosition], 3);
		CopyArrayToArray(g_fInitialAngles[client], iHeader[FH_initialAngles], 3);
		iHeader[FH_frames] = g_hRecording[client];
		
		iHeader[FH_bookmarkCount] = GetArraySize(g_hRecordingBookmarks[client]);
		iHeader[FH_bookmarks] = g_hRecordingBookmarks[client];
		
		if (GetArraySize(g_hRecordingAdditionalTeleport[client]) > 0)
			g_hLoadedRecordsAdditionalTeleport.SetValue(sPath, g_hRecordingAdditionalTeleport[client]);
		else
			delete g_hRecordingAdditionalTeleport[client];
		
		WriteRecordToDisk(sPath, iHeader);
		
		g_hLoadedRecords.SetArray(sPath, iHeader[0], _:FileHeader);
		g_hLoadedRecordsCategory.SetString(sPath, g_sRecordCategory[client]);
		g_hSortedRecordList.PushString(sPath);
		if (g_hSortedCategoryList.FindString(g_sRecordCategory[client]) == -1)
			g_hSortedCategoryList.PushString(g_sRecordCategory[client]);
		SortRecordList();
		
		Call_StartForward(g_hfwdOnRecordSaved);
		Call_PushCell(client);
		Call_PushString(g_sRecordName[client]);
		Call_PushString(g_sRecordCategory[client]);
		Call_PushString(g_sRecordSubDir[client]);
		Call_PushString(sPath);
		Call_Finish();
	}
	else
	{
		delete g_hRecording[client];
		delete g_hRecordingAdditionalTeleport[client];
		delete g_hRecordingBookmarks[client];
	}
	
	g_hRecording[client] = null;
	g_hRecordingAdditionalTeleport[client] = null;
	g_hRecordingBookmarks[client] = null;
	g_iRecordedTicks[client] = 0;
	g_iRecordPreviousWeapon[client] = 0;
	g_sRecordName[client][0] = 0;
	g_sRecordPath[client][0] = 0;
	g_sRecordCategory[client][0] = 0;
	g_sRecordSubDir[client][0] = 0;
	g_iCurrentAdditionalTeleportIndex[client] = 0;
	g_iOriginSnapshotInterval[client] = 0;
	g_bRecordingPaused[client] = false;
	g_bSaveFullSnapshot[client] = false;
}

public SaveBookmark(Handle:plugin, numParams)
{
	int client = GetNativeCell(1);
	
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return;
	}
	
	// Not recording..
	if (g_hRecording[client] == null)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Player is not recording.");
		return;
	}
	
	char sBookmarkName[MAX_BOOKMARK_NAME_LENGTH];
	GetNativeString(2, sBookmarkName, sizeof(sBookmarkName));
	
	// First check if there already is a bookmark with this name
	new iBookmark[Bookmarks];
	new iSize = GetArraySize(g_hRecordingBookmarks[client]);
	for (int i=0;i<iSize;i++)
	{
		GetArrayArray(g_hRecordingBookmarks[client], i, iBookmark[0], _:Bookmarks);
		if (StrEqual(iBookmark[BKM_name], sBookmarkName, false))
		{
			ThrowNativeError(SP_ERROR_NATIVE, "There already is a bookmark named \"%s\".", sBookmarkName);
			return;
		}
	}
	
	// Save the current state so it can be restored when jumping to that frame.
	new iAT[AdditionalTeleport], Float:fBuffer[3];
	GetClientAbsOrigin(client, fBuffer);
	CopyArrayToArray(fBuffer, iAT[atOrigin], 3);
	GetClientEyeAngles(client, fBuffer);
	CopyArrayToArray(fBuffer, iAT[atAngles], 3);
	GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", fBuffer);
	CopyArrayToArray(fBuffer, iAT[atVelocity], 3);
	
	iAT[atFlags] = ADDITIONAL_FIELD_TELEPORTED_ORIGIN|ADDITIONAL_FIELD_TELEPORTED_ANGLES|ADDITIONAL_FIELD_TELEPORTED_VELOCITY;
	
	new iFrame[FrameInfo];
	GetArrayArray(g_hRecording[client], g_iRecordedTicks[client]-1, iFrame[0], _:FrameInfo);
	// There already is some Teleport call saved this frame :(
	if ((iFrame[additionalFields] & iAT[atFlags]) != 0)
	{
		// Purge it and replace it with this one as we might have more information.
		SetArrayArray(g_hRecordingAdditionalTeleport[client], g_iCurrentAdditionalTeleportIndex[client]-1, iAT[0], _:AdditionalTeleport);
	}
	else
	{
		PushArrayArray(g_hRecordingAdditionalTeleport[client], iAT[0], _:AdditionalTeleport);
		g_iCurrentAdditionalTeleportIndex[client]++;
	}
	// Remember, we were teleported this frame!
	iFrame[additionalFields] |= iAT[atFlags];
	
	new iWeapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (iWeapon != INVALID_ENT_REFERENCE && iFrame[newWeapon] == CSWeapon_NONE && IsValidEntity(iWeapon))
	{
		char sClassName[64];
		GetEntityClassname(iWeapon, sClassName, sizeof(sClassName));
		ReplaceString(sClassName, sizeof(sClassName), "weapon_", "", false);
		
		char sWeaponAlias[64];
		CS_GetTranslatedWeaponAlias(sClassName, sWeaponAlias, sizeof(sWeaponAlias));
		new CSWeaponID:weaponId = CS_AliasToWeaponID(sWeaponAlias);
		iFrame[newWeapon] = weaponId;
	}
	
	SetArrayArray(g_hRecording[client], g_iRecordedTicks[client]-1, iFrame[0], _:FrameInfo);
	
	// Save the bookmark
	iBookmark[BKM_frame] = g_iRecordedTicks[client]-1;
	iBookmark[BKM_additionalTeleportTick] = g_iCurrentAdditionalTeleportIndex[client]-1;
	strcopy(iBookmark[BKM_name], MAX_BOOKMARK_NAME_LENGTH, sBookmarkName);
	PushArrayArray(g_hRecordingBookmarks[client], iBookmark[0], _:Bookmarks);
	
	// Inform other plugins, that there's been a bookmark saved.
	Call_StartForward(g_hfwdOnRecordingBookmarkSaved);
	Call_PushCell(client);
	Call_PushString(sBookmarkName);
	Call_Finish();
}

public DeleteRecord(Handle:plugin, numParams)
{
	new iLen;
	GetNativeStringLength(1, iLen);
	char[] sPath = new char[iLen+1];
	GetNativeString(1, sPath, iLen+1);
	
	// Do we have this record loaded?
	new iFileHeader[FileHeader];
	if (!g_hLoadedRecords.GetArray(sPath, iFileHeader[0], _:FileHeader))
	{
		if (!FileExists(sPath))
			return -1;
		
		// Try to load it to make sure it's a record file we're deleting here!
		new BMError:error = LoadRecordFromFile(sPath, DEFAULT_CATEGORY, iFileHeader, true, false);
		if (error == BM_FileNotFound || error == BM_BadFile)
			return -1;
	}
	
	new iCount;
	if (iFileHeader[FH_frames] != null)
	{
		for (int i=1;i<=MaxClients;i++)
		{
			// Stop the bots from mimicing this one
			if (g_hBotMimicsRecord[i] == iFileHeader[FH_frames])
			{
				BotMimic_StopPlayerMimic(i);
				iCount++;
			}
		}
		
		// Discard the frames
		delete iFileHeader[FH_frames];
	}
	
	delete iFileHeader[FH_bookmarks];
	
	char sCategory[64];
	g_hLoadedRecordsCategory.GetString(sPath, sCategory, sizeof(sCategory));
	
	g_hLoadedRecords.Remove(sPath);
	g_hLoadedRecordsCategory.Remove(sPath);
	g_hSortedRecordList.Erase 	
	(g_hSortedRecordList.FindString(sPath));
	
	Handle hAT;
	if (g_hLoadedRecordsAdditionalTeleport.GetValue(sPath, hAT))
		delete hAT;
	
	g_hLoadedRecordsAdditionalTeleport.Remove(sPath);
	
	// Delete the file
	if (FileExists(sPath))
		DeleteFile(sPath);
	
	Call_StartForward(g_hfwdOnRecordDeleted);
	Call_PushString(iFileHeader[FH_recordName]);
	Call_PushString(sCategory);
	Call_PushString(sPath);
	Call_Finish();
	
	return iCount;
}

public IsPlayerRecording(Handle:plugin, numParams)
{
	int client = GetNativeCell(1);
	
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return false;
	}
	
	return g_hRecording[client] != null;
}

public IsPlayerMimicing(Handle:plugin, numParams)
{
	int client = GetNativeCell(1);
	
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return false;
	}
	
	return g_hBotMimicsRecord[client] != null;
}

public GetRecordPlayerMimics(Handle:plugin, numParams)
{
	int client = GetNativeCell(1);
	
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return;
	}
	
	if (!BotMimic_IsPlayerMimicing(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Player is not mimicing.");
		return;
	}
	
	new iLen = GetNativeCell(3);
	char[] sPath = new char[iLen];
	GetFileFromFrameHandle(g_hBotMimicsRecord[client], sPath, iLen);
	SetNativeString(2, sPath, iLen);
}

public GoToBookmark(Handle:plugin, numParams)
{
	int client = GetNativeCell(1);
	
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return;
	}
	
	if (!BotMimic_IsPlayerMimicing(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Player is not mimicing.");
		return;
	}
	
	char sBookmarkName[MAX_BOOKMARK_NAME_LENGTH];
	GetNativeString(2, sBookmarkName, sizeof(sBookmarkName));
	
	// Get the file header
	char sPath[PLATFORM_MAX_PATH];
	GetFileFromFrameHandle(g_hBotMimicsRecord[client], sPath, sizeof(sPath));
	
	new iFileHeader[FileHeader];
	g_hLoadedRecords.GetArray(sPath, iFileHeader[0], _:FileHeader);
	
	// Get the bookmark with this name
	new iBookmark[Bookmarks], bool:bBookmarkFound, iBookmarkIndex;
	for (;iBookmarkIndex<iFileHeader[FH_bookmarkCount];iBookmarkIndex++)
	{
		GetArrayArray(iFileHeader[FH_bookmarks], iBookmarkIndex, iBookmark[0], _:Bookmarks);
		if (StrEqual(iBookmark[BKM_name], sBookmarkName, false))
		{
			bBookmarkFound = true;
			break;
		}
	}
	
	if (!bBookmarkFound)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "There is no bookmark named \"%s\" in this record.", sBookmarkName);
		return;
	}
	
	g_iBotMimicTick[client] = iBookmark[BKM_frame];
	g_iCurrentAdditionalTeleportIndex[client] = iBookmark[BKM_additionalTeleportTick];
	
	// Remember that we're now at this bookmark.
	g_iBotMimicNextBookmarkTick[client][BWM_frame] = iBookmark[BKM_frame];
	g_iBotMimicNextBookmarkTick[client][BWM_index] = iBookmarkIndex;
}

public StopPlayerMimic(Handle:plugin, numParams)
{
	int client = GetNativeCell(1);
	
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return;
	}
	
	if (!BotMimic_IsPlayerMimicing(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Player is not mimicing.");
		return;
	}
	
	char sPath[PLATFORM_MAX_PATH];
	GetFileFromFrameHandle(g_hBotMimicsRecord[client], sPath, sizeof(sPath));
	
	g_hBotMimicsRecord[client] = null;
	g_iBotMimicTick[client] = 0;
	g_iCurrentAdditionalTeleportIndex[client] = 0;
	g_iBotMimicRecordTickCount[client] = 0;
	g_bValidTeleportCall[client] = false;
	g_iBotMimicNextBookmarkTick[client][BWM_frame] = -1;
	g_iBotMimicNextBookmarkTick[client][BWM_index] = -1;
	
	new iFileHeader[FileHeader];
	g_hLoadedRecords.GetArray(sPath, iFileHeader[0], _:FileHeader);
	
	SDKUnhook(client, SDKHook_WeaponCanSwitchTo, Hook_WeaponCanSwitchTo);
	
	char sCategory[64];
	g_hLoadedRecordsCategory.GetString(sPath, sCategory, sizeof(sCategory));
	
	Call_StartForward(g_hfwdOnPlayerStopsMimicing);
	Call_PushCell(client);
	Call_PushString(iFileHeader[FH_recordName]);
	Call_PushString(sCategory);
	Call_PushString(sPath);
	Call_Finish();
}

public PlayRecordFromFile(Handle:plugin, numParams)
{
	int client = GetNativeCell(1);
	
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
		return _:BM_BadClient;
	
	new iLen;
	GetNativeStringLength(2, iLen);
	char[] sPath = new char[iLen+1];
	GetNativeString(2, sPath, iLen+1);
	
	if (!FileExists(sPath))
		return _:BM_FileNotFound;
	
	int start = GetNativeCell(3);
	
	return _:PlayRecord(client, sPath, start);
}

public PlayRecordByName(Handle:plugin, numParams)
{
	int client = GetNativeCell(1);
	
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
		return _:BM_BadClient;
	
	new iLen;
	GetNativeStringLength(2, iLen);
	char[] sName = new char[iLen+1];
	GetNativeString(2, sName, iLen+1);
	
	char sPath[PLATFORM_MAX_PATH];
	new iSize = g_hSortedRecordList.Length;
	new iFileHeader[FileHeader], iRecentTimeStamp; char sRecentPath[PLATFORM_MAX_PATH];
	for (int i=0;i<iSize;i++)
	{
		g_hSortedRecordList.GetString(i, sPath, sizeof(sPath));
		g_hLoadedRecords.GetArray(sPath, iFileHeader[0], _:FileHeader);
		if (StrEqual(sName, iFileHeader[FH_recordName]))
		{
			if (iRecentTimeStamp == 0 || iRecentTimeStamp < iFileHeader[FH_recordEndTime])
			{
				iRecentTimeStamp = iFileHeader[FH_recordEndTime];
				strcopy(sRecentPath, sizeof(sRecentPath), sPath);
			}
		}
	}
	
	if (!iRecentTimeStamp || !FileExists(sRecentPath))
		return _:BM_FileNotFound;
	
	int start = GetNativeCell(3);
	
	return _:PlayRecord(client, sRecentPath, start);
}

public ResetPlayback(Handle:plugin, numParams)
{
	int client = GetNativeCell(1);
	
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Bad player index %d", client);
		return;
	}
	
	if (!BotMimic_IsPlayerMimicing(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Player is not mimicing.");
		return;
	}
	
	g_iBotMimicTick[client] = 0;
	g_iCurrentAdditionalTeleportIndex[client] = 0;
	g_bValidTeleportCall[client] = false;
	g_iBotMimicNextBookmarkTick[client][BWM_frame] = -1;
	g_iBotMimicNextBookmarkTick[client][BWM_index] = -1;
	UpdateNextBookmarkTick(client);
}

public GetFileHeaders(Handle:plugin, numParams)
{
	new iLen;
	GetNativeStringLength(1, iLen);
	char[] sPath = new char[iLen+1];
	GetNativeString(1, sPath, iLen+1);
	
	if (!FileExists(sPath))
		return _:BM_FileNotFound;
	
	new iFileHeader[FileHeader];
	if (!g_hLoadedRecords.GetArray(sPath, iFileHeader[0], _:FileHeader))
	{
		char sCategory[64];
		if (!g_hLoadedRecordsCategory.GetString(sPath, sCategory, sizeof(sCategory)))
			strcopy(sCategory, sizeof(sCategory), DEFAULT_CATEGORY);
		new BMError:error = LoadRecordFromFile(sPath, sCategory, iFileHeader, true, false);
		if (error != BM_NoError)
			return _:error;
	}
	
	new iExposedFileHeader[BMFileHeader];
	iExposedFileHeader[BMFH_binaryFormatVersion] = iFileHeader[FH_binaryFormatVersion];
	iExposedFileHeader[BMFH_recordEndTime] = iFileHeader[FH_recordEndTime];
	strcopy(iExposedFileHeader[BMFH_recordName], MAX_RECORD_NAME_LENGTH, iFileHeader[FH_recordName]);
	iExposedFileHeader[BMFH_tickCount] = iFileHeader[FH_tickCount];
	CopyArrayToArray(iFileHeader[BMFH_initialPosition], iExposedFileHeader[FH_initialPosition], 3);
	CopyArrayToArray(iFileHeader[BMFH_initialAngles], iExposedFileHeader[FH_initialAngles], 3);
	iExposedFileHeader[BMFH_bookmarkCount] = iFileHeader[FH_bookmarkCount];
	
	
	new iSize = _:BMFileHeader;
	if (numParams > 2)
		iSize = GetNativeCell(3);
	if (iSize > _:BMFileHeader)
		iSize = _:BMFileHeader;
	
	SetNativeArray(2, iExposedFileHeader[0], iSize);
	return _:BM_NoError;
}

public ChangeRecordName(Handle:plugin, numParams)
{
	new iLen;
	GetNativeStringLength(1, iLen);
	char[] sPath = new char[iLen+1];
	GetNativeString(1, sPath, iLen+1);
	
	if (!FileExists(sPath))
		return _:BM_FileNotFound;
	
	char sCategory[64];
	if (!g_hLoadedRecordsCategory.GetString(sPath, sCategory, sizeof(sCategory)))
		strcopy(sCategory, sizeof(sCategory), DEFAULT_CATEGORY);
	
	new iFileHeader[FileHeader];
	if (!g_hLoadedRecords.GetArray(sPath, iFileHeader[0], _:FileHeader))
	{
		new BMError:error = LoadRecordFromFile(sPath, sCategory, iFileHeader, false, false);
		if (error != BM_NoError)
			return _:error;
	}
	
	// Load the whole record first or we'd lose the frames!
	if (iFileHeader[FH_frames] == null)
		LoadRecordFromFile(sPath, sCategory, iFileHeader, false, true);
	
	GetNativeStringLength(2, iLen);
	char[] sName = new char[iLen+1];
	GetNativeString(2, sName, iLen+1);
	
	strcopy(iFileHeader[FH_recordName], MAX_RECORD_NAME_LENGTH, sName);
	g_hLoadedRecords.SetArray(sPath, iFileHeader[0], _:FileHeader);
	
	WriteRecordToDisk(sPath, iFileHeader);
	
	return _:BM_NoError;
}

public GetLoadedRecordCategoryList(Handle:plugin, numParams)
{
	return _:g_hSortedCategoryList;
}

public GetLoadedRecordList(Handle:plugin, numParams)
{
	return _:g_hSortedRecordList;
}

public GetFileCategory(Handle:plugin, numParams)
{
	new iLen;
	GetNativeStringLength(1, iLen);
	char[] sPath = new char[iLen+1];
	GetNativeString(1, sPath, iLen+1);
	
	iLen = GetNativeCell(3);
	char[] sCategory = new char[iLen];
	bool bFound = g_hLoadedRecordsCategory.GetString(sPath, sCategory, iLen);
	
	SetNativeString(2, sCategory, iLen);
	return _:bFound;
}

public GetRecordBookmarks(Handle:plugin, numParams)
{
	new iLen;
	GetNativeStringLength(1, iLen);
	char[] sPath = new char[iLen+1];
	GetNativeString(1, sPath, iLen+1);
	
	if (!FileExists(sPath))
		return _:BM_FileNotFound;
	
	new iFileHeader[FileHeader];
	if (!g_hLoadedRecords.GetArray(sPath, iFileHeader[0], _:FileHeader))
	{
		char sCategory[64];
		if (!g_hLoadedRecordsCategory.GetString(sPath, sCategory, sizeof(sCategory)))
			strcopy(sCategory, sizeof(sCategory), DEFAULT_CATEGORY);
		new BMError:error = LoadRecordFromFile(sPath, sCategory, iFileHeader, true, false);
		if (error != BM_NoError)
			return _:error;
	}
	
	new Handle:hBookmarks = CreateArray(ByteCountToCells(MAX_BOOKMARK_NAME_LENGTH));
	new iBookmark[Bookmarks];
	for (int i=0;i<iFileHeader[FH_bookmarkCount];i++)
	{
		GetArrayArray(iFileHeader[FH_bookmarks], i, iBookmark[0], _:Bookmarks);
		PushArrayString(hBookmarks, iBookmark[BKM_name]);
	}
	
	SetNativeCellRef(2, hBookmarks);
	return _:BM_NoError;
}


/**
 * Helper functions
 */

ParseRecordsInDirectory(const char[] sPath, const char[] sCategory, bool subdir)
{
	char sMapFilePath[PLATFORM_MAX_PATH];
	// We already are in the map folder? Don't add it again!
	if (subdir)
		strcopy(sMapFilePath, sizeof(sMapFilePath), sPath);
	// We're in a category. add the mapname to load the correct records for the current map
	else
	{
		char sMapName[64];
		GetCurrentMap(sMapName, sizeof(sMapName));
		Format(sMapFilePath, sizeof(sMapFilePath), "%s/%s", sPath, sMapName);
	}
	
	Handle hDir = OpenDirectory(sMapFilePath);
	
	if (hDir == null)
		return;
	
	char sFile[64]; FileType fileType; char sFilePath[PLATFORM_MAX_PATH];
	new iFileHeader[FileHeader];
	while(ReadDirEntry(hDir, sFile, sizeof(sFile), fileType))
	{
		switch(fileType)
		{
			// This is a record for this map.
			case FileType_File:
			{
				Format(sFilePath, sizeof(sFilePath), "%s/%s", sMapFilePath, sFile);
				LoadRecordFromFile(sFilePath, sCategory, iFileHeader, true, false);
			}
			// There's a subdir containing more records.
			case FileType_Directory:
			{
				// INFINITE RECURSION ANYONE?
				if (StrEqual(sFile, ".") || StrEqual(sFile, ".."))
					continue;
				
				Format(sFilePath, sizeof(sFilePath), "%s/%s", sMapFilePath, sFile);
				ParseRecordsInDirectory(sFilePath, sCategory, true);
			}
		}
	}
	
	delete hDir;
}

WriteRecordToDisk(const char[] sPath, iFileHeader[FileHeader])
{
	Handle hFile = OpenFile(sPath, "wb");
	
	if (hFile == null)
	{
		LogError("Can't open the record file for writing! (%s)", sPath);
		return;
	}
	
	WriteFileCell(hFile, BM_MAGIC, 4);
	WriteFileCell(hFile, iFileHeader[FH_binaryFormatVersion], 1);
	WriteFileCell(hFile, iFileHeader[FH_recordEndTime], 4);
	WriteFileCell(hFile, strlen(iFileHeader[FH_recordName]), 1);
	WriteFileString(hFile, iFileHeader[FH_recordName], false);
	
	WriteFile(hFile, _:iFileHeader[FH_initialPosition], 3, 4);
	WriteFile(hFile, _:iFileHeader[FH_initialAngles], 2, 4);
	
	new Handle:hAdditionalTeleport, iATIndex;
	g_hLoadedRecordsAdditionalTeleport.GetValue(sPath, hAdditionalTeleport);
	
	new iTickCount = iFileHeader[FH_tickCount];
	WriteFileCell(hFile, iTickCount, 4);
	
	new iBookmarkCount = iFileHeader[FH_bookmarkCount];
	WriteFileCell(hFile, iBookmarkCount, 4);
	
	// Write all bookmarks
	new Handle:hBookmarks = iFileHeader[FH_bookmarks];
	
	new iBookmark[Bookmarks];
	for (int i=0;i<iBookmarkCount;i++)
	{
		GetArrayArray(hBookmarks, i, iBookmark[0], _:Bookmarks);
		
		WriteFileCell(hFile, iBookmark[BKM_frame], 4);
		WriteFileCell(hFile, iBookmark[BKM_additionalTeleportTick], 4);
		WriteFileString(hFile, iBookmark[BKM_name], true);
	}
	
	new iFrame[FrameInfo];
	for (int i=0;i<iTickCount;i++)
	{
		GetArrayArray(iFileHeader[FH_frames], i, iFrame[0], _:FrameInfo);
		WriteFile(hFile, iFrame[0], _:FrameInfo, 4);
		
		// Handle the optional Teleport call
		if (hAdditionalTeleport != null && iFrame[additionalFields] & (ADDITIONAL_FIELD_TELEPORTED_ORIGIN|ADDITIONAL_FIELD_TELEPORTED_ANGLES|ADDITIONAL_FIELD_TELEPORTED_VELOCITY))
		{
			new iAT[AdditionalTeleport];
			GetArrayArray(hAdditionalTeleport, iATIndex, iAT[0], _:AdditionalTeleport);
			if (iFrame[additionalFields] & ADDITIONAL_FIELD_TELEPORTED_ORIGIN)
				WriteFile(hFile, _:iAT[atOrigin], 3, 4);
			if (iFrame[additionalFields] & ADDITIONAL_FIELD_TELEPORTED_ANGLES)
				WriteFile(hFile, _:iAT[atAngles], 3, 4);
			if (iFrame[additionalFields] & ADDITIONAL_FIELD_TELEPORTED_VELOCITY)
				WriteFile(hFile, _:iAT[atVelocity], 3, 4);
			iATIndex++;
		}
	}
	
	delete hFile;
}

BMError:LoadRecordFromFile(const char[] path, const char[] sCategory, headerInfo[FileHeader], bool onlyHeader, bool forceReload)
{
	if (!FileExists(path))
		return BM_FileNotFound;
	
	// Already loaded that file?
	bool bAlreadyLoaded;
	if (g_hLoadedRecords.GetArray(path, headerInfo[0], _:FileHeader))
	{
		// Header already loaded.
		if (onlyHeader && !forceReload)
			return BM_NoError;
		
		bAlreadyLoaded = true;
	}
	
	Handle hFile = OpenFile(path, "rb");
	
	if (hFile == null)
		return BM_FileNotFound;
	
	new iMagic;
	ReadFileCell(hFile, iMagic, 4);
	
	if (iMagic != BM_MAGIC)
	{
		delete hFile;
		return BM_BadFile;
	}
	
	new iBinaryFormatVersion;
	ReadFileCell(hFile, iBinaryFormatVersion, 1);
	headerInfo[FH_binaryFormatVersion] = iBinaryFormatVersion;
	
	if (iBinaryFormatVersion > BINARY_FORMAT_VERSION)
	{
		delete hFile;
		return BM_NewerBinaryVersion;
	}
	
	new iRecordTime, iNameLength;
	ReadFileCell(hFile, iRecordTime, 4);
	ReadFileCell(hFile, iNameLength, 1);
	char[] sRecordName = new char[iNameLength+1];
	ReadFileString(hFile, sRecordName, iNameLength+1, iNameLength);
	sRecordName[iNameLength] = '\0';
	
	ReadFile(hFile, _:headerInfo[FH_initialPosition], 3, 4);
	ReadFile(hFile, _:headerInfo[FH_initialAngles], 2, 4);
	
	new iTickCount;
	ReadFileCell(hFile, iTickCount, 4);
	
	new iBookmarkCount;
	
	if (iBinaryFormatVersion >= 0x02)
		ReadFileCell(hFile, iBookmarkCount, 4);
	
	headerInfo[FH_bookmarkCount] = iBookmarkCount;
	
	headerInfo[FH_recordEndTime] = iRecordTime;
	strcopy(headerInfo[FH_recordName], MAX_RECORD_NAME_LENGTH, sRecordName);
	headerInfo[FH_tickCount] = iTickCount;

	headerInfo[FH_frames] = null;
	
	//PrintToServer("Record %s:", sRecordName);
	//PrintToServer("File %s:", path);
	//PrintToServer("EndTime: %d, BinaryVersion: 0x%x, ticks: %d, initialPosition: %f,%f,%f, initialAngles: %f,%f,%f", iRecordTime, iBinaryFormatVersion, iTickCount, headerInfo[FH_initialPosition][0], headerInfo[FH_initialPosition][1], headerInfo[FH_initialPosition][2], headerInfo[FH_initialAngles][0], headerInfo[FH_initialAngles][1], headerInfo[FH_initialAngles][2]);
	
	// Read in all bookmarks
	new Handle:hBookmarks = CreateArray(_:Bookmarks);
	
	new iBookmark[Bookmarks];
	for (int i=0;i<iBookmarkCount;i++)
	{
		ReadFileCell(hFile, iBookmark[BKM_frame], 4);
		ReadFileCell(hFile, iBookmark[BKM_additionalTeleportTick], 4);
		ReadFileString(hFile, iBookmark[BKM_name], MAX_BOOKMARK_NAME_LENGTH);
		PushArrayArray(hBookmarks, iBookmark[0], _:Bookmarks);
	}
	
	headerInfo[FH_bookmarks] = hBookmarks;
	
	g_hLoadedRecords.SetArray(path, headerInfo[0], _:FileHeader);
	g_hLoadedRecordsCategory.SetString(path, sCategory);
	
	if (!bAlreadyLoaded)
		g_hSortedRecordList.PushString(path);
	
	if (g_hSortedCategoryList.FindString(sCategory) == -1)
		g_hSortedCategoryList.PushString(sCategory);
	
	// Sort it by record end time
	SortRecordList();
	
	if (onlyHeader)
	{
		delete hFile;
		return BM_NoError;
	}
	
	// Read in all the saved frames
	new Handle:hRecordFrames = CreateArray(_:FrameInfo);
	new Handle:hAdditionalTeleport = CreateArray(_:AdditionalTeleport);
	
	new iFrame[FrameInfo];
	for (int i=0;i<iTickCount;i++)
	{
		ReadFile(hFile, iFrame[0], _:FrameInfo, 4);
		PushArrayArray(hRecordFrames, iFrame[0], _:FrameInfo);
		
		if (iFrame[additionalFields] & (ADDITIONAL_FIELD_TELEPORTED_ORIGIN|ADDITIONAL_FIELD_TELEPORTED_ANGLES|ADDITIONAL_FIELD_TELEPORTED_VELOCITY))
		{
			new iAT[AdditionalTeleport];
			
			if (iFrame[additionalFields] & ADDITIONAL_FIELD_TELEPORTED_ORIGIN)
				ReadFile(hFile, _:iAT[atOrigin], 3, 4);
			
			if (iFrame[additionalFields] & ADDITIONAL_FIELD_TELEPORTED_ANGLES)
				ReadFile(hFile, _:iAT[atAngles], 3, 4);
			
			if (iFrame[additionalFields] & ADDITIONAL_FIELD_TELEPORTED_VELOCITY)
				ReadFile(hFile, _:iAT[atVelocity], 3, 4);
			
			iAT[atFlags] = iFrame[additionalFields] & (ADDITIONAL_FIELD_TELEPORTED_ORIGIN|ADDITIONAL_FIELD_TELEPORTED_ANGLES|ADDITIONAL_FIELD_TELEPORTED_VELOCITY);
			PushArrayArray(hAdditionalTeleport, iAT[0], _:AdditionalTeleport);
		}
	}
	
	headerInfo[FH_frames] = hRecordFrames;
	
	g_hLoadedRecords.SetArray(path, headerInfo[0], _:FileHeader);
	if (GetArraySize(hAdditionalTeleport) > 0)
		g_hLoadedRecordsAdditionalTeleport.SetValue(path, hAdditionalTeleport);
	
	delete hFile;
	return BM_NoError;
}

SortRecordList()
{
	SortADTArrayCustom(g_hSortedRecordList, SortFuncADT_ByEndTime);
	SortADTArray(g_hSortedCategoryList, Sort_Descending, Sort_String);
}

public SortFuncADT_ByEndTime(index1, index2, Handle:array, Handle:hndl)
{
	char path1[PLATFORM_MAX_PATH]; char path2[PLATFORM_MAX_PATH];
	GetArrayString(array, index1, path1, sizeof(path1));
	GetArrayString(array, index2, path2, sizeof(path2));
	
	new header1[FileHeader], header2[FileHeader];
	g_hLoadedRecords.GetArray(path1, header1[0], _:FileHeader);
	g_hLoadedRecords.GetArray(path2, header2[0], _:FileHeader);
	
	return header1[FH_recordEndTime] - header2[FH_recordEndTime];
}

BMError:PlayRecord(int client, const char[] path, int start = 0)
{
	// He's currently recording. Don't start to play some record on him at the same time.
	if (g_hRecording[client] != null)
		return BM_BadClient;
	
	new iFileHeader[FileHeader];
	g_hLoadedRecords.GetArray(path, iFileHeader[0], _:FileHeader);
	
	// That record isn't fully loaded yet. Do that now.
	if (iFileHeader[FH_frames] == null)
	{
		char sCategory[64];
		
		if (!g_hLoadedRecordsCategory.GetString(path, sCategory, sizeof(sCategory)))
			strcopy(sCategory, sizeof(sCategory), DEFAULT_CATEGORY);
		
		new BMError:error = LoadRecordFromFile(path, sCategory, iFileHeader, false, true);
		
		if (error != BM_NoError)
			return error;
	}
	
	if (start > 0)
		g_bBotMimicStart[client] = true;
	
	g_hBotMimicsRecord[client] = iFileHeader[FH_frames];
	g_iBotMimicTick[client] = start;
	g_iBotMimicRecordTickCount[client] = iFileHeader[FH_tickCount];
	g_iCurrentAdditionalTeleportIndex[client] = 0;
	
	// Cache at which tick we should fire the first OnPlayerMimicBookmark forward.
	g_iBotMimicNextBookmarkTick[client][BWM_frame] = -1;
	g_iBotMimicNextBookmarkTick[client][BWM_index] = -1;
	UpdateNextBookmarkTick(client);
	
	CopyArrayToArray(iFileHeader[FH_initialPosition], g_fInitialPosition[client], 3);
	CopyArrayToArray(iFileHeader[FH_initialAngles], g_fInitialAngles[client], 3);
	
	SDKHook(client, SDKHook_WeaponCanSwitchTo, Hook_WeaponCanSwitchTo);
	
	// Respawn him to get him moving!
	if (IsClientInGame(client) && !IsPlayerAlive(client) && GetClientTeam(client) >= CS_TEAM_T)
		CS_RespawnPlayer(client);
	
	char sCategory[64];
	g_hLoadedRecordsCategory.GetString(path, sCategory, sizeof(sCategory));
	
	Action result;
	Call_StartForward(g_hfwdOnPlayerStartsMimicing);
	Call_PushCell(client);
	Call_PushString(iFileHeader[FH_recordName]);
	Call_PushString(sCategory);
	Call_PushString(path);
	Call_Finish(result);
	
	// Someone doesn't want this guy to play that record.
	if (result >= Plugin_Handled)
	{
		g_hBotMimicsRecord[client] = null;
		g_iBotMimicRecordTickCount[client] = 0;
		g_iBotMimicNextBookmarkTick[client][BWM_frame] = -1;
		g_iBotMimicNextBookmarkTick[client][BWM_index] = -1;
	}
	
	return BM_NoError;
}

// Find the next frame in which a bookmark was saved, so the OnPlayerMimicBookmark forward can be called.
UpdateNextBookmarkTick(client)
{
	// Not mimicing anything.
	if (g_hBotMimicsRecord[client] == null)
		return;
	
	char sPath[PLATFORM_MAX_PATH];
	GetFileFromFrameHandle(g_hBotMimicsRecord[client], sPath, sizeof(sPath));
	
	new iFileHeader[FileHeader];
	g_hLoadedRecords.GetArray(sPath, iFileHeader[0], _:FileHeader);
	
	if (iFileHeader[FH_bookmarks] == null)
		return;
	
	new iSize = GetArraySize(iFileHeader[FH_bookmarks]);
	
	if (iSize == 0)
		return;
	
	new iCurrentIndex = g_iBotMimicNextBookmarkTick[client][BWM_index];
	// We just reached some bookmark regularly and want to proceed to wait for the next one sequentially.
	// If there is no further bookmarks, restart from the first one.
	iCurrentIndex++;
	if (iCurrentIndex >= iSize)
		iCurrentIndex = 0;
	
	new iBookmark[Bookmarks];
	GetArrayArray(iFileHeader[FH_bookmarks], iCurrentIndex, iBookmark[0], _:Bookmarks);
	
	g_iBotMimicNextBookmarkTick[client][BWM_frame] = iBookmark[BKM_frame];
	g_iBotMimicNextBookmarkTick[client][BWM_index] = iCurrentIndex;
}

stock bool:CheckCreateDirectory(const char[] sPath, mode)
{
	if (!DirExists(sPath))
	{
		CreateDirectory(sPath, mode);
		
		if (!DirExists(sPath))
		{
			LogError("Can't create a new directory. Please create one manually! (%s)", sPath);
			return false;
		}
	}
	
	return true;
}

stock GetFileFromFrameHandle(Handle:frames, char[] path, maxlen)
{
	new iSize = g_hSortedRecordList.Length;
	char sPath[PLATFORM_MAX_PATH];
	new iFileHeader[FileHeader];
	for (int i=0;i<iSize;i++)
	{
		g_hSortedRecordList.GetString(i, sPath, sizeof(sPath));
		g_hLoadedRecords.GetArray(sPath, iFileHeader[0], _:FileHeader);
		if (iFileHeader[FH_frames] != frames)
			continue;
		
		strcopy(path, maxlen, sPath);
		break;
	}
}

void CopyArrayToArray(const any[] array, any[] newArray, int size)
{
	for (int i = 0; i < size; i++)
		newArray[i] = array[i];
}

void CSGO_StripAllWeapons(int client)
{
	int weapon;
	for (int i = 0; i < 3; i++)
	{
		if ((weapon = GetPlayerWeaponSlot(client, i)) != -1)
		{
			if (GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity") != client)
				SetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity", client);

			SDKHooks_DropWeapon(client, weapon, NULL_VECTOR, NULL_VECTOR);
			AcceptEntityInput(weapon, "Kill");
		}
	}
}

bool HasWeapon(int client, const char[] entity, bool caseSensitive = true)
{
	if (client == 0 || client > MaxClients || !IsClientInGame(client) || !IsPlayerAlive(client))
		return false;
	
	int weapon; char class[32];
	for (int i = 0; i < 5; i++)
	{
		weapon = GetPlayerWeaponSlot(client, i);
		
		if (!IsValidEntity(weapon))
			continue;
		
		GetEntityClassname(weapon, class, sizeof(class));
		
		if (StrEqual(class, entity, caseSensitive))
			return true;
	}
	
	return false;
}

void EquipWeapon(int client, int weapon)
{
	char class[64];
	GetEntityClassname(weapon, class, sizeof(class));
	FakeClientCommand(client, "use %s", class);
}

int GetWeapon(int client, const char[] entity, bool caseSensitive = true)
{
	if (client == 0 || client > MaxClients || !IsClientInGame(client) || !IsPlayerAlive(client))
		return -1;
	
	int weapon; char class[32];
	for (int i = 0; i < 5; i++)
	{
		weapon = GetPlayerWeaponSlot(client, i);
		
		if (!IsValidEntity(weapon))
			continue;
		
		GetEntityClassname(weapon, class, sizeof(class));
		
		if (StrEqual(class, entity, caseSensitive))
			return weapon;
	}
	
	return -1;
}