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
local SkillData = require(Shared:WaitForChild("SkillData") :: ModuleScript)

local servicesFolder = script.Parent
local CardService = require(servicesFolder:WaitForChild("CardService") :: ModuleScript)
local ClassService = require(servicesFolder:WaitForChild("ClassService") :: ModuleScript)
local DungeonService = require(servicesFolder:WaitForChild("DungeonService") :: ModuleScript)
local NetworkService = require(servicesFolder:WaitForChild("NetworkService") :: ModuleScript)
local PersistenceService = require(servicesFolder:WaitForChild("PersistenceService") :: ModuleScript)
local SkillService = require(servicesFolder:WaitForChild("SkillService") :: ModuleScript)
local RelicService = require(servicesFolder:WaitForChild("RelicService") :: ModuleScript)
local CardCollectionService = require(servicesFolder:WaitForChild("CardCollectionService") :: ModuleScript)

local CombatService: any = nil
local StatusService: any = nil
local ArenaVisualizer: any = nil

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

local function getArenaVisualizer(): any
	if not ArenaVisualizer then
		local av = servicesFolder:FindFirstChild("ArenaVisualizer")
		if av then
			ArenaVisualizer = require(av :: ModuleScript)
		end
	end
	return ArenaVisualizer
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
		StateRevision = 0,
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
	local runToRead = if (isIsolatedTesting and isReal) then liveRun else currentRun
	local dRun = if (isIsolatedTesting and isReal) then liveDungeonRun else internalDungeonRun
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
					NodeId = node.Id,
					Act = node.Act,
					Tier = node.Tier,
					Lane = node.Lane,
					Type = node.Type :: StateTypes.ActiveRoomType,
					ConnectedNodeIds = table.clone(node.OutgoingNodeIds),
					Connections = table.clone(node.OutgoingNodeIds),
					IsAvailable = (availableSet[node.Id] == true),
					Reachable = (availableSet[node.Id] == true),
					IsCleared = (clearedSet[node.Id] == true),
					Cleared = (clearedSet[node.Id] == true),
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
		StateRevision = runToRead.StateRevision or 0,
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

local function initializeSkillsForPlayer(pState: StateTypes.PlayerState, playerRef: any)
	-- 1. Always grant the 4 starter skills
	local starterSkills = { "HeroicStrike", "AegisBarrier", "BattleRally", "Whirlwind" }
	for _, skillId in ipairs(starterSkills) do
		SkillService.unlockSkill(pState, skillId)
	end

	-- 2. Read persistent profile and rehydrate unlocked skills
	local profile = PersistenceService.getProfile(playerRef)
	if profile and typeof(profile.UnlockedSkills) == "table" then
		for skillId, unlocked in pairs(profile.UnlockedSkills) do
			if unlocked == true and typeof(skillId) == "string" then
				local def = SkillData.getSkill(skillId)
				if def then
					if not def.RequiredClassId or def.RequiredClassId == pState.ClassId then
						SkillService.unlockSkill(pState, skillId)
					end
				end
			end
		end
	end
end

function RunManager.addPlayer(player: any): StateTypes.PlayerState?
	local userId = player.UserId
	local displayName = player.DisplayName or player.Name or ("Player_" .. tostring(userId))
	local isRealPlayer = (typeof(player) == "Instance" and player:IsA("Player"))
	if typeof(player) == "table" and player._isSimulatedRealPlayer == true then
		isRealPlayer = true
	end

	-- FAIL-CLOSED PROTECTION:
	-- For REAL Roblox Players only, require profile to be loaded before creating or initializing PlayerState
	if isRealPlayer and not PersistenceService.isProfileLoaded(player) then
		local loadState = PersistenceService.getLoadState(player)
		if loadState == "NotLoaded" then
			PersistenceService.loadProfile(player)
		end
		local waitStart = os.clock()
		while not PersistenceService.isProfileLoaded(player) and (os.clock() - waitStart < 5.0) do
			if PersistenceService.getLoadState(player) == "LoadFailed" then
				break
			end
			task.wait(0.05)
		end

		if not PersistenceService.isProfileLoaded(player) then
			warn(string.format("[RunManager] Authoritative profile not loaded for real player %s (UserId %d). Cannot add to party (fail-closed).", displayName, userId))
			return nil
		end
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

	initializeSkillsForPlayer(pState, player)

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
	elseif targetRun.Phase == "MapSelect" then
		-- Re-evaluate votes among remaining connected members so disconnected players do not deadlock progress
		local votes: { [string]: number } = {}
		local totalVoters = 0
		local totalCastVotes = 0
		for _, memberState in targetRun.PartyMembers do
			if memberState.IsConnected ~= false then
				totalVoters += 1
				if memberState.VotedNodeId then
					totalCastVotes += 1
					votes[memberState.VotedNodeId] = (votes[memberState.VotedNodeId] or 0) + 1
				end
			end
		end
		if totalVoters > 0 then
			local requiredMajority = math.floor(totalVoters / 2) + 1
			local winningNodeId: string? = nil
			for nodeId, count in votes do
				if count >= requiredMajority then
					winningNodeId = nodeId
					break
				end
			end
			if winningNodeId then
				for _, memberState in targetRun.PartyMembers do
					memberState.VotedNodeId = nil
				end
				RunManager.travelToNode(winningNodeId, isRealPlayer)
			end
		end
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

	-- 2. Validate initiator belongs to the party, is connected, and is locked
	if initiator == nil then
		if not isIsolatedTesting then
			warn("[RunManager] Cannot start run: initiator is required.")
			return false
		end
	else
		local initUserId = (typeof(initiator) == "Instance" and initiator.UserId) or (typeof(initiator) == "table" and initiator.UserId) or initiator
		if typeof(initUserId) ~= "number" then
			warn("[RunManager] Cannot start run: invalid initiator identifier.")
			return false
		end
		local initMember = runToStart.PartyMembers[initUserId]
		if not initMember then
			warn(string.format("[RunManager] Cannot start run: initiator %s is not in the party.", tostring(initUserId)))
			return false
		end
		if initMember.IsConnected == false then
			warn(string.format("[RunManager] Cannot start run: initiator %s is disconnected.", tostring(initUserId)))
			return false
		end
		if not initMember.ClassLocked then
			warn(string.format("[RunManager] Cannot start run: initiator %s has not locked their class.", initMember.DisplayName))
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
	runToStart.StateRevision = (runToStart.StateRevision or 0) + 1
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

function RunManager.voteMapNode(player: any, targetNodeId: string): (boolean, string?, boolean?, StateTypes.RunPhase?, number?)
	local isReal = (typeof(player) == "Instance" and player:IsA("Player"))
	if typeof(player) == "table" and player._isSimulatedRealPlayer == true then
		isReal = true
	end
	local runToUse = if (isIsolatedTesting and isReal) then liveRun else currentRun
	local dRun = if (isIsolatedTesting and isReal) then liveDungeonRun else internalDungeonRun

	local userId = (typeof(player) == "Instance" and player.UserId) or (typeof(player) == "table" and player.UserId) or player
	local pState = (typeof(userId) == "number") and runToUse.PartyMembers[userId] or nil

	print(string.format("[MAPFLOW][SERVER] 1. Vote received [MapVote]: Player=%s, Target=%s, Phase=%s, Rev=%d",
		tostring(userId), tostring(targetNodeId), tostring(runToUse.Phase), runToUse.StateRevision or 0))

	if not dRun then
		print("[MAPFLOW][SERVER] vote rejected: Reason=Dungeon run is not initialized.")
		return false, "Dungeon run is not initialized.", false, runToUse.Phase, runToUse.StateRevision
	end

	if not pState then
		print("[MAPFLOW][SERVER] vote rejected: Reason=Player not in party.")
		return false, "Player not in party.", false, runToUse.Phase, runToUse.StateRevision
	end
	if pState.IsConnected == false then
		print("[MAPFLOW][SERVER] vote rejected: Reason=Player is disconnected.")
		return false, "Player is disconnected.", false, runToUse.Phase, runToUse.StateRevision
	end

	local node = DungeonService.getNode(dRun, targetNodeId)
	if not node then
		print("[MAPFLOW][SERVER] vote rejected: Reason=Target room does not exist in dungeon.")
		return false, "Target room does not exist in dungeon.", false, runToUse.Phase, runToUse.StateRevision
	end

	-- Idempotent handling: If the run has already transitioned to ActiveRoom and the winning CurrentNodeId
	-- matches the requested targetNodeId from a valid party member, treat it as an already-completed success.
	if runToUse.Phase == "ActiveRoom" and runToUse.CurrentNodeId == targetNodeId then
		print(string.format("[MAPFLOW][SERVER] duplicate vote received (idempotent): Node=%s, CurrentNode=%s, Phase=ActiveRoom, Rev=%d",
			targetNodeId, tostring(runToUse.CurrentNodeId), runToUse.StateRevision or 0))
		return true, nil, true, runToUse.Phase, runToUse.StateRevision
	end

	if runToUse.Phase ~= "MapSelect" then
		print(string.format("[MAPFLOW][SERVER] vote rejected: Reason=Map selection is no longer active (Phase=%s).", tostring(runToUse.Phase)))
		return false, "Map selection is no longer active.", false, runToUse.Phase, runToUse.StateRevision
	end

	local isAvailable = false
	for _, id in runToUse.AvailableNodeIds do
		if id == targetNodeId then
			isAvailable = true
			break
		end
	end

	if not isAvailable then
		print("[MAPFLOW][SERVER] vote rejected: Reason=Target room is not currently reachable.")
		return false, "Target room is not currently reachable.", false, runToUse.Phase, runToUse.StateRevision
	end

	pState.VotedNodeId = targetNodeId
	print(string.format("[MAPFLOW][SERVER] 2. vote accepted: Player=%s, Target=%s", tostring(userId), tostring(targetNodeId)))

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

	print(string.format("[MAPFLOW][SERVER] 3. winner check: Winner=%s, Votes=%s",
		tostring(winningNodeId), HttpService:JSONEncode(votes)))

	if winningNodeId then
		for _, member in runToUse.PartyMembers do
			member.VotedNodeId = nil
		end
		print(string.format("[MAPFLOW][SERVER] 4. travel START: Target=%s", winningNodeId))
		local travelOk, travelErr = RunManager.travelToNode(winningNodeId, isReal)
		return travelOk, travelErr, true, runToUse.Phase, runToUse.StateRevision
	else
		if not isIsolatedTesting or isReal then
			RunManager.broadcastRunSnapshots(string.format("%s voted for room %s", pState.DisplayName, targetNodeId), isReal)
		end
		return true, nil, false, runToUse.Phase, runToUse.StateRevision
	end
end

function RunManager.travelToNode(targetNodeId: string, isLiveAction: boolean?): (boolean, string?)
	local dRun = if (isIsolatedTesting and isLiveAction) then liveDungeonRun else internalDungeonRun
	local runToMutate = if (isIsolatedTesting and isLiveAction) then liveRun else currentRun
	if not dRun then
		print("[MAPFLOW][SERVER][10] rollback executed: Phase=MapSelect, Err=No active run.")
		return false, "No active run."
	end

	-- Stage 1: Validate node reachability WITHOUT mutating state
	local valid, err, node = DungeonService.validateNode(dRun, targetNodeId)
	if not valid or not node then
		print(string.format("[MAPFLOW][SERVER][10] rollback executed: Phase=MapSelect, Err=%s", tostring(err)))
		return false, err or "Invalid target node."
	end

	-- Stage 2: If combat node, attempt combat initialization in pcall BEFORE mutating run state or dungeon
	local activeCombat = nil
	if node.Type == "Combat" or node.Type == "Elite Monster" or node.Type == "Act Boss" then
		if not CombatService then
			CombatService = require(servicesFolder:WaitForChild("CombatService") :: ModuleScript)
		end

		print(string.format("[MAPFLOW][SERVER] 5. combat START: Node=%s", node.Id))
		local encounterId = "enc_" .. node.Id
		local combatOk, combatResult = pcall(function()
			return CombatService.startCombat(
				encounterId,
				node.Type,
				node.Tier,
				runToMutate.PartyMembers,
				function(outcome: "Victory" | "Defeat")
					RunManager.onCombatCompleted(outcome, node)
				end
			)
		end)

		if not combatOk or not combatResult then
			local combatErr = not combatOk and tostring(combatResult) or "startCombat returned nil"
			warn(string.format("[MAPFLOW][SERVER] combat setup result: Success=false, Err=%s", combatErr))
			print(string.format("[MAPFLOW][SERVER] rollback executed: Phase=MapSelect, Err=%s", combatErr))
			return false, "Failed to start combat: " .. combatErr
		end

		activeCombat = combatResult
		print(string.format("[MAPFLOW][SERVER] 6. combat SUCCESS: Node=%s", node.Id))
	end

	-- Stage 3: Commit dungeon progression now that encounter is verified
	DungeonService.commitNode(dRun, node)
	print(string.format("[MAPFLOW][SERVER] 7. dungeon COMMIT: Node=%s", node.Id))

	-- Stage 4: Commit run state transactionally with incremented revision
	runToMutate.StateRevision = (runToMutate.StateRevision or 0) + 1
	runToMutate.CurrentNodeId = targetNodeId
	runToMutate.CurrentTier = node.Tier
	runToMutate.ActIndex = node.Act

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
	table.clear(runToMutate.AvailableNodeIds)

	if activeCombat then
		runToMutate.ActiveCombat = activeCombat
	elseif node.Type == "Campfire Rest" then
		for _, member in runToMutate.PartyMembers do
			local heal = math.floor(member.Resources.MaxHP * GameConfig.Dungeon.CampfireHealPercent)
			member.Resources.HP = math.min(member.Resources.MaxHP, member.Resources.HP + heal)
		end
		DungeonService.markNodeCleared(dRun, targetNodeId)
		table.insert(runToMutate.ClearedNodeIds, targetNodeId)
		if not isIsolatedTesting or isLiveAction then
			RunManager.broadcastRunSnapshots("🔥 Rested at the Campfire (+30% HP recovered).", isLiveAction)
		end
	elseif node.Type == "Merchant Shop" then
		DungeonService.markNodeCleared(dRun, targetNodeId)
		table.insert(runToMutate.ClearedNodeIds, targetNodeId)
		if not isIsolatedTesting or isLiveAction then
			RunManager.broadcastRunSnapshots("💰 Visited the Merchant Shop. Supplies replenished.", isLiveAction)
		end
	end

	-- Stage 5: Teleport players in live game
	local av = getArenaVisualizer()
	if av and av.teleportPlayersToPedestal then
		pcall(function()
			av.teleportPlayersToPedestal()
		end)
	end

	print(string.format("[MAPFLOW][SERVER] 8. run COMMIT: Phase=ActiveRoom, Rev=%d, Node=%s",
		runToMutate.StateRevision, targetNodeId))

	-- Stage 6: Broadcast state snapshot to all connected clients
	if not isIsolatedTesting or isLiveAction then
		print(string.format("[MAPFLOW][SERVER] 9. snapshot SEND: Phase=ActiveRoom, Rev=%d", runToMutate.StateRevision))
		RunManager.broadcastRunSnapshots(string.format("Entered Room: %s (Tier %d)", node.Type, node.Tier), isLiveAction)
	end

	print("[MAPFLOW][SERVER] travelToNode completed: Success=true")
	return true, nil
end

function RunManager.onCombatCompleted(outcome: "Victory" | "Defeat", node: DungeonMap.DungeonNode)
	if outcome == "Defeat" then
		local runToMutate = if (isIsolatedTesting and liveRun.Phase == "ActiveRoom") then liveRun else currentRun
		runToMutate.StateRevision = (runToMutate.StateRevision or 0) + 1
		runToMutate.Phase = "RunDefeat"
		runToMutate.ActiveCombat = nil
		RunManager.broadcastRunSnapshots("DEFEAT! The party has fallen.")
		NetworkService.broadcastAnnouncement("EXPEDITION FAILED", "Your party was overwhelmed by the rift.", Color3.fromRGB(255, 60, 60))
		return
	end

	-- Combat Victory: mark the combat node cleared!
	local dRun = if (isIsolatedTesting and liveDungeonRun and liveRun.Phase == "ActiveRoom") then liveDungeonRun else internalDungeonRun
	local runToMutate = if (isIsolatedTesting and liveRun.Phase == "ActiveRoom") then liveRun else currentRun
	if dRun then
		DungeonService.markNodeCleared(dRun, node.Id)
	end
	local already = false
	for _, id in runToMutate.ClearedNodeIds do
		if id == node.Id then
			already = true
			break
		end
	end
	if not already then
		table.insert(runToMutate.ClearedNodeIds, node.Id)
	end

	if node.Type == "Act Boss" and node.Act == 4 then
		runToMutate.StateRevision = (runToMutate.StateRevision or 0) + 1
		runToMutate.Phase = "RunVictory"
		for _, member in runToMutate.PartyMembers do
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
	local runToMutate = if (isIsolatedTesting and liveRun.Phase == "ActiveRoom") then liveRun else currentRun
	runToMutate.StateRevision = (runToMutate.StateRevision or 0) + 1
	runToMutate.Phase = "Rewards"
	runToMutate.ActiveCombat = nil -- Clear ActiveCombat reference on room completion
	if (runToMutate :: any).RoomPhase then
		(runToMutate :: any).RoomPhase = "Rewards"
	end

	print(string.format("[REWARDFLOW][SERVER][0] transitionToRewards: isElite=%s, isBoss=%s, Rev=%d",
		tostring(isElite), tostring(isBoss), runToMutate.StateRevision))

	local gold = GameConfig.Rewards.BaseCombatGold + (isElite and GameConfig.Rewards.EliteBonusGold or 0) + (isBoss and GameConfig.Rewards.BossBonusGold or 0)
	local shards = GameConfig.Rewards.BaseCombatShards + (isElite and GameConfig.Rewards.EliteBonusShards or 0) + (isBoss and GameConfig.Rewards.BossBonusShards or 0)

	local offeredCards: { [number]: { CardData.Card } } = {}
	local claimedFlags: { [number]: boolean } = {}

	for userId, member in runToMutate.PartyMembers do
		member.Gold += gold
		offeredCards[userId] = generateDraftChoices()
		claimedFlags[userId] = false

		if member.PlayerInstance then
			PersistenceService.addAetherShards(member.PlayerInstance, shards)
		end
	end

	runToMutate.PendingRewards = {
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

	print(string.format("[REWARDFLOW][SERVER][1] claimRewardCard starting: Player=%s, Card=%s", tostring(userId), tostring(cardDefId)))

	-- 1. Pre-create runtime CardInstance; verify creation succeeds before permanent grant
	local newCardInst = CardService.createCardInstance(cardDefId, userId)
	if not newCardInst then
		warn(string.format("[REWARDFLOW][SERVER][1] failed to create CardInstance for %s", tostring(cardDefId)))
		return false, "Failed to create runtime card instance."
	end

	-- 2. Verify permanent collection grant succeeds
	local playerRef = member.PlayerInstance or player or { UserId = userId }
	local grantOk, grantErr = CardCollectionService.grantCard(playerRef, cardDefId, 1)
	if not grantOk then
		warn(string.format("[REWARDFLOW][SERVER][1] failed to grant card to collection: %s", tostring(grantErr)))
		return false, grantErr or "Failed to grant card to permanent collection."
	end

	-- 3. Both operations succeeded: commit runtime deck insertion and mark claimed
	table.insert(member.Deck, newCardInst)
	runToUse.PendingRewards.ClaimedCards[userId] = true
	runToUse.StateRevision = (runToUse.StateRevision or 0) + 1

	print(string.format("[REWARDFLOW][SERVER][2] claimRewardCard committed: Player=%s, Card=%s, Rev=%d",
		tostring(userId), tostring(cardDefId), runToUse.StateRevision))

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

	local userId = if typeof(player) == "table" or (typeof(player) == "Instance" and player:IsA("Player")) then player.UserId else "?"
	print(string.format("[REWARDFLOW][SERVER][3] continueFromRewards requested: Player=%s, Phase=%s", tostring(userId), tostring(runToUse.Phase)))

	-- Strict security guard: only allowed in Rewards phase and never during active combat or active room
	if runToUse.Phase ~= "Rewards" and (runToUse :: any).RoomPhase ~= "Rewards" then
		warn("[REWARDFLOW][SERVER][3] rejected: Not in Rewards phase.")
		return false
	end
	if runToUse.Phase == "ActiveRoom" or (runToUse :: any).RoomPhase == "ActiveRoom" or runToUse.ActiveCombat ~= nil then
		warn(string.format("[REWARDFLOW][SERVER][3] rejected: ActiveRoom or ActiveCombat non-nil (Phase=%s, ActiveCombat=%s)",
			tostring(runToUse.Phase), tostring(runToUse.ActiveCombat)))
		return false
	end

	if not dRun then
		warn("[REWARDFLOW][SERVER][3] rejected: No dungeon run found.")
		return false
	end

	-- Check if continuing after an Act Boss (Tier 10) was cleared: advance to the next Act
	local isBossCleared = (runToUse.CurrentTier == DungeonMap.TIERS_PER_ACT or (dRun and dRun.CurrentTier == DungeonMap.TIERS_PER_ACT))
	if isBossCleared and dRun.CurrentActIndex < DungeonMap.TOTAL_ACTS then
		dRun.CurrentActIndex += 1
		dRun.CurrentTier = 0
		dRun.CurrentNodeId = nil
		runToUse.ActIndex = dRun.CurrentActIndex
		runToUse.CurrentTier = 0
		runToUse.CurrentNodeId = nil
		print(string.format("[REWARDFLOW][SERVER] Advanced to Act %d (%s) after Boss victory!",
			dRun.CurrentActIndex, dRun.Acts[dRun.CurrentActIndex].Name))
	end

	local available = DungeonService.getAvailableNodes(dRun)
	table.clear(runToUse.AvailableNodeIds)
	for _, node in available do
		table.insert(runToUse.AvailableNodeIds, node.Id)
	end

	runToUse.StateRevision = (runToUse.StateRevision or 0) + 1
	runToUse.Phase = "MapSelect"
	if (runToUse :: any).RoomPhase then
		(runToUse :: any).RoomPhase = "MapSelect"
	end
	runToUse.ActiveRoom = nil
	runToUse.ActiveCombat = nil
	runToUse.PendingRewards = nil

	print(string.format("[REWARDFLOW][SERVER][4] continueFromRewards committed: Phase=MapSelect, Rev=%d, AvailableCount=%d",
		runToUse.StateRevision, #runToUse.AvailableNodeIds))

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
	local runsToReset = { currentRun }
	if isIsolatedTesting and liveRun and liveRun ~= currentRun then
		table.insert(runsToReset, liveRun)
	end

	for _, run in runsToReset do
		run.StateRevision = (run.StateRevision or 0) + 1
		run.Phase = "Lobby"
		run.ActIndex = 1
		run.CurrentTier = 0
		run.CurrentNodeId = nil
		run.ClearedNodeIds = {}
		run.AvailableNodeIds = {}
		run.ActiveRoom = nil
		run.ActiveCombat = nil
		run.PendingRewards = nil

		for _, member in run.PartyMembers do
			member.ClassLocked = false
			member.IsReady = false
			member.IsDowned = false
			member.VotedNodeId = nil
			member.Gold = GameConfig.Dungeon.StarterGold
			member.RelicIds = { "Anchor" }
			ClassService.applyBaseClassStats(member)
			ClassService.initializeStartingDeck(member)
			ClassService.resetCombatResources(member)
			ClassService.resetClassCombatGimmicks(member.UserId)
			RelicService.resetCombatState(member.UserId)

			-- Reset all 7 run-scoped progression fields
			table.clear(member.EquippedItems)
			table.clear(member.EquipmentInventory)
			table.clear(member.EquippedSkills)
			table.clear(member.SkillInventory)
			table.clear(member.UnlockedSkills)
			table.clear(member.UnlockedPassives)
			member.PassivePoints = 0

			-- Re-provision starting skills & persistent unlocked skills
			initializeSkillsForPlayer(member, member.PlayerInstance or { UserId = member.UserId })
			SkillService.resetCooldowns(member)
		end
	end

	internalDungeonRun = nil
	if isIsolatedTesting then
		liveDungeonRun = nil
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
