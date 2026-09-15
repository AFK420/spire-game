--!strict

--[=[
	ClassData ModuleScript
	Mapped to: ReplicatedStorage.Shared.ClassData
	Defines the 10 core classes, their unique active/passive combat gimmicks,
	two specialized subclasses per class, and their unique starting decks.
]=]

local ClassData = {}

--------------------------------------------------------------------------------
-- Exported Types
--------------------------------------------------------------------------------

export type Subclass = {
	Id: string,
	Name: string,
	Description: string,
	StartingPassiveId: string,
}

export type HeroClass = {
	Id: string,
	Name: string,
	Description: string,
	MaxHp: number,
	StartingEnergy: number,
	GimmickName: string,
	GimmickDescription: string,
	Subclasses: { Subclass },
	StartingDeck: { string },
	Color: Color3,
	Icon: string,
}

--------------------------------------------------------------------------------
-- Master Class Database (10 Core Classes & 20 Subclasses)
--------------------------------------------------------------------------------

local CLASS_REGISTRY: { [string]: HeroClass } = {
	["Warlord"] = {
		Id = "Warlord",
		Name = "Warlord",
		Description = "A ferocious frontline juggernaut who channels pain into overwhelming offensive power.",
		MaxHp = 110,
		StartingEnergy = 3,
		GimmickName = "Rage",
		GimmickDescription = "Increases attack damage as health drops (+1 permanent ATK per 10% missing HP).",
		Color = Color3.fromRGB(220, 60, 50),
		Icon = "⚔️",
		Subclasses = {
			{
				Id = "Berserker",
				Name = "Berserker",
				Description = "When below 50% HP, all attacks gain an additional +4 flat damage.",
				StartingPassiveId = "BerserkerFrenzy",
			},
			{
				Id = "Titan",
				Name = "Titan",
				Description = "Start every combat encounter with +10 Shield and gain +10 Max HP.",
				StartingPassiveId = "TitanBastion",
			},
		},
		StartingDeck = {
			"Strike",
			"Strike",
			"Defend",
			"Defend",
			"HeavyBlow",
			"RageSlash",
			"ShieldSlam",
			"Strike",
		},
	},

	["Shadowblade"] = {
		Id = "Shadowblade",
		Name = "Shadowblade",
		Description = "A lethal rogue specializing in high-speed combos, backstabs, and debilitating poisons.",
		MaxHp = 85,
		StartingEnergy = 3,
		GimmickName = "Combo",
		GimmickDescription = "Tracks cards played in sequence. Every card played after the first deals +2 bonus damage or grants +2 Shield.",
		Color = Color3.fromRGB(150, 75, 210),
		Icon = "🗡️",
		Subclasses = {
			{
				Id = "Assassin",
				Name = "Assassin",
				Description = "The 3rd card played each turn is a guaranteed Critical Strike (deals 2x damage).",
				StartingPassiveId = "LethalTempo",
			},
			{
				Id = "Venomancer",
				Name = "Venomancer",
				Description = "Every card played applies +1 Poison to the target enemy.",
				StartingPassiveId = "ToxicCoat",
			},
		},
		StartingDeck = {
			"Strike",
			"Strike",
			"Defend",
			"Defend",
			"PoisonDart",
			"QuickSlash",
			"ShadowCloak",
			"Strike",
		},
	},

	["AetherMage"] = {
		Id = "AetherMage",
		Name = "Aether Mage",
		Description = "A master of raw cosmic energy who channels leftover mana into catastrophic bursts.",
		MaxHp = 80,
		StartingEnergy = 4,
		GimmickName = "Overload",
		GimmickDescription = "Unspent energy at turn end converts into Overload charges (+4 spell damage per charge next turn).",
		Color = Color3.fromRGB(50, 160, 255),
		Icon = "🔮",
		Subclasses = {
			{
				Id = "Pyromancer",
				Name = "Pyromancer",
				Description = "Overload charges detonate directly at turn end, dealing 5 damage per charge to all enemies.",
				StartingPassiveId = "FlameIgnition",
			},
			{
				Id = "Cryomancer",
				Name = "Cryomancer",
				Description = "Overload charges solidify at turn end, granting +4 Shield per charge.",
				StartingPassiveId = "GlacialArmor",
			},
		},
		StartingDeck = {
			"Strike",
			"Strike",
			"Defend",
			"Defend",
			"ArcaneMissiles",
			"ManaSurge",
			"ArcaneMissiles",
			"Defend",
		},
	},

	["Necrobinder"] = {
		Id = "Necrobinder",
		Name = "Necrobinder",
		Description = "A sinister occultist who harvests the life essence of fallen enemies to summon undead minions.",
		MaxHp = 90,
		StartingEnergy = 3,
		GimmickName = "Souls",
		GimmickDescription = "Tracks fallen entities and soul cards. At 5 Souls, summons a Bone Servant that strikes for 8 damage at turn end.",
		Color = Color3.fromRGB(90, 190, 140),
		Icon = "💀",
		Subclasses = {
			{
				Id = "Reaper",
				Name = "Reaper",
				Description = "Whenever an entity dies, heal 6 HP and gain 2 bonus Soul tokens.",
				StartingPassiveId = "SoulSiphon",
			},
			{
				Id = "SwarmLord",
				Name = "Swarm Lord",
				Description = "Maximum Soul capacity increased to 15; summons 2 Bone Servants instead of 1.",
				StartingPassiveId = "LegionSummon",
			},
		},
		StartingDeck = {
			"Strike",
			"Strike",
			"Defend",
			"Defend",
			"SoulHarvest",
			"BoneArmor",
			"SoulHarvest",
			"Strike",
		},
	},

	["Mechanist"] = {
		Id = "Mechanist",
		Name = "Mechanist",
		Description = "An ingenious engineer who leaves scrap parts across the arena to construct lethal automated turrets.",
		MaxHp = 95,
		StartingEnergy = 3,
		GimmickName = "Gears",
		GimmickDescription = "Playing cards generates Scrap parts (1 Scrap per card). At 4 Scrap, builds an automated Turret dealing 6 damage per turn.",
		Color = Color3.fromRGB(215, 145, 55),
		Icon = "⚙️",
		Subclasses = {
			{
				Id = "Artificer",
				Name = "Artificer",
				Description = "Turrets grant +4 Shield to the party at the end of each turn in addition to firing.",
				StartingPassiveId = "ReinforcedAlloy",
			},
			{
				Id = "Demolitionist",
				Name = "Demolitionist",
				Description = "Whenever a Turret is destroyed or expires, it detonates dealing 15 area damage.",
				StartingPassiveId = "ScrapBomb",
			},
		},
		StartingDeck = {
			"Strike",
			"Strike",
			"Defend",
			"Defend",
			"WrenchThrow",
			"DeployTurret",
			"WrenchThrow",
			"Defend",
		},
	},

	["Gambler"] = {
		Id = "Gambler",
		Name = "Gambler",
		Description = "A chaotic trickster who tests fate with coin flips and wide random damage multipliers.",
		MaxHp = 90,
		StartingEnergy = 3,
		GimmickName = "Luck Rolls",
		GimmickDescription = "All attacks deal randomized damage (50% to 175% base power); coin flips double damage on Heads.",
		Color = Color3.fromRGB(240, 205, 50),
		Icon = "🎲",
		Subclasses = {
			{
				Id = "HighRoller",
				Name = "High Roller",
				Description = "Coin flip winning probability increased from 50% to 70%.",
				StartingPassiveId = "LoadedDice",
			},
			{
				Id = "CardSharp",
				Name = "Card Sharp",
				Description = "Rolling maximum damage on any card immediately refunds its Energy cost.",
				StartingPassiveId = "AceInTheHole",
			},
		},
		StartingDeck = {
			"Strike",
			"Strike",
			"Defend",
			"Defend",
			"CoinFlip",
			"HighStakes",
			"CoinFlip",
			"Strike",
		},
	},

	["Chronomancer"] = {
		Id = "Chronomancer",
		Name = "Chronomancer",
		Description = "A time-weaver capable of undoing recent combat blunders or echoing powerful spells across turns.",
		MaxHp = 85,
		StartingEnergy = 3,
		GimmickName = "Rewind",
		GimmickDescription = "Tracks recent combat events; can rewind damage taken or duplicate the previous card played for 0 Energy.",
		Color = Color3.fromRGB(80, 215, 215),
		Icon = "⏳",
		Subclasses = {
			{
				Id = "Paradox",
				Name = "Paradox",
				Description = "Echoed cards trigger their secondary effects twice.",
				StartingPassiveId = "TemporalEcho",
			},
			{
				Id = "Decay",
				Name = "Decay",
				Description = "Enemy poison ticks accelerate, dealing double poison damage each turn.",
				StartingPassiveId = "EntropicRift",
			},
		},
		StartingDeck = {
			"Strike",
			"Strike",
			"Defend",
			"Defend",
			"TimeWarp",
			"RewindEcho",
			"TimeWarp",
			"Defend",
		},
	},

	["PlagueDoctor"] = {
		Id = "PlagueDoctor",
		Name = "Plague Doctor",
		Description = "A bird-masked alchemist who infects enemies with virulent afflictions that bounce between foes.",
		MaxHp = 90,
		StartingEnergy = 3,
		GimmickName = "Infection",
		GimmickDescription = "When an enemy takes Poison damage, contagion splashes to all targets and increases Poison potency by +1.",
		Color = Color3.fromRGB(60, 185, 75),
		Icon = "☣️",
		Subclasses = {
			{
				Id = "Toxicologist",
				Name = "Toxicologist",
				Description = "Poison stacks on enemies do not decay by 1 at the end of their turn.",
				StartingPassiveId = "VirulentStrain",
			},
			{
				Id = "Apothecary",
				Name = "Apothecary",
				Description = "50% of all Poison damage dealt to enemies is converted into healing for the party.",
				StartingPassiveId = "Panacea",
			},
		},
		StartingDeck = {
			"Strike",
			"Strike",
			"Defend",
			"Defend",
			"PoisonDart",
			"MiasmaFlask",
			"Contagion",
			"PoisonDart",
		},
	},

	["BloodPriest"] = {
		Id = "BloodPriest",
		Name = "Blood Priest",
		Description = "A devout zealot who bypasses normal energy restrictions by offering vitality on the altar of war.",
		MaxHp = 120,
		StartingEnergy = 3,
		GimmickName = "Sacrifice",
		GimmickDescription = "Can play cards without Energy by sacrificing 5 HP per missing Energy, granting +3 bonus damage to the card.",
		Color = Color3.fromRGB(180, 25, 60),
		Icon = "🩸",
		Subclasses = {
			{
				Id = "Zealot",
				Name = "Zealot",
				Description = "Sacrificing health while below 50% HP grants 10 Shield.",
				StartingPassiveId = "Martyrdom",
			},
			{
				Id = "Inquisitor",
				Name = "Inquisitor",
				Description = "Every 15 total HP sacrificed triggers an unholy shockwave dealing 18 damage to all enemies.",
				StartingPassiveId = "RighteousPurge",
			},
		},
		StartingDeck = {
			"Strike",
			"Strike",
			"Defend",
			"Defend",
			"FirstAid",
			"BloodPact",
			"UnholyOffering",
			"Strike",
		},
	},

	["Beastmaster"] = {
		Id = "Beastmaster",
		Name = "Beastmaster",
		Description = "A wild ranger bound to a spectral beast that grows more ferocious with every coordinated strike.",
		MaxHp = 95,
		StartingEnergy = 3,
		GimmickName = "Pact",
		GimmickDescription = "Fights alongside a Spirit Wolf companion that strikes for 6 damage at turn end and gains Evolution stacks.",
		Color = Color3.fromRGB(160, 120, 75),
		Icon = "🐺",
		Subclasses = {
			{
				Id = "Predator",
				Name = "Predator",
				Description = "Wolf companion attacks inflict Bleed / Vulnerable (+25% damage taken for 1 turn).",
				StartingPassiveId = "HunterInstinct",
			},
			{
				Id = "Symbiote",
				Name = "Symbiote",
				Description = "Wolf companion absorbs 50% of incoming unblocked damage directed at the Beastmaster.",
				StartingPassiveId = "SharedVitality",
			},
		},
		StartingDeck = {
			"Strike",
			"Strike",
			"Defend",
			"Defend",
			"FeralBite",
			"PackCall",
			"FeralBite",
			"Defend",
		},
	},
}

--------------------------------------------------------------------------------
-- Helper Methods
--------------------------------------------------------------------------------

-- Fetches a class definition by its ID
function ClassData.getClass(classId: string): HeroClass?
	return CLASS_REGISTRY[classId]
end

-- Returns the full map of 10 registered classes
function ClassData.getAllClasses(): { [string]: HeroClass }
	return CLASS_REGISTRY
end

-- Returns an ordered array of all classes for UI iteration
function ClassData.getClassList(): { HeroClass }
	return {
		CLASS_REGISTRY.Warlord,
		CLASS_REGISTRY.Shadowblade,
		CLASS_REGISTRY.AetherMage,
		CLASS_REGISTRY.Necrobinder,
		CLASS_REGISTRY.Mechanist,
		CLASS_REGISTRY.Gambler,
		CLASS_REGISTRY.Chronomancer,
		CLASS_REGISTRY.PlagueDoctor,
		CLASS_REGISTRY.BloodPriest,
		CLASS_REGISTRY.Beastmaster,
	}
end

-- Fetches a specific subclass definition for a class
function ClassData.getSubclass(classId: string, subclassId: string): Subclass?
	local heroClass = CLASS_REGISTRY[classId]
	if not heroClass then return nil end

	for _, subclass in heroClass.Subclasses do
		if subclass.Id == subclassId then
			return subclass
		end
	end
	return nil
end

return ClassData
