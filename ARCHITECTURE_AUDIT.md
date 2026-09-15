# Architecture Audit: Card Rift: Co-op Dungeon

**Audit Date:** September 2026  
**Auditor:** Lead Systems & Architecture Engineer  
**Scope:** Complete codebase inspection of `spire-game` (`src/shared`, `src/server`, `src/client`, `default.project.json`)  
**Objective:** Evaluate architectural integrity, state authority, multiplayer safety, security exposure, and structural readiness for scaling into a high-depth Co-op Roguelike ARPG/Deckbuilder.

---

## 1. Executive Summary

The existing codebase contains working core foundations for a turn-based deckbuilder: procedural map generation ([`DungeonMap.luau`](file:///c:/Users/owner/Documents/spire-game/src/shared/DungeonMap.luau)), card and relic definitions ([`CardData.luau`](file:///c:/Users/owner/Documents/spire-game/src/shared/CardData.luau), [`RelicData.luau`](file:///c:/Users/owner/Documents/spire-game/src/shared/RelicData.luau)), class data ([`ClassData.luau`](file:///c:/Users/owner/Documents/spire-game/src/shared/ClassData.luau)), DataStore persistence ([`ProfileStore.server.luau`](file:///c:/Users/owner/Documents/spire-game/src/server/ProfileStore.server.luau)), and UI controllers.

However, the server-side architecture suffers from a **critical structural flaw: Triple-State Duplication**. Three independent server scripts—[`CombatServer.server.luau`](file:///c:/Users/owner/Documents/spire-game/src/server/CombatServer.server.luau), [`SessionManager.server.luau`](file:///c:/Users/owner/Documents/spire-game/src/server/SessionManager.server.luau), and [`GameCoordinator.server.luau`](file:///c:/Users/owner/Documents/spire-game/src/server/GameCoordinator.server.luau)—each maintain separate, uncoordinated representations of:
1. **The Player State** (HP, Energy, Shields, Decks, Hands)
2. **The Enemy State** (HP, MaxHP, Intent, Statuses)
3. **The Combat & Turn State** (Turn numbering, Phase resolution, Timers)
4. **The Dungeon/Run State** (Active node, Map progression)

If unaddressed, building complex Path of Exile-style depth (Energy Shield, Armor, Evasion, Block, Resistances, Status Reactions, Gear affixes, Skill trees) on top of this fractured foundation will lead to severe state corruption, desyncs, and unmaintainable technical debt.

---

## 2. File-by-File Responsibility Audit

| File Path | Execution Context | Intended Responsibility | Actual Implementation & Flaws |
|---|---|---|---|
| [`src/shared/CardData.luau`](file:///c:/Users/owner/Documents/spire-game/src/shared/CardData.luau) | Shared | Card definition library & lookup | Clean catalog of 25 cards with basic effect types (`Damage`, `Shield`, `Poison`, `Revive`, `Heal`). Effect interpretation is hardcoded in server scripts rather than driven by an extensible pipeline. |
| [`src/shared/ClassData.luau`](file:///c:/Users/owner/Documents/spire-game/src/shared/ClassData.luau) | Shared | Class & subclass definitions | Well-structured data for 10 classes and 20 subclasses. Contains hardcoded strings for starting decks and passive IDs without programmatic linking to passive logic. |
| [`src/shared/RelicData.luau`](file:///c:/Users/owner/Documents/spire-game/src/shared/RelicData.luau) | Shared | Relic definitions & metadata | Well-structured catalog of 18 relics, rarities, triggers, and values. Relic mechanics are driven by string comparisons (`Id == "Anchor"`) in execution layers. |
| [`src/shared/DungeonMap.luau`](file:///c:/Users/owner/Documents/spire-game/src/shared/DungeonMap.luau) | Shared | 4-Act, 10-Tier map generator & pathfinding | Robust, pure functional procedural graph generator. Deterministic and free of side-effects. |
| [`src/server/CombatServer.server.luau`](file:///c:/Users/owner/Documents/spire-game/src/server/CombatServer.server.luau) | Server (`Script`) | 3D Arena Spawner, Boss Entity, Turn Resolution | **Overloaded.** Acts as an entire solo-combat server while ignoring `SessionManager`'s co-op state. Tracks private `PlayerCombatant` and private singleton `currentBoss`. Connects directly to `PlayCard` and `EndTurn`. |
| [`src/server/SessionManager.server.luau`](file:///c:/Users/owner/Documents/spire-game/src/server/SessionManager.server.luau) | Server (`Script`) | Co-op Session, 45s timer, multiplayer scaling | **Duplicated.** Maintains its own `currentSession.Players` and `currentSession.Enemy`. Tracks ready votes and runs its own `Heartbeat` timer, but client gameplay remote events bypass its `PlayCoopCardEvent`. |
| [`src/server/GameCoordinator.server.luau`](file:///c:/Users/owner/Documents/spire-game/src/server/GameCoordinator.server.luau) | Server (`Script`) | Global run state machine & rewards | **Duplicated.** Tracks run phases (`Lobby` $\rightarrow$ `MapSelect` $\rightarrow$ `ActiveRoom` $\rightarrow$ `Rewards`), party gold, card draft offers, and its own `ActiveRoom.EnemyHP`. Completely isolated from `CombatServer`'s actual battle resolution. |
| [`src/server/ProfileStore.server.luau`](file:///c:/Users/owner/Documents/spire-game/src/server/ProfileStore.server.luau) | Server (`Script`) | Persistent player save data via DataStore | Solid DataStoreService wrapper with retries, autosaving, and fallback schemas. Exposes via `_G.ProfileStore`. |
| [`src/server/RelicManager.server.luau`](file:///c:/Users/owner/Documents/spire-game/src/server/RelicManager.server.luau) | Server (`Script`) | Player relic inventory & combat trigger dispatcher | Stores player relics in `playerInventories`. Dispatches 6 triggers. Uses giant hardcoded `if-elseif` ladders per relic ID instead of composable modifier behaviors. |
| [`src/server/ClassManager.server.luau`](file:///c:/Users/owner/Documents/spire-game/src/server/ClassManager.server.luau) | Server (`Script`) | Class selection, deck injection, gimmick engine | Stores class selections and transient gimmick counters. Contains hardcoded `if-elseif` trees for all 10 classes and subclasses. Directly modifies session tables. |
| [`src/client/UIController.client.luau`](file:///c:/Users/owner/Documents/spire-game/src/client/UIController.client.luau) | Client (`LocalScript`) | Tactical HUD, Map UI, Card Hand, Rewards | Large monolithic UI script (880 lines). Connects to 3 different remote event families simultaneously (`CombatEvents`, `CoopEvents`, `GameFlowEvents`). |
| [`src/client/ClassSelectUI.client.luau`](file:///c:/Users/owner/Documents/spire-game/src/client/ClassSelectUI.client.luau) | Client (`LocalScript`) | Lobby class picker & subclass toggles | Clean interactive modal for class selection. Hides on run start and reappears in Lobby. |
| [`src/client/RelicUI.client.luau`](file:///c:/Users/owner/Documents/spire-game/src/client/RelicUI.client.luau) | Client (`LocalScript`) | Relic bar & dynamic hover tooltips | High-quality HUD ribbon with hover tooltips and trigger pulse bounce tweens. |

---

## 3. Detailed Architectural Breakdown

### 3.1 Authoritative Game-State Locations (The Three-Headed Monster)
State authority is currently fragmented across three independent server scripts that communicate inconsistently:

```
[GameCoordinator]                  [SessionManager]                  [CombatServer]
- coordinator.DungeonRun           - currentSession.TurnNumber       - session.DungeonRun (per player!)
- coordinator.Phase                - currentSession.Phase            - session.TurnNumber
- coordinator.ActiveRoom.EnemyHP   - currentSession.Enemy.HP         - currentBoss.HP (Singleton)
- coordinator.Players[uid].Deck    - currentSession.Players[uid].Deck- activeSessions[p].Deck
- coordinator.Players[uid].Gold    - currentSession.Players[uid].HP  - activeSessions[p].HP
```

1. **Player State**:
   * Stored in `CombatServer.activeSessions[player]` (`PlayerCombatant`)
   * Stored in `SessionManager.currentSession.Players[userId]` (`CoopPlayerState`)
   * Stored in `GameCoordinator.coordinator.Players[userId]` (`PlayerRunData`)
   * Stored in `RelicManager.playerInventories[userId]` & `combatStates[userId]`
   * Stored in `ClassManager.playerSelections[userId]` & `gimmickStates[userId]`
   * Stored in `ProfileStore.activeProfiles[player]`
2. **Combat State**:
   * In `CombatServer`: `session.InCombat`, `session.TurnNumber`, `session.Hand`, `session.DiscardPile`.
   * In `SessionManager`: `currentSession.Phase`, `currentSession.TurnNumber`, `currentSession.TurnTimer`, `pState.IsReady`, `pState.IsDowned`.
3. **Enemy State**:
   * In `CombatServer`: `currentBoss: BossCombatant` (Single global table: `Name`, `HP`, `MaxHP`, `Shield`, `Poison`, `AttackPower`, `Model`, `OverheadGui`).
   * In `SessionManager`: `currentSession.Enemy: CoopEnemyState` (`Name`, `BaseHP`, `MaxHP`, `HP`, `Shield`, `Poison`, `BaseAttack`, `AttackPower`, `Intent`).
   * In `GameCoordinator`: `coordinator.ActiveRoom` (`EnemyName`, `EnemyMaxHP`, `EnemyHP`, `EnemyAttack`).
4. **Dungeon / Run State**:
   * In `GameCoordinator`: `coordinator.DungeonRun` (Shared party run).
   * In `CombatServer`: `activeSessions[player].DungeonRun` (Private run instantiated independently per player upon joining).

---

### 3.2 Where Damage is Calculated
Damage calculation is duplicated in multiple locations with divergent logic:
1. **[`CombatServer.server.luau:490-496`](file:///c:/Users/owner/Documents/spire-game/src/server/CombatServer.server.luau#L490-L496)**:
   ```luau
   local function applyDamage(targetName: string, target: { HP: number, Shield: number }, amount: number): (number, number)
       local absorbed = math.min(target.Shield, amount)
       target.Shield -= absorbed
       local rem = amount - absorbed
       target.HP = math.max(0, target.HP - rem)
       return rem, absorbed
   end
   ```
2. **[`SessionManager.server.luau:303-309`](file:///c:/Users/owner/Documents/spire-game/src/server/SessionManager.server.luau#L303-L309)**:
   ```luau
   local function applyDamageToCombatant(target: { HP: number, Shield: number }, amount: number): (number, number)
       local absorbed = math.min(target.Shield, amount)
       target.Shield -= absorbed
       local rem = amount - absorbed
       target.HP = math.max(0, target.HP - rem)
       return rem, absorbed
   end
   ```
3. **[`ClassManager.server.luau:188-285`](file:///c:/Users/owner/Documents/spire-game/src/server/ClassManager.server.luau#L188-L285)**:
   * Warlord Rage: calculates missing HP and injects `BonusDamage`.
   * Shadowblade Combo: injects `(ComboCount - 1) * 2` bonus damage.
   * Blood Priest: injects `+3` damage on sacrifice.
   * Gambler: applies `rng:NextNumber(0.5, 1.75)` variance and `+8` on coin flip.
4. **[`RelicManager.server.luau:190-250`](file:///c:/Users/owner/Documents/spire-game/src/server/RelicManager.server.luau#L190-L250)**:
   * Vajra: `+2` flat attack damage.
   * Akabeko: `+8` first attack damage.
   * Bronze Scales: `3` counter thorns damage.

---

### 3.3 Where Card Effects are Interpreted
1. **[`CombatServer.server.luau:499-548`](file:///c:/Users/owner/Documents/spire-game/src/server/CombatServer.server.luau#L499-L548)**:
   * Loops through `card.Effects`.
   * Evaluates `effect.Type == "Damage"` $\rightarrow$ calls `applyDamage` against `currentBoss`.
   * Evaluates `effect.Type == "Shield"` $\rightarrow$ adds to `session.Shield`.
   * Evaluates `effect.Type == "Poison"` $\rightarrow$ adds to `currentBoss.Poison`.
   * **Defect**: Does NOT interpret `"Revive"` or `"Heal"` effects! Cards like `First Aid` do nothing when played in `CombatServer`.
2. **[`SessionManager.server.luau:539-559`](file:///c:/Users/owner/Documents/spire-game/src/server/SessionManager.server.luau#L539-L559)**:
   * Loops through `card.Effects`.
   * Evaluates `"Damage"`, `"Shield"`, `"Poison"`, `"Revive"`, `"Heal"`.
   * **Defect**: `SessionManager`'s handler is dead code because the client currently fires `PlayCard` (pointing to `CombatServer`) instead of `PlayCoopCard`.

---

### 3.4 Where Player Stats are Modified
* **Health / HP**:
  * Decremented in `CombatServer.handleBossAttack`
  * Decremented in `SessionManager.resolveEnemyTurnPhase`
  * Decremented in `ClassManager.processGimmickOnCardPlay` (Blood Priest HP sacrifice)
  * Incremented in `CombatServer.startRoomEncounter` (Campfire 30% heal)
  * Incremented in `SessionManager.revivePlayer` (25% max HP)
  * Incremented in `SessionManager.PlayCoopCardEvent` (`First Aid` heal)
  * Incremented in `RelicManager.triggerEvent` (Blood Vial +4, Burning Blood +6, Meat on the Bone +12)
* **Shield**:
  * Modified in `CombatServer.executeEffects` (`Defend`, `ShieldSlam`)
  * Modified in `CombatServer.startRoomEncounter` (reset to 0)
  * Modified in `CombatServer.EndTurnEvent` (reset to 0 or capped at 15 via Calipers)
  * Modified in `RelicManager.triggerEvent` (Anchor +5, Orichalcum +6)
  * Modified in `ClassManager.processGimmickOnCardPlay` (Shadowblade combo shield, Blood Priest Zealot +10)
  * Modified in `ClassManager.processGimmickOnTurnEnd` (Cryomancer, Artificer)
* **Energy**:
  * Decremented in `CombatServer.PlayCardEvent` (`session.Energy -= card.Cost`)
  * Replenished in `CombatServer.EndTurnEvent` (`session.Energy = session.MaxEnergy`)
  * Modified in `RelicManager.triggerEvent` (Lantern +1 on Turn 1, Coffee Dripper +1 every turn, Sundial +2, Gremlin Horn +1)
  * Modified in `ClassManager.processGimmickOnCardPlay` (Gambler Card Sharp refund)

---

### 3.5 RemoteEvents & Networking Catalog

| RemoteEvent Name | Folder in ReplicatedStorage | Direction | Payload Parameters | Handled By |
|---|---|:---:|---|---|
| `StartRun` | `GameFlowEvents` | Client $\rightarrow$ Server | `(player: Player)` | `GameCoordinator` |
| `VoteMapNode` | `GameFlowEvents` | Client $\rightarrow$ Server | `(player: Player, targetNodeId: string)` | `GameCoordinator` |
| `ClaimRewardCard` | `GameFlowEvents` | Client $\rightarrow$ Server | `(player: Player, cardId: string)` | `GameCoordinator` |
| `ContinueFromRewards` | `GameFlowEvents` | Client $\rightarrow$ Server | `(player: Player)` | `GameCoordinator` |
| `CampfireChoice` | `GameFlowEvents` | Client $\rightarrow$ Server | `(player: Player, choice: "Rest" \| "Smith")` | `GameCoordinator` |
| `FlowStateUpdate` | `GameFlowEvents` | Server $\rightarrow$ Client | `(payload: table)` | `UIController`, `ClassSelectUI` |
| `FlowAnnouncement` | `GameFlowEvents` | Server $\rightarrow$ Client | `(payload: table)` | `UIController` |
| `PlayerVoteReady` | `CoopEvents` | Client $\rightarrow$ Server | `(player: Player)` | `SessionManager` |
| `RescueTeammate` | `CoopEvents` | Client $\rightarrow$ Server | `(player: Player, targetUserId: number)` | `SessionManager` |
| `PlayCoopCard` | `CoopEvents` | Client $\rightarrow$ Server | `(player: Player, handIndex: number, targetUserId: number?)` | `SessionManager` *(Currently Orphaned)* |
| `CoopStateUpdate` | `CoopEvents` | Server $\rightarrow$ Client | `(payload: table)` | `UIController` |
| `CoopAnnouncement` | `CoopEvents` | Server $\rightarrow$ Client | `(payload: table)` | `UIController` |
| `PlayCard` | `CombatEvents` | Client $\rightarrow$ Server | `(player: Player, handIndex: number)` | `CombatServer` |
| `EndTurn` | `CombatEvents` | Client $\rightarrow$ Server | `(player: Player)` | `CombatServer` |
| `SelectMapNode` | `CombatEvents` | Client $\rightarrow$ Server | `(player: Player, targetNodeId: string)` | `CombatServer` *(Conflicting with VoteMapNode)* |
| `StateUpdate` | `CombatEvents` | Server $\rightarrow$ Client | `(payload: table)` | `UIController` |
| `CombatAction` | `CombatEvents` | Server $\rightarrow$ Client | `(payload: table)` | `UIController` |
| `MapUpdate` | `CombatEvents` | Server $\rightarrow$ Client | `(payload: table)` | `UIController` |
| `SelectClass` | `ClassEvents` | Client $\rightarrow$ Server | `(player: Player, payload: { ClassId: string, SubclassId: string })` | `ClassManager` |
| `ClassSelectionUpdate` | `ClassEvents` | Server $\rightarrow$ Client | `(payload: table)` | `ClassSelectUI` |
| `GimmickFeedback` | `ClassEvents` | Server $\rightarrow$ Client | `(payload: table)` | `ClassSelectUI` |
| `RequestClassSelection` | `ClassEvents` | Client $\rightarrow$ Server | `(player: Player)` | `ClassManager` |
| `RelicInventoryUpdate` | `RelicEvents` | Server $\rightarrow$ Client | `(inventory: { Relic })` | `RelicUI` |
| `RelicTriggerNotification` | `RelicEvents` | Server $\rightarrow$ Client | `(payload: table)` | `RelicUI` |
| `RequestRelicInventory` | `RelicEvents` | Client $\rightarrow$ Server | `(player: Player)` | `RelicManager` |

**Total RemoteEvents:** 25  
**RemoteFunctions:** 0 (All communications are fire-and-forget async, creating ordering hazards).

---

## 4. Security & Exploitation Vulnerabilities

1. **Unbounded Hand Indexing & Card Duplication Exploit**:
   `PlayCardEvent` takes a raw integer `handIndex`. A malicious client can fire `PlayCardEvent` dozens of times in a single frame. Because table modifications (`table.remove(session.Hand, index)`) and effect execution yield asynchronously during animations, rapid firings will cause index-shifting race conditions, playing cards that have already been discarded or executing effects multiple times.
2. **Missing Rate Limiting & Cooldown Validation**:
   None of the 25 RemoteEvents enforce rate-limiting. A client can flood `StartRun`, `VoteMapNode`, or `SelectClass` to cause severe server frame drops or trigger repeated DataStore requests.
3. **Unchecked Class & Subclass Selection**:
   `SelectClassEvent` blindly accepts any string matching `ClassData`. There is no check against `ProfileStore` to verify whether the player has actually unlocked non-default classes (e.g. Rogue, Mage, Necrobinder).
4. **Client-Triggered Map Traversal Desynchronization**:
   Both `CombatEvents.SelectMapNode` and `GameFlowEvents.VoteMapNode` accept node IDs from clients. An attacker firing `SelectMapNode` will force `CombatServer` to jump to an arbitrary node in their private map, leaving other co-op players stranded in the previous room.

---

## 5. Architectural Bottlenecks & Scaling Blockers

1. **Monolithic Singleton Enemy in CombatServer**:
   `currentBoss: BossCombatant` is a single module-level variable. It cannot support multi-enemy combats (e.g. 3 Gremlins, 1 Boss + 2 Minions, summons).
2. **Hardcoded Class & Relic Logic Ladders**:
   Adding 50 new relics or 10 new classes currently requires editing 300-line `if-elseif` blocks inside `RelicManager` and `ClassManager`.
3. **No Separation Between Base Stats and Modified Stats**:
   Current code directly mutates `session.MaxHP` and `session.HP`. When we add Path of Exile-style mechanics (e.g., +15% Increased Maximum Life from a tree, +50 Flat Life from a Chestplate, -10% Life from a Curse), calculating the correct current stat without an entity-stat container will cause irreversible stat drift.
4. **Binary Health Model**:
   There is currently only `HP` and `Shield`. The vision requires:
   * `Life` (Pool)
   * `Energy Shield` (Recharging pool with bypass rules)
   * `Mana` (Skill resource)
   * `Energy` (Card play resource)
   * `Armor` (Damage reduction mitigation)
   * `Evasion` (Entropy-based miss chance)
   * `Block` (Shield/weapon percentage mitigation)
   * `Parry / Deflect` (Timing/chance mitigation)
   * `Resistances` (Physical, Fire, Cold, Lightning, Chaos/Void)

---

## 6. Audit Conclusion

The game has functional gameplay logic, but the server layer is fractured across 3 competing coordinators. **Before adding any ARPG stats, equipment, skill trees, or ailments, the server architecture must be consolidated into a unified Single Source of Truth.**
