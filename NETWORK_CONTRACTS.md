# CARD RIFT: NETWORK CONTRACTS & SECURITY SPECIFICATION

**Location**: `ReplicatedStorage.GameNetwork`  
**Gateway Manager**: [`src/server/services/NetworkService.luau`](src/server/services/NetworkService.luau)  
**Security Architecture**: Strict Server-Authoritative with Token-Bucket Rate Limiting  

---

## 1. Gateway Overview

All remote network traffic is centralized under the `ReplicatedStorage.GameNetwork` folder. Client scripts are prohibited from communicating with arbitrary folders or legacy namespaces (`CombatEvents`, `CoopEvents`, `GameFlowEvents`, `ClassEvents`, `RelicEvents`).

### Core Security Guarantees:
1. **Zero Client Authority**: The client never dictates health damage, card draws, gold balances, or enemy status changes. The client only sends *intentions* (e.g. "Play card with ID X on target Y").
2. **Instance GUID Validation**: Cards are referenced solely by unique `CardInstanceId`s. The server verifies that the specified card exists in the player's current `Hand` table before applying effects.
3. **Phase & Resource Enforcement**: Actions are rejected immediately if the player does not possess sufficient energy, is in a downed state, or acts outside the allowed phase (`PlayerPhase`, `MapSelect`, `Rewards`).
4. **Token-Bucket Rate Limiting**: Every client is monitored per category. Flooding or spamming results in immediate drop and warning logs.

---

## 2. Rate Limiting Categories & Thresholds

Each category operates an independent token bucket per connected player:

| Category | Max Tokens (Burst) | Refill Rate (Tokens/sec) | Covered Events |
| :--- | :---: | :---: | :--- |
| **Combat** | 6 | 3.0 | `PlayCard`, `PlayerVoteReady`, `RescueTeammate` |
| **Map** | 3 | 1.0 | `VoteMapNode` |
| **Class** | 3 | 1.0 | `SelectClass` |
| **General** | 4 | 2.0 | `StartRun`, `ClaimRewardCard`, `ContinueFromRewards`, `RequestStateSync` |

---

## 3. Network Contracts Catalog

### 3.1 Client $\to$ Server (Action Invocations)

#### 1. `StartRun`
- **Category**: `General`
- **Trigger**: Player clicks "START EXPEDITION" in the Lobby.
- **Payload**: None.
- **Server Action**: If currently in `Lobby`, generates a new procedural `DungeonRun`, initializes party states, and transitions to `MapSelect`.

#### 2. `SelectClass`
- **Category**: `Class`
- **Trigger**: Player selects a hero class and subclass in the lobby.
- **Payload**:
  ```luau
  classId: string, subclassId: string
  -- Alternatively accepted as: { ClassId: string, SubclassId: string }
  ```
- **Server Validation**: Verifies that `classId` and `subclassId` exist in `ClassData` and that the player has unlocked the class in their `PersistenceService` profile.

#### 3. `VoteMapNode`
- **Category**: `Map`
- **Trigger**: Player clicks a reachable node on the Dungeon Map screen.
- **Payload**:
  ```luau
  targetNodeId: string -- e.g. "Act1_T2_L1"
  ```
- **Server Validation**: Verifies that the run is in `MapSelect` phase and `targetNodeId` is present in `currentRun.AvailableNodeIds`. Reaches majority or unanimous consensus to trigger `travelToNode()`.

#### 4. `PlayCard`
- **Category**: `Combat`
- **Trigger**: Player clicks or drags a card from hand in combat.
- **Payload**:
  ```luau
  cardInstanceId: string, targetEnemyId: string?
  ```
- **Server Validation**:
  - Verifies combat is active and in `PlayerPhase`.
  - Verifies player is not downed.
  - Verifies `cardInstanceId` exists in `playerState.Hand[cardInstanceId]`.
  - Verifies target enemy exists in `combatState.Enemies` and has $\text{HP} > 0$.
  - Verifies energy cost (or evaluates Blood Priest HP sacrifice).
  - Removes card from hand to discard pile, deducts energy, and applies effects.

#### 5. `PlayerVoteReady`
- **Category**: `Combat`
- **Trigger**: Player clicks "VOTE READY" during their combat turn.
- **Payload**: None.
- **Server Action**: Toggles `playerState.IsReady`. If all active non-downed players are ready, immediately ends `PlayerPhase` and triggers `resolveTurn()`.

#### 6. `RescueTeammate`
- **Category**: `Combat`
- **Trigger**: Living player clicks the rescue button on a downed teammate.
- **Payload**:
  ```luau
  targetUserId: number
  ```
- **Server Validation**:
  - Rescuer must not be downed.
  - Target must be downed (`targetPlayerState.IsDowned == true`).
  - Rescuer must have at least 2 Energy.
  - Deducts 2 Energy from rescuer; revives target with $25\%$ of Max HP.

#### 7. `ClaimRewardCard`
- **Category**: `General`
- **Trigger**: Player selects 1 of the 3 offered draft cards on the Rewards screen.
- **Payload**:
  ```luau
  cardDefId: string -- Definition ID, e.g. "HeavyBlow"
  ```
- **Server Validation**:
  - Verifies run is in `Rewards` phase.
  - Verifies player has not already claimed a card reward for this room.
  - Verifies `cardDefId` was among the player's 3 offered cards.
  - Instantiates `CardInstance` into player's deck and marks reward claimed.

#### 8. `ContinueFromRewards`
- **Category**: `General`
- **Trigger**: Player clicks "CONTINUE" after claiming or skipping rewards.
- **Payload**: None.
- **Server Action**: Updates available nodes for the next tier and transitions run phase back to `MapSelect`.

#### 9. `RequestStateSync`
- **Category**: `General`
- **Trigger**: Client joins or finishes local UI load.
- **Payload**: None.
- **Server Action**: Fires fresh `RunSnapshot` and `CombatSnapshot` directly to the requesting client.

---

### 3.2 Server $\to$ Client (State Projections & Feedback)

#### 1. `RunStateUpdate`
- **Target**: Broadcast (`FireAllClients`) or Targeted (`FireClient`).
- **Payload**:
  ```luau
  snapshot: StateTypes.RunSnapshot
  ```
- **Client Handling**: Updates current view (Lobby, MapSelect, ActiveRoom, Rewards), updates available node tree on the map, and displays draft choices.

#### 2. `CombatStateUpdate`
- **Target**: Targeted (`FireClient` per player).
- **Payload**:
  ```luau
  snapshot: StateTypes.CombatSnapshot
  ```
- **Client Handling**: Renders multi-enemy indicators, active player hand (with `CardInstanceId`), teammate statuses, and monotonic countdown timer.

#### 3. `CombatEventLogged`
- **Target**: Broadcast (`FireAllClients`).
- **Payload**:
  ```luau
  event: StateTypes.CombatEvent
  ```
- **Client Handling**: Spawns floating damage/shield numbers and appends to combat log.

#### 4. `Announcement`
- **Target**: Broadcast (`FireAllClients`).
- **Payload**:
  ```luau
  {
      Title: string,
      Message: string,
      Color: Color3?,
  }
  ```
- **Client Handling**: Displays animated top banner banner notification.

#### 5. `RelicNotification`
- **Target**: Targeted (`FireClient`).
- **Payload**:
  ```luau
  {
      RelicId: string,
      RelicName: string,
      Icon: string,
      Text: string,
      Rarity: string,
  }
  ```
- **Client Handling**: Plays pulsing animation on player's relic HUD icon.
