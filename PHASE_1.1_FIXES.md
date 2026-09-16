# Phase 1.1 — Critical Fixes & Hardening Specification
**Card Rift: Co-op Dungeon**  
Repository: [AFK420/spire-game](https://github.com/AFK420/spire-game)  
Branch: `master`

---

## 1. Executive Summary

Phase 1.1 delivers a targeted hardening pass addressing correctness bugs and safety gaps identified during architecture code review of Phase 1. 

**Explicit Constraint**: DO NOT START PHASE 2. Phase 2 systems (generic `EffectResolver`, `ModifierResolver`, damage pipeline redesign, equipment affix engine, passive skill trees, and reactions) remain intentionally deferred.

---

## 2. Bugs Fixed & Architectural Adjustments

### 2.1 Deck Persistence Across Encounters (Never Reset Run Deck)
- **Problem**: `CombatService.startCombat()` invoked `ClassService.applyClassToPlayer(playerState)`, which cleared `playerState.Deck`, `Hand`, `DiscardPile`, and `ExhaustPile`, regenerating starting class cards and wiping all drafted reward cards.
- **Fix**:
  - Refactored `ClassService.luau` into distinct, single-responsibility methods:
    - `initializeStartingDeck(playerState)`: Invoked strictly once during initial character creation in Lobby.
    - `applyBaseClassStats(playerState)`: Configures base HP, energy, and subclass bonuses without touching card collections.
    - `resetCombatResources(playerState)`: Resets temporary combat flags, energy, and shield.
    - `resetClassCombatGimmicks(userId)`: Resets class mechanic counters.
    - `selectClass(...)`: Strictly rejects class changes if `RunState.Phase ~= "Lobby"`.
  - Added `CardService.resetCombatPiles(playerState)`: Gathers cards from `Hand`, `DiscardPile`, and `ExhaustPile` back into `Deck` and shuffles the draw pile without discarding any acquired cards.
  - `CombatService.startCombat()` now preserves the player's run deck and only resets combat-specific piles and resources.

### 2.2 Proper Card Targeting Model & Strict Server Validation
- **Problem**: `CombatService.playCard()` assumed all cards target enemies and fell back to the first living enemy when no target was specified, breaking `Self` and `Ally` cards.
- **Fix**:
  - Extended `TargetType` in `CardData.luau`: `"Enemy" | "Self" | "Ally" | "None"`.
  - Added `Target` to `CardView` snapshot DTO in `StateTypes.luau` and populated it in `CardService.toCardView()`.
  - Server-side validation in `CombatService.playCard()`:
    - **Enemy Target**: Rejects `nil`, non-string, non-existent, or dead enemy IDs (`"Target enemy is already defeated."`).
    - **Self Target**: Auto-targets the player; rejects attempts to target other entities.
    - **Ally Target**: Validates target is a valid party member UserId; rejects non-party or invalid targets.
    - **Downed / Energy / Phase**: Rejects card play by downed players, when energy is insufficient, or during non-Player phases.

### 2.3 First Aid Revive & Heal Mechanics
- **Problem**: `FirstAid` defined both `Revive` and `Heal` effects, but `Revive` was unimplemented and `Heal` only applied to self.
- **Fix**:
  - If target ally is downed: executes `Revive`, restores specified revive HP (30 HP), and skips `Heal` to prevent double-healing.
  - If target ally is alive: executes `Heal`, restoring +30 HP up to Max HP, and skips `Revive`.
  - Targeting an enemy with First Aid is rejected at target validation time.

### 2.4 Relic Double-Trigger Bug Resolution
- **Problem**: In `RelicService.triggerEvent()`, the `OnCardPlay` branch iterated over all player relics and checked `RelicService.hasRelic(playerState, "Vajra")`, which added +2 per relic in the inventory rather than once. Additionally, `Vajra` and `Akabeko` were incorrectly tagged with `OnCombatStart` and `OnTurnStart` in `RelicData.luau`.
- **Fix**:
  - Corrected triggers for `Vajra` and `Akabeko` to `"OnCardPlay"` in `RelicData.luau`.
  - Added `evaluatedRelics` tracking in `RelicService.triggerEvent()` to ensure each unique relic ID is evaluated at most once per trigger call.
  - Replaced loose `hasRelic` check with explicit `id == "Vajra"`, `id == "Akabeko"`, and `id == "Sundial"`.
  - Vajra grants exactly +2 per attack, Akabeko grants +8 on the first attack only, and Sundial increments once per attack (granting +2 energy every 3 attacks).

### 2.5 GameConfig as Authoritative Single Source of Configuration
- Unified all configuration parameters in `GameConfig.luau`:
  - `Combat`: `TurnDuration` (45s), `DefaultBaseHP` (100), `DefaultStartingEnergy` (3), `BaseHandDrawCount` (4).
  - `Coop`: `RescueEnergyCost` (2), `ReviveHpPercent` (0.25), `EnemyHpScaleMultiplier` (0.65), `EnemyAtkScaleMultiplier` (0.20).
  - `NetworkLimits`: Rate limits and refill rates for Combat, Map, Class, and General categories.
- Added `NetworkService.cleanPlayer(userId)` to flush rate limit buckets on disconnect.

### 2.6 Persistence Autosave & TotalRuns Tracking
- Implemented background autosave loop in `PersistenceService.luau` running every `AUTOSAVE_INTERVAL` (300s) and on `game:BindToClose`.
- Added `PersistenceService.recordRunStarted(player)` which increments `TotalRuns` strictly once when `RunManager.startRun()` transitions from Lobby to MapSelect.

### 2.7 Player Lifecycle & Disconnect Safety
- In `RunManager.removePlayer(player)`: clears `PlayerInstance = nil`, sets `IsConnected = false`, flushes rate limits, and persists player profile.
- In `CombatService.luau`: `areAllLivingPlayersReady()` checks `pState.IsConnected ~= false` so disconnected players do not prevent living connected players from readying up.
- Reconnection via `RunManager.addPlayer(player)` reattaches `PlayerInstance`, sets `IsConnected = true`, and preserves deck, resources, and gold without state corruption.

### 2.8 UI Ownership Decoupling
- Eliminated destructive `existingGui:Destroy()` calls in `UIController.client.luau`.
- Separated UI hierarchies into dedicated, non-interfering ScreenGuis:
  - `CardRiftScreenGui`: Owned by `UIController.client.luau` (HUD, Map, Rewards).
  - `CardRiftClassSelectGui`: Owned by `ClassSelectUI.client.luau` (DisplayOrder 20).
  - `CardRiftRelicGui`: Owned by `RelicUI.client.luau` (DisplayOrder 15).
- Cleaned legacy references to `"ClassEvents"` and `ClassManager`.

---

## 3. Production API Integration Test Suite

`TestRunner.luau` executes 14 comprehensive test suites exercising actual production methods:

1. **Suite 1**: 1–4 players join & shared `RunState` verification (`IsConnected == true`).
2. **Suite 2**: Class selection & starting deck synthesis (Titan +10 MaxHP, unique GUIDs).
3. **Suite 3**: Run start & persistence `TotalRuns` tracking (increments strictly once; mid-run class change rejected).
4. **Suite 4**: Map voting & consensus room traversal via `RunManager.voteMapNode()`.
5. **Suite 5**: Mathematical co-op scaling across 1–4 players (+65% HP, +20% ATK per extra player).
6. **Suite 6**: Strict card targeting & API rejection checks (invalid enemy, nil target, dead enemy, self card targeting enemy, ally card targeting non-party/nil, unauthorized player, insufficient energy, wrong phase, downed player).
7. **Suite 7**: First Aid mechanics (downed ally revived with 30 HP, living ally healed +30 HP, enemy target rejected).
8. **Suite 8**: Relic trigger correctness (0 relics, 1 relic Vajra +2, 2 relics Vajra+Akabeko +10 on first attack, multiple duplicate IDs evaluated once, Sundial 3-attack counter).
9. **Suite 9**: Safe card play & double-play rejection via `CombatService.playCard()`.
10. **Suite 10**: Downed state & teammate rescue mechanics (2 energy, 25% revive HP).
11. **Suite 11**: Turn ready voting & monotonic turn timeout auto-resolution via `CombatService.forceTurnTimeout()`.
12. **Suite 12**: Enemy defeat, rewards generation, 3-card universal draft claim, and double-claim rejection.
13. **Suite 13 (CRITICAL INVARIANT)**: Card persistence across multiple combat encounters — verifies that reward cards and original card instances remain in the player deck when traveling from Combat #1 to Combat #2.
14. **Suite 14**: Disconnect & reconnect mid-run state resilience.

---

## 4. Known Prototype Constraints & Intentional Limitations

The following architectural constraints are intentionally preserved for Phase 1.1:
1. **One Active Run Per Server**: `RunManager` maintains a single active `currentRun`. Multi-run support (`RunId -> RunState`) is scheduled for future phases.
2. **One Active Combat Encounter Per Server**: `CombatService` maintains a single active `activeCombat`.
3. **Phase 2 Systems Deferred**: No generic `EffectResolver`, `ModifierResolver`, damage pipeline redesign, equipment affix engine, passive skill trees, or elemental status reactions were introduced in this pass.

---

## 5. Verification Status

- **Rojo Build**: `rojo build -o test.rbxl` compiles with **Exit Code 0**.
- **Offline Logic Verifier**: `tests/verify_phase1_integration.py` passes **105/105 checks**.
- **Typing**: `--!strict` maintained on 100% of Luau files.
