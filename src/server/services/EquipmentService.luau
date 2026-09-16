--!strict
--[=[
	EquipmentService ModuleScript
	Mapped to: ServerScriptService.Server.services.EquipmentService

	Authoritative equipment engine for Card Rift: Co-op Dungeon (Phase 3):
	1. Instantiates runtime EquipmentInstance objects from immutable EquipmentDefinitions.
	2. Validates server-authoritative equip and unequip lifecycle transitions.
	3. Enforces single-slot occupancy and returns replaced gear to inventory.
	4. Synthesizes and collects deterministic modifiers for StatResolver and ModifierResolver.
]=]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)
local EquipmentData = require(Shared:WaitForChild("EquipmentData") :: ModuleScript)

local EquipmentService = {}

-- Creates a new runtime instance of an equipment item
function EquipmentService.createInstance(definitionId: string, ownerUserId: number): StateTypes.EquipmentInstance?
	local def = EquipmentData.getEquipment(definitionId)
	if not def then
		warn(string.format("[EquipmentService] Unknown equipment definition '%s'.", definitionId))
		return nil
	end

	local guid = string.gsub(HttpService:GenerateGUID(false), "-", ""):sub(1, 12)
	local instanceId = string.format("equip_%s_%s", definitionId, guid)

	local instance: StateTypes.EquipmentInstance = {
		InstanceId = instanceId,
		DefinitionId = definitionId,
		OwnerUserId = ownerUserId,
		Slot = def.Slot,
		Level = 1,
		Modifiers = nil,
	}

	return instance
end

-- Equips an item to the player's appropriate slot, replacing any existing item
function EquipmentService.equipItem(
	playerState: StateTypes.PlayerState,
	equipInst: StateTypes.EquipmentInstance
): (boolean, string?)
	if not playerState then
		return false, "Player state is nil."
	end
	if not equipInst then
		return false, "Equipment instance is nil."
	end

	-- Ownership verification
	if equipInst.OwnerUserId ~= playerState.UserId then
		return false, "Cannot equip an item owned by another player."
	end

	-- Definition verification
	local def = EquipmentData.getEquipment(equipInst.DefinitionId)
	if not def then
		return false, string.format("Unknown equipment definition '%s'.", equipInst.DefinitionId)
	end

	local slot = equipInst.Slot
	if slot ~= "Weapon" and slot ~= "Armor" and slot ~= "Accessory" then
		return false, string.format("Invalid equipment slot '%s'.", tostring(slot))
	end

	if not playerState.EquippedItems then
		playerState.EquippedItems = {}
	end
	if not playerState.EquipmentInventory then
		playerState.EquipmentInventory = {}
	end

	-- Handle slot conflict: if another item is already equipped, move it to inventory
	local currentEquipped = playerState.EquippedItems[slot]
	if currentEquipped then
		table.insert(playerState.EquipmentInventory, currentEquipped)
		playerState.EquippedItems[slot] = nil
	end

	-- Remove the item being equipped from inventory if present
	for idx, item in ipairs(playerState.EquipmentInventory) do
		if item.InstanceId == equipInst.InstanceId then
			table.remove(playerState.EquipmentInventory, idx)
			break
		end
	end

	playerState.EquippedItems[slot] = equipInst
	return true, nil
end

-- Unequips the item from the specified slot and moves it to inventory
function EquipmentService.unequipItem(
	playerState: StateTypes.PlayerState,
	slot: StateTypes.EquipmentSlot
): (boolean, string?)
	if not playerState then
		return false, "Player state is nil."
	end

	if not playerState.EquippedItems then
		playerState.EquippedItems = {}
	end
	if not playerState.EquipmentInventory then
		playerState.EquipmentInventory = {}
	end

	local current = playerState.EquippedItems[slot]
	if not current then
		return false, string.format("No equipment currently equipped in slot '%s'.", tostring(slot))
	end

	playerState.EquippedItems[slot] = nil
	table.insert(playerState.EquipmentInventory, current)
	return true, nil
end

-- Collects all active modifiers contributed by the player's equipped gear
function EquipmentService.collectModifiers(playerState: StateTypes.PlayerState): { StateTypes.Modifier }
	local modifiers: { StateTypes.Modifier } = {}

	if not playerState or not playerState.EquippedItems then
		return modifiers
	end

	for slot, item in playerState.EquippedItems do
		local def = EquipmentData.getEquipment(item.DefinitionId)
		if def then
			-- Synthesize additive stat modifiers from BaseStats
			for statName, statVal in def.BaseStats do
				local modStat: StateTypes.ModifierStat? = nil
				if statName == "Damage" then
					modStat = "Damage"
				elseif statName == "MaxHP" then
					modStat = "MaxHP"
				elseif statName == "ShieldGain" then
					modStat = "ShieldGain"
				elseif statName == "MaxEnergy" then
					modStat = "MaxEnergy"
				elseif statName == "CritChance" then
					modStat = "CritChance"
				elseif statName == "CritMultiplier" then
					modStat = "CritMultiplier"
				elseif statName == "Healing" then
					modStat = "Healing"
				end

				if modStat then
					table.insert(modifiers, {
						Id = string.format("equip_%s_%s", item.InstanceId, statName),
						Source = string.format("Equipment:%s", def.Id),
						Stat = modStat,
						Operation = "Add",
						Value = statVal,
						Condition = nil,
						Priority = 50, -- Equipment base stats apply early in additive layer
					})
				end
			end

			-- Include definition modifiers if present
			if def.Modifiers then
				for _, mod in def.Modifiers do
					table.insert(modifiers, mod)
				end
			end
		end

		-- Include rolled instance modifiers if present
		if item.Modifiers then
			for _, mod in item.Modifiers do
				table.insert(modifiers, mod)
			end
		end
	end

	return modifiers
end

function EquipmentService.init()
	print("[EquipmentService] Initialized authoritative equipment foundation.")
end

return EquipmentService
