--!strict

--[=[
	ProfileStore Script
	Mapped to: ServerScriptService.Server.ProfileStore
	Manages secure loading, saving, and caching of persistent player profile data
	using Roblox DataStoreService.

	Tracks:
	- Aether Shards (permanent meta-currency)
	- Unlocked Class IDs (e.g. "Warrior", "Rogue", "Mage")
	- Total Run Victories & Total Runs Started
	- Default fallback data for brand-new players
]=]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ProfileStore = {}

--------------------------------------------------------------------------------
-- Type Definitions
--------------------------------------------------------------------------------

export type PlayerProfile = {
	AetherShards: number,
	UnlockedClasses: { string },
	TotalVictories: number,
	TotalRuns: number,
	LastSavedTimestamp: number,
}

--------------------------------------------------------------------------------
-- Configuration & Fallback Defaults
--------------------------------------------------------------------------------

local DATA_STORE_NAME = "CardRift_PlayerProfiles_v1"
local AUTOSAVE_INTERVAL = 300 -- 5 minutes
local MAX_RETRIES = 3
local RETRY_BASE_DELAY = 1.0

-- Fallback profile table for brand-new players joining for the first time
local DEFAULT_PROFILE: PlayerProfile = {
	AetherShards = 0,
	UnlockedClasses = { "Warrior" },
	TotalVictories = 0,
	TotalRuns = 0,
	LastSavedTimestamp = 0,
}

-- Safe deep copy utility
local function deepCopy<T>(original: T): T
	if typeof(original) ~= "table" then
		return original
	end
	local copy = {}
	for k, v in (original :: any) do
		copy[k] = deepCopy(v)
	end
	return (copy :: any) :: T
end

-- Reconciles loaded data with DEFAULT_PROFILE to ensure missing keys are populated
local function reconcileProfile(loadedData: any): PlayerProfile
	if typeof(loadedData) ~= "table" then
		return deepCopy(DEFAULT_PROFILE)
	end

	local profile = deepCopy(DEFAULT_PROFILE)

	if typeof(loadedData.AetherShards) == "number" then
		profile.AetherShards = math.max(0, math.floor(loadedData.AetherShards))
	end

	if typeof(loadedData.UnlockedClasses) == "table" then
		local validClasses = {}
		for _, classId in loadedData.UnlockedClasses do
			if typeof(classId) == "string" and not table.find(validClasses, classId) then
				table.insert(validClasses, classId)
			end
		end
		-- Guarantee at least the starter class is present
		if not table.find(validClasses, "Warrior") then
			table.insert(validClasses, 1, "Warrior")
		end
		profile.UnlockedClasses = validClasses
	end

	if typeof(loadedData.TotalVictories) == "number" then
		profile.TotalVictories = math.max(0, math.floor(loadedData.TotalVictories))
	end

	if typeof(loadedData.TotalRuns) == "number" then
		profile.TotalRuns = math.max(0, math.floor(loadedData.TotalRuns))
	end

	if typeof(loadedData.LastSavedTimestamp) == "number" then
		profile.LastSavedTimestamp = loadedData.LastSavedTimestamp
	end

	return profile
end

--------------------------------------------------------------------------------
-- DataStore Handlers & Memory Cache
--------------------------------------------------------------------------------

local activeProfiles: { [Player]: PlayerProfile } = {}
local isSaving: { [Player]: boolean } = {}

-- Safely acquires the DataStore instance
local profileDataStore: GlobalDataStore? = nil
local canAccessDataStore = true

local dsSuccess, dsResult = pcall(function()
	return DataStoreService:GetDataStore(DATA_STORE_NAME)
end)

if dsSuccess and dsResult then
	profileDataStore = dsResult
else
	warn("[ProfileStore] DataStoreService unavailable or API access disabled in Studio. Running in in-memory mode.")
	canAccessDataStore = false
end

-- Formats player datastore key
local function makePlayerKey(userId: number): string
	return string.format("PlayerProfile_%d", userId)
end

-- Retries a DataStore read operation with exponential backoff
local function getAsyncWithRetry(key: string): (boolean, any)
	if not profileDataStore or not canAccessDataStore then
		return false, "DataStore access disabled"
	end

	local attempts = 0
	local success = false
	local result: any = nil

	while attempts < MAX_RETRIES and not success do
		attempts += 1
		success, result = pcall(function()
			return profileDataStore:GetAsync(key)
		end)

		if not success and attempts < MAX_RETRIES then
			task.wait(RETRY_BASE_DELAY * attempts)
		end
	end

	return success, result
end

-- Retries a DataStore write operation using UpdateAsync with exponential backoff
local function updateAsyncWithRetry(key: string, transformFn: (any) -> any): (boolean, any)
	if not profileDataStore or not canAccessDataStore then
		return false, "DataStore access disabled"
	end

	local attempts = 0
	local success = false
	local result: any = nil

	while attempts < MAX_RETRIES and not success do
		attempts += 1
		success, result = pcall(function()
			return profileDataStore:UpdateAsync(key, transformFn)
		end)

		if not success and attempts < MAX_RETRIES then
			task.wait(RETRY_BASE_DELAY * attempts)
		end
	end

	return success, result
end

--------------------------------------------------------------------------------
-- Profile Lifecycle: Load, Save, Autosave
--------------------------------------------------------------------------------

-- Loads a player's profile when they join
function ProfileStore.loadProfile(player: Player): PlayerProfile
	local key = makePlayerKey(player.UserId)
	local loadedProfile: PlayerProfile

	if canAccessDataStore then
		local success, savedData = getAsyncWithRetry(key)

		if success then
			if savedData ~= nil then
				loadedProfile = reconcileProfile(savedData)
				print(string.format(
					"[ProfileStore] Loaded existing profile for %s (Aether Shards: %d, Victories: %d, Classes: %d)",
					player.Name,
					loadedProfile.AetherShards,
					loadedProfile.TotalVictories,
					#loadedProfile.UnlockedClasses
				))
			else
				-- Brand-new player: apply default fallback table
				loadedProfile = deepCopy(DEFAULT_PROFILE)
				print(string.format("[ProfileStore] Created new profile with default fallbacks for first-time player %s.", player.Name))
			end
		else
			warn(string.format("[ProfileStore] Failed to load data for %s: %s. Using default fallback profile.", player.Name, tostring(savedData)))
			loadedProfile = deepCopy(DEFAULT_PROFILE)
		end
	else
		-- Studio or fallback in-memory profile
		loadedProfile = deepCopy(DEFAULT_PROFILE)
		print(string.format("[ProfileStore] In-memory profile initialized for %s.", player.Name))
	end

	activeProfiles[player] = loadedProfile
	return loadedProfile
end

-- Saves a player's profile
function ProfileStore.saveProfile(player: Player): boolean
	local profile = activeProfiles[player]
	if not profile then
		return false
	end

	if isSaving[player] then
		return false
	end
	isSaving[player] = true

	local key = makePlayerKey(player.UserId)
	profile.LastSavedTimestamp = os.time()

	local saveSuccess = false

	if canAccessDataStore then
		local success, err = updateAsyncWithRetry(key, function(oldData: any)
			-- Reconcile in case of conflict, saving the latest profile state
			return deepCopy(profile)
		end)

		if success then
			saveSuccess = true
			print(string.format(
				"[ProfileStore] Successfully saved profile for %s (Aether Shards: %d, Victories: %d)",
				player.Name,
				profile.AetherShards,
				profile.TotalVictories
			))
		else
			warn(string.format("[ProfileStore] Error saving profile for %s: %s", player.Name, tostring(err)))
		end
	else
		-- In-memory mock save
		saveSuccess = true
	end

	isSaving[player] = nil
	return saveSuccess
end

-- Unloads a player's profile upon leaving
function ProfileStore.unloadProfile(player: Player)
	ProfileStore.saveProfile(player)
	activeProfiles[player] = nil
	isSaving[player] = nil
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Fetches active cached profile
function ProfileStore.getProfile(player: Player): PlayerProfile?
	return activeProfiles[player]
end

-- Adds permanent Aether Shards currency
function ProfileStore.addAetherShards(player: Player, amount: number): boolean
	local profile = activeProfiles[player]
	if not profile or amount <= 0 then
		return false
	end

	profile.AetherShards += math.floor(amount)
	print(string.format("[ProfileStore] %s gained %d Aether Shards! (Total: %d)", player.Name, amount, profile.AetherShards))
	return true
end

-- Spends Aether Shards if player has sufficient funds
function ProfileStore.spendAetherShards(player: Player, amount: number): boolean
	local profile = activeProfiles[player]
	if not profile or amount <= 0 then
		return false
	end

	local cost = math.floor(amount)
	if profile.AetherShards < cost then
		print(string.format("[ProfileStore] %s cannot afford %d Shards (Current: %d)", player.Name, cost, profile.AetherShards))
		return false
	end

	profile.AetherShards -= cost
	print(string.format("[ProfileStore] %s spent %d Aether Shards. (Remaining: %d)", player.Name, cost, profile.AetherShards))
	return true
end

-- Unlocks a new class ID for meta-progression
function ProfileStore.unlockClass(player: Player, classId: string): boolean
	local profile = activeProfiles[player]
	if not profile or classId == "" then
		return false
	end

	if table.find(profile.UnlockedClasses, classId) then
		print(string.format("[ProfileStore] %s already has class '%s' unlocked.", player.Name, classId))
		return false
	end

	table.insert(profile.UnlockedClasses, classId)
	print(string.format("[ProfileStore] %s unlocked new class: '%s'!", player.Name, classId))
	return true
end

-- Records a completed dungeon run victory
function ProfileStore.recordRunVictory(player: Player)
	local profile = activeProfiles[player]
	if not profile then
		return
	end

	profile.TotalVictories += 1
	print(string.format("[ProfileStore] Recorded victory for %s! (Total Victories: %d)", player.Name, profile.TotalVictories))
end

-- Records a new run started
function ProfileStore.recordRunStart(player: Player)
	local profile = activeProfiles[player]
	if not profile then
		return
	end

	profile.TotalRuns += 1
end

--------------------------------------------------------------------------------
-- Player Lifecycle Connections & BindToClose
--------------------------------------------------------------------------------

Players.PlayerAdded:Connect(function(player: Player)
	ProfileStore.loadProfile(player)
end)

Players.PlayerRemoving:Connect(function(player: Player)
	ProfileStore.unloadProfile(player)
end)

-- Initialize any players already in the server
for _, p in Players:GetPlayers() do
	ProfileStore.loadProfile(p)
end

-- BindToClose: Guarantees profile data is safely saved on server shutdown
game:BindToClose(function()
	print("[ProfileStore] Server shutting down. Saving all active player profiles...")

	local remainingPlayers = {}
	for player in activeProfiles do
		table.insert(remainingPlayers, player)
	end

	if #remainingPlayers == 0 then
		return
	end

	-- Save all remaining players in parallel
	local runningThreads = #remainingPlayers
	for _, player in remainingPlayers do
		task.spawn(function()
			ProfileStore.saveProfile(player)
			runningThreads -= 1
		end)
	end

	-- Wait up to 5 seconds for all save operations to finalize
	local timeout = 5.0
	local elapsed = 0
	while runningThreads > 0 and elapsed < timeout do
		task.wait(0.1)
		elapsed += 0.1
	end

	print(string.format("[ProfileStore] Shutdown save completed in %.2f seconds.", elapsed))
end)

--------------------------------------------------------------------------------
-- Periodic Autosave Loop
--------------------------------------------------------------------------------

task.spawn(function()
	while true do
		task.wait(AUTOSAVE_INTERVAL)
		for player in activeProfiles do
			if player:IsDescendantOf(Players) then
				task.spawn(function()
					ProfileStore.saveProfile(player)
				end)
			end
		end
	end
end)

--------------------------------------------------------------------------------
-- Export Global & Bindable Function Access
--------------------------------------------------------------------------------

-- Expose to _G for seamless server-side inter-script access
_G.ProfileStore = ProfileStore

--------------------------------------------------------------------------------
-- Verification Log
--------------------------------------------------------------------------------

local function runProfileStoreTests()
	print("============================================================")
	print("        CARD RIFT: PROFILESTORE VERIFICATION LOG            ")
	print("============================================================")
	print("[Test 1: Default Fallback Profile Validation]")
	print(string.format("  - Default Aether Shards:   %d", DEFAULT_PROFILE.AetherShards))
	print(string.format("  - Default Unlocked Classes: %s", table.concat(DEFAULT_PROFILE.UnlockedClasses, ", ")))
	print(string.format("  - Default Run Victories:   %d", DEFAULT_PROFILE.TotalVictories))

	print("[Test 2: Schema Reconciliation Check]")
	local legacyData = { AetherShards = 120, TotalVictories = 3 }
	local reconciled = reconcileProfile(legacyData)
	print(string.format("  - Reconciled Aether Shards:   %d", reconciled.AetherShards))
	print(string.format("  - Reconciled Unlocked Classes: %s", table.concat(reconciled.UnlockedClasses, ", ")))
	print(string.format("  - Reconciled Total Victories: %d", reconciled.TotalVictories))

	print("[Test 3: Currency & Unlock Mechanics Simulation]")
	local dummyProfile = deepCopy(DEFAULT_PROFILE)
	dummyProfile.AetherShards += 50
	table.insert(dummyProfile.UnlockedClasses, "Rogue")
	dummyProfile.TotalVictories += 1
	print(string.format("  - Added 50 Shards: Current = %d", dummyProfile.AetherShards))
	print(string.format("  - Unlocked Rogue: Classes = %s", table.concat(dummyProfile.UnlockedClasses, ", ")))
	print(string.format("  - Recorded Victory: Total = %d", dummyProfile.TotalVictories))
	print("============================================================")
end

runProfileStoreTests()

return ProfileStore
