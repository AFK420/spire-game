# PHASE 1 IMPLEMENTATION REPORT: CORE STATE ARCHITECTURE

**Status**: Completed  
**Repository**: [https://github.com/AFK420/spire-game](https://github.com/AFK420/spire-game)  
**Target Milestone**: Phase 1 — Single Source of Truth + Server Service Architecture  

---

## 1. Executive Summary

Phase 1 refactored the legacy *Card Rift: Co-op Dungeon* codebase into a single source of truth server service architecture. The previous prototype suffered from severe state duplication across three scripts (`CombatServer`, `SessionManager`, and `GameCoordinator`) communicating through global `_G`. 

This refactor successfully:
1. **Created a Single Authoritative State Model**: Established canonical data structures (`RunState`, `PlayerState`, `CombatState`, `EnemyState`) in `StateTypes.luau`.
2. **Deconstructed Legacy Monoliths**: Replaced autonomous scripts with modular, deterministic services under `ServerScriptService.Server.services`.
3. **Eliminated State Duplication**: Deleted all 6 legacy `.server.luau` scripts; all gameplay logic is now driven by `init.server.luau`.
4. **Resolved Card Instance Safety**: Replaced fragile integer array indices (`handIndex`) with immutable definitions (`CardData`) and unique runtime GUID instances (`CardInstanceId`).
5. **Introduced Multi-Enemy Encounters**: Migrated from a singleton boss state to an extensible, keyed collection (`Enemies: { [string]: EnemyState }`).
6. **Standardized Network Communications**: Centralized all RemoteEvents into `ReplicatedStorage.GameNetwork` with token-bucket category rate-limiting.
7. **Implemented Monotonic Turn Timers**: Eliminated client-drift by driving turn countdowns strictly via `os.clock()`.

---

## 2. File Inventory of Changes

### A. New Modules Created
| File Path | Description |
| :--- | :--- |
| `src/shared/StateTypes.luau` | Canonical type definitions for `RunState`, `PlayerState`, `CombatState`, `EnemyState`, `CardInstance`, and client DTO snapshots (`RunSnapshot`, `CombatSnapshot`, etc.). |
| `src/server/services/NetworkService.luau` | Central network manager owning `ReplicatedStorage.GameNetwork`, rate limiting, and snapshot dispatchers. |
| `src/server/services/PersistenceService.luau` | Encapsulated DataStore persistence for player profiles, meta-currency, and class unlock states. |
| `src/server/services/CardService.luau` | Runtime instance engine; generates `CardInstanceId`, manages draw/discard piles, and converts instances to client `CardView`s. |
| `src/server/services/ClassService.luau` | Manages hero classes, subclasses, starting decks, and active gimmick calculations (Rage, Combo, Overload, etc.). |
| `src/server/services/RelicService.luau` | Passive relic trigger engine (`OnCombatStart`, `OnTurnStart`, `OnCardPlay`, `OnTurnEnd`, `OnDamageTaken`, `OnKill`). |
| `src/server/services/DungeonService.luau` | Procedural dungeon pathfinding wrapper. |
| `src/server/services/ArenaVisualizer.luau` | Reactive Workspace 3D scene visualizer; builds platforms and spawns multi-enemy models without owning gameplay state. |
| `src/server/services/CombatService.luau` | Authoritative multi-enemy combat engine with monotonic turn timers and downed/rescue co-op mechanics. |
| `src/server/services/RunManager.luau` | Authoritative run state machine managing rooms, party lifecycle, and post-combat drafting. |

### B. Files Modified
| File Path | Changes |
| :--- | :--- |
| `src/server/init.server.luau` | Upgraded to master server bootstrap, deterministically loading services and registering network event listeners. |
| `src/client/UIController.client.luau` | Refactored to listen to `GameNetwork` events, use `CardInstanceId` for playing cards, render multi-enemy targets, and display monotonic timer. |
| `src/client/ClassSelectUI.client.luau` | Updated to dispatch `SelectClass` through `GameNetwork` and listen to `RunStateUpdate`. |
| `src/client/RelicUI.client.luau` | Updated to synchronize inventory from `RunSnapshot.Party` and listen to `RelicNotification`. |

### C. Legacy Files Safely Removed
| Removed File Path | Rationale for Removal |
| :--- | :--- |
| `src/server/CombatServer.server.luau` | Decomposed into `CombatService.luau` and `ArenaVisualizer.luau`. |
| `src/server/SessionManager.server.luau` | Co-op mechanics integrated directly into `CombatService.luau` and `RunManager.luau`. |
| `src/server/GameCoordinator.server.luau` | Run state machine integrated into `RunManager.luau`. |
| `src/server/RelicManager.server.luau` | Replaced by `RelicService.luau`. |
| `src/server/ClassManager.server.luau` | Replaced by `ClassService.luau`. |
| `src/server/ProfileStore.server.luau` | Replaced by `PersistenceService.luau`. |
| `src/shared/Hello.luau` | Obsolete placeholder script. |

---

## 3. Detailed Technical Solutions

### 3.1 Elimination of `_G` & Autonomous Scripts
Previously, `CombatServer`, `SessionManager`, and `GameCoordinator` each created independent global references on `_G`:
```luau
-- Legacy anti-pattern:
_G.CombatServer = ...
_G.SessionManager = ...
_G.GameCoordinator = ...
```
This created race conditions depending on which script executed first. 

**Solution**: All state logic now exists as Luau `ModuleScript` services loaded deterministically by `init.server.luau`. No service writes to `_G`. Circular dependencies are prevented through explicit forward referencing or layered dependency hierarchy.

### 3.2 Definition vs. Runtime Instance Separation
Previously, playing cards used numeric hand indices:
```luau
-- Legacy:
PlayCardEvent:FireServer(handIndex)
```
If two cards were played in rapid succession, the second index would point to the wrong card or cause an out-of-bounds error.

**Solution**:
```luau
export type CardInstance = {
    InstanceId: string,         -- Unique stable GUID: "card_50123_4_f19a2b"
    DefinitionId: string,       -- Definition key: "Strike"
    CardData: CardData.Card,    -- Immutable definition reference
    OwnerUserId: number,        -- Owner player's UserId
}
```
Cards in a player's hand are stored as a hashmap keyed by `CardInstanceId`: `Hand: { [string]: CardInstance }`. The client sends `PlayCard:FireServer(cardInstanceId, targetEnemyId)`. Lookup is $O(1)$, deterministic, and entirely immune to array shifting bugs.

### 3.3 Multi-Enemy Encounter Support
Previously, `currentBoss` was a single struct containing HP and Shield.

**Solution**:
`CombatState.Enemies` is a keyed dictionary:
```luau
export type CombatState = {
    CombatId: string,
    Phase: CombatPhase,
    TurnNumber: number,
    TurnStartTime: number,
    TurnDuration: number,
    Participants: { number },
    Enemies: { [string]: EnemyState }, -- Supports 1 to N enemies
    ReadyPlayers: { [number]: boolean },
    CombatLog: { CombatEvent },
}
```
`CombatService.startCombat` automatically scales encounter compositions:
- **Tier 1-2 Combat**: 1 Spire Sentinel.
- **Tier 3+ Combat**: 1 Spire Sentinel + 1 Dark Cultist minion.
- **Elite Encounter**: 1 Gremlin Nob with enhanced stats.
- **Act Boss**: 1 Spire Guardian / Corrupt Archon.
`ArenaVisualizer` automatically arranges multiple enemies in Workspace with individual health bars and intent indicators.

### 3.4 Monotonic Turn Timer
Previously, `SessionManager` decremented a floating point number in a `task.wait(1)` loop, causing client desynchronization.

**Solution**:
Turn start records a monotonic CPU timestamp via `os.clock()`:
```luau
activeCombat.TurnStartTime = os.clock()
activeCombat.TurnDuration = 45
```
Every snapshot sent to the client evaluates `TimeRemaining = math.max(0, math.ceil(TurnDuration - (os.clock() - TurnStartTime)))`. The server timer runs on `RunService.Heartbeat`, ensuring exact auto-resolution on expiration.

### 3.5 Downed & Teammate Rescue System
When a player's HP reaches 0:
1. `playerState.IsDowned = true`, `playerState.Resources.HP = 0`, `playerState.Resources.Shield = 0`.
2. Downed players cannot play cards or vote ready.
3. Any conscious teammate can call `RescueTeammateEvent:FireServer(downedUserId)`.
4. Rescuing costs 2 Energy and revives the teammate with 25% of their Max HP.
5. If all party members are downed simultaneously, `CombatService` triggers team defeat.

---

## 4. Verification & Validation

1. **Rojo Project Build**:
   - Command: `rojo build -o test.rbxl`
   - Result: Successfully compiled project with **Exit Code 0**, verifying that all Rojo paths, files, and instance trees are valid.
2. **Static Typing**:
   - All newly introduced and modified files enforce `--!strict` typing without Luau type-check failures.
3. **Backward Compatibility**:
   - Prototype gameplay loop (Lobby $\to$ Class Selection $\to$ Map Selection $\to$ Multi-Enemy Combat $\to$ 3-Card Universal Draft Rewards $\to$ Map) is completely preserved under the new architecture.
