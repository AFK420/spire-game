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

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CardData = require(Shared:WaitForChild("CardData") :: ModuleScript)
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)
local GameConfig = require(Shared:WaitForChild("GameConfig") :: ModuleScript)

local servicesFolder = script.Parent
local CardService = require(servicesFolder:WaitForChild("CardService") :: ModuleScript)
local ClassService = require(servicesFolder:WaitForChild("ClassService") :: ModuleScript)
local RelicService = require(servicesFolder:WaitForChild("RelicService") :: ModuleScript)
local NetworkService = require(servicesFolder:WaitForChild("NetworkService") :: ModuleScript)
local ArenaVisualizer = require(servicesFolder:WaitForChild("ArenaVisualizer") :: ModuleScript)
local TargetResolver = require(servicesFolder:WaitForChild("TargetResolver") :: ModuleScript)
local ModifierResolver = require(servicesFolder:WaitForChild("ModifierResolver") :: ModuleScript)
local DamagePipeline = require(servicesFolder:WaitForChild("DamagePipeline") :: ModuleScript)
local StatusService = require(servicesFolder:WaitForChild("StatusService") :: ModuleScript)
local EffectResolver = require(servicesFolder:WaitForChild("EffectResolver") :: ModuleScript)
local StatResolver = require(servicesFolder:WaitForChild("StatResolver") :: ModuleScript)
local SkillService = require(servicesFolder:WaitForChild("SkillService") :: ModuleScript)
local ActionTransaction = require(servicesFolder:WaitForChild("ActionTransaction") :: ModuleScript)

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

		enemyViews[id] = {
			InstanceId = enemy.InstanceId,
			Name = enemy.Name,
			HP = enemy.HP,
			MaxHP = enemy.MaxHP,
			Shield = enemy.Shield,
			Poison = enemy.Poison,
			AttackPower = enemy.AttackPower,
			IntentText = string.format("%s (%d)", enemy.Intent.Type, enemy.Intent.Value),
			IntentIcon = intentIcon,
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
		}
	end

	-- Local Hand Views
	local localHand: { StateTypes.CardView } = {}
	for _, cardInst in playerState.Hand do
		table.insert(localHand, CardService.toCardView(cardInst, playerState))
	end
	table.sort(localHand, function(a, b) return a.Name < b.Name end)

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
		Message = nil,
	}
end

function CombatService.broadcastSnapshots(message: string?)
	if not activeCombat then return end

	if not isCombatIsolation then
		ArenaVisualizer.syncEnemies(activeCombat.Enemies)
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
	local rng = Random.new()
	local roll = rng:NextInteger(1, 100)

	if roll <= 65 then
		local variance = rng:NextInteger(-2, 3)
		local dmg = math.max(4, enemy.AttackPower + variance)
		return {
			Type = "Attack",
			Value = dmg,
			Description = string.format("Striking for %d damage", dmg),
		}
	elseif roll <= 85 then
		local shieldVal = math.max(6, math.floor(enemy.AttackPower * 0.8))
		return {
			Type = "Defend",
			Value = shieldVal,
			Description = string.format("Fortifying for %d shield", shieldVal),
		}
	else
		return {
			Type = "Debuff",
			Value = 3,
			Description = "Exhaling venomous fumes (3 Poison)",
		}
	end
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

local function logEvent(eventType: string, sourceId: string, targetId: string, value: number?, text: string?)
	if not activeCombat then return end

	local event: StateTypes.CombatEvent = {
		Type = eventType,
		SourceId = sourceId,
		TargetId = targetId,
		Value = value,
		ExtraText = text,
		Timestamp = os.clock(),
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
			cb(outcome)
		else
			task.delay(1.5, function()
				if not isCombatIsolation then
					ArenaVisualizer.cleanup()
				end
				cb(outcome)
			end)
		end
	end
end

local function resolveTurn()
	if not activeCombat or activeCombat.Phase ~= "PlayerPhase" then return end

	activeCombat.Phase = "ResolutionPhase"
	CombatService.broadcastSnapshots("Enemies are counterattacking...")

	-- 1. End of Turn Class Gimmicks & Relic Triggers
	for userId, playerState in partyRef do
		if not playerState.IsDowned and playerState.IsConnected ~= false then
			local dummyTarget: StateTypes.EnemyState? = nil
			for _, enemy in activeCombat.Enemies do
				if enemy.HP > 0 then dummyTarget = enemy break end
			end

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
						local remDmg, _ = applyDamageToEnemy(enemy, gimmickEnd.EndTurnDamage)
						logEvent("DamageDealt", "Gimmick", enemy.Name, gimmickEnd.EndTurnDamage, string.format("-%d HP (Gimmick)", remDmg))
						if enemy.HP <= 0 then
							logEvent("EnemyDefeated", "Gimmick", enemy.InstanceId, nil, string.format("%s was defeated by gimmick damage!", enemy.Name))
						end
						break
					end
				end
			end

			CardService.discardHand(playerState)
		end
	end

	-- 2. Enemy Poison & Attacks
	task.spawn(function()
		for enemyId, enemy in activeCombat.Enemies do
			if enemy.HP > 0 then
				local statusTicks = StatusService.tickStatuses(enemyId, "TurnStart", enemy, true)
				local statusKiller: string? = nil
				for _, tick in statusTicks do
					if tick.DamageDealt > 0 then
						logEvent("DamageDealt", tick.DefinitionId, enemy.Name, tick.DamageDealt, string.format("-%d HP (%s)", tick.DamageDealt, tick.DefinitionId))
					end
					if tick.Defeated then
						statusKiller = tick.DefinitionId
					end
				end

				if enemy.HP <= 0 then
					local killer = statusKiller or "Poison"
					logEvent("EnemyDefeated", killer, enemyId, nil, string.format("%s collapsed from %s!", enemy.Name, killer:lower()))
					continue
				end

				local rm = getRunManager()
				if not (rm and rm.isTestIsolationActive and rm.isTestIsolationActive()) then
					task.wait(0.3)
				end
				if enemy.Intent.Type == "Attack" then
					if not isCombatIsolation then
						ArenaVisualizer.playEnemyAttackAnimation(enemyId)
					end
					local livingPlayers: { StateTypes.PlayerState } = {}
					for _, pState in partyRef do
						if not pState.IsDowned and pState.IsConnected ~= false then
							table.insert(livingPlayers, pState)
						end
					end

					if #livingPlayers > 0 then
						local target = livingPlayers[math.random(1, #livingPlayers)]
						local remDmg, _ = applyDamageToPlayer(target, enemy.Intent.Value)
						logEvent("DamageDealt", enemy.Name, target.DisplayName, enemy.Intent.Value, string.format("-%d HP", remDmg))

						if remDmg > 0 then
							local dmgRelic = RelicService.triggerEvent(target, activeCombat, "OnDamageTaken", {
								Damage = remDmg,
								Enemy = enemy,
							})
							if dmgRelic.BonusDamage > 0 then
								local thornsRem, _ = applyDamageToEnemy(enemy, dmgRelic.BonusDamage)
								logEvent("DamageDealt", "BronzeScales", enemy.Name, dmgRelic.BonusDamage, string.format("-%d Thorns", thornsRem))
							end
							if dmgRelic.BonusDraw > 0 then
								CardService.drawCards(target, dmgRelic.BonusDraw)
								logEvent("CardDrawn", "Relic", target.DisplayName, dmgRelic.BonusDraw, string.format("+%d Cards Drawn (Relic)", dmgRelic.BonusDraw))
							end
						end
					end

				elseif enemy.Intent.Type == "Defend" then
					enemy.Shield += enemy.Intent.Value
					logEvent("ShieldGained", enemy.Name, enemy.Name, enemy.Intent.Value, string.format("+%d Shield", enemy.Intent.Value))

				elseif enemy.Intent.Type == "Debuff" then
					for _, pState in partyRef do
						if not pState.IsDowned and pState.IsConnected ~= false then
							StatusService.applyStatus(tostring(pState.UserId), "Poison", enemy.Intent.Value, nil, enemy.InstanceId, pState)
							logEvent("DebuffApplied", enemy.Name, pState.DisplayName, enemy.Intent.Value, "Debuffed with Poison")
						end
					end

				elseif enemy.Intent.Type == "Buff" then
					enemy.AttackPower = (enemy.AttackPower or 10) + enemy.Intent.Value
					logEvent("BuffGained", enemy.Name, enemy.Name, enemy.Intent.Value, string.format("+%d Attack Power", enemy.Intent.Value))
				end

				enemy.Intent = generateEnemyIntent(enemy)
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
						logEvent("DamageDealt", tick.DefinitionId, playerState.DisplayName, tick.DamageDealt, string.format("-%d HP (%s)", tick.DamageDealt, tick.DefinitionId))
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

		-- STATUS-INDUCED TOTAL DEFEAT:
		-- If all players were downed by turn-start statuses, immediately trigger Defeat
		-- without advancing TurnNumber, entering PlayerPhase, refreshing energy, or drawing cards.
		if areAllPlayersDowned() then
			endCombat("Defeat")
			return
		end

		-- Living players remain: advance turn number and start next player phase
		activeCombat.TurnNumber += 1
		activeCombat.Phase = "PlayerPhase"
		activeCombat.TurnStartTime = os.clock()

		for _, playerState in partyRef do
			if not playerState.IsDowned and playerState.IsConnected ~= false then
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

	local playerCount = 0
	for _ in party do playerCount += 1 end

	local enemies: { [string]: StateTypes.EnemyState } = {}

	if roomType == "Elite Monster" then
		local baseHp = 135 + (tier * 15)
		local baseAtk = 14 + (tier * 2)
		local hp = GameConfig.scaleEnemyHp(baseHp, playerCount)
		local atk = GameConfig.scaleEnemyAttack(baseAtk, playerCount)

		enemies["elite_1"] = {
			InstanceId = "elite_1",
			DefinitionId = "GremlinNob",
			Name = "Gremlin Nob (Elite)",
			HP = hp,
			MaxHP = hp,
			Shield = 0,
			Poison = 0,
			AttackPower = atk,
			Intent = { Type = "Attack", Value = atk, Description = "Fierce Slam" },
			ModelRef = nil,
		}
	elseif roomType == "Act Boss" then
		local baseHp = 220 + (tier * 25)
		local baseAtk = 16 + (tier * 3)
		local hp = GameConfig.scaleEnemyHp(baseHp, playerCount)
		local atk = GameConfig.scaleEnemyAttack(baseAtk, playerCount)

		enemies["boss_1"] = {
			InstanceId = "boss_1",
			DefinitionId = "SpireGuardian",
			Name = "The Spire Guardian (Boss)",
			HP = hp,
			MaxHP = hp,
			Shield = 0,
			Poison = 0,
			AttackPower = atk,
			Intent = { Type = "Attack", Value = atk, Description = "Cataclysm Strike" },
			ModelRef = nil,
		}
	else
		local baseHp = 70 + (tier * 10)
		local baseAtk = 8 + math.floor(tier * 1.5)
		local hp = GameConfig.scaleEnemyHp(baseHp, playerCount)
		local atk = GameConfig.scaleEnemyAttack(baseAtk, playerCount)

		enemies["enemy_1"] = {
			InstanceId = "enemy_1",
			DefinitionId = "SpireSentinel",
			Name = "Spire Sentinel",
			HP = hp,
			MaxHP = hp,
			Shield = 0,
			Poison = 0,
			AttackPower = atk,
			Intent = { Type = "Attack", Value = atk, Description = "Sentry Bolt" },
			ModelRef = nil,
		}

		if tier >= 3 then
			local minionHp = GameConfig.scaleEnemyHp(40, playerCount)
			local minionAtk = GameConfig.scaleEnemyAttack(5, playerCount)
			enemies["enemy_2"] = {
				InstanceId = "enemy_2",
				DefinitionId = "Cultist",
				Name = "Dark Cultist",
				HP = minionHp,
				MaxHP = minionHp,
				Shield = 0,
				Poison = 0,
				AttackPower = minionAtk,
				Intent = { Type = "Buff", Value = 2, Description = "Ritual Chant" },
				ModelRef = nil,
			}
		end
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
	}

	-- Setup player combat state
	StatusService.resetCombat()
	for userId, playerState in partyRef do
		table.insert(activeCombat.Participants, userId)
		ClassService.resetCombatResources(playerState)
		ClassService.resetClassCombatGimmicks(userId)
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
		ArenaVisualizer.teleportPlayersToPedestal()
	end

	CombatService.broadcastSnapshots("Battle initiated! Choose your actions.")
	return activeCombat
end

-- Plays a card by its stable CardInstanceId targeting a specific entity (Enemy InstanceId, Ally UserId, or Self)
function CombatService.playCard(player: any, cardInstanceId: string, targetParam: any?): (boolean, string?)
	if not activeCombat or activeCombat.Phase ~= "PlayerPhase" then
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

	-- Pre-validate effect preconditions before mutating any state or resources
	for _, eff in cardDef.Effects do
		if not EffectResolver.isSupportedEffectType(eff.Type) then
			return false, "Unsupported effect type: " .. tostring(eff.Type)
		end
		if eff.Condition and eff.Condition ~= "" then
			if eff.Condition ~= "TargetDowned" and eff.Condition ~= "TargetLiving" and eff.Condition ~= "LowHP" then
				return false, "Unknown effect condition: " .. tostring(eff.Condition)
			end
		end
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

	if gimmick.PoisonApplied > 0 and targetEnemy then
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

	local effectResults = EffectResolver.resolveEffects(cardInst.CardData.Effects, actionCtx)

	-- Transaction verification: all required effects must succeed
	local hasFailure = false
	local failureMsg = "Card effect execution failed."
	if #cardInst.CardData.Effects > 0 and #effectResults == 0 then
		hasFailure = true
		failureMsg = "No card effects were satisfied or executed."
	else
		for _, res in effectResults do
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
	if not activeCombat or activeCombat.Phase ~= "PlayerPhase" then
		return false, "Combat is not in PlayerPhase."
	end

	local playerState = partyRef[player.UserId]
	if not playerState then
		return false, "Player not in party."
	end

	local ok, err = SkillService.useSkill(playerState, slot, targetParam, activeCombat, partyRef, logEvent)
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
	if not activeCombat or activeCombat.Phase ~= "PlayerPhase" then
		return false, "Cannot vote ready outside PlayerPhase."
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
	StatusService.resetCombat()
	activeCombat = nil
	partyRef = {}
	onCombatEndCallback = nil
end

function CombatService.init()
	print("[CombatService] Initialized authoritative single-encounter combat engine.")
end

return CombatService
