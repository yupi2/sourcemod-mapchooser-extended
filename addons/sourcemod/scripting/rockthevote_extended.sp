/**
 * vim: set ts=4 :
 * =============================================================================
 * Rock The Vote Extended
 * Creates a map vote when the required number of players have requested one.
 *
 * Rock The Vote Extended (C)2012-2013 Powerlord (Ross Bemrose)
 * SourceMod (C)2004-2007 AlliedModders LLC.  All rights reserved.
 * =============================================================================
 *
 * This program is free software; you can redistribute it and/or modify it under
 * the terms of the GNU General Public License, version 3.0, as published by the
 * Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more
 * details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * As a special exception, AlliedModders LLC gives you permission to link the
 * code of this program (as well as its derivative works) to "Half-Life 2," the
 * "Source Engine," the "SourcePawn JIT," and any Game MODs that run on software
 * by the Valve Corporation.  You must obey the GNU General Public License in
 * all respects for all other code used.  Additionally, AlliedModders LLC grants
 * this exception to all derivative works.  AlliedModders LLC defines further
 * exceptions, found in LICENSE.txt (as of this writing, version JULY-31-2007),
 * or <http://www.sourcemod.net/license.php>.
 *
 * Version: $Id$
 */

#include <sourcemod>
#include <mapchooser>
#include "include/mapchooser_extended"
#include <nextmap>
#include <colors>
#include <cstrike> // Used for the "CS_TEAM_SPECTATOR" definition.

#pragma semicolon 1

// "specrtv" version includes the ability to disable spectators RTVing and
// counting towards the votes needed to change the map.
#define MCE_VERSION "1.10.2-specrtv"

#define TESTING 0

public Plugin:myinfo =
{
	name = "Rock The Vote Extended",
	author = "Powerlord and AlliedModders LLC",
	description = "Provides RTV Map Voting",
	version = MCE_VERSION,
	url = "https://forums.alliedmods.net/showthread.php?t=156974"
};

new Handle:g_Cvar_Needed = INVALID_HANDLE;
new Handle:g_Cvar_MinPlayers = INVALID_HANDLE;
new Handle:g_Cvar_InitialDelay = INVALID_HANDLE;
new Handle:g_Cvar_Interval = INVALID_HANDLE;
new Handle:g_Cvar_ChangeTime = INVALID_HANDLE;
new Handle:g_Cvar_RTVPostVoteAction = INVALID_HANDLE;
new Handle:g_Cvar_AllowSpectatorRTV = INVALID_HANDLE; // sm_allowspectatorrtv

new bool:g_CanRTV = false;		// True if RTV loaded maps and is active.
new bool:g_RTVAllowed = false;	// True if RTV is available to players. Used to delay rtv votes.
new g_Voters = 0;				// Total voters connected. Doesn't include fake clients.
new g_Votes = 0;				// Total number of "say rtv" votes
new g_VotesNeeded = 0;			// Necessary votes before map vote begins. (voters * percent_needed)
new bool:g_Voted[MAXPLAYERS+1] = {false, ...};

new bool:g_InChange = false;

CalcVotesNeeded()
{
	g_VotesNeeded = RoundToFloor(float(g_Voters) * GetConVarFloat(g_Cvar_Needed));
	return g_VotesNeeded;
}

public OnPluginStart()
{
	LoadTranslations("common.phrases");
	LoadTranslations("rockthevote.phrases");
	LoadTranslations("basevotes.phrases");

	g_Cvar_Needed = CreateConVar("sm_rtv_needed", "0.60", "Percentage of players needed to rockthevote (Def 60%)", 0, true, 0.05, true, 1.0);
	g_Cvar_MinPlayers = CreateConVar("sm_rtv_minplayers", "0", "Number of players required before RTV will be enabled.", 0, true, 0.0, true, float(MAXPLAYERS));
	g_Cvar_InitialDelay = CreateConVar("sm_rtv_initialdelay", "5.0", "Time (in seconds) before first RTV can be held", 0, true, 0.00);
	g_Cvar_Interval = CreateConVar("sm_rtv_interval", "240.0", "Time (in seconds) after a failed RTV before another can be held", 0, true, 0.00);
	g_Cvar_ChangeTime = CreateConVar("sm_rtv_changetime", "0", "When to change the map after a successful RTV: 0 - Instant, 1 - RoundEnd, 2 - MapEnd", _, true, 0.0, true, 2.0);
	g_Cvar_RTVPostVoteAction = CreateConVar("sm_rtv_postvoteaction", "0", "What to do with RTV's after a mapvote has completed. 0 - Allow, success = instant change, 1 - Deny", _, true, 0.0, true, 1.0);

	// New shit added by pufftwitt!
	g_Cvar_AllowSpectatorRTV = CreateConVar("sm_allowspectatorrtv", "0", "Allow the spectators to RTV and also count towards the percentage of players needed to rockthevote.", 0, true, 0.0, true, 1.0);
	HookConVarChange(g_Cvar_AllowSpectatorRTV, AllowSpectatorRTV_Callback);
	// Set-up the team switch hook to disable spectators from RTV'ing.
	HookEvent("player_team", PlayerTeam_RTVCheck);

	RegConsoleCmd("say", Command_Say);
	RegConsoleCmd("say_team", Command_Say);

	RegConsoleCmd("sm_rtv", Command_RTV);

	RegAdminCmd("sm_forcertv", Command_ForceRTV, ADMFLAG_CHANGEMAP, "Force an RTV vote");
	RegAdminCmd("mce_forcertv", Command_ForceRTV, ADMFLAG_CHANGEMAP, "Force an RTV vote");

	// Rock The Vote Extended cvars
	CreateConVar("rtve_version", MCE_VERSION, "Rock The Vote Extended Version", FCVAR_PLUGIN|FCVAR_SPONLY|FCVAR_NOTIFY|FCVAR_DONTRECORD);

	AutoExecConfig(true, "rtv");
}

public OnMapStart()
{
	g_Voters = 0;
	g_Votes = 0;
	g_VotesNeeded = 0;
	g_InChange = false;

	// Handle late load
	for (new i = 1; i <= MaxClients; ++i)
	{
		if (IsClientConnected(i))
		{
			OnClientConnected(i);
		}
	}
}

public OnMapEnd()
{
	g_CanRTV = false;
	g_RTVAllowed = false;
}

public OnConfigsExecuted()
{
	g_CanRTV = true;
	g_RTVAllowed = false;
	CreateTimer(GetConVarFloat(g_Cvar_InitialDelay), Timer_DelayRTV, _, TIMER_FLAG_NO_MAPCHANGE);
}

public OnClientConnected(client)
{
	if (IsFakeClient(client))
	{
		return;
	}

	g_Voted[client] = false;

	// They'll be on team CS_TEAM_NONE when they first join.
	if (GetConVarBool(g_Cvar_AllowSpectatorRTV))
	{
		++g_Voters;
		CalcVotesNeeded();
	}
}

public OnClientDisconnect(client)
{
	if (IsFakeClient(client))
	{
		return;
	}

	// If the client is in spectator, another function has already removed the votes.
	if (!GetConVarBool(g_Cvar_AllowSpectatorRTV) && ClientIsInSpectator(client))
	{
		return;
	}

	if (g_Voted[client])
	{
		--g_Votes;
	}

	--g_Voters;

	CalcVotesNeeded();

	if (!g_CanRTV)
	{
		return;
	}

	if (g_Votes &&
		g_Voters &&
		g_Votes >= g_VotesNeeded &&
		g_RTVAllowed)
	{
		if (GetConVarInt(g_Cvar_RTVPostVoteAction) == 1 && HasEndOfMapVoteFinished())
		{
			return;
		}

		StartRTV();
	}
}

TeamIsSpectator(team)
{
	return team == CS_TEAM_NONE || team == CS_TEAM_SPECTATOR;
}

ClientIsInSpectator(client)
{
	return TeamIsSpectator(GetClientTeam(client));
}

public PlayerTeam_RTVCheck(Handle:event, const String:name[], bool:dontBroadcast)
{
	// The EventBool "disconnect" is true if the team is changed because of the client disconnecting.
	if (GetEventBool(event, "disconnect") || GetConVarBool(g_Cvar_AllowSpectatorRTV))
	{
		return;
	}

	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	new newteam = GetEventInt(event, "team");
	new oldteam = GetEventInt(event, "oldteam");

	if (IsFakeClient(client) || newteam == oldteam)
	{
		return;
	}

	// If they are a spectator, remove their vote and reduce the number of possible voters.
	// If the are switching from spectator to T or CT then increase the number of possible voters.
	if (TeamIsSpectator(newteam))
	{
		if (!TeamIsSpectator(oldteam))
		{
			if (g_Voted[client])
			{
				--g_Votes;
				g_Voted[client] = false;
			}

			--g_Voters;
		}
	}
	else if (TeamIsSpectator(oldteam))
	{
		++g_Voters;
	}

	CalcVotesNeeded();
}

// This callback was added if the CVAR is changed and thus enabling/disabling the spectator's ability to RTV.
// If "0" we can remove the votes from the spectators and see if the vote will start.
public AllowSpectatorRTV_Callback(ConVar convar, const String:oldValue[], const String:newValue[])
{
	new bool:allowSpectatorRTV = convar.BoolValue;
	g_Voters = 0;

	// Great place for a bird to live...it's a joke about nested if-statements...
	for (new i = 1; i < MaxClients; ++i)
	{
		if (IsClientConnected(i) && !IsFakeClient(i))
		{
			if (ClientIsInSpectator(i) && !allowSpectatorRTV)
			{
				if (g_Voted[i])
				{
					g_Voted[i] = false;
					--g_Votes;
				}
			}
			else
			{
				++g_Voters;
			}
		}
	}

	if (g_Votes >= CalcVotesNeeded())
	{
		StartRTV();
	}
}

public Action:Command_RTV(client, args)
{
	if (!g_CanRTV || !client)
	{
		return Plugin_Handled;
	}

	AttemptRTV(client);

	return Plugin_Handled;
}

public Action:Command_Say(client, args)
{
	if (!g_CanRTV || !client)
	{
		return Plugin_Continue;
	}

	decl String:text[192];
	if (!GetCmdArgString(text, sizeof(text)))
	{
		return Plugin_Continue;
	}

	new startidx = 0;
	if (text[strlen(text)-1] == '"')
	{
		text[strlen(text)-1] = '\0';
		startidx = 1;
	}

	new ReplySource:old = SetCmdReplySource(SM_REPLY_TO_CHAT);

	if (strcmp(text[startidx], "rtv", false) == 0 || strcmp(text[startidx], "rockthevote", false) == 0)
	{
		AttemptRTV(client);
	}

	SetCmdReplySource(old);

	return Plugin_Continue;
}

AttemptRTV(client)
{
	// NEW: Disallow RTVs from spectators if "sm_allowspectatorrtv" is "1".
	if (!g_RTVAllowed || (GetConVarInt(g_Cvar_RTVPostVoteAction) == 1 && HasEndOfMapVoteFinished()) ||
	    (!GetConVarBool(g_Cvar_AllowSpectatorRTV) && ClientIsInSpectator(client)))
	{
		CReplyToCommand(client, "[SM] %t", "RTV Not Allowed");
		return;
	}

	if (!CanMapChooserStartVote())
	{
		CReplyToCommand(client, "[SM] %t", "RTV Started");
		return;
	}

	if (GetClientCount(true) < GetConVarInt(g_Cvar_MinPlayers))
	{
		CReplyToCommand(client, "[SM] %t", "Minimal Players Not Met");
		return;
	}

	if (g_Voted[client])
	{
		CReplyToCommand(client, "[SM] %t", "Already Voted", g_Votes, g_VotesNeeded);
		return;
	}

	new String:name[MAX_NAME_LENGTH];
	GetClientName(client, name, sizeof(name));

	++g_Votes;
	g_Voted[client] = true;

	CPrintToChatAll("[SM] %t", "RTV Requested", name, g_Votes, g_VotesNeeded);

	if (g_Votes >= g_VotesNeeded)
	{
		StartRTV();
	}
}

public Action:Timer_DelayRTV(Handle:timer)
{
	g_RTVAllowed = true;
}

StartRTV()
{
	if (g_InChange)
	{
		return;
	}

	if (EndOfMapVoteEnabled() && HasEndOfMapVoteFinished())
	{
		/* Change right now then */
		new String:map[PLATFORM_MAX_PATH];
		if (GetNextMap(map, sizeof(map)))
		{
			CPrintToChatAll("[SM] %t", "Changing Maps", map);
			CreateTimer(5.0, Timer_ChangeMap, _, TIMER_FLAG_NO_MAPCHANGE);
			g_InChange = true;

			ResetRTV();

			g_RTVAllowed = false;
		}
		return;
	}

	if (CanMapChooserStartVote())
	{
		new MapChange:when = MapChange:GetConVarInt(g_Cvar_ChangeTime);
		InitiateMapChooserVote(when);

		ResetRTV();

		g_RTVAllowed = false;
		CreateTimer(GetConVarFloat(g_Cvar_Interval), Timer_DelayRTV, _, TIMER_FLAG_NO_MAPCHANGE);
	}
}

ResetRTV()
{
	g_Votes = 0;

	for (new i = 1; i <= MAXPLAYERS; ++i)
	{
		g_Voted[i] = false;
	}
}

public Action:Timer_ChangeMap(Handle:hTimer)
{
	g_InChange = false;

	LogMessage("RTV changing map manually");

	new String:map[PLATFORM_MAX_PATH];
	if (GetNextMap(map, sizeof(map)))
	{
		ForceChangeLevel(map, "RTV after mapvote");
	}

	return Plugin_Stop;
}

// Rock The Vote Extended functions

public Action:Command_ForceRTV(client, args)
{
	if (!g_CanRTV || !client)
	{
		return Plugin_Handled;
	}

	ShowActivity2(client, "[RTVE] ", "%t", "Initiated Vote Map");

	StartRTV();

	return Plugin_Handled;
}
