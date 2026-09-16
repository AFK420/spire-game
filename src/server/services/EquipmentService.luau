--!strict
--[=[
	EquipmentService ModuleScript
	Mapped to: ServerScriptService.Server.services.EquipmentService

	Authoritative equipment engine for Card Rift: Co-op Dungeon (Phase 3 / 3.1):
	1. Instantiates runtime EquipmentInstance objects from immutable EquipmentDefinitions.
	2. Grants equipment authoritatively into player EquipmentInventory.
	3. Enforces that the authoritative slot strictly matches EquipmentData.getEquipment(definitionId).Slot.
	4. Rejects forged slots, fabricated instances, and unowned/uninventoried equipment.
	5. Enforces single-slot occupancy with safe replacement back to inventory.
	6. Synthesizes and deterministically sorts modifiers for StatResolver.
]=]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)
local EquipmentData = require(Shared:WaitForChild("EquipmentData") :: ModuleScript)

local servicesFolder = script.Parent

local EquipmentService = {}

local VALID_SLOTS: { [string]: boolean } = {
	["Weapon"] = true,
	["Armor"] = true,
	["Accessory"] = true,
}

local ORDERED_SLOTS: { StateTypes.EquipmentSlot } = { "Weapon", "Armor", "Accessory" }

-- Safely resolves StatResolver to trigger derived stat recalculation
local function syncDerivedStats(playerState: StateTypes.PlayerState)
	local mod = servicesFolder:FindFirstChild("StatResolver")
	if mod and mod:IsA("ModuleScript") then
		local StatResolver = require(mod) :: any
		if type(StatResolver.syncPlayerDerivedStats) == "function" then
			StatResolver.syncPlayerDerivedStats(playerState)
		end
	end
end

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

-- Grants an equipment item authoritatively directly into the player's inventory
function EquipmentService.grantEquipment(
	playerState: StateTypes.PlayerState,
	definitionId: string
): StateTypes.EquipmentInstance?
	if not playerState then
		return nil
	end

	local instance = EquipmentService.createInstance(definitionId, playerState.UserId)
	if not instance then
		return nil
	end

	if not playerState.EquipmentInventory then
		playerState.EquipmentInventory = {}
	end

	table.insert(playerState.EquipmentInventory, instance)
	return instance
end

-- Equips an item to the player's authoritative slot, replacing any existing item
-- Accepts either an EquipmentInstance table or an InstanceId string
function EquipmentService.equipItem(
	playerState: StateTypes.PlayerState,
	equipInstOrId: any,
	bypassInventoryCheck: boolean?
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

	local targetInst: StateTypes.EquipmentInstance? = nil
	local invIndex: number? = nil

	if typeof(equipInstOrId) == "string" then
		for idx, item in ipairs(playerState.EquipmentInventory) do
			if item.InstanceId == equipInstOrId then
				targetInst = item
				invIndex = idx
				break
			end
		end
		if not targetInst then
			return false, string.format("Equipment instance '%s' not found in player's inventory.", equipInstOrId)
		end
	elseif typeof(equipInstOrId) == "table" and equipInstOrId.InstanceId then
		targetInst = equipInstOrId :: StateTypes.EquipmentInstance
		for idx, item in ipairs(playerState.EquipmentInventory) do
			if item.InstanceId == targetInst.InstanceId then
				invIndex = idx
				break
			end
		end

		-- Phase 3.1: Enforce that the instance must exist in inventory unless internal bypass is explicitly flagged
		if not invIndex and not bypassInventoryCheck then
			return false, string.format("Equipment instance '%s' not found in player's inventory.", targetInst.InstanceId)
		end
	else
		return false, "Invalid equipment parameter: expected EquipmentInstance or InstanceId string."
	end

	assert(targetInst ~= nil, "Target equipment instance must be resolved.")

	-- 1. Ownership verification
	if targetInst.OwnerUserId ~= playerState.UserId then
		return false, string.format("Cannot equip item owned by user %d on user %d.", targetInst.OwnerUserId, playerState.UserId)
	end

	-- 2. Definition verification
	local def = EquipmentData.getEquipment(targetInst.DefinitionId)
	if not def then
		return false, string.format("Unknown equipment definition '%s'.", targetInst.DefinitionId)
	end

	-- 3. Authoritative Slot Enforcement (Never trust instance.Slot over definition)
	local authSlot = def.Slot
	if not VALID_SLOTS[authSlot] then
		return false, string.format("Definition '%s' has invalid slot '%s'.", def.Id, tostring(authSlot))
	end

	-- Phase 3.1: Reject instances with forged or mismatched slots
	if targetInst.Slot ~= authSlot then
		return false, string.format("Forged slot: item '%s' must be equipped to '%s', but instance claims '%s'.", def.Id, authSlot, tostring(targetInst.Slot))
	end

	-- 4. Duplicate Equipped Instance Check
	for s, equipped in playerState.EquippedItems do
		if equipped and equipped.InstanceId == targetInst.InstanceId then
			return false, string.format("Equipment instance '%s' is already equipped in slot '%s'.", targetInst.InstanceId, s)
		end
	end

	-- 5. Slot conflict: if another item is already equipped in this slot, move it back to inventory
	local currentEquipped = playerState.EquippedItems[authSlot]
	if currentEquipped then
		table.insert(playerState.EquipmentInventory, currentEquipped)
		playerState.EquippedItems[authSlot] = nil
	end

	-- 6. Remove the newly equipped item from inventory
	if invIndex then
		table.remove(playerState.EquipmentInventory, invIndex)
	else
		for idx, item in ipairs(playerState.EquipmentInventory) do
			if item.InstanceId == targetInst.InstanceId then
				table.remove(playerState.EquipmentInventory, idx)
				break
			end
		end
	end

	-- 7. Place in equipped slot
	playerState.EquippedItems[authSlot] = targetInst

	-- 8. Synchronize derived stats
	syncDerivedStats(playerState)

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

	if not VALID_SLOTS[slot] then
		return false, string.format("Invalid equipment slot '%s'.", tostring(slot))
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

	-- Prevent duplicate insertion into inventory
	local alreadyInInv = false
	for _, item in ipairs(playerState.EquipmentInventory) do
		if item.InstanceId == current.InstanceId then
			alreadyInInv = true
			break
		end
	end
	if not alreadyInInv then
		table.insert(playerState.EquipmentInventory, current)
	end

	-- Synchronize derived stats
	syncDerivedStats(playerState)

	return true, nil
end

-- Collects all active modifiers contributed by the player's equipped gear
function EquipmentService.collectModifiers(playerState: StateTypes.PlayerState): { StateTypes.Modifier }
	local modifiers: { StateTypes.Modifier } = {}

	if not playerState or not playerState.EquippedItems then
		return modifiers
	end

	-- Iterate slots deterministically
	for _, slot in ipairs(ORDERED_SLOTS) do
		local item = playerState.EquippedItems[slot]
		if item then
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
	end

	-- Sort all collected modifiers deterministically: Priority ascending, then Id alphabetical
	table.sort(modifiers, function(a, b)
		if a.Priority == b.Priority then
			return a.Id < b.Id
		end
		return a.Priority < b.Priority
	end)

	return modifiers
end

function EquipmentService.init()
	print("[EquipmentService] Initialized authoritative equipment foundation with Phase 3.1 hardening.")
end

return EquipmentService
