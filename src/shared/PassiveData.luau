--!strict
--[=[
	PassiveData ModuleScript
	Mapped to: ReplicatedStorage.Shared.PassiveData

	Canonical passive skill tree graphs and node definitions for Card Rift: Co-op Dungeon (Phase 3).
	Implements DAG validation (cycle detection, prerequisite integrity, duplicate checks).
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)
local CardData = require(Shared:WaitForChild("CardData") :: ModuleScript)

local PassiveData = {}

--------------------------------------------------------------------------------
-- Exported Types
--------------------------------------------------------------------------------

export type PassiveNodeType = "Stat" | "Notable" | "Keystone"

export type PassiveNodeDefinition = {
	Id: string,
	Name: string,
	Description: string,
	ClassId: string,
	Type: PassiveNodeType,
	Tier: number,
	Cost: number,
	Prerequisites: { string },
	Modifiers: { StateTypes.Modifier },
	Effects: { CardData.Effect }?,
}

--------------------------------------------------------------------------------
-- Master Passive Node Registry (Phase 3 Foundation)
--------------------------------------------------------------------------------

local NODE_REGISTRY: { [string]: PassiveNodeDefinition } = {
	-- 1. Tier 1 Root Node: Iron Skin (+15 MaxHP)
	["Warlord_IronSkin"] = {
		Id = "Warlord_IronSkin",
		Name = "Iron Skin",
		Description = "Hardened resilience increases maximum HP by 15.",
		ClassId = "Warlord",
		Type = "Stat",
		Tier = 1,
		Cost = 1,
		Prerequisites = {},
		Modifiers = {
			{
				Id = "mod_ironskin_hp",
				Source = "Warlord_IronSkin",
				Stat = "MaxHP",
				Operation = "Add",
				Value = 15,
				Priority = 100,
			},
		},
	},

	-- 2. Tier 2a Branch Node: Juggernaut Prowess (+4 ShieldGain)
	["Warlord_JuggernautProwess"] = {
		Id = "Warlord_JuggernautProwess",
		Name = "Juggernaut Prowess",
		Description = "Reinforces defensive postures, granting +4 bonus shield gain.",
		ClassId = "Warlord",
		Type = "Notable",
		Tier = 2,
		Cost = 1,
		Prerequisites = { "Warlord_IronSkin" },
		Modifiers = {
			{
				Id = "mod_juggernaut_shield",
				Source = "Warlord_JuggernautProwess",
				Stat = "ShieldGain",
				Operation = "Add",
				Value = 4,
				Priority = 100,
			},
		},
	},

	-- 3. Tier 2b Branch Node: Heavy Strikes (+3 Damage)
	["Warlord_HeavyStrikes"] = {
		Id = "Warlord_HeavyStrikes",
		Name = "Heavy Strikes",
		Description = "Channels brute momentum, granting +3 bonus attack damage.",
		ClassId = "Warlord",
		Type = "Notable",
		Tier = 2,
		Cost = 1,
		Prerequisites = { "Warlord_IronSkin" },
		Modifiers = {
			{
				Id = "mod_heavy_strikes_dmg",
				Source = "Warlord_HeavyStrikes",
				Stat = "Damage",
				Operation = "Add",
				Value = 3,
				Priority = 100,
			},
		},
	},

	-- 4. Tier 3 Keystone: Titan Stance (+6 Damage, +6 ShieldGain, -1 MaxEnergy)
	["Warlord_TitanStance"] = {
		Id = "Warlord_TitanStance",
		Name = "Titan Stance",
		Description = "Assume an immovable titan stance: +6 damage, +6 shield gain, but -1 maximum energy.",
		ClassId = "Warlord",
		Type = "Keystone",
		Tier = 3,
		Cost = 2,
		Prerequisites = { "Warlord_JuggernautProwess", "Warlord_HeavyStrikes" },
		Modifiers = {
			{
				Id = "mod_titan_dmg",
				Source = "Warlord_TitanStance",
				Stat = "Damage",
				Operation = "Add",
				Value = 6,
				Priority = 100,
			},
			{
				Id = "mod_titan_shield",
				Source = "Warlord_TitanStance",
				Stat = "ShieldGain",
				Operation = "Add",
				Value = 6,
				Priority = 100,
			},
			{
				Id = "mod_titan_energy",
				Source = "Warlord_TitanStance",
				Stat = "MaxEnergy",
				Operation = "Add",
				Value = -1,
				Priority = 100,
			},
		},
	},
}

--------------------------------------------------------------------------------
-- Public Query Methods
--------------------------------------------------------------------------------

-- Fetches a passive node definition by Id
function PassiveData.getNode(nodeId: string): PassiveNodeDefinition?
	return NODE_REGISTRY[nodeId]
end

-- Returns all registered passive nodes
function PassiveData.getAllNodes(): { [string]: PassiveNodeDefinition }
	return NODE_REGISTRY
end

-- Returns all nodes belonging to a class
function PassiveData.getNodesForClass(classId: string): { PassiveNodeDefinition }
	local result: { PassiveNodeDefinition } = {}
	for _, node in NODE_REGISTRY do
		if node.ClassId == classId then
			table.insert(result, node)
		end
	end
	return result
end

--------------------------------------------------------------------------------
-- DAG Graph Validation
--------------------------------------------------------------------------------

-- Validates an arbitrary collection of passive nodes for DAG compliance
function PassiveData.validateNodes(nodes: { PassiveNodeDefinition }): (boolean, string?)
	local nodeMap: { [string]: PassiveNodeDefinition } = {}
	local seenIds: { [string]: boolean } = {}

	-- 1. Check for duplicate IDs and build map
	for _, node in nodes do
		if seenIds[node.Id] then
			return false, string.format("Duplicate node Id '%s' detected.", node.Id)
		end
		seenIds[node.Id] = true
		nodeMap[node.Id] = node
	end

	-- 2. Check for broken / missing prerequisites
	for _, node in nodes do
		for _, prereqId in node.Prerequisites do
			if prereqId == node.Id then
				return false, string.format("Node '%s' cannot have itself as a prerequisite (self-cycle).", node.Id)
			end
			if not nodeMap[prereqId] then
				return false, string.format("Node '%s' references missing prerequisite '%s'.", node.Id, prereqId)
			end
		end
	end

	-- 3. Check for cycles using DFS cycle detection
	local visited: { [string]: boolean } = {}
	local inStack: { [string]: boolean } = {}

	local function dfs(nodeId: string): (boolean, string?)
		visited[nodeId] = true
		inStack[nodeId] = true

		local node = nodeMap[nodeId]
		if node then
			for _, prereqId in node.Prerequisites do
				if not visited[prereqId] then
					local ok, err = dfs(prereqId)
					if not ok then return false, err end
				elseif inStack[prereqId] then
					return false, string.format("Cycle detected in passive tree involving '%s' and '%s'.", nodeId, prereqId)
				end
			end
		end

		inStack[nodeId] = false
		return true, nil
	end

	for _, node in nodes do
		if not visited[node.Id] then
			local ok, err = dfs(node.Id)
			if not ok then return false, err end
		end
	end

	return true, nil
end

-- Validates that a given class's passive tree forms a valid DAG
function PassiveData.validateTree(classId: string): (boolean, string?)
	local classNodes = PassiveData.getNodesForClass(classId)
	if #classNodes == 0 then
		return false, string.format("No passive nodes registered for class '%s'.", classId)
	end
	return PassiveData.validateNodes(classNodes)
end

return PassiveData
