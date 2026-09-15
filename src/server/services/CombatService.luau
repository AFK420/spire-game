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
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CardData = require(Shared:WaitForChild("CardData") :: ModuleScript)
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)

local servicesFolder = script.Parent
local CardService = require(servicesFolder:WaitForChild("CardService") :: ModuleScript)
local ClassService = require(servicesFolder:WaitForChild("ClassService") :: ModuleScript)
local RelicService = require(servicesFolder:WaitForChild("RelicService") :: ModuleScript)
local NetworkService = require(servicesFolder:WaitForChild("NetworkService") :: ModuleScript)
local ArenaVisualizer = require(servicesFolder:WaitForChild("ArenaVisualizer") :: ModuleScript)

local CombatService = {}

--------------------------------------------------------------------------------
-- Constants & Configuration
--------------------------------------------------------------------------------

local DEFAULT_TURN_DURATION = 45 -- Monotonic seconds
local RESCUE_ENERGY_COST = 2
local REVIVE_HP_PERCENT = 0.25

-- Multi-player co-op scaling
local function scaleEnemyHp(baseHp: number, playerCount: number): number
	local clamped = math.clamp(playerCount, 1, 4)
	return math.round(baseHp * (1 + 0.65 * (clamped - 1)))
end

local function scaleEnemyAttack(baseAtk: number, playerCount: number): number
	local clamped = math.clamp(playerCount, 1, 4)
	return math.round(baseAtk * (1 + 0.20 * (clamped - 1)))
end

--------------------------------------------------------------------------------
-- Active Combat State
--------------------------------------------------------------------------------

local activeCombat: StateTypes.CombatState? = nil
local partyRef: { [number]: StateTypes.PlayerState } = {}
local onCombatEndCallback: ((outcome: "Victory" | "Defeat") -> ())? = nil
local turnTimerConnection: RBXScriptConnection? = nil

--------------------------------------------------------------------------------
-- Snapshot Generators
--------------------------------------------------------------------------------

function CombatService.getCombatSnapshotForPlayer(player: Player): StateTypes.CombatSnapshot?
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

	-- Local Hand Views
	local localHand: { StateTypes.CardView } = {}
	for _, cardInst in playerState.Hand do
		table.insert(localHand, CardService.toCardView(cardInst))
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

	ArenaVisualizer.syncEnemies(activeCombat.Enemies)

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
		-- Attack intent
		local variance = rng:NextInteger(-2, 3)
		local dmg = math.max(4, enemy.AttackPower + variance)
		return {
			Type = "Attack",
			Value = dmg,
			Description = string.format("Striking for %d damage", dmg),
		}
	elseif roll <= 85 then
		-- Defend intent
		local shieldVal = math.max(6, math.floor(enemy.AttackPower * 0.8))
		return {
			Type = "Defend",
			Value = shieldVal,
			Description = string.format("Fortifying for %d shield", shieldVal),
		}
	else
		-- Debuff / Poison intent
		return {
			Type = "Debuff",
			Value = 3,
			Description = "Exhaling venomous fumes (3 Poison)",
		}
	end
end

--------------------------------------------------------------------------------
-- Damage & Combat Resolution Calculations
--------------------------------------------------------------------------------

local function applyDamageToEnemy(enemy: StateTypes.EnemyState, rawDamage: number): (number, number)
	local absorbed = math.min(enemy.Shield, rawDamage)
	enemy.Shield -= absorbed
	local rem = rawDamage - absorbed
	enemy.HP = math.max(0, enemy.HP - rem)
	return rem, absorbed
end

local function applyDamageToPlayer(playerState: StateTypes.PlayerState, rawDamage: number): (number, number)
	local absorbed = math.min(playerState.Resources.Shield, rawDamage)
	playerState.Resources.Shield -= absorbed
	local rem = rawDamage - absorbed
	playerState.Resources.HP = math.max(0, playerState.Resources.HP - rem)

	if playerState.Resources.HP <= 0 then
		playerState.IsDowned = true
		playerState.Resources.HP = 0
		playerState.Resources.Shield = 0
		playerState.IsReady = false
	end

	return rem, absorbed
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

	table.insert(activeCombat.CombatLog, event)
	if #activeCombat.CombatLog > 25 then
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
	local total = 0
	local downed = 0
	for _, pState in partyRef do
		total += 1
		if pState.IsDowned then
			downed += 1
		end
	end
	return total > 0 and (downed == total)
end

local function areAllLivingPlayersReady(): boolean
	local livingCount = 0
	local readyCount = 0
	for _, pState in partyRef do
		if not pState.IsDowned then
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
		task.delay(1.5, function()
			ArenaVisualizer.cleanup()
			cb(outcome)
		end)
	end
end

local function resolveTurn()
	if not activeCombat or activeCombat.Phase ~= "PlayerPhase" then return end

	activeCombat.Phase = "ResolutionPhase"
	CombatService.broadcastSnapshots("Enemies are counterattacking...")

	-- 1. End of Turn Class Gimmicks & Relic Triggers
	for userId, playerState in partyRef do
		if not playerState.IsDowned then
			local dummyTarget: StateTypes.EnemyState? = nil
			for _, enemy in activeCombat.Enemies do
				if enemy.HP > 0 then dummyTarget = enemy break end
			end

			-- Relic triggers: OnTurnEnd (Orichalcum, Pocketwatch, Calipers)
			local relicResult = RelicService.triggerEvent(playerState, activeCombat, "OnTurnEnd", {
				UnspentEnergy = playerState.Resources.Energy,
				Enemy = dummyTarget,
			})

			if relicResult.BonusShield > 0 then
				playerState.Resources.Shield += relicResult.BonusShield
				logEvent("ShieldGained", "Relic", tostring(userId), relicResult.BonusShield, string.format("+%d Shield (Relic)", relicResult.BonusShield))
			end

			-- Calipers check
			if not relicResult.RetainShield then
				playerState.Resources.Shield = 0
			else
				playerState.Resources.Shield = math.min(15, playerState.Resources.Shield)
			end

			-- Discard remaining hand
			CardService.discardHand(playerState)
		end
	end

	-- 2. Enemy Poison & Attacks
	task.spawn(function()
		for enemyId, enemy in activeCombat.Enemies do
			if enemy.HP > 0 then
				-- Poison tick
				if enemy.Poison > 0 then
					local pDmg = enemy.Poison
					enemy.HP = math.max(0, enemy.HP - pDmg)
					enemy.Poison = math.max(0, enemy.Poison - 1)
					logEvent("PoisonTick", enemyId, enemyId, pDmg, string.format("-%d Poison DMG", pDmg))

					if enemy.HP <= 0 then
						logEvent("EnemyDefeated", "Poison", enemyId, nil, string.format("%s collapsed from poison!", enemy.Name))
						continue
					end
				end

				-- Execute Intent
				task.wait(0.4)
				if enemy.Intent.Type == "Attack" then
					ArenaVisualizer.playEnemyAttackAnimation(enemyId)
					local livingPlayers: { StateTypes.PlayerState } = {}
					for _, pState in partyRef do
						if not pState.IsDowned then
							table.insert(livingPlayers, pState)
						end
					end

					if #livingPlayers > 0 then
						local target = livingPlayers[math.random(1, #livingPlayers)]
						local remDmg, _ = applyDamageToPlayer(target, enemy.Intent.Value)
						logEvent("DamageDealt", enemy.Name, target.DisplayName, enemy.Intent.Value, string.format("-%d HP", remDmg))

						-- Relic trigger: OnDamageTaken (BronzeScales, CentennialPuzzle)
						if remDmg > 0 then
							local dmgRelic = RelicService.triggerEvent(target, activeCombat, "OnDamageTaken", {
								Damage = remDmg,
								Enemy = enemy,
							})
							if dmgRelic.BonusDamage > 0 then
								local thornsRem, _ = applyDamageToEnemy(enemy, dmgRelic.BonusDamage)
								logEvent("DamageDealt", "BronzeScales", enemy.Name, dmgRelic.BonusDamage, string.format("-%d Thorns", thornsRem))
							end
						end
					end

				elseif enemy.Intent.Type == "Defend" then
					enemy.Shield += enemy.Intent.Value
					logEvent("ShieldGained", enemy.Name, enemy.Name, enemy.Intent.Value, string.format("+%d Shield", enemy.Intent.Value))

				elseif enemy.Intent.Type == "Debuff" then
					for _, pState in partyRef do
						if not pState.IsDowned then
							logEvent("DebuffApplied", enemy.Name, pState.DisplayName, enemy.Intent.Value, "Debuffed with Poison")
						end
					end
				end

				-- Roll next intent for enemy
				enemy.Intent = generateEnemyIntent(enemy)
			end
		end

		-- 3. Check Post-Resolution Status
		if areAllEnemiesDead() then
			endCombat("Victory")
			return
		end

		if areAllPlayersDowned() then
			endCombat("Defeat")
			return
		end

		-- 4. Start Next Player Turn
		activeCombat.TurnNumber += 1
		activeCombat.Phase = "PlayerPhase"
		activeCombat.TurnStartTime = os.clock()

		for userId, playerState in partyRef do
			playerState.IsReady = false

			if not playerState.IsDowned then
				playerState.Resources.Energy = playerState.Resources.MaxEnergy

				-- Relic OnTurnStart
				local startRelic = RelicService.triggerEvent(playerState, activeCombat, "OnTurnStart")
				playerState.Resources.Energy += startRelic.BonusEnergy

				-- Draw cards: 4 base + bonus
				CardService.drawCards(playerState, 4 + startRelic.BonusDraw)
			end
		end

		CombatService.broadcastSnapshots(string.format("Turn %d Begins! Draw cards and plan actions.", activeCombat.TurnNumber))
	end)
end

--------------------------------------------------------------------------------
-- Public Methods: Encounters, Actions, Ready, Rescue
--------------------------------------------------------------------------------

-- Initializes a new combat encounter with 1 to N enemies scaled to party size
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
		local hp = scaleEnemyHp(baseHp, playerCount)
		local atk = scaleEnemyAttack(baseAtk, playerCount)

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
		local hp = scaleEnemyHp(baseHp, playerCount)
		local atk = scaleEnemyAttack(baseAtk, playerCount)

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
		-- Standard Combat: Supports 1-2 enemies
		local baseHp = 70 + (tier * 10)
		local baseAtk = 8 + math.floor(tier * 1.5)
		local hp = scaleEnemyHp(baseHp, playerCount)
		local atk = scaleEnemyAttack(baseAtk, playerCount)

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
			local minionHp = scaleEnemyHp(40, playerCount)
			local minionAtk = scaleEnemyAttack(5, playerCount)
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
		TurnDuration = DEFAULT_TURN_DURATION,
		Participants = {},
		Enemies = enemies,
		ReadyPlayers = {},
		CombatLog = {},
	}

	-- Setup player combat state
	for userId, playerState in partyRef do
		table.insert(activeCombat.Participants, userId)
		playerState.Resources.Shield = 0
		playerState.Resources.Energy = playerState.Resources.MaxEnergy
		playerState.IsReady = false
		playerState.IsDowned = false

		ClassService.applyClassToPlayer(playerState)
		RelicService.resetCombatState(userId)

		-- Relic OnCombatStart
		local combatRelic = RelicService.triggerEvent(playerState, activeCombat, "OnCombatStart", {
			Enemy = enemies["enemy_1"] or enemies["elite_1"] or enemies["boss_1"],
		})
		if combatRelic.BonusShield > 0 then
			playerState.Resources.Shield += combatRelic.BonusShield
		end

		-- Draw initial hand of 4 cards
		CardService.drawCards(playerState, 4)
	end

	-- Start monotonic turn timer loop
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

	CombatService.broadcastSnapshots("Battle initiated! Choose your actions.")
	return activeCombat
end

-- Plays a card by its stable CardInstanceId targeting a specific Enemy InstanceId
function CombatService.playCard(player: Player, cardInstanceId: string, targetEnemyId: string?): (boolean, string?)
	if not activeCombat or activeCombat.Phase ~= "PlayerPhase" then
		return false, "Combat is not in PlayerPhase."
	end

	local playerState = partyRef[player.UserId]
	if not playerState then
		return false, "Player not in party."
	end

	if playerState.IsDowned then
		return false, "Downed players cannot play cards."
	end

	-- Locate card in hand by CardInstanceId
	local cardInst = CardService.getCardInHand(playerState, cardInstanceId)
	if not cardInst then
		return false, "Card not found in hand."
	end

	-- Resolve target enemy
	local targetEnemy: StateTypes.EnemyState? = nil
	if targetEnemyId and activeCombat.Enemies[targetEnemyId] and activeCombat.Enemies[targetEnemyId].HP > 0 then
		targetEnemy = activeCombat.Enemies[targetEnemyId]
	else
		-- Fallback to first living enemy
		for _, e in activeCombat.Enemies do
			if e.HP > 0 then
				targetEnemy = e
				break
			end
		end
	end

	if not targetEnemy then
		return false, "No valid living target enemy found."
	end

	-- Evaluate Class Gimmick
	local gimmick = ClassService.processGimmickOnCardPlay(playerState, cardInst, targetEnemy)

	-- Energy verification (considering BloodPriest sacrifice)
	if not gimmick.FreeEnergy and playerState.Resources.Energy < cardInst.CardData.Cost then
		return false, "Not enough Energy!"
	end

	if not gimmick.FreeEnergy then
		playerState.Resources.Energy -= cardInst.CardData.Cost
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

	if totalBonusShield > 0 then
		playerState.Resources.Shield += totalBonusShield
	end

	if gimmick.PoisonApplied > 0 then
		targetEnemy.Poison += gimmick.PoisonApplied
	end

	-- Execute Card Effects
	for _, effect in cardInst.CardData.Effects do
		if effect.Type == "Damage" then
			local dmg = effect.Value + totalBonusDamage
			local remDmg, _ = applyDamageToEnemy(targetEnemy, dmg)
			logEvent("DamageDealt", player.DisplayName, targetEnemy.Name, dmg, string.format("-%d HP", remDmg))

			-- Check if enemy died
			if targetEnemy.HP <= 0 then
				logEvent("EnemyDefeated", player.DisplayName, targetEnemy.Name, nil, string.format("%s was defeated!", targetEnemy.Name))
				RelicService.triggerEvent(playerState, activeCombat, "OnKill", { Enemy = targetEnemy })
			end

		elseif effect.Type == "Shield" then
			local shieldVal = effect.Value + totalBonusShield
			playerState.Resources.Shield += shieldVal
			logEvent("ShieldGained", player.DisplayName, player.DisplayName, shieldVal, string.format("+%d Shield", shieldVal))

		elseif effect.Type == "Poison" then
			targetEnemy.Poison += effect.Value
			logEvent("PoisonApplied", player.DisplayName, targetEnemy.Name, effect.Value, string.format("+%d Poison", effect.Value))

		elseif effect.Type == "Heal" then
			playerState.Resources.HP = math.min(playerState.Resources.MaxHP, playerState.Resources.HP + effect.Value)
			logEvent("Healed", player.DisplayName, player.DisplayName, effect.Value, string.format("+%d HP", effect.Value))

		elseif effect.Type == "Draw" then
			CardService.drawCards(playerState, effect.Value)
		end
	end

	-- Check Victory
	if areAllEnemiesDead() then
		endCombat("Victory")
		return true, nil
	end

	CombatService.broadcastSnapshots(string.format("%s played [%s]!", player.DisplayName, cardInst.CardData.Name))
	return true, nil
end

-- Toggles player ready status; resolves turn if all living players are ready
function CombatService.voteReady(player: Player): (boolean, string?)
	if not activeCombat or activeCombat.Phase ~= "PlayerPhase" then
		return false, "Cannot vote ready outside PlayerPhase."
	end

	local playerState = partyRef[player.UserId]
	if not playerState then
		return false, "Player not in party."
	end

	if playerState.IsDowned then
		return false, "Downed players cannot vote ready."
	end

	playerState.IsReady = not playerState.IsReady
	logEvent("PlayerReadyVoted", player.DisplayName, "Combat", nil, playerState.IsReady and "Ready!" or "Unready")

	if areAllLivingPlayersReady() then
		print("[CombatService] All active players ready! Resolving turn...")
		resolveTurn()
	else
		CombatService.broadcastSnapshots()
	end

	return true, nil
end

-- Rescues a downed teammate by spending 2 Energy
function CombatService.rescueTeammate(rescuer: Player, targetUserId: number): (boolean, string?)
	if not activeCombat or activeCombat.Phase ~= "PlayerPhase" then
		return false, "Can only rescue teammates during PlayerPhase."
	end

	local rescuerState = partyRef[rescuer.UserId]
	local targetState = partyRef[targetUserId]

	if not rescuerState or not targetState then
		return false, "Player not found."
	end

	if rescuerState.IsDowned then
		return false, "Downed players cannot rescue others."
	end

	if not targetState.IsDowned then
		return false, "Target is not downed."
	end

	if rescuerState.Resources.Energy < RESCUE_ENERGY_COST then
		return false, string.format("Need %d Energy to rescue teammate!", RESCUE_ENERGY_COST)
	end

	rescuerState.Resources.Energy -= RESCUE_ENERGY_COST
	targetState.IsDowned = false
	targetState.Resources.HP = math.max(1, math.floor(targetState.Resources.MaxHP * REVIVE_HP_PERCENT))
	targetState.IsReady = false

	logEvent("PlayerRevived", rescuer.DisplayName, targetState.DisplayName, targetState.Resources.HP, string.format("%s rescued %s!", rescuer.DisplayName, targetState.DisplayName))
	CombatService.broadcastSnapshots(string.format("%s was revived by %s!", targetState.DisplayName, rescuer.DisplayName))

	return true, nil
end

function CombatService.getActiveCombat(): StateTypes.CombatState?
	return activeCombat
end

function CombatService.cleanupCombat()
	if turnTimerConnection then
		turnTimerConnection:Disconnect()
		turnTimerConnection = nil
	end
	ArenaVisualizer.cleanup()
	activeCombat = nil
	partyRef = {}
	onCombatEndCallback = nil
end

function CombatService.init()
	print("[CombatService] Initialized authoritative multi-enemy combat engine.")
end

return CombatService
