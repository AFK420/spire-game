--!strict

--[=[
	ReactionService ModuleScript
	Mapped to: ServerScriptService.Server.services.ReactionService
	Authoritative combat reaction engine for Card Rift: Co-op Dungeon.
	1. Manages real-time reaction windows during enemy attack telegraphs.
	2. Validates player Dodge and Parry submissions against monotonic server clocks.
	3. Enforces single-submission per window, target validation, and strict timing windows.
	4. Guarantees safe timeout resolution without blocking or hanging turn progression.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)
local GameConfig = require(Shared:WaitForChild("GameConfig") :: ModuleScript)

local ReactionService = {}

local activeWindow: StateTypes.ReactionWindowState? = nil
local onParryHook: ((targetUserId: number, attackProfile: StateTypes.AttackReactionProfile) -> ())? = nil

--------------------------------------------------------------------------------
-- Profile Constructor
--------------------------------------------------------------------------------

function ReactionService.createAttackProfile(
	attackId: string,
	attackName: string,
	rawDamage: number,
	damageType: StateTypes.DamageType,
	canDodge: boolean,
	canParry: boolean,
	telegraphDuration: number?,
	dodgeWindowEnd: number?,
	parryStart: number?,
	parryEnd: number?
): StateTypes.AttackReactionProfile
	local tDuration = telegraphDuration or GameConfig.Reaction.DefaultTelegraphDuration or 1.0
	local dEnd = dodgeWindowEnd or GameConfig.Reaction.DefaultDodgeWindow or 1.2
	local pStart = parryStart or GameConfig.Reaction.DefaultParryStart or 0.7
	local pDuration = GameConfig.Reaction.DefaultParryDuration or 0.3
	local pEnd = parryEnd or (pStart + pDuration)

	return {
		AttackId = attackId,
		AttackName = attackName,
		CanDodge = canDodge,
		CanParry = canParry,
		TelegraphDuration = tDuration,
		DodgeWindowStart = 0.0,
		DodgeWindowEnd = dEnd,
		ParryWindowStart = pStart,
		ParryWindowEnd = pEnd,
		DamageType = damageType,
		RawDamage = rawDamage,
		IsAoE = false,
	}
end

function ReactionService.setParryHook(fn: ((targetUserId: number, attackProfile: StateTypes.AttackReactionProfile) -> ())?)
	onParryHook = fn
end

--------------------------------------------------------------------------------
-- Reaction Window Lifecycle
--------------------------------------------------------------------------------

function ReactionService.getActiveWindow(): StateTypes.ReactionWindowState?
	return activeWindow
end

function ReactionService.cleanup()
	activeWindow = nil
end

function ReactionService.openReactionWindow(
	combatState: StateTypes.CombatState,
	attackProfile: StateTypes.AttackReactionProfile,
	enemyInstanceId: string,
	targetUserIds: { number }
): StateTypes.ReactionWindowState
	local now = os.clock()
	local duration = math.max(attackProfile.TelegraphDuration, attackProfile.DodgeWindowEnd)
	local windowId = "react_" .. string.sub(HttpService:GenerateGUID(false), 1, 8)

	local perPlayerMap: { [number]: { Reaction: StateTypes.ReactionType?, Result: StateTypes.ReactionResult, SubmittedAt: number? } } = {}
	for _, uId in targetUserIds do
		perPlayerMap[uId] = {
			Reaction = nil,
			Result = "None",
			SubmittedAt = nil,
		}
	end

	local windowState: StateTypes.ReactionWindowState = {
		WindowId = windowId,
		AttackProfile = attackProfile,
		EnemyInstanceId = enemyInstanceId,
		TargetUserIds = targetUserIds,
		OpenTime = now,
		CloseTime = now + duration,
		Resolved = false,
		PerPlayerResult = perPlayerMap,
	}

	activeWindow = windowState
	combatState.ActiveReactionWindow = windowState

	print(string.format("[ReactionService] Opened reaction window %s for attack '%s' against %d target(s). Closes in %.2fs.",
		windowId, attackProfile.AttackName, #targetUserIds, duration))
	return windowState
end

--------------------------------------------------------------------------------
-- Player Submission Validation
--------------------------------------------------------------------------------

function ReactionService.submitReaction(
	player: any,
	windowId: string,
	reactionType: StateTypes.ReactionType,
	clientTimestamp: number?
): (boolean, string?, StateTypes.ReactionResult?)
	if not activeWindow or activeWindow.Resolved then
		return false, "No active reaction window.", "None"
	end

	if activeWindow.WindowId ~= windowId then
		return false, "Invalid or expired reaction window ID.", "None"
	end

	local userId = (typeof(player) == "number") and player or (typeof(player) == "Instance" and player.UserId) or (typeof(player) == "table" and player.UserId)
	if not userId then
		return false, "Invalid player identity.", "None"
	end

	local playerRecord = activeWindow.PerPlayerResult[userId]
	if not playerRecord then
		return false, "Player is not a targeted recipient of this incoming attack.", "None"
	end

	if playerRecord.Reaction ~= nil then
		return false, "Reaction already submitted for this window.", playerRecord.Result
	end

	local profile = activeWindow.AttackProfile
	local now = os.clock()
	local elapsed = now - activeWindow.OpenTime

	playerRecord.Reaction = reactionType
	playerRecord.SubmittedAt = now

	-- Validation: Dodge
	if reactionType == "Dodge" then
		if not profile.CanDodge then
			playerRecord.Result = "Miss"
			return false, "This attack cannot be dodged!", "Miss"
		end

		if elapsed < profile.DodgeWindowStart then
			playerRecord.Result = "Early"
			return false, "Dodged too early!", "Early"
		elseif elapsed > profile.DodgeWindowEnd then
			playerRecord.Result = "Late"
			return false, "Dodged too late!", "Late"
		else
			playerRecord.Result = "Success"
			print(string.format("[ReactionService] Player %d successfully DODGED attack '%s' (elapsed: %.2fs)",
				userId, profile.AttackName, elapsed))
			return true, "Dodge successful!", "Success"
		end

	-- Validation: Parry
	elseif reactionType == "Parry" then
		if not profile.CanParry then
			playerRecord.Result = "Miss"
			return false, "This attack cannot be parried!", "Miss"
		end

		if elapsed < profile.ParryWindowStart then
			playerRecord.Result = "Early"
			return false, "Parried too early!", "Early"
		elseif elapsed > profile.ParryWindowEnd then
			playerRecord.Result = "Late"
			return false, "Parried too late!", "Late"
		else
			playerRecord.Result = "Success"
			print(string.format("[ReactionService] Player %d successfully PARRIED attack '%s' (elapsed: %.2fs)",
				userId, profile.AttackName, elapsed))
			if onParryHook then
				pcall(function()
					onParryHook(userId, profile)
				end)
			end
			return true, "Parry successful!", "Success"
		end
	end

	playerRecord.Result = "Miss"
	return false, "Unknown reaction type.", "Miss"
end

--------------------------------------------------------------------------------
-- Resolution
--------------------------------------------------------------------------------

function ReactionService.resolveReactionWindow(
	combatState: StateTypes.CombatState,
	windowId: string
): { [number]: { Reaction: StateTypes.ReactionType?, Result: StateTypes.ReactionResult } }
	if not activeWindow or activeWindow.WindowId ~= windowId then
		return {}
	end

	activeWindow.Resolved = true
	local results = activeWindow.PerPlayerResult
	combatState.ActiveReactionWindow = nil
	activeWindow = nil

	print(string.format("[ReactionService] Resolved reaction window %s.", windowId))
	return results
end

function ReactionService.getReactionWindowView(
	windowState: StateTypes.ReactionWindowState?,
	enemyName: string?
): StateTypes.ReactionWindowView?
	if not windowState or windowState.Resolved then return nil end

	local now = os.clock()
	local remaining = math.max(0, windowState.CloseTime - now)
	local total = windowState.CloseTime - windowState.OpenTime

	return {
		WindowId = windowState.WindowId,
		AttackName = windowState.AttackProfile.AttackName,
		EnemyName = enemyName or "Hostile Creature",
		DamageType = windowState.AttackProfile.DamageType,
		RawDamage = windowState.AttackProfile.RawDamage,
		CanDodge = windowState.AttackProfile.CanDodge,
		CanParry = windowState.AttackProfile.CanParry,
		TimeRemaining = math.round(remaining * 10) / 10,
		TotalDuration = total,
		TargetUserIds = windowState.TargetUserIds,
	}
end

function ReactionService.init()
	print("[ReactionService] Initialized authoritative combat reaction service.")
end

return ReactionService
