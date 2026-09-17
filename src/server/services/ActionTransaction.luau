--!strict

--[=[
	ActionTransaction ModuleScript
	Mapped to: ServerScriptService.Server.services.ActionTransaction
	Provides deterministic snapshot and rollback capabilities for combat actions
	(Card play, Skill execution), ensuring full transactionality.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)

local servicesFolder = script.Parent
local ClassService = require(servicesFolder:WaitForChild("ClassService") :: ModuleScript)
local StatusService = require(servicesFolder:WaitForChild("StatusService") :: ModuleScript)
local RelicService = require(servicesFolder:WaitForChild("RelicService") :: ModuleScript)

local ActionTransaction = {}

export type ActionSnapshot = {
	Party: { [number]: any },
	Enemies: { [string]: any },
	ClassGimmick: any,
	Statuses: { [string]: { [string]: StateTypes.StatusInstance } },
	RelicState: any,
	CombatLogLength: number,
}

local function deepCopyTable<T>(t: T): T
	if typeof(t) ~= "table" then return t end
	local copy = {}
	for k, v in pairs(t :: any) do
		if typeof(v) == "table" then
			copy[k] = deepCopyTable(v)
		else
			copy[k] = v
		end
	end
	return copy :: any
end

local function restoreTableInPlace(target: any, source: any)
	-- Remove extra keys in target that are not in source
	for k, _ in pairs(target) do
		if source[k] == nil then
			target[k] = nil
		end
	end
	-- Copy / restore keys from source
	for k, v in pairs(source) do
		if typeof(v) == "table" then
			if typeof(target[k]) == "table" then
				restoreTableInPlace(target[k], v)
			else
				target[k] = deepCopyTable(v)
			end
		else
			target[k] = v
		end
	end
end

-- Captures a complete snapshot of combat action state before mutations occur
function ActionTransaction.beginCombatTransaction(
	playerState: StateTypes.PlayerState,
	combatState: StateTypes.CombatState,
	party: { [number]: StateTypes.PlayerState }
): ActionSnapshot
	local partySnap: { [number]: any } = {}
	for uid, member in party do
		partySnap[uid] = deepCopyTable(member)
	end

	local enemiesSnap: { [string]: any } = {}
	for eid, enemy in combatState.Enemies do
		enemiesSnap[eid] = deepCopyTable(enemy)
	end

	return {
		Party = partySnap,
		Enemies = enemiesSnap,
		ClassGimmick = ClassService.snapshotGimmickTracker(playerState.UserId),
		Statuses = StatusService.snapshotStatuses(),
		RelicState = RelicService.snapshotCombatState(playerState.UserId),
		CombatLogLength = #combatState.CombatLog,
	}
end

-- Completely reverts all combat and entity mutations back to the snapshot state
function ActionTransaction.rollbackCombatTransaction(
	snapshot: ActionSnapshot,
	playerState: StateTypes.PlayerState,
	combatState: StateTypes.CombatState,
	party: { [number]: StateTypes.PlayerState }
)
	-- 1. Restore party members in-place
	for uid, pSnap in pairs(snapshot.Party) do
		if party[uid] then
			restoreTableInPlace(party[uid], pSnap)
		end
	end

	-- 2. Restore enemies in-place (and remove any spawned during action)
	for eid, _ in pairs(combatState.Enemies) do
		if not snapshot.Enemies[eid] then
			combatState.Enemies[eid] = nil
		end
	end
	for eid, eSnap in pairs(snapshot.Enemies) do
		if combatState.Enemies[eid] then
			restoreTableInPlace(combatState.Enemies[eid], eSnap)
		else
			combatState.Enemies[eid] = deepCopyTable(eSnap)
		end
	end

	-- 3. Restore Class Gimmick Tracker
	ClassService.restoreGimmickTracker(playerState.UserId, snapshot.ClassGimmick)

	-- 4. Restore Status Service
	StatusService.restoreStatuses(snapshot.Statuses)

	-- 5. Restore Relic State
	RelicService.restoreCombatState(playerState.UserId, snapshot.RelicState)

	-- 6. Truncate CombatLog to snapshot length
	local log = combatState.CombatLog
	while #log > snapshot.CombatLogLength do
		table.remove(log)
	end
end

return ActionTransaction
