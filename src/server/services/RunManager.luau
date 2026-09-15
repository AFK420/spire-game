--!strict

--[=[
	RunManager ModuleScript
	Mapped to: ServerScriptService.Server.services.RunManager
	Single Authoritative State Owner for active Dungeon Runs in Card Rift: Co-op Dungeon:
	1. Owns canonical RunState (Lobby -> MapSelect -> ActiveRoom -> Rewards -> Victory/Defeat).
	2. Manages co-op party lifecycle (1 to 4 players, joining, leaving, reconnection).
	3. Interacts with DungeonService for procedural map traversal and node voting.
	4. Triggers CombatService when entering combat/elite/boss rooms.
	5. Handles post-encounter universal 3-card drafting and Aether Shard meta-rewards.
	6. Emits synchronized RunSnapshot DTOs to clients via NetworkService.
]=]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CardData = require(Shared:WaitForChild("CardData") :: ModuleScript)
local DungeonMap = require(Shared:WaitForChild("DungeonMap") :: ModuleScript)
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)

local servicesFolder = script.Parent
local CardService = require(servicesFolder:WaitForChild("CardService") :: ModuleScript)
local ClassService = require(servicesFolder:WaitForChild("ClassService") :: ModuleScript)
local DungeonService = require(servicesFolder:WaitForChild("DungeonService") :: ModuleScript)
local NetworkService = require(servicesFolder:WaitForChild("NetworkService") :: ModuleScript)
local PersistenceService = require(servicesFolder:WaitForChild("PersistenceService") :: ModuleScript)
local RelicService = require(servicesFolder:WaitForChild("RelicService") :: ModuleScript)

-- Forward declaration for circular reference avoidance
local CombatService: any = nil

local RunManager = {}

--------------------------------------------------------------------------------
-- Authoritative Run State
--------------------------------------------------------------------------------

local currentRun: StateTypes.RunState = {
	RunId = "run_init",
	Seed = 0,
	Phase = "Lobby",
	ActIndex = 1,
	CurrentTier = 0,
	CurrentNodeId = nil,
	ClearedNodeIds = {},
	AvailableNodeIds = {},
	PartyMembers = {},
	ActiveRoom = nil,
	ActiveCombat = nil,
	PendingRewards = nil,
}

local internalDungeonRun: DungeonMap.DungeonRun? = nil

--------------------------------------------------------------------------------
-- Snapshot Helpers
--------------------------------------------------------------------------------

function RunManager.getRunSnapshotForPlayer(player: Player): StateTypes.RunSnapshot
	local actName = "Act 1: The Forsaken Ascent"
	if internalDungeonRun and internalDungeonRun.Acts[internalDungeonRun.CurrentActIndex] then
		actName = internalDungeonRun.Acts[internalDungeonRun.CurrentActIndex].Name
	end

	local partyViews: { [string]: StateTypes.PlayerView } = {}
	for pUserId, pState in currentRun.PartyMembers do
		local handCount = 0
		for _ in pState.Hand do handCount += 1 end

		partyViews[tostring(pUserId)] = {
			UserId = pUserId,
			DisplayName = pState.DisplayName,
			ClassId = pState.ClassId,
			SubclassId = pState.SubclassId,
			HP = pState.Resources.HP,
			MaxHP = pState.Resources.MaxHP,
			Shield = pState.Resources.Shield,
			Energy = pState.Resources.Energy,
			MaxEnergy = pState.Resources.MaxEnergy,
			HandCount = handCount,
			DeckCount = #pState.Deck,
			DiscardCount = #pState.DiscardPile,
			IsReady = pState.IsReady,
			IsDowned = pState.IsDowned,
			Gold = pState.Gold,
			RelicIds = pState.RelicIds,
		}
	end

	local rewardView = nil
	if currentRun.PendingRewards then
		local offeredViews: { StateTypes.CardView } = {}
		local offered = currentRun.PendingRewards.OfferedCardsByPlayer[player.UserId]
		if offered then
			for _, cardDef in offered do
				table.insert(offeredViews, {
					InstanceId = "draft_" .. cardDef.Id,
					DefinitionId = cardDef.Id,
					Name = cardDef.Name,
					Cost = cardDef.Cost,
					Description = cardDef.Description,
					Icon = cardDef.Icon,
					Color = cardDef.Color,
				})
			end
		end

		rewardView = {
			GoldAmount = currentRun.PendingRewards.GoldAmount,
			AetherShardsAmount = currentRun.PendingRewards.AetherShardsAmount,
			OfferedCards = offeredViews,
			HasClaimed = currentRun.PendingRewards.ClaimedCards[player.UserId] or false,
		}
	end

	return {
		RunId = currentRun.RunId,
		Phase = currentRun.Phase,
		ActIndex = currentRun.ActIndex,
		ActName = actName,
		CurrentTier = currentRun.CurrentTier,
		CurrentNodeId = currentRun.CurrentNodeId,
		ClearedNodeIds = currentRun.ClearedNodeIds,
		AvailableNodeIds = currentRun.AvailableNodeIds,
		Party = partyViews,
		Rewards = rewardView,
		Message = nil,
	}
end

function RunManager.broadcastRunSnapshots(message: string?)
	for _, player in Players:GetPlayers() do
		local snapshot = RunManager.getRunSnapshotForPlayer(player)
		snapshot.Message = message
		NetworkService.sendRunState(player, snapshot)
	end
end

--------------------------------------------------------------------------------
-- Party Lifecycle
--------------------------------------------------------------------------------

function RunManager.addPlayer(player: Player): StateTypes.PlayerState
	local userId = player.UserId
	if currentRun.PartyMembers[userId] then
		currentRun.PartyMembers[userId].PlayerInstance = player
		return currentRun.PartyMembers[userId]
	end

	local pState: StateTypes.PlayerState = {
		UserId = userId,
		PlayerInstance = player,
		DisplayName = player.DisplayName or player.Name,
		ClassId = "Warlord",
		SubclassId = "Berserker",
		Resources = {
			HP = 100,
			MaxHP = 100,
			Shield = 0,
			Energy = 3,
			MaxEnergy = 3,
		},
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = { "Anchor" }, -- Default starter relic
		Gold = 50,
		IsReady = false,
		IsDowned = false,
		VotedNodeId = nil,
	}

	currentRun.PartyMembers[userId] = pState
	ClassService.applyClassToPlayer(pState)

	RunManager.broadcastRunSnapshots(string.format("%s joined the party!", player.DisplayName))
	return pState
end

function RunManager.removePlayer(player: Player)
	local userId = player.UserId
	if currentRun.PartyMembers[userId] then
		currentRun.PartyMembers[userId] = nil
		RunManager.broadcastRunSnapshots(string.format("%s left the party.", player.DisplayName))
	end
end

--------------------------------------------------------------------------------
-- Universal Card Draft Generation (3 Choices per Player)
--------------------------------------------------------------------------------

local function generateDraftChoices(): { CardData.Card }
	local pool = {
		CardData.Strike,
		CardData.Defend,
		CardData.HeavyBlow,
		CardData.PoisonDart,
		CardData.FirstAid,
	}

	local rng = Random.new()
	for i = #pool, 2, -1 do
		local j = rng:NextInteger(1, i)
		pool[i], pool[j] = pool[j], pool[i]
	end

	local draft = {}
	for i = 1, math.min(3, #pool) do
		table.insert(draft, pool[i])
	end
	return draft
end

--------------------------------------------------------------------------------
-- Run State Machine Transitions
--------------------------------------------------------------------------------

-- Lobby -> MapSelect
function RunManager.startRun(): boolean
	if currentRun.Phase ~= "Lobby" then
		warn("[RunManager] Cannot start run outside Lobby.")
		return false
	end

	print("[RunManager] Initializing new DungeonRun...")
	internalDungeonRun = DungeonService.generateRun()

	local seed = internalDungeonRun.Seed
	local runId = string.format("run_%d_%s", seed, HttpService:GenerateGUID(false):sub(1, 6))

	currentRun.RunId = runId
	currentRun.Seed = seed
	currentRun.Phase = "MapSelect"
	currentRun.ActIndex = 1
	currentRun.CurrentTier = 0
	currentRun.CurrentNodeId = nil
	currentRun.ClearedNodeIds = {}
	currentRun.ActiveRoom = nil
	currentRun.ActiveCombat = nil
	currentRun.PendingRewards = nil

	-- Refresh available starting nodes
	local availableNodes = DungeonService.getAvailableNodes(internalDungeonRun)
	table.clear(currentRun.AvailableNodeIds)
	for _, n in availableNodes do
		table.insert(currentRun.AvailableNodeIds, n.Id)
	end

	-- Reset party stats & decks
	for _, pState in currentRun.PartyMembers do
		pState.VotedNodeId = nil
		pState.IsReady = false
		pState.IsDowned = false
		pState.Resources.HP = pState.Resources.MaxHP
		pState.Resources.Shield = 0
		pState.Resources.Energy = pState.Resources.MaxEnergy
		ClassService.applyClassToPlayer(pState)
	end

	RunManager.broadcastRunSnapshots("The Rift has opened! Select your starting path on the Map.")
	NetworkService.broadcastAnnouncement("EXPEDITION BEGINS", "Choose your path through the Dungeon!", Color3.fromRGB(60, 200, 255))
	return true
end

-- Players vote or travel to a connected map node
function RunManager.voteMapNode(player: Player, targetNodeId: string): (boolean, string?)
	if currentRun.Phase ~= "MapSelect" or not internalDungeonRun then
		return false, "Not currently on MapSelect phase."
	end

	local pState = currentRun.PartyMembers[player.UserId]
	if not pState then return false, "Player not in party." end

	-- Check if targetNodeId is in available nodes
	local isAvailable = false
	for _, id in currentRun.AvailableNodeIds do
		if id == targetNodeId then
			isAvailable = true
			break
		end
	end

	if not isAvailable then
		return false, "Target room is not currently reachable."
	end

	pState.VotedNodeId = targetNodeId

	-- Check if all players have voted or if majority reached
	local votes: { [string]: number } = {}
	local totalVoters = 0
	for _, member in currentRun.PartyMembers do
		totalVoters += 1
		if member.VotedNodeId then
			votes[member.VotedNodeId] = (votes[member.VotedNodeId] or 0) + 1
		end
	end

	local winningNodeId: string? = nil
	for nodeId, count in votes do
		if count >= math.ceil(totalVoters / 2) then
			winningNodeId = nodeId
			break
		end
	end

	if winningNodeId then
		return RunManager.travelToNode(winningNodeId)
	else
		RunManager.broadcastRunSnapshots(string.format("%s voted for room %s", player.DisplayName, targetNodeId))
		return true, nil
	end
end

-- Executes travel to the node and transitions to ActiveRoom
function RunManager.travelToNode(targetNodeId: string): (boolean, string?)
	if not internalDungeonRun then return false, "No active run." end

	local success, err = DungeonService.selectNode(internalDungeonRun, targetNodeId)
	if not success then
		return false, err
	end

	local node = DungeonService.getNode(internalDungeonRun, targetNodeId)
	if not node then return false, "Node not found." end

	currentRun.CurrentNodeId = targetNodeId
	currentRun.CurrentTier = node.Tier
	currentRun.ActIndex = node.Act
	table.insert(currentRun.ClearedNodeIds, targetNodeId)

	-- Clear votes
	for _, member in currentRun.PartyMembers do
		member.VotedNodeId = nil
	end

	currentRun.ActiveRoom = {
		NodeId = node.Id,
		Type = node.Type,
		Tier = node.Tier,
		ActIndex = node.Act,
		RoomEncounterId = "enc_" .. node.Id,
		CampfireUsed = false,
		ShopVisited = false,
	}

	currentRun.Phase = "ActiveRoom"

	-- Route based on Room Type
	if node.Type == "Combat" or node.Type == "Elite Monster" or node.Type == "Act Boss" then
		if not CombatService then
			CombatService = require(servicesFolder:WaitForChild("CombatService") :: ModuleScript)
		end

		currentRun.ActiveCombat = CombatService.startCombat(
			currentRun.ActiveRoom.RoomEncounterId or "enc_def",
			node.Type,
			node.Tier,
			currentRun.PartyMembers,
			function(outcome: "Victory" | "Defeat")
				RunManager.onCombatCompleted(outcome, node)
			end
		)

	elseif node.Type == "Campfire Rest" then
		-- Campfire Rest heals all party members by 30% Max HP
		for _, member in currentRun.PartyMembers do
			local heal = math.floor(member.Resources.MaxHP * 0.3)
			member.Resources.HP = math.min(member.Resources.MaxHP, member.Resources.HP + heal)
		end
		RunManager.broadcastRunSnapshots("🔥 Rested at the Campfire (+30% HP recovered).")

	elseif node.Type == "Merchant Shop" then
		RunManager.broadcastRunSnapshots("💰 Visited the Merchant Shop. Supplies replenished.")
	end

	RunManager.broadcastRunSnapshots(string.format("Entered Room: %s (Tier %d)", node.Type, node.Tier))
	return true, nil
end

-- Callback from CombatService when an encounter finishes
function RunManager.onCombatCompleted(outcome: "Victory" | "Defeat", node: DungeonMap.DungeonNode)
	if outcome == "Defeat" then
		currentRun.Phase = "RunDefeat"
		RunManager.broadcastRunSnapshots("DEFEAT! The party has fallen.")
		NetworkService.broadcastAnnouncement("EXPEDITION FAILED", "Your party was overwhelmed by the rift.", Color3.fromRGB(255, 60, 60))
		return
	end

	-- Victory: Check if Final Boss (Act 4 Boss)
	if node.Type == "Act Boss" and node.Act == 4 then
		currentRun.Phase = "RunVictory"
		for _, member in currentRun.PartyMembers do
			if member.PlayerInstance then
				PersistenceService.recordRunVictory(member.PlayerInstance)
			end
		end
		RunManager.broadcastRunSnapshots("VICTORY! You have conquered the Card Rift!")
		NetworkService.broadcastAnnouncement("VICTORY ACHIEVED!", "The Spire has fallen! You are triumphant!", Color3.fromRGB(80, 255, 120))
		return
	end

	-- Distribute rewards
	RunManager.transitionToRewards(node.Type == "Elite Monster", node.Type == "Act Boss")
end

-- ActiveRoom -> Rewards
function RunManager.transitionToRewards(isElite: boolean, isBoss: boolean)
	currentRun.Phase = "Rewards"

	local gold = 25 + (isElite and 25 or 0) + (isBoss and 50 or 0)
	local shards = 5 + (isElite and 5 or 0) + (isBoss and 15 or 0)

	local offeredCards: { [number]: { CardData.Card } } = {}
	local claimedFlags: { [number]: boolean } = {}

	for userId, member in currentRun.PartyMembers do
		member.Gold += gold
		offeredCards[userId] = generateDraftChoices()
		claimedFlags[userId] = false

		if member.PlayerInstance then
			PersistenceService.addAetherShards(member.PlayerInstance, shards)
		end
	end

	currentRun.PendingRewards = {
		GoldAmount = gold,
		AetherShardsAmount = shards,
		OfferedCardsByPlayer = offeredCards,
		ClaimedCards = claimedFlags,
	}

	RunManager.broadcastRunSnapshots(string.format("Rewards Available! Claimed +%d Gold, +%d Shards.", gold, shards))
end

-- Claims one card from draft choices and adds it as a CardInstance to the player's deck
function RunManager.claimRewardCard(player: Player, cardDefId: string): (boolean, string?)
	if currentRun.Phase ~= "Rewards" or not currentRun.PendingRewards then
		return false, "Not in Rewards phase."
	end

	local userId = player.UserId
	local member = currentRun.PartyMembers[userId]
	if not member then return false, "Player not in party." end

	if currentRun.PendingRewards.ClaimedCards[userId] then
		return false, "Reward already claimed."
	end

	-- Check if card is among offered cards
	local offered = currentRun.PendingRewards.OfferedCardsByPlayer[userId]
	if not offered then return false, "No offered cards." end

	local valid = false
	for _, cardDef in offered do
		if cardDef.Id == cardDefId then
			valid = true
			break
		end
	end

	if not valid then
		return false, "Card not in draft choices."
	end

	-- Instantiate card into player's deck
	local newCardInst = CardService.createCardInstance(cardDefId, userId)
	if newCardInst then
		table.insert(member.Deck, newCardInst)
	end

	currentRun.PendingRewards.ClaimedCards[userId] = true
	RunManager.broadcastRunSnapshots(string.format("%s drafted [%s]!", player.DisplayName, cardDefId))
	return true, nil
end

-- Leaves the Rewards screen and returns to MapSelect
function RunManager.continueFromRewards(player: Player): boolean
	if currentRun.Phase ~= "Rewards" and currentRun.Phase ~= "ActiveRoom" then
		return false
	end

	if not internalDungeonRun then return false end

	-- Update available nodes for next tier
	local available = DungeonService.getAvailableNodes(internalDungeonRun)
	table.clear(currentRun.AvailableNodeIds)
	for _, node in available do
		table.insert(currentRun.AvailableNodeIds, node.Id)
	end

	currentRun.Phase = "MapSelect"
	currentRun.ActiveRoom = nil
	currentRun.ActiveCombat = nil
	currentRun.PendingRewards = nil

	RunManager.broadcastRunSnapshots("Select the next room on the Map.")
	return true
end

function RunManager.getRunState(): StateTypes.RunState
	return currentRun
end

function RunManager.getPlayerState(userId: number): StateTypes.PlayerState?
	return currentRun.PartyMembers[userId]
end

function RunManager.init()
	CombatService = require(servicesFolder:WaitForChild("CombatService") :: ModuleScript)

	Players.PlayerAdded:Connect(function(player: Player)
		RunManager.addPlayer(player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		RunManager.removePlayer(player)
	end)

	for _, p in Players:GetPlayers() do
		RunManager.addPlayer(p)
	end

	print("[RunManager] Initialized authoritative Dungeon Run state machine.")
end

return RunManager
