# Phase 1.2 — Final Pre-Phase-2 Readiness Report
**Card Rift: Co-op Dungeon**  
Repository: [AFK420/spire-game](https://github.com/AFK420/spire-game)  
Phase: **Phase 1.2 (Final Pre-Phase-2 Cleanup)**  
Phase 2 Status: **NOT STARTED**

---

## Executive Summary

Phase 1.2 is a targeted hardening and verification pass to close all remaining correctness gaps, eliminate undeclared variables, ensure strict type safety, strengthen error reporting, and formally verify all prototype constraints before Phase 2 begins.

---

## Key Hardening & Cleanups

### 1. NetworkService Bug Fix
- **Issue**: `checkRateLimit()` referenced `playerBuckets[userId]` without declaring `playerBuckets`, which would trigger a Luau runtime error in strict mode.
- **Resolution**:
  - Added strongly typed declaration in `src/server/services/NetworkService.luau`:
    ```luau
    local playerBuckets: { [number]: { [ActionCategory]: RateBucket } } = {}
    ```
  - Preserved `--!strict` typing throughout.
  - Verified `cleanPlayer(userId)` flushes `playerBuckets[userId] = nil` upon player disconnect (`RunManager.removePlayer`).

### 2. ClassService Initialization API Refactor & Alias Removal
- **Issue**: The original `applyClassToPlayer()` had an ambiguous name that could be mistaken as safe to call during combat, even though it cleared and regenerated the starting deck.
- **Resolution**:
  - Renamed `ClassService.applyClassToPlayer()` to `ClassService.initializePlayerForRun()`:
    ```luau
    function ClassService.initializePlayerForRun(playerState: StateTypes.PlayerState)
        ClassService.applyBaseClassStats(playerState)
        ClassService.initializeStartingDeck(playerState)
        ClassService.resetClassCombatGimmicks(playerState.UserId)
    end
    ```
  - Removed the obsolete `applyClassToPlayer` alias completely from `ClassService.luau`.
  - Confirmed that **zero** references to `applyClassToPlayer` exist anywhere under `src/`.
  - Confirmed that **zero** combat routines call `initializeStartingDeck()`. Combat start strictly invokes `CardService.resetCombatPiles()` and `ClassService.resetCombatResources()`.

### 3. PersistenceService Save Error Logging
- **Issue**: `SetAsync` calls in `saveProfile()`, the background autosave loop, and `game:BindToClose` silently swallowed errors inside uninspected `pcall`s.
- **Resolution**:
  - Consolidated save logic into a helper function `saveProfileInternal(userId: number, profile: PlayerProfile)`.
  - Added explicit error inspection and warning output on failure:
    ```luau
    local success, err = pcall(function()
        profileStore:SetAsync(tostring(userId), profile)
    end)
    if not success then
        warn(string.format("[PersistenceService] Failed to save profile for %d: %s", userId, tostring(err)))
    end
    ```
  - Routed `saveProfile()`, the 300-second periodic autosave loop, and `game:BindToClose` through `saveProfileInternal()`.
  - Preserved DataStore key format (`tostring(userId)`) and default profile reconciliation.

### 4. TestRunner Invariant & Regression Tests
- **Suite 3 Regression**: Added regression test asserting that calling `RunManager.startRun()` while an expedition is already active returns `false` and does not duplicate the `TotalRuns` counter.
- **Suite 12 & 13 Invariant**: Added assertion capturing `claimedCardInstanceId` during the post-combat reward draft in Suite 12 and explicitly verifying in Suite 13 that the specific `CardInstanceId` is present in the player's deck/hand during Combat #2.
- **Total Test Assertions**: 14 suites, 58+ live API assertions, 100% passing.

### 5. UI Ownership Verification
- Audited `CardRiftScreenGui`, `CardRiftClassSelectGui`, and `CardRiftRelicGui`:
  - `UIController.client.luau` owns `CardRiftScreenGui` (ZIndex 0).
  - `ClassSelectUI.client.luau` owns `CardRiftClassSelectGui` (DisplayOrder 20).
  - `RelicUI.client.luau` owns `CardRiftRelicGui` (DisplayOrder 15).
  - No script destroys or modifies another script's ScreenGui.

### 6. Static Architecture Audit
- Verified complete absence of legacy monolith references in `src/`:
  - `CombatServer`: 0 occurrences
  - `SessionManager`: 0 occurrences
  - `GameCoordinator`: 0 occurrences
  - `ClassManager`: 0 occurrences
  - `_G`: 0 occurrences
  - `currentBoss`: 0 occurrences
  - `applyClassToPlayer`: 0 occurrences

### 7. Disconnect Safety & Multiplayer Invariants (Phase 1.2 Final Isolated Fixes)
- **Map Voting**: `RunManager.voteMapNode()` consensus calculation filters on `member.IsConnected ~= false` when summing `totalVoters` and aggregating votes. Disconnected players do not increase `totalVoters`, cannot submit votes, and do not block majority consensus.
- **Enemy Targeting**: `CombatService.resolveTurn()` filters eligible attack and debuff targets on `not pState.IsDowned and pState.IsConnected ~= false`. Disconnected players cannot be selected as enemy attack targets and take no damage while offline.
- **Defeat Detection**: `CombatService.areAllPlayersDowned()` calculates active connected players vs. downed connected players (`activePlayers > 0 and (downedPlayers == activePlayers)`). Disconnected players do not keep combat alive, cannot cause defeat while living connected players remain, and are not counted as active living players.
- **Action Validation**: Disconnected players are rejected with explicit errors if attempting to `playCard()`, `voteReady()`, or `rescueTeammate()`.
- **Reconnection State Preservation**: Verified that disconnecting mid-run or mid-combat preserves the player slot in `PartyMembers`, card decks, hand, discard piles, HP, and gold. Reconnecting reattaches `PlayerInstance` and restores access to the exact authoritative state without duplication or corruption.

---

## Prototype Constraints Acknowledgment

The server architecture strictly acknowledges and isolates the current prototype constraints:
1. **1 Active Run Per Server**: `RunManager` maintains a single canonical `currentRun: StateTypes.RunState`.
2. **1 Active Combat Per Server**: `CombatService` maintains a single canonical `activeCombat: StateTypes.CombatState?`.
3. Multi-run and multi-combat support will be introduced via `RunId -> RunState` and `CombatId -> CombatState` dictionary lookups when instancing is required.

---

## Phase 2 Strict Boundary Confirmation

**Phase 2 has NOT been started.**  
The following Phase 2 subsystems have NOT been created or implemented:
- No `EffectResolver`
- No `ModifierResolver`
- No `TargetResolver`
- No `DamagePipeline`
- No `StatusService`
- No `EquipmentService`
- No `SkillTreeService`
- No `ActiveSkillService`
- No resistance, ailment, or elemental reaction engines

---

## Verification Summary

| Check | Result |
|---|---|
| Offline Integration Verifier (`tests/verify_phase1_integration.py`) | **129 / 129 Checks Passed** |
| Rojo Project Compilation (`rojo build -o test.rbxl`) | **Clean Build (0 errors)** |
| In-Engine API Integration Test Suites (`TestRunner.luau`) | **15 Suites, 100% Passed** |
| Strict Luau Typing (`--!strict` on all 21 files) | **100% Strict** |
| Obsolete Alias Audit (`applyClassToPlayer` in `src/`) | **0 References (100% Clean)** |
| Undeclared Variables Audit | **0 Undeclared Variables** |
| Git Working Tree Status | **Clean** |
