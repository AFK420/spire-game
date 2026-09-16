--!strict
--[=[
	StatResolver ModuleScript
	Mapped to: ServerScriptService.Server.services.StatResolver

	Centralized deterministic calculation layer for player and entity stats (Phase 3 / 3.1):
	Pipeline: Base Stat -> Additive Modifiers -> Multiplicative Modifiers -> Clamped Final Stat.
	Supports absolute Override precedence.
	Aggregates modifiers across Equipment, Class Passives, and active Combat modifiers.

	=============================================================================
	STAT SEMANTICS SPECIFICATION (9 Supported ModifierStats):
	-----------------------------------------------------------------------------
	1. "Damage"
	   - Base: Raw damage from card/skill action or 0 for player bonus attack.
	   - Add: Flat bonus/penalty. Negative additives supported (e.g. weakness debuffs).
	   - Multiply: Percentage scaling factor (e.g. 1.5 for +50% vulnerable).
	   - Override: Forces fixed damage value directly (e.g. execute effects).
	   - Final: Clamped to math.max(0, math.floor(val + 0.5)).

	2. "Shield"
	   - Base: Raw shield value from defensive card/skill.
	   - Add: Flat bonus shield from passives, relics, or synergies.
	   - Multiply: Percentage scaling factor.
	   - Override: Forces fixed shield value.
	   - Final: Clamped to math.max(0, math.floor(val + 0.5)).

	3. "ShieldGain"
	   - Base: 0 (player baseline shield gain bonus).
	   - Add: Flat bonus shield added to all shield-granting actions (e.g. armor +4).
	   - Multiply: Scaling factor.
	   - Override: Fixed bonus shield gain.
	   - Final: Clamped to math.max(0, math.floor(val + 0.5)).

	4. "Healing"
	   - Base: Raw healing from support card/skill or 0 for player bonus healing.
	   - Add: Flat bonus healing.
	   - Multiply: Percentage scaling factor.
	   - Override: Fixed healing value.
	   - Final: Clamped to math.max(0, math.floor(val + 0.5)).

	5. "Cost"
	   - Base: Action base energy cost (e.g. 2) or 0 for player flat cost reduction.
	   - Add: Energy adjustments. Negative additives represent cost reductions (e.g. -1).
	          Positive additives represent energy tax/curse penalties (e.g. +1).
	   - Multiply: Multiplier scaling on cost.
	   - Override: Fixed cost override (e.g. 0 for free action gimmick).
	   - Final: Strictly clamped to math.max(0, math.floor(val + 0.5)). Negative costs are forbidden.

	6. "MaxHP"
	   - Base: HeroClass.MaxHp (e.g. Warlord 110).
	   - Add: Flat MaxHP adjustments (e.g. gear +10, passive +15). Negative additives supported.
	   - Multiply: Percentage MaxHP scaling.
	   - Override: Fixed MaxHP.
	   - Final: Strictly clamped to math.max(1, math.floor(val + 0.5)). MaxHP can never drop below 1.

	7. "MaxEnergy"
	   - Base: HeroClass.StartingEnergy (e.g. 3).
	   - Add: Flat energy adjustments. Negative additives supported (e.g. TitanStance -1 MaxEnergy).
	   - Multiply: Energy multiplier.
	   - Override: Fixed MaxEnergy.
	   - Final: Strictly clamped to math.max(0, math.floor(val + 0.5)).

	8. "CritChance"
	   - Base: Default baseline 0.05 (5%).
	   - Add: Flat crit chance bonus (e.g. +0.10 for +10%).
	   - Multiply: Scaling factor on crit chance.
	   - Override: Fixed crit chance (e.g. 1.0 for guaranteed critical hit).
	   - Final: Floating point clamped to [0.0, 1.0] range.

	9. "CritMultiplier"
	   - Base: Default baseline 1.5 (150% crit damage).
	   - Add: Flat crit damage bonus (e.g. +0.5 for 200% total crit damage).
	   - Multiply: Multiplier on crit damage scaling.
	   - Override: Fixed crit multiplier.
	   - Final: Floating point clamped to math.max(1.0, val). Crit damage can never fall below 100%.
	=============================================================================
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

-- Safely requires PassiveService
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
		-- 4. Apply Additive Modifiers (negative additives are permitted where intentionally supported)
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

	-- Sort all collected modifiers deterministically
	table.sort(allModifiers, function(a, b)
		if a.Priority == b.Priority then
			return a.Id < b.Id
		end
		return a.Priority < b.Priority
	end)

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
	print("[StatResolver] Initialized centralized stat resolution engine with Phase 3.1 hardening.")
end

return StatResolver
