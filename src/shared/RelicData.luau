--!strict

--[=[
	RelicData ModuleScript
	Mapped to: ReplicatedStorage.Shared.RelicData
	Defines the database of passive Relics for Card Rift: Co-op Dungeon.
	Contains types, rarities, trigger definitions, and mechanical stats.
]=]

local RelicData = {}

--------------------------------------------------------------------------------
-- Exported Types
--------------------------------------------------------------------------------

export type RelicRarity = "Starter" | "Common" | "Uncommon" | "Rare" | "Boss"

export type RelicTrigger =
	| "OnCombatStart"
	| "OnTurnStart"
	| "OnCardPlay"
	| "OnTurnEnd"
	| "OnDamageTaken"
	| "OnKill"

export type Relic = {
	Id: string,
	Name: string,
	Rarity: RelicRarity,
	Description: string,
	Trigger: RelicTrigger,
	Value: number,
	ExtraParam: string?,
	Icon: string?,
}

--------------------------------------------------------------------------------
-- Relic Database (18 Unique Relics)
--------------------------------------------------------------------------------

local RELIC_REGISTRY: { [string]: Relic } = {
	["Anchor"] = {
		Id = "Anchor",
		Name = "Anchor",
		Rarity = "Common",
		Description = "Start combat with 5 bonus Shield.",
		Trigger = "OnCombatStart",
		Value = 5,
		Icon = "⚓",
	},

	["Vajra"] = {
		Id = "Vajra",
		Name = "Vajra",
		Rarity = "Common",
		Description = "Gain 2 bonus Attack strength in combat.",
		Trigger = "OnCardPlay",
		Value = 2,
		Icon = "🗡️",
	},

	["Lantern"] = {
		Id = "Lantern",
		Name = "Lantern",
		Rarity = "Common",
		Description = "Gain 1 extra Energy on Turn 1 of every combat.",
		Trigger = "OnTurnStart",
		Value = 1,
		ExtraParam = "Turn1Only",
		Icon = "🏮",
	},

	["VenomVial"] = {
		Id = "VenomVial",
		Name = "Venom Vial",
		Rarity = "Uncommon",
		Description = "Apply 2 Poison to all enemies at the start of combat.",
		Trigger = "OnCombatStart",
		Value = 2,
		Icon = "🧪",
	},

	["Pocketwatch"] = {
		Id = "Pocketwatch",
		Name = "Pocketwatch",
		Rarity = "Rare",
		Description = "Draw 2 extra cards next turn if you end your turn with unspent Energy.",
		Trigger = "OnTurnEnd",
		Value = 2,
		ExtraParam = "UnspentEnergy",
		Icon = "⏱️",
	},

	["BloodVial"] = {
		Id = "BloodVial",
		Name = "Blood Vial",
		Rarity = "Common",
		Description = "Heal 4 HP at the start of combat.",
		Trigger = "OnCombatStart",
		Value = 4,
		Icon = "🩸",
	},

	["BronzeScales"] = {
		Id = "BronzeScales",
		Name = "Bronze Scales",
		Rarity = "Common",
		Description = "Whenever you take unblocked damage, deal 3 damage back to the attacker.",
		Trigger = "OnDamageTaken",
		Value = 3,
		Icon = "🛡️",
	},

	["Akabeko"] = {
		Id = "Akabeko",
		Name = "Akabeko",
		Rarity = "Uncommon",
		Description = "Your first attack in each combat deals 8 additional damage.",
		Trigger = "OnCardPlay",
		Value = 8,
		ExtraParam = "FirstAttackInCombat",
		Icon = "🐂",
	},

	["Orichalcum"] = {
		Id = "Orichalcum",
		Name = "Orichalcum",
		Rarity = "Common",
		Description = "If you have 0 Shield at the end of your turn, gain 6 Shield.",
		Trigger = "OnTurnEnd",
		Value = 6,
		ExtraParam = "ZeroShield",
		Icon = "💎",
	},

	["MeatOnTheBone"] = {
		Id = "MeatOnTheBone",
		Name = "Meat on the Bone",
		Rarity = "Uncommon",
		Description = "If your HP is below 50% at the start of combat, heal 12 HP.",
		Trigger = "OnCombatStart",
		Value = 12,
		ExtraParam = "LowHpOnly",
		Icon = "🍖",
	},

	["GremlinHorn"] = {
		Id = "GremlinHorn",
		Name = "Gremlin Horn",
		Rarity = "Uncommon",
		Description = "Whenever an enemy dies, gain 1 Energy and draw 1 card.",
		Trigger = "OnKill",
		Value = 1,
		Icon = "📯",
	},

	["Sundial"] = {
		Id = "Sundial",
		Name = "Sundial",
		Rarity = "Uncommon",
		Description = "Every 3 attack cards played, gain 2 Energy.",
		Trigger = "OnCardPlay",
		Value = 2,
		ExtraParam = "Every3Attacks",
		Icon = "☀️",
	},

	["CentennialPuzzle"] = {
		Id = "CentennialPuzzle",
		Name = "Centennial Puzzle",
		Rarity = "Rare",
		Description = "The first time you take unblocked damage in combat, draw 3 cards.",
		Trigger = "OnDamageTaken",
		Value = 3,
		ExtraParam = "FirstDamageInCombat",
		Icon = "🧩",
	},

	["Calipers"] = {
		Id = "Calipers",
		Name = "Calipers",
		Rarity = "Rare",
		Description = "Retain up to 15 Shield between combat turns instead of losing it all.",
		Trigger = "OnTurnEnd",
		Value = 15,
		ExtraParam = "RetainShield",
		Icon = "📐",
	},

	["IncenseBurner"] = {
		Id = "IncenseBurner",
		Name = "Incense Burner",
		Rarity = "Rare",
		Description = "Every 5 turns, gain Intangible for that turn (prevent all damage).",
		Trigger = "OnTurnStart",
		Value = 1,
		ExtraParam = "Every5Turns",
		Icon = "💨",
	},

	["CoffeeDripper"] = {
		Id = "CoffeeDripper",
		Name = "Coffee Dripper",
		Rarity = "Boss",
		Description = "Gain 1 additional Energy at the start of every turn.",
		Trigger = "OnTurnStart",
		Value = 1,
		Icon = "☕",
	},

	["BlackStar"] = {
		Id = "BlackStar",
		Name = "Black Star",
		Rarity = "Boss",
		Description = "Defeating an Elite Monster grants an extra Relic reward.",
		Trigger = "OnKill",
		Value = 1,
		ExtraParam = "EliteRelicBonus",
		Icon = "⭐",
	},

	["BurningBlood"] = {
		Id = "BurningBlood",
		Name = "Burning Blood",
		Rarity = "Starter",
		Description = "Starter relic: Heal 6 HP at the beginning of each combat encounter.",
		Trigger = "OnCombatStart",
		Value = 6,
		Icon = "🔥",
	},
}

--------------------------------------------------------------------------------
-- Helper Functions
--------------------------------------------------------------------------------

-- Fetches a relic definition by its unique ID
function RelicData.getRelic(id: string): Relic?
	return RELIC_REGISTRY[id]
end

-- Returns the full map of registered relics
function RelicData.getAllRelics(): { [string]: Relic }
	return RELIC_REGISTRY
end

-- Returns a list of all relics matching a specific rarity
function RelicData.getRelicsByRarity(rarity: RelicRarity): { Relic }
	local results: { Relic } = {}
	for _, relic in RELIC_REGISTRY do
		if relic.Rarity == rarity then
			table.insert(results, relic)
		end
	end
	return results
end

-- Returns a randomized relic of the specified rarity
function RelicData.getRandomRelicByRarity(rarity: RelicRarity, excludeIds: { string }?): Relic?
	local pool = RelicData.getRelicsByRarity(rarity)
	local validPool: { Relic } = {}

	local excludedSet: { [string]: boolean } = {}
	if excludeIds then
		for _, id in excludeIds do
			excludedSet[id] = true
		end
	end

	for _, relic in pool do
		if not excludedSet[relic.Id] then
			table.insert(validPool, relic)
		end
	end

	if #validPool == 0 then
		return nil
	end

	local rng = Random.new()
	local selectedIndex = rng:NextInteger(1, #validPool)
	return validPool[selectedIndex]
end

-- Returns the standardized theme color for each rarity tier
function RelicData.getRarityColor(rarity: RelicRarity): Color3
	if rarity == "Starter" then
		return Color3.fromRGB(180, 185, 200) -- Slate Gray
	elseif rarity == "Common" then
		return Color3.fromRGB(230, 235, 245) -- Bright White / Silver
	elseif rarity == "Uncommon" then
		return Color3.fromRGB(60, 220, 130) -- Emerald Green
	elseif rarity == "Rare" then
		return Color3.fromRGB(65, 175, 255) -- Brilliant Cyan
	elseif rarity == "Boss" then
		return Color3.fromRGB(255, 205, 45) -- Radiant Gold
	else
		return Color3.fromRGB(200, 200, 200)
	end
end

return RelicData
