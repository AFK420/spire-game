--!strict

--[=[
	EventData ModuleScript
	Mapped to: ReplicatedStorage.Shared.EventData
	Data-driven definitions for 3D event rooms in Card Rift: Co-op Dungeon.
	Defines event categories, reward/penalty configurations, and puzzle templates.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)

local EventData = {}

export type EventInteractableDef = {
	Id: string,
	Name: string,
	Type: string,
	Label: string?,
	DefaultActive: boolean?,
}

export type EventRewardConfig = {
	Gold: number?,
	AetherShards: number?,
	HealPercent: number?,
	CardDraft: boolean?,
}

export type EventPenaltyConfig = {
	DamagePercent: number?,
	GoldLoss: number?,
}

export type StatueRiddleChoice = {
	StatueId: string,
	StatueName: string,
	Clue: string,
	AnswerKey: string,
}

export type EventDefinition = {
	Id: string,
	Name: string,
	Description: string,
	Category: StateTypes.EventCategory,
	MaxAttempts: number,
	Reward: EventRewardConfig,
	FailurePenalty: EventPenaltyConfig,
	Interactables: { EventInteractableDef },
	PuzzleDefinitionId: string?,
	RuneSymbols: { string }?,
	RiddlePrompt: string?,
	Statues: { StatueRiddleChoice }?,
}

local EVENT_DEFINITIONS: { [string]: EventDefinition } = {
	["rune_sequence_puzzle"] = {
		Id = "rune_sequence_puzzle",
		Name = "Chamber of Elemental Runes",
		Description = "Four ancient elemental runes hum with latent energy. Touch them in the sacred sequence inscribed upon the stones.",
		Category = "Puzzle",
		MaxAttempts = 3,
		Reward = {
			Gold = 40,
			AetherShards = 10,
			CardDraft = true,
		},
		FailurePenalty = {
			DamagePercent = 0.15,
			GoldLoss = 10,
		},
		Interactables = {
			{ Id = "Rune_Fire", Name = "Ignis Rune", Type = "Rune", Label = "🔥 Touch Ignis Rune", DefaultActive = true },
			{ Id = "Rune_Water", Name = "Aqua Rune", Type = "Rune", Label = "💧 Touch Aqua Rune", DefaultActive = true },
			{ Id = "Rune_Earth", Name = "Terra Rune", Type = "Rune", Label = "🌿 Touch Terra Rune", DefaultActive = true },
			{ Id = "Rune_Air", Name = "Aero Rune", Type = "Rune", Label = "💨 Touch Aero Rune", DefaultActive = true },
		},
		RuneSymbols = { "Rune_Fire", "Rune_Water", "Rune_Earth", "Rune_Air" },
	},

	["statue_riddle"] = {
		Id = "statue_riddle",
		Name = "The Triad of Ancient Sentinels",
		Description = "Three ornate marble statues guard an offering chest. Only the sentinel speaking the truth of the riddle unlocks the treasure.",
		Category = "Riddle",
		MaxAttempts = 1,
		Reward = {
			Gold = 50,
			AetherShards = 15,
			HealPercent = 0.20,
		},
		FailurePenalty = {
			DamagePercent = 0.20,
			GoldLoss = 0,
		},
		Interactables = {
			{ Id = "Statue_Valor", Name = "Sentinel of Valor", Type = "Statue", Label = "⚔️ Inquire Sentinel of Valor", DefaultActive = true },
			{ Id = "Statue_Wisdom", Name = "Sentinel of Wisdom", Type = "Statue", Label = "📜 Inquire Sentinel of Wisdom", DefaultActive = true },
			{ Id = "Statue_Shadows", Name = "Sentinel of Shadows", Type = "Statue", Label = "🌑 Inquire Sentinel of Shadows", DefaultActive = true },
		},
		RiddlePrompt = "I speak without a mouth and hear without ears. I have no body, but I come alive with wind. Whom do I serve?",
		Statues = {
			{
				StatueId = "Statue_Valor",
				StatueName = "Sentinel of Valor",
				Clue = "'The sword cuts deep, but it leaves no whisper upon the wind. I answer: The Battle Cry!'",
				AnswerKey = "BattleCry",
			},
			{
				StatueId = "Statue_Wisdom",
				StatueName = "Sentinel of Wisdom",
				Clue = "'It rebounds from stone and repeats the words of those who call. I answer: The Echo!'",
				AnswerKey = "Echo",
			},
			{
				StatueId = "Statue_Shadows",
				StatueName = "Sentinel of Shadows",
				Clue = "'It creeps in darkness and swallows all breath unseen. I answer: The Void!'",
				AnswerKey = "Void",
			},
		},
	},
}

function EventData.getDefinition(eventId: string): EventDefinition?
	return EVENT_DEFINITIONS[eventId]
end

function EventData.getAllDefinitions(): { [string]: EventDefinition }
	return EVENT_DEFINITIONS
end

function EventData.pickRandomEventId(seed: number): string
	local rng = Random.new(seed)
	local keys = { "rune_sequence_puzzle", "statue_riddle" }
	return keys[rng:NextInteger(1, #keys)]
end

return EventData
