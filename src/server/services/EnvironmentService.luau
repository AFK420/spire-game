--!strict

--[=[
	EnvironmentService ModuleScript
	Mapped to: ServerScriptService.Server.services.EnvironmentService
	Authoritative environmental combat manager for Card Rift: Co-op Dungeon.
	1. Selects and instantiates room environments deterministically from seed/act.
	2. Authoritatively resolves damage modifiers, status interactions, and healing scaling.
	3. Executes elemental transformations (e.g. RainSoaked + Cold -> FrozenWastes).
	4. Updates 3D world visual presets via WorldRoomService.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)
local EnvironmentData = require(Shared:WaitForChild("EnvironmentData") :: ModuleScript)

local servicesFolder = script.Parent

local EnvironmentService = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function getWorldRoomService()
	local ws = servicesFolder:FindFirstChild("WorldRoomService")
	if ws then
		return require(ws :: ModuleScript)
	end
	return nil
end

--------------------------------------------------------------------------------
-- Environment Lifecycle
--------------------------------------------------------------------------------

function EnvironmentService.createEnvironment(
	envId: StateTypes.EnvironmentId?,
	actIndex: number?,
	seed: number?
): StateTypes.EnvironmentState
	local targetId: StateTypes.EnvironmentId = envId or "None"

	if targetId == "None" and actIndex and seed then
		targetId = EnvironmentData.pickDeterministicEnvironment(actIndex, seed)
	end

	local def = EnvironmentData.getDefinition(targetId)
	if not def then
		-- Fallback to None if not defined
		return {
			EnvironmentId = "None",
			Name = "Neutral Arena",
			StartTime = os.clock(),
			Intensity = 1.0,
			Tags = {},
			ActiveHazards = {},
			DamageModifiers = {},
			StatusModifiers = {},
			HealingModifier = 1.0,
			ActiveTransformation = nil,
		}
	end

	local tagsCopy = {}
	for k, v in def.Tags do tagsCopy[k] = v end

	local dmgModsCopy = {}
	for k, v in def.DamageModifiers do dmgModsCopy[k] = v end

	local statusModsCopy = {}
	for k, v in def.StatusModifiers do
		statusModsCopy[k] = {
			DurationBonus = v.DurationBonus,
			StacksBonus = v.StacksBonus,
		}
	end

	local envState: StateTypes.EnvironmentState = {
		EnvironmentId = def.Id,
		Name = def.Name,
		StartTime = os.clock(),
		Intensity = 1.0,
		Tags = tagsCopy,
		ActiveHazards = {},
		DamageModifiers = dmgModsCopy,
		StatusModifiers = statusModsCopy,
		HealingModifier = def.HealingModifier,
		ActiveTransformation = nil,
	}

	-- Apply 3D visual presentation
	local wrs = getWorldRoomService()
	if wrs and wrs.applyEnvironmentVisuals then
		pcall(function()
			wrs.applyEnvironmentVisuals(def.Id)
		end)
	end

	print(string.format("[EnvironmentService] Instantiated environment '%s' (%s).", def.Name, def.Id))
	return envState
end

function EnvironmentService.cleanup(envState: StateTypes.EnvironmentState?)
	if not envState then return end
	table.clear(envState.ActiveHazards)
	envState.ActiveTransformation = nil
end

--------------------------------------------------------------------------------
-- Authoritative Resolvers
--------------------------------------------------------------------------------

-- Modifies raw damage according to elemental environment affinities
function EnvironmentService.modifyDamage(
	envState: StateTypes.EnvironmentState?,
	context: StateTypes.DamageContext,
	currentDamage: number
): number
	if not envState or envState.EnvironmentId == "None" or currentDamage <= 0 then
		return currentDamage
	end

	local dmgType = context.DamageType
	local mult = envState.DamageModifiers[dmgType]
	if mult and mult > 0 then
		local modified = math.round(currentDamage * mult)
		if modified ~= currentDamage then
			print(string.format("[EnvironmentService] Damage modified by %s: %s %d -> %d (mult: %.2f)",
				envState.Name, dmgType, currentDamage, modified, mult))
		end
		return math.max(0, modified)
	end

	return currentDamage
end

-- Modifies status applications (bonus stacks or adjusted duration)
function EnvironmentService.modifyStatusApplication(
	envState: StateTypes.EnvironmentState?,
	statusDefId: string,
	stacks: number,
	duration: number?
): (number, number?)
	if not envState or envState.EnvironmentId == "None" then
		return stacks, duration
	end

	local mod = envState.StatusModifiers[statusDefId]
	if not mod then
		return stacks, duration
	end

	local finalStacks = stacks
	if mod.StacksBonus then
		finalStacks = math.max(1, finalStacks + mod.StacksBonus)
	end

	local finalDuration = duration
	if duration and mod.DurationBonus then
		finalDuration = math.max(1, duration + mod.DurationBonus)
	end

	return finalStacks, finalDuration
end

-- Modifies healing effectiveness
function EnvironmentService.modifyHealing(
	envState: StateTypes.EnvironmentState?,
	healAmount: number
): number
	if not envState or envState.EnvironmentId == "None" or healAmount <= 0 then
		return healAmount
	end

	if envState.HealingModifier ~= 1.0 then
		local modified = math.round(healAmount * envState.HealingModifier)
		return math.max(1, modified)
	end

	return healAmount
end

--------------------------------------------------------------------------------
-- Elemental Transformations
--------------------------------------------------------------------------------

function EnvironmentService.applyElementalTrigger(
	envState: StateTypes.EnvironmentState,
	triggerDamageType: StateTypes.DamageType
): (boolean, string?, StateTypes.EnvironmentId?)
	if envState.EnvironmentId == "None" then
		return false, nil, nil
	end

	local def = EnvironmentData.getDefinition(envState.EnvironmentId)
	if not def or not def.Transformations then
		return false, nil, nil
	end

	for _, trans in def.Transformations do
		if trans.TriggerDamageType == triggerDamageType then
			if trans.ResultEnvironmentId then
				-- Full transformation to another environment!
				local newDef = EnvironmentData.getDefinition(trans.ResultEnvironmentId)
				if newDef then
					envState.EnvironmentId = newDef.Id
					envState.Name = newDef.Name
					envState.ActiveTransformation = trans.NotificationText

					-- Reload modifiers
					table.clear(envState.DamageModifiers)
					for k, v in newDef.DamageModifiers do envState.DamageModifiers[k] = v end

					table.clear(envState.StatusModifiers)
					for k, v in newDef.StatusModifiers do
						envState.StatusModifiers[k] = { DurationBonus = v.DurationBonus, StacksBonus = v.StacksBonus }
					end
					envState.HealingModifier = newDef.HealingModifier

					local wrs = getWorldRoomService()
					if wrs and wrs.applyEnvironmentVisuals then
						pcall(function()
							wrs.applyEnvironmentVisuals(newDef.Id)
						end)
					end

					print(string.format("[EnvironmentService] Transformation executed: %s -> %s (%s)",
						def.Id, newDef.Id, trans.NotificationText))
					return true, trans.NotificationText, newDef.Id
				end
			elseif trans.HazardCreated then
				table.insert(envState.ActiveHazards, trans.HazardCreated)
				envState.ActiveTransformation = trans.NotificationText
				print(string.format("[EnvironmentService] Hazard created in %s: %s (%s)",
					def.Id, trans.HazardCreated, trans.NotificationText))
				return true, trans.NotificationText, nil
			end
		end
	end

	return false, nil, nil
end

--------------------------------------------------------------------------------
-- Client View Snapshot
--------------------------------------------------------------------------------

function EnvironmentService.getEnvironmentView(envState: StateTypes.EnvironmentState?): StateTypes.EnvironmentView?
	if not envState or envState.EnvironmentId == "None" then
		return nil
	end

	local def = EnvironmentData.getDefinition(envState.EnvironmentId)
	local desc = def and def.Description or ""
	local icon = def and def.Icon or "🌐"

	local tagList = {}
	for tag in envState.Tags do
		table.insert(tagList, tag)
	end

	return {
		EnvironmentId = envState.EnvironmentId,
		Name = envState.Name,
		Description = desc,
		Icon = icon,
		Tags = tagList,
		ActiveTransformation = envState.ActiveTransformation,
	}
end

function EnvironmentService.init()
	print("[EnvironmentService] Initialized authoritative environmental combat service.")
end

return EnvironmentService
