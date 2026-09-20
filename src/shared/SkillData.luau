--!strict
--[=[
	SkillData ModuleScript
	Mapped to: ReplicatedStorage.Shared.SkillData

	Canonical active skill catalog and schemas for Card Rift: Co-op Dungeon (Phase 3).
	Active skills are non-card, cooldown-managed, energy-costed combat abilities.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local CardData = require(Shared:WaitForChild("CardData") :: ModuleScript)

local SkillData = {}

--------------------------------------------------------------------------------
-- Exported Types
--------------------------------------------------------------------------------

export type SkillSlot = "Skill1" | "Skill2" | "Skill3" | "Skill4"

export type SkillCost = {
	Energy: number,
	HP: number?,
}

export type SkillDefinition = {
	Id: string,
	Name: string,
	Description: string,
	Target: CardData.TargetType,
	Cost: SkillCost,
	CooldownTurns: number,
	Accuracy: number,
	Effects: { CardData.Effect },
	Tags: { string },
	RequiredClassId: string?,
}

--------------------------------------------------------------------------------
-- Master Skill Catalog (Phase 3 Foundation)
--------------------------------------------------------------------------------

local SKILL_REGISTRY: { [string]: SkillDefinition } = {
	["HeroicStrike"] = {
		Id = "HeroicStrike",
		Name = "Heroic Strike",
		Description = "Deliver a crushing strike dealing 12 physical damage.",
		Target = "Enemy",
		Cost = {
			Energy = 1,
		},
		CooldownTurns = 1,
		Accuracy = 0.90,
		Effects = {
			{
				Type = "Damage",
				Value = 12,
				DamageType = "Physical",
				Target = "Enemy",
			},
		},
		Tags = { "Attack", "Physical" },
		RequiredClassId = nil,
	},

	["AegisBarrier"] = {
		Id = "AegisBarrier",
		Name = "Aegis Barrier",
		Description = "Raise a defensive barrier granting 10 shield.",
		Target = "Self",
		Cost = {
			Energy = 1,
		},
		CooldownTurns = 2,
		Accuracy = 1.00,
		Effects = {
			{
				Type = "Shield",
				Value = 10,
				Target = "Self",
			},
		},
		Tags = { "Defensive", "Shield" },
		RequiredClassId = nil,
	},

	["BattleRally"] = {
		Id = "BattleRally",
		Name = "Battle Rally",
		Description = "Inspire your party, granting 6 shield and 4 healing.",
		Target = "Self",
		Cost = {
			Energy = 2,
		},
		CooldownTurns = 3,
		Accuracy = 1.00,
		Effects = {
			{
				Type = "Shield",
				Value = 6,
				Target = "Self",
			},
			{
				Type = "Heal",
				Value = 4,
				Target = "Self",
			},
		},
		Tags = { "Support", "Buff" },
		RequiredClassId = nil,
	},

	["Whirlwind"] = {
		Id = "Whirlwind",
		Name = "Whirlwind",
		Description = "A ferocious whirlwind attack dealing 8 physical damage.",
		Target = "Enemy",
		Cost = {
			Energy = 2,
		},
		CooldownTurns = 2,
		Accuracy = 0.85,
		Effects = {
			{
				Type = "Damage",
				Value = 8,
				DamageType = "Physical",
				Target = "Enemy",
			},
		},
		Tags = { "Attack", "Physical", "AoE" },
		RequiredClassId = nil,
	},

	["ShieldBash"] = {
		Id = "ShieldBash",
		Name = "Shield Bash",
		Description = "Bash the target with your shield dealing 10 physical damage.",
		Target = "Enemy",
		Cost = {
			Energy = 1,
		},
		CooldownTurns = 2,
		Accuracy = 0.88,
		Effects = {
			{
				Type = "Damage",
				Value = 10,
				DamageType = "Physical",
				Target = "Enemy",
			},
		},
		Tags = { "Attack", "Physical" },
		RequiredClassId = nil,
	},
}

--------------------------------------------------------------------------------
-- Public Query API
--------------------------------------------------------------------------------

-- Registers a skill definition (for testing or extensibility)
function SkillData.registerSkill(skill: SkillDefinition)
	SKILL_REGISTRY[skill.Id] = skill
end

-- Fetches an immutable skill definition by Id
function SkillData.getSkill(skillId: string): SkillDefinition?
	return SKILL_REGISTRY[skillId]
end

-- Returns the full registry of skills
function SkillData.getAllSkills(): { [string]: SkillDefinition }
	return SKILL_REGISTRY
end

-- Kept for API compatibility: active skills, like cards, belong to the shared
-- build pool and are never filtered by the selected hero class.
function SkillData.getSkillsForClass(_classId: string?): { SkillDefinition }
	local result: { SkillDefinition } = {}
	for _, skill in SKILL_REGISTRY do
		table.insert(result, skill)
	end
	return result
end

-- Validates skill schema
function SkillData.validateSkill(skill: SkillDefinition): (boolean, string?)
	if not skill.Id or skill.Id == "" then
		return false, "Skill Id must not be empty."
	end
	if not skill.Name or skill.Name == "" then
		return false, "Skill Name must not be empty."
	end
	if skill.CooldownTurns < 0 then
		return false, "CooldownTurns cannot be negative."
	end
	if skill.Accuracy <= 0 or skill.Accuracy > 1 then
		return false, "Skill Accuracy must be within (0, 1]."
	end
	if not skill.Cost or skill.Cost.Energy < 0 then
		return false, "Skill cost must specify non-negative Energy."
	end
	if #skill.Effects == 0 then
		return false, "Skill must have at least one effect."
	end
	return true, nil
end

return SkillData
