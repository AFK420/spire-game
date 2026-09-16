--!strict

--[=[
	EffectResolver ModuleScript
	Mapped to: ServerScriptService.Server.services.EffectResolver
	Data-driven effect dispatcher with recursion depth protection.
	Dispatches and resolves all card, skill, and relic effects
	(Damage, Shield, Heal, Revive, ApplyStatus, RemoveStatus, Draw, GainEnergy, etc.)
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local CardData = require(Shared:WaitForChild("CardData") :: ModuleScript)
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)

local servicesFolder = script.Parent
local ModifierResolver = require(servicesFolder:WaitForChild("ModifierResolver") :: ModuleScript)
local DamagePipeline = require(servicesFolder:WaitForChild("DamagePipeline") :: ModuleScript)
local StatusService = require(servicesFolder:WaitForChild("StatusService") :: ModuleScript)
local CardService = require(servicesFolder:WaitForChild("CardService") :: ModuleScript)

local EffectResolver = {}

local MAX_RECURSION_DEPTH = 5
local currentDepth = 0

export type ActionContext = {
	SourcePlayer: StateTypes.PlayerState,
	Target: StateTypes.ResolvedTarget,
	CombatState: StateTypes.CombatState?,
	Party: { [number]: StateTypes.PlayerState }?,
	CardInstance: StateTypes.CardInstance?,
	Modifiers: { StateTypes.Modifier }?,
	LogEvent: ((eventType: string, sourceId: string, targetId: string, value: number?, text: string?) -> ())?,
	OnKillCallback: ((enemy: StateTypes.EnemyState) -> ())?,
	DidRevive: boolean?,
}

export type EffectExecutionResult = {
	Success: boolean,
	EffectType: string,
	Value: number?,
	Message: string?,
}

-- Evaluates a condition against action context
local function evaluateCondition(condition: string?, context: ActionContext): boolean
	if not condition or condition == "" then
		return true
	end

	if condition == "TargetDowned" then
		local p = context.Target.PlayerTarget
		return p ~= nil and p.IsDowned == true

	elseif condition == "TargetLiving" then
		local p = context.Target.PlayerTarget
		return p == nil or p.IsDowned ~= true

	elseif condition == "LowHP" then
		local p = context.Target.PlayerTarget or context.SourcePlayer
		return p.Resources.HP < (p.Resources.MaxHP * 0.5)
	end

	return true
end

--------------------------------------------------------------------------------
-- Effect Handlers Table
--------------------------------------------------------------------------------

type EffectHandler = (effect: CardData.Effect, context: ActionContext) -> EffectExecutionResult

local handlers: { [string]: EffectHandler } = {}

-- 1. Damage Effect
handlers["Damage"] = function(effect: CardData.Effect, context: ActionContext): EffectExecutionResult
	local rawVal = effect.Value or 0
	local enemy = context.Target.EnemyTarget
	if not enemy or enemy.HP <= 0 then
		return { Success = false, EffectType = "Damage", Message = "No living enemy target." }
	end

	local dmgCtx: StateTypes.DamageContext = {
		RawDamage = rawVal,
		DamageType = (effect.DamageType :: any) or "Physical",
		SourceId = tostring(context.SourcePlayer.UserId),
		SourceName = context.SourcePlayer.DisplayName,
		SourcePlayer = context.SourcePlayer,
		TargetEntityKind = "Enemy",
		TargetEnemy = enemy,
		TargetPlayer = nil,
		Tags = effect.Tags,
		Critical = false,
		CanHitShield = true,
		IsPeriodic = false,
	}

	local dmgResult = DamagePipeline.executeDamage(dmgCtx, context.Modifiers)

	if context.LogEvent then
		context.LogEvent(
			"DamageDealt",
			context.SourcePlayer.DisplayName,
			enemy.Name,
			dmgResult.FinalDamage,
			string.format("-%d HP", dmgResult.HPLost)
		)

		if enemy.HP <= 0 then
			context.LogEvent(
				"EnemyDefeated",
				context.SourcePlayer.DisplayName,
				enemy.Name,
				nil,
				string.format("%s was defeated!", enemy.Name)
			)
			if context.OnKillCallback then
				context.OnKillCallback(enemy)
			end
		end
	end

	return {
		Success = true,
		EffectType = "Damage",
		Value = dmgResult.FinalDamage,
		Message = string.format("Dealt %d damage.", dmgResult.FinalDamage),
	}
end

-- 2. Shield Effect
handlers["Shield"] = function(effect: CardData.Effect, context: ActionContext): EffectExecutionResult
	local rawVal = effect.Value or 0
	local finalShield = rawVal

	if context.Modifiers and #context.Modifiers > 0 then
		local modCtx = {
			SourcePlayer = context.SourcePlayer,
			PlayerTarget = context.Target.PlayerTarget,
			EnemyTarget = context.Target.EnemyTarget,
		}
		finalShield = ModifierResolver.resolve(rawVal, "Shield", context.Modifiers, modCtx)
	end

	local recipient = context.Target.PlayerTarget or context.SourcePlayer
	recipient.Resources.Shield += finalShield

	if context.LogEvent then
		context.LogEvent(
			"ShieldGained",
			context.SourcePlayer.DisplayName,
			recipient.DisplayName,
			finalShield,
			string.format("+%d Shield", finalShield)
		)
	end

	return {
		Success = true,
		EffectType = "Shield",
		Value = finalShield,
		Message = string.format("Gained %d Shield.", finalShield),
	}
end

-- 3. Heal Effect
handlers["Heal"] = function(effect: CardData.Effect, context: ActionContext): EffectExecutionResult
	local rawVal = effect.Value or 0
	local recipient = context.Target.PlayerTarget or context.SourcePlayer

	-- Prevent healing downed players, or healing a player that was just revived by this same action
	if context.DidRevive or recipient.IsDowned then
		return { Success = false, EffectType = "Heal", Message = "Cannot heal downed player." }
	end

	local finalHeal = rawVal
	if context.Modifiers and #context.Modifiers > 0 then
		local modCtx = {
			SourcePlayer = context.SourcePlayer,
			PlayerTarget = recipient,
		}
		finalHeal = ModifierResolver.resolve(rawVal, "Healing", context.Modifiers, modCtx)
	end

	local oldHp = recipient.Resources.HP
	recipient.Resources.HP = math.min(recipient.Resources.MaxHP, recipient.Resources.HP + finalHeal)
	local actualHealed = recipient.Resources.HP - oldHp

	if context.LogEvent then
		context.LogEvent(
			"Healed",
			context.SourcePlayer.DisplayName,
			recipient.DisplayName,
			finalHeal,
			string.format("+%d HP", finalHeal)
		)
	end

	return {
		Success = true,
		EffectType = "Heal",
		Value = actualHealed,
		Message = string.format("Healed %d HP.", actualHealed),
	}
end

-- 4. Revive Effect
handlers["Revive"] = function(effect: CardData.Effect, context: ActionContext): EffectExecutionResult
	local rawVal = effect.Value or 0
	local recipient = context.Target.PlayerTarget or context.SourcePlayer

	if not recipient.IsDowned then
		return { Success = false, EffectType = "Revive", Message = "Player is not downed." }
	end

	recipient.IsDowned = false
	recipient.Resources.HP = math.min(recipient.Resources.MaxHP, rawVal)
	context.DidRevive = true

	if context.LogEvent then
		context.LogEvent(
			"PlayerRevived",
			context.SourcePlayer.DisplayName,
			recipient.DisplayName,
			rawVal,
			string.format("%s was revived with %d HP!", recipient.DisplayName, recipient.Resources.HP)
		)
	end

	return {
		Success = true,
		EffectType = "Revive",
		Value = recipient.Resources.HP,
		Message = string.format("Revived with %d HP.", recipient.Resources.HP),
	}
end

-- 5. ApplyStatus Effect
handlers["ApplyStatus"] = function(effect: CardData.Effect, context: ActionContext): EffectExecutionResult
	local statusId = effect.StatusId or "Poison"
	local stacks = effect.Stacks or effect.Value or 1
	local duration = effect.Duration

	local targetEntity = context.Target.EnemyTarget or context.Target.PlayerTarget
	local targetId = context.Target.TargetId
	local targetName = context.Target.TargetName

	if not targetEntity or targetId == "" then
		return { Success = false, EffectType = "ApplyStatus", Message = "Invalid target for status." }
	end

	StatusService.applyStatus(targetId, statusId, stacks, duration, tostring(context.SourcePlayer.UserId), targetEntity)

	if context.LogEvent then
		local eventName = (statusId == "Poison") and "PoisonApplied" or "StatusApplied"
		context.LogEvent(
			eventName,
			context.SourcePlayer.DisplayName,
			targetName,
			stacks,
			string.format("+%d %s", stacks, statusId)
		)
	end

	return {
		Success = true,
		EffectType = "ApplyStatus",
		Value = stacks,
		Message = string.format("Applied %d stacks of %s.", stacks, statusId),
	}
end

-- Backward compatibility alias: "Poison"
handlers["Poison"] = function(effect: CardData.Effect, context: ActionContext): EffectExecutionResult
	local copy: CardData.Effect = {
		Type = "ApplyStatus",
		StatusId = "Poison",
		Stacks = effect.Value or 1,
		Value = effect.Value,
		Duration = -1,
	}
	return handlers["ApplyStatus"](copy, context)
end

-- 6. RemoveStatus Effect
handlers["RemoveStatus"] = function(effect: CardData.Effect, context: ActionContext): EffectExecutionResult
	local statusId = effect.StatusId or "Poison"
	local targetEntity = context.Target.EnemyTarget or context.Target.PlayerTarget
	local targetId = context.Target.TargetId

	if not targetEntity or targetId == "" then
		return { Success = false, EffectType = "RemoveStatus", Message = "Invalid target." }
	end

	local removed = StatusService.removeStatus(targetId, statusId, targetEntity)
	return {
		Success = removed,
		EffectType = "RemoveStatus",
		Message = removed and string.format("Removed status %s.", statusId) or "Status was not present.",
	}
end

-- 7. Draw Effect
handlers["Draw"] = function(effect: CardData.Effect, context: ActionContext): EffectExecutionResult
	local count = effect.Value or 1
	CardService.drawCards(context.SourcePlayer, count)

	return {
		Success = true,
		EffectType = "Draw",
		Value = count,
		Message = string.format("Drew %d cards.", count),
	}
end

-- 8. Discard Effect
handlers["Discard"] = function(effect: CardData.Effect, context: ActionContext): EffectExecutionResult
	CardService.discardHand(context.SourcePlayer)
	return {
		Success = true,
		EffectType = "Discard",
		Message = "Discarded hand.",
	}
end

-- 9. Exhaust Effect
handlers["Exhaust"] = function(effect: CardData.Effect, context: ActionContext): EffectExecutionResult
	if context.CardInstance then
		table.insert(context.SourcePlayer.ExhaustPile, context.CardInstance)
	end
	return {
		Success = true,
		EffectType = "Exhaust",
		Message = "Exhausted card.",
	}
end

-- 10. GainEnergy Effect
handlers["GainEnergy"] = function(effect: CardData.Effect, context: ActionContext): EffectExecutionResult
	local count = effect.Value or 1
	context.SourcePlayer.Resources.Energy = math.min(
		context.SourcePlayer.Resources.MaxEnergy,
		context.SourcePlayer.Resources.Energy + count
	)
	return {
		Success = true,
		EffectType = "GainEnergy",
		Value = count,
		Message = string.format("Gained %d Energy.", count),
	}
end

-- 11. LoseEnergy Effect
handlers["LoseEnergy"] = function(effect: CardData.Effect, context: ActionContext): EffectExecutionResult
	local count = effect.Value or 1
	context.SourcePlayer.Resources.Energy = math.max(0, context.SourcePlayer.Resources.Energy - count)
	return {
		Success = true,
		EffectType = "LoseEnergy",
		Value = count,
		Message = string.format("Lost %d Energy.", count),
	}
end

-- 12. CreateCard Effect
handlers["CreateCard"] = function(effect: CardData.Effect, context: ActionContext): EffectExecutionResult
	local cardDefId = effect.CardDefId or effect.StatusId or "Strike"
	local inst = CardService.createCardInstance(cardDefId, context.SourcePlayer.UserId)
	if inst then
		table.insert(context.SourcePlayer.Deck, inst)
	end
	return {
		Success = true,
		EffectType = "CreateCard",
		Message = string.format("Created card %s.", cardDefId),
	}
end

-- 13. ModifyResource Effect
handlers["ModifyResource"] = function(effect: CardData.Effect, context: ActionContext): EffectExecutionResult
	local count = effect.Value or 0
	context.SourcePlayer.Gold = math.max(0, context.SourcePlayer.Gold + count)
	return {
		Success = true,
		EffectType = "ModifyResource",
		Value = count,
		Message = string.format("Modified resource by %d.", count),
	}
end

-- 14. TriggerEvent Effect
handlers["TriggerEvent"] = function(effect: CardData.Effect, context: ActionContext): EffectExecutionResult
	if context.LogEvent then
		context.LogEvent("CustomEvent", context.SourcePlayer.DisplayName, context.Target.TargetName, effect.Value, effect.StatusId)
	end
	return {
		Success = true,
		EffectType = "TriggerEvent",
		Message = "Custom event triggered.",
	}
end

--------------------------------------------------------------------------------
-- Public Dispatcher
--------------------------------------------------------------------------------

-- Resolves an array of card/action effects against the given context
function EffectResolver.resolveEffects(effects: { CardData.Effect }, context: ActionContext): { EffectExecutionResult }
	if currentDepth >= MAX_RECURSION_DEPTH then
		warn("[EffectResolver] Exceeded maximum recursion depth of " .. tostring(MAX_RECURSION_DEPTH))
		return {}
	end

	currentDepth += 1
	local results: { EffectExecutionResult } = {}

	for _, effect in effects do
		-- Check condition
		if evaluateCondition(effect.Condition, context) then
			local handler = handlers[effect.Type]
			if handler then
				local res = handler(effect, context)
				table.insert(results, res)
			else
				warn("[EffectResolver] No handler registered for effect type: " .. tostring(effect.Type))
			end
		end
	end

	currentDepth -= 1
	return results
end

function EffectResolver.init()
	print("[EffectResolver] Initialized data-driven effect resolution dispatcher.")
end

return EffectResolver
