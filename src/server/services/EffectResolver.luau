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
local TargetResolver = require(servicesFolder:WaitForChild("TargetResolver") :: ModuleScript)
local RelicService = require(servicesFolder:WaitForChild("RelicService") :: ModuleScript)

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

-- Resolves target for an individual effect if specified, otherwise falls back to context.Target
local function resolveEffectTarget(effect: CardData.Effect, context: ActionContext): StateTypes.ResolvedTarget
	if not effect.Target then
		return context.Target
	end

	local targetParam: any = nil
	if effect.Target == "Self" then
		targetParam = context.SourcePlayer.UserId
	elseif effect.Target == "Enemy" then
		if context.Target and context.Target.EnemyTarget then
			targetParam = context.Target.EnemyTarget.InstanceId
		end
	elseif effect.Target == "Ally" then
		if context.Target and context.Target.PlayerTarget then
			targetParam = context.Target.PlayerTarget.UserId
		else
			targetParam = context.SourcePlayer.UserId
		end
	end

	local combatState = context.CombatState or ({
		CombatId = "dummy",
		Phase = "PlayerPhase",
		TurnNumber = 1,
		TurnStartTime = 0,
		TurnDuration = 45,
		Participants = { context.SourcePlayer.UserId },
		Enemies = (context.Target and context.Target.EnemyTarget) and { [context.Target.EnemyTarget.InstanceId] = context.Target.EnemyTarget } or {},
		ReadyPlayers = {},
		CombatLog = {},
	} :: StateTypes.CombatState)

	local party = context.Party or {
		[context.SourcePlayer.UserId] = context.SourcePlayer,
	}
	if context.Target and context.Target.PlayerTarget then
		party[context.Target.PlayerTarget.UserId] = context.Target.PlayerTarget
	end

	return TargetResolver.resolveTarget(
		context.SourcePlayer,
		effect.Target,
		targetParam,
		combatState,
		party
	)
end

-- Evaluates a condition against action context
local function evaluateCondition(condition: string?, context: ActionContext, resolvedTarget: StateTypes.ResolvedTarget?): boolean
	if not condition or condition == "" then
		return true
	end

	local t = resolvedTarget or context.Target

	if condition == "TargetDowned" then
		local p = t.PlayerTarget
		return p ~= nil and p.IsDowned == true

	elseif condition == "TargetLiving" then
		local p = t.PlayerTarget
		return p == nil or p.IsDowned ~= true

	elseif condition == "LowHP" then
		local p = t.PlayerTarget or context.SourcePlayer
		return p.Resources.HP < (p.Resources.MaxHP * 0.5)
	end

	return true
end

--------------------------------------------------------------------------------
-- Effect Handlers Table
--------------------------------------------------------------------------------

type EffectHandler = (effect: CardData.Effect, context: ActionContext, resolvedTarget: StateTypes.ResolvedTarget) -> EffectExecutionResult

local handlers: { [string]: EffectHandler } = {}

-- 1. Damage Effect
handlers["Damage"] = function(effect: CardData.Effect, context: ActionContext, resolvedTarget: StateTypes.ResolvedTarget): EffectExecutionResult
	local rawVal = effect.Value or 0
	local enemy = resolvedTarget.EnemyTarget
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
handlers["Shield"] = function(effect: CardData.Effect, context: ActionContext, resolvedTarget: StateTypes.ResolvedTarget): EffectExecutionResult
	local rawVal = effect.Value or 0
	local finalShield = rawVal

	if context.Modifiers and #context.Modifiers > 0 then
		local modCtx = {
			SourcePlayer = context.SourcePlayer,
			PlayerTarget = resolvedTarget.PlayerTarget,
			EnemyTarget = resolvedTarget.EnemyTarget,
		}
		finalShield = ModifierResolver.resolve(rawVal, "Shield", context.Modifiers, modCtx)
	end

	local recipient = resolvedTarget.PlayerTarget or (resolvedTarget.TargetKind == "None" and context.SourcePlayer) or context.SourcePlayer
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
handlers["Heal"] = function(effect: CardData.Effect, context: ActionContext, resolvedTarget: StateTypes.ResolvedTarget): EffectExecutionResult
	local rawVal = effect.Value or 0
	local recipient = resolvedTarget.PlayerTarget or context.SourcePlayer

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
handlers["Revive"] = function(effect: CardData.Effect, context: ActionContext, resolvedTarget: StateTypes.ResolvedTarget): EffectExecutionResult
	local rawVal = effect.Value or 0
	local recipient = resolvedTarget.PlayerTarget or context.SourcePlayer

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
handlers["ApplyStatus"] = function(effect: CardData.Effect, context: ActionContext, resolvedTarget: StateTypes.ResolvedTarget): EffectExecutionResult
	local statusId = effect.StatusId or "Poison"
	local stacks = effect.Stacks or effect.Value or 1
	local duration = effect.Duration

	local targetEntity = resolvedTarget.EnemyTarget or resolvedTarget.PlayerTarget
	local targetId = resolvedTarget.TargetId
	local targetName = resolvedTarget.TargetName

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
handlers["Poison"] = function(effect: CardData.Effect, context: ActionContext, resolvedTarget: StateTypes.ResolvedTarget): EffectExecutionResult
	local copy: CardData.Effect = {
		Type = "ApplyStatus",
		StatusId = "Poison",
		Stacks = effect.Value or 1,
		Value = effect.Value,
		Duration = -1,
		Target = effect.Target,
	}
	return handlers["ApplyStatus"](copy, context, resolvedTarget)
end

-- 6. RemoveStatus Effect
handlers["RemoveStatus"] = function(effect: CardData.Effect, context: ActionContext, resolvedTarget: StateTypes.ResolvedTarget): EffectExecutionResult
	local statusId = effect.StatusId or "Poison"
	local targetEntity = resolvedTarget.EnemyTarget or resolvedTarget.PlayerTarget
	local targetId = resolvedTarget.TargetId

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
handlers["Draw"] = function(effect: CardData.Effect, context: ActionContext, _resolvedTarget: StateTypes.ResolvedTarget): EffectExecutionResult
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
handlers["Discard"] = function(effect: CardData.Effect, context: ActionContext, _resolvedTarget: StateTypes.ResolvedTarget): EffectExecutionResult
	CardService.discardHand(context.SourcePlayer)
	return {
		Success = true,
		EffectType = "Discard",
		Message = "Discarded hand.",
	}
end

-- 9. Exhaust Effect
handlers["Exhaust"] = function(effect: CardData.Effect, context: ActionContext, _resolvedTarget: StateTypes.ResolvedTarget): EffectExecutionResult
	if context.CardInstance then
		local exhausted = CardService.exhaustCard(context.SourcePlayer, context.CardInstance.InstanceId)
		if exhausted then
			if context.LogEvent then
				context.LogEvent(
					"CardExhausted",
					context.SourcePlayer.DisplayName,
					context.SourcePlayer.DisplayName,
					nil,
					string.format("%s exhausted.", context.CardInstance.CardDefId)
				)
			end
			return {
				Success = true,
				EffectType = "Exhaust",
				Message = string.format("Exhausted card %s.", context.CardInstance.CardDefId),
			}
		end
	end
	return {
		Success = false,
		EffectType = "Exhaust",
		Message = "Failed to exhaust card: card not found.",
	}
end

-- 10. GainEnergy Effect
handlers["GainEnergy"] = function(effect: CardData.Effect, context: ActionContext, resolvedTarget: StateTypes.ResolvedTarget): EffectExecutionResult
	local recipient = (resolvedTarget.Success and resolvedTarget.PlayerTarget) or context.SourcePlayer
	local count = effect.Value or 1
	recipient.Resources.Energy = math.min(
		recipient.Resources.MaxEnergy,
		recipient.Resources.Energy + count
	)
	return {
		Success = true,
		EffectType = "GainEnergy",
		Value = count,
		Message = string.format("Gained %d Energy.", count),
	}
end

-- 11. LoseEnergy Effect
handlers["LoseEnergy"] = function(effect: CardData.Effect, context: ActionContext, resolvedTarget: StateTypes.ResolvedTarget): EffectExecutionResult
	local recipient = (resolvedTarget.Success and resolvedTarget.PlayerTarget) or context.SourcePlayer
	local count = effect.Value or 1
	recipient.Resources.Energy = math.max(0, recipient.Resources.Energy - count)
	return {
		Success = true,
		EffectType = "LoseEnergy",
		Value = count,
		Message = string.format("Lost %d Energy.", count),
	}
end

-- 12. CreateCard Effect
handlers["CreateCard"] = function(effect: CardData.Effect, context: ActionContext, _resolvedTarget: StateTypes.ResolvedTarget): EffectExecutionResult
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
handlers["ModifyResource"] = function(effect: CardData.Effect, context: ActionContext, resolvedTarget: StateTypes.ResolvedTarget): EffectExecutionResult
	if not resolvedTarget.Success or resolvedTarget.TargetKind ~= "Player" or not resolvedTarget.PlayerTarget then
		return {
			Success = false,
			EffectType = "ModifyResource",
			Message = resolvedTarget.Error or "ModifyResource requires a valid Player target.",
		}
	end

	local count = effect.Value or 0
	local resType: StateTypes.ResourceType? = effect.Resource

	if not resType then
		-- Default to Gold for backward compatibility with numeric-value cards
		resType = "Gold"
	end

	local recipient = resolvedTarget.PlayerTarget

	if resType == "HP" then
		if recipient.IsDowned and count > 0 then
			return { Success = false, EffectType = "ModifyResource", Message = "Cannot modify HP of downed player." }
		end
		recipient.Resources.HP = math.clamp(recipient.Resources.HP + count, 0, recipient.Resources.MaxHP)
		if recipient.Resources.HP <= 0 then
			recipient.IsDowned = true
		end
	elseif resType == "MaxHP" then
		recipient.Resources.MaxHP = math.max(1, recipient.Resources.MaxHP + count)
		recipient.Resources.HP = math.clamp(recipient.Resources.HP, 0, recipient.Resources.MaxHP)
	elseif resType == "Shield" then
		recipient.Resources.Shield = math.max(0, recipient.Resources.Shield + count)
	elseif resType == "Energy" then
		recipient.Resources.Energy = math.clamp(
			recipient.Resources.Energy + count,
			0,
			recipient.Resources.MaxEnergy
		)
	elseif resType == "MaxEnergy" then
		recipient.Resources.MaxEnergy = math.max(0, recipient.Resources.MaxEnergy + count)
		recipient.Resources.Energy = math.clamp(
			recipient.Resources.Energy,
			0,
			recipient.Resources.MaxEnergy
		)
	elseif resType == "Gold" then
		recipient.Gold = math.max(0, recipient.Gold + count)
	else
		return {
			Success = false,
			EffectType = "ModifyResource",
			Message = "Invalid or unsupported resource type: " .. tostring(resType),
		}
	end

	if context.LogEvent then
		context.LogEvent(
			"ResourceModified",
			context.SourcePlayer.DisplayName,
			recipient.DisplayName,
			count,
			string.format("%s %+d (%s)", resType, count, recipient.DisplayName)
		)
	end

	return {
		Success = true,
		EffectType = "ModifyResource",
		Value = count,
		Message = string.format("Modified %s by %d on %s.", resType, count, recipient.DisplayName),
	}
end

-- 14. TriggerEvent Effect
handlers["TriggerEvent"] = function(effect: CardData.Effect, context: ActionContext, resolvedTarget: StateTypes.ResolvedTarget): EffectExecutionResult
	local eventId = effect.EventId or effect.StatusId
	if not eventId or eventId == "" or typeof(eventId) ~= "string" then
		return {
			Success = false,
			EffectType = "TriggerEvent",
			Message = "Missing or invalid EventId for TriggerEvent.",
		}
	end

	local combatContext: StateTypes.CombatEventContext = {
		Event = eventId,
		CombatState = context.CombatState,
		SourcePlayer = context.SourcePlayer,
		Enemy = resolvedTarget.EnemyTarget,
		Card = context.CardInstance,
		Value = effect.Value,
		TargetPlayer = resolvedTarget.PlayerTarget,
	}

	local ok, err = pcall(function()
		RelicService.triggerRelics(context.SourcePlayer, eventId :: any, context.CombatState, combatContext)
	end)

	if not ok then
		warn(string.format("[EffectResolver] TriggerEvent dispatch failed for event '%s': %s", eventId, tostring(err)))
		return {
			Success = false,
			EffectType = "TriggerEvent",
			Value = effect.Value,
			Message = string.format("Event dispatch failed for '%s': %s", eventId, tostring(err)),
		}
	end

	if context.LogEvent then
		context.LogEvent("CustomEvent", context.SourcePlayer.DisplayName, resolvedTarget.TargetName, effect.Value, eventId)
	end

	return {
		Success = true,
		EffectType = "TriggerEvent",
		Value = effect.Value,
		Message = string.format("Triggered event %s.", eventId),
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

	local ok, err = pcall(function()
		for _, effect in effects do
			local resolvedTarget = resolveEffectTarget(effect, context)
			if evaluateCondition(effect.Condition, context, resolvedTarget) then
				local handler = handlers[effect.Type]
				if handler then
					local res = handler(effect, context, resolvedTarget)
					table.insert(results, res)
				else
					warn("[EffectResolver] No handler registered for effect type: " .. tostring(effect.Type))
				end
			end
		end
	end)

	currentDepth -= 1
	if not ok then
		warn("[EffectResolver] Error during effect resolution: " .. tostring(err))
	end

	return results
end

function EffectResolver.init()
	print("[EffectResolver] Initialized data-driven effect resolution dispatcher.")
end

return EffectResolver
