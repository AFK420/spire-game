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
	- Phase 4.1 Fail-Closed Protection & Concurrency-Safe UpdateAsync
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
local ClassData = require(Shared:WaitForChild("ClassData") :: ModuleScript)

local PersistenceService = {}

export type PlayerProfile = StateTypes.PlayerProfile
export type SavedDeck = StateTypes.SavedDeck
export type ProfileLoadState = "NotLoaded" | "Loaded" | "New" | "LoadFailed" | "Saving"

local DATA_STORE_NAME = "CardRift_PlayerProfiles_v3"
local AUTOSAVE_INTERVAL = 300
local CURRENT_PROFILE_VERSION = 1

local activeProfiles: { [number]: StateTypes.PlayerProfile } = {} -- Keyed by UserId
local profileLoadStates: { [number]: ProfileLoadState } = {}       -- Explicit load state tracking

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

	-- 1. Currencies and Statistics (strict non-negativity and integer checks)
	if typeof(data.AetherShards) == "number" and data.AetherShards == math.floor(data.AetherShards) then
		profile.AetherShards = math.max(0, data.AetherShards)
	end
	if typeof(data.PremiumCurrency) == "number" and data.PremiumCurrency == math.floor(data.PremiumCurrency) then
		profile.PremiumCurrency = math.max(0, data.PremiumCurrency)
	end
	if typeof(data.TotalVictories) == "number" and data.TotalVictories == math.floor(data.TotalVictories) then
		profile.TotalVictories = math.max(0, data.TotalVictories)
	end
	if typeof(data.TotalRuns) == "number" and data.TotalRuns == math.floor(data.TotalRuns) then
		profile.TotalRuns = math.max(0, data.TotalRuns)
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

	-- 3. Permanent Card Collection (definitions and positive integer quantities only)
	if typeof(data.CardCollection) == "table" then
		for cardId, count in data.CardCollection do
			if typeof(cardId) == "string" and typeof(count) == "number" then
				-- Strictly require positive integers (reject fractional values, zeros, and negatives)
				if count > 0 and count == math.floor(count) then
					-- Verify definition exists in CardData
					local cardDef = CardData.getCard(cardId)
					if cardDef then
						profile.CardCollection[cardId] = count
					end
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

	-- 4. Deck Slot Entitlement (bounded non-negative integers)
	if typeof(data.DeckSlotEntitlement) == "table" then
		local baseSlots = data.DeckSlotEntitlement.BaseDeckSlots
		if typeof(baseSlots) == "number" and baseSlots > 0 and baseSlots == math.floor(baseSlots) then
			profile.DeckSlotEntitlement.BaseDeckSlots = math.min(GameConfig.Deck.MaxDeckSlots, baseSlots)
		end
		local addSlots = data.DeckSlotEntitlement.AdditionalDeckSlots
		if typeof(addSlots) == "number" and addSlots >= 0 and addSlots == math.floor(addSlots) then
			profile.DeckSlotEntitlement.AdditionalDeckSlots = math.min(GameConfig.Deck.MaxDeckSlots, addSlots)
		end
	end

	-- 5. Saved Decks
	if typeof(data.Decks) == "table" then
		for deckId, rawDeck in data.Decks do
			if typeof(deckId) == "string" and #deckId > 0 and typeof(rawDeck) == "table" then
				-- Deck name sanitization & deterministic repair
				local rawName = typeof(rawDeck.Name) == "string" and rawDeck.Name or ""
				local trimmedName = trim(rawName)
				if #trimmedName == 0 then
					trimmedName = "Custom Deck" -- Deterministically repair empty name
				elseif #trimmedName > GameConfig.Deck.MaxDeckNameLength then
					trimmedName = trimmedName:sub(1, GameConfig.Deck.MaxDeckNameLength)
				end

				-- ClassId validation against ClassData
				local validClassId: string? = nil
				if typeof(rawDeck.ClassId) == "string" and #rawDeck.ClassId > 0 then
					if ClassData.getClass(rawDeck.ClassId) then
						validClassId = rawDeck.ClassId
					end
				end

				-- Cards sanitization: positive integers and existing CardDefinitions only
				local cards: { [string]: number } = {}
				if typeof(rawDeck.Cards) == "table" then
					for cId, q in rawDeck.Cards do
						if typeof(cId) == "string" and #cId > 0 and typeof(q) == "number" then
							-- Strictly require positive integers (no fractions, no zeros/negatives)
							if q > 0 and q == math.floor(q) then
								local cardDef = CardData.getCard(cId)
								if cardDef then
									cards[cId] = q
								end
							end
						end
					end
				end

				local cAt = typeof(rawDeck.CreatedAt) == "number" and rawDeck.CreatedAt or now
				local uAt = typeof(rawDeck.UpdatedAt) == "number" and rawDeck.UpdatedAt or now

				profile.Decks[deckId] = {
					DeckId = deckId,
					Name = trimmedName,
					Cards = cards,
					ClassId = validClassId,
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

local mockGetAsyncFailure = false

-- Queries the current load state of a player's profile
function PersistenceService.getLoadState(userId: number): ProfileLoadState
	return profileLoadStates[userId] or "NotLoaded"
end

-- Checks if a player's profile is authoritative and ready for gameplay
function PersistenceService.isProfileLoaded(playerOrUserId: any): boolean
	local userId = if typeof(playerOrUserId) == "number" then playerOrUserId else playerOrUserId.UserId
	local state = profileLoadStates[userId]
	return state == "Loaded" or state == "New"
end

-- Loads a player's persistent profile with strict fail-closed protection
function PersistenceService.loadProfile(player: any): StateTypes.PlayerProfile?
	local userId = player.UserId
	if activeProfiles[userId] and (profileLoadStates[userId] == "Loaded" or profileLoadStates[userId] == "New") then
		return activeProfiles[userId]
	end

	local loadFailed = false
	local loadedData = nil

	if mockGetAsyncFailure then
		loadFailed = true
		warn(string.format("[PersistenceService] CRITICAL: Simulated DataStore failure for %s (%d)", tostring(player.Name), userId))
	elseif profileStore and not RunService:IsStudio() then
		local success, err = pcall(function()
			loadedData = profileStore:GetAsync(tostring(userId))
		end)
		if not success then
			loadFailed = true
			warn(string.format("[PersistenceService] CRITICAL: Failed to load DataStore for %s (%d): %s", player.Name, userId, tostring(err)))
		end
	end

	-- FAIL-CLOSED PROTECTION:
	-- If DataStore call failed, DO NOT create a starter profile, DO NOT mark Loaded, DO NOT allow saving.
	if loadFailed then
		profileLoadStates[userId] = "LoadFailed"
		activeProfiles[userId] = nil
		return nil
	end

	if loadedData == nil then
		-- Genuinely new account
		local profile = reconcile(nil, userId)
		profileLoadStates[userId] = "New"
		activeProfiles[userId] = profile
		return profile
	else
		-- Successfully loaded existing account
		local profile = reconcile(loadedData, userId)
		profileLoadStates[userId] = "Loaded"
		activeProfiles[userId] = profile
		return profile
	end
end

-- Concurrency safety: check for conflicting newer session data
function PersistenceService.resolveUpdateConflict(currentData: any, incomingProfile: StateTypes.PlayerProfile): (any, boolean)
	if typeof(currentData) == "table" and typeof(currentData.LastSavedTimestamp) == "number" then
		if currentData.LastSavedTimestamp > incomingProfile.LastSavedTimestamp then
			return currentData, false -- Conflict: keep newer remote data
		end
	end
	return incomingProfile, true -- incoming is accepted
end

-- Internal persistence save using UpdateAsync for concurrency safety
local function saveProfileInternal(userId: number, profile: StateTypes.PlayerProfile): (boolean, string?)
	local loadState = profileLoadStates[userId]

	-- STRICT FAIL-CLOSED GUARD:
	-- Refuse to save if the profile was not successfully loaded or intentionally created as new.
	if loadState ~= "Loaded" and loadState ~= "New" then
		warn(string.format("[PersistenceService] Blocked save for user %d: LoadState is '%s' (fail-closed protection).", userId, tostring(loadState)))
		return false, "Blocked save: profile load state is not Loaded or New"
	end

	profile.LastSavedTimestamp = os.time()
	if not profileStore or RunService:IsStudio() then
		return true, nil
	end

	profileLoadStates[userId] = "Saving"

	local success, err = pcall(function()
		profileStore:UpdateAsync(tostring(userId), function(currentData: any)
			local dataToSave, applied = PersistenceService.resolveUpdateConflict(currentData, profile)
			if not applied then
				warn(string.format("[PersistenceService] Conflict detected for user %d: DataStore timestamp %d > session timestamp %d.", userId, currentData.LastSavedTimestamp, profile.LastSavedTimestamp))
			end
			return dataToSave
		end)
	end)

	profileLoadStates[userId] = loadState

	if not success then
		warn(string.format("[PersistenceService] Failed to save profile for %d: %s", userId, tostring(err)))
		return false, tostring(err)
	end

	return true, nil
end

-- Saves a player's profile if and only if it is in an authoritative loaded/new state
function PersistenceService.saveProfile(player: any): (boolean, string?)
	local userId = player.UserId
	local loadState = profileLoadStates[userId]

	if loadState ~= "Loaded" and loadState ~= "New" then
		return false, string.format("Cannot save: load state is '%s'", tostring(loadState))
	end

	local profile = activeProfiles[userId]
	if not profile then
		return false, "No active profile to save"
	end

	return saveProfileInternal(userId, profile)
end

function PersistenceService.getProfile(player: any): StateTypes.PlayerProfile
	local userId = player.UserId
	local profile = activeProfiles[userId]
	if not profile then
		if typeof(player) == "Instance" and player:IsA("Player") then
			local loaded = PersistenceService.loadProfile(player)
			if loaded then return loaded end
			-- Return safe fallback memory profile but do NOT mark saveable
			local fallback = reconcile(nil, userId)
			activeProfiles[userId] = fallback
			return fallback
		else
			-- Synthetic / mock player for testing or headless execution
			local newProfile = reconcile(nil, userId)
			activeProfiles[userId] = newProfile
			profileLoadStates[userId] = "New"
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

function PersistenceService.setLoadStateForTesting(userId: number, state: ProfileLoadState)
	profileLoadStates[userId] = state
end

function PersistenceService.simulateLoadFailureForTesting(userId: number)
	profileLoadStates[userId] = "LoadFailed"
	activeProfiles[userId] = nil
end

function PersistenceService.simulateLoadSuccessForTesting(userId: number, data: any): StateTypes.PlayerProfile
	local profile = reconcile(data, userId)
	activeProfiles[userId] = profile
	profileLoadStates[userId] = "Loaded"
	return profile
end

-- Handles player leaving: attempts save if safe, then unloads profile
function PersistenceService.onPlayerRemoving(player: any): (boolean, string?)
	local ok, err = PersistenceService.saveProfile(player)
	activeProfiles[player.UserId] = nil
	profileLoadStates[player.UserId] = nil
	return ok, err
end

function PersistenceService.setMockGetAsyncFailureForTesting(fail: boolean)
	mockGetAsyncFailure = fail
end

function PersistenceService.resetForTesting(userId: number?)
	mockGetAsyncFailure = false
	if userId then
		activeProfiles[userId] = nil
		profileLoadStates[userId] = nil
	else
		table.clear(activeProfiles)
		table.clear(profileLoadStates)
	end
end

local autosaveThread: thread? = nil

function PersistenceService.init()
	Players.PlayerAdded:Connect(function(p: Player)
		PersistenceService.loadProfile(p)
	end)

	Players.PlayerRemoving:Connect(function(p: Player)
		-- Only saves if profile was successfully loaded or new; blocks overwrite on load failure
		PersistenceService.onPlayerRemoving(p)
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

	print("[PersistenceService] Initialized Versioned DataStore persistence layer (v1) with fail-closed protection.")
end

return PersistenceService
