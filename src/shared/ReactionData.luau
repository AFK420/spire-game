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
	AttackType: StateTypes.AttackType,
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
	ProjectileSpeed: number?,
	Description: string?,
}

local ReactionData = {}

local DEFAULT_PROFILES: { [string]: AttackTimingProfile } = {
	["SlowHeavy"] = {
		AttackId = "SlowHeavy",
		AttackName = "Heavy Cleave",
		AttackType = "Melee",
		TelegraphDuration = 1.6,
		ImpactDelay = 1.45,
		RecoveryDuration = 0.40,
		CanDodge = true,
		CanParry = true,
		DodgePerfectTolerance = 0.15,
		DodgeGoodTolerance = 0.35,
		ParryPerfectTolerance = 0.08,
		ParryGoodTolerance = 0.18,
		DamageType = "Physical",
		RawDamage = 18,
		ProjectileSpeed = nil,
		Description = "A slow, crushing axe swing with an obvious wind-up.",
	},
	["FastDagger"] = {
		AttackId = "FastDagger",
		AttackName = "Shadow Thrust",
		AttackType = "Melee",
		TelegraphDuration = 0.65,
		ImpactDelay = 0.55,
		RecoveryDuration = 0.25,
		CanDodge = true,
		CanParry = true,
		DodgePerfectTolerance = 0.08,
		DodgeGoodTolerance = 0.20,
		ParryPerfectTolerance = 0.05,
		ParryGoodTolerance = 0.12,
		DamageType = "Physical",
		RawDamage = 8,
		ProjectileSpeed = nil,
		Description = "A rapid, lethal dagger thrust requiring quick reflexes.",
	},
	["JumpAttack"] = {
		AttackId = "JumpAttack",
		AttackName = "Leaping Smash",
		AttackType = "Jump",
		TelegraphDuration = 1.4,
		ImpactDelay = 1.25,
		RecoveryDuration = 0.45,
		CanDodge = true,
		CanParry = true,
		DodgePerfectTolerance = 0.12,
		DodgeGoodTolerance = 0.30,
		ParryPerfectTolerance = 0.07,
		ParryGoodTolerance = 0.16,
		DamageType = "Physical",
		RawDamage = 22,
		ProjectileSpeed = nil,
		Description = "A high leap into the air slamming down onto the target at impact.",
	},
	["ProjectileBolt"] = {
		AttackId = "ProjectileBolt",
		AttackName = "Arcane Missile",
		AttackType = "Projectile",
		TelegraphDuration = 1.3,
		ImpactDelay = 1.10,
		RecoveryDuration = 0.30,
		CanDodge = true,
		CanParry = true,
		DodgePerfectTolerance = 0.12,
		DodgeGoodTolerance = 0.30,
		ParryPerfectTolerance = 0.06,
		ParryGoodTolerance = 0.16,
		DamageType = "Arcane",
		RawDamage = 14,
		ProjectileSpeed = 30,
		Description = "A visible arcane orb fired from the enemy that travels toward the player.",
	},
	["BossHeavyStrike"] = {
		AttackId = "BossHeavyStrike",
		AttackName = "Cataclysmic Slam",
		AttackType = "Melee",
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
		ProjectileSpeed = nil,
		Description = "A seismic boss slam requiring absolute pinpoint parry timing.",
	},
	["UnparryableCleave"] = {
		AttackId = "UnparryableCleave",
		AttackName = "Sweeping Torrent",
		AttackType = "Melee",
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
		ProjectileSpeed = nil,
		Description = "A wide sweep that cannot be parried; hero must dodge.",
	},
	["UndodgeableImpale"] = {
		AttackId = "UndodgeableImpale",
		AttackName = "Piercing Spire",
		AttackType = "Melee",
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
		ProjectileSpeed = nil,
		Description = "A pinpoint homing thrust that cannot be dodged; hero must parry.",
	},
	["UnreactableExplosion"] = {
		AttackId = "UnreactableExplosion",
		AttackName = "Volatile Detonation",
		AttackType = "AoE",
		TelegraphDuration = 1.0,
		ImpactDelay = 1.0,
		RecoveryDuration = 0.30,
		CanDodge = false,
		CanParry = false,
		DodgePerfectTolerance = 0.0,
		DodgeGoodTolerance = 0.0,
		ParryPerfectTolerance = 0.0,
		ParryGoodTolerance = 0.0,
		DamageType = "Fire",
		RawDamage = 20,
		ProjectileSpeed = nil,
		Description = "An unavoidable room-wide blast; defense must come from shields.",
	},
}

function ReactionData.getProfile(id: string): AttackTimingProfile?
	local preset = DEFAULT_PROFILES[id]
	if preset then
		return {
			AttackId = preset.AttackId,
			AttackName = preset.AttackName,
			AttackType = preset.AttackType,
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
			ProjectileSpeed = preset.ProjectileSpeed,
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
	parryGoodTol: number?,
	attackType: StateTypes.AttackType?,
	projectileSpeed: number?
): AttackTimingProfile
	local tDur = telegraphDuration or 1.2
	local iDelay = impactDelay or (tDur * 0.9)
	local rDur = recoveryDuration or 0.3

	return {
		AttackId = attackId,
		AttackName = attackName,
		AttackType = attackType or "Melee",
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
		ProjectileSpeed = projectileSpeed,
		Description = nil,
	}
end

function ReactionData.getAllProfiles(): { [string]: AttackTimingProfile }
	return DEFAULT_PROFILES
end

return ReactionData
