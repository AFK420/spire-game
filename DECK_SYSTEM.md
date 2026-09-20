# DECK MANAGEMENT & VALIDATION SUBSYSTEM

## Card Rift: Co-op Dungeon

This document outlines the data structures, slot entitlement model, authoritative validation rules, and network contracts for the **Deck Management & Deck Builder** subsystem.

---

## 1. SavedDeck Data Model

Persistent decks are stored inside `PlayerProfile.Decks` keyed by a server-generated `DeckId`.

```luau
export type SavedDeck = {
	DeckId: string,               -- Server-generated GUID (e.g. "deck_10001_172648_a8f9c2")
	Name: string,                 -- Player deck name (trimmed, 1 to MaxDeckNameLength)
	Cards: { [string]: number },  -- CardDefinition ID -> Quantity owned/slotted
	ClassId: string?,             -- Legacy compatibility field; normalized to nil
	CreatedAt: number,            -- Creation timestamp
	UpdatedAt: number,            -- Last edited timestamp
}
```

---

## 2. Configurable Deck Slot Entitlement

The slot entitlement model separates free base slots from future purchased or earned slots:

```luau
TotalAvailableSlots = math.min(GameConfig.Deck.MaxDeckSlots, BaseDeckSlots + AdditionalDeckSlots)
```

- **`BaseDeckSlots`**: Defaults to 4 (`GameConfig.Deck.BaseDeckSlots`).
- **`AdditionalDeckSlots`**: Defaults to 0; can be increased via monetization or meta achievements without modifying `DeckService` logic.
- **`MaxDeckSlots`**: Upper safety ceiling of 20 (`GameConfig.Deck.MaxDeckSlots`).

---

## 3. Authoritative Deck Validation Rules

`DeckService.validateDeck(player, cards, classId)` enforces:

1. **Card Definition Existence**: Every card ID in the deck must exist in `CardData`.
2. **Permanent Collection Ownership**: The quantity of any card slotted must not exceed the permanent count owned in `CardCollectionService.getCardCount(player, cardDefId)`.
3. **Card Copy Limits**: The strictest global, rarity, and card-specific cap applies. Common/Uncommon may reach 3, Rare 2, and Super Rare/Ultra Rare 1 unless a card is stricter.
4. **Deck Size Bounds**:
   - Minimum 8 cards (`GameConfig.Deck.MinDeckSize`).
   - Maximum 30 cards (`GameConfig.Deck.MaxDeckSize`).
5. **Class Independence**: Decks are never class-locked. Legacy `ClassId` values are discarded during sanitization, and new decks always store `ClassId = nil`.

---

## 4. Run Integration & Active Deck Selection

At the start of an expedition or when preparing player state:

```
[ Persistent Profile ]
          │
          ├── ActiveDeckId points to candidate SavedDeck
          ▼
[ DeckService.getActiveDeck(player) ]
          │
          ├── 1. Check if ActiveDeckId is valid via validateDeck
          │      └── If Valid ──> Use active SavedDeck
          ├── 2. If Invalid/Missing ──> Deterministically search sorted decks
          │      └── If Valid Deck Found ──> Use that fallback SavedDeck
          └── 3. If No Valid Decks ──> Return nil (Zero profile mutation)
                 └── ClassService synthesizes the universal fallback deck
          ▼
[ CardService.createCardInstance(cardDefId, userId) ]
          │
          └── Synthesize fresh runtime CardInstances with unique GUIDs
          ▼
[ PlayerState.Deck in RunState ]
          │
          └── Run / Combat only manipulates runtime CardInstances
```

Key Runtime Invariants:
1. **Zero Persistence Mutation on Resolution**: `getActiveDeck()` never mutates `ActiveDeckId` or any saved deck in the persistent profile during resolution or fallback.
2. **Strict Run Isolation**: Combat card movement (drawing, playing, discarding, exhausting, creating cards) NEVER alters the persistent `SavedDeck` or permanent `CardCollection`.
3. **Mid-Run Mutation Rejection**: All deck mutations (`CreateDeck`, `RenameDeck`, `DeleteDeck`, `SaveDeck`, `DuplicateDeck`, `SelectActiveDeck`) are strictly rejected by `DeckService` and `init.server` during active dungeon runs outside Lobby (`Phase ~= "Lobby"`), returning `"Cannot modify decks during an active run."`.
4. **Server-Authoritative Deletion Rules**:
   - **Only Deck Rejection**: Reject deleting the sole remaining deck (`"Cannot delete your only deck."`).
   - **Active Deck Rejection**: Reject deleting the currently active deck (`"Cannot delete active deck. Switch active deck first."`).
   - **No Mutation on Rejection**: `ActiveDeckId` and deck counts are preserved on rejection with zero persistence mutation.
   - **Safe Inactive Deletion**: Deleting an inactive deck succeeds and preserves `ActiveDeckId`.

---

## 5. RemoteEvent Network Endpoints

All endpoints are rate-limited under `"General"`, enforce the Lobby phase boundary (rejecting mid-run mutations), and validate arguments strictly:

| RemoteEvent | Arguments (Client $\to$ Server) | Server Action / Behavior |
|---|---|---|
| `CreateDeck` | `(name: string, cards: { [string]: number }?, classId: string?)` | Generates server GUID, verifies slot capacity, creates deck (class-agnostic when `classId = nil`). Rejected mid-run. |
| `RenameDeck` | `(deckId: string, newName: string)` | Validates name length (1–24 chars), updates deck name authoritatively. Rejected mid-run. |
| `DeleteDeck` | `(deckId: string)` | Strictly server-authoritative: rejects deleting only deck or active deck; deletes inactive deck without mutating `ActiveDeckId`. Rejected mid-run. |
| `SaveDeck` | `(deckId: string, cards: { [string]: number })` | Validates the full deck against collection ownership, 8–30 cards, and rarity/card-specific copy limits. Rejected mid-run. |
| `DuplicateDeck` | `(sourceDeckId: string, newName: string?)` | Checks slot availability, clones card list with fresh server GUID. Rejected mid-run. |
| `SelectActiveDeck`| `(deckId: string)` | Validates target deck is playable; updates `ActiveDeckId`. Rejected mid-run. |
| `RequestDecks` | `()` | Sends `DeckListUpdate` with summaries, activeDeckId, and slot info. |
| `RequestCardCollection` | `()` | Sends `CardCollectionUpdate` with collection view. |

### Server $\to$ Client Response Events:

- **`DeckListUpdateEvent`**:
  - **Server Dispatch**: `DeckListUpdateEvent:FireClient(player, summaries, activeDeckId, slotInfo)`
  - **Client Listener**: `DeckListUpdateEvent.OnClientEvent:Connect(function(summaries: { StateTypes.DeckSummaryView }, activeDeckId: string, slotInfo: StateTypes.DeckSlotView?))`
- **`DeckDetailUpdateEvent`**:
  - **Server Dispatch**: `DeckDetailUpdateEvent:FireClient(player, detail)`
  - **Client Listener**: `DeckDetailUpdateEvent.OnClientEvent:Connect(function(detail: StateTypes.DeckDetailView))`
- **`CardCollectionUpdateEvent`**:
  - **Server Dispatch**: `CardCollectionUpdateEvent:FireClient(player, collectionView)`
  - **Client Listener**: `CardCollectionUpdateEvent.OnClientEvent:Connect(function(col: StateTypes.CardCollectionView))`
- **`ActionResultEvent`**:
  - **Server Dispatch**: `ActionResultEvent:FireClient(player, { Action = actionName, Success = ok, Message = errMsg })`
  - **Client Listener**: `ActionResultEvent.OnClientEvent:Connect(function(result: StateTypes.ActionResult))`
