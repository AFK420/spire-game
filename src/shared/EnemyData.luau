--!strict

--[=[
	EnemyData
	Definition-driven Act 1 enemy roster, authored move cycles, and encounter
	compositions. Runtime EnemyState remains owned by CombatService.
]=]

local EnemyData = {}

export type IntentType = "Attack" | "Defend" | "Buff" | "Debuff"
export type TargetMode = "RandomPlayer" | "AllPlayers" | "Self" | "LowestHPAlly"

export type EnemyMoveDefinition = {
	Id: string,
	Type: IntentType,
	Description: string,
	Value: number?,
	AttackMultiplier: number?,
	AttackProfileId: string?,
	TargetMode: TargetMode?,
	StatusId: string?,
	StatusStacks: number?,
	BreakInterruptible: boolean?,
	InterruptText: string?,
	ArmorAfterAction: number?,
	EvasionAfterAction: number?,
	DefenseText: string?,
}

export type BossPhaseDefinition = {
	Phase: number,
	Name: string,
	StartHPRatio: number,
	TransitionShield: number?,
	Moves: { EnemyMoveDefinition },
}

export type EnemyDefinition = {
	Id: string,
	Name: string,
	Role: string,
	BaseHP: number,
	HPPerTier: number,
	BaseAttack: number,
	AttackPerTier: number,
	BaseArmor: number,
	BaseEvasion: number,
	OnAllyDefeatedAttackGain: number?,
	UsesInterruptMeter: boolean?,
	Moves: { EnemyMoveDefinition },
	BossPhases: { BossPhaseDefinition }?,
}

export type GeneratedIntent = {
	Type: IntentType,
	Value: number,
	Description: string?,
	MoveId: string?,
	AttackProfileId: string?,
	TargetMode: TargetMode?,
	StatusId: string?,
	StatusStacks: number?,
	BreakInterruptible: boolean?,
	InterruptText: string?,
	ArmorAfterAction: number?,
	EvasionAfterAction: number?,
	DefenseText: string?,
}

local DEFINITIONS: { [string]: EnemyDefinition } = {
	SpireSentinel = {
		Id = "SpireSentinel",
		Name = "Spire Sentinel",
		Role = "Baseline",
		BaseHP = 70,
		HPPerTier = 10,
		BaseAttack = 8,
		AttackPerTier = 1.5,
		BaseArmor = 8,
		BaseEvasion = 0.05,
		Moves = {
			{ Id = "MeasuredStrike", Type = "Attack", Description = "Measured Strike", AttackMultiplier = 1.0, AttackProfileId = "SlowHeavy", TargetMode = "RandomPlayer", ArmorAfterAction = 8, EvasionAfterAction = 0.05, DefenseText = "Balanced stance" },
			{ Id = "GuardStance", Type = "Defend", Description = "Guard Stance: Armor rises, Evasion falls", Value = 8, TargetMode = "Self", ArmorAfterAction = 20, EvasionAfterAction = 0.02, DefenseText = "Fortified stance" },
			{ Id = "QuickJab", Type = "Attack", Description = "Quick Jab: prepares an evasive stance", AttackMultiplier = 0.8, AttackProfileId = "FastDagger", TargetMode = "RandomPlayer", ArmorAfterAction = 4, EvasionAfterAction = 0.18, DefenseText = "Evasive stance" },
		},
	},
	Cultist = {
		Id = "Cultist",
		Name = "Dark Cultist",
		Role = "ScalingSupport",
		BaseHP = 42,
		HPPerTier = 6,
		BaseAttack = 5,
		AttackPerTier = 1.0,
		BaseArmor = 0,
		BaseEvasion = 0.12,
		Moves = {
			{ Id = "RitualChant", Type = "Buff", Description = "Ritual Chant: gains Attack", Value = 2, TargetMode = "Self" },
			{ Id = "VoidBolt", Type = "Attack", Description = "Void Bolt", AttackMultiplier = 1.0, AttackProfileId = "ProjectileBolt", TargetMode = "RandomPlayer" },
	},
	},
	ShieldPriest = {
		Id = "ShieldPriest",
		Name = "Ashen Shield Priest",
		Role = "Protector",
		BaseHP = 58,
		HPPerTier = 8,
		BaseAttack = 6,
		AttackPerTier = 1.0,
		BaseArmor = 5,
		BaseEvasion = 0.05,
		UsesInterruptMeter = true,
		Moves = {
			{ Id = "AegisTransfer", Type = "Defend", Description = "Aegis Transfer: shields the most wounded ally", Value = 12, TargetMode = "LowestHPAlly", BreakInterruptible = true, InterruptText = "BREAK TO CANCEL THE SHIELD" },
			{ Id = "Censure", Type = "Attack", Description = "Censure", AttackMultiplier = 0.85, AttackProfileId = "UnparryableCleave", TargetMode = "RandomPlayer", BreakInterruptible = false },
		},
	},
	BombCarrier = {
		Id = "BombCarrier",
		Name = "Cinder Bomb Carrier",
		Role = "Countdown",
		BaseHP = 50,
		HPPerTier = 7,
		BaseAttack = 8,
		AttackPerTier = 1.2,
		BaseArmor = 3,
		BaseEvasion = 0.03,
		UsesInterruptMeter = true,
		Moves = {
			{ Id = "FuseOne", Type = "Buff", Description = "Fuse 1/3: the bomb begins to hiss", Value = 2, TargetMode = "Self", BreakInterruptible = false },
			{ Id = "FuseTwo", Type = "Defend", Description = "Fuse 2/3: braces for detonation", Value = 7, TargetMode = "Self", BreakInterruptible = false },
			{ Id = "Detonate", Type = "Attack", Description = "DETONATE: unavoidable—prepare defenses", AttackMultiplier = 2.0, AttackProfileId = "UnreactableExplosion", TargetMode = "AllPlayers", BreakInterruptible = true, InterruptText = "BREAK TO CANCEL DETONATION" },
		},
	},
	SoulEater = {
		Id = "SoulEater",
		Name = "Hollow Soul Eater",
		Role = "Escalation",
		BaseHP = 82,
		HPPerTier = 10,
		BaseAttack = 9,
		AttackPerTier = 1.4,
		BaseArmor = 6,
		BaseEvasion = 0.08,
		OnAllyDefeatedAttackGain = 3,
		Moves = {
			{ Id = "ConsumeEchoes", Type = "Buff", Description = "Consume Echoes: gathers strength", Value = 3, TargetMode = "Self" },
			{ Id = "SoulRend", Type = "Attack", Description = "Soul Rend: parry-only pressure", AttackMultiplier = 1.15, AttackProfileId = "UndodgeableImpale", TargetMode = "RandomPlayer" },
		},
	},
	StormMage = {
		Id = "StormMage",
		Name = "Rift Storm Mage",
		Role = "ReactionControl",
		BaseHP = 62,
		HPPerTier = 8,
		BaseAttack = 9,
		AttackPerTier = 1.3,
		BaseArmor = 2,
		BaseEvasion = 0.16,
		Moves = {
			{ Id = "ArcBolt", Type = "Attack", Description = "Arc Bolt: incoming projectile", AttackMultiplier = 0.9, AttackProfileId = "ProjectileBolt", TargetMode = "RandomPlayer", ArmorAfterAction = 0, EvasionAfterAction = 0.22, DefenseText = "Stormstep: highly evasive" },
			{ Id = "StaticField", Type = "Attack", Description = "Static Field: MOVE OUT of the lightning zone", AttackMultiplier = 0.8, AttackProfileId = "LightningField", TargetMode = "AllPlayers", StatusId = "Shock", StatusStacks = 2, ArmorAfterAction = 2, EvasionAfterAction = 0.12, DefenseText = "Grounded channel" },
			{ Id = "StormBurst", Type = "Attack", Description = "Storm Burst: party-wide impact", AttackMultiplier = 1.25, AttackProfileId = "UnreactableExplosion", TargetMode = "AllPlayers", ArmorAfterAction = 8, EvasionAfterAction = 0.06, DefenseText = "Charged barrier" },
		},
	},
	GremlinNob = {
		Id = "GremlinNob",
		Name = "Gremlin Nob",
		Role = "EliteAggressor",
		BaseHP = 135,
		HPPerTier = 15,
		BaseAttack = 14,
		AttackPerTier = 2.0,
		BaseArmor = 10,
		BaseEvasion = 0.06,
		Moves = {
			{ Id = "CrushingLeap", Type = "Attack", Description = "Crushing Leap", AttackMultiplier = 1.0, AttackProfileId = "JumpAttack", TargetMode = "RandomPlayer" },
			{ Id = "Frenzy", Type = "Buff", Description = "Frenzy: permanently gains Attack", Value = 3, TargetMode = "Self" },
			{ Id = "HeavyClub", Type = "Attack", Description = "Heavy Club", AttackMultiplier = 1.2, AttackProfileId = "SlowHeavy", TargetMode = "RandomPlayer" },
		},
	},
	IronBulwark = {
		Id = "IronBulwark",
		Name = "Iron Bulwark",
		Role = "EliteDefender",
		BaseHP = 155,
		HPPerTier = 17,
		BaseAttack = 12,
		AttackPerTier = 1.8,
		BaseArmor = 22,
		BaseEvasion = 0.02,
		Moves = {
			{ Id = "Fortify", Type = "Defend", Description = "Fortify: massive Armor, almost no Evasion", Value = 20, TargetMode = "Self", ArmorAfterAction = 35, EvasionAfterAction = 0, DefenseText = "Fortress stance" },
			{ Id = "ShieldCrash", Type = "Attack", Description = "Shield Crash: drops Armor to gain mobility", AttackMultiplier = 1.15, AttackProfileId = "UnparryableCleave", TargetMode = "RandomPlayer", ArmorAfterAction = 12, EvasionAfterAction = 0.10, DefenseText = "Mobile bulwark stance" },
		},
	},
	SpireGuardian = {
		Id = "SpireGuardian",
		Name = "The Spire Guardian",
		Role = "ActBoss",
		BaseHP = 220,
		HPPerTier = 25,
		BaseAttack = 16,
		AttackPerTier = 3.0,
		BaseArmor = 16,
		BaseEvasion = 0.05,
		Moves = {
			{ Id = "Cataclysm", Type = "Attack", Description = "Cataclysmic Slam: heavy reactable strike", AttackMultiplier = 1.0, AttackProfileId = "BossHeavyStrike", TargetMode = "RandomPlayer" },
			{ Id = "GuardianShell", Type = "Defend", Description = "Guardian Shell", Value = 24, TargetMode = "Self" },
			{ Id = "VolatileCore", Type = "Attack", Description = "Volatile Core: unavoidable party attack", AttackMultiplier = 1.35, AttackProfileId = "UnreactableExplosion", TargetMode = "AllPlayers" },
		},
		BossPhases = {
			{
				Phase = 1,
				Name = "The Warden",
				StartHPRatio = 1.0,
				Moves = {
					{ Id = "Cataclysm", Type = "Attack", Description = "Cataclysmic Slam: heavy reactable strike", AttackMultiplier = 1.0, AttackProfileId = "BossHeavyStrike", TargetMode = "RandomPlayer" },
					{ Id = "GuardianShell", Type = "Defend", Description = "Guardian Shell", Value = 24, TargetMode = "Self" },
					{ Id = "VolatileCore", Type = "Attack", Description = "Volatile Core: unavoidable party attack", AttackMultiplier = 1.35, AttackProfileId = "UnreactableExplosion", TargetMode = "AllPlayers" },
				},
			},
			{
				Phase = 2,
				Name = "Fractured Sentinel",
				StartHPRatio = 0.70,
				TransitionShield = 20,
				Moves = {
					{ Id = "RiftSweep", Type = "Attack", Description = "Rift Sweep: DODGE the blade wave", AttackMultiplier = 1.05, AttackProfileId = "UnparryableCleave", TargetMode = "RandomPlayer" },
					{ Id = "FractureSlam", Type = "Attack", Description = "Fracture Slam: PARRY the focused blow", AttackMultiplier = 1.15, AttackProfileId = "UndodgeableImpale", TargetMode = "RandomPlayer" },
					{ Id = "CorePulse", Type = "Attack", Description = "Core Pulse: shield the whole party", AttackMultiplier = 1.25, AttackProfileId = "UnreactableExplosion", TargetMode = "AllPlayers" },
				},
			},
			{
				Phase = 3,
				Name = "Core Unbound",
				StartHPRatio = 0.35,
				TransitionShield = 30,
				Moves = {
					{ Id = "CoreOverload", Type = "Attack", Description = "CORE OVERLOAD: coordinate Heavy cards and Parries", AttackMultiplier = 1.45, AttackProfileId = "UnreactableExplosion", TargetMode = "AllPlayers", BreakInterruptible = true, InterruptText = "PARTY: BREAK TO STOP CORE OVERLOAD" },
					{ Id = "ShatterLeap", Type = "Attack", Description = "Shatter Leap: react to the impact", AttackMultiplier = 1.25, AttackProfileId = "JumpAttack", TargetMode = "RandomPlayer" },
					{ Id = "FinalImpale", Type = "Attack", Description = "Final Impale: PARRY ONLY", AttackMultiplier = 1.30, AttackProfileId = "UndodgeableImpale", TargetMode = "RandomPlayer" },
				},
			},
		},
	},
}

function EnemyData.getEnemy(id: string): EnemyDefinition?
	return DEFINITIONS[id]
end

function EnemyData.getAllEnemies(): { [string]: EnemyDefinition }
	return DEFINITIONS
end

function EnemyData.getEncounter(roomType: string, tier: number): { string }
	if roomType == "Act Boss" then
		return { "SpireGuardian" }
	elseif roomType == "Elite Monster" then
		return { if tier >= 6 then "IronBulwark" else "GremlinNob" }
	end

	if tier <= 2 then
		return { "SpireSentinel" }
	elseif tier <= 4 then
		return { "SpireSentinel", "ShieldPriest" }
	elseif tier <= 6 then
		return { "BombCarrier", "SpireSentinel" }
	elseif tier == 7 then
		return { "SoulEater", "Cultist" }
	else
		return { "StormMage", "ShieldPriest" }
	end
end

function EnemyData.getBossPhase(definitionId: string, phaseNumber: number): BossPhaseDefinition?
	local definition = DEFINITIONS[definitionId]
	if not definition or not definition.BossPhases then
		return nil
	end
	for _, phase in definition.BossPhases do
		if phase.Phase == phaseNumber then
			return phase
		end
	end
	return nil
end

function EnemyData.resolveBossPhase(definitionId: string, hp: number, maxHP: number): BossPhaseDefinition?
	local definition = DEFINITIONS[definitionId]
	if not definition or not definition.BossPhases or maxHP <= 0 then
		return nil
	end
	local hpRatio = math.clamp(hp / maxHP, 0, 1)
	local resolved = definition.BossPhases[1]
	for _, phase in definition.BossPhases do
		if hpRatio <= phase.StartHPRatio and phase.Phase >= resolved.Phase then
			resolved = phase
		end
	end
	return resolved
end

function EnemyData.createIntent(definitionId: string, moveIndex: number, attackPower: number, bossPhase: number?): GeneratedIntent
	local definition = DEFINITIONS[definitionId]
	if not definition then
		return {
			Type = "Attack",
			Value = math.max(1, attackPower),
			Description = "Basic Attack",
			AttackProfileId = "SlowHeavy",
			TargetMode = "RandomPlayer",
		}
	end

	local moves = definition.Moves
	if bossPhase then
		local phase = EnemyData.getBossPhase(definitionId, bossPhase)
		if phase then
			moves = phase.Moves
		end
	end
	if #moves == 0 then
		return {
			Type = "Attack",
			Value = math.max(1, attackPower),
			Description = "Basic Attack",
			AttackProfileId = "SlowHeavy",
			TargetMode = "RandomPlayer",
		}
	end

	local normalizedIndex = ((math.max(1, moveIndex) - 1) % #moves) + 1
	local move = moves[normalizedIndex]
	local value = move.Value or math.max(1, math.round(attackPower * (move.AttackMultiplier or 1)))
	return {
		Type = move.Type,
		Value = value,
		Description = move.Description,
		MoveId = move.Id,
		AttackProfileId = move.AttackProfileId,
		TargetMode = move.TargetMode or "RandomPlayer",
		StatusId = move.StatusId,
		StatusStacks = move.StatusStacks,
		BreakInterruptible = move.BreakInterruptible,
		InterruptText = move.InterruptText,
		ArmorAfterAction = move.ArmorAfterAction,
		EvasionAfterAction = move.EvasionAfterAction,
		DefenseText = move.DefenseText,
	}
end

function EnemyData.validateDefinitions(): (boolean, string?)
	for id, definition in DEFINITIONS do
		if id ~= definition.Id or definition.Name == "" or #definition.Moves == 0 then
			return false, "Invalid enemy definition: " .. tostring(id)
		end
		if definition.BaseArmor < 0 or definition.BaseEvasion < 0 or definition.BaseEvasion > 0.75 then
			return false, string.format("Enemy %s has invalid Armor/Evasion defenses.", id)
		end
		local defeatGain = definition.OnAllyDefeatedAttackGain
		if defeatGain and (defeatGain <= 0 or defeatGain ~= math.floor(defeatGain)) then
			return false, string.format("Enemy %s has invalid on-defeat Attack gain.", id)
		end
		local hasInterruptibleMove = false
		for _, move in definition.Moves do
			if move.Id == "" or move.Description == "" then
				return false, string.format("Enemy %s has invalid move data.", id)
			end
			if move.Type == "Attack" and not move.AttackProfileId then
				return false, string.format("Enemy %s attack %s lacks AttackProfileId.", id, move.Id)
			end
			if move.BreakInterruptible == true then
				hasInterruptibleMove = true
				if not move.InterruptText or move.InterruptText == "" then
					return false, string.format("Enemy %s interruptible move %s lacks InterruptText.", id, move.Id)
				end
			elseif move.InterruptText ~= nil then
				return false, string.format("Enemy %s move %s has InterruptText but is not interruptible.", id, move.Id)
			end
			if (move.ArmorAfterAction and move.ArmorAfterAction < 0)
				or (move.EvasionAfterAction and (move.EvasionAfterAction < 0 or move.EvasionAfterAction > 0.75)) then
				return false, string.format("Enemy %s move %s has invalid defense stance values.", id, move.Id)
			end
		end
		if definition.UsesInterruptMeter == true and not hasInterruptibleMove then
			return false, string.format("Enemy %s uses an interrupt meter without an interruptible move.", id)
		end
		if definition.BossPhases then
			local previousRatio = math.huge
			for expectedPhase, phase in definition.BossPhases do
				if phase.Phase ~= expectedPhase or phase.Name == "" or #phase.Moves == 0
					or phase.StartHPRatio <= 0 or phase.StartHPRatio > 1 or phase.StartHPRatio >= previousRatio
				then
					return false, string.format("Enemy %s has invalid boss phase %d.", id, expectedPhase)
				end
				previousRatio = phase.StartHPRatio
				for _, move in phase.Moves do
					if move.Id == "" or move.Description == "" or (move.Type == "Attack" and not move.AttackProfileId) then
						return false, string.format("Enemy %s phase %d has invalid move data.", id, phase.Phase)
					end
					if move.BreakInterruptible == true and (not move.InterruptText or move.InterruptText == "") then
						return false, string.format("Enemy %s phase %d interrupt lacks guidance.", id, phase.Phase)
					end
				end
			end
		end
	end
	return true, nil
end

return EnemyData
