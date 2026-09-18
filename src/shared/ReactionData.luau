--!strict

--[=[
	ReactionData ModuleScript
	Mapped to: ReplicatedStorage.Shared.ReactionData
	Data-driven attack timing profiles for the rhythm approach-circle reaction system.
	1. Defines telegraph duration, impact delay, and recovery timing per attack type.
	2. Defines tight Perfect and wider Good tolerances for Dodge and Parry.
	3. Authoritatively gates whether an attack CanDodge, CanParry, or is Unreactable.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)

export type AttackTimingProfile = {
	AttackId: string,
	AttackName: string,
	TelegraphDuration: number,
	ImpactDelay: number,
	RecoveryDuration: number,
	CanDodge: boolean,
	CanParry: boolean,
	DodgePerfectTolerance: number,
	DodgeGoodTolerance: number,
	ParryPerfectTolerance: number,
	ParryGoodTolerance: number,
	DamageType: StateTypes.DamageType,
	RawDamage: number,
	Description: string?,
}

local ReactionData = {}

local DEFAULT_PROFILES: { [string]: AttackTimingProfile } = {
	["SlowHeavy"] = {
		AttackId = "SlowHeavy",
		AttackName = "Heavy Cleave",
		TelegraphDuration = 1.6,
		ImpactDelay = 1.45,
		RecoveryDuration = 0.35,
		CanDodge = true,
		CanParry = true,
		DodgePerfectTolerance = 0.15,
		DodgeGoodTolerance = 0.35,
		ParryPerfectTolerance = 0.08,
		ParryGoodTolerance = 0.20,
		DamageType = "Physical",
		RawDamage = 18,
		Description = "A slow, crushing axe swing with an obvious wind-up.",
	},
	["FastDagger"] = {
		AttackId = "FastDagger",
		AttackName = "Shadow Thrust",
		TelegraphDuration = 0.65,
		ImpactDelay = 0.55,
		RecoveryDuration = 0.25,
		CanDodge = true,
		CanParry = true,
		DodgePerfectTolerance = 0.10,
		DodgeGoodTolerance = 0.22,
		ParryPerfectTolerance = 0.06,
		ParryGoodTolerance = 0.14,
		DamageType = "Physical",
		RawDamage = 8,
		Description = "A rapid, lethal dagger thrust requiring quick reflexes.",
	},
	["BossHeavyStrike"] = {
		AttackId = "BossHeavyStrike",
		AttackName = "Cataclysmic Slam",
		TelegraphDuration = 2.2,
		ImpactDelay = 2.0,
		RecoveryDuration = 0.40,
		CanDodge = true,
		CanParry = true,
		DodgePerfectTolerance = 0.12,
		DodgeGoodTolerance = 0.30,
		ParryPerfectTolerance = 0.06,
		ParryGoodTolerance = 0.15,
		DamageType = "Physical",
		RawDamage = 26,
		Description = "A seismic boss slam requiring absolute pinpoint parry timing.",
	},
	["UnparryableCleave"] = {
		AttackId = "UnparryableCleave",
		AttackName = "Sweeping Torrent",
		TelegraphDuration = 1.2,
		ImpactDelay = 1.0,
		RecoveryDuration = 0.30,
		CanDodge = true,
		CanParry = false,
		DodgePerfectTolerance = 0.15,
		DodgeGoodTolerance = 0.35,
		ParryPerfectTolerance = 0.0,
		ParryGoodTolerance = 0.0,
		DamageType = "Physical",
		RawDamage = 14,
		Description = "A wide sweep that cannot be parried; hero must dodge.",
	},
	["UndodgeableImpale"] = {
		AttackId = "UndodgeableImpale",
		AttackName = "Piercing Spire",
		TelegraphDuration = 1.1,
		ImpactDelay = 0.95,
		RecoveryDuration = 0.30,
		CanDodge = false,
		CanParry = true,
		DodgePerfectTolerance = 0.0,
		DodgeGoodTolerance = 0.0,
		ParryPerfectTolerance = 0.08,
		ParryGoodTolerance = 0.18,
		DamageType = "Physical",
		RawDamage = 16,
		Description = "A pinpoint homing thrust that cannot be dodged; hero must parry.",
	},
	["UnreactableExplosion"] = {
		AttackId = "UnreactableExplosion",
		AttackName = "Volatile Detonation",
		TelegraphDuration = 0.8,
		ImpactDelay = 0.8,
		RecoveryDuration = 0.20,
		CanDodge = false,
		CanParry = false,
		DodgePerfectTolerance = 0.0,
		DodgeGoodTolerance = 0.0,
		ParryPerfectTolerance = 0.0,
		ParryGoodTolerance = 0.0,
		DamageType = "Fire",
		RawDamage = 20,
		Description = "An unavoidable room-wide blast; defense must come from shields.",
	},
}

function ReactionData.getProfile(id: string): AttackTimingProfile?
	local preset = DEFAULT_PROFILES[id]
	if preset then
		return {
			AttackId = preset.AttackId,
			AttackName = preset.AttackName,
			TelegraphDuration = preset.TelegraphDuration,
			ImpactDelay = preset.ImpactDelay,
			RecoveryDuration = preset.RecoveryDuration,
			CanDodge = preset.CanDodge,
			CanParry = preset.CanParry,
			DodgePerfectTolerance = preset.DodgePerfectTolerance,
			DodgeGoodTolerance = preset.DodgeGoodTolerance,
			ParryPerfectTolerance = preset.ParryPerfectTolerance,
			ParryGoodTolerance = preset.ParryGoodTolerance,
			DamageType = preset.DamageType,
			RawDamage = preset.RawDamage,
			Description = preset.Description,
		}
	end
	return nil
end

function ReactionData.createCustomProfile(
	attackId: string,
	attackName: string,
	rawDamage: number,
	damageType: StateTypes.DamageType,
	canDodge: boolean,
	canParry: boolean,
	telegraphDuration: number?,
	impactDelay: number?,
	recoveryDuration: number?,
	dodgePerfectTol: number?,
	dodgeGoodTol: number?,
	parryPerfectTol: number?,
	parryGoodTol: number?
): AttackTimingProfile
	local tDur = telegraphDuration or 1.2
	local iDelay = impactDelay or (tDur * 0.9)
	local rDur = recoveryDuration or 0.3

	return {
		AttackId = attackId,
		AttackName = attackName,
		TelegraphDuration = tDur,
		ImpactDelay = iDelay,
		RecoveryDuration = rDur,
		CanDodge = canDodge,
		CanParry = canParry,
		DodgePerfectTolerance = dodgePerfectTol or 0.15,
		DodgeGoodTolerance = dodgeGoodTol or 0.35,
		ParryPerfectTolerance = parryPerfectTol or 0.08,
		ParryGoodTolerance = parryGoodTol or 0.18,
		DamageType = damageType,
		RawDamage = rawDamage,
		Description = nil,
	}
end

function ReactionData.getAllProfiles(): { [string]: AttackTimingProfile }
	return DEFAULT_PROFILES
end

return ReactionData
