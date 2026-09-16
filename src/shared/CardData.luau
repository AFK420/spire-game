--!strict

--[=[
	CardData ModuleScript
	Mapped to: ReplicatedStorage.Shared.CardData
	Defines the core card library and class signature cards for Card Rift: Co-op Dungeon.
]=]

export type EffectType =
	| "Damage"
	| "Shield"
	| "Poison"
	| "Revive"
	| "Heal"
	| "ApplyStatus"
	| "RemoveStatus"
	| "Draw"
	| "Discard"
	| "Exhaust"
	| "GainEnergy"
	| "LoseEnergy"
	| "CreateCard"
	| "ModifyResource"
	| "TriggerEvent"

export type TargetType = "Enemy" | "Self" | "Ally" | "None"

export type ResourceType = "HP" | "MaxHP" | "Shield" | "Energy" | "MaxEnergy" | "Gold"

export type Effect = {
	Type: EffectType,
	Value: number?,
	Target: TargetType?,
	StatusId: string?,
	Stacks: number?,
	Duration: number?,
	DamageType: string?,
	Tags: { string }?,
	Condition: string?,
	CardDefId: string?, -- Definition ID of card to create for CreateCard effect
	DestinationPile: string?, -- Target pile for CreateCard effect ("Deck", "Hand", "DiscardPile", "ExhaustPile"; defaults to "Deck")
	Resource: ResourceType?,
	EventId: string?,
}

export type Card = {
	Id: string,
	Name: string,
	Cost: number,
	Target: TargetType,
	Effects: { Effect },
	Description: string,
	Color: Color3,
	Icon: string,
}

--------------------------------------------------------------------------------
-- Core Generic Cards
--------------------------------------------------------------------------------

local Strike: Card = {
	Id = "Strike",
	Name = "Strike",
	Cost = 1,
	Target = "Enemy",
	Effects = {
		{ Type = "Damage", Value = 6 },
	},
	Description = "Deal 6 damage to an enemy.",
	Color = Color3.fromRGB(195, 55, 55),
	Icon = "⚔️",
}

local Defend: Card = {
	Id = "Defend",
	Name = "Defend",
	Cost = 1,
	Target = "Self",
	Effects = {
		{ Type = "Shield", Value = 5 },
	},
	Description = "Gain 5 Shield.",
	Color = Color3.fromRGB(45, 115, 205),
	Icon = "🛡️",
}

local HeavyBlow: Card = {
	Id = "HeavyBlow",
	Name = "Heavy Blow",
	Cost = 2,
	Target = "Enemy",
	Effects = {
		{ Type = "Damage", Value = 14 },
	},
	Description = "Deal 14 damage to an enemy.",
	Color = Color3.fromRGB(220, 110, 35),
	Icon = "💥",
}

local PoisonDart: Card = {
	Id = "PoisonDart",
	Name = "Poison Dart",
	Cost = 1,
	Target = "Enemy",
	Effects = {
		{ Type = "Damage", Value = 3, Target = "Enemy" },
		{ Type = "ApplyStatus", Value = 3, StatusId = "Poison", Stacks = 3, Target = "Enemy" },
	},
	Description = "Deal 3 damage and apply 3 Poison.",
	Color = Color3.fromRGB(40, 160, 80),
	Icon = "🧪",
}

local FirstAid: Card = {
	Id = "FirstAid",
	Name = "First Aid",
	Cost = 2,
	Target = "Ally",
	Effects = {
		{ Type = "Revive", Value = 30, Target = "Ally", Condition = "TargetDowned" },
		{ Type = "Heal", Value = 30, Target = "Ally", Condition = "TargetLiving" },
	},
	Description = "Revive a downed ally with 30 HP, or restore 30 HP to an active ally.",
	Color = Color3.fromRGB(30, 185, 145),
	Icon = "💖",
}

--------------------------------------------------------------------------------
-- Class Signature Cards
--------------------------------------------------------------------------------

-- Warlord Cards
local RageSlash: Card = {
	Id = "RageSlash",
	Name = "Rage Slash",
	Cost = 1,
	Target = "Enemy",
	Effects = {
		{ Type = "Damage", Value = 8, Target = "Enemy" },
	},
	Description = "Deal 8 damage. Gains bonus damage as your HP drops.",
	Color = Color3.fromRGB(225, 45, 45),
	Icon = "🩸",
}

local ShieldSlam: Card = {
	Id = "ShieldSlam",
	Name = "Shield Slam",
	Cost = 2,
	Target = "Enemy",
	Effects = {
		{ Type = "Shield", Value = 8, Target = "Self" },
		{ Type = "Damage", Value = 8, Target = "Enemy" },
	},
	Description = "Gain 8 Shield, then bash the foe with an armored strike for 8 damage.",
	Color = Color3.fromRGB(180, 80, 60),
	Icon = "🛡️",
}

-- Shadowblade Cards
local QuickSlash: Card = {
	Id = "QuickSlash",
	Name = "Quick Slash",
	Cost = 0,
	Target = "Enemy",
	Effects = {
		{ Type = "Damage", Value = 5 },
	},
	Description = "Deal 5 damage. Fast combo starter that costs 0 Energy.",
	Color = Color3.fromRGB(160, 65, 220),
	Icon = "🗡️",
}

local ShadowCloak: Card = {
	Id = "ShadowCloak",
	Name = "Shadow Cloak",
	Cost = 1,
	Target = "Self",
	Effects = {
		{ Type = "Shield", Value = 8 },
	},
	Description = "Vanish into shadows. Gain 8 Shield.",
	Color = Color3.fromRGB(110, 45, 160),
	Icon = "🌫️",
}

-- Aether Mage Cards
local ArcaneMissiles: Card = {
	Id = "ArcaneMissiles",
	Name = "Arcane Missiles",
	Cost = 1,
	Target = "Enemy",
	Effects = {
		{ Type = "Damage", Value = 10 },
	},
	Description = "Unleash a volley of 3 homing arcane bolts dealing 10 total damage.",
	Color = Color3.fromRGB(50, 160, 255),
	Icon = "✨",
}

local ManaSurge: Card = {
	Id = "ManaSurge",
	Name = "Mana Surge",
	Cost = 0,
	Target = "Self",
	Effects = {
		{ Type = "Shield", Value = 4 },
	},
	Description = "Draw upon astral currents. Gain 4 Shield and bank Overload for next turn.",
	Color = Color3.fromRGB(70, 190, 255),
	Icon = "⚡",
}

-- Necrobinder Cards
local SoulHarvest: Card = {
	Id = "SoulHarvest",
	Name = "Soul Harvest",
	Cost = 1,
	Target = "Enemy",
	Effects = {
		{ Type = "Damage", Value = 7, Target = "Enemy" },
		{ Type = "Heal", Value = 3, Target = "Self" },
	},
	Description = "Deal 7 damage and harvest spiritual essence to heal 3 HP.",
	Color = Color3.fromRGB(75, 180, 130),
	Icon = "💀",
}

local BoneArmor: Card = {
	Id = "BoneArmor",
	Name = "Bone Armor",
	Cost = 1,
	Target = "Self",
	Effects = {
		{ Type = "Shield", Value = 9 },
	},
	Description = "Form a protective exoskeleton of spectral bones. Gain 9 Shield.",
	Color = Color3.fromRGB(100, 150, 120),
	Icon = "🦴",
}

-- Mechanist Cards
local WrenchThrow: Card = {
	Id = "WrenchThrow",
	Name = "Wrench Throw",
	Cost = 1,
	Target = "Enemy",
	Effects = {
		{ Type = "Damage", Value = 7, Target = "Enemy" },
		{ Type = "Shield", Value = 3, Target = "Self" },
	},
	Description = "Hurl a heavy tool dealing 7 damage and salvaging 3 Shield.",
	Color = Color3.fromRGB(220, 140, 50),
	Icon = "🔧",
}

local DeployTurret: Card = {
	Id = "DeployTurret",
	Name = "Deploy Turret",
	Cost = 2,
	Target = "Enemy",
	Effects = {
		{ Type = "Shield", Value = 6, Target = "Self" },
		{ Type = "Damage", Value = 6, Target = "Enemy" },
	},
	Description = "Construct an automated sentry turret that shields you for 6 and fires at the target enemy for 6 damage.",
	Color = Color3.fromRGB(190, 120, 40),
	Icon = "⚙️",
}

-- Gambler Cards
local CoinFlip: Card = {
	Id = "CoinFlip",
	Name = "Coin Flip",
	Cost = 1,
	Target = "Enemy",
	Effects = {
		{ Type = "Damage", Value = 9 },
	},
	Description = "Flip a lucky coin. Heads deals critical damage; Tails deals base damage.",
	Color = Color3.fromRGB(240, 195, 45),
	Icon = "🪙",
}

local HighStakes: Card = {
	Id = "HighStakes",
	Name = "High Stakes",
	Cost = 2,
	Target = "Enemy",
	Effects = {
		{ Type = "Damage", Value = 16 },
	},
	Description = "Wager big! Deals high fluctuating damage between 8 and 24.",
	Color = Color3.fromRGB(215, 170, 35),
	Icon = "🎲",
}

-- Chronomancer Cards
local TimeWarp: Card = {
	Id = "TimeWarp",
	Name = "Time Warp",
	Cost = 1,
	Target = "Enemy",
	Effects = {
		{ Type = "Damage", Value = 7, Target = "Enemy" },
		{ Type = "Shield", Value = 4, Target = "Self" },
	},
	Description = "Distort temporal flow. Deal 7 damage and gain 4 Shield.",
	Color = Color3.fromRGB(70, 210, 210),
	Icon = "⌛",
}

local RewindEcho: Card = {
	Id = "RewindEcho",
	Name = "Rewind Echo",
	Cost = 1,
	Target = "Self",
	Effects = {
		{ Type = "Shield", Value = 8 },
	},
	Description = "Echo previous actions into a temporal bubble granting 8 Shield.",
	Color = Color3.fromRGB(50, 180, 190),
	Icon = "🔄",
}

-- Plague Doctor Cards
local MiasmaFlask: Card = {
	Id = "MiasmaFlask",
	Name = "Miasma Flask",
	Cost = 1,
	Target = "Enemy",
	Effects = {
		{ Type = "Poison", Value = 5 },
	},
	Description = "Shatter a vile concoction applying 5 Poison to the foe.",
	Color = Color3.fromRGB(60, 190, 80),
	Icon = "🧪",
}

local Contagion: Card = {
	Id = "Contagion",
	Name = "Contagion",
	Cost = 2,
	Target = "Enemy",
	Effects = {
		{ Type = "Damage", Value = 8, Target = "Enemy" },
		{ Type = "Poison", Value = 4, Target = "Enemy" },
	},
	Description = "Inflict virulent pathogen dealing 8 damage and 4 Poison.",
	Color = Color3.fromRGB(80, 160, 60),
	Icon = "☣️",
}

-- Blood Priest Cards
local BloodPact: Card = {
	Id = "BloodPact",
	Name = "Blood Pact",
	Cost = 1,
	Target = "Self",
	Effects = {
		{ Type = "Shield", Value = 12 },
	},
	Description = "Sacrifice vitality for spiritual fortitude. Gain 12 Shield.",
	Color = Color3.fromRGB(190, 30, 70),
	Icon = "🩸",
}

local UnholyOffering: Card = {
	Id = "UnholyOffering",
	Name = "Unholy Offering",
	Cost = 2,
	Target = "Enemy",
	Effects = {
		{ Type = "Damage", Value = 18 },
	},
	Description = "Smite the enemy with fanatical fury for 18 damage.",
	Color = Color3.fromRGB(160, 20, 50),
	Icon = "🕯️",
}

-- Beastmaster Cards
local FeralBite: Card = {
	Id = "FeralBite",
	Name = "Feral Bite",
	Cost = 1,
	Target = "Enemy",
	Effects = {
		{ Type = "Damage", Value = 9 },
	},
	Description = "Command your beast companion to savage the foe for 9 damage.",
	Color = Color3.fromRGB(175, 130, 70),
	Icon = "🐾",
}

local PackCall: Card = {
	Id = "PackCall",
	Name = "Pack Call",
	Cost = 1,
	Target = "Enemy",
	Effects = {
		{ Type = "Shield", Value = 7, Target = "Self" },
		{ Type = "Damage", Value = 4, Target = "Enemy" },
	},
	Description = "Rally your pack. Gain 7 Shield and deal 4 damage to the target enemy.",
	Color = Color3.fromRGB(145, 105, 55),
	Icon = "🐺",
}

--------------------------------------------------------------------------------
-- Master Card Registry & Lookup
--------------------------------------------------------------------------------

local CardData: { [string]: any } = {
	-- Generic
	Strike = Strike,
	["Strike"] = Strike,
	Defend = Defend,
	["Defend"] = Defend,
	HeavyBlow = HeavyBlow,
	["Heavy Blow"] = HeavyBlow,
	PoisonDart = PoisonDart,
	["Poison Dart"] = PoisonDart,
	FirstAid = FirstAid,
	["First Aid"] = FirstAid,

	-- Class Signatures
	RageSlash = RageSlash,
	["Rage Slash"] = RageSlash,
	ShieldSlam = ShieldSlam,
	["Shield Slam"] = ShieldSlam,
	QuickSlash = QuickSlash,
	["Quick Slash"] = QuickSlash,
	ShadowCloak = ShadowCloak,
	["Shadow Cloak"] = ShadowCloak,
	ArcaneMissiles = ArcaneMissiles,
	["Arcane Missiles"] = ArcaneMissiles,
	ManaSurge = ManaSurge,
	["Mana Surge"] = ManaSurge,
	SoulHarvest = SoulHarvest,
	["Soul Harvest"] = SoulHarvest,
	BoneArmor = BoneArmor,
	["Bone Armor"] = BoneArmor,
	WrenchThrow = WrenchThrow,
	["Wrench Throw"] = WrenchThrow,
	DeployTurret = DeployTurret,
	["Deploy Turret"] = DeployTurret,
	CoinFlip = CoinFlip,
	["Coin Flip"] = CoinFlip,
	HighStakes = HighStakes,
	["High Stakes"] = HighStakes,
	TimeWarp = TimeWarp,
	["Time Warp"] = TimeWarp,
	RewindEcho = RewindEcho,
	["Rewind Echo"] = RewindEcho,
	MiasmaFlask = MiasmaFlask,
	["Miasma Flask"] = MiasmaFlask,
	Contagion = Contagion,
	["Contagion"] = Contagion,
	BloodPact = BloodPact,
	["Blood Pact"] = BloodPact,
	UnholyOffering = UnholyOffering,
	["Unholy Offering"] = UnholyOffering,
	FeralBite = FeralBite,
	["Feral Bite"] = FeralBite,
	PackCall = PackCall,
	["Pack Call"] = PackCall,
}

-- Helper function to fetch card by Id or Name safely
function CardData.getCard(identifier: string): Card?
	local direct = CardData[identifier]
	if direct and typeof(direct) == "table" and direct.Id then
		return direct :: Card
	end

	for _, card in CardData do
		if typeof(card) == "table" and (card.Id == identifier or card.Name == identifier) then
			return card :: Card
		end
	end
	return nil
end

local VALID_TARGET_TYPES: { [string]: boolean } = {
	Enemy = true,
	Self = true,
	Ally = true,
	None = true,
}

-- Validates an individual Card definition against strict effect-target compatibility rules
function CardData.validateCard(card: Card): (boolean, string?)
	if not card or typeof(card) ~= "table" then
		return false, "Card is nil or not a table"
	end
	if not card.Id or card.Id == "" then
		return false, "Card has missing or empty Id"
	end
	if not VALID_TARGET_TYPES[card.Target] then
		return false, string.format("Card '%s' has invalid top-level Target '%s'", card.Id, tostring(card.Target))
	end
	if not card.Effects or #card.Effects == 0 then
		return false, string.format("Card '%s' has no effects", card.Id)
	end

	-- Check if card is mixed-target (contains both Enemy-targeting and Player-targeting effects)
	local hasEnemyEffect = false
	local hasPlayerEffect = false
	for _, eff in card.Effects do
		if eff.Type == "Damage" or eff.Type == "Poison" then
			hasEnemyEffect = true
		elseif eff.Type == "Shield" or eff.Type == "Heal" or eff.Type == "Revive" or eff.Type == "ModifyResource" then
			hasPlayerEffect = true
		end
	end
	local isMixedTarget = hasEnemyEffect and hasPlayerEffect

	for idx, eff in ipairs(card.Effects) do
		-- Rule 2: Explicitly targeted effect must use valid TargetType
		if eff.Target ~= nil and not VALID_TARGET_TYPES[eff.Target] then
			return false, string.format("Card '%s' effect #%d has invalid Target '%s'", card.Id, idx, tostring(eff.Target))
		end

		-- Rule 3: Mixed-target cards must explicitly declare Target on effects
		if isMixedTarget and eff.Target == nil then
			return false, string.format("Mixed-target card '%s' effect #%d (%s) must explicitly declare its Target", card.Id, idx, eff.Type)
		end

		local effectiveTarget = eff.Target or card.Target

		-- Rule 1, 4, 7: Damage and Poison effects require Enemy target and cannot inherit/target Self or Ally
		if eff.Type == "Damage" or eff.Type == "Poison" then
			if effectiveTarget ~= "Enemy" then
				if eff.Target == nil then
					return false, string.format("Card '%s' effect #%d (%s) cannot silently inherit '%s' target from card", card.Id, idx, eff.Type, effectiveTarget)
				else
					return false, string.format("Card '%s' effect #%d (%s) has illegal target '%s' (must be Enemy)", card.Id, idx, eff.Type, effectiveTarget)
				end
			end
		end

		-- Rule 1, 5, 7: Shield, Heal, Revive require Player target (Self or Ally) and cannot inherit/target Enemy
		if eff.Type == "Shield" or eff.Type == "Heal" or eff.Type == "Revive" then
			if effectiveTarget == "Enemy" then
				if eff.Target == nil then
					return false, string.format("Card '%s' effect #%d (%s) cannot silently inherit 'Enemy' target from card", card.Id, idx, eff.Type)
				else
					return false, string.format("Card '%s' effect #%d (%s) has illegal target 'Enemy' (must be Self or Ally)", card.Id, idx, eff.Type)
				end
			end
			if effectiveTarget ~= "Self" and effectiveTarget ~= "Ally" then
				return false, string.format("Card '%s' effect #%d (%s) has illegal target '%s' (must be Self or Ally)", card.Id, idx, eff.Type, effectiveTarget)
			end
		end

		-- Rule 6: ModifyResource must have a legal Player target and a valid Resource type
		if eff.Type == "ModifyResource" then
			if effectiveTarget ~= "Self" and effectiveTarget ~= "Ally" then
				return false, string.format("Card '%s' effect #%d (ModifyResource) requires a legal Player target (Self or Ally), got '%s'", card.Id, idx, effectiveTarget)
			end
			if not eff.Resource or eff.Resource == "" then
				return false, string.format("Card '%s' effect #%d (ModifyResource) requires a valid non-empty Resource", card.Id, idx)
			end
			if eff.Resource ~= "HP" and eff.Resource ~= "MaxHP" and eff.Resource ~= "Shield" and eff.Resource ~= "Energy" and eff.Resource ~= "MaxEnergy" and eff.Resource ~= "Gold" then
				return false, string.format("Card '%s' effect #%d (ModifyResource) has invalid Resource '%s'", card.Id, idx, tostring(eff.Resource))
			end
		end

		-- CreateCard requires valid CardDefId and valid DestinationPile if provided
		if eff.Type == "CreateCard" then
			if not eff.CardDefId or eff.CardDefId == "" then
				return false, string.format("Card '%s' effect #%d (CreateCard) requires a non-empty CardDefId", card.Id, idx)
			end
			if eff.DestinationPile ~= nil then
				if eff.DestinationPile ~= "Deck" and eff.DestinationPile ~= "Hand" and eff.DestinationPile ~= "DiscardPile" and eff.DestinationPile ~= "ExhaustPile" then
					return false, string.format("Card '%s' effect #%d (CreateCard) has invalid DestinationPile '%s'", card.Id, idx, tostring(eff.DestinationPile))
				end
			end
		end
	end

	return true, nil
end

-- Validates all registered card definitions in CardData
function CardData.validateCardDefinitions(): (boolean, string?)
	local seen: { [string]: boolean } = {}
	for _, entry in CardData do
		if typeof(entry) == "table" and entry.Id and not seen[entry.Id] then
			seen[entry.Id] = true
			local ok, err = CardData.validateCard(entry :: Card)
			if not ok then
				return false, err
			end
		end
	end
	return true, nil
end

return CardData
