--!strict

--[=[
	PersistenceService ModuleScript
	Mapped to: ServerScriptService.Server.services.PersistenceService
	Handles persistent DataStore storage for versioned permanent player profiles:
	- ProfileVersion (v1)
	- Meta currencies (Aether Shards, Premium Currency placeholder)
	- Canonical unlocked classes
	- Lifetime run statistics
	- Permanent Card Collection (definition ownership and copy counts)
	- Persistent Saved Decks and Deck Slot Entitlements
	- Active Deck Selection for runs
	- Placeholders for future EquipmentCollection and GachaBanners schemas
]=]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)
local GameConfig = require(Shared:WaitForChild("GameConfig") :: ModuleScript)
local CardData = require(Shared:WaitForChild("CardData") :: ModuleScript)

local PersistenceService = {}

export type PlayerProfile = StateTypes.PlayerProfile
export type SavedDeck = StateTypes.SavedDeck

local DATA_STORE_NAME = "CardRift_PlayerProfiles_v3"
local AUTOSAVE_INTERVAL = 300
local CURRENT_PROFILE_VERSION = 1

local activeProfiles: { [number]: StateTypes.PlayerProfile } = {} -- Keyed by UserId

local function deepCopy<T>(original: T): T
	if typeof(original) ~= "table" then return original end
	local copy = {}
	for k, v in (original :: any) do
		copy[k] = deepCopy(v)
	end
	return (copy :: any) :: T
end

-- Generates a valid server-side default starter deck
local function createDefaultStarterDeck(userId: number): StateTypes.SavedDeck
	local now = os.time()
	local deckId = string.format("deck_%d_starter_%s", userId, HttpService:GenerateGUID(false):sub(1, 8))
	local starterCards = deepCopy(GameConfig.StarterCollection.DefaultDeckCards)

	return {
		DeckId = deckId,
		Name = GameConfig.StarterCollection.DefaultDeckName,
		Cards = starterCards,
		ClassId = GameConfig.StarterCollection.DefaultDeckClass,
		CreatedAt = now,
		UpdatedAt = now,
	}
end

-- Robust, deterministic reconcile and schema migration pipeline
local function reconcile(data: any, userId: number): StateTypes.PlayerProfile
	local now = os.time()

	-- Baseline default structure
	local profile: StateTypes.PlayerProfile = {
		ProfileVersion = CURRENT_PROFILE_VERSION,
		AetherShards = 0,
		PremiumCurrency = 0,
		UnlockedClasses = { "Warlord", "Shadowblade", "AetherMage", "Necrobinder", "Mechanist" },
		TotalVictories = 0,
		TotalRuns = 0,
		LastSavedTimestamp = now,
		CardCollection = {},
		Decks = {},
		ActiveDeckId = nil,
		DeckSlotEntitlement = {
			BaseDeckSlots = GameConfig.Deck.BaseDeckSlots,
			AdditionalDeckSlots = 0,
		},
		UnlockedSkills = {},
		EquipmentCollection = {},
		GachaBanners = {},
	}

	-- New account (no saved data)
	if typeof(data) ~= "table" then
		-- Grant starter collection
		for cardId, count in GameConfig.StarterCollection.DefaultCards do
			profile.CardCollection[cardId] = count
		end

		-- Create default starter deck
		local starterDeck = createDefaultStarterDeck(userId)
		profile.Decks[starterDeck.DeckId] = starterDeck
		profile.ActiveDeckId = starterDeck.DeckId
		return profile
	end

	-- 1. Currencies and Statistics (strict non-negativity)
	if typeof(data.AetherShards) == "number" then
		profile.AetherShards = math.max(0, math.floor(data.AetherShards))
	end
	if typeof(data.PremiumCurrency) == "number" then
		profile.PremiumCurrency = math.max(0, math.floor(data.PremiumCurrency))
	end
	if typeof(data.TotalVictories) == "number" then
		profile.TotalVictories = math.max(0, math.floor(data.TotalVictories))
	end
	if typeof(data.TotalRuns) == "number" then
		profile.TotalRuns = math.max(0, math.floor(data.TotalRuns))
	end

	-- 2. Unlocked Classes
	if typeof(data.UnlockedClasses) == "table" then
		local validClasses: { string } = {}
		local seenClass: { [string]: boolean } = {}
		for _, c in data.UnlockedClasses do
			if typeof(c) == "string" and #c > 0 and not seenClass[c] then
				seenClass[c] = true
				table.insert(validClasses, c)
			end
		end
		if #validClasses > 0 then
			profile.UnlockedClasses = validClasses
		end
	end

	-- 3. Permanent Card Collection (definitions and positive quantities)
	if typeof(data.CardCollection) == "table" then
		for cardId, count in data.CardCollection do
			if typeof(cardId) == "string" and typeof(count) == "number" then
				-- Verify definition exists in CardData
				local cardDef = CardData.getCard(cardId)
				if cardDef and count > 0 then
					profile.CardCollection[cardId] = math.floor(count)
				end
			end
		end
	end
	-- If migrating from v0 where CardCollection was absent, seed starter collection
	if next(profile.CardCollection) == nil then
		for cardId, count in GameConfig.StarterCollection.DefaultCards do
			profile.CardCollection[cardId] = count
		end
	end

	-- 4. Deck Slot Entitlement
	if typeof(data.DeckSlotEntitlement) == "table" then
		local addSlots = data.DeckSlotEntitlement.AdditionalDeckSlots
		if typeof(addSlots) == "number" then
			profile.DeckSlotEntitlement.AdditionalDeckSlots = math.max(0, math.floor(addSlots))
		end
	end

	-- 5. Saved Decks
	if typeof(data.Decks) == "table" then
		for deckId, rawDeck in data.Decks do
			if typeof(deckId) == "string" and #deckId > 0 and typeof(rawDeck) == "table" then
				local name = typeof(rawDeck.Name) == "string" and rawDeck.Name or "Custom Deck"
				if #name > GameConfig.Deck.MaxDeckNameLength then
					name = name:sub(1, GameConfig.Deck.MaxDeckNameLength)
				end

				local cards: { [string]: number } = {}
				if typeof(rawDeck.Cards) == "table" then
					for cId, q in rawDeck.Cards do
						if typeof(cId) == "string" and typeof(q) == "number" and q > 0 then
							cards[cId] = math.floor(q)
						end
					end
				end

				local cAt = typeof(rawDeck.CreatedAt) == "number" and rawDeck.CreatedAt or now
				local uAt = typeof(rawDeck.UpdatedAt) == "number" and rawDeck.UpdatedAt or now

				profile.Decks[deckId] = {
					DeckId = deckId,
					Name = name,
					Cards = cards,
					ClassId = typeof(rawDeck.ClassId) == "string" and rawDeck.ClassId or nil,
					CreatedAt = cAt,
					UpdatedAt = uAt,
				}
			end
		end
	end
	-- If migrating from v0 or no decks exist, seed starter deck
	if next(profile.Decks) == nil then
		local starterDeck = createDefaultStarterDeck(userId)
		profile.Decks[starterDeck.DeckId] = starterDeck
		profile.ActiveDeckId = starterDeck.DeckId
	else
		-- 6. Active Deck Selection
		if typeof(data.ActiveDeckId) == "string" and profile.Decks[data.ActiveDeckId] then
			profile.ActiveDeckId = data.ActiveDeckId
		else
			-- Fallback to first available deck
			local firstDeckId = next(profile.Decks)
			profile.ActiveDeckId = firstDeckId
		end
	end

	-- 7. Unlocked Skills
	if typeof(data.UnlockedSkills) == "table" then
		for sId, unlocked in data.UnlockedSkills do
			if typeof(sId) == "string" and unlocked == true then
				profile.UnlockedSkills[sId] = true
			end
		end
	end

	-- 8. Schemas for future equipment and gacha
	if typeof(data.EquipmentCollection) == "table" then
		profile.EquipmentCollection = data.EquipmentCollection
	end
	if typeof(data.GachaBanners) == "table" then
		profile.GachaBanners = data.GachaBanners
	end

	return profile
end

local profileStore: any = nil
pcall(function()
	profileStore = DataStoreService:GetDataStore(DATA_STORE_NAME)
end)

function PersistenceService.loadProfile(player: Player): StateTypes.PlayerProfile
	local userId = player.UserId
	if activeProfiles[userId] then
		return activeProfiles[userId]
	end

	local loadedData = nil
	if profileStore and not RunService:IsStudio() then
		local success, err = pcall(function()
			loadedData = profileStore:GetAsync(tostring(userId))
		end)
		if not success then
			warn(string.format("[PersistenceService] Failed to load data for %s: %s", player.Name, tostring(err)))
		end
	end

	local profile = reconcile(loadedData, userId)
	activeProfiles[userId] = profile
	return profile
end

local function saveProfileInternal(userId: number, profile: StateTypes.PlayerProfile)
	profile.LastSavedTimestamp = os.time()
	if not profileStore or RunService:IsStudio() then return end

	local success, err = pcall(function()
		profileStore:SetAsync(tostring(userId), profile)
	end)
	if not success then
		warn(string.format("[PersistenceService] Failed to save profile for %d: %s", userId, tostring(err)))
	end
end

function PersistenceService.saveProfile(player: any)
	local userId = player.UserId
	local profile = activeProfiles[userId]
	if not profile then return end

	saveProfileInternal(userId, profile)
end

function PersistenceService.getProfile(player: any): StateTypes.PlayerProfile
	local userId = player.UserId
	local profile = activeProfiles[userId]
	if not profile then
		if typeof(player) == "Instance" and player:IsA("Player") then
			return PersistenceService.loadProfile(player)
		else
			-- Synthetic / mock player for testing or headless execution
			local newProfile = reconcile(nil, userId)
			activeProfiles[userId] = newProfile
			return newProfile
		end
	end
	return profile
end

-- Centralized profile mutation wrapper (prevents competing uncoordinated overwrites)
function PersistenceService.mutateProfile(
	player: any,
	mutator: (profile: StateTypes.PlayerProfile) -> (boolean, string?)
): (boolean, string?)
	local profile = PersistenceService.getProfile(player)
	local ok, err = mutator(profile)
	if not ok then
		return false, err
	end
	profile.LastSavedTimestamp = os.time()
	return true, nil
end

-- Currency and Stat Helpers
function PersistenceService.addAetherShards(player: any, amount: number)
	if amount <= 0 then return end
	local profile = PersistenceService.getProfile(player)
	profile.AetherShards += amount
end

function PersistenceService.recordRunStarted(player: any)
	local profile = PersistenceService.getProfile(player)
	profile.TotalRuns += 1
end

function PersistenceService.recordRunVictory(player: any)
	local profile = PersistenceService.getProfile(player)
	profile.TotalVictories += 1
end

function PersistenceService.isClassUnlocked(player: any, classId: string): boolean
	local profile = PersistenceService.getProfile(player)
	for _, unlocked in profile.UnlockedClasses do
		if unlocked == classId then
			return true
		end
	end
	return false
end

function PersistenceService.unlockClass(player: any, classId: string)
	local profile = PersistenceService.getProfile(player)
	if not PersistenceService.isClassUnlocked(player, classId) then
		table.insert(profile.UnlockedClasses, classId)
	end
end

-- Direct testing helper for offline schema migration verification
function PersistenceService.reconcileForTesting(data: any, userId: number?): StateTypes.PlayerProfile
	return reconcile(data, userId or 10001)
end

function PersistenceService.resetForTesting(userId: number?)
	if userId then
		activeProfiles[userId] = nil
	else
		table.clear(activeProfiles)
	end
end

local autosaveThread: thread? = nil

function PersistenceService.init()
	Players.PlayerAdded:Connect(function(p: Player)
		PersistenceService.loadProfile(p)
	end)

	Players.PlayerRemoving:Connect(function(p: Player)
		PersistenceService.saveProfile(p)
		activeProfiles[p.UserId] = nil
	end)

	for _, p in Players:GetPlayers() do
		PersistenceService.loadProfile(p)
	end

	-- Periodic autosave loop running every AUTOSAVE_INTERVAL seconds
	autosaveThread = task.spawn(function()
		while true do
			task.wait(AUTOSAVE_INTERVAL)
			for userId, profile in activeProfiles do
				saveProfileInternal(userId, profile)
			end
		end
	end)

	game:BindToClose(function()
		for userId, profile in activeProfiles do
			saveProfileInternal(userId, profile)
		end
	end)

	print("[PersistenceService] Initialized Versioned DataStore persistence layer (v1) with autosave loop.")
end

return PersistenceService
