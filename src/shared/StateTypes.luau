--!strict

--[=[
	StateTypes ModuleScript
	Mapped to: ReplicatedStorage.Shared.StateTypes
	Defines the canonical data models, Definition vs Instance types,
	multi-enemy combat structures, and serializable client snapshot contracts
	for Card Rift: Co-op Dungeon.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local CardData = require(Shared:WaitForChild("CardData") :: ModuleScript)

local StateTypes = {}

--------------------------------------------------------------------------------
-- 1. Definition vs Instance Types
--------------------------------------------------------------------------------

-- Runtime instance of a card in a deck, hand, or discard pile
export type CardInstance = {
	InstanceId: string,         -- Unique stable runtime GUID (e.g. "card_inst_94821")
	DefinitionId: string,       -- Reference to CardData definition ID (e.g. "Strike")
	CardData: CardData.Card,    -- Immutable definition snapshot
	OwnerUserId: number,        -- Owner player's UserId
}

--------------------------------------------------------------------------------
-- 1.1 Phase 3 Equipment Types
--------------------------------------------------------------------------------

export type EquipmentSlot = "Weapon" | "Armor" | "Accessory"
export type EquipmentRarity = "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary"

-- Runtime instance of equipped or inventoried equipment
export type EquipmentInstance = {
	InstanceId: string,         -- Unique stable runtime GUID (e.g. "equip_inst_48102")
	DefinitionId: string,       -- Reference to EquipmentData definition ID (e.g. "IronBroadsword")
	OwnerUserId: number,        -- Owner player's UserId
	Slot: EquipmentSlot,        -- Equipment slot ("Weapon", "Armor", "Accessory")
	Level: number,              -- Item upgrade level (default 1)
	Modifiers: { Modifier }?,   -- Rolled or runtime modifiers
}

--------------------------------------------------------------------------------
-- 1.2 Phase 3 Active Skill & Passive Types
--------------------------------------------------------------------------------

export type SkillSlot = "Skill1" | "Skill2" | "Skill3" | "Skill4"

export type SkillInstance = {
	InstanceId: string,
	DefinitionId: string,
	OwnerUserId: number,
	Slot: SkillSlot?,
	CurrentCooldown: number,
}

--------------------------------------------------------------------------------
-- 2. Player Canonical State Models
--------------------------------------------------------------------------------

export type PlayerResources = {
	HP: number,
	MaxHP: number,
	Shield: number,
	Energy: number,
	MaxEnergy: number,
}

export type PlayerState = {
	UserId: number,
	PlayerInstance: Player?,
	DisplayName: string,
	ClassId: string,
	SubclassId: string,
	Resources: PlayerResources,
	Deck: { CardInstance },
	Hand: { [string]: CardInstance }, -- Keyed by CardInstanceId for O(1) safe lookup
	DiscardPile: { CardInstance },
	ExhaustPile: { CardInstance },
	RelicIds: { string },
	Gold: number,
	IsReady: boolean,
	IsDowned: boolean,
	IsConnected: boolean?,
	ClassLocked: boolean?,
	VotedNodeId: string?,
	-- =========================================================================
	-- Phase 3 / 3.1 Run-Scoped Progression State
	-- These fields are ephemeral and bound strictly to the current expedition run.
	--
	-- FUTURE PERSISTENT ACCOUNT PROFILE STATE (DEFERRED TO PHASE 4+):
	-- The following systems are NOT run-scoped and must eventually reside in
	-- PersistenceService profile data once designed:
	--   * Permanent Card Collection & Deck Presets/Slots
	--   * Account Equipment Armory / Collection
	--   * Permanent Skill Mastery / Unlock Entitlements
	--   * Class Meta-Progression / Permanent Talent Trees
	--   * Permanent Currencies (Aether Shards, Gems) & Gacha Pity Banners
	-- =========================================================================
	EquippedItems: { [EquipmentSlot]: EquipmentInstance }?,
	EquipmentInventory: { EquipmentInstance }?,
	EquippedSkills: { [SkillSlot]: SkillInstance }?,
	SkillInventory: { SkillInstance }?, -- Authoritative owned skill instances for this run
	UnlockedSkills: { [string]: boolean }?, -- Skills legitimately unlocked for this run
	UnlockedPassives: { [string]: boolean }?,
	PassivePoints: number?,
}

--------------------------------------------------------------------------------
-- 3. Multi-Enemy & Combat Canonical State Models
--------------------------------------------------------------------------------

export type EnemyIntentType = "Attack" | "Defend" | "Buff" | "Debuff"

export type EnemyIntent = {
	Type: EnemyIntentType,
	Value: number,
	TargetUserId: number?,
	Description: string?,
}

export type EnemyState = {
	InstanceId: string,         -- Stable runtime ID (e.g. "enemy_001", "enemy_002")
	DefinitionId: string,       -- e.g. "SpireSentinel", "GremlinNob"
	Name: string,
	HP: number,
	MaxHP: number,
	Shield: number,
	Poison: number,
	AttackPower: number,
	Intent: EnemyIntent,
	ModelRef: Model?,           -- Optional Workspace visual model
}

export type CombatPhase = "PlayerPhase" | "ResolutionPhase" | "Victory" | "Defeat"

export type CombatEvent = {
	Type: string,               -- e.g. "DamageDealt", "ShieldGained", "PlayerDowned", "PlayerRevived"
	SourceId: string,
	TargetId: string,
	Value: number?,
	ExtraText: string?,
	Timestamp: number,
}

--------------------------------------------------------------------------------
-- 3.0 Reaction & Environmental Combat Types
--------------------------------------------------------------------------------

export type ReactionType = "Dodge" | "Parry"
export type TimingJudgement = "Perfect" | "Good" | "Early" | "Late" | "Miss" | "Unavailable" | "None"
export type ReactionResult = "Success" | "Perfect" | "Good" | "Miss" | "Early" | "Late" | "Unavailable" | "None"
export type AttackType = "Melee" | "Jump" | "Projectile" | "AoE"

export type AttackReactionProfile = {
	AttackId: string,
	AttackName: string,
	AttackType: AttackType,
	CanDodge: boolean,
	CanParry: boolean,
	TelegraphDuration: number,
	ImpactDelay: number,
	RecoveryDuration: number,
	DodgeWindowStart: number,
	DodgeWindowEnd: number,
	ParryWindowStart: number,
	ParryWindowEnd: number,
	DodgePerfectTolerance: number,
	DodgeGoodTolerance: number,
	ParryPerfectTolerance: number,
	ParryGoodTolerance: number,
	DamageType: DamageType,
	RawDamage: number,
	IsAoE: boolean?,
	AnimationLength: number?,
	ProjectileSpeed: number?,
	ProjectileColor: Color3?,
}

export type ReactionWindowState = {
	WindowId: string,
	AttackProfile: AttackReactionProfile,
	EnemyInstanceId: string,
	TargetUserIds: { number },
	AttackStartServerTime: number,
	ImpactServerTime: number,
	ReactionCloseServerTime: number,
	OpenTime: number,     -- Alias for AttackStartServerTime
	ImpactTime: number,   -- Alias for ImpactServerTime
	CloseTime: number,    -- Alias for ReactionCloseServerTime
	Resolved: boolean,
	PerPlayerResult: {
		[number]: {
			Reaction: ReactionType?,
			Result: ReactionResult,
			Judgement: TimingJudgement?,
			TimeDelta: number?,
			SubmittedAt: number?,
		},
	},
}

export type ReactionWindowView = {
	WindowId: string,
	AttackName: string,
	EnemyName: string,
	AttackType: AttackType,
	DamageType: DamageType,
	RawDamage: number,
	CanDodge: boolean,
	CanParry: boolean,
	AttackStartServerTime: number,
	ImpactServerTime: number,
	ReactionCloseServerTime: number,
	OpenTime: number,     -- Alias for AttackStartServerTime
	ImpactTime: number,   -- Alias for ImpactServerTime
	CloseTime: number,    -- Alias for ReactionCloseServerTime
	TimeRemaining: number,
	TotalDuration: number,
	TargetUserIds: { number },
	ImpactDelay: number,
	RecoveryDuration: number,
	TelegraphDuration: number,
	ProjectileSpeed: number?,
	DodgePerfectTolerance: number?,
	DodgeGoodTolerance: number?,
	ParryPerfectTolerance: number?,
	ParryGoodTolerance: number?,
}

export type EnvironmentId = "RainSoaked" | "LavaCavern" | "FrozenWastes" | "ToxicSwamp" | "ArcaneStorm" | "None"

export type EnvironmentState = {
	EnvironmentId: EnvironmentId,
	Name: string,
	StartTime: number,
	Intensity: number,
	Tags: { [string]: boolean },
	ActiveHazards: { string },
	DamageModifiers: { [DamageType]: number },
	StatusModifiers: { [string]: { DurationBonus: number?, StacksBonus: number? } },
	HealingModifier: number,
	ActiveTransformation: string?,
}

export type EnvironmentView = {
	EnvironmentId: EnvironmentId,
	Name: string,
	Description: string,
	Icon: string,
	Tags: { string },
	ActiveTransformation: string?,
}

--------------------------------------------------------------------------------
-- 3.0b 3D Event Room Types
--------------------------------------------------------------------------------

export type EventCategory = "Puzzle" | "Riddle" | "Choice"

export type EventInteractableState = {
	Id: string,
	Name: string,
	Type: string,
	IsActive: boolean,
	Position: Vector3?,
	Label: string?,
}

export type EventState = {
	EventId: string,
	DefinitionId: string,
	Name: string,
	Category: EventCategory,
	IsCompleted: boolean,
	Outcome: "Success" | "Failure" | "Pending",
	AttemptsRemaining: number,
	MaxAttempts: number,
	Interactables: { [string]: EventInteractableState },
	TargetSequence: { string }?,
	CurrentStep: number?,
	CorrectStatueId: string?,
	Clues: { [string]: string }?,
	PlayerSpecificClues: { [number]: string }?,
	PlayerSpecificObjectives: { [number]: string }?,
	SharedEventState: { [string]: any },
	Message: string?,
}

export type EventInteractableView = {
	Id: string,
	Name: string,
	Type: string,
	IsActive: boolean,
	Label: string?,
}

export type EventView = {
	EventId: string,
	Name: string,
	Category: EventCategory,
	IsCompleted: boolean,
	Outcome: "Success" | "Failure" | "Pending",
	AttemptsRemaining: number,
	Message: string?,
	ClueText: string?,
	Interactables: { EventInteractableView },
	ObjectiveText: string?,
}

export type CombatState = {
	CombatId: string,
	Phase: CombatPhase,
	TurnNumber: number,
	TurnStartTime: number,      -- Monotonic timestamp via os.clock()
	TurnDuration: number,       -- Standard 45-second duration
	Participants: { number },   -- UserIds of players in combat
	Enemies: { [string]: EnemyState }, -- Keyed by EnemyState.InstanceId (Supports 1 to N enemies)
	ReadyPlayers: { [number]: boolean },
	CombatLog: { CombatEvent },
	ActiveReactionWindow: ReactionWindowState?,
	Environment: EnvironmentState?,
}

--------------------------------------------------------------------------------
-- 3.1 Phase 2 Generic Gameplay Engine Types
--------------------------------------------------------------------------------

export type EffectType =
	| "Damage"
	| "Heal"
	| "Shield"
	| "Revive"
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
	| "Poison"

export type ResourceType = "HP" | "MaxHP" | "Shield" | "Energy" | "MaxEnergy" | "Gold"

export type DamageType =
	| "Physical"
	| "Fire"
	| "Cold"
	| "Lightning"
	| "Light"
	| "Void"
	| "Venom"
	| "Sonic"
	| "Acid"

export type TargetEntityKind = "Enemy" | "Player" | "None"

export type ResolvedTarget = {
	Success: boolean,
	Error: string?,
	TargetKind: TargetEntityKind,
	EnemyTarget: EnemyState?,
	PlayerTarget: PlayerState?,
	TargetId: string,
	TargetName: string,
}

export type ModifierOperation = "Add" | "Multiply" | "Override"
export type ModifierStat =
	| "Damage"
	| "Shield"
	| "Healing"
	| "Cost"
	| "MaxHP"
	| "MaxEnergy"
	| "ShieldGain"
	| "CritChance"
	| "CritMultiplier"

export type Modifier = {
	Id: string,
	Source: string,
	Stat: ModifierStat,
	Operation: ModifierOperation,
	Value: number,
	Condition: string?,
	Priority: number,
}

export type ResolvedPlayerStats = {
	MaxHP: number,
	MaxEnergy: number,
	BonusDamage: number,
	BonusShieldGain: number,
	BonusHealing: number,
	CritChance: number,
	CritMultiplier: number,
	CostReduction: number,
}

export type DamageContext = {
	RawDamage: number,
	DamageType: DamageType,
	SourceId: string,
	SourceName: string,
	SourcePlayer: PlayerState?,
	TargetEntityKind: TargetEntityKind,
	TargetEnemy: EnemyState?,
	TargetPlayer: PlayerState?,
	Tags: { string }?,
	Critical: boolean?,
	CanHitShield: boolean,
	IsPeriodic: boolean,
}

export type DamageResult = {
	FinalDamage: number,
	ShieldAbsorbed: number,
	HPLost: number,
	IsDefeatedOrDowned: boolean,
	IsCritical: boolean?,
}

export type StatusStackingMode = "Stack" | "RefreshDuration" | "Independent" | "None"
export type StatusTickTiming = "TurnStart" | "TurnEnd" | "OnAction" | "None"

export type StatusDefinition = {
	Id: string,
	Name: string,
	Description: string,
	Stacking: StatusStackingMode,
	DefaultDuration: number?,
	TickTiming: StatusTickTiming,
	MaxStacks: number?,
	IsDebuff: boolean,
	Icon: string?,
	Implemented: boolean,
	TickBehaviorId: string?,
}

export type StatusInstance = {
	InstanceId: string,
	DefinitionId: string,
	Stacks: number,
	Duration: number,
	SourceId: string,
	TargetId: string,
}

export type CombatEventContext = {
	Event: string,
	CombatState: CombatState?,
	SourcePlayer: PlayerState?,
	Enemy: EnemyState?,
	Card: CardInstance?,
	Damage: number?,
	Value: number?,
	TargetPlayer: PlayerState?,
	UnspentEnergy: number?,
}

--------------------------------------------------------------------------------
-- 4. Dungeon Run Canonical State Model
--------------------------------------------------------------------------------

export type RunPhase =
	| "Lobby"
	| "MapSelect"
	| "ActiveRoom"
	| "Rewards"
	| "RunVictory"
	| "RunDefeat"

export type ActiveRoomType =
	| "Combat"
	| "Elite Monster"
	| "Campfire Rest"
	| "Merchant Shop"
	| "Act Boss"
	| "Event"

export type ActiveRoom = {
	NodeId: string,
	Type: ActiveRoomType,
	Tier: number,
	ActIndex: number,
	RoomEncounterId: string?,
	RoomTemplateId: string?,
	EnvironmentId: EnvironmentId?,
	EventId: string?,
	CampfireUsed: boolean?,
	ShopVisited: boolean?,
}

export type RunRewards = {
	GoldAmount: number,
	AetherShardsAmount: number,
	OfferedCardsByPlayer: { [number]: { CardData.Card } }, -- 3 universal draft choices per player
	ClaimedCards: { [number]: boolean },
}

export type RunState = {
	RunId: string,
	Seed: number,
	Phase: RunPhase,
	ActIndex: number,
	CurrentTier: number,
	CurrentNodeId: string?,
	ClearedNodeIds: { string },
	AvailableNodeIds: { string },
	PartyMembers: { [number]: PlayerState }, -- Keyed by UserId
	ActiveRoom: ActiveRoom?,
	ActiveCombat: CombatState?,
	ActiveEvent: EventState?,
	PendingRewards: RunRewards?,
	StateRevision: number,
}

--------------------------------------------------------------------------------
-- 5. Serializable Client View Snapshots (DTOs)
--------------------------------------------------------------------------------

export type CardView = {
	InstanceId: string,
	DefinitionId: string,
	Name: string,
	Cost: number,
	Target: CardData.TargetType,
	Description: string,
	Icon: string,
	Color: Color3,
}

export type PlayerView = {
	UserId: number,
	DisplayName: string,
	ClassId: string,
	SubclassId: string,
	HP: number,
	MaxHP: number,
	Shield: number,
	Energy: number,
	MaxEnergy: number,
	HandCount: number,
	DeckCount: number,
	DiscardCount: number,
	IsReady: boolean,
	IsDowned: boolean,
	ClassLocked: boolean?,
	Gold: number,
	RelicIds: { string },
	EquippedItems: { [string]: string }?,
	EquippedSkills: { [string]: string }?,
	SkillInventory: { string }?,
	UnlockedPassives: { [string]: boolean }?,
	PassivePoints: number?,
}

export type EnemyView = {
	InstanceId: string,
	Name: string,
	HP: number,
	MaxHP: number,
	Shield: number,
	Poison: number,
	AttackPower: number,
	IntentText: string,
	IntentIcon: string,
}

export type CombatSnapshot = {
	CombatId: string,
	Phase: CombatPhase,
	TurnNumber: number,
	TurnStartTime: number,
	TurnDuration: number,
	TimeRemaining: number,
	Enemies: { [string]: EnemyView },
	Party: { [string]: PlayerView }, -- Keyed by tostring(UserId)
	LocalHand: { CardView },
	CombatEvents: { CombatEvent },
	Message: string?,
	ActiveReactionWindow: ReactionWindowView?,
	Environment: EnvironmentView?,
}

export type MapNodeView = {
	Id: string,
	NodeId: string?,
	Act: number,
	Tier: number,
	Lane: number,
	Type: ActiveRoomType,
	ConnectedNodeIds: { string },
	Connections: { string }?,
	IsAvailable: boolean,
	Reachable: boolean?,
	IsCleared: boolean,
	Cleared: boolean?,
	IsCurrent: boolean,
}

export type ActionResult = {
	Action: string,
	Success: boolean,
	Message: string?,
	Reason: string?,
	Won: boolean?,
	NodeId: string?,
	Phase: RunPhase?,
	StateRevision: number?,
	CardDefId: string?,
}

export type RunSnapshot = {
	RunId: string,
	Phase: RunPhase,
	ActIndex: number,
	ActName: string,
	CurrentTier: number,
	CurrentNodeId: string?,
	ClearedNodeIds: { string },
	AvailableNodeIds: { string },
	MapNodes: { MapNodeView }?,
	Party: { [string]: PlayerView },
	Event: EventView?,
	Rewards: {
		GoldAmount: number,
		AetherShardsAmount: number,
		OfferedCards: { CardView },
		HasClaimed: boolean,
	}?,
	Message: string?,
	StateRevision: number?,
}

--------------------------------------------------------------------------------
-- 6. Phase 4 Persistent Account Profile & Deck Models
--------------------------------------------------------------------------------

-- Persistent saved deck definition (references CardDefinition IDs + quantities, NEVER CardInstances)
export type SavedDeck = {
	DeckId: string,               -- Server-generated GUID (e.g. "deck_10001_1_a8f9c2")
	Name: string,                 -- Player deck name (trimmed, 1 to MaxDeckNameLength)
	Cards: { [string]: number },  -- CardDefinition ID -> Quantity owned/slotted
	ClassId: string?,             -- Optional target class binding (e.g. "Warlord")
	CreatedAt: number,            -- Timestamp created
	UpdatedAt: number,            -- Timestamp last edited
}

-- Configurable deck slot entitlement model
export type DeckSlotEntitlement = {
	BaseDeckSlots: number,        -- Base free slots (default 4 from GameConfig)
	AdditionalDeckSlots: number,  -- Additional slots unlocked via progression/purchases (default 0)
}

-- Authoritative persistent player profile (DataStore persistence)
export type PlayerProfile = {
	ProfileVersion: number,                    -- Schema migration version (current: 1)
	AetherShards: number,                      -- Meta currency earned from runs
	PremiumCurrency: number,                   -- Placeholder schema for future currency (default 0)
	UnlockedClasses: { string },               -- Canonical unlocked HeroClass IDs
	TotalVictories: number,                    -- Lifetime run victories
	TotalRuns: number,                         -- Lifetime runs started
	LastSavedTimestamp: number,                -- os.time() of last persistence save
	CardCollection: { [string]: number },      -- CardDefinition ID -> Permanent quantity owned
	Decks: { [string]: SavedDeck },            -- Keyed by server-generated DeckId
	ActiveDeckId: string?,                     -- Selected starting deck for runs
	DeckSlotEntitlement: DeckSlotEntitlement,  -- Configurable deck slot capacity
	UnlockedSkills: { [string]: boolean },     -- Account-wide unlocked skill IDs
	EquipmentCollection: { [string]: any },    -- Future equipment collection schema placeholder
	GachaBanners: { [string]: any },           -- Future banner/pity schema placeholder
	ProfileRevision: number?,                  -- Monotonically increasing revision number for optimistic concurrency
}

--------------------------------------------------------------------------------
-- 7. Phase 4 Client View Models / DTOs
--------------------------------------------------------------------------------

-- Summary of player's permanent card collection
export type CardCollectionView = {
	Cards: { [string]: number },  -- CardDefinition ID -> Count owned
	TotalUniqueCards: number,
	TotalCardCopies: number,
}

-- Lightweight deck summary for deck selection / lists
export type DeckSummaryView = {
	DeckId: string,
	Name: string,
	CardCount: number,
	ClassId: string?,
	CreatedAt: number,
	UpdatedAt: number,
	IsValid: boolean,
}

-- Detailed deck view for Deck Builder editing
export type DeckDetailView = {
	DeckId: string,
	Name: string,
	Cards: { [string]: number },
	CardCount: number,
	ClassId: string?,
	CreatedAt: number,
	UpdatedAt: number,
	IsValid: boolean,
	ValidationErrors: { string }?,
}

-- Deck slot capacity view
export type DeckSlotView = {
	BaseSlots: number,
	AdditionalSlots: number,
	TotalSlots: number,
	UsedSlots: number,
	AvailableSlots: number,
}

return StateTypes
