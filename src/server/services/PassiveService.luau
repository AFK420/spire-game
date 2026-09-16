--!strict
--[=[
	PassiveService ModuleScript
	Mapped to: ServerScriptService.Server.services.PassiveService

	Authoritative engine for passive skill progression (Phase 3):
	1. Manages passive point granting and spending.
	2. Validates prerequisite and class constraints for DAG node unlocks.
	3. Collects passive modifiers for StatResolver and ModifierResolver.
	4. Synchronizes derived stats upon progression changes.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)
local PassiveData = require(Shared:WaitForChild("PassiveData") :: ModuleScript)

local Server = ServerScriptService:WaitForChild("Server")
local Services = Server:WaitForChild("services")

local PassiveService = {}

-- Safely resolves StatResolver to trigger derived stat recalculation
local function getStatResolver(): any?
	local mod = Services:FindFirstChild("StatResolver")
	if mod and mod:IsA("ModuleScript") then
		return require(mod)
	end
	return nil
end

-- Grants passive points to a player state
function PassiveService.grantPoints(playerState: StateTypes.PlayerState, points: number)
	if not playerState then return end
	if not playerState.PassivePoints then
		playerState.PassivePoints = 0
	end
	playerState.PassivePoints += math.max(0, points)
end

-- Authoritatively unlocks a passive node on the player's tree
function PassiveService.unlockNode(
	playerState: StateTypes.PlayerState,
	nodeId: string
): (boolean, string?)
	if not playerState then
		return false, "Player state is nil."
	end

	if not playerState.UnlockedPassives then
		playerState.UnlockedPassives = {}
	end
	if not playerState.PassivePoints then
		playerState.PassivePoints = 0
	end

	local node = PassiveData.getNode(nodeId)
	if not node then
		return false, string.format("Passive node '%s' does not exist.", nodeId)
	end

	-- 1. Class requirement check
	if node.ClassId ~= "" and node.ClassId ~= playerState.ClassId then
		return false, string.format("Node '%s' requires class '%s', but player is '%s'.", node.Name, node.ClassId, playerState.ClassId)
	end

	-- 2. Duplicate unlock check
	if playerState.UnlockedPassives[nodeId] then
		return false, string.format("Passive node '%s' is already unlocked.", node.Name)
	end

	-- 3. Prerequisite check
	for _, prereqId in node.Prerequisites do
		if not playerState.UnlockedPassives[prereqId] then
			local prereqNode = PassiveData.getNode(prereqId)
			local prereqName = prereqNode and prereqNode.Name or prereqId
			return false, string.format("Prerequisite node '%s' must be unlocked first.", prereqName)
		end
	end

	-- 4. Cost check
	if playerState.PassivePoints < node.Cost then
		return false, string.format("Insufficient passive points. Requires %d, have %d.", node.Cost, playerState.PassivePoints)
	end

	-- 5. Mutate state
	playerState.PassivePoints -= node.Cost
	playerState.UnlockedPassives[nodeId] = true

	-- 6. Synchronize derived stats (e.g. MaxHP, MaxEnergy)
	local statResolver = getStatResolver()
	if statResolver and type(statResolver.syncPlayerDerivedStats) == "function" then
		statResolver.syncPlayerDerivedStats(playerState)
	end

	return true, nil
end

-- Collects all active modifiers from the player's unlocked passives
function PassiveService.collectModifiers(playerState: StateTypes.PlayerState): { StateTypes.Modifier }
	local modifiers: { StateTypes.Modifier } = {}

	if not playerState or not playerState.UnlockedPassives then
		return modifiers
	end

	for nodeId, isUnlocked in playerState.UnlockedPassives do
		if isUnlocked then
			local node = PassiveData.getNode(nodeId)
			if node and node.Modifiers then
				for _, mod in node.Modifiers do
					table.insert(modifiers, mod)
				end
			end
		end
	end

	-- Sort deterministically: Priority ascending, then Id alphabetical
	table.sort(modifiers, function(a, b)
		if a.Priority == b.Priority then
			return a.Id < b.Id
		end
		return a.Priority < b.Priority
	end)

	return modifiers
end

-- Checks if a specific passive node is unlocked
function PassiveService.isNodeUnlocked(playerState: StateTypes.PlayerState, nodeId: string): boolean
	if not playerState or not playerState.UnlockedPassives then
		return false
	end
	return playerState.UnlockedPassives[nodeId] == true
end

function PassiveService.init()
	print("[PassiveService] Initialized passive progression service.")
end

return PassiveService
