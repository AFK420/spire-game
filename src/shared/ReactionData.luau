--!strict

--[=[
	ReactionData ModuleScript
	Mapped to: ReplicatedStorage.Shared.ReactionData
	Data-driven attack timing profiles for the 3D Attack Reaction System.
	1. Defines telegraph duration, impact delay, and recovery timing per attack type.
	   - AttackStartServerTime: Authoritative Workspace:GetServerTimeNow() timestamp when attack begins.
	   - TelegraphDuration: Intentional visible anticipation / windup duration before active motion.
	   - ImpactDelay: Total duration from AttackStartServerTime to impact (ImpactServerTime = AttackStart + ImpactDelay).
	   - Projectiles: ImpactDelay = TelegraphDuration + travelTime (where travelTime = distance / ProjectileSpeed).
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
	AvoidanceMode: StateTypes.AvoidanceMode?,
	HazardRadius: number?,
	Description: string?,
}

local ReactionData = {}

local DEFAULT_PROFILES: { [string]: AttackTimingProfile } = {
	["SlowHeavy"] = {
		AttackId = "SlowHeavy",
		AttackName = "Heavy Cleave",
		AttackType = "Melee",
		TelegraphDuration = 1.0,
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
		TelegraphDuration = 0.30,
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
		TelegraphDuration = 0.50,
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
		TelegraphDuration = 0.40,
		ImpactDelay = 1.10,
		RecoveryDuration = 0.30,
		CanDodge = true,
		CanParry = true,
		DodgePerfectTolerance = 0.12,
		DodgeGoodTolerance = 0.30,
		ParryPerfectTolerance = 0.06,
		ParryGoodTolerance = 0.16,
		DamageType = "Void",
		RawDamage = 14,
		ProjectileSpeed = 30,
		Description = "A visible arcane orb fired from the enemy that travels toward the player.",
	},
	["BossHeavyStrike"] = {
		AttackId = "BossHeavyStrike",
		AttackName = "Cataclysmic Slam",
		AttackType = "Melee",
		TelegraphDuration = 1.40,
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
		TelegraphDuration = 0.60,
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
		TelegraphDuration = 0.50,
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
		TelegraphDuration = 0.80,
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
		AvoidanceMode = "DefenseOnly",
		Description = "An unavoidable room-wide blast; defense must come from shields.",
	},
	["LightningField"] = {
		AttackId = "LightningField",
		AttackName = "Static Lightning Field",
		AttackType = "AoE",
		TelegraphDuration = 1.80,
		ImpactDelay = 2.0,
		RecoveryDuration = 0.30,
		CanDodge = false,
		CanParry = false,
		DodgePerfectTolerance = 0.0,
		DodgeGoodTolerance = 0.0,
		ParryPerfectTolerance = 0.0,
		ParryGoodTolerance = 0.0,
		DamageType = "Lightning",
		RawDamage = 8,
		ProjectileSpeed = nil,
		AvoidanceMode = "Movement",
		HazardRadius = 7,
		Description = "A marked lightning zone. Physically move outside the circle before impact.",
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
			AvoidanceMode = preset.AvoidanceMode,
			HazardRadius = preset.HazardRadius,
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
	local iDelay = impactDelay or 1.2
	local tDur = telegraphDuration or math.min(iDelay * 0.75, iDelay)
	if tDur > iDelay then
		tDur = iDelay
	end
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

function ReactionData.resolveProjectileTiming(
	distance: number,
	projectileSpeed: number,
	castWindup: number?
): (number, number)
	local windup = math.max(0.15, castWindup or 0.35)
	local safeSpeed = math.max(1, projectileSpeed)
	local travelTime = math.clamp(distance / safeSpeed, 0.25, 3.0)
	local impactDelay = math.round((windup + travelTime) * 100) / 100
	return windup, impactDelay
end

function ReactionData.getAllProfiles(): { [string]: AttackTimingProfile }
	return DEFAULT_PROFILES
end

return ReactionData
