--!strict

--[=[
	ReactionService ModuleScript
	Mapped to: ServerScriptService.Server.services.ReactionService
	Authoritative combat reaction engine for Card Rift: Co-op Dungeon.
	1. Manages real-time rhythm-style reaction windows during enemy attack telegraphs.
	2. Evaluates player Dodge and Parry submissions against authoritative monotonic server clocks.
	3. Judges Perfect, Good, Early, Late, Miss, and Unavailable based on attack-specific tolerances.
	4. Supports data-driven attack timing profiles from ReactionData.
	5. Guarantees safe timeout resolution without blocking or hanging turn progression.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)
local GameConfig = require(Shared:WaitForChild("GameConfig") :: ModuleScript)
local ReactionData = require(Shared:WaitForChild("ReactionData") :: ModuleScript)

local servicesFolder = script.Parent

local ReactionService = {}

local activeWindowLive: StateTypes.ReactionWindowState? = nil
local activeWindowTest: StateTypes.ReactionWindowState? = nil
local onParryHook: ((targetUserId: number, attackProfile: StateTypes.AttackReactionProfile, isPerfect: boolean) -> ())? = nil

local function getServerTime(): number
	local ok, t = pcall(function()
		return Workspace:GetServerTimeNow()
	end)
	if ok and typeof(t) == "number" and t > 0 then
		return t
	end
	return os.clock()
end

local function getRunManager(): any
	local rm = servicesFolder:FindFirstChild("RunManager")
	if rm then
		return require(rm :: ModuleScript)
	end
	return nil
end

local function isTestIsolated(): boolean
	local rm = getRunManager()
	if rm and rm.isTestIsolationActive then
		return rm.isTestIsolationActive()
	end
	return false
end

local function getActiveWindowInternal(): StateTypes.ReactionWindowState?
	return if isTestIsolated() then activeWindowTest else activeWindowLive
end

local function setActiveWindowInternal(win: StateTypes.ReactionWindowState?)
	if isTestIsolated() then
		activeWindowTest = win
	else
		activeWindowLive = win
	end
end

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
	parryEnd: number?,
	impactDelay: number?,
	recoveryDuration: number?,
	dodgePerfectTol: number?,
	dodgeGoodTol: number?,
	parryPerfectTol: number?,
	parryGoodTol: number?,
	attackType: StateTypes.AttackType?,
	projectileSpeed: number?
): StateTypes.AttackReactionProfile
	local tDuration = telegraphDuration or GameConfig.Reaction.DefaultTelegraphDuration or 1.2
	local iDelay = impactDelay or (tDuration * 0.85)
	local rDuration = recoveryDuration or GameConfig.Reaction.DefaultRecoveryDuration or 0.3
	local dEnd = dodgeWindowEnd or (iDelay + 0.35)
	local pStart = parryStart or (iDelay - 0.15)
	local pEnd = parryEnd or (iDelay + 0.15)

	local dPerfTol = dodgePerfectTol or GameConfig.Reaction.DefaultDodgePerfectTolerance or 0.15
	local dGoodTol = dodgeGoodTol or GameConfig.Reaction.DefaultDodgeGoodTolerance or 0.35
	local pPerfTol = parryPerfectTol or GameConfig.Reaction.DefaultParryPerfectTolerance or 0.08
	local pGoodTol = parryGoodTol or GameConfig.Reaction.DefaultParryGoodTolerance or 0.18

	return {
		AttackId = attackId,
		AttackName = attackName,
		AttackType = attackType or "Melee",
		CanDodge = canDodge,
		CanParry = canParry,
		TelegraphDuration = tDuration,
		ImpactDelay = iDelay,
		RecoveryDuration = rDuration,
		DodgeWindowStart = 0.0,
		DodgeWindowEnd = dEnd,
		ParryWindowStart = pStart,
		ParryWindowEnd = pEnd,
		DodgePerfectTolerance = dPerfTol,
		DodgeGoodTolerance = dGoodTol,
		ParryPerfectTolerance = pPerfTol,
		ParryGoodTolerance = pGoodTol,
		DamageType = damageType,
		RawDamage = rawDamage,
		IsAoE = false,
		ProjectileSpeed = projectileSpeed,
	}
end

function ReactionService.createProfileFromPreset(
	presetId: string,
	rawDamage: number?,
	damageType: StateTypes.DamageType?
): StateTypes.AttackReactionProfile
	local preset = ReactionData.getProfile(presetId)
	if not preset then
		preset = ReactionData.getProfile("SlowHeavy") :: ReactionData.AttackTimingProfile
	end

	local dmg = rawDamage or preset.RawDamage
	local dt = damageType or preset.DamageType

	return ReactionService.createAttackProfile(
		preset.AttackId,
		preset.AttackName,
		dmg,
		dt,
		preset.CanDodge,
		preset.CanParry,
		preset.TelegraphDuration,
		preset.ImpactDelay + preset.DodgeGoodTolerance,
		preset.ImpactDelay - preset.ParryGoodTolerance,
		preset.ImpactDelay + preset.ParryGoodTolerance,
		preset.ImpactDelay,
		preset.RecoveryDuration,
		preset.DodgePerfectTolerance,
		preset.DodgeGoodTolerance,
		preset.ParryPerfectTolerance,
		preset.ParryGoodTolerance,
		preset.AttackType,
		preset.ProjectileSpeed
	)
end

function ReactionService.setParryHook(fn: ((targetUserId: number, attackProfile: StateTypes.AttackReactionProfile, isPerfect: boolean) -> ())?)
	onParryHook = fn
end

--------------------------------------------------------------------------------
-- Reaction Window Lifecycle
--------------------------------------------------------------------------------

function ReactionService.getActiveWindow(): StateTypes.ReactionWindowState?
	return getActiveWindowInternal()
end

function ReactionService.cleanup()
	setActiveWindowInternal(nil)
end

function ReactionService.openReactionWindow(
	combatState: StateTypes.CombatState,
	attackProfile: StateTypes.AttackReactionProfile,
	enemyInstanceId: string,
	targetUserIds: { number }
): StateTypes.ReactionWindowState
	local now = getServerTime()
	local impactTime = now + attackProfile.ImpactDelay
	local maxGrace = math.max(attackProfile.DodgeGoodTolerance, attackProfile.ParryGoodTolerance, 0.25)
	local closeTime = impactTime + maxGrace
	local windowId = "react_" .. string.sub(HttpService:GenerateGUID(false), 1, 8)

	local perPlayerMap: {
		[number]: {
			Reaction: StateTypes.ReactionType?,
			Result: StateTypes.ReactionResult,
			Judgement: StateTypes.TimingJudgement?,
			TimeDelta: number?,
			SubmittedAt: number?,
		},
	} = {}

	for _, uId in targetUserIds do
		perPlayerMap[uId] = {
			Reaction = nil,
			Result = "None",
			Judgement = "None",
			TimeDelta = nil,
			SubmittedAt = nil,
		}
	end

	local windowState: StateTypes.ReactionWindowState = {
		WindowId = windowId,
		AttackProfile = attackProfile,
		EnemyInstanceId = enemyInstanceId,
		TargetUserIds = targetUserIds,
		AttackStartServerTime = now,
		ImpactServerTime = impactTime,
		ReactionCloseServerTime = closeTime,
		OpenTime = now,
		ImpactTime = impactTime,
		CloseTime = closeTime,
		Resolved = false,
		PerPlayerResult = perPlayerMap,
	}

	setActiveWindowInternal(windowState)
	combatState.ActiveReactionWindow = windowState

	print(string.format("[ReactionService] Opened authoritative reaction window %s for '%s' (%s, impact in %.2fs, close in %.2fs).",
		windowId, attackProfile.AttackName, attackProfile.AttackType or "Melee", attackProfile.ImpactDelay, closeTime - now))
	return windowState
end

--------------------------------------------------------------------------------
-- Player Submission Validation & Exact Authoritative Timing
--------------------------------------------------------------------------------

function ReactionService.submitReaction(
	player: any,
	windowId: string,
	reactionType: StateTypes.ReactionType,
	clientTimestamp: number?
): (boolean, string?, StateTypes.ReactionResult?)
	local activeWin = getActiveWindowInternal()
	if not activeWin or activeWin.Resolved then
		return false, "No active reaction window.", "None"
	end

	if activeWin.WindowId ~= windowId then
		return false, "Invalid or expired reaction window ID.", "None"
	end

	local userId = (typeof(player) == "number") and player or (typeof(player) == "Instance" and player.UserId) or (typeof(player) == "table" and player.UserId)
	if not userId then
		return false, "Invalid player identity.", "None"
	end

	local playerRecord = activeWin.PerPlayerResult[userId]
	if not playerRecord then
		return false, "Player is not a targeted recipient of this incoming attack.", "None"
	end

	if playerRecord.Reaction ~= nil then
		return false, "Reaction already submitted for this window.", playerRecord.Result
	end

	local profile = activeWin.AttackProfile
	local now = getServerTime()
	local impactTime = activeWin.ImpactServerTime or activeWin.ImpactTime
	local timeDelta = now - impactTime -- Negative = Early, Positive = Late

	playerRecord.Reaction = reactionType
	playerRecord.SubmittedAt = now
	playerRecord.TimeDelta = timeDelta

	-- 1. Evaluate Dodge Timing
	if reactionType == "Dodge" then
		if not profile.CanDodge then
			playerRecord.Result = "Unavailable"
			playerRecord.Judgement = "Unavailable"
			return false, "This attack cannot be dodged!", "Unavailable"
		end

		local absDelta = math.abs(timeDelta)
		if absDelta <= profile.DodgePerfectTolerance then
			playerRecord.Result = "Perfect"
			playerRecord.Judgement = "Perfect"
			print(string.format("[ReactionService] Player %d PERFECT DODGE against '%s' (delta: %+.3fs, tol: %.3fs)",
				userId, profile.AttackName, timeDelta, profile.DodgePerfectTolerance))
			return true, "PERFECT DODGE!", "Perfect"
		elseif absDelta <= profile.DodgeGoodTolerance then
			playerRecord.Result = "Good"
			playerRecord.Judgement = "Good"
			print(string.format("[ReactionService] Player %d GOOD DODGE against '%s' (delta: %+.3fs, tol: %.3fs)",
				userId, profile.AttackName, timeDelta, profile.DodgeGoodTolerance))
			return true, "GOOD DODGE!", "Good"
		elseif timeDelta < -profile.DodgeGoodTolerance then
			playerRecord.Result = "Early"
			playerRecord.Judgement = "Early"
			print(string.format("[ReactionService] Player %d DODGE EARLY against '%s' (delta: %+.3fs)",
				userId, profile.AttackName, timeDelta))
			return false, "Dodged too early!", "Early"
		else
			playerRecord.Result = "Late"
			playerRecord.Judgement = "Late"
			print(string.format("[ReactionService] Player %d DODGE LATE against '%s' (delta: %+.3fs)",
				userId, profile.AttackName, timeDelta))
			return false, "Dodged too late!", "Late"
		end

	-- 2. Evaluate Parry Timing
	elseif reactionType == "Parry" then
		if not profile.CanParry then
			playerRecord.Result = "Unavailable"
			playerRecord.Judgement = "Unavailable"
			return false, "This attack cannot be parried!", "Unavailable"
		end

		local absDelta = math.abs(timeDelta)
		if absDelta <= profile.ParryPerfectTolerance then
			playerRecord.Result = "Perfect"
			playerRecord.Judgement = "Perfect"
			print(string.format("[ReactionService] Player %d PERFECT PARRY against '%s' (delta: %+.3fs, tol: %.3fs)",
				userId, profile.AttackName, timeDelta, profile.ParryPerfectTolerance))
			if onParryHook then
				pcall(function()
					onParryHook(userId, profile, true)
				end)
			end
			return true, "PERFECT PARRY!", "Perfect"
		elseif absDelta <= profile.ParryGoodTolerance then
			playerRecord.Result = "Good"
			playerRecord.Judgement = "Good"
			print(string.format("[ReactionService] Player %d GOOD PARRY against '%s' (delta: %+.3fs, tol: %.3fs)",
				userId, profile.AttackName, timeDelta, profile.ParryGoodTolerance))
			if onParryHook then
				pcall(function()
					onParryHook(userId, profile, false)
				end)
			end
			return true, "GOOD PARRY!", "Good"
		elseif timeDelta < -profile.ParryGoodTolerance then
			playerRecord.Result = "Early"
			playerRecord.Judgement = "Early"
			print(string.format("[ReactionService] Player %d PARRY EARLY against '%s' (delta: %+.3fs)",
				userId, profile.AttackName, timeDelta))
			return false, "Parried too early!", "Early"
		else
			playerRecord.Result = "Late"
			playerRecord.Judgement = "Late"
			print(string.format("[ReactionService] Player %d PARRY LATE against '%s' (delta: %+.3fs)",
				userId, profile.AttackName, timeDelta))
			return false, "Parried too late!", "Late"
		end
	end

	playerRecord.Result = "Miss"
	playerRecord.Judgement = "Miss"
	return false, "Unknown reaction type.", "Miss"
end

--------------------------------------------------------------------------------
-- Resolution
--------------------------------------------------------------------------------

function ReactionService.resolveReactionWindow(
	combatState: StateTypes.CombatState,
	windowId: string
): {
	[number]: {
		Reaction: StateTypes.ReactionType?,
		Result: StateTypes.ReactionResult,
		Judgement: StateTypes.TimingJudgement?,
		TimeDelta: number?,
	},
}
	local activeWin = getActiveWindowInternal()
	if not activeWin or activeWin.WindowId ~= windowId then
		return {}
	end

	activeWin.Resolved = true
	-- Fill unreacted targets as Miss
	for _, uId in activeWin.TargetUserIds do
		local rec = activeWin.PerPlayerResult[uId]
		if rec and rec.Reaction == nil then
			rec.Result = "Miss"
			rec.Judgement = "Miss"
		end
	end

	local results = activeWin.PerPlayerResult
	combatState.ActiveReactionWindow = nil
	setActiveWindowInternal(nil)

	print(string.format("[ReactionService] Resolved authoritative reaction window %s.", windowId))
	return results
end

function ReactionService.getReactionWindowView(
	windowState: StateTypes.ReactionWindowState?,
	enemyName: string?
): StateTypes.ReactionWindowView?
	if not windowState or windowState.Resolved then return nil end

	local now = getServerTime()
	local remaining = math.max(0, windowState.ReactionCloseServerTime - now)
	local total = windowState.ReactionCloseServerTime - windowState.AttackStartServerTime

	return {
		WindowId = windowState.WindowId,
		AttackName = windowState.AttackProfile.AttackName,
		EnemyName = enemyName or "Hostile Creature",
		AttackType = windowState.AttackProfile.AttackType or "Melee",
		DamageType = windowState.AttackProfile.DamageType,
		RawDamage = windowState.AttackProfile.RawDamage,
		CanDodge = windowState.AttackProfile.CanDodge,
		CanParry = windowState.AttackProfile.CanParry,
		AttackStartServerTime = windowState.AttackStartServerTime,
		ImpactServerTime = windowState.ImpactServerTime,
		ReactionCloseServerTime = windowState.ReactionCloseServerTime,
		OpenTime = windowState.OpenTime,
		ImpactTime = windowState.ImpactTime,
		CloseTime = windowState.CloseTime,
		TimeRemaining = math.round(remaining * 10) / 10,
		TotalDuration = total,
		TargetUserIds = windowState.TargetUserIds,
		ImpactDelay = windowState.AttackProfile.ImpactDelay,
		RecoveryDuration = windowState.AttackProfile.RecoveryDuration,
		TelegraphDuration = windowState.AttackProfile.TelegraphDuration,
		ProjectileSpeed = windowState.AttackProfile.ProjectileSpeed,
		DodgePerfectTolerance = windowState.AttackProfile.DodgePerfectTolerance,
		DodgeGoodTolerance = windowState.AttackProfile.DodgeGoodTolerance,
		ParryPerfectTolerance = windowState.AttackProfile.ParryPerfectTolerance,
		ParryGoodTolerance = windowState.AttackProfile.ParryGoodTolerance,
	}
end

function ReactionService.getServerTime(): number
	return getServerTime()
end

function ReactionService.init()
	print("[ReactionService] Initialized authoritative 3D combat reaction service.")
end

return ReactionService
