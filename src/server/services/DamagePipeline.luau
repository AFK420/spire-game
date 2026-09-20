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
local GameConfig = require(Shared:WaitForChild("GameConfig") :: ModuleScript)

local servicesFolder = script.Parent
local ModifierResolver = require(servicesFolder:WaitForChild("ModifierResolver") :: ModuleScript)
local BreakService = require(servicesFolder:WaitForChild("BreakService") :: ModuleScript)
local BossMechanicsService = require(servicesFolder:WaitForChild("BossMechanicsService") :: ModuleScript)

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

	-- Shock is a target-side electrical vulnerability. It amplifies direct hits
	-- only, preventing damage-over-time effects from recursively scaling each other.
	if not context.IsPeriodic then
		local statusModule = servicesFolder:FindFirstChild("StatusService")
		if statusModule then
			local StatusServiceModule = require(statusModule :: ModuleScript)
			local targetId = if context.TargetEntityKind == "Enemy" and context.TargetEnemy
				then context.TargetEnemy.InstanceId
				elseif context.TargetEntityKind == "Player" and context.TargetPlayer
					then tostring(context.TargetPlayer.UserId)
					else nil
			if targetId and StatusServiceModule.getIncomingDamageMultiplier then
				local shockMultiplier = StatusServiceModule.getIncomingDamageMultiplier(targetId, false)
				finalDamage = math.round(finalDamage * shockMultiplier)
			end
		end
	end

	-- Periodic or direct hits cannot deal negative damage
	finalDamage = math.max(0, finalDamage)

	-- Broken enemies take increased direct damage. Periodic effects are excluded
	-- so damage-over-time does not replace coordinated Break-phase burst play.
	if context.TargetEntityKind == "Enemy" then
		finalDamage *= BreakService.getDirectDamageMultiplier(context.TargetEnemy, context.IsPeriodic)
		finalDamage = math.round(finalDamage)
	end

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

	-- Enemy Armor reduces direct physical damage after offensive multipliers but
	-- before Shield. Piercing cards and periodic damage bypass Armor entirely.
	local armorMitigated = 0
	if context.TargetEntityKind == "Enemy"
		and context.TargetEnemy
		and context.DamageType == "Physical"
		and not context.IsPeriodic
		and not (context.Tags and table.find(context.Tags, "Piercing")) then
		local armor = math.max(0, context.TargetEnemy.Armor or 0)
		if armor > 0 and finalDamage > 0 then
			local reduction = math.min(
				GameConfig.Combat.MaximumEnemyArmorReduction,
				armor / (armor + GameConfig.Combat.ArmorScalingConstant)
			)
			local beforeArmor = finalDamage
			finalDamage = math.max(1, math.round(finalDamage * (1 - reduction)))
			armorMitigated = math.max(0, beforeArmor - finalDamage)
		end
	end

	local shieldAbsorbed = 0
	local hpLost = 0
	local isDefeatedOrDowned = false

	-- 2. Apply damage to Enemy target
	if context.TargetEntityKind == "Enemy" and context.TargetEnemy then
		local enemy = context.TargetEnemy
		if enemy.HP > 0 then
			local phaseHealthFloor = BossMechanicsService.getPhaseHealthFloor(enemy)
			if context.CanHitShield then
				shieldAbsorbed = math.min(math.max(0, enemy.Shield), finalDamage)
				enemy.Shield = math.max(0, enemy.Shield - shieldAbsorbed)
				hpLost = math.min(finalDamage - shieldAbsorbed, math.max(0, enemy.HP - phaseHealthFloor))
				enemy.HP = math.max(0, enemy.HP - hpLost)
			else
				-- Bypasses Shield directly (e.g. Poison, Direct HP Drain)
				shieldAbsorbed = 0
				hpLost = math.min(finalDamage, math.max(0, enemy.HP - phaseHealthFloor))
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
		ArmorMitigated = armorMitigated,
	}
end

function DamagePipeline.init()
	print("[DamagePipeline] Initialized authoritative damage resolution pipeline.")
end

return DamagePipeline
