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

## 4. Concurrency, Load States & Fail-Closed Protection

### 4.1 Load States (`ProfileLoadState`)
Every player profile lifecycle is strictly governed by authoritative load states:
- `"NotLoaded"`: Profile has not yet attempted loading from DataStore.
- `"Loaded"`: Existing profile successfully fetched from DataStore and reconciled.
- `"New"`: Genuinely new account (`GetAsync` returned `nil`) initialized with starter profile.
- `"LoadFailed"`: DataStore `GetAsync` call failed or threw an error.
- `"Saving"`: DataStore `UpdateAsync` write is currently in progress.

### 4.2 Strict Fail-Closed Guarantee
To prevent catastrophic account wipes when Roblox DataStore experiences outages or rate limits:
1. `loadProfile()` distinguishes between a clean `nil` result (genuinely new account) and a pcall failure (`LoadFailed`).
2. If `GetAsync` fails, `loadProfile()`:
   - Sets load state to `"LoadFailed"`.
   - Returns `nil` without creating or substituting a starter profile.
3. Every save pathway (`saveProfile`, `onPlayerRemoving`, autosave, `BindToClose`) strictly enforces:
   `if loadState ~= "Loaded" and loadState ~= "New" then return false, "Cannot save" end`
4. A failed load can **never** overwrite an existing player's DataStore record on disconnect or server shutdown.

### 4.3 Concurrency & `UpdateAsync` Transactional Safety
- Saving executes via `DataStore:UpdateAsync(userId, transformFn)`.
- `PersistenceService.resolveUpdateConflict(currentData, profile)` verifies `currentData.LastSavedTimestamp <= profile.LastSavedTimestamp`.
- If a newer session timestamp exists in DataStore (e.g. from a concurrent server session or teleport), the save aborts without overwriting remote data, maintaining cross-server consistency.
- In-memory cache `activeProfiles[userId]` is the authoritative source of truth for the local server session, guarded by `mutateProfile`.

