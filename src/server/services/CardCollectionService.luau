--!strict

--[=[
	CardCollectionService ModuleScript
	Mapped to: ServerScriptService.Server.services.CardCollectionService
	Authoritative manager for permanent player card collections:
	- CardDefinition ownership and permanent copy counts
	- Authoritative card grants (future gacha / banner integration entry point)
	- Authoritative card deductions (crafting / sacrificial mechanics)
	- Ownership validation and copy count queries
	- Deterministic serialization to CardCollectionView DTOs
	- Strict prevention of client minting and negative quantities
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)
local CardData = require(Shared:WaitForChild("CardData") :: ModuleScript)

local servicesFolder = script.Parent
local PersistenceService = require(servicesFolder:WaitForChild("PersistenceService") :: ModuleScript)

local CardCollectionService = {}

-- Queries the number of permanent copies owned of a specific card definition
function CardCollectionService.getCardCount(player: any, cardDefId: string): number
	if typeof(cardDefId) ~= "string" or #cardDefId == 0 then
		return 0
	end
	local profile = PersistenceService.getProfile(player)
	if not profile then
		return 0
	end
	return profile.CardCollection[cardDefId] or 0
end

-- Checks if a player owns at least 1 copy of a card definition
function CardCollectionService.hasCard(player: any, cardDefId: string): boolean
	return CardCollectionService.getCardCount(player, cardDefId) > 0
end

-- Returns an isolated copy of the player's permanent collection dictionary
function CardCollectionService.getCollection(player: any): { [string]: number }
	local profile = PersistenceService.getProfile(player)
	if not profile then
		return {}
	end
	local copy: { [string]: number } = {}
	for cardId, count in profile.CardCollection do
		if count > 0 then
			copy[cardId] = count
		end
	end
	return copy
end

-- Authoritatively grants copies of a card definition to a player's collection
-- Future Gacha/Banner systems should call this method directly
function CardCollectionService.grantCard(player: any, cardDefId: string, quantity: number): (boolean, string?)
	if typeof(cardDefId) ~= "string" or #cardDefId == 0 then
		return false, "Invalid card definition ID: must be non-empty string."
	end

	local cardDef = CardData.getCard(cardDefId)
	if not cardDef then
		return false, string.format("Unknown card definition '%s'. Cannot grant non-existent card.", tostring(cardDefId))
	end

	if typeof(quantity) ~= "number" or quantity <= 0 or quantity ~= math.floor(quantity) then
		return false, string.format("Invalid grant quantity %s: must be a positive integer.", tostring(quantity))
	end

	local ok, err = PersistenceService.mutateProfile(player, function(profile)
		local current = profile.CardCollection[cardDefId] or 0
		profile.CardCollection[cardDefId] = current + quantity
		return true, nil
	end)

	if not ok then
		return false, err
	end

	return true, nil
end

-- Authoritatively removes copies of a card definition from a player's collection
-- Prevents negative quantities and rejects unauthorized deductions
function CardCollectionService.removeCard(player: any, cardDefId: string, quantity: number): (boolean, string?)
	if typeof(cardDefId) ~= "string" or #cardDefId == 0 then
		return false, "Invalid card definition ID: must be non-empty string."
	end

	if typeof(quantity) ~= "number" or quantity <= 0 or quantity ~= math.floor(quantity) then
		return false, string.format("Invalid remove quantity %s: must be a positive integer.", tostring(quantity))
	end

	local ok, err = PersistenceService.mutateProfile(player, function(profile)
		local current = profile.CardCollection[cardDefId] or 0
		if current < quantity then
			return false, string.format("Insufficient owned copies of '%s'. Owned: %d, Requested: %d.", cardDefId, current, quantity)
		end

		local remaining = current - quantity
		if remaining > 0 then
			profile.CardCollection[cardDefId] = remaining
		else
			profile.CardCollection[cardDefId] = nil
		end
		return true, nil
	end)

	if not ok then
		return false, err
	end

	return true, nil
end

-- Serializes the player's card collection into a client view DTO
function CardCollectionService.toCollectionView(player: any): StateTypes.CardCollectionView
	local collection = CardCollectionService.getCollection(player)
	local uniqueCount = 0
	local totalCopies = 0

	for _, count in collection do
		uniqueCount += 1
		totalCopies += count
	end

	return {
		Cards = collection,
		TotalUniqueCards = uniqueCount,
		TotalCardCopies = totalCopies,
	}
end

function CardCollectionService.init()
	print("[CardCollectionService] Initialized authoritative permanent Card Collection subsystem.")
end

return CardCollectionService
