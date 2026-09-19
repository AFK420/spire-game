--!strict

--[=[
	DeckService ModuleScript
	Mapped to: ServerScriptService.Server.services.DeckService
	Authoritative manager for persistent player decks and deck-slot entitlements:
	- Server-generated Deck IDs (client cannot choose arbitrary persistent DeckId)
	- Enforces configurable deck-slot entitlement (BaseDeckSlots + AdditionalDeckSlots)
	- Enforces strict authoritative deck validation (owned copies, deck size, copy limits)
	- Authoritative CRUD (Create, Rename, Delete, Duplicate, Save/Update, List, Get)
	- Active Deck Selection with robust fallback logic
	- Serializable DTO view transformers for Deck Builder UI
]=]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)
local GameConfig = require(Shared:WaitForChild("GameConfig") :: ModuleScript)
local CardData = require(Shared:WaitForChild("CardData") :: ModuleScript)
local ClassData = require(Shared:WaitForChild("ClassData") :: ModuleScript)

local servicesFolder = script.Parent
local PersistenceService = require(servicesFolder:WaitForChild("PersistenceService") :: ModuleScript)
local CardCollectionService = require(servicesFolder:WaitForChild("CardCollectionService") :: ModuleScript)

local RunManager: any = nil
local function getRunManager(): any
	if not RunManager then
		local rmMod = servicesFolder:FindFirstChild("RunManager")
		if rmMod then
			RunManager = require(rmMod :: ModuleScript)
		end
	end
	return RunManager
end

local DeckService = {}

local function deepCopy<T>(original: T): T
	if typeof(original) ~= "table" then return original end
	local copy = {}
	for k, v in (original :: any) do
		copy[k] = deepCopy(v)
	end
	return (copy :: any) :: T
end

local function trim(s: string): string
	return s:match("^%s*(.-)%s*$") or ""
end

-- Counts total individual card copies in a deck dictionary
local function countTotalCards(cards: { [string]: number }): number
	local total = 0
	for _, count in cards do
		if count > 0 then
			total += count
		end
	end
	return total
end

--------------------------------------------------------------------------------
-- 1. Slot Entitlement Queries
--------------------------------------------------------------------------------

-- Returns detailed deck slot capacity information for a player
function DeckService.getSlotEntitlement(player: any): StateTypes.DeckSlotView
	local profile = PersistenceService.getProfile(player)
	if not profile then
		return {
			BaseSlots = GameConfig.Deck.BaseDeckSlots,
			AdditionalSlots = 0,
			TotalSlots = GameConfig.Deck.BaseDeckSlots,
			UsedSlots = 0,
			AvailableSlots = 0,
		}
	end

	local baseSlots = profile.DeckSlotEntitlement.BaseDeckSlots or GameConfig.Deck.BaseDeckSlots
	local addSlots = profile.DeckSlotEntitlement.AdditionalDeckSlots or 0
	local totalSlots = math.min(GameConfig.Deck.MaxDeckSlots, baseSlots + addSlots)

	local usedSlots = 0
	for _ in profile.Decks do
		usedSlots += 1
	end

	local availableSlots = math.max(0, totalSlots - usedSlots)

	return {
		BaseSlots = baseSlots,
		AdditionalSlots = addSlots,
		TotalSlots = totalSlots,
		UsedSlots = usedSlots,
		AvailableSlots = availableSlots,
	}
end

-- Checks if a player has available deck slot capacity
function DeckService.checkSlotAvailability(player: any): boolean
	local info = DeckService.getSlotEntitlement(player)
	return info.AvailableSlots > 0
end

--------------------------------------------------------------------------------
-- 2. Authoritative Deck Validation Layer
--------------------------------------------------------------------------------

-- Validates a candidate deck against player collection, card limits, and size rules
function DeckService.validateDeck(player: any, cards: { [string]: number }, classId: string?): (boolean, string?)
	if typeof(cards) ~= "table" then
		return false, "Deck cards payload must be a table."
	end

	-- Class requirement check (if provided)
	if classId and typeof(classId) == "string" and #classId > 0 then
		if not ClassData.getClass(classId) then
			return false, string.format("Unknown class ID '%s' bound to deck.", classId)
		end
	end

	local totalCards = 0

	for cardDefId, count in cards do
		if typeof(cardDefId) ~= "string" or #cardDefId == 0 then
			return false, "Card definition ID must be a non-empty string."
		end

		local cardDef = CardData.getCard(cardDefId)
		if not cardDef then
			return false, string.format("Unknown card definition '%s'.", tostring(cardDefId))
		end

		if typeof(count) ~= "number" or count <= 0 or count ~= math.floor(count) then
			return false, string.format("Invalid card quantity %s for '%s': must be a positive integer.", tostring(count), cardDefId)
		end

		-- Enforce maximum copies per deck rule
		if count > GameConfig.Deck.MaxCopiesPerCard then
			return false, string.format("Card '%s' exceeds max copies limit (%d > %d).", cardDefId, count, GameConfig.Deck.MaxCopiesPerCard)
		end

		-- Enforce permanent collection ownership requirement
		local ownedCopies = CardCollectionService.getCardCount(player, cardDefId)
		if count > ownedCopies then
			return false, string.format("Card '%s' exceeds owned copies in collection (%d requested > %d owned).", cardDefId, count, ownedCopies)
		end

		totalCards += count
	end

	-- Enforce deck size constraints
	if totalCards < GameConfig.Deck.MinDeckSize then
		return false, string.format("Deck has too few cards (%d < %d minimum).", totalCards, GameConfig.Deck.MinDeckSize)
	end

	if totalCards > GameConfig.Deck.MaxDeckSize then
		return false, string.format("Deck has too many cards (%d > %d maximum).", totalCards, GameConfig.Deck.MaxDeckSize)
	end

	return true, nil
end

--------------------------------------------------------------------------------
-- 3. Authoritative Deck CRUD Operations
--------------------------------------------------------------------------------

-- Creates a new persistent deck with a server-generated GUID
function DeckService.createDeck(
	player: any,
	name: string,
	cards: { [string]: number }?,
	classId: string?
): (boolean, string?, StateTypes.SavedDeck?)
	local rm = getRunManager()
	if rm and rm.isRunActiveForPlayer and rm.isRunActiveForPlayer(player) then
		return false, "Cannot modify decks during an active run.", nil
	end

	if typeof(name) ~= "string" then
		return false, "Deck name must be a string.", nil
	end

	local trimmedName = trim(name)
	if #trimmedName == 0 then
		return false, "Deck name cannot be empty.", nil
	end
	if #trimmedName > GameConfig.Deck.MaxDeckNameLength then
		return false, string.format("Deck name exceeds max length (%d > %d).", #trimmedName, GameConfig.Deck.MaxDeckNameLength), nil
	end

	if not DeckService.checkSlotAvailability(player) then
		return false, "Deck slot entitlement limit reached. Cannot create additional decks.", nil
	end

	local deckCards: { [string]: number } = {}
	if cards and next(cards) ~= nil then
		local ok, err = DeckService.validateDeck(player, cards, classId)
		if not ok then
			return false, err, nil
		end
		deckCards = deepCopy(cards)
	end

	local now = os.time()
	local userId = player.UserId
	local deckId = string.format("deck_%d_%d_%s", userId, now, HttpService:GenerateGUID(false):sub(1, 8))

	local newDeck: StateTypes.SavedDeck = {
		DeckId = deckId,
		Name = trimmedName,
		Cards = deckCards,
		ClassId = classId,
		CreatedAt = now,
		UpdatedAt = now,
	}

	local mutateOk, mutateErr = PersistenceService.mutateProfile(player, function(profile)
		profile.Decks[deckId] = newDeck
		if profile.ActiveDeckId == nil then
			profile.ActiveDeckId = deckId
		end
		return true, nil
	end)

	if not mutateOk then
		return false, mutateErr, nil
	end

	return true, nil, deepCopy(newDeck)
end

-- Renames an existing persistent deck
function DeckService.renameDeck(player: any, deckId: string, newName: string): (boolean, string?)
	if typeof(deckId) ~= "string" or #deckId == 0 then
		return false, "Invalid deck ID: must be non-empty string."
	end

	local rm = getRunManager()
	if rm and rm.isRunActiveForPlayer and rm.isRunActiveForPlayer(player) then
		return false, "Cannot modify decks during an active run."
	end

	if typeof(newName) ~= "string" then
		return false, "Deck name must be a string."
	end

	local trimmedName = trim(newName)
	if #trimmedName == 0 then
		return false, "Deck name cannot be empty."
	end
	if #trimmedName > GameConfig.Deck.MaxDeckNameLength then
		return false, string.format("Deck name exceeds max length (%d > %d).", #trimmedName, GameConfig.Deck.MaxDeckNameLength)
	end

	return PersistenceService.mutateProfile(player, function(profile)
		local deck = profile.Decks[deckId]
		if not deck then
			return false, string.format("Deck '%s' not found.", deckId)
		end

		deck.Name = trimmedName
		deck.UpdatedAt = os.time()
		return true, nil
	end)
end

-- Deletes a persistent deck with strict server-authoritative rules
function DeckService.deleteDeck(player: any, deckId: string): (boolean, string?)
	if typeof(deckId) ~= "string" or #deckId == 0 then
		return false, "Invalid deck ID: must be non-empty string."
	end

	local rm = getRunManager()
	if rm and rm.isRunActiveForPlayer and rm.isRunActiveForPlayer(player) then
		return false, "Cannot modify decks during an active run."
	end

	local profile = PersistenceService.getProfile(player)
	if not profile then
		return false, "Player profile unavailable."
	end

	if not profile.Decks[deckId] then
		return false, string.format("Deck '%s' not found.", deckId)
	end

	-- Count total decks
	local deckCount = 0
	for _ in profile.Decks do
		deckCount += 1
	end

	-- Rule 1: Reject deleting the only remaining deck
	if deckCount <= 1 then
		return false, "Cannot delete your only deck."
	end

	-- Rule 2: Reject deleting the currently active deck
	if profile.ActiveDeckId == deckId then
		return false, "Cannot delete active deck. Switch active deck first."
	end

	return PersistenceService.mutateProfile(player, function(p)
		if not p.Decks[deckId] then
			return false, string.format("Deck '%s' not found.", deckId)
		end

		local count = 0
		for _ in p.Decks do
			count += 1
		end
		if count <= 1 then
			return false, "Cannot delete your only deck."
		end
		if p.ActiveDeckId == deckId then
			return false, "Cannot delete active deck. Switch active deck first."
		end

		p.Decks[deckId] = nil
		return true, nil
	end)
end

-- Duplicates an existing deck into a new slot
function DeckService.duplicateDeck(
	player: any,
	sourceDeckId: string,
	newName: string?
): (boolean, string?, StateTypes.SavedDeck?)
	if typeof(sourceDeckId) ~= "string" or #sourceDeckId == 0 then
		return false, "Invalid source deck ID: must be non-empty string.", nil
	end

	local rm = getRunManager()
	if rm and rm.isRunActiveForPlayer and rm.isRunActiveForPlayer(player) then
		return false, "Cannot modify decks during an active run.", nil
	end

	if not DeckService.checkSlotAvailability(player) then
		return false, "Deck slot entitlement limit reached. Cannot create duplicate deck.", nil
	end

	local profile = PersistenceService.getProfile(player)
	if not profile then
		return false, "Player profile unavailable.", nil
	end
	local sourceDeck = profile.Decks[sourceDeckId]
	if not sourceDeck then
		return false, string.format("Source deck '%s' not found.", sourceDeckId), nil
	end

	local name = newName
	if not name or #trim(name) == 0 then
		name = sourceDeck.Name .. " (Copy)"
	end
	if #name > GameConfig.Deck.MaxDeckNameLength then
		name = name:sub(1, GameConfig.Deck.MaxDeckNameLength)
	end

	return DeckService.createDeck(player, name, sourceDeck.Cards, sourceDeck.ClassId)
end

-- Updates cards inside an existing persistent deck
function DeckService.saveDeck(player: any, deckId: string, cards: { [string]: number }): (boolean, string?)
	if typeof(deckId) ~= "string" or #deckId == 0 then
		return false, "Invalid deck ID: must be non-empty string."
	end

	local rm = getRunManager()
	if rm and rm.isRunActiveForPlayer and rm.isRunActiveForPlayer(player) then
		return false, "Cannot modify decks during an active run."
	end

	local profile = PersistenceService.getProfile(player)
	if not profile then
		return false, "Player profile unavailable."
	end
	local existingDeck = profile.Decks[deckId]
	if not existingDeck then
		return false, string.format("Deck '%s' not found.", deckId)
	end

	local ok, err = DeckService.validateDeck(player, cards, existingDeck.ClassId)
	if not ok then
		return false, err
	end

	return PersistenceService.mutateProfile(player, function(p)
		local deck = p.Decks[deckId]
		if not deck then
			return false, string.format("Deck '%s' not found.", deckId)
		end

		deck.Cards = deepCopy(cards)
		deck.UpdatedAt = os.time()
		return true, nil
	end)
end

-- Retrieves a single saved deck by ID
function DeckService.getDeck(player: any, deckId: string): StateTypes.SavedDeck?
	if typeof(deckId) ~= "string" or #deckId == 0 then
		return nil
	end
	local profile = PersistenceService.getProfile(player)
	if not profile then return nil end
	local deck = profile.Decks[deckId]
	if not deck then return nil end
	return deepCopy(deck)
end

-- Lists all saved decks owned by the player, sorted deterministically
function DeckService.listDecks(player: any): { StateTypes.SavedDeck }
	local profile = PersistenceService.getProfile(player)
	if not profile then return {} end
	local list: { StateTypes.SavedDeck } = {}

	for _, deck in profile.Decks do
		table.insert(list, deepCopy(deck))
	end

	table.sort(list, function(a, b)
		if a.CreatedAt ~= b.CreatedAt then
			return a.CreatedAt < b.CreatedAt
		end
		return a.DeckId < b.DeckId
	end)

	return list
end

--------------------------------------------------------------------------------
-- 4. Active Deck Selection
--------------------------------------------------------------------------------

-- Sets the player's active deck for dungeon runs
function DeckService.setActiveDeck(player: any, deckId: string): (boolean, string?)
	if typeof(deckId) ~= "string" or #deckId == 0 then
		return false, "Invalid deck ID: must be non-empty string."
	end

	local rm = getRunManager()
	if rm and rm.isRunActiveForPlayer and rm.isRunActiveForPlayer(player) then
		return false, "Cannot modify decks during an active run."
	end

	local profile = PersistenceService.getProfile(player)
	if not profile then
		return false, "Player profile unavailable."
	end
	local deck = profile.Decks[deckId]
	if not deck then
		return false, string.format("Deck '%s' not found.", deckId)
	end

	-- Verify that the selected deck is currently valid and playable
	local validOk, validErr = DeckService.validateDeck(player, deck.Cards, deck.ClassId)
	if not validOk then
		return false, string.format("Cannot select invalid deck: %s", tostring(validErr))
	end

	return PersistenceService.mutateProfile(player, function(p)
		p.ActiveDeckId = deckId
		return true, nil
	end)
end

-- Returns the player's active saved deck if valid; otherwise finds a valid fallback deck, or returns nil
function DeckService.getActiveDeck(player: any): StateTypes.SavedDeck?
	local profile = PersistenceService.getProfile(player)
	if not profile then return nil end
	local activeId = profile.ActiveDeckId

	-- 1. If active deck exists, check if it is structurally and playably valid
	if activeId and profile.Decks[activeId] then
		local candidate = profile.Decks[activeId]
		local isValid, _ = DeckService.validateDeck(player, candidate.Cards, candidate.ClassId)
		if isValid then
			return deepCopy(candidate)
		end
	end

	-- 2. Otherwise, deterministically find a valid fallback deck
	local sortedDecks = DeckService.listDecks(player)
	for _, deck in sortedDecks do
		if deck.DeckId ~= activeId then
			local isValid, _ = DeckService.validateDeck(player, deck.Cards, deck.ClassId)
			if isValid then
				return deepCopy(deck)
			end
		end
	end

	-- 3. If no valid saved deck exists, return nil (ClassService will use default class starter deck)
	return nil
end

--------------------------------------------------------------------------------
-- 5. Client View / DTO Transformers
--------------------------------------------------------------------------------

function DeckService.toDeckSummaryView(player: any, deck: StateTypes.SavedDeck): StateTypes.DeckSummaryView
	local isValid, _ = DeckService.validateDeck(player, deck.Cards, deck.ClassId)
	return {
		DeckId = deck.DeckId,
		Name = deck.Name,
		Cards = deepCopy(deck.Cards),
		CardCount = countTotalCards(deck.Cards),
		ClassId = deck.ClassId,
		CreatedAt = deck.CreatedAt,
		UpdatedAt = deck.UpdatedAt,
		IsValid = isValid,
	}
end

function DeckService.toDeckDetailView(player: any, deck: StateTypes.SavedDeck): StateTypes.DeckDetailView
	local isValid, err = DeckService.validateDeck(player, deck.Cards, deck.ClassId)
	local errors = nil
	if not isValid and err then
		errors = { err }
	end

	return {
		DeckId = deck.DeckId,
		Name = deck.Name,
		Cards = deepCopy(deck.Cards),
		CardCount = countTotalCards(deck.Cards),
		ClassId = deck.ClassId,
		CreatedAt = deck.CreatedAt,
		UpdatedAt = deck.UpdatedAt,
		IsValid = isValid,
		ValidationErrors = errors,
	}
end

function DeckService.init()
	print("[DeckService] Initialized authoritative Deck & Slot Management subsystem.")
end

return DeckService
