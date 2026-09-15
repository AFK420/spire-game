--!strict

--[=[
	PersistenceService ModuleScript
	Mapped to: ServerScriptService.Server.services.PersistenceService
	Handles persistent DataStore storage for permanent player profiles:
	- Aether Shards (meta currency)
	- Unlocked Class IDs
	- Lifetime victories and statistics
]=]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local PersistenceService = {}

export type PlayerProfile = {
	AetherShards: number,
	UnlockedClasses: { string },
	TotalVictories: number,
	TotalRuns: number,
	LastSavedTimestamp: number,
}

local DATA_STORE_NAME = "CardRift_PlayerProfiles_v2"
local AUTOSAVE_INTERVAL = 300

local DEFAULT_PROFILE: PlayerProfile = {
	AetherShards = 0,
	UnlockedClasses = { "Warlord", "Shadowblade", "AetherMage", "Necrobinder", "Mechanist" },
	TotalVictories = 0,
	TotalRuns = 0,
	LastSavedTimestamp = 0,
}

local activeProfiles: { [number]: PlayerProfile } = {} -- Keyed by UserId

local function deepCopy<T>(original: T): T
	if typeof(original) ~= "table" then return original end
	local copy = {}
	for k, v in (original :: any) do
		copy[k] = deepCopy(v)
	end
	return (copy :: any) :: T
end

local function reconcile(data: any): PlayerProfile
	local profile = deepCopy(DEFAULT_PROFILE)
	if typeof(data) == "table" then
		if typeof(data.AetherShards) == "number" then profile.AetherShards = math.max(0, data.AetherShards) end
		if typeof(data.TotalVictories) == "number" then profile.TotalVictories = math.max(0, data.TotalVictories) end
		if typeof(data.TotalRuns) == "number" then profile.TotalRuns = math.max(0, data.TotalRuns) end
		if typeof(data.UnlockedClasses) == "table" then profile.UnlockedClasses = data.UnlockedClasses end
	end
	return profile
end

local profileStore: any = nil
pcall(function()
	profileStore = DataStoreService:GetDataStore(DATA_STORE_NAME)
end)

function PersistenceService.loadProfile(player: Player): PlayerProfile
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

	local profile = reconcile(loadedData)
	activeProfiles[userId] = profile
	return profile
end

function PersistenceService.saveProfile(player: Player)
	local userId = player.UserId
	local profile = activeProfiles[userId]
	if not profile or not profileStore or RunService:IsStudio() then return end

	profile.LastSavedTimestamp = os.time()
	pcall(function()
		profileStore:SetAsync(tostring(userId), profile)
	end)
end

function PersistenceService.getProfile(player: Player): PlayerProfile
	local profile = activeProfiles[player.UserId]
	if not profile then
		return PersistenceService.loadProfile(player)
	end
	return profile
end

function PersistenceService.addAetherShards(player: Player, amount: number)
	local profile = PersistenceService.getProfile(player)
	profile.AetherShards += amount
end

function PersistenceService.recordRunVictory(player: Player)
	local profile = PersistenceService.getProfile(player)
	profile.TotalVictories += 1
end

function PersistenceService.isClassUnlocked(player: Player, classId: string): boolean
	local profile = PersistenceService.getProfile(player)
	for _, unlocked in profile.UnlockedClasses do
		if unlocked == classId then
			return true
		end
	end
	return false
end

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

	print("[PersistenceService] Initialized DataStore persistence layer.")
end

return PersistenceService
