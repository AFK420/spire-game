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
	VotedNodeId: string?,
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

export type ActiveRoom = {
	NodeId: string,
	Type: ActiveRoomType,
	Tier: number,
	ActIndex: number,
	RoomEncounterId: string?,
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
	PendingRewards: RunRewards?,
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
	Gold: number,
	RelicIds: { string },
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
	Party: { [string]: PlayerView },
	Rewards: {
		GoldAmount: number,
		AetherShardsAmount: number,
		OfferedCards: { CardView },
		HasClaimed: boolean,
	}?,
	Message: string?,
}

return StateTypes
