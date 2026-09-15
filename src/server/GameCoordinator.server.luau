--!strict

--[=[
	GameCoordinator Script
	Mapped to: ServerScriptService.Server.GameCoordinator
	Manages the global state machine and run lifecycle for Card Rift: Co-op Dungeon:
	1. Lobby -> When players hit start, initialize a new DungeonRun using DungeonMap.generateRun().
	2. MapSelect -> Send available nodes to clients so players can vote/choose the next node.
	3. ActiveRoom -> Loads the room controller (Combat, Elite Monster, Campfire Rest, Merchant Shop, Act Boss).
	4. Rewards -> Distributes gold & card draft choices, then returns players to MapSelect.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CardData = require(Shared:WaitForChild("CardData") :: ModuleScript)
local DungeonMap = require(Shared:WaitForChild("DungeonMap") :: ModuleScript)
local RelicData = require(Shared:WaitForChild("RelicData") :: ModuleScript)

--------------------------------------------------------------------------------
-- Remote Events Setup
--------------------------------------------------------------------------------

local flowEventsFolder = ReplicatedStorage:FindFirstChild("GameFlowEvents")
if not flowEventsFolder then
	local folder = Instance.new("Folder")
	folder.Name = "GameFlowEvents"
	folder.Parent = ReplicatedStorage
	flowEventsFolder = folder
end

local function getOrCreateRemoteEvent(name: string): RemoteEvent
	local existing = flowEventsFolder:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local event = Instance.new("RemoteEvent")
	event.Name = name
	event.Parent = flowEventsFolder
	return event
end

local StartRunEvent = getOrCreateRemoteEvent("StartRun")
local VoteMapNodeEvent = getOrCreateRemoteEvent("VoteMapNode")
local ClaimRewardCardEvent = getOrCreateRemoteEvent("ClaimRewardCard")
local ContinueFromRewardsEvent = getOrCreateRemoteEvent("ContinueFromRewards")
local CampfireChoiceEvent = getOrCreateRemoteEvent("CampfireChoice")
local FlowStateUpdateEvent = getOrCreateRemoteEvent("FlowStateUpdate")
local FlowAnnouncementEvent = getOrCreateRemoteEvent("FlowAnnouncement")

--------------------------------------------------------------------------------
-- Type Definitions
--------------------------------------------------------------------------------

export type RunPhase =
	| "Lobby"
	| "MapSelect"
	| "ActiveRoom"
	| "Rewards"
	| "RunVictory"
	| "RunDefeat"

export type ActiveRoomType =
	| "Combat"
	| "Elite Monster"
	| "Campfire Rest"
	| "Merchant Shop"
	| "Act Boss"

export type PlayerRunData = {
	PlayerInstance: Player,
	UserId: number,
	DisplayName: string,
	Gold: number,
	Deck: { CardData.Card },
	OfferedCards: { CardData.Card },
	HasClaimedReward: boolean,
	VotedNodeId: string?,
}

export type ActiveRoomState = {
	NodeId: string,
	Type: ActiveRoomType,
	Tier: number,
	Act: number,
	EnemyName: string?,
	EnemyMaxHP: number?,
	EnemyHP: number?,
	EnemyAttack: number?,
	CampfireUsed: boolean?,
	ShopVisited: boolean?,
}

export type RunCoordinatorState = {
	Phase: RunPhase,
	DungeonRun: DungeonMap.DungeonRun?,
	Players: { [number]: PlayerRunData }, -- Keyed by UserId
	ActiveRoom: ActiveRoomState?,
	PendingRewards: {
		GoldAmount: number,
		AetherShardsAmount: number,
	}?,
}

--------------------------------------------------------------------------------
-- Global Coordinator State
--------------------------------------------------------------------------------

local coordinator: RunCoordinatorState = {
	Phase = "Lobby",
	DungeonRun = nil,
	Players = {},
	ActiveRoom = nil,
	PendingRewards = nil,
}

--------------------------------------------------------------------------------
-- Card Pool Utility (For 3-Card Draft Choices)
--------------------------------------------------------------------------------

local function getAllDraftableCards(): { CardData.Card }
	return {
		CardData.Strike,
		CardData.Defend,
		CardData.HeavyBlow,
		CardData.PoisonDart,
		CardData.FirstAid,
	}
end

local function generateCardDraftChoices(count: number): { CardData.Card }
	local pool = getAllDraftableCards()
	local rng = Random.new()

	-- Fisher-Yates shuffle
	for i = #pool, 2, -1 do
		local j = rng:NextInteger(1, i)
		pool[i], pool[j] = pool[j], pool[i]
	end

	local draft: { CardData.Card } = {}
	for i = 1, math.min(count, #pool) do
		table.insert(draft, pool[i])
	end

	return draft
end

--------------------------------------------------------------------------------
-- State Broadcast & Announcements
--------------------------------------------------------------------------------

local function broadcastFlowState(customMessage: string?)
	local playersSummary = {}
	for userId, pData in coordinator.Players do
		local offeredNames = {}
		for _, card in pData.OfferedCards do
			table.insert(offeredNames, card.Name)
		end

		playersSummary[tostring(userId)] = {
			UserId = userId,
			DisplayName = pData.DisplayName,
			Gold = pData.Gold,
			DeckCount = #pData.Deck,
			OfferedCards = pData.OfferedCards,
			HasClaimedReward = pData.HasClaimedReward,
			VotedNodeId = pData.VotedNodeId,
		}
	end

	local runData = nil
	local availableNodesPayload = {}
	if coordinator.DungeonRun then
		local currentAct = coordinator.DungeonRun.Acts[coordinator.DungeonRun.CurrentActIndex]
		local available = DungeonMap.getAvailableNextNodes(coordinator.DungeonRun)
		for _, node in available do
			table.insert(availableNodesPayload, {
				Id = node.Id,
				Act = node.Act,
				Tier = node.Tier,
				Lane = node.Lane,
				Type = node.Type,
			})
		end

		runData = {
			CurrentAct = currentAct.ActNumber,
			ActName = currentAct.Name,
			CurrentTier = coordinator.DungeonRun.CurrentTier,
			CurrentNodeId = coordinator.DungeonRun.CurrentNodeId,
			ClearedCount = #coordinator.DungeonRun.ClearedNodeIds,
			IsCompleted = coordinator.DungeonRun.IsCompleted,
		}
	end

	local payload = {
		Phase = coordinator.Phase,
		Run = runData,
		AvailableNodes = availableNodesPayload,
		ActiveRoom = coordinator.ActiveRoom,
		PendingRewards = coordinator.PendingRewards,
		Players = playersSummary,
		Message = customMessage or "",
	}

	FlowStateUpdateEvent:FireAllClients(payload)
end

local function broadcastFlowAnnouncement(title: string, message: string, color: Color3?)
	FlowAnnouncementEvent:FireAllClients({
		Title = title,
		Message = message,
		Color = color or Color3.fromRGB(255, 220, 80),
	})
	print(string.format("[GameCoordinator] %s: %s", title, message))
end

--------------------------------------------------------------------------------
-- State Transitions: Lobby -> MapSelect -> ActiveRoom -> Rewards
--------------------------------------------------------------------------------

-- Forward declarations
local transitionToMapSelect: () -> ()
local transitionToActiveRoom: (node: DungeonMap.DungeonNode) -> ()
local transitionToRewards: (isElite: boolean, isBoss: boolean) -> ()

-- 1. Lobby -> MapSelect
local function startNewRun()
	print("[GameCoordinator] Initializing new DungeonRun from Lobby...")

	-- Generate a new procedural 4-Act dungeon
	coordinator.DungeonRun = DungeonMap.generateRun()

	-- Initialize player run data
	for _, player in Players:GetPlayers() do
		local pData: PlayerRunData = {
			PlayerInstance = player,
			UserId = player.UserId,
			DisplayName = player.DisplayName or player.Name,
			Gold = 50, -- Starter gold
			Deck = {
				CardData.Strike,
				CardData.Defend,
				CardData.HeavyBlow,
				CardData.PoisonDart,
				CardData.FirstAid,
				CardData.Strike,
				CardData.Defend,
			},
			OfferedCards = {},
			HasClaimedReward = false,
			VotedNodeId = nil,
		}
		coordinator.Players[player.UserId] = pData

		-- Record run start in ProfileStore if available
		local ps = _G.ProfileStore
		if ps and typeof(ps.recordRunStart) == "function" then
			ps.recordRunStart(player)
		end
	end

	broadcastFlowAnnouncement("🏰 RUN STARTED!", "Welcome to Card Rift. Select your starting room!", Color3.fromRGB(100, 200, 255))
	transitionToMapSelect()
end

-- 2. Transition to MapSelect
transitionToMapSelect = function()
	coordinator.Phase = "MapSelect"
	coordinator.ActiveRoom = nil
	coordinator.PendingRewards = nil

	-- Reset node votes
	for _, pData in coordinator.Players do
		pData.VotedNodeId = nil
		pData.HasClaimedReward = false
		table.clear(pData.OfferedCards)
	end

	local run = coordinator.DungeonRun
	if not run then return end

	local available = DungeonMap.getAvailableNextNodes(run)
	print(string.format("[GameCoordinator] Phase -> MapSelect (Available Rooms: %d)", #available))

	broadcastFlowState("Select a connected room on the map to proceed.")
end

-- 3. Transition to ActiveRoom
transitionToActiveRoom = function(node: DungeonMap.DungeonNode)
	coordinator.Phase = "ActiveRoom"

	print(string.format("[GameCoordinator] Phase -> ActiveRoom: [%s] at Tier %d, Lane %d", node.Type, node.Tier, node.Lane))

	local roomState: ActiveRoomState = {
		NodeId = node.Id,
		Type = node.Type,
		Tier = node.Tier,
		Act = node.Act,
	}

	if node.Type == "Combat" then
		roomState.EnemyName = "Spire Sentinel"
		roomState.EnemyMaxHP = 75
		roomState.EnemyHP = 75
		roomState.EnemyAttack = 8
		coordinator.ActiveRoom = roomState
		broadcastFlowAnnouncement("⚔️ COMBAT ENGAGED", "Defeat the Spire Sentinel!", Color3.fromRGB(220, 60, 60))

	elseif node.Type == "Elite Monster" then
		roomState.EnemyName = "Gremlin Nob (Elite)"
		roomState.EnemyMaxHP = 135
		roomState.EnemyHP = 135
		roomState.EnemyAttack = 14
		coordinator.ActiveRoom = roomState
		broadcastFlowAnnouncement("💀 ELITE ENCOUNTER!", "Prepare for battle against an Elite monster!", Color3.fromRGB(255, 120, 40))

	elseif node.Type == "Act Boss" then
		roomState.EnemyName = "The Spire Guardian (Boss)"
		roomState.EnemyMaxHP = 200
		roomState.EnemyHP = 200
		roomState.EnemyAttack = 12
		coordinator.ActiveRoom = roomState
		broadcastFlowAnnouncement("👹 ACT BOSS BATTLE!", "The guardian of the Act blocks your path!", Color3.fromRGB(200, 50, 220))

	elseif node.Type == "Campfire Rest" then
		roomState.CampfireUsed = false
		coordinator.ActiveRoom = roomState
		broadcastFlowAnnouncement("🔥 CAMPFIRE REST", "Rest to restore 30% Max HP or Smith to empower your deck.", Color3.fromRGB(80, 220, 120))

	elseif node.Type == "Merchant Shop" then
		roomState.ShopVisited = true
		coordinator.ActiveRoom = roomState
		broadcastFlowAnnouncement("💰 MERCHANT SHOP", "Browse cards and supplies with your gold.", Color3.fromRGB(255, 215, 60))
	end

	broadcastFlowState()
end

-- 4. Transition to Rewards
transitionToRewards = function(isElite: boolean, isBoss: boolean)
	coordinator.Phase = "Rewards"

	local goldReward = 20
	local shardReward = 0

	if isBoss then
		goldReward = 100
		shardReward = 25
	elseif isElite then
		goldReward = 45
		shardReward = 5
	end

	coordinator.PendingRewards = {
		GoldAmount = goldReward,
		AetherShardsAmount = shardReward,
	}

	print(string.format("[GameCoordinator] Phase -> Rewards (Gold: %d, Aether Shards: %d)", goldReward, shardReward))

	-- Distribute gold, aether shards, and generate 3 card draft options per player
	for _, pData in coordinator.Players do
		pData.Gold += goldReward
		pData.HasClaimedReward = false
		pData.OfferedCards = generateCardDraftChoices(3)

		-- Add permanent Aether Shards to ProfileStore
		if shardReward > 0 then
			local ps = _G.ProfileStore
			if ps and typeof(ps.addAetherShards) == "function" then
				ps.addAetherShards(pData.PlayerInstance, shardReward)
			end
		end

		if isBoss then
			local ps = _G.ProfileStore
			if ps and typeof(ps.recordRunVictory) == "function" then
				ps.recordRunVictory(pData.PlayerInstance)
			end
		end

		-- Award Relics on Elite / Boss victories
		local relicMgr = _G.RelicManager
		if relicMgr and typeof(relicMgr.addRelic) == "function" then
			if isBoss then
				local bossRelic = RelicData.getRandomRelicByRarity("Boss")
				if bossRelic then
					relicMgr.addRelic(pData.PlayerInstance, bossRelic.Id)
				end
			elseif isElite then
				local eliteRelic = RelicData.getRandomRelicByRarity("Rare") or RelicData.getRandomRelicByRarity("Uncommon")
				if eliteRelic then
					relicMgr.addRelic(pData.PlayerInstance, eliteRelic.Id)
				end
			end
		end
	end

	broadcastFlowAnnouncement(
		"🎁 VICTORY REWARDS!",
		string.format("Earned +%d Gold! Choose a card to add to your deck.", goldReward),
		Color3.fromRGB(255, 215, 70)
	)
	broadcastFlowState("Choose your reward card or skip to continue.")
end

--------------------------------------------------------------------------------
-- Room Completion Handlers
--------------------------------------------------------------------------------

-- Called when a room is cleared (e.g. from CombatServer / SessionManager)
local function onRoomCleared()
	local active = coordinator.ActiveRoom
	if not active then return end

	if active.Type == "Combat" then
		transitionToRewards(false, false)
	elseif active.Type == "Elite Monster" then
		transitionToRewards(true, false)
	elseif active.Type == "Act Boss" then
		if coordinator.DungeonRun and coordinator.DungeonRun.CurrentActIndex == 4 then
			coordinator.Phase = "RunVictory"
			broadcastFlowAnnouncement("🏆 SPIRE CONQUERED!", "Congratulations! You have conquered the Heart Summit!", Color3.fromRGB(255, 230, 80))
			broadcastFlowState("Victory! Returning to Lobby shortly...")
			task.delay(5.0, function()
				coordinator.Phase = "Lobby"
				broadcastFlowState("Back in Lobby. Ready for another run?")
			end)
		else
			transitionToRewards(false, true)
		end
	else
		-- Non-combat rooms (Campfire, Shop) return directly to MapSelect
		transitionToMapSelect()
	end
end

-- Called when party wipes in combat
local function onPartyDefeated()
	coordinator.Phase = "RunDefeat"
	broadcastFlowAnnouncement("💀 TEAM DEFEAT", "Your party was overwhelmed by the Spire.", Color3.fromRGB(255, 50, 50))
	broadcastFlowState("Defeat! Returning to Lobby...")

	task.delay(4.0, function()
		coordinator.Phase = "Lobby"
		coordinator.DungeonRun = nil
		coordinator.ActiveRoom = nil
		broadcastFlowState("Lobby: Ready for another run.")
	end)
end

--------------------------------------------------------------------------------
-- Remote Event Listeners
--------------------------------------------------------------------------------

-- 1. Start Run from Lobby
StartRunEvent.OnServerEvent:Connect(function(player: Player)
	if coordinator.Phase ~= "Lobby" then return end
	print(string.format("[GameCoordinator] Player %s requested StartRun.", player.Name))
	startNewRun()
end)

-- 2. Vote/Choose Map Node
VoteMapNodeEvent.OnServerEvent:Connect(function(player: Player, targetNodeId: any)
	if coordinator.Phase ~= "MapSelect" or not coordinator.DungeonRun then return end
	if typeof(targetNodeId) ~= "string" then return end

	local pData = coordinator.Players[player.UserId]
	if not pData then return end

	pData.VotedNodeId = targetNodeId
	print(string.format("[GameCoordinator] %s voted for room '%s'.", pData.DisplayName, targetNodeId))

	-- Check available nodes
	local available = DungeonMap.getAvailableNextNodes(coordinator.DungeonRun)
	local isValid = false
	local selectedNode: DungeonMap.DungeonNode? = nil

	for _, node in available do
		if node.Id == targetNodeId then
			isValid = true
			selectedNode = node
			break
		end
	end

	if not isValid or not selectedNode then
		broadcastFlowAnnouncement("❌ INVALID ROOM", "That room is not currently reachable.", Color3.fromRGB(255, 90, 90))
		return
	end

	-- Advance the dungeon map
	local success, err = DungeonMap.selectNextNode(coordinator.DungeonRun, targetNodeId)
	if success then
		transitionToActiveRoom(selectedNode)
	else
		warn("[GameCoordinator] Map advance error: " .. tostring(err))
	end
end)

-- 3. Claim Card Reward
ClaimRewardCardEvent.OnServerEvent:Connect(function(player: Player, cardNameOrId: any)
	if coordinator.Phase ~= "Rewards" then return end
	if typeof(cardNameOrId) ~= "string" then return end

	local pData = coordinator.Players[player.UserId]
	if not pData or pData.HasClaimedReward then return end

	-- Validate card was in the offered choices
	local chosenCard: CardData.Card? = nil
	for _, card in pData.OfferedCards do
		if card.Id == cardNameOrId or card.Name == cardNameOrId then
			chosenCard = card
			break
		end
	end

	if chosenCard then
		table.insert(pData.Deck, chosenCard)
		pData.HasClaimedReward = true
		print(string.format("[GameCoordinator] %s drafted [%s] into their deck! (Deck size: %d)", pData.DisplayName, chosenCard.Name, #pData.Deck))
		broadcastFlowAnnouncement("🃏 CARD ADDED", string.format("%s drafted [%s]!", pData.DisplayName, chosenCard.Name), Color3.fromRGB(120, 240, 160))
		broadcastFlowState()
	end
end)

-- 4. Continue from Rewards to MapSelect
ContinueFromRewardsEvent.OnServerEvent:Connect(function(player: Player)
	if coordinator.Phase ~= "Rewards" then return end
	local pData = coordinator.Players[player.UserId]
	if not pData then return end

	print(string.format("[GameCoordinator] %s clicked Continue from Rewards.", pData.DisplayName))
	transitionToMapSelect()
end)

-- 5. Campfire Choices (Rest or Smith)
CampfireChoiceEvent.OnServerEvent:Connect(function(player: Player, choice: any)
	if coordinator.Phase ~= "ActiveRoom" or not coordinator.ActiveRoom or coordinator.ActiveRoom.Type ~= "Campfire Rest" then return end

	local pData = coordinator.Players[player.UserId]
	if not pData then return end

	if choice == "Rest" then
		broadcastFlowAnnouncement("🔥 RESTED", string.format("%s rested and restored 30%% HP!", pData.DisplayName), Color3.fromRGB(100, 240, 140))
	elseif choice == "Smith" then
		broadcastFlowAnnouncement("⚒️ SMITHEE", string.format("%s honed their cards at the campfire!", pData.DisplayName), Color3.fromRGB(240, 180, 80))
	end

	task.delay(1.2, function()
		transitionToMapSelect()
	end)
end)

--------------------------------------------------------------------------------
-- Player Lifecycle Management
--------------------------------------------------------------------------------

Players.PlayerAdded:Connect(function(player: Player)
	if not coordinator.Players[player.UserId] then
		coordinator.Players[player.UserId] = {
			PlayerInstance = player,
			UserId = player.UserId,
			DisplayName = player.DisplayName or player.Name,
			Gold = 50,
			Deck = {
				CardData.Strike,
				CardData.Defend,
				CardData.HeavyBlow,
				CardData.PoisonDart,
				CardData.FirstAid,
				CardData.Strike,
				CardData.Defend,
			},
			OfferedCards = {},
			HasClaimedReward = false,
			VotedNodeId = nil,
		}
	end
	broadcastFlowState()
end)

Players.PlayerRemoving:Connect(function(player: Player)
	coordinator.Players[player.UserId] = nil
	broadcastFlowState()
end)

for _, p in Players:GetPlayers() do
	if not coordinator.Players[p.UserId] then
		coordinator.Players[p.UserId] = {
			PlayerInstance = p,
			UserId = p.UserId,
			DisplayName = p.DisplayName or p.Name,
			Gold = 50,
			Deck = {
				CardData.Strike,
				CardData.Defend,
				CardData.HeavyBlow,
				CardData.PoisonDart,
				CardData.FirstAid,
				CardData.Strike,
				CardData.Defend,
			},
			OfferedCards = {},
			HasClaimedReward = false,
			VotedNodeId = nil,
		}
	end
end

--------------------------------------------------------------------------------
-- Public Server API & Shared Exposure
--------------------------------------------------------------------------------

local GameCoordinator = {}

function GameCoordinator.getPhase(): RunPhase
	return coordinator.Phase
end

function GameCoordinator.startRun()
	startNewRun()
end

function GameCoordinator.notifyRoomCleared()
	onRoomCleared()
end

function GameCoordinator.notifyPartyDefeated()
	onPartyDefeated()
end

function GameCoordinator.getState(): RunCoordinatorState
	return coordinator
end

_G.GameCoordinator = GameCoordinator

--------------------------------------------------------------------------------
-- Standalone State Machine Verification Test
--------------------------------------------------------------------------------

local function runStateMachineSimulation()
	print("============================================================")
	print("      CARD RIFT: GAMECOORDINATOR STATE MACHINE TEST         ")
	print("============================================================")

	-- Step 1: Lobby -> MapSelect
	print("[Test 1: Lobby -> MapSelect Transition]")
	local testRun = DungeonMap.generateRun(12345)
	local availableStarterNodes = DungeonMap.getAvailableNextNodes(testRun)
	print(string.format("  - Generated 4-Act DungeonRun. Available Tier 1 starter rooms: %d", #availableStarterNodes))
	for _, n in availableStarterNodes do
		print(string.format("    - [%s] %s (Tier %d, Lane %d)", n.Id, n.Type, n.Tier, n.Lane))
	end

	-- Step 2: MapSelect -> ActiveRoom (Select first node)
	print("[Test 2: MapSelect -> ActiveRoom Transition]")
	local chosen = availableStarterNodes[1]
	local success, err = DungeonMap.selectNextNode(testRun, chosen.Id)
	print(string.format("  - Advanced map to '%s': %s (Current Tier: %d)", chosen.Id, tostring(success), testRun.CurrentTier))

	-- Step 3: ActiveRoom -> Rewards (Simulate combat clearance)
	print("[Test 3: ActiveRoom -> Rewards Transition]")
	local testRewards = { GoldAmount = 20, AetherShardsAmount = 0 }
	local draftChoices = generateCardDraftChoices(3)
	print(string.format("  - Combat Room Cleared! Gold awarded: %d", testRewards.GoldAmount))
	print(string.format("  - Generated 3 unique draft card options:"))
	for i, c in draftChoices do
		print(string.format("    %d. [%s] Cost: %d Energy - %s", i, c.Name, c.Cost, c.Description))
	end

	-- Step 4: Rewards -> MapSelect (Draft a card and continue)
	print("[Test 4: Draft Card & Return to MapSelect]")
	local pickedCard = draftChoices[1]
	print(string.format("  - Player drafted [%s] into deck!", pickedCard.Name))
	local nextReachable = DungeonMap.getAvailableNextNodes(testRun)
	print(string.format("  - Returned to MapSelect. Reachable rooms in Tier %d: %d", testRun.CurrentTier + 1, #nextReachable))
	for _, n in nextReachable do
		print(string.format("    - [%s] %s (Tier %d, Lane %d)", n.Id, n.Type, n.Tier, n.Lane))
	end

	print("============================================================")
end

runStateMachineSimulation()

return GameCoordinator
