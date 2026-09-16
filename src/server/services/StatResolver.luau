--!strict
--[=[
	StatResolver ModuleScript
	Mapped to: ServerScriptService.Server.services.StatResolver

	Centralized deterministic calculation layer for player and entity stats (Phase 3).
	Pipeline: Base Stat -> Additive Modifiers -> Multiplicative Modifiers -> Clamped Final Stat.
	Supports absolute Override precedence.
	Aggregates modifiers across Equipment, Class Passives, and active Combat modifiers.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)
local ClassData = require(Shared:WaitForChild("ClassData") :: ModuleScript)

local Server = ServerScriptService:WaitForChild("Server")
local Services = Server:WaitForChild("services")
local ModifierResolver = require(Services:WaitForChild("ModifierResolver") :: ModuleScript)

local StatResolver = {}

-- Safely requires EquipmentService
local function getEquipmentService(): any?
	local mod = Services:FindFirstChild("EquipmentService")
	if mod and mod:IsA("ModuleScript") then
		return require(mod)
	end
	return nil
end

-- Safely requires PassiveService (available in Commit 4)
local function getPassiveService(): any?
	local mod = Services:FindFirstChild("PassiveService")
	if mod and mod:IsA("ModuleScript") then
		return require(mod)
	end
	return nil
end

-- Deterministic evaluation of condition strings
local function evaluateCondition(condition: string?, context: any?): boolean
	if not condition or condition == "" then
		return true
	end
	if not context then
		return true
	end
	if condition == "LowHP" then
		local p = context.PlayerTarget or context.SourcePlayer
		if p and p.Resources then
			return p.Resources.HP < (p.Resources.MaxHP * 0.5)
		end
		return false
	elseif condition == "TargetDowned" then
		local p = context.PlayerTarget
		return p ~= nil and p.IsDowned == true
	elseif condition == "TargetLiving" then
		local p = context.PlayerTarget
		return p == nil or p.IsDowned ~= true
	end
	return true
end

-- Resolves an individual stat value through deterministic pipeline and applies stat-specific bounds clamping
function StatResolver.resolveStat(
	baseValue: number,
	stat: StateTypes.ModifierStat,
	modifiers: { StateTypes.Modifier },
	context: any?
): (number, { StateTypes.Modifier })
	-- 1. Filter applicable modifiers
	local applicable: { StateTypes.Modifier } = {}
	for _, mod in modifiers do
		if mod.Stat == stat and evaluateCondition(mod.Condition, context) then
			table.insert(applicable, mod)
		end
	end

	-- 2. Sort deterministically by Priority (ascending), then Id (alphabetical)
	table.sort(applicable, function(a, b)
		if a.Priority == b.Priority then
			return a.Id < b.Id
		end
		return a.Priority < b.Priority
	end)

	local currentValue = baseValue
	local applied: { StateTypes.Modifier } = {}

	-- 3. Override takes absolute precedence (last applied override wins)
	local overrideMod: StateTypes.Modifier? = nil
	for _, mod in applicable do
		if mod.Operation == "Override" then
			overrideMod = mod
		end
	end

	if overrideMod then
		currentValue = overrideMod.Value
		table.insert(applied, overrideMod)
	else
		-- 4. Apply Additive Modifiers
		for _, mod in applicable do
			if mod.Operation == "Add" then
				currentValue += mod.Value
				table.insert(applied, mod)
			end
		end

		-- 5. Apply Multiplicative Modifiers
		for _, mod in applicable do
			if mod.Operation == "Multiply" then
				currentValue = currentValue * mod.Value
				table.insert(applied, mod)
			end
		end
	end

	-- 6. Enforce stat-specific clamping and boundaries
	local finalValue: number
	if stat == "MaxHP" then
		finalValue = math.max(1, math.floor(currentValue + 0.5))
	elseif stat == "MaxEnergy" then
		finalValue = math.max(0, math.floor(currentValue + 0.5))
	elseif stat == "CritChance" then
		finalValue = math.clamp(currentValue, 0.0, 1.0)
	elseif stat == "CritMultiplier" then
		finalValue = math.max(1.0, currentValue)
	else
		-- Damage, Shield, ShieldGain, Healing, Cost, etc.
		finalValue = math.max(0, math.floor(currentValue + 0.5))
	end

	return finalValue, applied
end

-- Collects all passive and equipment modifiers for a given player state
function StatResolver.collectPlayerModifiers(
	playerState: StateTypes.PlayerState,
	extraModifiers: { StateTypes.Modifier }?
): { StateTypes.Modifier }
	local allModifiers: { StateTypes.Modifier } = {}

	-- 1. Collect equipment modifiers
	local equipService = getEquipmentService()
	if equipService and type(equipService.collectModifiers) == "function" then
		local equipMods = equipService.collectModifiers(playerState)
		for _, mod in equipMods do
			table.insert(allModifiers, mod)
		end
	end

	-- 2. Collect passive tree modifiers
	local passService = getPassiveService()
	if passService and type(passService.collectModifiers) == "function" then
		local passMods = passService.collectModifiers(playerState)
		for _, mod in passMods do
			table.insert(allModifiers, mod)
		end
	end

	-- 3. Include any extra/contextual modifiers
	if extraModifiers then
		for _, mod in extraModifiers do
			table.insert(allModifiers, mod)
		end
	end

	return allModifiers
end

-- Resolves the full suite of combat stats for a player
function StatResolver.resolvePlayerStats(
	playerState: StateTypes.PlayerState,
	extraModifiers: { StateTypes.Modifier }?
): StateTypes.ResolvedPlayerStats
	local modifiers = StatResolver.collectPlayerModifiers(playerState, extraModifiers)

	-- Base stats from class or player resources
	local baseMaxHP = 80
	local baseMaxEnergy = 3

	if playerState.ClassId and playerState.ClassId ~= "" then
		local classDef = ClassData.getClass(playerState.ClassId)
		if classDef then
			baseMaxHP = classDef.MaxHp
			baseMaxEnergy = classDef.StartingEnergy
		end
	elseif playerState.Resources and playerState.Resources.MaxHP > 0 then
		baseMaxHP = playerState.Resources.MaxHP
		baseMaxEnergy = playerState.Resources.MaxEnergy
	end

	local maxHP = StatResolver.resolveStat(baseMaxHP, "MaxHP", modifiers, { SourcePlayer = playerState })
	local maxEnergy = StatResolver.resolveStat(baseMaxEnergy, "MaxEnergy", modifiers, { SourcePlayer = playerState })
	local bonusDamage = StatResolver.resolveStat(0, "Damage", modifiers, { SourcePlayer = playerState })
	local bonusShieldGain = StatResolver.resolveStat(0, "ShieldGain", modifiers, { SourcePlayer = playerState })
	local bonusHealing = StatResolver.resolveStat(0, "Healing", modifiers, { SourcePlayer = playerState })
	local critChance = StatResolver.resolveStat(0.05, "CritChance", modifiers, { SourcePlayer = playerState })
	local critMultiplier = StatResolver.resolveStat(1.5, "CritMultiplier", modifiers, { SourcePlayer = playerState })
	local costReduction = StatResolver.resolveStat(0, "Cost", modifiers, { SourcePlayer = playerState })

	return {
		MaxHP = maxHP,
		MaxEnergy = maxEnergy,
		BonusDamage = bonusDamage,
		BonusShieldGain = bonusShieldGain,
		BonusHealing = bonusHealing,
		CritChance = critChance,
		CritMultiplier = critMultiplier,
		CostReduction = costReduction,
	}
end

-- Synchronizes resolved MaxHP and MaxEnergy onto the player state's Resources, clamping current values
function StatResolver.syncPlayerDerivedStats(playerState: StateTypes.PlayerState): StateTypes.ResolvedPlayerStats
	local resolved = StatResolver.resolvePlayerStats(playerState)

	if playerState.Resources then
		playerState.Resources.MaxHP = resolved.MaxHP
		playerState.Resources.HP = math.clamp(playerState.Resources.HP, 0, resolved.MaxHP)

		playerState.Resources.MaxEnergy = resolved.MaxEnergy
		playerState.Resources.Energy = math.clamp(playerState.Resources.Energy, 0, resolved.MaxEnergy)
	end

	return resolved
end

function StatResolver.init()
	print("[StatResolver] Initialized centralized stat resolution engine.")
end

return StatResolver
