--!strict

--[=[
	BreakService
	Server-authoritative Break/Stagger rules for elites and bosses.

	The service intentionally owns only deterministic state transitions. Combat
	orchestration decides when an action is skipped, while DamagePipeline reads
	the active Broken state for direct-hit vulnerability.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)
local GameConfig = require(Shared:WaitForChild("GameConfig") :: ModuleScript)

local BreakService = {}

local function hasTag(tags: { string }?, wanted: string): boolean
	if not tags then return false end
	for _, tag in tags do
		if tag == wanted then
			return true
		end
	end
	return false
end

function BreakService.isBreakable(enemy: StateTypes.EnemyState): boolean
	return (enemy.BreakThreshold or 0) > 0
end

function BreakService.isCurrentIntentInterruptible(enemy: StateTypes.EnemyState): boolean
	-- Existing elites and bosses predate explicit move metadata, so nil keeps
	-- their established behavior. Authored normal-enemy mechanics opt out of
	-- ordinary moves and opt in only for the move players can cancel.
	return enemy.Intent.BreakInterruptible ~= false
end

function BreakService.getCardBreakDamage(cardDef: any): number
	if cardDef and hasTag(cardDef.Tags, "Heavy") then
		return GameConfig.Break.HeavyCardDamage
	end
	return 0
end

-- currentActionConsumed is true when a successful parry already cancelled the
-- attack that caused the Break. Card/skill Breaks pass false so the next enemy
-- action is cancelled explicitly during resolution.
function BreakService.applyBreakDamage(
	enemy: StateTypes.EnemyState,
	amount: number,
	currentActionConsumed: boolean?
): (number, boolean)
	if amount <= 0 or enemy.HP <= 0 or not BreakService.isBreakable(enemy) then
		return 0, false
	end
	if enemy.IsBroken == true then
		return 0, false
	end

	local threshold = enemy.BreakThreshold or 0
	local before = math.clamp(enemy.BreakMeter or 0, 0, threshold)
	local after = math.clamp(before + amount, 0, threshold)
	if after >= threshold and not BreakService.isCurrentIntentInterruptible(enemy) then
		-- Preserve progress while preventing a non-interruptible move from
		-- consuming the Break. One more Break contribution can cancel the next
		-- explicitly interruptible mechanic.
		after = math.max(0, threshold - 1)
	end
	enemy.BreakMeter = after

	if after >= threshold then
		enemy.IsBroken = true
		enemy.BreakActionsToSkip = if currentActionConsumed == true then 0 else 1
		return after - before, true
	end

	return after - before, false
end

-- A Break caused during the player phase skips one action and stays vulnerable
-- through the following player phase. At the next resolution the enemy recovers
-- immediately before acting.
function BreakService.resolveBeforeEnemyAction(enemy: StateTypes.EnemyState): (boolean, boolean)
	if enemy.IsBroken ~= true then
		return false, false
	end

	local actionsToSkip = enemy.BreakActionsToSkip or 0
	if actionsToSkip > 0 then
		if not BreakService.isCurrentIntentInterruptible(enemy) then
			return false, false
		end
		enemy.BreakActionsToSkip = actionsToSkip - 1
		return true, false
	end

	enemy.IsBroken = false
	enemy.BreakMeter = 0
	enemy.BreakActionsToSkip = 0
	return false, true
end

function BreakService.getDirectDamageMultiplier(enemy: StateTypes.EnemyState?, isPeriodic: boolean): number
	if enemy and enemy.IsBroken == true and not isPeriodic then
		return GameConfig.Break.BrokenDamageMultiplier
	end
	return 1
end

return BreakService
