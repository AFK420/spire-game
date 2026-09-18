--!strict

--[=[
	NetworkService ModuleScript
	Mapped to: ServerScriptService.Server.services.NetworkService
	Centralized network gateway for Card Rift: Co-op Dungeon:
	1. Owns and manages all RemoteEvents under ReplicatedStorage.GameNetwork.
	2. Enforces category-based rate limiting to prevent spam and packet flooding.
	3. Provides validation utilities for incoming client requests.
	4. Dispatches authoritative state snapshots (RunSnapshot, CombatSnapshot) to clients.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)
local GameConfig = require(Shared:WaitForChild("GameConfig") :: ModuleScript)

local NetworkService = {}

--------------------------------------------------------------------------------
-- Remote Events Container Setup
--------------------------------------------------------------------------------

local networkFolder = ReplicatedStorage:FindFirstChild("GameNetwork")
if not networkFolder then
	local folder = Instance.new("Folder")
	folder.Name = "GameNetwork"
	folder.Parent = ReplicatedStorage
	networkFolder = folder
end

local function getOrCreateRemoteEvent(name: string): RemoteEvent
	local existing = networkFolder:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local event = Instance.new("RemoteEvent")
	event.Name = name
	event.Parent = networkFolder
	return event
end

-- Client -> Server Action Events
NetworkService.StartRunEvent = getOrCreateRemoteEvent("StartRun")
NetworkService.SelectClassEvent = getOrCreateRemoteEvent("SelectClass")
NetworkService.VoteMapNodeEvent = getOrCreateRemoteEvent("VoteMapNode")
NetworkService.PlayCardEvent = getOrCreateRemoteEvent("PlayCard")
NetworkService.PlayerVoteReadyEvent = getOrCreateRemoteEvent("PlayerVoteReady")
NetworkService.RescueTeammateEvent = getOrCreateRemoteEvent("RescueTeammate")
NetworkService.CampfireChoiceEvent = getOrCreateRemoteEvent("CampfireChoice")
NetworkService.ClaimRewardCardEvent = getOrCreateRemoteEvent("ClaimRewardCard")
NetworkService.ContinueFromRewardsEvent = getOrCreateRemoteEvent("ContinueFromRewards")
NetworkService.RequestStateSyncEvent = getOrCreateRemoteEvent("RequestStateSync")

-- Phase 3.1 RPG Foundation Action Events
NetworkService.EquipEquipmentEvent = getOrCreateRemoteEvent("EquipEquipment")
NetworkService.UnequipEquipmentEvent = getOrCreateRemoteEvent("UnequipEquipment")
NetworkService.EquipSkillEvent = getOrCreateRemoteEvent("EquipSkill")
NetworkService.UnequipSkillEvent = getOrCreateRemoteEvent("UnequipSkill")
NetworkService.UnlockPassiveEvent = getOrCreateRemoteEvent("UnlockPassive")
NetworkService.UnlockSkillEvent = getOrCreateRemoteEvent("UnlockSkill")
NetworkService.UseSkillEvent = getOrCreateRemoteEvent("UseSkill")

-- Phase 4 Deck & Collection Action Events (Client -> Server)
NetworkService.CreateDeckEvent = getOrCreateRemoteEvent("CreateDeck")
NetworkService.RenameDeckEvent = getOrCreateRemoteEvent("RenameDeck")
NetworkService.DeleteDeckEvent = getOrCreateRemoteEvent("DeleteDeck")
NetworkService.SaveDeckEvent = getOrCreateRemoteEvent("SaveDeck")
NetworkService.DuplicateDeckEvent = getOrCreateRemoteEvent("DuplicateDeck")
NetworkService.SelectActiveDeckEvent = getOrCreateRemoteEvent("SelectActiveDeck")
NetworkService.RequestDecksEvent = getOrCreateRemoteEvent("RequestDecks")
NetworkService.RequestCardCollectionEvent = getOrCreateRemoteEvent("RequestCardCollection")

-- Server -> Client State & Feedback Events
NetworkService.RunStateUpdateEvent = getOrCreateRemoteEvent("RunStateUpdate")
NetworkService.CombatStateUpdateEvent = getOrCreateRemoteEvent("CombatStateUpdate")
NetworkService.CombatEventLoggedEvent = getOrCreateRemoteEvent("CombatEventLogged")
NetworkService.AnnouncementEvent = getOrCreateRemoteEvent("Announcement")
NetworkService.RelicNotificationEvent = getOrCreateRemoteEvent("RelicNotification")
NetworkService.DeckListUpdateEvent = getOrCreateRemoteEvent("DeckListUpdate")
NetworkService.DeckDetailUpdateEvent = getOrCreateRemoteEvent("DeckDetailUpdate")
NetworkService.CardCollectionUpdateEvent = getOrCreateRemoteEvent("CardCollectionUpdate")
NetworkService.ClassSelectionResultEvent = getOrCreateRemoteEvent("ClassSelectionResult")
NetworkService.ActionResultEvent = getOrCreateRemoteEvent("ActionResult")
NetworkService.ReturnToLobbyEvent = getOrCreateRemoteEvent("ReturnToLobby")

--------------------------------------------------------------------------------
-- Token-Bucket Rate Limiting Engine
--------------------------------------------------------------------------------

export type ActionCategory = "Combat" | "Map" | "Class" | "General"

type RateBucket = {
	Tokens: number,
	MaxTokens: number,
	RefillRate: number, -- Tokens per second
	LastRefillTime: number,
}

local playerBuckets: { [number]: { [ActionCategory]: RateBucket } } = {}

-- Validates whether an action is permitted under rate-limiting rules
function NetworkService.checkRateLimit(player: Player, category: ActionCategory): boolean
	local userId = player.UserId
	local now = os.clock()

	if not playerBuckets[userId] then
		playerBuckets[userId] = {}
	end

	local bucket = playerBuckets[userId][category]
	local config = (GameConfig.NetworkLimits :: any)[category] or GameConfig.NetworkLimits.General

	if not bucket then
		bucket = {
			Tokens = config.MaxTokens,
			MaxTokens = config.MaxTokens,
			RefillRate = config.RefillRate,
			LastRefillTime = now,
		}
		playerBuckets[userId][category] = bucket
	else
		-- Refill tokens based on elapsed monotonic time
		local elapsed = now - bucket.LastRefillTime
		bucket.Tokens = math.min(bucket.MaxTokens, bucket.Tokens + elapsed * bucket.RefillRate)
		bucket.LastRefillTime = now
	end

	if bucket.Tokens >= 1 then
		bucket.Tokens -= 1
		return true
	else
		warn(string.format("[NetworkService] Rate limit exceeded for %s on category '%s'", player.Name, category))
		return false
	end
end

-- Flushes rate-limit buckets for a player on disconnect
function NetworkService.cleanPlayer(userId: number)
	playerBuckets[userId] = nil
end

--------------------------------------------------------------------------------
-- Client Dispatch Helpers
--------------------------------------------------------------------------------

-- Sends a synchronized run snapshot to all players in the party
function NetworkService.broadcastRunState(snapshot: StateTypes.RunSnapshot)
	NetworkService.RunStateUpdateEvent:FireAllClients(snapshot)
end

-- Sends a personalized run snapshot to a specific player
function NetworkService.sendRunState(player: Player, snapshot: StateTypes.RunSnapshot)
	if typeof(player) == "Instance" and player:IsA("Player") then
		NetworkService.RunStateUpdateEvent:FireClient(player, snapshot)
	end
end

-- Sends a personalized combat snapshot to a specific player
function NetworkService.sendCombatState(player: Player, snapshot: StateTypes.CombatSnapshot)
	if typeof(player) == "Instance" and player:IsA("Player") then
		NetworkService.CombatStateUpdateEvent:FireClient(player, snapshot)
	end
end

local combatEventHook: ((event: StateTypes.CombatEvent) -> ())? = nil

function NetworkService.setCombatEventHook(hook: ((event: StateTypes.CombatEvent) -> ())?)
	combatEventHook = hook
end

-- Sends a structured combat event (e.g. floating damage or sound) to all clients
function NetworkService.broadcastCombatEvent(event: StateTypes.CombatEvent)
	if combatEventHook then
		pcall(combatEventHook, event)
	end
	NetworkService.CombatEventLoggedEvent:FireAllClients(event)
end

-- Sends a banner announcement to all connected clients
function NetworkService.broadcastAnnouncement(title: string, message: string, color: Color3?)
	NetworkService.AnnouncementEvent:FireAllClients({
		Title = title,
		Message = message,
		Color = color or Color3.fromRGB(255, 220, 80),
	})
end

-- Notifies a specific player of a passive relic trigger
function NetworkService.notifyRelicTrigger(player: Player, payload: { RelicId: string, RelicName: string, Icon: string, Text: string, Rarity: string })
	if typeof(player) == "Instance" and player:IsA("Player") then
		NetworkService.RelicNotificationEvent:FireClient(player, payload)
	end
end

-- Notifies a specific player of class selection outcome
function NetworkService.sendClassSelectionResult(player: Player, payload: { Success: boolean, ClassId: string?, SubclassId: string?, Error: string? })
	if typeof(player) == "Instance" and player:IsA("Player") then
		NetworkService.ClassSelectionResultEvent:FireClient(player, payload)
	end
end

export type ActionResultPayload = {
	Action: string,
	Success: boolean,
	Message: string?,
	Reason: string?,
	NodeId: string?,
	Won: boolean?,
	Phase: StateTypes.RunPhase?,
	StateRevision: number?,
	CardDefId: string?,
}

-- Notifies a specific player of an action result
function NetworkService.sendActionResult(player: Player, payload: ActionResultPayload)
	if typeof(player) == "Instance" and player:IsA("Player") then
		if payload.Success == false then
			local reason = payload.Reason or payload.Message or "Action rejected."
			payload.Reason = reason
			payload.Message = payload.Message or reason
		end
		NetworkService.ActionResultEvent:FireClient(player, payload)
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function NetworkService.init()
	Players.PlayerRemoving:Connect(function(player: Player)
		playerBuckets[player.UserId] = nil
	end)
	print("[NetworkService] Initialized centralized network gateway with category rate-limiting.")
end

return NetworkService
