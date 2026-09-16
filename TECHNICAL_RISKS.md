# Technical Risks: Card Rift: Co-op Dungeon

> [!NOTE]
> **Audit Resolution Status: 100% Mitigated & Resolved (Phases 1.0 – 4.1)**  
> All architectural, concurrency, security, and persistence risks identified in this document have been eliminated through discrete vertical slice hardening passes. See the resolution matrix below.

| Risk Category | Specific Flaw | Initial Severity | Resolved In | Resolution Mechanism |
| :--- | :--- | :---: | :---: | :--- |
| **1.1 State Divergence** | Triple-state split across 3 server scripts | **CRITICAL** | Phase 1.0 | Unified `RunManager` (RunState SSOT) and `CombatService` (CombatState SSOT). |
| **1.2 Singleton Enemy** | `currentBoss` module singleton | **HIGH** | Phase 1.0 | Keyed entity table `Enemies: { [string]: EnemyState }` supporting 1..$N$ combatants. |
| **1.3 Direct Stat Drift** | Uncontrolled mutations to base stats | **HIGH** | Phase 3.0 | `StatResolver`: deterministic `(Base + Add) * Mult` with absolute override priority. |
| **2.1 Hand Index Shift** | Array index card plays causing race conditions | **CRITICAL** | Phase 1.0 | `CardInstance` unique GUIDs and keyed dictionary `Hand: { [InstanceId]: CardInstance }`. |
| **2.2 Desynced Countdown** | Independent timers across client/server | **HIGH** | Phase 1.0 | Monotonic `TurnStartTime` via `os.clock()` and authoritative server ready voting. |
| **3.1 Hardcoded Pipelines** | Giant `if-elseif` ladders in managers | **HIGH** | Phase 2.0 | Generic `EffectResolver`, `DamagePipeline`, `ModifierResolver`, `TargetResolver`. |
| **3.2 Class-Tied Cards** | Cards rigidly hardcoded to single classes | **MEDIUM** | Phase 2.0 | Universal card foundation with data-driven effects and target constraints. |
| **4.1 Network Spoofing** | Forged player identity / remote spamming | **CRITICAL** | Phase 1–4 | `NetworkService`: token-bucket rate limits; sender identity derived from `player.UserId`. |
| **4.2 DataStore Overwrites** | Load failure creating fresh profiles & overwriting | **CRITICAL** | Phase 4.1 | Fail-closed `ProfileLoadState`: load failure aborts saving; `UpdateAsync` concurrency safety. |

---

## 1. Architectural & State Risks

### 1.1 State Divergence & Split-Brain Condition (CRITICAL)
* **Risk:** The server runs 3 distinct state representations for the same game session:
  * `CombatServer.activeSessions`
  * `SessionManager.currentSession`
  * `GameCoordinator.coordinator`
* **Impact:** 
  * If Player A plays an attack in `CombatServer`, `CombatServer.currentBoss` loses HP, but `SessionManager.currentSession.Enemy` remains at full health.
  * When `SessionManager`'s 45s timer expires, it attacks based on its own enemy HP, potentially reviving an enemy already killed in `CombatServer`.
  * Cards drafted in `GameCoordinator` during `Rewards` update `GameCoordinator.coordinator.Players[p].Deck`, but `CombatServer` never receives the new cards for subsequent rooms.
* **Mitigation:**
  * Consolidate into a single authoritative **Run & Combat State Service** (`ServerRunManager`).
  * Eliminate private local session tables across separate scripts.

### 1.2 Singleton Enemy Limitation (HIGH)
* **Risk:** `CombatServer` defines `currentBoss: BossCombatant` as a single static module-level table.
* **Impact:**
  * Impossible to spawn multiple enemies in a single room (e.g. 3 Cultists, 1 Boss + 2 Summons).
  * Prevents running multiple dungeon instances simultaneously on the same Roblox game server.
* **Mitigation:**
  * Refactor enemy representation from a singleton table into an **Entity Collection**: `Enemies: { [string]: CombatEntity }`.

### 1.3 Direct Stat Mutation without Base vs. Current Distinction (HIGH)
* **Risk:** Code directly mutates `session.MaxHP`, `session.HP`, `session.Energy`.
* **Impact:**
  * When adding Path of Exile-style affixes (e.g. `+20% Maximum Life`, `Flat +40 Life`, `15% Reduced Armor`), temporary buffs or debuffs cannot be safely recalculated without permanent stat drift or calculation order errors.
* **Mitigation:**
  * Implement an **Entity Stat System** where stats are computed dynamically from `Base + Sum(Modifiers.Flat) * Product(Modifiers.Increased) * Product(Modifiers.More)`.

---

## 2. Concurrency & Multiplayer Race Conditions

### 2.1 Hand Index Shifting Race Condition (CRITICAL)
* **Risk:**
  `PlayCard(player, handIndex)` relies on array indices:
  ```luau
  local card = session.Hand[index]
  table.remove(session.Hand, index)
  ```
* **Impact:**
  * If a player plays two cards quickly, or high network jitter delivers two `PlayCard` packets in the same server frame, the second packet accesses an index that has already shifted.
  * The player plays the wrong card, wastes energy, or crashes with a nil index exception.
* **Mitigation:**
  * Cards in hand must have a unique runtime GUID (`CardInstanceId: string`).
  * `PlayCard` must take `CardInstanceId` rather than array index. The server validates that the specific instance exists in the player's active hand.

### 2.2 Unsynchronized Heartbeat Timers (MEDIUM)
* **Risk:**
  `SessionManager` runs an unthrottled `RunService.Heartbeat` loop with a timer accumulator:
  ```luau
  RunService.Heartbeat:Connect(function(dt: number)
      if currentSession.Phase ~= "PlayerTurn" then return end
      timerAccumulator += dt
      ...
  ```
* **Impact:**
  * Accumulator drift across server lag spikes can cause turn resolution to trigger unexpectedly while players are in the middle of executing card animations.
* **Mitigation:**
  * Track turn start timestamp (`TurnStartTime = os.clock()`) and derive remaining time monotonically (`math.max(0, TURN_DURATION - (os.clock() - TurnStartTime))`).

---

## 3. Security & Exploitation Vulnerabilities

### 3.1 Zero Rate-Limiting on RemoteEvents (HIGH)
* **Risk:**
  None of the 25 RemoteEvents enforce rate-limiting or debounce guards.
* **Impact:**
  * A malicious client running a simple executor script can fire `PlayCard`, `VoteMapNode`, or `SelectClass` thousands of times per second, crashing the Roblox game server for all 4 players.
* **Mitigation:**
  * Centralize RemoteEvent handling behind a **Network Dispatcher** that enforces token-bucket rate-limiting (e.g. max 5 actions/second per player).

### 3.2 Unvalidated Class & Subclass Selection (MEDIUM)
* **Risk:**
  `SelectClassEvent` accepts any class/subclass string matching `ClassData`.
* **Impact:**
  * Players can select locked premium or high-tier meta classes without meeting the unlock criteria stored in `ProfileStore`.
* **Mitigation:**
  * Server cross-checks `ProfileStore.isClassUnlocked(player, classId)` before applying selection.

### 3.3 Dual Map-Select Event Vectors (MEDIUM)
* **Risk:**
  Both `CombatEvents.SelectMapNode` and `GameFlowEvents.VoteMapNode` exist in the code.
* **Impact:**
  * A hacked client can bypass the party vote in `GameCoordinator` by firing `SelectMapNode` directly to `CombatServer`.
* **Mitigation:**
  * Remove `CombatEvents.SelectMapNode` completely. All map progression must pass through the authoritative party coordinator.

---

## 4. Scalability & Extensibility Bottlenecks

### 4.1 Hardcoded Monolithic `if-elseif` Ladders (HIGH)
* **Risk:**
  `RelicManager` and `ClassManager` evaluate mechanics using hardcoded string comparisons:
  ```luau
  if relicId == "Anchor" then ...
  elseif relicId == "Vajra" then ...
  elseif relicId == "Lantern" then ...
  ```
* **Impact:**
  * Scaling to 100+ relics, 50+ enemy types, and 200+ cards will make these files thousands of lines long and impossible to debug or unit-test in isolation.
* **Mitigation:**
  * Adopt a **Behavior-Component Model**: Relics, Passives, and Card Effects register modular handler functions or modifier tables conforming to a standard `CombatEffect` interface.

### 4.2 Inter-Script `_G` Dependency (MEDIUM)
* **Risk:**
  Scripts rely on `_G.RelicManager`, `_G.ClassManager`, and `_G.ProfileStore`.
* **Impact:**
  * Global variables have undefined initialization ordering in Roblox. If `CombatServer` runs before `RelicManager` finishes initializing, `_G.RelicManager` is `nil`, silently bypassing relic triggers.
* **Mitigation:**
  * Convert all server logic to proper Luau `ModuleScripts` required through a deterministic service bootstrap (`init.server.luau`).
