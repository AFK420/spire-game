--!strict

--[=[
	RelicService ModuleScript
	Mapped to: ServerScriptService.Server.services.RelicService
	Manages passive relic inventories and event-driven combat triggers
	operating against the canonical PlayerState and CombatState.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RelicData = require(Shared:WaitForChild("RelicData") :: ModuleScript)
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)

local servicesFolder = script.Parent
local NetworkService = require(servicesFolder:WaitForChild("NetworkService") :: ModuleScript)

local RelicService = {}

type RelicCombatState = {
	AttacksPlayedThisCombat: number,
	FirstAttackUsed: boolean,
	CentennialTriggered: boolean,
	PendingBonusDraw: number,
}

local relicCombatStates: { [number]: RelicCombatState } = {}

local function getCombatState(userId: number): RelicCombatState
	if not relicCombatStates[userId] then
		relicCombatStates[userId] = {
			AttacksPlayedThisCombat = 0,
			FirstAttackUsed = false,
			CentennialTriggered = false,
			PendingBonusDraw = 0,
		}
	end
	return relicCombatStates[userId]
end

function RelicService.resetCombatState(userId: number)
	relicCombatStates[userId] = {
		AttacksPlayedThisCombat = 0,
		FirstAttackUsed = false,
		CentennialTriggered = false,
		PendingBonusDraw = 0,
	}
end

function RelicService.hasRelic(playerState: StateTypes.PlayerState, relicId: string): boolean
	for _, id in playerState.RelicIds do
		if id == relicId then
			return true
		end
	end
	return false
end

function RelicService.addRelic(playerState: StateTypes.PlayerState, relicId: string): boolean
	local relicDef = RelicData.getRelic(relicId)
	if not relicDef then return false end

	if RelicService.hasRelic(playerState, relicId) then
		return false
	end

	table.insert(playerState.RelicIds, relicId)
	if playerState.PlayerInstance then
		NetworkService.notifyRelicTrigger(playerState.PlayerInstance, {
			RelicId = relicDef.Id,
			RelicName = relicDef.Name,
			Icon = relicDef.Icon or "✨",
			Text = "Acquired relic!",
			Rarity = relicDef.Rarity,
		})
	end
	return true
end

-- Evaluates event-driven triggers for a player against active combat state
function RelicService.triggerEvent(
	playerState: StateTypes.PlayerState,
	combatState: StateTypes.CombatState?,
	triggerType: RelicData.RelicTrigger,
	context: { Card: StateTypes.CardInstance?, Damage: number?, Enemy: StateTypes.EnemyState?, UnspentEnergy: number? }?
): { BonusDamage: number, BonusShield: number, BonusEnergy: number, BonusDraw: number, RetainShield: boolean }
	local result = {
		BonusDamage = 0,
		BonusShield = 0,
		BonusEnergy = 0,
		BonusDraw = 0,
		RetainShield = false,
	}

	local cState = getCombatState(playerState.UserId)

	if triggerType == "OnTurnStart" and cState.PendingBonusDraw > 0 then
		result.BonusDraw += cState.PendingBonusDraw
		cState.PendingBonusDraw = 0
	end

	for _, relicId in playerState.RelicIds do
		local relic = RelicData.getRelic(relicId)
		if relic and relic.Trigger == triggerType then
			local id = relic.Id

			if triggerType == "OnCombatStart" then
				if id == "Anchor" then
					playerState.Resources.Shield += relic.Value
				elseif id == "BloodVial" or id == "BurningBlood" then
					playerState.Resources.HP = math.min(playerState.Resources.MaxHP, playerState.Resources.HP + relic.Value)
				elseif id == "VenomVial" and context and context.Enemy then
					context.Enemy.Poison += relic.Value
				elseif id == "MeatOnTheBone" and playerState.Resources.HP < (playerState.Resources.MaxHP * 0.5) then
					playerState.Resources.HP = math.min(playerState.Resources.MaxHP, playerState.Resources.HP + relic.Value)
				end

			elseif triggerType == "OnTurnStart" then
				if id == "Lantern" and combatState and combatState.TurnNumber == 1 then
					result.BonusEnergy += relic.Value
				elseif id == "CoffeeDripper" then
					result.BonusEnergy += relic.Value
				end

			elseif triggerType == "OnCardPlay" then
				local card = context and context.Card
				local isAttack = false
				if card then
					for _, eff in card.CardData.Effects do
						if eff.Type == "Damage" then isAttack = true break end
					end
				end

				if isAttack and RelicService.hasRelic(playerState, "Vajra") then
					result.BonusDamage += 2
				end
				if isAttack and id == "Akabeko" and not cState.FirstAttackUsed then
					cState.FirstAttackUsed = true
					result.BonusDamage += relic.Value
				end
				if isAttack and id == "Sundial" then
					cState.AttacksPlayedThisCombat += 1
					if cState.AttacksPlayedThisCombat % 3 == 0 then
						result.BonusEnergy += relic.Value
					end
				end

			elseif triggerType == "OnTurnEnd" then
				if id == "Pocketwatch" and context and context.UnspentEnergy and context.UnspentEnergy > 0 then
					cState.PendingBonusDraw += relic.Value
				elseif id == "Orichalcum" and playerState.Resources.Shield == 0 then
					playerState.Resources.Shield += relic.Value
				elseif id == "Calipers" then
					result.RetainShield = true
				end

			elseif triggerType == "OnDamageTaken" then
				if id == "BronzeScales" and context and context.Enemy then
					context.Enemy.HP = math.max(0, context.Enemy.HP - relic.Value)
				elseif id == "CentennialPuzzle" and not cState.CentennialTriggered then
					cState.CentennialTriggered = true
					result.BonusDraw += relic.Value
				end

			elseif triggerType == "OnKill" then
				if id == "GremlinHorn" then
					result.BonusEnergy += relic.Value
					result.BonusDraw += relic.Value
				end
			end

			-- Fire client animation notification
			if playerState.PlayerInstance then
				NetworkService.notifyRelicTrigger(playerState.PlayerInstance, {
					RelicId = relic.Id,
					RelicName = relic.Name,
					Icon = relic.Icon or "✨",
					Text = relic.Description,
					Rarity = relic.Rarity,
				})
			end
		end
	end

	return result
end

function RelicService.init()
	print("[RelicService] Initialized canonical relic modifier engine.")
end

return RelicService
