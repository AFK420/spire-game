--!strict

--[=[
	GameConfig ModuleScript
	Mapped to: ReplicatedStorage.Shared.GameConfig
	Centralized configuration parameters, tuning constants, and scaling formulas
	for Card Rift: Co-op Dungeon.
	Decouples gameplay balance and tuning from core system architecture.
]=]

local GameConfig = {}

--------------------------------------------------------------------------------
-- Combat Tuning
--------------------------------------------------------------------------------

GameConfig.Combat = {
	TurnDuration = 45,            -- Monotonic seconds per player turn
	DefaultBaseHP = 100,          -- Fallback hero Max HP
	DefaultStartingEnergy = 3,    -- Fallback hero starting energy
	BaseHandDrawCount = 4,        -- Cards drawn at the beginning of each turn
	MaxTurnHistoryLog = 25,       -- Maximum entries preserved in active combat log
}

--------------------------------------------------------------------------------
-- Co-op Multiplayer Scaling & Team Mechanics
--------------------------------------------------------------------------------

GameConfig.Coop = {
	MaxPartySize = 4,             -- Maximum players in a single run
	MinPartySize = 1,
	RescueEnergyCost = 2,         -- Energy cost to rescue a downed teammate
	ReviveHpPercent = 0.25,       -- Downed players revive with 25% of Max HP

	-- Co-op enemy stat scaling multipliers per additional player
	-- ScaledHP = BaseHP * (1 + 0.65 * (PlayerCount - 1))
	-- ScaledAtk = BaseAtk * (1 + 0.20 * (PlayerCount - 1))
	EnemyHpScaleMultiplier = 0.65,
	EnemyAtkScaleMultiplier = 0.20,
}

function GameConfig.scaleEnemyHp(baseHp: number, playerCount: number): number
	local clamped = math.clamp(playerCount, GameConfig.Coop.MinPartySize, GameConfig.Coop.MaxPartySize)
	return math.round(baseHp * (1 + GameConfig.Coop.EnemyHpScaleMultiplier * (clamped - 1)))
end

function GameConfig.scaleEnemyAttack(baseAtk: number, playerCount: number): number
	local clamped = math.clamp(playerCount, GameConfig.Coop.MinPartySize, GameConfig.Coop.MaxPartySize)
	return math.round(baseAtk * (1 + GameConfig.Coop.EnemyAtkScaleMultiplier * (clamped - 1)))
end

--------------------------------------------------------------------------------
-- Dungeon Run & Progression Tuning
--------------------------------------------------------------------------------

GameConfig.Dungeon = {
	StarterGold = 50,             -- Gold granted at expedition start
	CampfireHealPercent = 0.30,   -- Fraction of Max HP recovered at Campfire Rest
}

--------------------------------------------------------------------------------
-- Encounter Rewards & Drafting
--------------------------------------------------------------------------------

GameConfig.Rewards = {
	BaseCombatGold = 25,
	BaseCombatShards = 5,
	EliteBonusGold = 25,
	EliteBonusShards = 5,
	BossBonusGold = 50,
	BossBonusShards = 15,
	CardDraftChoicesCount = 3,    -- Number of cards offered in universal post-combat draft
}

--------------------------------------------------------------------------------
-- Network Security & Rate Limiting Thresholds
--------------------------------------------------------------------------------

GameConfig.NetworkLimits = {
	Combat = { MaxTokens = 6, RefillRate = 3.0 },
	Map = { MaxTokens = 3, RefillRate = 1.0 },
	Class = { MaxTokens = 3, RefillRate = 1.0 },
	General = { MaxTokens = 4, RefillRate = 2.0 },
}

--------------------------------------------------------------------------------
-- Phase 4 Deck & Collection System Configuration
--------------------------------------------------------------------------------

GameConfig.Deck = {
	BaseDeckSlots = 4,            -- Free base deck slots granted to all accounts
	MaxDeckSlots = 20,           -- Maximum entitlement cap for safety
	MinDeckSize = 8,             -- Minimum cards required in a valid playable deck
	MaxDeckSize = 30,            -- Maximum cards allowed in a deck
	MaxCopiesPerCard = 3,        -- Maximum copies of the same card allowed in a deck
	MaxDeckNameLength = 30,      -- Maximum character length for deck names
}

GameConfig.StarterCollection = {
	-- Default starter card definitions and quantities granted to new accounts
	DefaultCards = {
		["Strike"] = 5,
		["Defend"] = 5,
		["HeavyBlow"] = 2,
		["RageSlash"] = 2,
		["ShieldSlam"] = 2,
		["FirstAid"] = 2,
		["PoisonDart"] = 2,
	} :: { [string]: number },

	-- Default starter deck configuration
	DefaultDeckName = "Starter Deck",
	DefaultDeckClass = "Warlord",
	DefaultDeckCards = {
		["Strike"] = 3,
		["Defend"] = 2,
		["HeavyBlow"] = 1,
		["RageSlash"] = 1,
		["ShieldSlam"] = 1,
	} :: { [string]: number },
}

--------------------------------------------------------------------------------
-- Automated Testing Configuration
--------------------------------------------------------------------------------

GameConfig.Testing = {
	AutoRunTestsInStudio = true,
}

return GameConfig
