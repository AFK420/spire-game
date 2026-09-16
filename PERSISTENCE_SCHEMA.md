# PERSISTENCE SCHEMA SPECIFICATION (VERSION 1)

## Card Rift: Co-op Dungeon

This document defines the canonical persistent account profile data model, schema migrations, reconciliation pipeline, and boundaries between persistent and run-scoped data for Card Rift: Co-op Dungeon.

---

## 1. Schema Overview

The persistent account profile is managed by `PersistenceService` and saved to Roblox DataStores (`CardRift_PlayerProfiles_v3`).

```luau
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
}
```

---

## 2. Invariants & Isolation Boundaries

### 2.1 What is Persisted
- Permanent meta currencies (`AetherShards`, `PremiumCurrency`).
- Account entitlements (`UnlockedClasses`, `DeckSlotEntitlement`, `UnlockedSkills`).
- Permanent card ownership counts (`CardCollection: { [string]: number }`).
- Persistent saved decks referencing CardDefinition IDs and counts (`SavedDeck`).
- Lifetime statistics (`TotalVictories`, `TotalRuns`, `LastSavedTimestamp`).

### 2.2 What is NEVER Persisted
The following runtime objects must never be written to DataStore:
- `Player` instances.
- `CombatState` (turns, combat log, combat participants).
- `EnemyState` (instance IDs, current HP, shield, intents).
- `Hand` objects and runtime `CardInstance` GUIDs.
- Cooldown runtime timers and skill slots.
- Run-scoped equipment instances and run-scoped inventory.
- Transient VFX, animations, or UI states.

---

## 3. Schema Migration & Reconciliation Pipeline

`PersistenceService.reconcile(data: any, userId: number): PlayerProfile` provides deterministic normalization:

```
Loaded Raw Data
     │
     ├── Data is nil? ──> New Account: Seed starter collection & starter deck (v1)
     │
     └── Data is table
           ├── Check ProfileVersion (< 1 or absent: legacy v0 upgrade)
           ├── Non-negativity clamp on currencies (AetherShards >= 0, PremiumCurrency >= 0)
           ├── Validate UnlockedClasses against non-empty string format
           ├── Sanitize CardCollection:
           │     - Strip invalid or unknown card definition IDs
           │     - Strip non-positive or fractional counts
           │     - If empty/missing (v0 upgrade), seed starter cards
           ├── Validate DeckSlotEntitlement (BaseDeckSlots = 4, AdditionalDeckSlots >= 0)
           ├── Sanitize Decks:
           │     - Validate string DeckId and Name
           │     - Strip invalid card entries and clamp quantities
           │     - If empty/missing (v0 upgrade), seed starter deck
           ├── Reconcile ActiveDeckId (fallback to first available deck if missing/deleted)
           └── Set ProfileVersion = 1
```

---

## 4. Concurrency & Persistence Limitations

### Current Implementation:
- In-memory cache `activeProfiles[userId]` is the authoritative source of truth while the player is connected to the server.
- Writes to profile state flow through `PersistenceService.mutateProfile(player, mutatorFn)` ensuring single-threaded atomicity per server.
- Saves occur on `PlayerRemoving`, periodic autosave (`AUTOSAVE_INTERVAL = 300` seconds), and `game:BindToClose`.

### Migration to `UpdateAsync`:
- For cross-server operations (e.g. future trading, external webhooks, or multi-place universes), DataStore writes will migrate from `SetAsync` to `UpdateAsync(key, transformFn)` to resolve conflicting updates transactionally.
- Because `mutateProfile` isolates profile mutations through functional transforms, the logic is already 100% compatible with `UpdateAsync` callbacks.
