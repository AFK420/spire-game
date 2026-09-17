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

	=============================================================================
	SINGLE RUN ARCHITECTURAL ASSUMPTION & MULTI-RUN MIGRATION PATH:
	Current architecture assumes one active party and run per Roblox game server.
	To isolate this constraint for future scalability, all run state mutations
	and queries flow through encapsulated methods. When transitioning to multi-run,
	`currentRun` will be promoted to `activeRuns: { [string]: StateTypes.RunState }`
	without changing client network contracts or external service signatures.
	=============================================================================
]=]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CardData = require(Shared:WaitForChild("CardData") :: ModuleScript)
local DungeonMap = require(Shared:WaitForChild("DungeonMap") :: ModuleScript)
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)
local GameConfig = require(Shared:WaitForChild("GameConfig") :: ModuleScript)

local servicesFolder = script.Parent
local CardService = require(servicesFolder:WaitForChild("CardService") :: ModuleScript)
local ClassService = require(servicesFolder:WaitForChild("ClassService") :: ModuleScript)
local DungeonService = require(servicesFolder:WaitForChild("DungeonService") :: ModuleScript)
local NetworkService = require(servicesFolder:WaitForChild("NetworkService") :: ModuleScript)
local PersistenceService = require(servicesFolder:WaitForChild("PersistenceService") :: ModuleScript)
local SkillService = require(servicesFolder:WaitForChild("SkillService") :: ModuleScript)
local CardCollectionService = require(servicesFolder:WaitForChild("CardCollectionService") :: ModuleScript)

local CombatService: any = nil
local StatusService: any = nil

local function getCombatService(): any
	if not CombatService then
		local cs = servicesFolder:FindFirstChild("CombatService")
		if cs then
			CombatService = require(cs :: ModuleScript)
		end
	end
	return CombatService
end

local function getStatusService(): any
	if not StatusService then
		local ss = servicesFolder:FindFirstChild("StatusService")
		if ss then
			StatusService = require(ss :: ModuleScript)
		end
	end
	return StatusService
end

local RunManager = {}

--------------------------------------------------------------------------------
-- Isolated Authoritative Run State
--------------------------------------------------------------------------------

local function createInitialRun(runId: string?): StateTypes.RunState
	return {
		RunId = runId or "run_init",
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
end

local liveRun: StateTypes.RunState = createInitialRun("run_init")
local isolatedTestRun: StateTypes.RunState? = nil
local isIsolatedTesting = false

local currentRun: StateTypes.RunState = liveRun
local internalDungeonRun: DungeonMap.DungeonRun? = nil
local liveDungeonRun: DungeonMap.DungeonRun? = nil

function RunManager.beginTestIsolation()
	if not isIsolatedTesting then
		liveDungeonRun = internalDungeonRun
		isIsolatedTesting = true
	end
	isolatedTestRun = createInitialRun("run_test_isolated")
	currentRun = isolatedTestRun
	internalDungeonRun = nil

	local cs = getCombatService()
	if cs and cs.beginTestIsolation then
		cs.beginTestIsolation()
	end
	local ss = getStatusService()
	if ss and ss.beginTestIsolation then
		ss.beginTestIsolation()
	end
end

function RunManager.endTestIsolation()
	isIsolatedTesting = false
	isolatedTestRun = nil
	currentRun = liveRun
	internalDungeonRun = liveDungeonRun
	liveDungeonRun = nil

	local cs = getCombatService()
	if cs and cs.endTestIsolation then
		cs.endTestIsolation()
	end
	local ss = getStatusService()
	if ss and ss.endTestIsolation then
		ss.endTestIsolation()
	end

	-- Safe reconnect sync: ensure real players connected during isolation are registered in liveRun
	local okPlayers, players = pcall(function()
		return Players:GetPlayers()
	end)
	if okPlayers and typeof(players) == "table" then
		for _, player in ipairs(players) do
			if player and player.UserId and not liveRun.PartyMembers[player.UserId] then
				RunManager.addPlayer(player)
			end
		end
	end
end

function RunManager.isTestIsolationActive(): boolean
	return isIsolatedTesting
end

function RunManager.runWithTestIsolation<T>(testFn: () -> T): (boolean, any)
	RunManager.beginTestIsolation()
	local ok, result = pcall(testFn)
	RunManager.endTestIsolation()
	return ok, result
end

function RunManager.getLiveRunState(): StateTypes.RunState
	return liveRun
end

--------------------------------------------------------------------------------
-- Snapshot Generators
--------------------------------------------------------------------------------

function RunManager.getRunSnapshotForPlayer(player: any): StateTypes.RunSnapshot
	local userId = (typeof(player) == "table" and player.UserId) or (typeof(player) == "Instance" and player.UserId) or player
	local isReal = (typeof(player) == "Instance" and player:IsA("Player"))
	if typeof(player) == "table" and player._isSimulatedRealPlayer == true then
		isReal = true
	end
	local runToRead = if (isIsolatedTesting and isReal and liveRun.PartyMembers[userId]) then liveRun else currentRun
	local dRun = if (isIsolatedTesting and isReal and liveRun.PartyMembers[userId]) then liveDungeonRun else internalDungeonRun
	local actName = "Act 1: The Forsaken Ascent"
	if dRun and dRun.Acts[dRun.CurrentActIndex] then
		actName = dRun.Acts[dRun.CurrentActIndex].Name
	end

	local partyViews: { [string]: StateTypes.PlayerView } = {}
	for pUserId, pState in runToRead.PartyMembers do
		local handCount = 0
		for _ in pState.Hand do handCount += 1 end

		local equippedItemsSummary: { [string]: string } = {}
		if pState.EquippedItems then
			for slot, item in pState.EquippedItems do
				if item then
					equippedItemsSummary[slot] = item.DefinitionId
				end
			end
		end

		local equippedSkillsSummary: { [string]: string } = {}
		if pState.EquippedSkills then
			for slot, skill in pState.EquippedSkills do
				if skill then
					equippedSkillsSummary[slot] = skill.DefinitionId
				end
			end
		end

		local skillInventoryList: { string } = {}
		if pState.SkillInventory then
			for _, skill in ipairs(pState.SkillInventory) do
				table.insert(skillInventoryList, skill.DefinitionId)
			end
		end

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
			ClassLocked = pState.ClassLocked or false,
			Gold = pState.Gold,
			RelicIds = pState.RelicIds,
			EquippedItems = equippedItemsSummary,
			EquippedSkills = equippedSkillsSummary,
			SkillInventory = skillInventoryList,
			UnlockedPassives = table.clone(pState.UnlockedPassives or {}),
			PassivePoints = pState.PassivePoints or 0,
		}
	end

	local rewardView = nil
	if runToRead.PendingRewards then
		local offeredViews: { StateTypes.CardView } = {}
		local offered = runToRead.PendingRewards.OfferedCardsByPlayer[userId]
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
			GoldAmount = runToRead.PendingRewards.GoldAmount,
			AetherShardsAmount = runToRead.PendingRewards.AetherShardsAmount,
			OfferedCards = offeredViews,
			HasClaimed = runToRead.PendingRewards.ClaimedCards[userId] or false,
		}
	end

	local mapNodesList: { StateTypes.MapNodeView } = {}
	if dRun and dRun.Acts and dRun.Acts[dRun.CurrentActIndex] then
		local currentAct = dRun.Acts[dRun.CurrentActIndex]
		if currentAct and currentAct.NodesById then
			local clearedSet: { [string]: boolean } = {}
			for _, cId in runToRead.ClearedNodeIds do
				clearedSet[cId] = true
			end
			local availableSet: { [string]: boolean } = {}
			for _, aId in runToRead.AvailableNodeIds do
				availableSet[aId] = true
			end

			for _, node in currentAct.NodesById do
				table.insert(mapNodesList, {
					Id = node.Id,
					Act = node.Act,
					Tier = node.Tier,
					Lane = node.Lane,
					Type = node.Type :: StateTypes.ActiveRoomType,
					ConnectedNodeIds = table.clone(node.OutgoingNodeIds),
					IsAvailable = (availableSet[node.Id] == true),
					IsCleared = (clearedSet[node.Id] == true),
					IsCurrent = (runToRead.CurrentNodeId == node.Id),
				})
			end
		end
	end

	return {
		RunId = runToRead.RunId,
		Phase = runToRead.Phase,
		ActIndex = runToRead.ActIndex,
		ActName = actName,
		CurrentTier = runToRead.CurrentTier,
		CurrentNodeId = runToRead.CurrentNodeId,
		ClearedNodeIds = runToRead.ClearedNodeIds,
		AvailableNodeIds = runToRead.AvailableNodeIds,
		MapNodes = mapNodesList,
		Party = partyViews,
		Rewards = rewardView,
		Message = nil,
	}
end

function RunManager.broadcastRunSnapshots(message: string?, isLiveAction: boolean?)
	if isIsolatedTesting and not isLiveAction then return end
	local players = Players:GetPlayers()
	if #players == 0 then return end
	for _, player in players do
		local snapshot = RunManager.getRunSnapshotForPlayer(player)
		snapshot.Message = message
		NetworkService.sendRunState(player, snapshot)
	end
end

function RunManager.sendRunSnapshot(player: any, message: string?)
	local isRealPlayer = (typeof(player) == "Instance" and player:IsA("Player"))
	if typeof(player) == "table" and player._isSimulatedRealPlayer == true then
		isRealPlayer = true
	end
	if isIsolatedTesting and not isRealPlayer then return end
	local snapshot = RunManager.getRunSnapshotForPlayer(player)
	snapshot.Message = message
	NetworkService.sendRunState(player, snapshot)
end

--------------------------------------------------------------------------------
-- Party Lifecycle & Reconnection Resilience
--------------------------------------------------------------------------------

function RunManager.addPlayer(player: any): StateTypes.PlayerState
	local userId = player.UserId
	local displayName = player.DisplayName or player.Name or ("Player_" .. tostring(userId))
	local isRealPlayer = (typeof(player) == "Instance" and player:IsA("Player"))
	if typeof(player) == "table" and player._isSimulatedRealPlayer == true then
		isRealPlayer = true
	end

	-- Player rejoining existing run: reattach instance without corrupting state
	if isIsolatedTesting and isRealPlayer then
		if liveRun.PartyMembers[userId] then
			local existing = liveRun.PartyMembers[userId]
			existing.PlayerInstance = typeof(player) == "Instance" and player or nil
			existing.DisplayName = displayName
			existing.IsConnected = true
			RunManager.broadcastRunSnapshots(string.format("%s reconnected.", displayName), true)
			return existing
		end
	elseif currentRun.PartyMembers[userId] then
		local existing = currentRun.PartyMembers[userId]
		existing.PlayerInstance = isRealPlayer and (typeof(player) == "Instance" and player or nil) or nil
		existing.DisplayName = displayName
		existing.IsConnected = true
		if not isIsolatedTesting or isRealPlayer then
			RunManager.broadcastRunSnapshots(string.format("%s reconnected.", displayName), isRealPlayer)
		end
		return existing
	end

	local targetRun = if (isIsolatedTesting and isRealPlayer) then liveRun else currentRun
	local partyCount = 0
	for _ in targetRun.PartyMembers do
		partyCount += 1
	end
	if partyCount >= GameConfig.Coop.MaxPartySize then
		warn(string.format("[RunManager] Cannot add player %s: party is full (%d/%d).", displayName, partyCount, GameConfig.Coop.MaxPartySize))
		return nil
	end

	if targetRun.Phase ~= "Lobby" then
		warn(string.format("[RunManager] Cannot add player %s to active party: run is in phase %s.", displayName, targetRun.Phase))
		return nil
	end

	local pState: StateTypes.PlayerState = {
		UserId = userId,
		PlayerInstance = typeof(player) == "Instance" and player or nil,
		DisplayName = displayName,
		ClassId = "Warlord",
		SubclassId = "Berserker",
		Resources = {
			HP = GameConfig.Combat.DefaultBaseHP,
			MaxHP = GameConfig.Combat.DefaultBaseHP,
			Shield = 0,
			Energy = GameConfig.Combat.DefaultStartingEnergy,
			MaxEnergy = GameConfig.Combat.DefaultStartingEnergy,
		},
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = { "Anchor" },
		Gold = GameConfig.Dungeon.StarterGold,
		IsReady = false,
		IsDowned = false,
		IsConnected = true,
		ClassLocked = false,
		VotedNodeId = nil,
		EquippedItems = {},
		EquipmentInventory = {},
		EquippedSkills = {},
		SkillInventory = {},
		UnlockedSkills = {},
		UnlockedPassives = {},
		PassivePoints = 0,
	}

	SkillService.unlockSkill(pState, "HeroicStrike")
	SkillService.unlockSkill(pState, "AegisBarrier")
	SkillService.unlockSkill(pState, "BattleRally")
	SkillService.unlockSkill(pState, "Whirlwind")

	if isIsolatedTesting and isRealPlayer then
		local realMembers = liveRun.PartyMembers
		realMembers[userId] = pState
	else
		currentRun.PartyMembers[userId] = pState
	end
	ClassService.initializePlayerForRun(pState)

	if not isIsolatedTesting or isRealPlayer then
		RunManager.broadcastRunSnapshots(string.format("%s joined the expedition.", displayName), isRealPlayer)
	end
	return pState
end

function RunManager.removePlayer(player: any)
	local userId = player.UserId
	local isRealPlayer = (typeof(player) == "Instance" and player:IsA("Player"))
	if typeof(player) == "table" and player._isSimulatedRealPlayer == true then
		isRealPlayer = true
	end
	local targetRun = if (isIsolatedTesting and isRealPlayer) then liveRun else currentRun
	local member = targetRun.PartyMembers[userId]
	if not member then return end

	member.PlayerInstance = nil
	member.IsConnected = false

	-- Save profile and clean rate-limit buckets
	if typeof(player) == "Instance" then
		PersistenceService.saveProfile(player)
	end
	NetworkService.cleanPlayer(userId)

	if targetRun.Phase == "Lobby" then
		targetRun.PartyMembers[userId] = nil
	end

	if not isIsolatedTesting or isRealPlayer then
		RunManager.broadcastRunSnapshots(string.format("%s left the party.", member.DisplayName), isRealPlayer)
	end
end

--------------------------------------------------------------------------------
-- Universal 3-Card Draft Choices
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
	for i = 1, math.min(GameConfig.Rewards.CardDraftChoicesCount, #pool) do
		table.insert(draft, pool[i])
	end
	return draft
end

--------------------------------------------------------------------------------
-- State Machine Transitions
--------------------------------------------------------------------------------

function RunManager.startRun(initiator: any?): boolean
	local isReal = (typeof(initiator) == "Instance" and initiator:IsA("Player"))
	if typeof(initiator) == "table" and initiator._isSimulatedRealPlayer == true then
		isReal = true
	end
	local runToStart = if (isIsolatedTesting and isReal) then liveRun else currentRun
	if runToStart.Phase ~= "Lobby" then
		warn("[RunManager] Cannot start run outside Lobby.")
		return false
	end

	-- 1. Validate connected party members >= 1
	local connectedMembers = 0
	for _, pState in runToStart.PartyMembers do
		if pState.IsConnected ~= false then
			connectedMembers += 1
		end
	end
	if connectedMembers < 1 then
		warn("[RunManager] Cannot start run: no connected party members.")
		return false
	end

	-- 2. Validate initiator belongs to the party (if initiator specified)
	if initiator ~= nil then
		local initUserId = (typeof(initiator) == "Instance" and initiator.UserId) or (typeof(initiator) == "table" and initiator.UserId) or initiator
		if typeof(initUserId) == "number" and not runToStart.PartyMembers[initUserId] then
			warn(string.format("[RunManager] Cannot start run: initiator %s is not in the party.", tostring(initUserId)))
			return false
		end
	end

	-- 3. Validate all connected party members have locked their class
	for _, pState in runToStart.PartyMembers do
		if pState.IsConnected ~= false and not pState.ClassLocked then
			warn(string.format("[RunManager] Cannot start run: player %s has not locked their class.", pState.DisplayName))
			return false
		end
	end

	-- 4. Validate profile is loaded for real connected players (fail-closed guard)
	for _, pState in runToStart.PartyMembers do
		if pState.IsConnected ~= false and pState.PlayerInstance then
			if not PersistenceService.isProfileLoaded(pState.PlayerInstance) then
				warn(string.format("[RunManager] Cannot start run: profile for player %s failed to load.", pState.DisplayName))
				return false
			end
		end
	end

	local dungeon = DungeonService.generateRun()
	if isIsolatedTesting then
		if isReal then
			liveDungeonRun = dungeon
		else
			internalDungeonRun = dungeon
		end
	else
		internalDungeonRun = dungeon
	end

	local seed = dungeon.Seed
	local runId = string.format("run_%d_%s", seed, HttpService:GenerateGUID(false):sub(1, 6))

	runToStart.RunId = runId
	runToStart.Seed = seed
	runToStart.Phase = "MapSelect"
	runToStart.ActIndex = 1
	runToStart.CurrentTier = 0
	runToStart.CurrentNodeId = nil
	runToStart.ClearedNodeIds = {}
	runToStart.ActiveRoom = nil
	runToStart.ActiveCombat = nil
	runToStart.PendingRewards = nil

	-- Refresh available starting nodes
	local availableNodes = DungeonService.getAvailableNodes(dungeon)
	table.clear(runToStart.AvailableNodeIds)
	for _, n in availableNodes do
		table.insert(runToStart.AvailableNodeIds, n.Id)
	end

	-- Prepare all players
	for _, pState in runToStart.PartyMembers do
		pState.VotedNodeId = nil
		pState.Resources.HP = pState.Resources.MaxHP
		ClassService.resetCombatResources(pState)
		CardService.resetCombatPiles(pState)

		-- Record run start in profile exactly once when run begins
		local playerRef = pState.PlayerInstance or { UserId = pState.UserId }
		PersistenceService.recordRunStarted(playerRef)
	end

	if not isIsolatedTesting or isReal then
		RunManager.broadcastRunSnapshots("Expedition started! Choose your path on the Map.", true)
		NetworkService.broadcastAnnouncement("EXPEDITION BEGINS", "Choose your path through the Dungeon!", Color3.fromRGB(60, 200, 255))
	end
	return true
end

function RunManager.voteMapNode(player: any, targetNodeId: string): (boolean, string?)
	local isReal = (typeof(player) == "Instance" and player:IsA("Player"))
	if typeof(player) == "table" and player._isSimulatedRealPlayer == true then
		isReal = true
	end
	local runToUse = if (isIsolatedTesting and isReal) then liveRun else currentRun
	local dRun = if (isIsolatedTesting and isReal) then liveDungeonRun else internalDungeonRun
	if runToUse.Phase ~= "MapSelect" or not dRun then
		return false, "Not currently on MapSelect phase."
	end

	local pState = runToUse.PartyMembers[player.UserId]
	if not pState then return false, "Player not in party." end
	if pState.IsConnected == false then
		return false, "Player is disconnected."
	end

	local isAvailable = false
	for _, id in runToUse.AvailableNodeIds do
		if id == targetNodeId then
			isAvailable = true
			break
		end
	end

	if not isAvailable then
		return false, "Target room is not currently reachable."
	end

	pState.VotedNodeId = targetNodeId

	-- Consensus check among connected party members
	local votes: { [string]: number } = {}
	local totalVoters = 0
	local totalCastVotes = 0
	for _, member in runToUse.PartyMembers do
		if member.IsConnected ~= false then
			totalVoters += 1
			if member.VotedNodeId then
				totalCastVotes += 1
				votes[member.VotedNodeId] = (votes[member.VotedNodeId] or 0) + 1
			end
		end
	end

	local winningNodeId: string? = nil
	if totalVoters > 0 then
		local requiredMajority = math.floor(totalVoters / 2) + 1
		for nodeId, count in votes do
			if count >= requiredMajority then
				winningNodeId = nodeId
				break
			end
		end

		-- Deterministic tie-breaker ONLY after all connected players have voted
		if not winningNodeId and totalCastVotes >= totalVoters then
			local highestCount = 0
			local candidates: { string } = {}
			for nodeId, count in votes do
				if count > highestCount then
					highestCount = count
					candidates = { nodeId }
				elseif count == highestCount then
					table.insert(candidates, nodeId)
				end
			end
			table.sort(candidates)
			if #candidates > 0 then
				winningNodeId = candidates[1]
			end
		end
	end

	if winningNodeId then
		return RunManager.travelToNode(winningNodeId, isReal)
	else
		if not isIsolatedTesting or isReal then
			RunManager.broadcastRunSnapshots(string.format("%s voted for room %s", pState.DisplayName, targetNodeId), isReal)
		end
		return true, nil
	end
end

function RunManager.travelToNode(targetNodeId: string, isLiveAction: boolean?): (boolean, string?)
	local dRun = if (isIsolatedTesting and isLiveAction) then liveDungeonRun else internalDungeonRun
	local runToMutate = if (isIsolatedTesting and isLiveAction) then liveRun else currentRun
	if not dRun then return false, "No active run." end

	local success, err = DungeonService.selectNode(dRun, targetNodeId)
	if not success then return false, err end

	local node = DungeonService.getNode(dRun, targetNodeId)
	if not node then return false, "Node not found." end

	runToMutate.CurrentNodeId = targetNodeId
	runToMutate.CurrentTier = node.Tier
	runToMutate.ActIndex = node.Act
	table.insert(runToMutate.ClearedNodeIds, targetNodeId)

	for _, member in runToMutate.PartyMembers do
		member.VotedNodeId = nil
	end

	runToMutate.ActiveRoom = {
		NodeId = node.Id,
		Type = node.Type,
		Tier = node.Tier,
		ActIndex = node.Act,
		RoomEncounterId = "enc_" .. node.Id,
		CampfireUsed = false,
		ShopVisited = false,
	}

	runToMutate.Phase = "ActiveRoom"

	if node.Type == "Combat" or node.Type == "Elite Monster" or node.Type == "Act Boss" then
		if not CombatService then
			CombatService = require(servicesFolder:WaitForChild("CombatService") :: ModuleScript)
		end

		runToMutate.ActiveCombat = CombatService.startCombat(
			runToMutate.ActiveRoom.RoomEncounterId or "enc_def",
			node.Type,
			node.Tier,
			runToMutate.PartyMembers,
			function(outcome: "Victory" | "Defeat")
				RunManager.onCombatCompleted(outcome, node)
			end
		)

	elseif node.Type == "Campfire Rest" then
		for _, member in runToMutate.PartyMembers do
			local heal = math.floor(member.Resources.MaxHP * GameConfig.Dungeon.CampfireHealPercent)
			member.Resources.HP = math.min(member.Resources.MaxHP, member.Resources.HP + heal)
		end
		if not isIsolatedTesting or isLiveAction then
			RunManager.broadcastRunSnapshots("🔥 Rested at the Campfire (+30% HP recovered).", isLiveAction)
		end

	elseif node.Type == "Merchant Shop" then
		if not isIsolatedTesting or isLiveAction then
			RunManager.broadcastRunSnapshots("💰 Visited the Merchant Shop. Supplies replenished.", isLiveAction)
		end
	end

	if not isIsolatedTesting or isLiveAction then
		RunManager.broadcastRunSnapshots(string.format("Entered Room: %s (Tier %d)", node.Type, node.Tier), isLiveAction)
	end
	return true, nil
end

function RunManager.onCombatCompleted(outcome: "Victory" | "Defeat", node: DungeonMap.DungeonNode)
	if outcome == "Defeat" then
		currentRun.Phase = "RunDefeat"
		RunManager.broadcastRunSnapshots("DEFEAT! The party has fallen.")
		NetworkService.broadcastAnnouncement("EXPEDITION FAILED", "Your party was overwhelmed by the rift.", Color3.fromRGB(255, 60, 60))
		return
	end

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

	RunManager.transitionToRewards(node.Type == "Elite Monster", node.Type == "Act Boss")
end

function RunManager.transitionToRewards(isElite: boolean, isBoss: boolean)
	currentRun.Phase = "Rewards"

	local gold = GameConfig.Rewards.BaseCombatGold + (isElite and GameConfig.Rewards.EliteBonusGold or 0) + (isBoss and GameConfig.Rewards.BossBonusGold or 0)
	local shards = GameConfig.Rewards.BaseCombatShards + (isElite and GameConfig.Rewards.EliteBonusShards or 0) + (isBoss and GameConfig.Rewards.BossBonusShards or 0)

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

function RunManager.claimRewardCard(player: any, cardDefId: string): (boolean, string?)
	local isReal = (typeof(player) == "Instance" and player:IsA("Player"))
	if typeof(player) == "table" and player._isSimulatedRealPlayer == true then
		isReal = true
	end
	local runToUse = if (isIsolatedTesting and isReal) then liveRun else currentRun
	if runToUse.Phase ~= "Rewards" or not runToUse.PendingRewards then
		return false, "Not in Rewards phase."
	end

	local userId = player.UserId
	local member = runToUse.PartyMembers[userId]
	if not member then return false, "Player not in party." end

	if runToUse.PendingRewards.ClaimedCards[userId] then
		return false, "Reward already claimed."
	end

	local offered = runToUse.PendingRewards.OfferedCardsByPlayer[userId]
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

	local newCardInst = CardService.createCardInstance(cardDefId, userId)
	if newCardInst then
		table.insert(member.Deck, newCardInst)
	end

	-- Grant to permanent card collection
	local playerRef = member.PlayerInstance or player or { UserId = userId }
	CardCollectionService.grantCard(playerRef, cardDefId, 1)

	runToUse.PendingRewards.ClaimedCards[userId] = true
	if not isIsolatedTesting or isReal then
		RunManager.broadcastRunSnapshots(string.format("%s drafted [%s]!", member.DisplayName, cardDefId), isReal)
	end
	return true, nil
end

function RunManager.continueFromRewards(player: any): boolean
	local isReal = (typeof(player) == "Instance" and player:IsA("Player"))
	if typeof(player) == "table" and player._isSimulatedRealPlayer == true then
		isReal = true
	end
	local runToUse = if (isIsolatedTesting and isReal) then liveRun else currentRun
	local dRun = if (isIsolatedTesting and isReal) then liveDungeonRun else internalDungeonRun
	if runToUse.Phase ~= "Rewards" then
		return false
	end

	if not dRun then return false end

	local available = DungeonService.getAvailableNodes(dRun)
	table.clear(runToUse.AvailableNodeIds)
	for _, node in available do
		table.insert(runToUse.AvailableNodeIds, node.Id)
	end

	runToUse.Phase = "MapSelect"
	runToUse.ActiveRoom = nil
	runToUse.ActiveCombat = nil
	runToUse.PendingRewards = nil

	if not isIsolatedTesting or isReal then
		RunManager.broadcastRunSnapshots("Select the next room on the Map.", isReal)
	end
	return true
end

--------------------------------------------------------------------------------
-- Encapsulated State Access & Testing Reset
--------------------------------------------------------------------------------

function RunManager.getRunState(): StateTypes.RunState
	return currentRun
end

function RunManager.getRunById(runId: string): StateTypes.RunState?
	if currentRun.RunId == runId then
		return currentRun
	end
	if isIsolatedTesting and liveRun.RunId == runId then
		return liveRun
	end
	return nil
end

function RunManager.getPlayerState(playerOrUserId: any): StateTypes.PlayerState?
	local uid: number? = nil
	local isReal = false
	if typeof(playerOrUserId) == "number" then
		uid = playerOrUserId
	elseif typeof(playerOrUserId) == "Instance" and playerOrUserId:IsA("Player") then
		uid = playerOrUserId.UserId
		isReal = true
	elseif typeof(playerOrUserId) == "table" and typeof(playerOrUserId.UserId) == "number" then
		uid = playerOrUserId.UserId
		if playerOrUserId._isSimulatedRealPlayer == true then
			isReal = true
		end
	end
	if uid then
		if isIsolatedTesting then
			if isReal then
				return liveRun.PartyMembers[uid]
			else
				return currentRun.PartyMembers[uid]
			end
		end
		return currentRun.PartyMembers[uid]
	end
	return nil
end

function RunManager.getDungeonRun(): DungeonMap.DungeonRun?
	return internalDungeonRun
end

function RunManager.getLiveDungeonRun(): DungeonMap.DungeonRun?
	return liveDungeonRun
end

-- Resets existing party to clean Lobby state for a new expedition run
function RunManager.resetToLobby()
	currentRun.Phase = "Lobby"
	currentRun.ActIndex = 1
	currentRun.CurrentTier = 0
	currentRun.CurrentNodeId = nil
	currentRun.ClearedNodeIds = {}
	currentRun.AvailableNodeIds = {}
	currentRun.ActiveRoom = nil
	currentRun.ActiveCombat = nil
	currentRun.PendingRewards = nil
	internalDungeonRun = nil

	for _, member in currentRun.PartyMembers do
		member.ClassLocked = false
		member.IsReady = false
		member.IsDowned = false
		member.VotedNodeId = nil
		member.Gold = GameConfig.Dungeon.StarterGold
		member.RelicIds = { "Anchor" }
		ClassService.applyBaseClassStats(member)
		ClassService.initializeStartingDeck(member)
		ClassService.resetCombatResources(member)
	end

	if CombatService then
		CombatService.cleanupCombat()
	end

	if not isIsolatedTesting then
		RunManager.broadcastRunSnapshots("Returned to Lobby.")
	end
end

-- Resets the single run container to clean Lobby state (used for testing and new runs)
function RunManager.resetRunForTesting()
	local newRun = createInitialRun("run_test_" .. HttpService:GenerateGUID(false):sub(1, 6))
	if isIsolatedTesting then
		isolatedTestRun = newRun
		currentRun = isolatedTestRun
	else
		liveRun = newRun
		currentRun = liveRun
	end
	internalDungeonRun = nil
	if CombatService then
		CombatService.cleanupCombat()
	end
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

	print("[RunManager] Initialized authoritative single-run coordinator.")
end

return RunManager
