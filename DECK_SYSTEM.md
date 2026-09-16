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
	ClassId: string?,             -- Optional target class binding (e.g. "Warlord")
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
3. **Card Copy Limits**: Maximum 3 copies of any card definition per deck (`GameConfig.Deck.MaxCopiesPerCard`).
4. **Deck Size Bounds**:
   - Minimum 8 cards (`GameConfig.Deck.MinDeckSize`).
   - Maximum 30 cards (`GameConfig.Deck.MaxDeckSize`).
5. **Class Eligibility**: If a `ClassId` is specified, it must match a registered class in `ClassData`.

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
                 └── ClassService synthesizes default ClassData.StartingDeck
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
3. **Mid-Run Editing Safety**: Editing or deleting saved decks while a run is active has zero impact on the running expedition's in-progress card piles.

---

## 5. RemoteEvent Network Endpoints

All endpoints are rate-limited under `"General"` and validate arguments strictly:

| RemoteEvent | Arguments | Server Action |
|---|---|---|
| `CreateDeck` | `(name, cards?, classId?)` | Generates server GUID, verifies slot capacity, saves deck. |
| `RenameDeck` | `(deckId, newName)` | Validates name length, updates `UpdatedAt`. |
| `DeleteDeck` | `(deckId)` | Deletes deck; falls back `ActiveDeckId` if active deck was deleted. |
| `SaveDeck` | `(deckId, cards)` | Validates full deck against player's collection, updates deck. |
| `DuplicateDeck` | `(sourceDeckId, newName?)` | Checks slot availability, clones card list with fresh server GUID. |
| `SelectActiveDeck`| `(deckId)` | Validates target deck is playable; updates `ActiveDeckId`. |
| `RequestDecks` | `()` | Sends `DeckListUpdate` with summaries and slot info. |
| `RequestCardCollection` | `()` | Sends `CardCollectionUpdate` with collection view. |
