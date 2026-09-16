--!strict

--[=[
	ModifierResolver ModuleScript
	Mapped to: ServerScriptService.Server.services.ModifierResolver
	Deterministic, data-driven calculation engine for stats, damage, shield, and healing.
	Pipeline: Base Value -> Additive Modifiers -> Multiplicative Modifiers -> Final Value.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)

local ModifierResolver = {}

-- Helper to construct a structured modifier
function ModifierResolver.createModifier(
	id: string,
	source: string,
	stat: StateTypes.ModifierStat,
	operation: StateTypes.ModifierOperation,
	value: number,
	priority: number?,
	condition: string?
): StateTypes.Modifier
	return {
		Id = id,
		Source = source,
		Stat = stat,
		Operation = operation,
		Value = value,
		Priority = priority or (operation == "Add" and 100 or 200),
		Condition = condition,
	}
end

-- Evaluates a condition against an optional evaluation context
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

-- Resolves a stat value deterministically through the modifier pipeline
function ModifierResolver.resolve(
	baseValue: number,
	stat: StateTypes.ModifierStat,
	modifiers: { StateTypes.Modifier },
	context: any?
): (number, { StateTypes.Modifier })
	-- 1. Filter applicable modifiers by stat and condition
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

	-- 3. Check for Override modifiers first (highest priority override wins)
	local overrideMod: StateTypes.Modifier? = nil
	for _, mod in applicable do
		if mod.Operation == "Override" then
			overrideMod = mod
		end
	end

	if overrideMod then
		currentValue = overrideMod.Value
		table.insert(applied, overrideMod)
		return math.max(0, math.floor(currentValue + 0.5)), applied
	end

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

	-- 6. Floor clamp to 0 minimum
	local finalValue = math.max(0, math.floor(currentValue + 0.5))
	return finalValue, applied
end

function ModifierResolver.init()
	print("[ModifierResolver] Initialized deterministic modifier resolution engine.")
end

return ModifierResolver
