--!strict

--[=[
	EnvironmentData ModuleScript
	Mapped to: ReplicatedStorage.Shared.EnvironmentData
	Authoritative data-driven definitions for 3D combat environments in Card Rift: Co-op Dungeon.
	Defines elemental affinities, status interactions, healing scaling, and environmental transformations.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)

local EnvironmentData = {}

export type EnvironmentalTransformation = {
	TriggerDamageType: StateTypes.DamageType,
	ResultEnvironmentId: StateTypes.EnvironmentId?,
	HazardCreated: string?,
	NotificationText: string,
}

export type EnvironmentDefinition = {
	Id: StateTypes.EnvironmentId,
	Name: string,
	Description: string,
	Icon: string,
	VisualPresetId: string,
	Tags: { [string]: boolean },
	DamageModifiers: { [StateTypes.DamageType]: number },
	StatusModifiers: { [string]: { DurationBonus: number?, StacksBonus: number? } },
	HealingModifier: number,
	Transformations: { EnvironmentalTransformation }?,
}

local ENVIRONMENT_DEFINITIONS: { [StateTypes.EnvironmentId]: EnvironmentDefinition } = {
	["RainSoaked"] = {
		Id = "RainSoaked",
		Name = "Rain-Soaked Sanctum",
		Description = "Torrents of rain pour upon the stones. Fire attacks sputter and weaken, while lightning arcs with lethal intensity.",
		Icon = "🌧️",
		VisualPresetId = "RainPreset",
		Tags = { ["Wet"] = true, ["Water"] = true },
		DamageModifiers = {
			["Fire"] = 0.70,      -- -30% Fire damage
			["Lightning"] = 1.30, -- +30% Lightning damage
		},
		StatusModifiers = {
			["Ignite"] = { DurationBonus = -1 },
			["Shock"] = { DurationBonus = 1, StacksBonus = 2 },
		},
		HealingModifier = 1.0,
		Transformations = {
			{
				TriggerDamageType = "Cold",
				ResultEnvironmentId = "FrozenWastes",
				HazardCreated = nil,
				NotificationText = "❄️ Flash Freeze: The wet ground freezes into permafrost!",
			},
			{
				TriggerDamageType = "Lightning",
				ResultEnvironmentId = nil,
				HazardCreated = "ElectricField",
				NotificationText = "⚡ Electrified Water: Lightning surges through the puddles!",
			},
		},
	},

	["LavaCavern"] = {
		Id = "LavaCavern",
		Name = "Infernal Lava Cavern",
		Description = "Rivers of molten magma roast the cavern air. Flames rage uncontrollably, but frost instantly evaporates.",
		Icon = "🌋",
		VisualPresetId = "LavaPreset",
		Tags = { ["Heat"] = true, ["Fire"] = true },
		DamageModifiers = {
			["Fire"] = 1.30, -- +30% Fire damage
			["Cold"] = 0.70, -- -30% Cold damage
		},
		StatusModifiers = {
			["Ignite"] = { StacksBonus = 2 },
			["Chill"] = { DurationBonus = -1 },
		},
		HealingModifier = 1.0,
		Transformations = {
			{
				TriggerDamageType = "Cold",
				ResultEnvironmentId = nil,
				HazardCreated = "SteamVeil",
				NotificationText = "💨 Steam Eruption: Cold clashes with magma, creating blinding steam!",
			},
		},
	},

	["FrozenWastes"] = {
		Id = "FrozenWastes",
		Name = "Glacial Hollow",
		Description = "Subzero blizzards howl through frozen stalactites. Frost magic penetrates deep, chilling blood and bone.",
		Icon = "❄️",
		VisualPresetId = "FrozenPreset",
		Tags = { ["Cold"] = true, ["Ice"] = true },
		DamageModifiers = {
			["Cold"] = 1.30, -- +30% Cold damage
			["Fire"] = 0.70, -- -30% Fire damage
		},
		StatusModifiers = {
			["Chill"] = { DurationBonus = 1, StacksBonus = 1 },
			["Freeze"] = { DurationBonus = 1 },
		},
		HealingModifier = 1.0,
		Transformations = {
			{
				TriggerDamageType = "Fire",
				ResultEnvironmentId = "RainSoaked",
				HazardCreated = nil,
				NotificationText = "💧 Thawing Heat: Blazing fire melts the ice into pouring rain!",
			},
		},
	},

	["ToxicSwamp"] = {
		Id = "ToxicSwamp",
		Name = "Mire of Noxious Spores",
		Description = "Fetid mists and putrid slime pool across the soil. Venoms fester with unnatural virulence, choking cellular recovery.",
		Icon = "☣️",
		VisualPresetId = "ToxicPreset",
		Tags = { ["Toxic"] = true, ["Poison"] = true },
		DamageModifiers = {
			["Venom"] = 1.30, -- +30% Venom damage
			["Acid"] = 1.30,  -- +30% Acid damage
			["Physical"] = 1.0,
		},
		StatusModifiers = {
			["Poison"] = { StacksBonus = 2 },
			["Bleed"] = { StacksBonus = 1 },
		},
		HealingModifier = 0.75, -- -25% healing effectiveness
		Transformations = {
			{
				TriggerDamageType = "Fire",
				ResultEnvironmentId = nil,
				HazardCreated = "CombustingMire",
				NotificationText = "💥 Miasma Ignition: The toxic fumes ignite into a brief fiery blast!",
			},
		},
	},

	["ArcaneStorm"] = {
		Id = "ArcaneStorm",
		Name = "Astral Ley-Storm",
		Description = "Rifts of raw astral energy ripple through the air. Lightning, Void, and Sonic powers resonate with volatile frequencies.",
		Icon = "🔮",
		VisualPresetId = "ArcanePreset",
		Tags = { ["Astral"] = true, ["Arcane"] = true },
		DamageModifiers = {
			["Lightning"] = 1.25, -- +25% Lightning
			["Void"] = 1.25,      -- +25% Void
			["Sonic"] = 1.25,     -- +25% Sonic
		},
		StatusModifiers = {
			["Shock"] = { StacksBonus = 2 },
		},
		HealingModifier = 1.10, -- +10% magical healing resonance
		Transformations = {},
	},
}

function EnvironmentData.getDefinition(envId: StateTypes.EnvironmentId): EnvironmentDefinition?
	return ENVIRONMENT_DEFINITIONS[envId]
end

function EnvironmentData.getAllDefinitions(): { [StateTypes.EnvironmentId]: EnvironmentDefinition }
	return ENVIRONMENT_DEFINITIONS
end

function EnvironmentData.pickDeterministicEnvironment(actIndex: number, seed: number): StateTypes.EnvironmentId
	local rng = Random.new(seed)
	local candidates: { StateTypes.EnvironmentId } = {}

	if actIndex == 1 then
		candidates = { "RainSoaked", "LavaCavern", "ToxicSwamp" }
	elseif actIndex == 2 then
		candidates = { "RainSoaked", "FrozenWastes", "ToxicSwamp" }
	elseif actIndex == 3 then
		candidates = { "FrozenWastes", "ArcaneStorm", "LavaCavern" }
	else
		candidates = { "ArcaneStorm", "LavaCavern", "FrozenWastes", "ToxicSwamp" }
	end

	return candidates[rng:NextInteger(1, #candidates)]
end

return EnvironmentData
