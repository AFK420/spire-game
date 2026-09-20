--!strict

--[=[
	CombatFeedbackData
	Shared presentation policy for authoritative combat events. The server owns
	combat results; clients may only choose how those results are displayed.
]=]

local StateTypes = require(script.Parent:WaitForChild("StateTypes") :: ModuleScript)

local CombatFeedbackData = {}

export type FeedbackStyle = {
	Color: Color3,
	Scale: number,
	WorldPopup: boolean,
	FlashTarget: boolean,
	LocalHitShake: number,
	LocalAttackShake: number,
}

local DEFAULT_STYLE: FeedbackStyle = {
	Color = Color3.fromRGB(235, 235, 235),
	Scale = 1,
	WorldPopup = false,
	FlashTarget = false,
	LocalHitShake = 0,
	LocalAttackShake = 0,
}

local STYLES: { [string]: FeedbackStyle } = {
	DamageDealt = {
		Color = Color3.fromRGB(255, 92, 72),
		Scale = 1.18,
		WorldPopup = true,
		FlashTarget = true,
		LocalHitShake = 0.16,
		LocalAttackShake = 0.045,
	},
	Healed = {
		Color = Color3.fromRGB(94, 235, 140),
		Scale = 1,
		WorldPopup = true,
		FlashTarget = false,
		LocalHitShake = 0,
		LocalAttackShake = 0,
	},
	ShieldGained = {
		Color = Color3.fromRGB(90, 190, 255),
		Scale = 0.95,
		WorldPopup = true,
		FlashTarget = false,
		LocalHitShake = 0,
		LocalAttackShake = 0,
	},
	BreakDamage = {
		Color = Color3.fromRGB(255, 185, 60),
		Scale = 0.95,
		WorldPopup = true,
		FlashTarget = true,
		LocalHitShake = 0,
		LocalAttackShake = 0.025,
	},
	EnemyBroken = {
		Color = Color3.fromRGB(255, 225, 70),
		Scale = 1.35,
		WorldPopup = true,
		FlashTarget = true,
		LocalHitShake = 0,
		LocalAttackShake = 0.08,
	},
	BossPhaseChanged = {
		Color = Color3.fromRGB(205, 120, 255),
		Scale = 1.2,
		WorldPopup = true,
		FlashTarget = true,
		LocalHitShake = 0,
		LocalAttackShake = 0.05,
	},
	CardMissed = {
		Color = Color3.fromRGB(205, 215, 235),
		Scale = 1.1,
		WorldPopup = true,
		FlashTarget = false,
		LocalHitShake = 0,
		LocalAttackShake = 0,
	},
	SkillMissed = {
		Color = Color3.fromRGB(205, 215, 235),
		Scale = 1.1,
		WorldPopup = true,
		FlashTarget = false,
		LocalHitShake = 0,
		LocalAttackShake = 0,
	},
}

function CombatFeedbackData.getStyle(eventType: string): FeedbackStyle
	return STYLES[eventType] or DEFAULT_STYLE
end

function CombatFeedbackData.getDisplayText(event: StateTypes.CombatEvent): string
	if event.Type == "EnemyBroken" then
		return "BREAK!"
	elseif event.Type == "CardMissed" or event.Type == "SkillMissed" then
		return "MISS!"
	elseif event.Type == "BossPhaseChanged" and event.Value then
		return string.format("PHASE %d", event.Value)
	end
	if event.ExtraText and event.ExtraText ~= "" then
		return event.ExtraText
	end
	if event.Value then
		return tostring(event.Value)
	end
	return event.Type
end

return CombatFeedbackData
