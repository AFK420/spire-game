# CARD COLLECTION SUBSYSTEM SPECIFICATION

## Card Rift: Co-op Dungeon

This document outlines the architecture, data models, ownership rules, and integration contracts for the permanent **Card Collection** system.

---

## 1. Core Architectural Distinctions

It is essential to distinguish the three tiers of card representations in Card Rift:

| Concept | Scope | Stored In | Description |
|---|---|---|---|
| **`CardDefinition`** | Static / Catalog | `ReplicatedStorage.Shared.CardData` | Immutable definition defining base cost, target, description, and effects list. |
| **`CardCollection`** | Permanent Account | `PlayerProfile.CardCollection` | Persistent ownership counts (`{ [cardDefId]: quantity }`). |
| **`CardInstance`** | Ephemeral Run | `PlayerState.Deck`, `Hand`, etc. | Runtime mutable object with unique GUID created for a dungeon expedition. |

---

## 2. CardCollectionService API

All permanent card grants, deductions, and queries must flow through `CardCollectionService`:

```luau
-- Queries the number of permanent copies owned of a specific card definition
function CardCollectionService.getCardCount(player: any, cardDefId: string): number

-- Checks if a player owns at least 1 copy of a card definition
function CardCollectionService.hasCard(player: any, cardDefId: string): boolean

-- Returns an isolated copy of the player's permanent collection dictionary
function CardCollectionService.getCollection(player: any): { [string]: number }

-- Authoritatively grants copies of a card definition to a player's collection
function CardCollectionService.grantCard(player: any, cardDefId: string, quantity: number): (boolean, string?)

-- Authoritatively removes copies of a card definition from a player's collection
function CardCollectionService.removeCard(player: any, cardDefId: string, quantity: number): (boolean, string?)

-- Serializes the player's card collection into a client view DTO
function CardCollectionService.toCollectionView(player: any): StateTypes.CardCollectionView
```

---

## 3. Future Gacha / Banner Integration Flow

When banner summons or gacha pulls are implemented in future phases, the service flow remains completely decoupled from DataStore operations:

```
[ Banner / Gacha Service ]
           │
           │ 1. Roll banner RNG & pity counters
           │ 2. Determine awarded card definition and count
           ▼
[ CardCollectionService.grantCard(player, cardDefId, quantity) ]
           │
           │ 1. Validate cardDefId exists in CardData
           │ 2. Validate quantity is positive integer
           ▼
[ PersistenceService.mutateProfile ]
           │
           │ 1. Increment CardCollection[cardDefId]
           │ 2. Update LastSavedTimestamp
           ▼
[ DeckService ]
           └── Newly granted cards become immediately selectable in Deck Builder
```

---

## 4. Default Starter Collection

New player accounts receive a baseline starter card collection configured in `GameConfig.StarterCollection`:
- `Strike`: 5 copies
- `Defend`: 5 copies
- `HeavyBlow`: 2 copies
- `RageSlash`: 2 copies
- `ShieldSlam`: 2 copies
- `FirstAid`: 2 copies
- `PoisonDart`: 2 copies
