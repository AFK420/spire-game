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
	GuaranteedCritical: boolean?,
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
		end
	end

	return TargetResolver.resolveTarget(
		context.SourcePlayer,
		effect.Target,
		targetParam,
		context.CombatState,
		context.Party
	)
end

-- Evaluates a condition against action context
-- Returns (isSatisfied: boolean, isValid: boolean, errorMsg: string?)
function EffectResolver.evaluateCondition(
	conditionOrDef: any,
	contextOrSource: any?,
	resolvedTargetOrTarget: any?,
	_combatState: any?
): (boolean, boolean, string?)
	local conditionStr: string? = nil
	if typeof(conditionOrDef) == "table" and conditionOrDef ~= nil then
		conditionStr = conditionOrDef.Condition
	elseif typeof(conditionOrDef) == "string" then
		conditionStr = conditionOrDef
	elseif conditionOrDef == nil then
		return true, true, nil
	end

	if not conditionStr or conditionStr == "" then
		return true, true, nil
	end

	-- Determine target player or fallback
	local targetPlayer: StateTypes.PlayerState? = nil
	if typeof(resolvedTargetOrTarget) == "table" and resolvedTargetOrTarget ~= nil then
		if resolvedTargetOrTarget.PlayerTarget then
			targetPlayer = resolvedTargetOrTarget.PlayerTarget
		elseif resolvedTargetOrTarget.UserId and resolvedTargetOrTarget.Resources then
			targetPlayer = resolvedTargetOrTarget
		end
	end

	if not targetPlayer and typeof(contextOrSource) == "table" and contextOrSource ~= nil then
		if contextOrSource.Target and contextOrSource.Target.PlayerTarget then
			targetPlayer = contextOrSource.Target.PlayerTarget
		elseif contextOrSource.PlayerTarget then
			targetPlayer = contextOrSource.PlayerTarget
		elseif contextOrSource.UserId and contextOrSource.Resources then
			targetPlayer = contextOrSource
		end
	end

	if conditionStr == "TargetDowned" then
		return (targetPlayer ~= nil and targetPlayer.IsDowned == true), true, nil
	elseif conditionStr == "TargetLiving" then
		return (targetPlayer == nil or targetPlayer.IsDowned ~= true), true, nil
	elseif conditionStr == "LowHP" then
		local p = targetPlayer
		if not p and typeof(contextOrSource) == "table" and contextOrSource ~= nil then
			p = contextOrSource.SourcePlayer or contextOrSource
		end
		if p and p.Resources then
			return (p.Resources.HP < (p.Resources.MaxHP * 0.5)), true, nil
		end
		return false, true, nil
	end

	-- Fail closed on unknown conditions
	local msg = string.format("Unknown condition '%s'. Failing closed.", tostring(conditionStr))
	warn("[EffectResolver] " .. msg)
	return false, false, msg
end

--------------------------------------------------------------------------------
-- Effect Handlers Table
--------------------------------------------------------------------------------

type EffectHandler = (effect: CardData.Effect, context: ActionContext, resolvedTarget: StateTypes.ResolvedTarget) -> EffectExecutionResult

local handlers: { [string]: EffectHandler } = {}

-- 1. Damage Effect
handlers["Damage"] = function(effect: CardData.Effect, context: ActionContext, resolvedTarget: StateTypes.ResolvedTarget): EffectExecutionResult
	if not resolvedTarget.Success or resolvedTarget.TargetKind ~= "Enemy" or not resolvedTarget.EnemyTarget then
		return {
			Success = false,
			EffectType = "Damage",
			Message = resolvedTarget.Error or "Invalid target: Damage requires a living Enemy target.",
		}
	end

	local enemy = resolvedTarget.EnemyTarget
	if enemy.HP <= 0 then
		return { Success = false, EffectType = "Damage", Message = "No living enemy target." }
	end

	local rawVal = effect.Value or 0
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
		Critical = if context.GuaranteedCritical then true else nil,
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

		if dmgResult.IsDefeatedOrDowned and not (enemy :: any)._killTriggered then
			(enemy :: any)._killTriggered = true
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
	if not resolvedTarget.Success or resolvedTarget.TargetKind ~= "Player" or not resolvedTarget.PlayerTarget then
		return {
			Success = false,
			EffectType = "Shield",
			Message = resolvedTarget.Error or "Invalid target: Shield requires a valid Player target.",
		}
	end

	local recipient = resolvedTarget.PlayerTarget
	local rawVal = effect.Value or 0
	local finalShield = rawVal

	if context.Modifiers and #context.Modifiers > 0 then
		local modCtx = {
			SourcePlayer = context.SourcePlayer,
			PlayerTarget = recipient,
			EnemyTarget = resolvedTarget.EnemyTarget,
		}
		local baseShield = ModifierResolver.resolve(rawVal, "Shield", context.Modifiers, modCtx)
		local bonusShieldGain = ModifierResolver.resolve(0, "ShieldGain", context.Modifiers, modCtx)
		finalShield = baseShield + bonusShieldGain
	end

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
	if not resolvedTarget.Success or resolvedTarget.TargetKind ~= "Player" or not resolvedTarget.PlayerTarget then
		return {
			Success = false,
			EffectType = "Heal",
			Message = resolvedTarget.Error or "Invalid target: Heal requires a valid Player target.",
		}
	end

	local recipient = resolvedTarget.PlayerTarget

	-- Prevent healing downed players, or healing a player that was just revived by this same action
	if context.DidRevive or recipient.IsDowned then
		return { Success = false, EffectType = "Heal", Message = "Cannot heal downed player." }
	end

	local rawVal = effect.Value or 0
	local finalHeal = rawVal
	if context.Modifiers and #context.Modifiers > 0 then
		local modCtx = {
			SourcePlayer = context.SourcePlayer,
			PlayerTarget = recipient,
		}
		finalHeal = ModifierResolver.resolve(rawVal, "Healing", context.Modifiers, modCtx)
	end

	local envService = servicesFolder:FindFirstChild("EnvironmentService")
	if envService then
		local EnvironmentServiceModule = require(envService :: ModuleScript)
		local combatSvc = servicesFolder:FindFirstChild("CombatService")
		if combatSvc then
			local CombatServiceModule = require(combatSvc :: ModuleScript)
			local actCombat = CombatServiceModule.getActiveCombat()
			if actCombat and actCombat.Environment then
				finalHeal = EnvironmentServiceModule.modifyHealing(actCombat.Environment, finalHeal)
			end
		end
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
	if not resolvedTarget.Success or resolvedTarget.TargetKind ~= "Player" or not resolvedTarget.PlayerTarget then
		return {
			Success = false,
			EffectType = "Revive",
			Message = resolvedTarget.Error or "Invalid target: Revive requires a valid Player target.",
		}
	end

	local recipient = resolvedTarget.PlayerTarget

	if not recipient.IsDowned then
		return { Success = false, EffectType = "Revive", Message = "Player is not downed." }
	end

	local rawVal = effect.Value or 0
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

	if not resolvedTarget.Success or not targetEntity or targetId == "" then
		return { Success = false, EffectType = "ApplyStatus", Message = resolvedTarget.Error or "Invalid target for status." }
	end

	local appliedInst = StatusService.applyStatus(targetId, statusId, stacks, duration, tostring(context.SourcePlayer.UserId), targetEntity)
	if not appliedInst then
		return {
			Success = false,
			EffectType = "ApplyStatus",
			Message = string.format("Failed to apply status '%s': unknown or unimplemented status definition.", statusId),
		}
	end

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

	if not resolvedTarget.Success or not targetEntity or targetId == "" then
		return { Success = false, EffectType = "RemoveStatus", Message = resolvedTarget.Error or "Invalid target." }
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
					string.format("%s exhausted.", context.CardInstance.DefinitionId)
				)
			end
			return {
				Success = true,
				EffectType = "Exhaust",
				Message = string.format("Exhausted card %s.", context.CardInstance.DefinitionId),
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
	local cardDefId = effect.CardDefId
	if not cardDefId or cardDefId == "" then
		return {
			Success = false,
			EffectType = "CreateCard",
			Message = "CreateCard requires a valid CardDefId.",
		}
	end

	local cardDef = CardData.getCard(cardDefId)
	if not cardDef then
		return {
			Success = false,
			EffectType = "CreateCard",
			Message = string.format("Unknown CardDefId '%s'.", cardDefId),
		}
	end

	local dest = effect.DestinationPile
	if dest == nil then
		dest = "Deck"
	elseif dest ~= "Deck" and dest ~= "Hand" and dest ~= "DiscardPile" and dest ~= "ExhaustPile" then
		return {
			Success = false,
			EffectType = "CreateCard",
			Message = string.format("Invalid DestinationPile '%s'. Valid destinations are: Deck, Hand, DiscardPile, ExhaustPile.", tostring(dest)),
		}
	end

	local inst = CardService.createCardInstance(cardDefId, context.SourcePlayer.UserId)
	if not inst then
		return {
			Success = false,
			EffectType = "CreateCard",
			Message = string.format("Failed to instantiate card '%s'.", cardDefId),
		}
	end

	if dest == "Hand" then
		context.SourcePlayer.Hand[inst.InstanceId] = inst
	elseif dest == "DiscardPile" then
		table.insert(context.SourcePlayer.DiscardPile, inst)
	elseif dest == "ExhaustPile" then
		table.insert(context.SourcePlayer.ExhaustPile, inst)
	elseif dest == "Deck" then
		table.insert(context.SourcePlayer.Deck, inst)
	end

	return {
		Success = true,
		EffectType = "CreateCard",
		Message = string.format("Created card %s in %s.", cardDefId, dest),
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

	if not resType or resType == "" then
		return {
			Success = false,
			EffectType = "ModifyResource",
			Message = "ModifyResource requires a valid non-empty Resource type.",
		}
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

function EffectResolver.isSupportedEffectType(effectType: string): boolean
	return handlers[effectType] ~= nil
end

-- Resolves an array of card/action effects against the given context
function EffectResolver.resolveEffects(effects: any, context: ActionContext?): any
	if currentDepth >= MAX_RECURSION_DEPTH then
		local msg = "[EffectResolver] Exceeded maximum recursion depth of " .. tostring(MAX_RECURSION_DEPTH)
		warn(msg)
		local recRes = {
			{
				Success = false,
				EffectType = "Recursion",
				Message = msg,
			}
		}
		(recRes :: any).Success = false
		(recRes :: any).Error = msg
		return recRes
	end

	currentDepth += 1
	local results: { EffectExecutionResult } = {}

	local effectsList: { CardData.Effect }
	local actualContext: ActionContext

	if typeof(effects) == "table" and (effects :: any).Effects ~= nil then
		local callTable = effects :: any
		effectsList = callTable.Effects
		actualContext = {
			SourcePlayer = callTable.Caster or callTable.SourcePlayer,
			Target = if callTable.Target and (callTable.Target.TargetKind ~= nil or callTable.Target.Success ~= nil) then callTable.Target else {
				Success = true,
				TargetKind = "Enemy",
				EnemyTarget = callTable.Target,
				PlayerTarget = nil,
				TargetId = if callTable.Target then tostring(callTable.Target.InstanceId or callTable.Target.UserId or "") else "",
				TargetName = if callTable.Target then tostring(callTable.Target.Name or "") else "",
			},
			CombatState = callTable.CombatState,
			Party = callTable.Party,
		}
	else
		effectsList = effects
		actualContext = context :: ActionContext
	end

	local ok, err = pcall(function()
		type PreparedEffect = {
			effect: CardData.Effect,
			handler: EffectHandler?,
			resolvedTarget: StateTypes.ResolvedTarget,
			isSatisfied: boolean,
			isValid: boolean,
			condErr: string?,
		}

		-- 1. Pre-evaluate conditions against pre-action target state
		local prepared: { PreparedEffect } = {}
		for _, effect in effectsList do
			local handler = handlers[effect.Type]
			local resolvedTarget = resolveEffectTarget(effect, actualContext)
			local isSatisfied, isValid, condErr = EffectResolver.evaluateCondition(effect.Condition, actualContext, resolvedTarget)
			table.insert(prepared, {
				effect = effect,
				handler = handler,
				resolvedTarget = resolvedTarget,
				isSatisfied = isSatisfied,
				isValid = isValid,
				condErr = condErr,
			})
		end

		-- 2. Execute effects using pre-evaluated condition satisfaction
		for _, prep in prepared do
			if not prep.handler then
				local msg = "[EffectResolver] No handler registered for effect type: " .. tostring(prep.effect.Type)
				warn(msg)
				table.insert(results, {
					Success = false,
					EffectType = tostring(prep.effect.Type),
					Message = msg,
				})
				continue
			end

			if not prep.isValid then
				table.insert(results, {
					Success = false,
					EffectType = tostring(prep.effect.Type),
					Message = prep.condErr or ("Unknown condition: " .. tostring(prep.effect.Condition)),
				})
			elseif prep.isSatisfied then
				local res = prep.handler(prep.effect, actualContext, prep.resolvedTarget)
				table.insert(results, res)
			end
		end
	end)

	currentDepth -= 1
	if not ok then
		local msg = "[EffectResolver] Error during effect resolution: " .. tostring(err)
		warn(msg)
		table.insert(results, {
			Success = false,
			EffectType = "Error",
			Message = msg,
		})
	end

	-- Attach helper properties for callers expecting a summary object
	local allSuccess = #results > 0
	local firstError: string? = nil
	for _, r in results do
		if not r.Success then
			allSuccess = false
			firstError = r.Message or "Effect resolution failed."
			break
		end
	end

	local retAny: any = results
	retAny.Success = allSuccess
	retAny.Error = firstError

	return results
end

function EffectResolver.init()
	print("[EffectResolver] Initialized data-driven effect resolution dispatcher.")
end

return EffectResolver
