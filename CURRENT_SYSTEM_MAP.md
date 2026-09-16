# Current System Map: Card Rift: Co-op Dungeon

**Current State**: Phase 4.1 Complete  
**Architecture**: Layered Service-Oriented Server, Centralized Network Gateway, Strict State Separation (`--!strict`).

---

## 1. System Architecture & Dependency Graph

```mermaid
graph TD
    subgraph Client ["Client Layer (StarterPlayerScripts.Client)"]
        UIController["UIController.client.luau<br><i>Master HUD, Hand & Combat</i>"]
        ClassSelectUI["ClassSelectUI.client.luau<br><i>Lobby Hero & Subclass Selector</i>"]
        RelicUI["RelicUI.client.luau<br><i>HUD Relic Bar & Tooltips</i>"]
    end

    subgraph Network ["Centralized Network Gateway (ReplicatedStorage.GameNetwork)"]
        NetSvc["NetworkService.luau<br><i>Token-Bucket Rate Limiter (4 Categories)</i>"]
        Remotes["25 RemoteEvents<br>(Combat, Map, Class, General)"]
    end

    subgraph ServerCore ["Authoritative Core Services (ServerScriptService.Server.services)"]
        RunMgr["RunManager.luau<br><i>RunState SSOT & Room Lifecycle</i>"]
        CombatSvc["CombatService.luau<br><i>CombatState SSOT & Turn Engine</i>"]
    end

    subgraph ServerRPG ["RPG & Progression Services (Phase 3 & 4)"]
        PersistenceSvc["PersistenceService.luau<br><i>DataStore (v1), Fail-Closed & UpdateAsync</i>"]
        CardColSvc["CardCollectionService.luau<br><i>Permanent Card Collection</i>"]
        DeckSvc["DeckService.luau<br><i>Saved Decks & Slot Entitlement</i>"]
        EquipSvc["EquipmentService.luau<br><i>Gear Slots & Invariants</i>"]
        StatRes["StatResolver.luau<br><i>Deterministic 9-Stat Resolution</i>"]
        SkillSvc["SkillService.luau<br><i>Active Skills & Cooldowns</i>"]
        PassiveSvc["PassiveService.luau<br><i>Passive DAG Trees & Points</i>"]
    end

    subgraph ServerCombat ["Combat Pipeline & Resolution Engine"]
        CardSvc["CardService.luau<br><i>Runtime CardInstance GUIDs</i>"]
        ClassSvc["ClassService.luau<br><i>10 Classes, Gimmicks & Starter Decks</i>"]
        RelicSvc["RelicService.luau<br><i>18 Relics & Passive Hooks</i>"]
        DungeonSvc["DungeonService.luau<br><i>Procedural 4-Act Spire Graph</i>"]
        TargetRes["TargetResolver.luau<br><i>Target Entity Validator</i>"]
        ModRes["ModifierResolver.luau<br><i>Modifier Engine: (Base+Add)*Mult</i>"]
        DmgPipe["DamagePipeline.luau<br><i>Shields, Direct HP & Downed</i>"]
        StatusSvc["StatusService.luau<br><i>Poison, Ignite, Chill, Bleed</i>"]
        EffectRes["EffectResolver.luau<br><i>Generic Effect Dispatcher</i>"]
        ArenaVis["ArenaVisualizer.luau<br><i>Reactive 3D Workspace Models</i>"]
    end

    %% Client / Network flow
    Client -->|Intent Invocations| NetSvc
    NetSvc --> Remotes
    Remotes --> ServerCore
    Remotes --> ServerRPG
    Remotes --> ServerCombat

    %% Core orchestration
    RunMgr --> DungeonSvc
    RunMgr --> CombatSvc
    CombatSvc --> CardSvc
    CombatSvc --> TargetRes
    CombatSvc --> DmgPipe
    CombatSvc --> StatusSvc
    CombatSvc --> EffectRes
    CombatSvc --> ArenaVis

    %% RPG integration
    CombatSvc --> StatRes
    CombatSvc --> SkillSvc
    EquipSvc --> StatRes
    PassiveSvc --> StatRes
    DeckSvc --> CardColSvc
    DeckSvc --> PersistenceSvc
    ClassSvc --> DeckSvc
```

---

## 2. Authoritative State Partitioning

The architecture enforces strict state boundaries between persistent account meta-data, run-scoped expedition state, and combat encounter state:

| State Domain | Owner Module | Storage Lifetime | Contents |
| :--- | :--- | :--- | :--- |
| **Account Profile** | `PersistenceService.luau` | Cross-session (Roblox DataStore `ProfileVersion = 1`) | `AetherShards`, `UnlockedClasses`, `CardCollection`, `Decks`, `ActiveDeckId`, `DeckSlotEntitlement`, `UnlockedSkills`. |
| **Permanent Collection** | `CardCollectionService.luau` | Account lifecycle | Dictionary of `{ [cardDefId]: number }` tracking permanent ownership counts. Never stores runtime instances. |
| **Saved Decks** | `DeckService.luau` | Account lifecycle | Dictionary of `SavedDeck`s referencing card definition IDs and counts. Server-generated GUIDs. |
| **Run State** | `RunManager.luau` | Expedition duration (Lobby to Victory/Defeat) | `PartyMembers: { [number]: PlayerState }`, `DungeonRun`, `CurrentAct`, `CurrentTier`, `ActiveNodeId`, `RunPhase`. |
| **Combat State** | `CombatService.luau` | Single room encounter | `Enemies: { [string]: EnemyState }`, `ActiveCombatants`, `TurnNumber`, `TurnTimer`, `TurnHistoryLog`, `Phase`. |
| **Runtime Cards** | `CardService.luau` | Expedition duration | `CardInstance` objects carrying unique runtime GUIDs in player `Deck`, `Hand`, `DiscardPile`, `ExhaustPile`. |
| **Visual Scene** | `ArenaVisualizer.luau` | Room encounter (Reactive only) | Workspace 3D platform, enemy `Model` instances, `BillboardGui`s, animations. Zero gameplay authority. |

---

## 3. Network Remote Catalog Summary

All network communication flows through `ReplicatedStorage.GameNetwork` managed by `NetworkService.luau`:

### Category Rate Limiters:
- **`Combat` (6 tokens max, 3.0/s refill)**: `PlayCard`, `PlayerVoteReady`, `RescueTeammate`, `UseSkill`.
- **`Map` (3 tokens max, 1.0/s refill)**: `VoteMapNode`.
- **`Class` (3 tokens max, 1.0/s refill)**: `SelectClass`.
- **`General` (4 tokens max, 2.0/s refill)**: `StartRun`, `ClaimRewardCard`, `ContinueFromRewards`, `RequestStateSync`, `EquipEquipment`, `UnequipEquipment`, `EquipSkill`, `UnequipSkill`, `UnlockPassive`, `CreateDeck`, `RenameDeck`, `DeleteDeck`, `SaveDeck`, `DuplicateDeck`, `SelectActiveDeck`, `RequestDecks`, `RequestCardCollection`.

### Core Security Principles:
1. **Server Injected Sender**: Sender identity is strictly derived from Roblox's authoritative `player.UserId`.
2. **Instance GUIDs**: Cards and equipment are referenced by runtime instance GUIDs validated against server state.
3. **Zero Minting Pathways**: Client cannot create persistent items, forge slot capacities, or authoritatively unlock skills.
4. **Fail-Closed Protection**: DataStore failures never write fallback starter data over existing player profiles.

