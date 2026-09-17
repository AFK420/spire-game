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
local GameConfig = require(Shared:WaitForChild("GameConfig") :: ModuleScript)

local servicesFolder = script.Parent
local ClassService = require(servicesFolder:WaitForChild("ClassService") :: ModuleScript)
local StatusService = require(servicesFolder:WaitForChild("StatusService") :: ModuleScript)
local RelicService = require(servicesFolder:WaitForChild("RelicService") :: ModuleScript)
local NetworkService = require(servicesFolder:WaitForChild("NetworkService") :: ModuleScript)

local ActionTransaction = {}

export type ActionSnapshot = {
	Party: { [number]: any },
	Enemies: { [string]: any },
	ClassGimmick: any,
	Statuses: { [string]: { [string]: StateTypes.StatusInstance } },
	RelicState: any,
	CombatLog: { StateTypes.CombatEvent },
	BufferedEvents: { StateTypes.CombatEvent },
}

local activeTransaction: ActionSnapshot? = nil

function ActionTransaction.isTransactionActive(): boolean
	return activeTransaction ~= nil
end

function ActionTransaction.bufferEvent(event: StateTypes.CombatEvent)
	if activeTransaction then
		table.insert(activeTransaction.BufferedEvents, event)
	end
end

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

	local logSnap: { StateTypes.CombatEvent } = {}
	for _, evt in ipairs(combatState.CombatLog) do
		table.insert(logSnap, deepCopyTable(evt))
	end

	local snapshot: ActionSnapshot = {
		Party = partySnap,
		Enemies = enemiesSnap,
		ClassGimmick = ClassService.snapshotGimmickTracker(playerState.UserId),
		Statuses = StatusService.snapshotStatuses(),
		RelicState = RelicService.snapshotCombatState(playerState.UserId),
		CombatLog = logSnap,
		BufferedEvents = {},
	}

	activeTransaction = snapshot
	return snapshot
end

-- Commits the transaction: appends buffered events to CombatLog and broadcasts to clients
function ActionTransaction.commitCombatTransaction(
	snapshot: ActionSnapshot,
	combatState: StateTypes.CombatState
)
	for _, event in ipairs(snapshot.BufferedEvents) do
		table.insert(combatState.CombatLog, event)
		if #combatState.CombatLog > GameConfig.Combat.MaxTurnHistoryLog then
			table.remove(combatState.CombatLog, 1)
		end
		NetworkService.broadcastCombatEvent(event)
	end

	table.clear(snapshot.BufferedEvents)
	if activeTransaction == snapshot then
		activeTransaction = nil
	end
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

	-- 6. Restore exact CombatLog in-place
	table.clear(combatState.CombatLog)
	for _, evt in ipairs(snapshot.CombatLog) do
		table.insert(combatState.CombatLog, deepCopyTable(evt))
	end

	-- 7. Discard buffered events entirely (zero client broadcasts)
	table.clear(snapshot.BufferedEvents)
	if activeTransaction == snapshot then
		activeTransaction = nil
	end
end

return ActionTransaction
