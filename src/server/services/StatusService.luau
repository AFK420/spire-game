--!strict

--[=[
	StatusService ModuleScript
	Mapped to: ServerScriptService.Server.services.StatusService
	Central owner of statuses with strict Definition vs Instance separation.
	Manages applying, stacking, refreshing, ticking, and expiring statuses
	(Poison, Ignite, Chill, Freeze, Shock, Bleed) for both enemies and players.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)

local servicesFolder = script.Parent
local DamagePipeline = require(servicesFolder:WaitForChild("DamagePipeline") :: ModuleScript)

local StatusService = {}

--------------------------------------------------------------------------------
-- 1. Status Definitions
--------------------------------------------------------------------------------

local definitions: { [string]: StateTypes.StatusDefinition } = {
	Poison = {
		Id = "Poison",
		Name = "Poison",
		Description = "Deals direct damage to HP bypassing Shield equal to stacks, then loses 1 stack.",
		Stacking = "Stack",
		DefaultDuration = -1, -- Stack-based decay
		TickTiming = "TurnStart",
		MaxStacks = 999,
		IsDebuff = true,
		Icon = "🧪",
	},
	Ignite = {
		Id = "Ignite",
		Name = "Ignite",
		Description = "Burns for fire damage over time.",
		Stacking = "Stack",
		DefaultDuration = 3,
		TickTiming = "TurnStart",
		MaxStacks = 50,
		IsDebuff = true,
		Icon = "🔥",
	},
	Chill = {
		Id = "Chill",
		Name = "Chill",
		Description = "Reduces action effectiveness and initiative.",
		Stacking = "Stack",
		DefaultDuration = 2,
		TickTiming = "TurnEnd",
		MaxStacks = 10,
		IsDebuff = true,
		Icon = "❄️",
	},
	Freeze = {
		Id = "Freeze",
		Name = "Freeze",
		Description = "Completely incapacitates target for duration.",
		Stacking = "RefreshDuration",
		DefaultDuration = 1,
		TickTiming = "TurnEnd",
		MaxStacks = 1,
		IsDebuff = true,
		Icon = "🧊",
	},
	Shock = {
		Id = "Shock",
		Name = "Shock",
		Description = "Causes bonus damage on subsequent hits.",
		Stacking = "Stack",
		DefaultDuration = 2,
		TickTiming = "OnAction",
		MaxStacks = 20,
		IsDebuff = true,
		Icon = "⚡",
	},
	Bleed = {
		Id = "Bleed",
		Name = "Bleed",
		Description = "Inflicts physical hemorrhaging that deals damage when taking action.",
		Stacking = "Stack",
		DefaultDuration = 3,
		TickTiming = "TurnStart",
		MaxStacks = 50,
		IsDebuff = true,
		Icon = "🩸",
	},
}

--------------------------------------------------------------------------------
-- 2. Runtime Status Instances
--------------------------------------------------------------------------------

-- Keyed by TargetId (e.g. "enemy_1" or "player_12345"), then DefinitionId
local entityStatuses: { [string]: { [string]: StateTypes.StatusInstance } } = {}
local instanceGuidCounter = 0

local function nextInstanceId(): string
	instanceGuidCounter += 1
	return string.format("status_%d", instanceGuidCounter)
end

function StatusService.getDefinition(defId: string): StateTypes.StatusDefinition?
	return definitions[defId]
end

function StatusService.getStatus(targetId: string, defId: string): StateTypes.StatusInstance?
	local targetTable = entityStatuses[targetId]
	return targetTable and targetTable[defId] or nil
end

function StatusService.getStatuses(targetId: string): { StateTypes.StatusInstance }
	local targetTable = entityStatuses[targetId]
	if not targetTable then return {} end

	local list = {}
	for _, inst in targetTable do
		table.insert(list, inst)
	end
	return list
end

-- Applies or stacks a status on a target entity
function StatusService.applyStatus(
	targetId: string,
	defId: string,
	stacks: number,
	duration: number?,
	sourceId: string,
	targetEntityRef: any?
): StateTypes.StatusInstance?
	local def = definitions[defId]
	if not def then
		warn("[StatusService] Unknown status definition: " .. tostring(defId))
		return nil
	end

	if not entityStatuses[targetId] then
		entityStatuses[targetId] = {}
	end

	local targetTable = entityStatuses[targetId]
	local existing = targetTable[defId]

	if existing then
		if def.Stacking == "Stack" then
			existing.Stacks += stacks
			if def.MaxStacks and existing.Stacks > def.MaxStacks then
				existing.Stacks = def.MaxStacks
			end
			if duration and duration > existing.Duration then
				existing.Duration = duration
			end
		elseif def.Stacking == "RefreshDuration" then
			if duration and duration > existing.Duration then
				existing.Duration = duration
			else
				existing.Duration = def.DefaultDuration or 1
			end
		end

		-- Synchronize projection field if enemy
		if defId == "Poison" and targetEntityRef and targetEntityRef.Poison ~= nil then
			targetEntityRef.Poison = existing.Stacks
		end

		return existing
	else
		local newInst: StateTypes.StatusInstance = {
			InstanceId = nextInstanceId(),
			DefinitionId = defId,
			Stacks = stacks,
			Duration = duration or def.DefaultDuration or -1,
			SourceId = sourceId,
			TargetId = targetId,
		}

		targetTable[defId] = newInst

		-- Synchronize projection field if enemy
		if defId == "Poison" and targetEntityRef and targetEntityRef.Poison ~= nil then
			targetEntityRef.Poison = newInst.Stacks
		end

		return newInst
	end
end

-- Removes a specific status definition from a target
function StatusService.removeStatus(targetId: string, defId: string, targetEntityRef: any?): boolean
	local targetTable = entityStatuses[targetId]
	if not targetTable or not targetTable[defId] then
		return false
	end

	targetTable[defId] = nil

	if defId == "Poison" and targetEntityRef and targetEntityRef.Poison ~= nil then
		targetEntityRef.Poison = 0
	end

	return true
end

export type StatusTickResult = {
	DefinitionId: string,
	TargetId: string,
	DamageDealt: number,
	RemainingStacks: number,
	Expired: boolean,
	Defeated: boolean,
}

-- Ticks all applicable statuses for a target at a given combat timing
function StatusService.tickStatuses(
	targetId: string,
	timing: StateTypes.StatusTickTiming,
	targetEntity: any,
	isEnemy: boolean
): { StatusTickResult }
	local targetTable = entityStatuses[targetId]
	if not targetTable then return {} end

	local results: { StatusTickResult } = {}
	local toRemove: { string } = {}

	for defId, inst in targetTable do
		local def = definitions[defId]
		if not def or def.TickTiming ~= timing then
			continue
		end

		local dmgDealt = 0
		local defeated = false

		if defId == "Poison" then
			if inst.Stacks > 0 then
				dmgDealt = inst.Stacks

				-- Poison deals damage directly to HP bypassing Shield
				local dmgCtx: StateTypes.DamageContext = {
					RawDamage = dmgDealt,
					DamageType = "Venom",
					SourceId = inst.SourceId,
					SourceName = "Poison",
					SourcePlayer = nil,
					TargetEntityKind = isEnemy and "Enemy" or "Player",
					TargetEnemy = isEnemy and targetEntity or nil,
					TargetPlayer = not isEnemy and targetEntity or nil,
					Tags = { "Periodic", "Poison" },
					Critical = false,
					CanHitShield = false, -- Direct HP bypass
					IsPeriodic = true,
				}

				local res = DamagePipeline.executeDamage(dmgCtx)
				defeated = res.IsDefeatedOrDowned

				-- Poison decrements by 1 stack per tick
				inst.Stacks = math.max(0, inst.Stacks - 1)
				if isEnemy and targetEntity.Poison ~= nil then
					targetEntity.Poison = inst.Stacks
				end

				if inst.Stacks <= 0 then
					table.insert(toRemove, defId)
				end
			end

		elseif defId == "Ignite" then
			if inst.Stacks > 0 then
				dmgDealt = inst.Stacks * 2
				local dmgCtx: StateTypes.DamageContext = {
					RawDamage = dmgDealt,
					DamageType = "Fire",
					SourceId = inst.SourceId,
					SourceName = "Ignite",
					SourcePlayer = nil,
					TargetEntityKind = isEnemy and "Enemy" or "Player",
					TargetEnemy = isEnemy and targetEntity or nil,
					TargetPlayer = not isEnemy and targetEntity or nil,
					Tags = { "Periodic", "Fire" },
					Critical = false,
					CanHitShield = true,
					IsPeriodic = true,
				}
				local res = DamagePipeline.executeDamage(dmgCtx)
				defeated = res.IsDefeatedOrDowned

				if inst.Duration > 0 then
					inst.Duration -= 1
					if inst.Duration <= 0 then
						table.insert(toRemove, defId)
					end
				end
			end

		elseif defId == "Bleed" then
			if inst.Stacks > 0 then
				dmgDealt = inst.Stacks
				local dmgCtx: StateTypes.DamageContext = {
					RawDamage = dmgDealt,
					DamageType = "Physical",
					SourceId = inst.SourceId,
					SourceName = "Bleed",
					SourcePlayer = nil,
					TargetEntityKind = isEnemy and "Enemy" or "Player",
					TargetEnemy = isEnemy and targetEntity or nil,
					TargetPlayer = not isEnemy and targetEntity or nil,
					Tags = { "Periodic", "Bleed" },
					Critical = false,
					CanHitShield = true,
					IsPeriodic = true,
				}
				local res = DamagePipeline.executeDamage(dmgCtx)
				defeated = res.IsDefeatedOrDowned

				if inst.Duration > 0 then
					inst.Duration -= 1
					if inst.Duration <= 0 then
						table.insert(toRemove, defId)
					end
				end
			end
		end

		table.insert(results, {
			DefinitionId = defId,
			TargetId = targetId,
			DamageDealt = dmgDealt,
			RemainingStacks = inst.Stacks,
			Expired = inst.Stacks <= 0,
			Defeated = defeated,
		})
	end

	for _, defId in toRemove do
		targetTable[defId] = nil
	end

	return results
end

function StatusService.clearEntity(targetId: string)
	entityStatuses[targetId] = nil
end

function StatusService.resetCombat()
	table.clear(entityStatuses)
end

function StatusService.init()
	print("[StatusService] Initialized data-driven status engine with Definition/Instance separation.")
end

return StatusService
