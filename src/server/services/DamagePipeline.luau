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

-- Executes damage against an enemy or player target through the full mitigation pipeline
function DamagePipeline.executeDamage(
	context: StateTypes.DamageContext,
	modifiers: { StateTypes.Modifier }?
): StateTypes.DamageResult
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

	-- Periodic or direct hits cannot deal negative damage
	finalDamage = math.max(0, finalDamage)

	local shieldAbsorbed = 0
	local hpLost = 0
	local isDefeatedOrDowned = false

	-- 2. Apply damage to Enemy target
	if context.TargetEntityKind == "Enemy" and context.TargetEnemy then
		local enemy = context.TargetEnemy
		if enemy.HP > 0 then
			if context.CanHitShield then
				shieldAbsorbed = math.min(enemy.Shield, finalDamage)
				enemy.Shield -= shieldAbsorbed
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
				shieldAbsorbed = math.min(playerState.Resources.Shield, finalDamage)
				playerState.Resources.Shield -= shieldAbsorbed
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
	}
end

function DamagePipeline.init()
	print("[DamagePipeline] Initialized authoritative damage resolution pipeline.")
end

return DamagePipeline
