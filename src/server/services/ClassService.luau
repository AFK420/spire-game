--!strict

--[=[
	ClassService ModuleScript
	Mapped to: ServerScriptService.Server.services.ClassService
	Manages Class & Subclass selection, starting deck generation as CardInstances,
	and modular combat gimmick calculations for Card Rift: Co-op Dungeon.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ClassData = require(Shared:WaitForChild("ClassData") :: ModuleScript)
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)

local servicesFolder = script.Parent
local CardService = require(servicesFolder:WaitForChild("CardService") :: ModuleScript)
local PersistenceService = require(servicesFolder:WaitForChild("PersistenceService") :: ModuleScript)

local ClassService = {}

-- Transient combat gimmick counters per player
type GimmickTracker = {
	ComboCount: number,
	OverloadCharges: number,
	SoulTokens: number,
	BoneServants: number,
	ScrapParts: number,
	ActiveTurrets: number,
	TotalSacrificedHP: number,
	WolfHP: number,
	WolfAttack: number,
}

local playerGimmicks: { [number]: GimmickTracker } = {}

local function getGimmickTracker(userId: number): GimmickTracker
	if not playerGimmicks[userId] then
		playerGimmicks[userId] = {
			ComboCount = 0,
			OverloadCharges = 0,
			SoulTokens = 0,
			BoneServants = 0,
			ScrapParts = 0,
			ActiveTurrets = 0,
			TotalSacrificedHP = 0,
			WolfHP = 40,
			WolfAttack = 6,
		}
	end
	return playerGimmicks[userId]
end

function ClassService.resetGimmicks(userId: number)
	playerGimmicks[userId] = {
		ComboCount = 0,
		OverloadCharges = 0,
		SoulTokens = 0,
		BoneServants = 0,
		ScrapParts = 0,
		ActiveTurrets = 0,
		TotalSacrificedHP = 0,
		WolfHP = 40,
		WolfAttack = 6,
	}
end

-- Validates and updates a player's class & subclass
function ClassService.selectClass(player: Player, playerState: StateTypes.PlayerState, classId: string, subclassId: string): boolean
	local heroClass = ClassData.getClass(classId)
	if not heroClass then
		warn("[ClassService] Unknown class: " .. tostring(classId))
		return false
	end

	local subclass = ClassData.getSubclass(classId, subclassId)
	if not subclass then
		warn("[ClassService] Unknown subclass: " .. tostring(subclassId))
		return false
	end

	-- Verify unlock in profile
	if not PersistenceService.isClassUnlocked(player, classId) then
		warn(string.format("[ClassService] Player %s has not unlocked class %s", player.Name, classId))
		return false
	end

	playerState.ClassId = classId
	playerState.SubclassId = subclassId
	ClassService.applyClassToPlayer(playerState)
	return true
end

-- Applies hero class base stats and creates initial starting deck as CardInstances
function ClassService.applyClassToPlayer(playerState: StateTypes.PlayerState)
	local heroClass = ClassData.getClass(playerState.ClassId) or ClassData.getClass("Warlord") :: ClassData.HeroClass
	local subclass = ClassData.getSubclass(playerState.ClassId, playerState.SubclassId)

	local maxHp = heroClass.MaxHp
	if subclass and subclass.Id == "Titan" then
		maxHp += 10
	end

	playerState.Resources.MaxHP = maxHp
	playerState.Resources.HP = maxHp
	playerState.Resources.MaxEnergy = heroClass.StartingEnergy
	playerState.Resources.Energy = heroClass.StartingEnergy
	playerState.Resources.Shield = (subclass and subclass.Id == "Titan") and 10 or 0

	-- Generate runtime CardInstances for starting deck
	table.clear(playerState.Deck)
	table.clear(playerState.Hand)
	table.clear(playerState.DiscardPile)
	table.clear(playerState.ExhaustPile)

	for _, cardDefId in heroClass.StartingDeck do
		local inst = CardService.createCardInstance(cardDefId, playerState.UserId)
		if inst then
			table.insert(playerState.Deck, inst)
		end
	end

	ClassService.resetGimmicks(playerState.UserId)
end

-- Evaluates class-specific active gimmicks when playing a card
function ClassService.processGimmickOnCardPlay(
	playerState: StateTypes.PlayerState,
	cardInst: StateTypes.CardInstance,
	targetEnemy: StateTypes.EnemyState?
): { BonusDamage: number, BonusShield: number, FreeEnergy: boolean, PoisonApplied: number }
	local result = {
		BonusDamage = 0,
		BonusShield = 0,
		FreeEnergy = false,
		PoisonApplied = 0,
	}

	local tracker = getGimmickTracker(playerState.UserId)
	local isAttack = false
	for _, eff in cardInst.CardData.Effects do
		if eff.Type == "Damage" then
			isAttack = true
			break
		end
	end

	-- 1. Warlord Rage
	if playerState.ClassId == "Warlord" and isAttack then
		local missingRatio = math.clamp((playerState.Resources.MaxHP - playerState.Resources.HP) / playerState.Resources.MaxHP, 0, 1)
		result.BonusDamage += math.floor(missingRatio * 10)
		if playerState.SubclassId == "Berserker" and playerState.Resources.HP < (playerState.Resources.MaxHP * 0.5) then
			result.BonusDamage += 4
		end

	-- 2. Shadowblade Combo
	elseif playerState.ClassId == "Shadowblade" then
		tracker.ComboCount += 1
		if tracker.ComboCount > 1 then
			local bonus = (tracker.ComboCount - 1) * 2
			if isAttack then result.BonusDamage += bonus else result.BonusShield += bonus end
		end
		if playerState.SubclassId == "Assassin" and tracker.ComboCount == 3 and isAttack then
			result.BonusDamage += 10
		end
		if playerState.SubclassId == "Venomancer" then
			result.PoisonApplied += 1
		end

	-- 3. Blood Priest Sacrifice (Bypass energy cost with HP)
	elseif playerState.ClassId == "BloodPriest" then
		if playerState.Resources.Energy < cardInst.CardData.Cost then
			local missing = cardInst.CardData.Cost - playerState.Resources.Energy
			local hpCost = missing * 5
			if playerState.Resources.HP > hpCost then
				playerState.Resources.HP -= hpCost
				playerState.Resources.Energy = 0
				result.FreeEnergy = true
				result.BonusDamage += 3
				tracker.TotalSacrificedHP += hpCost
				if playerState.SubclassId == "Zealot" and playerState.Resources.HP < (playerState.Resources.MaxHP * 0.5) then
					result.BonusShield += 10
				end
				if playerState.SubclassId == "Inquisitor" and tracker.TotalSacrificedHP >= 15 then
					tracker.TotalSacrificedHP -= 15
					result.BonusDamage += 18
				end
			end
		end

	-- 4. Gambler Luck Rolls
	elseif playerState.ClassId == "Gambler" and isAttack then
		local rng = Random.new()
		local luckMult = rng:NextNumber(0.5, 1.75)
		local baseBonus = math.round(cardInst.CardData.Effects[1].Value * (luckMult - 1.0))
		result.BonusDamage += baseBonus
		if cardInst.CardData.Id == "CoinFlip" then
			local winChance = (playerState.SubclassId == "HighRoller") and 0.70 or 0.50
			if rng:NextNumber(0, 1) <= winChance then
				result.BonusDamage += 8
			end
		end
		if playerState.SubclassId == "CardSharp" and luckMult >= 1.65 then
			result.FreeEnergy = true
		end

	-- 5. Mechanist Gears
	elseif playerState.ClassId == "Mechanist" then
		tracker.ScrapParts += 1
		if tracker.ScrapParts >= 4 then
			tracker.ScrapParts -= 4
			tracker.ActiveTurrets += 1
		end
	end

	return result
end

-- Evaluates turn-end passive gimmicks (Overload, Turrets, Servants, Wolf)
function ClassService.processGimmickOnTurnEnd(
	playerState: StateTypes.PlayerState,
	enemies: { [string]: StateTypes.EnemyState }
): { EndTurnDamage: number, EndTurnShield: number, EndTurnHeal: number }
	local result = { EndTurnDamage = 0, EndTurnShield = 0, EndTurnHeal = 0 }
	local tracker = getGimmickTracker(playerState.UserId)

	-- 1. Aether Mage Overload
	if playerState.ClassId == "AetherMage" then
		local unspent = playerState.Resources.Energy
		if unspent > 0 then
			if playerState.SubclassId == "Pyromancer" then
				result.EndTurnDamage += unspent * 5
			elseif playerState.SubclassId == "Cryomancer" then
				result.EndTurnShield += unspent * 4
			end
		end

	-- 2. Mechanist Turrets
	elseif playerState.ClassId == "Mechanist" and tracker.ActiveTurrets > 0 then
		result.EndTurnDamage += tracker.ActiveTurrets * 6
		if playerState.SubclassId == "Artificer" then
			result.EndTurnShield += tracker.ActiveTurrets * 4
		end

	-- 3. Necrobinder Bone Servants
	elseif playerState.ClassId == "Necrobinder" and tracker.BoneServants > 0 then
		result.EndTurnDamage += tracker.BoneServants * 8

	-- 4. Beastmaster Wolf
	elseif playerState.ClassId == "Beastmaster" and tracker.WolfHP > 0 then
		result.EndTurnDamage += tracker.WolfAttack
	end

	-- Reset turn combo counter
	tracker.ComboCount = 0
	return result
end

-- Evaluates kill triggers (Necrobinder soul collection)
function ClassService.processGimmickOnKill(playerState: StateTypes.PlayerState)
	local tracker = getGimmickTracker(playerState.UserId)
	if playerState.ClassId == "Necrobinder" then
		local soulGain = (playerState.SubclassId == "Reaper") and 2 or 1
		tracker.SoulTokens += soulGain
		if playerState.SubclassId == "Reaper" then
			playerState.Resources.HP = math.min(playerState.Resources.MaxHP, playerState.Resources.HP + 6)
		end
		if tracker.SoulTokens >= 5 then
			tracker.SoulTokens -= 5
			local maxServants = (playerState.SubclassId == "SwarmLord") and 3 or 1
			if tracker.BoneServants < maxServants then
				tracker.BoneServants += 1
			end
		end
	end
end

function ClassService.init()
	print("[ClassService] Initialized class definition and combat gimmick engine.")
end

return ClassService
