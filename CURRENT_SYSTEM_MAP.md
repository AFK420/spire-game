# Current System Map: Card Rift: Co-op Dungeon

This document outlines the operational structure, dependency graphs, state schemas, and network pathways of the active codebase.

---

## 1. System Dependency & Architecture Diagram

```mermaid
graph TD
    subgraph Client ["Client (StarterPlayerScripts.Client)"]
        UIController["UIController.client.luau<br><i>Master HUD & Views</i>"]
        ClassSelectUI["ClassSelectUI.client.luau<br><i>Lobby Hero Selector</i>"]
        RelicUI["RelicUI.client.luau<br><i>HUD Relic Bar & Tooltips</i>"]
    end

    subgraph Network ["Network (ReplicatedStorage RemoteEvents)"]
        CombatEvents["CombatEvents<br>(PlayCard, EndTurn, StateUpdate...)"]
        CoopEvents["CoopEvents<br>(PlayerVoteReady, RescueTeammate...)"]
        GameFlowEvents["GameFlowEvents<br>(StartRun, VoteMapNode, Rewards...)"]
        RelicEvents["RelicEvents<br>(RelicInventoryUpdate, Trigger...)"]
        ClassEvents["ClassEvents<br>(SelectClass, SelectionUpdate...)"]
    end

    subgraph Server ["Server (ServerScriptService.Server)"]
        GameCoord["GameCoordinator.server.luau<br><i>Run State Machine & Nodes</i>"]
        CombatSrv["CombatServer.server.luau<br><i>3D Arena & Combat Loop</i>"]
        SessionMgr["SessionManager.server.luau<br><i>45s Co-op Turn Resolution</i>"]
        ClassMgr["ClassManager.server.luau<br><i>Decks & Gimmick Engine</i>"]
        RelicMgr["RelicManager.server.luau<br><i>Relic Inventory & Triggers</i>"]
        ProfileStore["ProfileStore.server.luau<br><i>DataStore Persistence</i>"]
    end

    subgraph Shared ["Shared (ReplicatedStorage.Shared)"]
        CardData["CardData.luau<br><i>Card Library (25 Cards)</i>"]
        ClassData["ClassData.luau<br><i>10 Classes, 20 Subclasses</i>"]
        RelicData["RelicData.luau<br><i>18 Relics, Rarity, Triggers</i>"]
        DungeonMap["DungeonMap.luau<br><i>4 Acts, 10 Tiers Tree</i>"]
    end

    %% Client to Network
    UIController --> CombatEvents
    UIController --> CoopEvents
    UIController --> GameFlowEvents
    ClassSelectUI --> ClassEvents
    RelicUI --> RelicEvents

    %% Network to Server
    CombatEvents --> CombatSrv
    CoopEvents --> SessionMgr
    GameFlowEvents --> GameCoord
    RelicEvents --> RelicMgr
    ClassEvents --> ClassMgr

    %% Cross-Server dependencies
    CombatSrv -.->|_G.RelicManager| RelicMgr
    CombatSrv -.->|_G.ClassManager| ClassMgr
    GameCoord -.->|_G.ProfileStore| ProfileStore
    GameCoord -.->|_G.RelicManager| RelicMgr

    %% Shared requirements
    CombatSrv --> CardData
    CombatSrv --> DungeonMap
    SessionMgr --> CardData
    GameCoord --> CardData
    GameCoord --> DungeonMap
    GameCoord --> RelicData
    ClassMgr --> ClassData
    ClassMgr --> CardData
    RelicMgr --> RelicData
    UIController --> CardData
    UIController --> DungeonMap
    ClassSelectUI --> ClassData
    RelicUI --> RelicData
```

---

## 2. Existing State Schemas Comparison

The table below illustrates the fragmentation across the 3 main server systems:

### 2.1 Player State Representations

| Attribute | `CombatServer.PlayerCombatant` | `SessionManager.CoopPlayerState` | `GameCoordinator.PlayerRunData` | `ProfileStore.PlayerProfile` |
|---|---|---|---|---|
| **Key** | `Player` | `number` (UserId) | `number` (UserId) | `Player` |
| **Max HP** | `number` | `number` | *Missing* | *Missing* |
| **Current HP** | `number` | `number` | *Missing* | *Missing* |
| **Shield** | `number` | `number` | *Missing* | *Missing* |
| **Energy / Max**| `number` / `number` | `number` / `number` | *Missing* | *Missing* |
| **Poison** | `number` | *Missing* (on enemy only) | *Missing* | *Missing* |
| **Deck** | `{ Card }` | `{ Card }` | `{ Card }` | *Missing* |
| **Hand** | `{ Card }` | `{ Card }` | *Missing* | *Missing* |
| **Discard Pile**| `{ Card }` | `{ Card }` | *Missing* | *Missing* |
| **Turn Status** | `TurnNumber: number` | `IsReady: boolean`, `IsDowned: boolean` | `VotedNodeId: string?` | *Missing* |
| **Gold** | *Missing* | *Missing* | `Gold: number` | *Missing* |
| **Run Instance**| `DungeonRun: table` | *Missing* | *Managed at root* | *Missing* |
| **Meta-Currency**| *Missing* | *Missing* | *Missing* | `AetherShards: number` |
| **Victories** | *Missing* | *Missing* | *Missing* | `TotalVictories: number` |

---

### 2.2 Enemy State Representations

| Attribute | `CombatServer.BossCombatant` | `SessionManager.CoopEnemyState` | `GameCoordinator.ActiveRoomState` |
|---|---|---|---|
| **Storage** | Module-level singleton (`currentBoss`) | Session table (`currentSession.Enemy`) | Root coordinator (`coordinator.ActiveRoom`) |
| **Name** | `string` | `string` | `EnemyName: string?` |
| **Base HP** | *Missing* | `BaseHP: number` | *Missing* |
| **Max HP** | `number` | `MaxHP: number` (scaled) | `EnemyMaxHP: number?` |
| **Current HP** | `number` | `HP: number` | `EnemyHP: number?` |
| **Shield** | `number` | `number` | *Missing* |
| **Poison** | `number` | `number` | *Missing* |
| **Attack Power**| `number` | `AttackPower: number` | `EnemyAttack: number?` |
| **Intent** | Parsed in billboard string | `Intent: string` | *Missing* |
| **3D Model** | `Model?`, `BillboardGui?` | *Missing* | *Missing* |

---

### 2.3 Run & Session State Representations

| Attribute | `GameCoordinator.RunCoordinatorState` | `SessionManager.CoopSession` | `CombatServer` (Inline) |
|---|---|---|---|
| **Phase / State** | `"Lobby"` \| `"MapSelect"` \| `"ActiveRoom"` \| `"Rewards"` \| `"RunVictory"` \| `"RunDefeat"` | `"PlayerTurn"` \| `"EnemyResolution"` \| `"Victory"` \| `"Defeat"` | `session.InCombat: boolean` |
| **Dungeon Tree** | `DungeonRun: DungeonMap.DungeonRun?` | *Missing* | `session.DungeonRun` (duplicated per player) |
| **Turn Timer** | *Missing* | `TurnTimer: 45` | *Missing* (unlimited turn time) |
| **Ready Voting** | *Missing* | `areAllActivePlayersReady()` | *Missing* (solo-turn resolution) |
| **Room Controller**| Dynamically matches node type | Always assumes boss combat | Hardcoded 3D room types |
| **Reward Drafting**| 3 cards generated from pool | *Missing* | *Missing* |

---

## 3. Network Traffic & Control Flow

### Current Gameplay Sequence (Flow Divergence)

```mermaid
sequenceDiagram
    autonumber
    actor Player as Client (UIController)
    participant GC as GameCoordinator
    participant SM as SessionManager
    participant CS as CombatServer

    Note over Player, GC: 1. Lobby Phase
    Player->>GC: FireServer: StartRun
    GC->>GC: DungeonMap.generateRun()
    GC-->>Player: FireAllClients: FlowStateUpdate("MapSelect")

    Note over Player, GC: 2. Map Selection
    Player->>GC: FireServer: VoteMapNode(targetNodeId)
    GC->>GC: Advance Map & Load Room
    GC-->>Player: FireAllClients: FlowStateUpdate("ActiveRoom")

    Note over Player, CS: 3. Combat Disconnect!
    Note over SM: SessionManager runs its own Heartbeat & timer in background!
    Player->>CS: FireServer: PlayCard(handIndex)
    CS->>CS: Modify private activeSessions[p] & currentBoss
    CS-->>Player: FireClient: StateUpdate / CombatAction

    Note over Player, SM: 4. Ready Vote Divergence!
    Player->>SM: FireServer: PlayerVoteReady()
    SM->>SM: All ready -> resolveEnemyTurnPhase() on currentSession.Enemy!
    Note over CS, SM: CS.currentBoss and SM.currentSession.Enemy are NOT synced!

    Note over Player, CS: 5. End Turn Mismatch!
    Player->>CS: FireServer: EndTurn()
    CS->>CS: Triggers handleBossAttack on private currentBoss!
```

### Critical Flow Takeaway:
* `GameCoordinator` changes states, but `CombatServer` handles live card attacks, while `SessionManager` counts down a turn timer and runs an independent resolution loop.
* The client receives conflicting `StateUpdateEvent` (from `CombatServer`) and `CoopStateUpdateEvent` (from `SessionManager`).
