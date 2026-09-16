--!strict
--[=[
	EquipmentData ModuleScript
	Mapped to: ReplicatedStorage.Shared.EquipmentData
	Defines the canonical equipment catalog and validation rules for Card Rift: Co-op Dungeon (Phase 3).
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)

export type EquipmentSlot = StateTypes.EquipmentSlot
export type EquipmentRarity = StateTypes.EquipmentRarity

export type EquipmentDefinition = {
	Id: string,
	Name: string,
	Description: string,
	Slot: EquipmentSlot,
	Rarity: EquipmentRarity,
	Tags: { string },
	BaseStats: { [string]: number },
	Modifiers: { StateTypes.Modifier }?,
}

local EquipmentData = {}

--------------------------------------------------------------------------------
-- Equipment Catalog (Representative Initial Set)
--------------------------------------------------------------------------------

local IronBroadsword: EquipmentDefinition = {
	Id = "IronBroadsword",
	Name = "Iron Broadsword",
	Description = "A sturdy forged broadsword. Increases attack power and maximum health.",
	Slot = "Weapon",
	Rarity = "Common",
	Tags = { "Melee", "Sword", "Physical" },
	BaseStats = {
		Damage = 5,
		MaxHP = 10,
	},
	Modifiers = nil,
}

local ReinforcedPlate: EquipmentDefinition = {
	Id = "ReinforcedPlate",
	Name = "Reinforced Plate",
	Description = "Heavy steel armor plating that fortifies maximum health and shield gain.",
	Slot = "Armor",
	Rarity = "Uncommon",
	Tags = { "HeavyArmor", "Plate", "Defensive" },
	BaseStats = {
		MaxHP = 20,
		ShieldGain = 4,
	},
	Modifiers = nil,
}

local AmuletOfFocus: EquipmentDefinition = {
	Id = "AmuletOfFocus",
	Name = "Amulet Of Focus",
	Description = "A crystalline amulet that sharpens the mind, expanding maximum energy and critical chance.",
	Slot = "Accessory",
	Rarity = "Rare",
	Tags = { "Trinket", "Amulet", "Focus" },
	BaseStats = {
		MaxEnergy = 1,
		CritChance = 0.05,
	},
	Modifiers = nil,
}

local registry: { [string]: EquipmentDefinition } = {
	IronBroadsword = IronBroadsword,
	ReinforcedPlate = ReinforcedPlate,
	AmuletOfFocus = AmuletOfFocus,
}

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function EquipmentData.getEquipment(id: string): EquipmentDefinition?
	return registry[id]
end

function EquipmentData.getAllEquipment(): { [string]: EquipmentDefinition }
	return registry
end

local VALID_SLOTS: { [string]: boolean } = {
	Weapon = true,
	Armor = true,
	Accessory = true,
}

local VALID_RARITIES: { [string]: boolean } = {
	Common = true,
	Uncommon = true,
	Rare = true,
	Epic = true,
	Legendary = true,
}

function EquipmentData.validateDefinition(def: EquipmentDefinition): (boolean, string?)
	if not def or typeof(def) ~= "table" then
		return false, "Equipment definition is nil or not a table."
	end
	if not def.Id or def.Id == "" then
		return false, "Equipment definition has empty or missing Id."
	end
	if not def.Name or def.Name == "" then
		return false, string.format("Equipment '%s' has empty Name.", def.Id)
	end
	if not VALID_SLOTS[def.Slot] then
		return false, string.format("Equipment '%s' has invalid Slot '%s'.", def.Id, tostring(def.Slot))
	end
	if not VALID_RARITIES[def.Rarity] then
		return false, string.format("Equipment '%s' has invalid Rarity '%s'.", def.Id, tostring(def.Rarity))
	end
	if not def.BaseStats or typeof(def.BaseStats) ~= "table" then
		return false, string.format("Equipment '%s' requires a BaseStats table.", def.Id)
	end
	return true, nil
end

function EquipmentData.validateDefinitions(): (boolean, string?)
	for _, def in registry do
		local ok, err = EquipmentData.validateDefinition(def)
		if not ok then
			return false, err
		end
	end
	return true, nil
end

return EquipmentData
