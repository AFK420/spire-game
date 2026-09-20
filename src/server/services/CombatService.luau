--!strict

--[=[
	CombatService ModuleScript
	Mapped to: ServerScriptService.Server.services.CombatService

	Authoritative combat engine for Card Rift: Co-op Dungeon:
	1. Owns active CombatState with multi-enemy collection (Enemies: { [string]: EnemyState }).
	2. Manages monotonic turn timer via os.clock() (TurnStartTime, 45s duration).
	3. Resolves card plays by unique CardInstanceId (safe against race conditions).
	4. Handles simultaneous player turn ready-voting and automatic turn expiry resolution.
	5. Manages downed player states, teammate rescue mechanics (2 energy, 25% HP revive).
	6. Dispatches serializable CombatSnapshot DTOs and structured CombatEvents.

	=============================================================================
	SINGLE COMBAT ENCOUNTER ASSUMPTION & MULTI-COMBAT MIGRATION PATH:
	The current engine assumes one active combat encounter per server instance.
	State is encapsulated under `activeCombat` and accessed via `CombatService.getActiveCombat()`.
	When multi-room concurrent combat is introduced, `activeCombat` will be promoted
	to `activeCombats: { [string]: StateTypes.CombatState }` keyed by CombatId
	without altering the action contracts or card resolution pipeline.
	=============================================================================
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CardData = require(Shared:WaitForChild("CardData") :: ModuleScript)
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)
local GameConfig = require(Shared:WaitForChild("GameConfig") :: ModuleScript)
local ReactionData = require(Shared:WaitForChild("ReactionData") :: ModuleScript)
local EnemyData = require(Shared:WaitForChild("EnemyData") :: ModuleScript)

local servicesFolder = script.Parent
local CardService = require(servicesFolder:WaitForChild("CardService") :: ModuleScript)
local ClassService = require(servicesFolder:WaitForChild("ClassService") :: ModuleScript)
local RelicService = require(servicesFolder:WaitForChild("RelicService") :: ModuleScript)
local NetworkService = require(servicesFolder:WaitForChild("NetworkService") :: ModuleScript)
local ArenaVisualizer = require(servicesFolder:WaitForChild("ArenaVisualizer") :: ModuleScript)
local TargetResolver = require(servicesFolder:WaitForChild("TargetResolver") :: ModuleScript)
local ModifierResolver = require(servicesFolder:WaitForChild("ModifierResolver") :: ModuleScript)
local DamagePipeline = require(servicesFolder:WaitForChild("DamagePipeline") :: ModuleScript)
local BreakService = require(servicesFolder:WaitForChild("BreakService") :: ModuleScript)
local EnemyMechanicsService = require(servicesFolder:WaitForChild("EnemyMechanicsService") :: ModuleScript)
local BossMechanicsService = require(servicesFolder:WaitForChild("BossMechanicsService") :: ModuleScript)
local SpatialHazardService = require(servicesFolder:WaitForChild("SpatialHazardService") :: ModuleScript)
local StatusService = require(servicesFolder:WaitForChild("StatusService") :: ModuleScript)
local EffectResolver = require(servicesFolder:WaitForChild("EffectResolver") :: ModuleScript)
local StatResolver = require(servicesFolder:WaitForChild("StatResolver") :: ModuleScript)
local SkillService = require(servicesFolder:WaitForChild("SkillService") :: ModuleScript)
local ActionTransaction = require(servicesFolder:WaitForChild("ActionTransaction") :: ModuleScript)
local CardRulesService = require(servicesFolder:WaitForChild("CardRulesService") :: ModuleScript)

local CombatService = {}

local runManagerRef: any = nil
local function getRunManager(): any
	if not runManagerRef then
		local rm = servicesFolder:FindFirstChild("RunManager")
		if rm then
			runManagerRef = require(rm :: ModuleScript)
		end
	end
	return runManagerRef
end

local ReactionService: any = nil
local function getReactionService(): any
	if not ReactionService then
		local rs = servicesFolder:FindFirstChild("ReactionService")
		if rs then
			ReactionService = require(rs :: ModuleScript)
		end
	end
	return ReactionService
end

local EnvironmentService: any = nil
local function getEnvironmentService(): any
	if not EnvironmentService then
		local es = servicesFolder:FindFirstChild("EnvironmentService")
		if es then
			EnvironmentService = require(es :: ModuleScript)
		end
	end
	return EnvironmentService
end

--------------------------------------------------------------------------------
-- Active Combat State (Single-Encounter Container)
--------------------------------------------------------------------------------

local activeCombat: StateTypes.CombatState? = nil
local partyRef: { [number]: StateTypes.PlayerState } = {}
local onCombatEndCallback: ((outcome: "Victory" | "Defeat") -> ())? = nil
local turnTimerConnection: RBXScriptConnection? = nil

local liveActiveCombatBackup: StateTypes.CombatState? = nil
local livePartyRefBackup: { [number]: StateTypes.PlayerState }? = nil
local liveOnCombatEndCallbackBackup: ((outcome: "Victory" | "Defeat") -> ())? = nil
local liveTurnTimerConnectionBackup: RBXScriptConnection? = nil
local isCombatIsolation = false

local failureInjectionEnabled = false
local failureInjectionMessage: string? = nil
local failureInjectionStage = 1

function CombatService.setFailureInjectionForTesting(enabled: boolean, message: string?, stage: number?)
	failureInjectionEnabled = enabled
	failureInjectionMessage = message
	failureInjectionStage = stage or 1
end

function CombatService.isFailureInjectionEnabled(): boolean
	return failureInjectionEnabled
end

function CombatService.beginTestIsolation()
	if not isCombatIsolation then
		liveActiveCombatBackup = activeCombat
		livePartyRefBackup = partyRef
		liveOnCombatEndCallbackBackup = onCombatEndCallback
		liveTurnTimerConnectionBackup = turnTimerConnection
		isCombatIsolation = true
		activeCombat = nil
		partyRef = {}
		onCombatEndCallback = nil
		turnTimerConnection = nil
	end
end

function CombatService.endTestIsolation()
	if isCombatIsolation then
		if turnTimerConnection then
			turnTimerConnection:Disconnect()
		end
		activeCombat = liveActiveCombatBackup
		partyRef = livePartyRefBackup or {}
		onCombatEndCallback = liveOnCombatEndCallbackBackup
		turnTimerConnection = liveTurnTimerConnectionBackup
		liveActiveCombatBackup = nil
		livePartyRefBackup = nil
		liveOnCombatEndCallbackBackup = nil
		liveTurnTimerConnectionBackup = nil
		isCombatIsolation = false
	end
end

function CombatService.isTestIsolationActive(): boolean
	return isCombatIsolation
end

local function getSortedLivingPlayers(): { StateTypes.PlayerState }
	local livingPlayers: { StateTypes.PlayerState } = {}
	for _, playerState in partyRef do
		if not playerState.IsDowned and playerState.IsConnected ~= false then
			table.insert(livingPlayers, playerState)
		end
	end
	table.sort(livingPlayers, function(a, b)
		return a.UserId < b.UserId
	end)
	return livingPlayers
end

local function stableTargetIndex(key: string, count: number): number
	local hash = 0
	for index = 1, #key do
		hash = (hash * 31 + string.byte(key, index)) % 2147483647
	end
	return (hash % count) + 1
end

local function assignIntentPlayerTarget(enemy: StateTypes.EnemyState, intent: StateTypes.EnemyIntent)
	if intent.TargetMode ~= "RandomPlayer" then
		intent.TargetUserId = nil
		return
	end

	local existingTarget = if intent.TargetUserId then partyRef[intent.TargetUserId] else nil
	if existingTarget and not existingTarget.IsDowned and existingTarget.IsConnected ~= false then
		return
	end

	local livingPlayers = getSortedLivingPlayers()
	if #livingPlayers == 0 then
		intent.TargetUserId = nil
		return
	end

	local turnNumber = if activeCombat then activeCombat.TurnNumber else 1
	local targetKey = string.format("%s:%d:%d", enemy.InstanceId, enemy.MoveIndex or 1, turnNumber)
	intent.TargetUserId = livingPlayers[stableTargetIndex(targetKey, #livingPlayers)].UserId
end

local function getLowestHPEnemy(enemies: { [string]: StateTypes.EnemyState }): StateTypes.EnemyState?
	local lowestTarget: StateTypes.EnemyState? = nil
	local lowestRatio = math.huge
	for _, ally in enemies do
		if ally.HP > 0 then
			local hpRatio = ally.HP / math.max(1, ally.MaxHP)
			local winsTie = hpRatio == lowestRatio
				and (lowestTarget == nil or ally.InstanceId < lowestTarget.InstanceId)
			if hpRatio < lowestRatio or winsTie then
				lowestRatio = hpRatio
				lowestTarget = ally
			end
		end
	end
	return lowestTarget
end

local function getIntentTargetText(enemy: StateTypes.EnemyState): string
	local targetMode = enemy.Intent.TargetMode
	if targetMode == "AllPlayers" then
		return "TARGET: ALL PLAYERS"
	elseif targetMode == "Self" then
		return "TARGET: SELF"
	elseif targetMode == "LowestHPAlly" and activeCombat then
		local ally = getLowestHPEnemy(activeCombat.Enemies)
		return if ally then "TARGET: " .. ally.Name else "TARGET: NO LIVING ALLY"
	elseif targetMode == "RandomPlayer" then
		local target = if enemy.Intent.TargetUserId then partyRef[enemy.Intent.TargetUserId] else nil
		return if target then "TARGET: " .. target.DisplayName else "TARGET: NO LIVING PLAYER"
	end
	return "TARGET: NONE"
end

local function getIntentReactionGuidance(intent: StateTypes.EnemyIntent): (string, string)
	if intent.Type ~= "Attack" then
		if intent.BreakInterruptible == true then
			return "USE HEAVY/BREAK NOW — NO C/V REACTION", "Interrupt"
		end
		return "PREPARE WITH CARDS — NO C/V REACTION", "Preparation"
	end

	local profile = ReactionData.getProfile(intent.AttackProfileId or "")
	if not profile then
		return "REACTION UNKNOWN — PREPARE DEFENSES", "DefenseOnly"
	end
	if profile.AvoidanceMode == "Movement" then
		return "MOVE OUT — C/V DO NOT WORK", "Movement"
	elseif profile.AvoidanceMode == "DefenseOnly" or (not profile.CanDodge and not profile.CanParry) then
		return "CANNOT DODGE OR PARRY — SHIELD/PREPARE", "DefenseOnly"
	elseif profile.CanDodge and profile.CanParry then
		return "C: DODGE  •  V: PARRY", "DodgeParry"
	elseif profile.CanDodge then
		return "C: DODGE ONLY  •  V WILL FAIL", "DodgeOnly"
	elseif profile.CanParry then
		return "V: PARRY ONLY  •  C WILL FAIL", "ParryOnly"
	end
	return "CANNOT REACT — PREPARE DEFENSES", "DefenseOnly"
end

--------------------------------------------------------------------------------
-- Snapshot Generators
--------------------------------------------------------------------------------

function CombatService.getCombatSnapshotForPlayer(player: any): StateTypes.CombatSnapshot?
	if not activeCombat then return nil end

	local userId = player.UserId
	local playerState = partyRef[userId]
	if not playerState then return nil end

	local now = os.clock()
	local elapsed = now - activeCombat.TurnStartTime
	local remaining = math.max(0, math.ceil(activeCombat.TurnDuration - elapsed))

	-- Enemy Views
	local enemyViews: { [string]: StateTypes.EnemyView } = {}
	for id, enemy in activeCombat.Enemies do
		local intentIcon = "⚔️"
		if enemy.Intent.Type == "Defend" then
			intentIcon = "🛡️"
		elseif enemy.Intent.Type == "Buff" then
			intentIcon = "⚡"
		elseif enemy.Intent.Type == "Debuff" then
			intentIcon = "🧪"
		end

		local intentDescription = enemy.Intent.Description or enemy.Intent.Type
		local reactionText, reactionStyle = getIntentReactionGuidance(enemy.Intent)
		enemyViews[id] = {
			InstanceId = enemy.InstanceId,
			Name = enemy.Name,
			HP = enemy.HP,
			MaxHP = enemy.MaxHP,
			Shield = enemy.Shield,
			Poison = enemy.Poison,
			Armor = enemy.Armor or 0,
			EvasionPercent = math.round((enemy.Evasion or 0) * 100),
			AttackPower = enemy.AttackPower,
			BreakMeter = enemy.BreakMeter or 0,
			BreakThreshold = enemy.BreakThreshold or 0,
			IsBroken = enemy.IsBroken == true,
			IntentText = string.format("%s (%d)", intentDescription, enemy.Intent.Value),
			IntentIcon = intentIcon,
			IntentInterruptible = enemy.Intent.BreakInterruptible == true,
			IntentInterruptText = enemy.Intent.InterruptText,
			IntentTargetUserId = enemy.Intent.TargetUserId,
			IntentTargetText = getIntentTargetText(enemy),
			IntentReactionText = reactionText,
			IntentReactionStyle = reactionStyle,
			BossPhase = enemy.BossPhase,
			BossPhaseName = enemy.BossPhaseName,
		}
	end

	-- Party Views
	local partyViews: { [string]: StateTypes.PlayerView } = {}
	for pUserId, pState in partyRef do
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

		local shockStatus = StatusService.getStatus(tostring(pUserId), "Shock")
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
			EquippedItems = equippedItemsSummary,
			EquippedSkills = equippedSkillsSummary,
			SkillInventory = skillInventoryList,
			UnlockedPassives = table.clone(pState.UnlockedPassives or {}),
			PassivePoints = pState.PassivePoints or 0,
			Shock = if shockStatus then shockStatus.Stacks else 0,
		}
	end

	-- Local Hand Views
	local localHand: { StateTypes.CardView } = {}
	for _, cardInst in playerState.Hand do
		table.insert(localHand, CardService.toCardView(cardInst, playerState))
	end
	table.sort(localHand, function(a, b) return a.Name < b.Name end)

	local reactionView: StateTypes.ReactionWindowView? = nil
	if activeCombat.ActiveReactionWindow then
		local rs = getReactionService()
		if rs and rs.getReactionWindowView then
			local enemyName = "Enemy"
			local enemyInst = activeCombat.Enemies[activeCombat.ActiveReactionWindow.EnemyInstanceId]
			if enemyInst then
				enemyName = enemyInst.Name
			end
			reactionView = rs.getReactionWindowView(activeCombat.ActiveReactionWindow, enemyName)
		end
	end

	local envView: StateTypes.EnvironmentView? = nil
	if activeCombat.Environment then
		local envService = getEnvironmentService()
		if envService and envService.getEnvironmentView then
			envView = envService.getEnvironmentView(activeCombat.Environment)
		end
	end

	return {
		CombatId = activeCombat.CombatId,
		Phase = activeCombat.Phase,
		TurnNumber = activeCombat.TurnNumber,
		TurnStartTime = activeCombat.TurnStartTime,
		TurnDuration = activeCombat.TurnDuration,
		TimeRemaining = remaining,
		Enemies = enemyViews,
		Party = partyViews,
		LocalHand = localHand,
		CombatEvents = activeCombat.CombatLog,
		ActiveReactionWindow = reactionView,
		Environment = envView,
		Message = nil,
	}
end

function CombatService.broadcastSnapshots(message: string?)
	if not activeCombat then return end

	if not isCombatIsolation then
		pcall(function()
			ArenaVisualizer.syncEnemies(activeCombat.Enemies)
		end)
	end

	for userId, playerState in partyRef do
		local player = playerState.PlayerInstance or Players:GetPlayerByUserId(userId)
		if player then
			local snapshot = CombatService.getCombatSnapshotForPlayer(player)
			if snapshot then
				snapshot.Message = message
				NetworkService.sendCombatState(player, snapshot)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Enemy AI & Intent Generation
--------------------------------------------------------------------------------

local function generateEnemyIntent(enemy: StateTypes.EnemyState): StateTypes.EnemyIntent
	local nextMoveIndex = (enemy.MoveIndex or 1) + 1
	enemy.MoveIndex = nextMoveIndex
	local intent = EnemyData.createIntent(enemy.DefinitionId, nextMoveIndex, enemy.AttackPower, enemy.BossPhase)
	assignIntentPlayerTarget(enemy, intent)
	return intent
end

--------------------------------------------------------------------------------
-- Damage & Combat Resolution
--------------------------------------------------------------------------------

local function applyDamageToEnemy(enemy: StateTypes.EnemyState, rawDamage: number): (number, number)
	local res = DamagePipeline.executeDamage({
		RawDamage = rawDamage,
		DamageType = "Physical",
		SourceId = "CombatService",
		SourceName = "CombatService",
		SourcePlayer = nil,
		TargetEntityKind = "Enemy",
		TargetEnemy = enemy,
		TargetPlayer = nil,
		Tags = nil,
		Critical = false,
		CanHitShield = true,
		IsPeriodic = false,
	})
	return res.HPLost, res.ShieldAbsorbed
end

local function applyDamageToPlayer(playerState: StateTypes.PlayerState, rawDamage: number): (number, number)
	local res = DamagePipeline.executeDamage({
		RawDamage = rawDamage,
		DamageType = "Physical",
		SourceId = "CombatService",
		SourceName = "CombatService",
		SourcePlayer = nil,
		TargetEntityKind = "Player",
		TargetEnemy = nil,
		TargetPlayer = playerState,
		Tags = nil,
		Critical = false,
		CanHitShield = true,
		IsPeriodic = false,
	})
	return res.HPLost, res.ShieldAbsorbed
end

local function logEvent(eventType: string, sourceId: string, targetId: string, value: number?, text: string?, metadata: any?)
	if not activeCombat then return end

	local event: StateTypes.CombatEvent = {
		Type = eventType,
		SourceId = sourceId,
		TargetId = targetId,
		Value = value,
		ExtraText = text,
		Timestamp = os.clock(),
		CardDefinitionId = if metadata then metadata.CardDefinitionId else nil,
		CardRarity = if metadata then metadata.CardRarity else nil,
		AnimationId = if metadata then metadata.AnimationId else nil,
		AnimationType = if metadata then metadata.AnimationType else nil,
		ProjectileShape = if metadata then metadata.ProjectileShape else nil,
		EffectColor = if metadata then metadata.EffectColor else nil,
		ImpactEffectId = if metadata then metadata.ImpactEffectId else nil,
		DidHit = if metadata then metadata.DidHit else nil,
	}

	if ActionTransaction.isTransactionActive() then
		ActionTransaction.bufferEvent(event)
		return
	end

	table.insert(activeCombat.CombatLog, event)
	if #activeCombat.CombatLog > GameConfig.Combat.MaxTurnHistoryLog then
		table.remove(activeCombat.CombatLog, 1)
	end

	NetworkService.broadcastCombatEvent(event)
end

local function syncBossPhase(enemy: StateTypes.EnemyState, sourceId: string): boolean
	local transition = BossMechanicsService.updatePhase(enemy)
	if not transition then
		return false
	end
	assignIntentPlayerTarget(enemy, enemy.Intent)
	logEvent(
		"BossPhaseChanged",
		sourceId,
		enemy.InstanceId,
		transition.ToPhase,
		string.format(
			"%s entered Phase %d — %s! +%d transition Shield.",
			transition.EnemyName,
			transition.ToPhase,
			transition.PhaseName,
			transition.ShieldGained
		)
	)
	return true
end

local function recordEnemyDefeat(
	defeatedEnemy: StateTypes.EnemyState,
	sourceId: string,
	defeatText: string,
	emitDefeatEvent: boolean
): boolean
	if not activeCombat or defeatedEnemy.HP > 0 or defeatedEnemy.DefeatProcessed == true then
		return false
	end

	if emitDefeatEvent then
		logEvent("EnemyDefeated", sourceId, defeatedEnemy.InstanceId, nil, defeatText)
	end
	local mechanicResults, processed = EnemyMechanicsService.processEnemyDefeat(defeatedEnemy, activeCombat.Enemies)
	for _, result in mechanicResults do
		logEvent(
			"BuffGained",
			result.SourceEnemyName,
			result.SourceEnemyId,
			result.AttackGain,
			string.format("%s devoured the fallen and gained +%d Attack!", result.SourceEnemyName, result.AttackGain)
		)
	end
	return processed
end

local function applyEnemyHitToPlayer(
	enemy: StateTypes.EnemyState,
	playerState: StateTypes.PlayerState,
	rawDamage: number,
	detail: string
): number
	if not activeCombat then
		return 0
	end
	local hpLost, _ = applyDamageToPlayer(playerState, rawDamage)
	logEvent("DamageDealt", enemy.Name, tostring(playerState.UserId), rawDamage, string.format("-%d HP (%s)", hpLost, detail))

	if hpLost > 0 then
		local dmgRelic = RelicService.triggerEvent(playerState, activeCombat, "OnDamageTaken", {
			Damage = hpLost,
			Enemy = enemy,
		})
		if dmgRelic.BonusDamage > 0 then
			local thornsLost, _ = applyDamageToEnemy(enemy, dmgRelic.BonusDamage)
			logEvent("DamageDealt", "BronzeScales", enemy.InstanceId, dmgRelic.BonusDamage, string.format("-%d Thorns", thornsLost))
			recordEnemyDefeat(enemy, "BronzeScales", string.format("%s was defeated by Thorns!", enemy.Name), true)
		end
		if dmgRelic.BonusDraw > 0 then
			CardService.drawCards(playerState, dmgRelic.BonusDraw)
			logEvent("CardDrawn", "Relic", playerState.DisplayName, dmgRelic.BonusDraw, string.format("+%d Cards Drawn (Relic)", dmgRelic.BonusDraw))
		end
	end

	return hpLost
end

--------------------------------------------------------------------------------
-- Check Victory / Defeat Conditions
--------------------------------------------------------------------------------

local function areAllEnemiesDead(): boolean
	if not activeCombat then return true end
	for _, enemy in activeCombat.Enemies do
		if enemy.HP > 0 then
			return false
		end
	end
	return true
end

local function areAllPlayersDowned(): boolean
	local activePlayers = 0
	local downedPlayers = 0
	for _, pState in partyRef do
		if pState.IsConnected ~= false then
			activePlayers += 1
			if pState.IsDowned then
				downedPlayers += 1
			end
		end
	end
	return activePlayers > 0 and (downedPlayers == activePlayers)
end

local function areAllLivingPlayersReady(): boolean
	local livingCount = 0
	local readyCount = 0
	for _, pState in partyRef do
		if not pState.IsDowned and pState.IsConnected ~= false then
			livingCount += 1
			if pState.IsReady then
				readyCount += 1
			end
		end
	end
	return livingCount > 0 and (readyCount >= livingCount)
end

--------------------------------------------------------------------------------
-- Turn Resolution Phase
--------------------------------------------------------------------------------

local function endCombat(outcome: "Victory" | "Defeat")
	if not activeCombat then return end

	activeCombat.Phase = outcome
	if turnTimerConnection then
		turnTimerConnection:Disconnect()
		turnTimerConnection = nil
	end

	logEvent(outcome, "System", "Combat", nil, outcome == "Victory" and "Room Cleared!" or "Team Defeated!")
	CombatService.broadcastSnapshots(outcome == "Victory" and "VICTORY! Room Cleared!" or "DEFEAT! All heroes downed.")

	if onCombatEndCallback then
		local cb = onCombatEndCallback
		local rm = getRunManager()
		if (rm and rm.isTestIsolationActive and rm.isTestIsolationActive()) or isCombatIsolation then
			if not isCombatIsolation then
				ArenaVisualizer.cleanup()
			end
			activeCombat = nil
			cb(outcome)
		else
			task.delay(1.5, function()
				if not isCombatIsolation then
					pcall(function()
						ArenaVisualizer.cleanup()
					end)
				end
				activeCombat = nil
				local cbOk, cbErr = pcall(cb, outcome)
				if not cbOk then
					warn(string.format("[CombatService] onCombatEndCallback error: %s", tostring(cbErr)))
				end
			end)
		end
	end
end

local function resolveTurn()
	if not activeCombat or activeCombat.Phase ~= "PlayerPhase" then return end

	activeCombat.Phase = "ResolutionPhase"
	local phaseTransitionsBeforeEnemyAction: { [string]: boolean } = {}

	-- 1. End of Turn Class Gimmicks & Relic Triggers
	for userId, playerState in partyRef do
		if not playerState.IsDowned and playerState.IsConnected ~= false then
			local dummyTarget: StateTypes.EnemyState? = nil
			for _, enemy in activeCombat.Enemies do
				if enemy.HP > 0 then dummyTarget = enemy break end
			end

			pcall(function()
				local relicResult = RelicService.triggerEvent(playerState, activeCombat, "OnTurnEnd", {
					UnspentEnergy = playerState.Resources.Energy,
					Enemy = dummyTarget,
				})

				if not relicResult.RetainShield then
					playerState.Resources.Shield = 0
				else
					playerState.Resources.Shield = math.min(15, playerState.Resources.Shield)
				end

				if relicResult.BonusShield > 0 then
					playerState.Resources.Shield += relicResult.BonusShield
					logEvent("ShieldGained", "Relic", tostring(userId), relicResult.BonusShield, string.format("+%d Shield (Relic)", relicResult.BonusShield))
				end
			end)

			pcall(function()
				local gimmickEnd = ClassService.processGimmickOnTurnEnd(playerState, activeCombat.Enemies)
				if gimmickEnd.EndTurnShield > 0 then
					playerState.Resources.Shield += gimmickEnd.EndTurnShield
					logEvent("ShieldGained", "Gimmick", tostring(userId), gimmickEnd.EndTurnShield, string.format("+%d Shield (Gimmick)", gimmickEnd.EndTurnShield))
				end
				if gimmickEnd.EndTurnHeal > 0 then
					playerState.Resources.HP = math.min(playerState.Resources.MaxHP, playerState.Resources.HP + gimmickEnd.EndTurnHeal)
					logEvent("Healed", "Gimmick", tostring(userId), gimmickEnd.EndTurnHeal, string.format("+%d HP (Gimmick)", gimmickEnd.EndTurnHeal))
				end
				if gimmickEnd.EndTurnDamage > 0 then
					for _, enemy in activeCombat.Enemies do
						if enemy.HP > 0 then
							local hpBeforeGimmick = enemy.HP
							local remDmg, _ = applyDamageToEnemy(enemy, gimmickEnd.EndTurnDamage)
							logEvent("DamageDealt", "Gimmick", enemy.InstanceId, gimmickEnd.EndTurnDamage, string.format("-%d HP (Gimmick)", remDmg))
							if enemy.HP <= 0 then
								recordEnemyDefeat(enemy, "Gimmick", string.format("%s was defeated by gimmick damage!", enemy.Name), true)
							elseif enemy.HP < hpBeforeGimmick and syncBossPhase(enemy, "Gimmick") then
								phaseTransitionsBeforeEnemyAction[enemy.InstanceId] = true
							end
							break
						end
					end
				end
			end)

			-- Discard hand BEFORE broadcasting ResolutionPhase so client renders empty hand during enemy turn
			CardService.discardHand(playerState)
		end
	end

	-- Broadcast snapshot now that hands are discarded and Phase is ResolutionPhase
	CombatService.broadcastSnapshots("Enemies are counterattacking...")

	-- 2. Enemy Poison & Attacks
	task.spawn(function()
		local resolveOk, resolveErr = pcall(function()
			for enemyId, enemy in activeCombat.Enemies do
				if enemy.HP > 0 then
					local statusTicks = StatusService.tickStatuses(enemyId, "TurnStart", enemy, true)
					local statusKiller: string? = nil
					local statusDamageTotal = 0
					for _, tick in statusTicks do
						if tick.DamageDealt > 0 then
							statusDamageTotal += tick.DamageDealt
							logEvent("DamageDealt", tick.DefinitionId, enemy.InstanceId, tick.DamageDealt, string.format("-%d HP (%s)", tick.DamageDealt, tick.DefinitionId))
						end
						if tick.Defeated then
							statusKiller = tick.DefinitionId
						end
					end

					if enemy.HP <= 0 then
						local killer = statusKiller or "Poison"
						recordEnemyDefeat(enemy, killer, string.format("%s collapsed from %s!", enemy.Name, killer:lower()), true)
						continue
					end

					if statusDamageTotal > 0 and syncBossPhase(enemy, statusKiller or "Status") then
						phaseTransitionsBeforeEnemyAction[enemyId] = true
					end
					if phaseTransitionsBeforeEnemyAction[enemyId] then
						logEvent("BossPhasePreparation", enemy.Name, enemyId, enemy.BossPhase, string.format("%s pauses as %s begins.", enemy.Name, enemy.BossPhaseName or "a new phase"))
						CombatService.broadcastSnapshots(string.format("⚠️ PHASE %d: %s — prepare now!", enemy.BossPhase or 1, enemy.BossPhaseName or "Boss transition"))
						continue
					end

					local skipBrokenAction, recoveredFromBreak = BreakService.resolveBeforeEnemyAction(enemy)
					if recoveredFromBreak then
						logEvent("BreakRecovered", enemy.Name, enemyId, nil, string.format("%s recovered from Break.", enemy.Name))
					end
					if skipBrokenAction then
						local interruptedMove = enemy.Intent.Description or enemy.Intent.MoveId or "enemy action"
						logEvent("EnemyActionInterrupted", "Break", enemyId, nil, string.format("%s interrupted: %s cancelled.", enemy.Name, interruptedMove))
						CombatService.broadcastSnapshots(string.format("✋ BREAK INTERRUPT! %s cancelled %s!", enemy.Name, interruptedMove))
						enemy.Intent = generateEnemyIntent(enemy)
						continue
					end

					local rm = getRunManager()
					if not (rm and rm.isTestIsolationActive and rm.isTestIsolationActive()) then
						task.wait(0.3)
					end
					local hpBeforeEnemyAction = enemy.HP
					if enemy.Intent.Type == "Attack" then
						local livingPlayers = getSortedLivingPlayers()

						if #livingPlayers > 0 then
							assignIntentPlayerTarget(enemy, enemy.Intent)
							local target = livingPlayers[1]
							if enemy.Intent.TargetUserId then
								for _, livingPlayer in livingPlayers do
									if livingPlayer.UserId == enemy.Intent.TargetUserId then
										target = livingPlayer
										break
									end
								end
							end

							local profilePreset = enemy.Intent.AttackProfileId or "SlowHeavy"
							local targetAllPlayers = enemy.Intent.TargetMode == "AllPlayers"
							local targetUserIds: { number } = {}
							if targetAllPlayers then
								for _, livingPlayer in livingPlayers do
									table.insert(targetUserIds, livingPlayer.UserId)
								end
							else
								table.insert(targetUserIds, target.UserId)
							end

							-- Open authoritative 3D reaction window
							local rs = getReactionService()
							local windowResults: { [number]: any } = {}
							local activeProfile: StateTypes.AttackReactionProfile? = nil
							local movementHazardCenter: Vector3? = nil

							if rs then
								-- Preserve data-driven DamageType from preset (pass nil for damageType override)
								local profile = rs.createProfileFromPreset(profilePreset, enemy.Intent.Value, nil)
								activeProfile = profile
								local isAoE = targetAllPlayers or profile.AttackType == "AoE" or profile.IsAoE
								if isAoE then
									profile.IsAoE = true
									if not targetAllPlayers then
										table.clear(targetUserIds)
										for _, livingPlayer in livingPlayers do
											table.insert(targetUserIds, livingPlayer.UserId)
										end
									end
								else
									profile.IsAoE = false
								end

								-- Resolve authoritative 3D target world position
								local targetWorldPos: Vector3? = nil
								local targetPlayerInstance = Players:GetPlayerByUserId(target.UserId)
								if targetPlayerInstance and targetPlayerInstance.Character then
									local hrp = targetPlayerInstance.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
									if hrp then
										targetWorldPos = hrp.Position
									end
								end
								if not targetWorldPos then
									targetWorldPos = Vector3.new(0, 1.2, 16)
								end

								-- Resolve authoritative 3D attacker world position
								local attackerWorldPos: Vector3? = nil
								local enemyModel = ArenaVisualizer.getEnemyModel(enemyId)
								if enemyModel then
									local root = enemyModel.PrimaryPart or (enemyModel:FindFirstChild("HumanoidRootPart") :: BasePart?)
									if root then
										attackerWorldPos = root.Position
									end
								end
								if not attackerWorldPos then
									attackerWorldPos = Vector3.new(0, 1.2, -16)
								end

								local isMovementHazard = profile.AvoidanceMode == "Movement"
								if isMovementHazard then
									profile.HazardRadius = profile.HazardRadius or GameConfig.SpatialCombat.LightningFieldRadius
									profile.TargetWorldPos = targetWorldPos
									profile.TargetWorldPosition = targetWorldPos
									movementHazardCenter = targetWorldPos
								elseif isAoE then
									profile.TargetWorldPos = nil
									profile.TargetWorldPosition = nil
								else
									profile.TargetWorldPos = targetWorldPos
									profile.TargetWorldPosition = targetWorldPos
								end
								profile.AttackerWorldPos = attackerWorldPos

								-- Dynamic projectile travel time based on distance and configured ProjectileSpeed
								if profile.AttackType == "Projectile" and profile.ProjectileSpeed and profile.ProjectileSpeed > 0 then
									local dist = (targetWorldPos - attackerWorldPos).Magnitude
									local windup, impactDelay = ReactionData.resolveProjectileTiming(dist, profile.ProjectileSpeed, profile.TelegraphDuration)
									profile.TelegraphDuration = windup
									profile.ImpactDelay = impactDelay
								end

								local windowState = rs.openReactionWindow(activeCombat, profile, enemyId, targetUserIds)

								if isMovementHazard then
									CombatService.broadcastSnapshots(string.format("🏃 %s cast %s — MOVE OUT OF THE RED ZONE!", enemy.Name, profile.AttackName))
								else
									CombatService.broadcastSnapshots(string.format("⚠️ %s is attacking %s with %s!", enemy.Name, if isAoE then "the entire party" else target.DisplayName, profile.AttackName))
								end

								-- Wait for reaction window in live play using synchronized server time, skip in test isolation
								local rm = getRunManager()
								local isIso = (rm and rm.isTestIsolationActive and rm.isTestIsolationActive()) or isCombatIsolation
								if not isIso then
									local now = (pcall(function() return Workspace:GetServerTimeNow() end) and Workspace:GetServerTimeNow()) or os.clock()
									local resolutionTime = if isMovementHazard then windowState.ImpactServerTime else windowState.ReactionCloseServerTime
									local waitTime = math.max(0.1, resolutionTime - now)
									task.wait(waitTime)
								end

								windowResults = rs.resolveReactionWindow(activeCombat, windowState.WindowId)
							end

							-- Resolve damage and reaction outcomes independently per targeted player
							local effectiveTargetIds = if (rs and activeCombat.ActiveReactionWindow == nil and next(windowResults) ~= nil)
								then (function()
									local ids = {}
									for uId in windowResults do table.insert(ids, uId) end
									return ids
								end)()
								else targetUserIds

							for _, tUserId in effectiveTargetIds do
								local playerState = partyRef[tUserId]
								if playerState and not playerState.IsDowned then
									if activeProfile and activeProfile.AvoidanceMode == "Movement" and movementHazardCenter then
										local playerInstance = Players:GetPlayerByUserId(tUserId)
										local isSafe, distance = SpatialHazardService.isPlayerOutsideCircle(
											playerInstance,
											movementHazardCenter,
											activeProfile.HazardRadius or GameConfig.SpatialCombat.LightningFieldRadius
										)
										if isSafe then
											logEvent("SpatialHazardAvoided", playerState.DisplayName, enemyId, math.round(distance), "Escaped the lightning field")
										else
											applyEnemyHitToPlayer(enemy, playerState, enemy.Intent.Value, "Static Lightning Field")
											if not playerState.IsDowned then
												local statusId = enemy.Intent.StatusId or "Shock"
												local statusStacks = enemy.Intent.StatusStacks or GameConfig.SpatialCombat.LightningFieldShockStacks
												StatusService.applyStatus(tostring(tUserId), statusId, statusStacks, nil, enemy.InstanceId, playerState)
												logEvent("DebuffApplied", enemy.Name, playerState.DisplayName, statusStacks, string.format("Applied %d %s", statusStacks, statusId))
											end
										end
										continue
									end
									local pResult = windowResults[tUserId]
									local reacted = false
									local rType: StateTypes.ReactionType? = nil
									local pJudgement: StateTypes.TimingJudgement = "Miss"

									if pResult and (pResult.Result == "Success" or pResult.Result == "Perfect" or pResult.Result == "Good") then
										reacted = true
										rType = pResult.Reaction
										pJudgement = pResult.Judgement or (pResult.Result :: any)
									elseif pResult and pResult.Judgement then
										pJudgement = pResult.Judgement
									end

									if reacted and rType == "Dodge" then
										if pJudgement == "Perfect" then
											logEvent("CombatReaction", tostring(tUserId), enemyId, 0, string.format("⚡ %s executed a PERFECT DODGE against %s!", playerState.DisplayName, enemy.Name))
											CombatService.broadcastSnapshots(string.format("✨ PERFECT DODGE! %s cleanly evaded %s!", playerState.DisplayName, enemy.Name))
										else
											logEvent("CombatReaction", tostring(tUserId), enemyId, 0, string.format("💨 %s DODGED %s's attack!", playerState.DisplayName, enemy.Name))
											CombatService.broadcastSnapshots(string.format("💨 %s dodged the attack!", playerState.DisplayName))
										end
									elseif reacted and rType == "Parry" then
										local breakAmount = if pJudgement == "Perfect"
											then GameConfig.Break.PerfectParryDamage
											else GameConfig.Break.ParryDamage
										local breakAdded, didBreak = BreakService.applyBreakDamage(enemy, breakAmount, true)
										if breakAdded > 0 then
											logEvent("BreakDamage", playerState.DisplayName, enemyId, breakAdded, string.format("+%d Break", breakAdded))
										end
										if didBreak then
											logEvent("EnemyBroken", playerState.DisplayName, enemyId, nil, string.format("%s was Broken!", enemy.Name))
										end
										if pJudgement == "Perfect" then
											logEvent("CombatReaction", tostring(tUserId), enemyId, 0, string.format("🛡️ %s executed a PERFECT PARRY against %s!", playerState.DisplayName, enemy.Name))
											local parryCounterDmg = math.max(2, math.floor(enemy.Intent.Value * 0.6))
											local thornsRem, _ = applyDamageToEnemy(enemy, parryCounterDmg)
											logEvent("DamageDealt", "ParryCounter", enemy.InstanceId, parryCounterDmg, string.format("-%d HP (Perfect Parry Riposte)", thornsRem))
											recordEnemyDefeat(enemy, "ParryCounter", string.format("%s fell to a Perfect Parry riposte!", enemy.Name), true)
											CombatService.broadcastSnapshots(string.format("⚔️ PERFECT PARRY! %s riposted for %d damage!", playerState.DisplayName, parryCounterDmg))
										else
											logEvent("CombatReaction", tostring(tUserId), enemyId, 0, string.format("⚔️ %s PARRIED %s's attack!", playerState.DisplayName, enemy.Name))
											local parryCounterDmg = math.max(1, math.floor(enemy.Intent.Value * 0.3))
											local thornsRem, _ = applyDamageToEnemy(enemy, parryCounterDmg)
											logEvent("DamageDealt", "ParryCounter", enemy.InstanceId, parryCounterDmg, string.format("-%d HP (Parry Counter)", thornsRem))
											recordEnemyDefeat(enemy, "ParryCounter", string.format("%s fell to a Parry counter!", enemy.Name), true)
											CombatService.broadcastSnapshots(string.format("⚔️ %s parried and countered for %d damage!", playerState.DisplayName, parryCounterDmg))
										end
									else
										if pJudgement == "Early" then
											CombatService.broadcastSnapshots(string.format("⚠️ %s reacted too early!", playerState.DisplayName))
										elseif pJudgement == "Late" then
											CombatService.broadcastSnapshots(string.format("⚠️ %s reacted too late!", playerState.DisplayName))
										end

										applyEnemyHitToPlayer(enemy, playerState, enemy.Intent.Value, "Enemy attack")
									end
								end
							end
						end

					elseif enemy.Intent.Type == "Defend" then
						local shieldTarget = enemy
						if enemy.Intent.TargetMode == "LowestHPAlly" then
							shieldTarget = getLowestHPEnemy(activeCombat.Enemies) or enemy
						end
						shieldTarget.Shield += enemy.Intent.Value
					logEvent("ShieldGained", enemy.Name, shieldTarget.InstanceId, enemy.Intent.Value, string.format("+%d Shield", enemy.Intent.Value))

					elseif enemy.Intent.Type == "Debuff" then
						for _, pState in partyRef do
							if not pState.IsDowned and pState.IsConnected ~= false then
								local statusId = enemy.Intent.StatusId or "Poison"
								StatusService.applyStatus(tostring(pState.UserId), statusId, enemy.Intent.Value, nil, enemy.InstanceId, pState)
								logEvent("DebuffApplied", enemy.Name, pState.DisplayName, enemy.Intent.Value, string.format("Debuffed with %s", statusId))
							end
						end

					elseif enemy.Intent.Type == "Buff" then
						enemy.AttackPower = (enemy.AttackPower or 10) + enemy.Intent.Value
						logEvent("BuffGained", enemy.Name, enemy.Name, enemy.Intent.Value, string.format("+%d Attack Power", enemy.Intent.Value))
					end

					if enemy.Intent.ArmorAfterAction ~= nil or enemy.Intent.EvasionAfterAction ~= nil then
						enemy.Armor = math.max(0, enemy.Intent.ArmorAfterAction or enemy.Armor or 0)
						enemy.Evasion = math.clamp(enemy.Intent.EvasionAfterAction or enemy.Evasion or 0, 0, 0.75)
						logEvent(
							"EnemyDefenseShift",
							enemy.InstanceId,
							enemy.InstanceId,
							enemy.Armor,
							string.format(
								"%s — Armor %d, Evasion %d%%",
								enemy.Intent.DefenseText or "Defense shifted",
								enemy.Armor,
								math.round(enemy.Evasion * 100)
							)
						)
					end

					local transitionedDuringAction = if enemy.HP < hpBeforeEnemyAction
						then syncBossPhase(enemy, "ReactionDamage") else false
					if not transitionedDuringAction then
						enemy.Intent = generateEnemyIntent(enemy)
					end
				end
			end

			-- Check Post-Resolution Status
			if areAllEnemiesDead() then
				endCombat("Victory")
				return
			end

			if areAllPlayersDowned() then
				endCombat("Defeat")
				return
			end

			-- Process living player TurnStart statuses before advancing TurnNumber or entering PlayerPhase
			for _, playerState in partyRef do
				playerState.IsReady = false

				if not playerState.IsDowned and playerState.IsConnected ~= false then
					-- Tick player turn-start statuses (Poison, Burn, etc.)
					-- Note: StatusService via DamagePipeline authoritatively applies the damage directly to HP.
					local pTargetId = tostring(playerState.UserId)
					local pTicks = StatusService.tickStatuses(pTargetId, "TurnStart", playerState, false)
					for _, tick in pTicks do
						if tick.DamageDealt > 0 then
							logEvent("DamageDealt", tick.DefinitionId, tostring(playerState.UserId), tick.DamageDealt, string.format("-%d HP (%s)", tick.DamageDealt, tick.DefinitionId))
						end
						if tick.Defeated or playerState.Resources.HP <= 0 then
							if not playerState.IsDowned then
								playerState.IsDowned = true
								playerState.Resources.HP = 0
								playerState.Resources.Shield = 0
								logEvent("PlayerDowned", tick.DefinitionId, playerState.DisplayName, nil, string.format("%s was downed by %s!", playerState.DisplayName, tick.DefinitionId))
							end
						end
					end
				end
			end

			if areAllPlayersDowned() then
				endCombat("Defeat")
				return
			end
		end)

		if not resolveOk then
			warn(string.format("[CombatService] Error during turn resolution: %s", tostring(resolveErr)))
		end

		if not activeCombat or activeCombat.Phase == "Victory" or activeCombat.Phase == "Defeat" then
			return
		end

		-- GUARANTEED RECOVERY: Always advance turn number and restore PlayerPhase!
		activeCombat.TurnNumber += 1
		activeCombat.Phase = "PlayerPhase"
		activeCombat.TurnStartTime = os.clock()

		for _, playerState in partyRef do
			if not playerState.IsDowned and playerState.IsConnected ~= false then
				playerState.IsReady = false
				playerState.Resources.Energy = playerState.Resources.MaxEnergy
				local startRelic = RelicService.triggerEvent(playerState, activeCombat, "OnTurnStart")
				playerState.Resources.Energy += startRelic.BonusEnergy
				CardService.drawCards(playerState, GameConfig.Combat.BaseHandDrawCount + startRelic.BonusDraw)
				SkillService.onTurnStart(playerState)
			end
		end

		CombatService.broadcastSnapshots(string.format("Turn %d Begins! Draw cards and plan actions.", activeCombat.TurnNumber))
	end)
end

--------------------------------------------------------------------------------
-- Public Methods: Encounters, Actions, Ready, Rescue
--------------------------------------------------------------------------------

function CombatService.startCombat(
	encounterId: string,
	roomType: StateTypes.ActiveRoomType,
	tier: number,
	party: { [number]: StateTypes.PlayerState },
	onEndCallback: (outcome: "Victory" | "Defeat") -> ()
): StateTypes.CombatState
	partyRef = party
	onCombatEndCallback = onEndCallback

	if failureInjectionEnabled and failureInjectionStage == 1 then
		for _, pState in partyRef do
			pState.Resources.Energy = 0
			pState.Resources.Shield = 999
		end
		error(failureInjectionMessage or "CombatService: Injected failure in startCombat for testing")
	end

	local playerCount = 0
	for _ in party do playerCount += 1 end

	local enemies: { [string]: StateTypes.EnemyState } = {}
	local encounterDefinitionIds = EnemyData.getEncounter(roomType, tier)
	for index, definitionId in encounterDefinitionIds do
		local definition = EnemyData.getEnemy(definitionId)
		assert(definition, string.format("Missing EnemyData definition: %s", definitionId))

		local instancePrefix = if roomType == "Elite Monster"
			then "elite"
			elseif roomType == "Act Boss" then "boss" else "enemy"
		local instanceId = string.format("%s_%d", instancePrefix, index)
		local baseHp = definition.BaseHP + (tier * definition.HPPerTier)
		local baseAttack = definition.BaseAttack + math.floor(tier * definition.AttackPerTier)
		local hp = GameConfig.scaleEnemyHp(baseHp, playerCount)
		local attack = GameConfig.scaleEnemyAttack(baseAttack, playerCount)
		local breakThreshold = if definition.UsesInterruptMeter == true
			then GameConfig.Break.NormalInterruptThreshold else 0
		if roomType == "Elite Monster" then
			breakThreshold = GameConfig.Break.EliteThreshold
		elseif roomType == "Act Boss" then
			breakThreshold = GameConfig.Break.BossThreshold
		end

		local enemyState: StateTypes.EnemyState = {
			InstanceId = instanceId,
			DefinitionId = definitionId,
			Name = definition.Name,
			HP = hp,
			MaxHP = hp,
			Shield = 0,
			Poison = 0,
			Armor = definition.BaseArmor,
			Evasion = definition.BaseEvasion,
			AttackPower = attack,
			Intent = EnemyData.createIntent(definitionId, 1, attack, if roomType == "Act Boss" then 1 else nil),
			MoveIndex = 1,
			Role = definition.Role,
			BreakMeter = 0,
			BreakThreshold = breakThreshold,
			IsBroken = false,
			BreakActionsToSkip = 0,
			ModelRef = nil,
		}
		BossMechanicsService.initializeBoss(enemyState)
		assignIntentPlayerTarget(enemyState, enemyState.Intent)
		enemies[instanceId] = enemyState
	end

	-- Initialize environment for combat
	local envService = getEnvironmentService()
	local combatEnv: StateTypes.EnvironmentState? = nil
	if envService then
		local actIdx = 1
		local rm = getRunManager()
		if rm and rm.getRunState then
			local rState = rm.getRunState()
			if rState then
				actIdx = rState.ActIndex or 1
			end
		end
		combatEnv = envService.createEnvironment(nil, actIdx, math.random(1, 100000))
	end

	activeCombat = {
		CombatId = encounterId,
		Phase = "PlayerPhase",
		TurnNumber = 1,
		TurnStartTime = os.clock(),
		TurnDuration = GameConfig.Combat.TurnDuration,
		Participants = {},
		Enemies = enemies,
		ReadyPlayers = {},
		CombatLog = {},
		ActiveReactionWindow = nil,
		Environment = combatEnv,
	}

	-- Setup player combat state
	StatusService.resetCombat()
	for userId, playerState in partyRef do
		table.insert(activeCombat.Participants, userId)
		ClassService.resetCombatResources(playerState)
		ClassService.resetClassCombatGimmicks(userId)
		CardRulesService.resetBattleUsage(playerState)
		CardService.resetCombatPiles(playerState)
		RelicService.resetCombatState(userId)

		local combatRelic = RelicService.triggerEvent(playerState, activeCombat, "OnCombatStart", {
			Enemy = enemies["enemy_1"] or enemies["elite_1"] or enemies["boss_1"],
		})
		if combatRelic.BonusShield > 0 then
			playerState.Resources.Shield += combatRelic.BonusShield
		end

		CardService.drawCards(playerState, GameConfig.Combat.BaseHandDrawCount)
		SkillService.onTurnStart(playerState)
	end

	if failureInjectionEnabled and failureInjectionStage == 2 then
		error(failureInjectionMessage or "CombatService: Injected stage-2 failure in startCombat for testing")
	end

	if turnTimerConnection then
		turnTimerConnection:Disconnect()
	end

	turnTimerConnection = RunService.Heartbeat:Connect(function()
		if not activeCombat or activeCombat.Phase ~= "PlayerPhase" then return end

		local now = os.clock()
		local elapsed = now - activeCombat.TurnStartTime
		if elapsed >= activeCombat.TurnDuration then
			print("[CombatService] Turn timer expired! Auto-resolving turn...")
			resolveTurn()
		end
	end)

	if not isCombatIsolation then
		pcall(function()
			ArenaVisualizer.teleportPlayersToPedestal()
		end)
	end

	CombatService.broadcastSnapshots("Battle initiated! Choose your actions.")
	return activeCombat
end

-- Plays a card by its stable CardInstanceId targeting a specific entity (Enemy InstanceId, Ally UserId, or Self)
function CombatService.playCard(player: any, cardInstanceId: string, targetParam: any?): (boolean, string?)
	if not activeCombat then
		return false, "No active combat encounter."
	end
	if activeCombat.Phase ~= "PlayerPhase" then
		return false, "Combat is not in PlayerPhase."
	end

	local playerState = partyRef[player.UserId]
	if not playerState then
		return false, "Player not in party."
	end

	if playerState.IsConnected == false then
		return false, "Disconnected players cannot play cards."
	end

	if playerState.IsDowned then
		return false, "Downed players cannot play cards."
	end

	-- Locate card in hand by CardInstanceId
	local cardInst = CardService.getCardInHand(playerState, cardInstanceId)
	if not cardInst then
		return false, "Card not found in hand."
	end

	local cardDef = cardInst.CardData
	local usageAllowed, usageError = CardRulesService.canUseCard(playerState, cardDef)
	if not usageAllowed then
		return false, usageError
	end
	-- Authoritative target resolution via TargetResolver
	local resolvedTarget = TargetResolver.resolveTarget(
		playerState,
		cardDef.Target,
		targetParam,
		activeCombat,
		partyRef
	)
	if not resolvedTarget.Success then
		return false, resolvedTarget.Error
	end

	local targetEnemy = resolvedTarget.EnemyTarget
	local targetPlayer = resolvedTarget.PlayerTarget
	local targetEnemyHPBefore = if targetEnemy then targetEnemy.HP else nil

	-- Pre-validate effect preconditions before mutating any state or resources
	local anyApplicable = false
	for _, eff in cardDef.Effects do
		if not EffectResolver.isSupportedEffectType(eff.Type) then
			return false, "Unsupported effect type: " .. tostring(eff.Type)
		end
		local conditionApplies = true
		if eff.Condition and eff.Condition ~= "" then
			if eff.Condition == "TargetDowned" then
				conditionApplies = (targetPlayer ~= nil and targetPlayer.IsDowned == true)
			elseif eff.Condition == "TargetLiving" then
				conditionApplies = (targetPlayer == nil or targetPlayer.IsDowned ~= true)
			elseif eff.Condition == "LowHP" then
				local p = targetPlayer or playerState
				conditionApplies = (p.Resources.HP < (p.Resources.MaxHP * 0.5))
			else
				return false, "Unknown effect condition: " .. tostring(eff.Condition)
			end
		end

		if conditionApplies then
			anyApplicable = true
			if eff.Type == "Damage" then
				if not targetEnemy or targetEnemy.HP <= 0 then
					return false, "No living enemy target."
				end
			elseif eff.Type == "Heal" then
				if targetPlayer and targetPlayer.IsDowned then
					return false, "Cannot heal downed player."
				end
			elseif eff.Type == "Revive" then
				if targetPlayer and not targetPlayer.IsDowned then
					return false, "Player is not downed."
				end
			end
		end
	end

	if #cardDef.Effects > 0 and not anyApplicable then
		return false, "No applicable card effects for target state."
	end

	-- Energy verification with StatResolver CostReduction
	local playerStats = StatResolver.resolvePlayerStats(playerState)
	local effectiveCost = cardInst.CardData.Cost
	if playerStats.CostReduction and playerStats.CostReduction > 0 then
		effectiveCost = math.max(0, effectiveCost - playerStats.CostReduction)
	end

	-- Pre-check energy and resource affordability before ANY state mutations
	if playerState.ClassId == "BloodPriest" then
		if playerState.Resources.Energy < effectiveCost then
			local missing = effectiveCost - playerState.Resources.Energy
			local hpCost = missing * 5
			if playerState.Resources.HP <= hpCost then
				return false, "Not enough Energy or HP to pay cost!"
			end
		end
	else
		if playerState.Resources.Energy < effectiveCost then
			return false, "Not enough Energy!"
		end
	end

	-- COMMIT PHASE: All validations passed. Capture atomic snapshot before mutating combat/player state
	local txSnapshot = ActionTransaction.beginCombatTransaction(playerState, activeCombat, partyRef)

	-- Evaluate Class Gimmick (all validations passed)
	local gimmick = ClassService.processGimmickOnCardPlay(playerState, cardInst, targetEnemy, effectiveCost)

	if not gimmick.FreeEnergy then
		playerState.Resources.Energy -= effectiveCost
	end

	-- Move card from hand to discard pile
	CardService.playCardFromHand(playerState, cardInstanceId)
	local remainingUses = CardRulesService.recordUse(playerState, cardDef)

	local cardDidHit = true
	local hitChance = 1
	if targetEnemy then
		local hitResult = CardRulesService.resolveHit(cardDef, targetEnemy)
		cardDidHit = hitResult.DidHit
		hitChance = hitResult.HitChance
	end
	local presentation = cardDef.Presentation
	logEvent(
		"CardPresented",
		tostring(playerState.UserId),
		resolvedTarget.TargetId,
		nil,
		cardDef.Name,
		{
			CardDefinitionId = cardDef.Id,
			CardRarity = cardDef.Rarity or "Common",
			AnimationId = if presentation then presentation.AnimationId else cardDef.Id,
			AnimationType = if presentation then presentation.AnimationType else "Aura",
			ProjectileShape = if presentation then presentation.ProjectileShape else nil,
			EffectColor = if presentation then presentation.EffectColor else cardDef.Color,
			ImpactEffectId = if presentation then presentation.ImpactEffectId else "DefaultImpact",
			DidHit = cardDidHit,
		}
	)
	if not cardDidHit and targetEnemy then
		logEvent(
			"CardMissed",
			tostring(playerState.UserId),
			targetEnemy.InstanceId,
			math.round(hitChance * 100),
			string.format("MISS! %s had %d%% accuracy.", cardDef.Name, math.round(hitChance * 100))
		)
	end

	-- Relic Trigger: OnCardPlay
	local relicTrigger = RelicService.triggerEvent(playerState, activeCombat, "OnCardPlay", {
		Card = cardInst,
		Enemy = targetEnemy,
	})

	local totalBonusDamage = gimmick.BonusDamage + relicTrigger.BonusDamage
	local totalBonusShield = gimmick.BonusShield + relicTrigger.BonusShield

	if relicTrigger.BonusEnergy > 0 then
		playerState.Resources.Energy = math.min(playerState.Resources.MaxEnergy, playerState.Resources.Energy + relicTrigger.BonusEnergy)
	end

	local cardHasShieldEffect = false
	for _, eff in cardInst.CardData.Effects do
		if eff.Type == "Shield" then
			cardHasShieldEffect = true
			break
		end
	end

	if gimmick.PoisonApplied > 0 and targetEnemy and cardDidHit then
		StatusService.applyStatus(targetEnemy.InstanceId, "Poison", gimmick.PoisonApplied, nil, tostring(playerState.UserId), targetEnemy)
	end

	-- Build action modifiers for deterministic ModifierResolver & EffectResolver
	local actionModifiers: { StateTypes.Modifier } = {}
	if totalBonusDamage > 0 then
		table.insert(actionModifiers, ModifierResolver.createModifier(
			"ActionBonusDamage",
			"GimmickAndRelics",
			"Damage",
			"Add",
			totalBonusDamage,
			100
		))
	end
	if totalBonusShield > 0 then
		if cardHasShieldEffect then
			table.insert(actionModifiers, ModifierResolver.createModifier(
				"ActionBonusShield",
				"GimmickAndRelics",
				"Shield",
				"Add",
				totalBonusShield,
				100
			))
		else
			playerState.Resources.Shield += totalBonusShield
		end
	end

	-- Phase 3: Include equipment and passive modifiers from StatResolver
	local playerModifiers = StatResolver.collectPlayerModifiers(playerState)
	for _, mod in playerModifiers do
		table.insert(actionModifiers, mod)
	end

	-- Execute Card Effects via generic EffectResolver
	local actionCtx: EffectResolver.ActionContext = {
		SourcePlayer = playerState,
		Target = resolvedTarget,
		CombatState = activeCombat,
		Party = partyRef,
		CardInstance = cardInst,
		Modifiers = actionModifiers,
		LogEvent = logEvent,
		OnKillCallback = function(defeatedEnemy)
			recordEnemyDefeat(defeatedEnemy, playerState.DisplayName, string.format("%s was defeated!", defeatedEnemy.Name), false)
			ClassService.processGimmickOnKill(playerState)
			local relicResult = RelicService.triggerEvent(playerState, activeCombat, "OnKill", { Enemy = defeatedEnemy })
			if relicResult then
				if relicResult.BonusEnergy > 0 then
					playerState.Resources.Energy += relicResult.BonusEnergy
					logEvent("EnergyGained", "Relic", playerState.DisplayName, relicResult.BonusEnergy, string.format("+%d Energy (Relic)", relicResult.BonusEnergy))
				end
				if relicResult.BonusDraw > 0 then
					CardService.drawCards(playerState, relicResult.BonusDraw)
				end
			end
		end,
		DidRevive = false,
		GuaranteedCritical = gimmick.GuaranteedCritical,
	}

	local effectsToResolve: { CardData.Effect } = {}
	for _, effect in cardInst.CardData.Effects do
		local effectTarget = effect.Target or cardDef.Target
		if cardDidHit or effectTarget ~= "Enemy" then
			table.insert(effectsToResolve, effect)
		end
	end
	local effectResults = EffectResolver.resolveEffects(effectsToResolve, actionCtx)
	if targetEnemy and targetEnemyHPBefore and targetEnemy.HP > 0 and targetEnemy.HP < targetEnemyHPBefore then
		syncBossPhase(targetEnemy, playerState.DisplayName)
	end

	-- Heavy cards contribute Break exactly once per card action. This mutation is
	-- inside the transaction: any later effect failure rolls the meter back with
	-- HP, Energy, card piles, statuses, and buffered combat events.
	if targetEnemy and cardDidHit then
		local breakDamage = BreakService.getCardBreakDamage(cardDef)
		local breakAdded, didBreak = BreakService.applyBreakDamage(targetEnemy, breakDamage, false)
		if breakAdded > 0 then
			logEvent("BreakDamage", playerState.DisplayName, targetEnemy.InstanceId, breakAdded, string.format("+%d Break", breakAdded))
		end
		if didBreak then
			logEvent("EnemyBroken", playerState.DisplayName, targetEnemy.InstanceId, nil, string.format("%s was Broken!", targetEnemy.Name))
		end
	end

	-- Transaction verification: all required effects must succeed
	local hasFailure = false
	local failureMsg = "Card effect execution failed."
	if #effectsToResolve > 0 and #effectResults == 0 then
		hasFailure = true
		failureMsg = "No card effects were satisfied or executed."
	else
		for _, res in ipairs(effectResults) do
			if not res.Success then
				hasFailure = true
				failureMsg = res.Message or failureMsg
				break
			end
		end
	end

	if hasFailure then
		ActionTransaction.rollbackCombatTransaction(txSnapshot, playerState, activeCombat, partyRef)
		return false, failureMsg
	end

	if remainingUses ~= nil and remainingUses <= 0 then
		CardService.exhaustUnavailableDefinitionCopies(playerState, cardDef.Id)
	end

	-- Execution succeeded: commit transaction
	ActionTransaction.commitCombatTransaction(txSnapshot, activeCombat)

	-- Check Victory
	if areAllEnemiesDead() then
		endCombat("Victory")
		return true, nil
	end

	CombatService.broadcastSnapshots(string.format("%s played [%s]!", playerState.DisplayName, cardInst.CardData.Name))
	return true, nil
end

-- Executes an equipped active skill server-authoritatively
function CombatService.useSkill(player: any, slot: StateTypes.SkillSlot, targetParam: any?): (boolean, string?)
	if not activeCombat then
		return false, "No active combat encounter."
	end
	if activeCombat.Phase ~= "PlayerPhase" then
		return false, "Combat is not in PlayerPhase."
	end

	local playerState = partyRef[player.UserId]
	if not playerState then
		return false, "Player not in party."
	end

	local ok, err = SkillService.useSkill(
		playerState,
		slot,
		targetParam,
		activeCombat,
		partyRef,
		logEvent,
		function(enemy)
			syncBossPhase(enemy, playerState.DisplayName)
		end
	)
	if not ok then
		return false, err
	end

	-- Check Victory
	if areAllEnemiesDead() then
		endCombat("Victory")
		return true, nil
	end

	CombatService.broadcastSnapshots(string.format("%s used %s!", playerState.DisplayName, tostring(slot)))
	return true, nil
end

-- Toggles player ready status; resolves turn if all living players are ready
function CombatService.voteReady(player: any): (boolean, string?)
	if not activeCombat then
		return false, "No active combat encounter."
	end
	if activeCombat.Phase ~= "PlayerPhase" then
		return false, "Combat is not in PlayerPhase."
	end

	local playerState = partyRef[player.UserId]
	if not playerState then
		return false, "Player not in party."
	end

	if playerState.IsConnected == false then
		return false, "Disconnected players cannot vote ready."
	end

	if playerState.IsDowned then
		return false, "Downed players cannot vote ready."
	end

	playerState.IsReady = not playerState.IsReady
	logEvent("PlayerReadyVoted", playerState.DisplayName, "Combat", nil, playerState.IsReady and "Ready!" or "Unready")

	if areAllLivingPlayersReady() then
		print("[CombatService] All active players ready! Resolving turn...")
		resolveTurn()
	else
		CombatService.broadcastSnapshots()
	end

	return true, nil
end

-- Rescues a downed teammate by spending Energy
function CombatService.rescueTeammate(rescuer: any, targetUserId: number): (boolean, string?)
	if not activeCombat or activeCombat.Phase ~= "PlayerPhase" then
		return false, "Can only rescue teammates during PlayerPhase."
	end

	local rescuerState = partyRef[rescuer.UserId]
	local targetState = partyRef[targetUserId]

	if not rescuerState or not targetState then
		return false, "Player not found."
	end

	if rescuerState.IsConnected == false then
		return false, "Disconnected players cannot rescue others."
	end

	if rescuerState.IsDowned then
		return false, "Downed players cannot rescue others."
	end

	if targetState.IsConnected == false then
		return false, "Cannot rescue a disconnected teammate."
	end

	if not targetState.IsDowned then
		return false, "Target is not downed."
	end

	if rescuerState.Resources.Energy < GameConfig.Coop.RescueEnergyCost then
		return false, string.format("Need %d Energy to rescue teammate!", GameConfig.Coop.RescueEnergyCost)
	end

	rescuerState.Resources.Energy -= GameConfig.Coop.RescueEnergyCost
	targetState.IsDowned = false
	targetState.Resources.HP = math.max(1, math.floor(targetState.Resources.MaxHP * GameConfig.Coop.ReviveHpPercent))
	targetState.IsReady = false

	logEvent("PlayerRevived", rescuerState.DisplayName, targetState.DisplayName, targetState.Resources.HP, string.format("%s rescued %s!", rescuerState.DisplayName, targetState.DisplayName))
	CombatService.broadcastSnapshots(string.format("%s was revived by %s!", targetState.DisplayName, rescuerState.DisplayName))

	return true, nil
end

-- Simulates an automatic turn timeout resolution (used by integration testing & timer expiry)
function CombatService.forceTurnTimeout()
	if activeCombat and activeCombat.Phase == "PlayerPhase" then
		print("[CombatService] Forcing turn timeout resolution...")
		resolveTurn()
	end
end

function CombatService.getActiveCombat(): StateTypes.CombatState?
	return activeCombat
end

function CombatService.cleanupCombat()
	if turnTimerConnection then
		turnTimerConnection:Disconnect()
		turnTimerConnection = nil
	end
	if not isCombatIsolation then
		ArenaVisualizer.cleanup()
	end
	local rs = getReactionService()
	if rs then
		rs.cleanup()
	end
	StatusService.resetCombat()
	activeCombat = nil
	partyRef = {}
	onCombatEndCallback = nil
end

function CombatService.init()
	print("[CombatService] Initialized authoritative single-encounter combat engine.")
end

return CombatService
