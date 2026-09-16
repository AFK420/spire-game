# PHASE 3 — UNIVERSAL COMBAT & GAMEPLAY FOUNDATION: RPG SYSTEMS FOUNDATION

## Card Rift: Co-op Dungeon

This document outlines the architecture, data models, state boundaries, runtime engines, and verification suite for the **Phase 3 RPG Systems Foundation**.

---

## 1. System Architecture & Foundation Components

Phase 3 introduces five foundational RPG subsystems that sit cleanly on top of the Phase 2 universal gameplay engine (`EffectResolver`, `TargetResolver`, `ModifierResolver`, `DamagePipeline`, `StatusService`):

```
+-----------------------------------------------------------------------------------+
|                                 PlayerState                                       |
|  - Resources (HP, MaxHP, Energy, MaxEnergy, Shield, Gold)                         |
|  - EquippedItems: { [EquipmentSlot]: EquipmentInstance }                          |
|  - EquipmentInventory: { EquipmentInstance }                                      |
|  - EquippedSkills: { [SkillSlot]: SkillInstance }                                 |
|  - UnlockedPassives: { [string]: boolean }, PassivePoints: number                 |
+-----------------------------------------------------------------------------------+
       |                            |                           |
       v                            v                           v
+-------------------+      +-------------------+      +-------------------+
| EquipmentService  |      |  PassiveService   |      |   SkillService    |
| - createInstance  |      | - unlockNode      |      | - createInstance  |
| - equipItem       |      | - collectModifiers|      | - equipSkill      |
| - unequipItem     |      | - validateDAG     |      | - useSkill        |
| - collectModifiers|      +-------------------+      | - onTurnStart     |
+-------------------+               |                 +-------------------+
       \                            |                           /
        \                           |                          /
         v                          v                         v
       +-------------------------------------------------------------+
       |                        StatResolver                         |
       |  - Base Stat Resolution from ClassData                      |
       |  - (Base + AdditiveSum) * MultiplicativeProduct             |
       |  - Absolute Override Precedence                             |
       |  - Clamping (MaxHP >= 1, MaxEnergy >= 0, Crit [0, 1])       |
       |  - Derived Stat Synchronization onto PlayerState            |
       +-------------------------------------------------------------+
                                    |
                                    v
       +-------------------------------------------------------------+
       |              Combat Actions & Execution Pipeline             |
       |  - CombatService.playCard  <--- Includes player modifiers   |
       |  - SkillService.useSkill   <--- Routed via TargetResolver   |
       |  - EffectResolver.resolveEffects                            |
       |  - DamagePipeline.executeDamage                             |
       +-------------------------------------------------------------+
```

---

## 2. Component Specifications

### 2.1 Equipment Foundation (`EquipmentData.luau` & `EquipmentService.luau`)
- **Definition vs Instance Pattern**:
  - `EquipmentDefinition`: Immutable catalog specification defining `Slot` (`Weapon`, `Armor`, `Accessory`), `Rarity`, `Tags`, `BaseStats`, and optional `Modifiers`.
  - `EquipmentInstance`: Mutable runtime item container with unique stable GUID `InstanceId`, `DefinitionId`, `OwnerUserId`, `Slot`, and `Level`.
- **Lifecycle & Single-Slot Invariants**:
  - `EquipmentService.equipItem`: Validates player ownership, enforces single-slot occupancy, automatically displaces any previously equipped item in that slot back into `playerState.EquipmentInventory`, and places the new item into `playerState.EquippedItems[slot]`.
  - `EquipmentService.unequipItem`: Vacates the slot and returns the item to inventory.
  - `EquipmentService.collectModifiers`: Gathers all additive modifiers defined in the gear's `BaseStats` or rolled modifiers.

### 2.2 Centralized Stat Resolution (`StatResolver.luau`)
- **Deterministic Pipeline**:
  - Evaluates stats in strict order:
    1. Base value queried from `ClassData.getClass(playerState.ClassId)`.
    2. Collects applicable modifiers via `StatResolver.collectPlayerModifiers(playerState)` (combining equipment, passives, and active effects).
    3. Sorts modifiers deterministically by Priority (ascending) and ID (alphabetical).
    4. Override Check: Any `Operation == "Override"` takes absolute precedence.
    5. Additive Sum: Evaluates all `Operation == "Add"`.
    6. Multiplicative Product: Evaluates all `Operation == "Multiply"`.
    7. Clamping:
       - `MaxHP`: clamped minimum `1`.
       - `MaxEnergy`: clamped minimum `0`.
       - `CritChance`: clamped floating range `[0.0, 1.0]`.
       - `CritMultiplier`: clamped minimum `1.0`.
       - Integers (`Damage`, `Shield`, `ShieldGain`, `Healing`, `Cost`): clamped minimum `0` and rounded.
- **Derived Stat Synchronization**:
  - `StatResolver.syncPlayerDerivedStats(playerState)`: Computes resolved `MaxHP` and `MaxEnergy`, updates `playerState.Resources`, and clamps current `HP` and `Energy` safely within the updated maximums.

### 2.3 Passive Tree Graph Foundation (`PassiveData.luau` & `PassiveService.luau`)
- **DAG Schema & Validation**:
  - `PassiveNodeDefinition`: Defines `Id`, `Name`, `Description`, `ClassId`, `Type` (`Stat`, `Notable`, `Keystone`), `Tier`, `Cost`, `Prerequisites`, and `Modifiers`.
  - `PassiveData.validateNodes(nodes)`: Graph validator detecting:
    - Cycles via depth-first search (DFS) with stack tracking.
    - Broken/missing prerequisite references.
    - Self-cycles (`node.Prerequisites` containing itself).
    - Duplicate node IDs.
  - `PassiveData.validateTree(classId)`: Validates the canonical class tree.
- **Progression Runtime**:
  - `PassiveService.unlockNode(playerState, nodeId)`: Checks class compatibility, rejects already-unlocked nodes, enforces that all prerequisites are already unlocked, checks available `PassivePoints`, deducts points, sets `playerState.UnlockedPassives[nodeId] = true`, and invokes `StatResolver.syncPlayerDerivedStats`.
  - `PassiveService.collectModifiers(playerState)`: Collects all modifiers from unlocked nodes.

### 2.4 Active Skills Runtime (`SkillData.luau` & `SkillService.luau`)
- **Distinction from Cards**:
  - Skills do not draw from or discard to card piles. They occupy dedicated player skill slots (`Skill1` .. `Skill4`) and operate on independent turn cooldowns and resource costs.
- **Authoritative Execution**:
  - `SkillService.useSkill`:
    - Enforces living, connected player and active `PlayerPhase`.
    - Enforces `CurrentCooldown == 0`.
    - Validates and deducts `Energy` and optional `HP` costs.
    - Resolves targets authoritatively via `TargetResolver.resolveTarget`.
    - Synthesizes action modifiers via `StatResolver.collectPlayerModifiers(playerState)`.
    - Dispatches effects directly via `EffectResolver.resolveEffects`.
    - Enforces cooldown: `CurrentCooldown = def.CooldownTurns`.
  - `SkillService.onTurnStart`: Monotonically decrements active cooldowns at turn start.
  - `CombatService.useSkill`: Public player action API with victory checks and snapshot broadcasts.

---

## 3. The Phase 3 Vertical Slice Proof

Suite 44 in `TestRunner.luau` verifies the complete end-to-end flow:

1. **Player Initialization**: Warlord initialized with baseline MaxHP 110, Energy 3.
2. **Equip Item**: Equips `IronBroadsword` (+5 Damage, +10 MaxHP).
   - `StatResolver.syncPlayerDerivedStats` recalculates and updates `playerState.Resources.MaxHP` to **120**.
3. **Unlock Passive**: Grants points and unlocks `Warlord_IronSkin` (+15 MaxHP).
   - `StatResolver.syncPlayerDerivedStats` updates `playerState.Resources.MaxHP` to **135** (110 Base + 10 Sword + 15 Passive).
4. **Unlock Second Passive**: Unlocks `Warlord_HeavyStrikes` (+3 Damage).
   - Total bonus attack damage resolves to **+8** (5 Sword + 3 Passive).
5. **Equip Active Skill**: Equips `HeroicStrike` (Base Damage 12, Cost 1 Energy, Cooldown 1 Turn) into `Skill1`.
6. **Combat Encounter**: Spawns boss target with 100 HP, 0 Shield.
7. **Skill Execution**: Player executes `HeroicStrike`:
   - Energy reduced from 3 to 2.
   - Skill cooldown enters 1 turn.
   - Damage routed through `TargetResolver` and `DamagePipeline.executeDamage`.
   - Base 12 Damage + 8 Bonus Damage = **20 Damage**.
   - Boss HP reduces from 100 to **80**.
8. **Turn Advancement**: `SkillService.onTurnStart` decrements cooldown to 0.
9. **Second Execution**: Executing `HeroicStrike` again deals another 20 Damage, reducing Boss HP to **60**.

---

## 4. Test Suite Summary

The test runner now covers **51 distinct test suites** and **432 automated assertions**:

- **Suite 40**: Phase 3 Equipment Foundation (Creation, slot assignment, equip/unequip lifecycle, single-slot replacement, inventory tracking, owner mismatch rejection, modifier aggregation).
- **Suite 41**: Phase 3 Centralized Stat Resolution (Base class stats, additive stacking, multiplicative stacking, absolute override precedence, stat bounds clamping, derived stat synchronization).
- **Suite 42**: Phase 3 Passive Tree & Graph Validation (Canonical DAG validation, cycle detection, self-cycle rejection, missing prerequisite rejection, duplicate ID rejection, player unlock lifecycle, prerequisite enforcement, point deduction, class mismatch rejection).
- **Suite 43**: Phase 3 Active Skills Runtime (Creation, class eligibility, slot equipping, authoritative execution, energy deduction, cooldown setting, cooldown prevention, turn start decrements, energy exhaustion rejection).
- **Suite 44**: Complete Vertical Slice End-to-End Test (Full chain integration from player state, equipment, passives, active skills, damage pipeline, to combat state updates).
- **Suite 45**: Phase 3.1 Equipment Authority Hardening (Forged slot tampering rejection, inventory absence rejection, authoritative provisioning via `grantEquipment`, duplicate equipped instance prevention, slot replacement preservation, deterministic modifier ordering).
- **Suite 46**: Phase 3.1 Active Skill Ownership & Cooldown Hardening (Unowned skill equip rejection, authoritative unlock via `unlockSkill`, runtime `SkillSlot` validation, class restriction enforcement, duplicate equipped instance rejection, runtime cooldown isolation).
- **Suite 47**: Phase 3.1 Passive Tree Hardening & Negative Modifier Stacking (Empty string ID rejection, non-array prerequisite rejection, empty string prerequisite rejection, keystone `TitanStance` negative MaxEnergy stacking, derived stat synchronization, deterministic modifier sorting).
- **Suite 48**: Phase 3.1 Active Skill Transactional Execution (Disconnected player rejection, downed player rejection, non-PlayerPhase rejection, target failure zero-cost & zero-cooldown rollback, defeated enemy rejection, successful execution).
- **Suite 49**: Phase 3.1 Network Contracts & Remote Event Authority (All 6 RemoteEvents registered in `NetworkService`, category rate limiting enforcement, player-inferred sender authority).
- **Suite 50**: Phase 3.1 Extended Vertical Slice End-to-End (Complete expedition lifecycle: gear provisioning & equipping, passive unlocks, skill unlocks, transactional execution, cooldown enforcement and turn reset, and gear unequip modifier cleanup with zero stale leaks).
- **Suite 51**: Phase 3.2 Network Ownership Boundary & Contract Validation (Authoritative skill ownership via `SkillInventory`, `getOwnedSkill` lookup, rejection of unowned/invalid/foreign skills, complete removal of `bypassInventoryCheck`, strict whitelist slot contracts, snapshot serialization consistency for `PlayerView`).

---

## 5. Phase 3.1 & 3.2 Hardening Architecture

For complete details on Phase 3.1 and Phase 3.2 hardening changes, see:
- [PHASE_3.1_HARDENING.md](file:///c:/Users/owner/Documents/spire-game/PHASE_3.1_HARDENING.md) (Equipment authority, transactional skills, negative modifier stacking, state boundaries).
- [PHASE_3.2_NETWORK_OWNERSHIP.md](file:///c:/Users/owner/Documents/spire-game/PHASE_3.2_NETWORK_OWNERSHIP.md) (Closing network ownership boundaries, strict slot validation, snapshot serialization consistency, remote event security audit).

---

## 6. Scope Boundaries & Intentional Deferrals

To maintain surgical focus and avoid content sprawl, the following systems remain intentionally unstarted and deferred to subsequent phases:

- Full 10-class passive trees (only the representative Warlord DAG is instantiated).
- 100s of equipment items (only representative Weapon, Armor, and Accessory definitions are instantiated).
- Full skill rosters (only representative attack, defense, buff, and class skills are instantiated).
- CraftingService, MonetizationService, BattlePassService (verified absent by verification suite).
- Persistent Account Profiles (deferred to Phase 4+; clear state boundaries established in `StateTypes.luau`).
- Complex UI visualizers for skill bars and passive trees (visual presentation deferred to client polish pass).

