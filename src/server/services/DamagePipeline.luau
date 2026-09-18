--!strict

--[=[
	DamagePipeline ModuleScript
	Mapped to: ServerScriptService.Server.services.DamagePipeline
	Authoritative executor for multi-phase damage calculations, mitigations,
	shield absorption, direct HP bypass, and lethal defeat/downed transitions.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)

local servicesFolder = script.Parent
local ModifierResolver = require(servicesFolder:WaitForChild("ModifierResolver") :: ModuleScript)

local DamagePipeline = {}

local customCritRng: (() -> number)? = nil

function DamagePipeline.setCritRngHook(fn: (() -> number)?)
	customCritRng = fn
end

-- Executes damage against an enemy or player target through the full mitigation pipeline
function DamagePipeline.executeDamage(
	context: StateTypes.DamageContext,
	modifiers: { StateTypes.Modifier }?
): StateTypes.DamageResult
	-- Input validation: reject negative damage or missing context
	if context == nil or context.RawDamage < 0 then
		return {
			FinalDamage = 0,
			ShieldAbsorbed = 0,
			HPLost = 0,
			IsDefeatedOrDowned = false,
		}
	end

	-- Entity existence validation
	if context.TargetEntityKind == "Enemy" and not context.TargetEnemy then
		return {
			FinalDamage = 0,
			ShieldAbsorbed = 0,
			HPLost = 0,
			IsDefeatedOrDowned = false,
		}
	elseif context.TargetEntityKind == "Player" and not context.TargetPlayer then
		return {
			FinalDamage = 0,
			ShieldAbsorbed = 0,
			HPLost = 0,
			IsDefeatedOrDowned = false,
		}
	end

	-- 1. Resolve raw damage through the modifier pipeline if modifiers provided
	local finalDamage = context.RawDamage
	if modifiers and #modifiers > 0 then
		local modContext = {
			SourcePlayer = context.SourcePlayer,
			PlayerTarget = context.TargetPlayer,
			EnemyTarget = context.TargetEnemy,
		}
		finalDamage = ModifierResolver.resolve(context.RawDamage, "Damage", modifiers, modContext)
	end

	-- 1a. Environmental damage modification
	local envService = servicesFolder:FindFirstChild("EnvironmentService")
	if envService then
		local EnvironmentServiceModule = require(envService :: ModuleScript)
		local combatSvc = servicesFolder:FindFirstChild("CombatService")
		if combatSvc then
			local CombatServiceModule = require(combatSvc :: ModuleScript)
			local actCombat = CombatServiceModule.getActiveCombat()
			if actCombat and actCombat.Environment then
				finalDamage = EnvironmentServiceModule.modifyDamage(actCombat.Environment, context, finalDamage)
			end
		end
	end

	-- Periodic or direct hits cannot deal negative damage
	finalDamage = math.max(0, finalDamage)

	-- 1b. Critical Hit Resolution
	local isCritical = false
	if not context.IsPeriodic then
		if context.Critical == true then
			isCritical = true
		elseif context.Critical == nil and context.SourcePlayer then
			local sr = servicesFolder:FindFirstChild("StatResolver")
			if sr then
				local StatResolverModule = require(sr :: ModuleScript)
				local playerStats = StatResolverModule.resolvePlayerStats(context.SourcePlayer)
				local critChance = playerStats.CritChance or 0.05
				local roll = if customCritRng then customCritRng() else math.random()
				if critChance > 0 and roll < critChance then
					isCritical = true
				end
			end
		end
	end

	if isCritical then
		local mult = 1.5
		if context.SourcePlayer then
			if context.SourcePlayer.SubclassId == "Assassin" then
				mult = 2.0
			end
			local sr = servicesFolder:FindFirstChild("StatResolver")
			if sr then
				local StatResolverModule = require(sr :: ModuleScript)
				local playerStats = StatResolverModule.resolvePlayerStats(context.SourcePlayer)
				if playerStats.CritMultiplier and playerStats.CritMultiplier > 0 then
					mult = playerStats.CritMultiplier
				end
			end
		end
		finalDamage = math.round(finalDamage * mult)
		context.Critical = true
	end

	local shieldAbsorbed = 0
	local hpLost = 0
	local isDefeatedOrDowned = false

	-- 2. Apply damage to Enemy target
	if context.TargetEntityKind == "Enemy" and context.TargetEnemy then
		local enemy = context.TargetEnemy
		if enemy.HP > 0 then
			if context.CanHitShield then
				shieldAbsorbed = math.min(math.max(0, enemy.Shield), finalDamage)
				enemy.Shield = math.max(0, enemy.Shield - shieldAbsorbed)
				hpLost = finalDamage - shieldAbsorbed
				enemy.HP = math.max(0, enemy.HP - hpLost)
			else
				-- Bypasses Shield directly (e.g. Poison, Direct HP Drain)
				shieldAbsorbed = 0
				hpLost = finalDamage
				enemy.HP = math.max(0, enemy.HP - hpLost)
			end

			if enemy.HP <= 0 then
				enemy.HP = 0
				isDefeatedOrDowned = true
			end
		end

	-- 3. Apply damage to Player target
	elseif context.TargetEntityKind == "Player" and context.TargetPlayer then
		local playerState = context.TargetPlayer
		if not playerState.IsDowned then
			if context.CanHitShield then
				shieldAbsorbed = math.min(math.max(0, playerState.Resources.Shield), finalDamage)
				playerState.Resources.Shield = math.max(0, playerState.Resources.Shield - shieldAbsorbed)
				hpLost = finalDamage - shieldAbsorbed
				playerState.Resources.HP = math.max(0, playerState.Resources.HP - hpLost)
			else
				-- Bypasses Shield directly
				shieldAbsorbed = 0
				hpLost = finalDamage
				playerState.Resources.HP = math.max(0, playerState.Resources.HP - hpLost)
			end

			if playerState.Resources.HP <= 0 then
				playerState.IsDowned = true
				playerState.Resources.HP = 0
				playerState.Resources.Shield = 0
				playerState.IsReady = false
				isDefeatedOrDowned = true
			end
		end
	end

	return {
		FinalDamage = finalDamage,
		ShieldAbsorbed = shieldAbsorbed,
		HPLost = hpLost,
		IsDefeatedOrDowned = isDefeatedOrDowned,
		IsCritical = isCritical,
	}
end

function DamagePipeline.init()
	print("[DamagePipeline] Initialized authoritative damage resolution pipeline.")
end

return DamagePipeline
