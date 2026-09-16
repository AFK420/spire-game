# Phase 2 Implementation Report: Universal Combat & Gameplay Foundation

## Executive Summary
Phase 2 replaces the prototype combat logic of **Card Rift: Co-op Dungeon** with a modular, data-driven gameplay engine. Responsibilities previously hardcoded into `CombatService.luau` have been decoupled into specialized, single-responsibility services:
1. **TargetResolver.luau**: Authoritative target entity validation, alive/downed constraints, and disconnect safety.
2. **ModifierResolver.luau**: Deterministic calculation engine for additive, multiplicative, and override modifiers.
3. **DamagePipeline.luau**: Multi-phase damage engine handling damage types, shield mitigation, direct HP bypass, and lethal transitions.
4. **StatusService.luau**: Central status authority with strict Definition vs. Instance separation.
5. **EffectResolver.luau**: Generic data-driven effect dispatcher with recursion depth protection.

All 16 existing Phase 1/1.2 test suites and 6 new Phase 2 test suites (22 suites total, 100% passing) verify that no regressions were introduced. The offline verifier passes 177 / 177 checks cleanly.

---

## 1. New Services & Architecture

### Service Matrix

| Service | Path | Responsibility |
|---|---|---|
| **TargetResolver** | `src/server/services/TargetResolver.luau` | Validates target entities (`Enemy`, `Self`, `Ally`, `None`) against active combat state, party membership, disconnect status, and alive/downed requirements. |
| **ModifierResolver** | `src/server/services/ModifierResolver.luau` | Deterministically calculates stat values: Base -> Additive Modifiers -> Multiplicative Modifiers -> Final Value (clamped to $\ge 0$). |
| **DamagePipeline** | `src/server/services/DamagePipeline.luau` | Calculates damage mitigation, applies shield absorption or shield bypass (`CanHitShield`), updates entity HP, and flags lethal states. |
| **StatusService** | `src/server/services/StatusService.luau` | Manages status definitions (`Poison`, `Ignite`, `Chill`, `Freeze`, `Shock`, `Bleed`) and runtime instances per entity with stacking, ticking, and duration expiration. |
| **EffectResolver** | `src/server/services/EffectResolver.luau` | Central dispatcher for card and skill actions (`Damage`, `Shield`, `Heal`, `Revive`, `ApplyStatus`, `RemoveStatus`, `Draw`, `GainEnergy`, `Exhaust`, etc.). |

---

## 2. Event Ordering & Action Lifecycle

Actions follow an explicit, deterministic resolution sequence:
```text
1. Client Action Received (PlayCard / Action)
2. Network Validation & Rate Limiting (NetworkService)
3. Action & Phase Validation (Player connected, alive, in PlayerPhase)
4. Target Resolution (TargetResolver.resolveTarget)
5. Class Gimmick Evaluation (ClassService)
6. Energy Verification & Hand Removal (CardService)
7. Relic Hook Trigger (RelicService.triggerEvent "OnCardPlay")
8. Modifier Collection (ModifierResolver)
9. Effect Resolution & Condition Check (EffectResolver.resolveEffects)
10. Damage / Shield / Heal / Status Execution (DamagePipeline & StatusService)
11. Death Checks & Event Logging (CombatLog & NetworkService)
12. Victory / Defeat Evaluation (CombatService.endCombat)
13. State Snapshot Broadcast (CombatService.broadcastSnapshots)
```

### Recursion & Cascade Protection
`EffectResolver` enforces a maximum recursion depth of 5 (`MAX_RECURSION_DEPTH = 5`). Any nested card trigger, status reaction, or chained effect exceeding this depth logs a warning and aborts to prevent infinite loops.

---

## 3. Data Model & Schema Enhancements

### Effect Schema (`StateTypes.luau` & `CardData.luau`)
```luau
export type Effect = {
    Type: EffectType,
    Value: number?,
    Target: TargetType?,
    StatusId: string?,
    Stacks: number?,
    Duration: number?,
    DamageType: string?,
    Tags: { string }?,
    Condition: string?,
    CardDefId: string?,
}
```

### First Aid Generic Representation
Previously, `FirstAid` had hardcoded branch logic in `CombatService`. It now uses generic condition evaluation with zero card-name branches:
```luau
local FirstAid: Card = {
    Id = "FirstAid",
    Name = "First Aid",
    Cost = 2,
    Target = "Ally",
    Effects = {
        { Type = "Revive", Value = 30, Condition = "TargetDowned" },
        { Type = "Heal", Value = 30, Condition = "TargetLiving" },
    },
    ...
}
```

---

## 4. StatusService & Poison Migration

Poison is now modeled as a structured status definition in `StatusService`:
- **Definition ID**: `"Poison"`
- **Stacking Mode**: `"Stack"`
- **Tick Timing**: `"TurnStart"`
- **Behavior**: Deals direct damage equal to stack count to HP with `CanHitShield = false` (bypasses Shield completely), then decrements stacks by 1.

### Backward Compatibility Projection
To ensure that existing UI snapshots (`EnemyView.Poison`), network payloads, and tests operate without breakage:
- `EnemyState.Poison` is maintained as a synchronized projection field.
- When `StatusService.applyStatus` or `tickStatuses` runs, `enemy.Poison` is updated to match `inst.Stacks`.
- When combat ends or starts, `StatusService.resetCombat()` clears all active status instances.

---

## 5. Test Coverage & Verification

### TestRunner Suites (22 Suites, 100% Passing)
- **Suite 17 (TargetResolver)**: Verified valid/invalid `Enemy`, `Self`, `Ally`, `None` resolution, dead enemy rejection, disconnected player rejection, and out-of-party rejection.
- **Suite 18 (ModifierResolver)**: Verified base values, additive modifiers, multiplicative modifiers, compound priority ordering ((10+4)*2 = 28), override modifiers, and `LowHP` conditions.
- **Suite 19 (DamagePipeline)**: Verified unshielded damage, shield absorption, complete shield absorption, direct HP bypass (`CanHitShield = false`), and lethal defeat.
- **Suite 20 (StatusService)**: Verified apply status, stack status, turn ticking, stack decrement, status removal, and definitions registry (`Poison`, `Ignite`, `Chill`, `Freeze`, `Shock`, `Bleed`).
- **Suite 21 (EffectResolver)**: Verified generic effect dispatch for `Damage`, `Shield`, `Heal`, `Revive`, `GainEnergy`, and `ApplyStatus`.
- **Suite 22 (First Aid Generic Semantics)**: Verified that living allies receive heal without revive, downed allies receive revive without double-heal, and no card-name branching exists.

### Offline Integration Verifier (`verify_phase1_integration.py`)
- **177 / 177 Checks Passed** (100% success rate, 0 failed).
- Verified strict Luau (`--!strict` on all 26 Luau files).
- Verified 0 `_G` references across all files.
- Verified 0 references to legacy monoliths or `applyClassToPlayer`.
- Verified Phase 3 strict boundary (`EquipmentService`, `SkillTreeService`, `ActiveSkillService` NOT present).

### Rojo Compilation
- `rojo build -o test.rbxl` compiles cleanly with exit code 0.

---

## 6. Strict Scope Boundary Confirmation
- Phase 2 implementation is strictly confined to the gameplay foundation engine.
- Equipment systems, passive skill trees, active skill trees, and large content rosters were **NOT** started.
- `PHASE 3 STARTED: NO`

---

## 7. Phase 2.1 Engine Hardening & Correctness Pass

A surgical hardening pass was conducted across the Phase 2 combat foundation to eliminate critical edge cases and enforce strict invariants:

### 1. Card Pile Invariant & Exhaust Uniqueness
- **Problem**: Playing a card moved it from `Hand` to `DiscardPile`, after which `handlers["Exhaust"]` inserted the same card instance into `ExhaustPile`, causing duplicate card instances across piles.
- **Resolution**: Implemented `CardService.exhaustCard(playerState, instanceId)`, which removes the card from `Hand`, `DiscardPile`, or `Deck` before inserting it into `ExhaustPile` exactly once.
- **Invariant**: A `CardInstance` exists in **EXACTLY ONE** pile at any time: `Deck` OR `Hand` OR `DiscardPile` OR `ExhaustPile`.

### 2. Effect-Level Target Overrides
- **Problem**: Secondary card effects (e.g. Damage Enemy + Shield Self) blindly targeted `context.Target`, causing player shields to be applied to enemies.
- **Resolution**: Implemented `resolveEffectTarget(effect, context)` in `EffectResolver.luau`. If `effect.Target` is specified, `TargetResolver.resolveTarget` evaluates the specific target entity; otherwise it falls back to `context.Target`. All handlers now receive and consume `resolvedTarget`.

### 3. Status Authority & Tick Behavior Registry
- **Problem**: `StatusService.luau` hardcoded `if/elseif` chains for ticking and had stub statuses without implementation status.
- **Resolution**:
  - Distinguish implemented statuses (`Poison`, `Ignite`, `Bleed`) from planned statuses (`Chill`, `Freeze`, `Shock`) using `Implemented: boolean` and `TickBehaviorId: string?`.
  - Replaced hardcoded conditionals with data-driven `tickBehaviors: { [string]: TickBehaviorFn }` (`DirectHPPoison`, `FireDoT`, `BleedDoT`).
  - Added `StatusService.syncEntityFromProjection(targetId, targetEntity)` to reconcile external or legacy modifications into `StatusService`, establishing `StatusService` as the single canonical source of truth for active statuses.

### 4. DamagePipeline Input Validation & Clamping
- **Input Validation**: Rejects `RawDamage < 0` and missing target entities upfront, returning deterministic `{ FinalDamage = 0, ShieldAbsorbed = 0, HPLost = 0, IsDefeatedOrDowned = false }`.
- **Invariant Clamping**: Enforces that entity `Shield` and `HP` are clamped to $\ge 0$ at every calculation step.

### 5. Generalized Effects & Recursion Protection
- **ModifyResource**: Supports typed resources (`HP`, `MaxHP`, `Shield`, `Energy`, `MaxEnergy`, `Gold`) with bounds clamping and downing detection. Rejects invalid resource types cleanly.
- **TriggerEvent**: Validates non-empty `EventId`, logs custom combat events, and safely dispatches to `RelicService.triggerRelics`.
- **Recursion Safety**: Protected against recursion depth leaks by wrapping handler resolution in `pcall` ensuring `currentDepth` is always decremented.

### 6. Phase 2.1 Test Suite Expansion (29 Suites Total)
- **Suite 23 (Suite A)**: Exhaust Pile Uniqueness & Pile Count Invariants.
- **Suite 24 (Suite B)**: Effect-Level Target Overrides (Damage Enemy + Shield Self).
- **Suite 25 (Suite C)**: ModifyResource Safety, Bounds Clamping, and Invalid Type Rejection.
- **Suite 26 (Suite D)**: Event Triggering, Event Logging, and Recursion Depth Limit Safety.
- **Suite 27 (Suite E)**: Status Authority, Projection Synchronization, and Tick Behavior Registry.
- **Suite 28 (Suite F)**: Damage Pipeline Edge Cases (Negative Raw Damage, Missing Entities, Direct HP Bypass, Shield Overflow).
- **Suite 29 (Suite G)**: Modifier Pipeline Determinism, Id Sorting, Override Precedence, and Immutability.
- **Offline Integration Verifier**: 207 / 207 Checks Passed (100% clean).

---

## 8. Phase 2.2 Correctness & Architecture Hardening Pass

A follow-up surgical hardening pass was completed to resolve deeper multiplayer and edge-case correctness issues across Phase 2:

### 1. True Target-Aware Generic Resource Modification
- **Problem**: `EffectResolver.handlers["ModifyResource"]` resolved `recipient = resolvedTarget.PlayerTarget or context.SourcePlayer`, but branches for `Energy`, `MaxEnergy`, and `Gold` still mutated `context.SourcePlayer`.
- **Resolution**: All resource branches (`HP`, `MaxHP`, `Shield`, `Energy`, `MaxEnergy`, `Gold`) now strictly mutate `recipient` (`resolvedTarget.PlayerTarget`). If targeting an ally, the ally receives the resource modification.
- **Validation**: `ModifyResource` requires `resolvedTarget.Success == true` and `resolvedTarget.TargetKind == "Player"`. Invalid or missing targets return `{ Success = false }` with zero silent fallback to caster.

### 2. RelicService Dispatch Failure Containment
- **Problem**: In `EffectResolver.handlers["TriggerEvent"]`, calling `RelicService.triggerRelics` could throw if relic context had corrupt data or an unhandled exception occurred, failing to report clean failure.
- **Resolution**: Wrapped `RelicService.triggerRelics` dispatch in `pcall`. If the trigger throws, an error is caught, warning logged, and `{ Success = false, Message = ... }` is returned truthfully.
- **Recursion Safety**: Guaranteed restoration of `currentDepth` counter in `EffectResolver.resolveEffects` via `pcall`, ensuring recursion depth tracking is never corrupted.

### 3. Strict Real-Target Context Resolution Without Dummy Synthesis
- **Problem**: `resolveEffectTarget` synthesized fake dummy `CombatState` and `Party` structures when context was omitted, masking missing combat/run state and failing real multiplayer party contexts.
- **Resolution**: Removed all dummy synthesis. `resolveEffectTarget` directly passes `context.CombatState` and `context.Party` to `TargetResolver.resolveTarget`.
- **Target Legality**: `TargetResolver.resolveTarget` strictly checks for `combatState` on `Enemy` targets and `party` on `Ally` targets, returning clean errors if missing. Handlers for `Damage`, `Shield`, `Heal`, `Revive`, `ApplyStatus`, and `RemoveStatus` strictly reject non-matching target kinds or un-success results with zero silent fallbacks.

### 4. Removal of CreateCard Prototype Fallbacks
- **Problem**: `handlers["CreateCard"]` used `local cardDefId = effect.CardDefId or effect.StatusId or "Strike"`.
- **Resolution**: Removed all fallbacks to `StatusId` and `"Strike"`. `CreateCard` now strictly requires `effect.CardDefId`.
- **Verification**: If `effect.CardDefId` is missing, nil, empty, or unknown in `CardData`, the effect returns `Success = false` cleanly.
- **Destination Pile**: Added typed `DestinationPile` to `CardData.Effect` (`"Deck"`, `"Hand"`, `"DiscardPile"`, `"ExhaustPile"`, defaulting to `"Deck"`).

### 5. Card Pile Invariant Validator
- **Helper**: Added `CardService.validatePileInvariants(playerState: StateTypes.PlayerState): (boolean, string?)`.
- **Guarantees**:
  - **Single Ownership**: Exact-one pile ownership per `CardInstance` across `Deck`, `Hand`, `DiscardPile`, `ExhaustPile` ($\sum \text{Locations} = 1$).
  - **No Duplicates**: No duplicate `InstanceId` within any single pile or across piles.
  - **Hand Integrity**: Every key in `Hand` dictionary matches `card.InstanceId`.
  - **Player Ownership**: All card instances across all piles have `OwnerUserId == playerState.UserId`.
  - **Type Safety**: All instances are valid tables with non-empty string `InstanceId` and `DefinitionId`.
- **Audited Methods**: Verified invariant preservation across `drawCards`, `playCardFromHand`, `discardHand`, `exhaustCard`, and `resetCombatPiles`.

### 6. Finalized Status Authority Boundary
- **Status Authority**: `StatusService` is the sole canonical source of truth for active statuses, durations, and stacks. Projections like `enemy.Poison` are strictly outputs / read models.
- **Ticking Contract**: `StatusService.tickStatuses` reads from `StatusService` first, decrements stacks/durations in `StatusService`, and writes back to `enemy.Poison` as an output. It does not overwrite internal state from projections.
- **Legacy Compatibility**: `StatusService.syncEntityFromProjection` only applies when `StatusService` has no existing record of that entity's status.
- **Rogue Mutation Cleanup**:
  - In `RelicService`, `VenomVial` now calls `StatusService.applyStatus` directly instead of `context.Enemy.Poison += relic.Value`.
  - In `CombatService`, enemy TurnStart status ticking invokes `StatusService.tickStatuses` directly without manual Poison checks or manual projection synchronization.

### 7. Phase 2.2 Test Suite Expansion (36 Suites Total, 232 Verifier Checks)
- **Suite 30 (ModifyResource Targeting)**: Verified caster vs. ally targeting for Energy, MaxEnergy, Shield, Gold, and clean rejection of invalid targets.
- **Suite 31 (TriggerEvent Failure Semantics)**: Verified normal execution, missing EventId rejection, pcall error containment, and recursion depth safety.
- **Suite 32 (Real Target Resolution Context)**: Verified Enemy target without CombatState rejection, Ally target without Party rejection, 4-player party resolution, multi-enemy targeting, and dead/disconnected entity rejection.
- **Suite 33 (CreateCard Schema Strictness)**: Verified missing CardDefId rejection, unknown def rejection with zero Strike fallback, and destination pile placement (`Deck`, `Hand`).
- **Suite 34 (Card Pile Invariant Validator)**: Verified valid states, duplicate detection across piles (Deck/Hand), duplicate detection within pile (Deck), owner mismatch rejection, and invariant preservation through draw, play, discard, exhaust, and reset.
- **Suite 35 (Status Authority Boundary)**: Verified ticking reads StatusService ignoring rogue writes to `enemy.Poison`, projection updated as output, and backward compat sync when no record exists.
- **Suite 36 (Cross-System Integration Chains)**: Verified Damage Enemy + Shield Self compound actions, Revive Ally, and CreateCard + Draw chains.
- **Offline Integration Verifier**: 232 / 232 Checks Passed (100% clean).
- **Rojo Compilation**: `rojo build -o test.rbxl` compiles cleanly with exit code 0.

---

## 9. Phase 2.3 Card Effect-Target Consistency & Mixed-Target Hardening

A surgical correctness pass was completed to resolve mixed-target card definitions, enforce static effect-target compatibility rules, and prevent double-counting of bonus shield:

### 1. Problem Analysis & Root Cause
- **Target Incompatibility**: Phase 2 generic effect handlers enforce strict target kinds (`Damage`/`Poison` require `EnemyTarget`, `Shield`/`Heal`/`Revive`/`ModifyResource` require `PlayerTarget`). However, several multi-effect cards combined offensive and defensive effects while omitting explicit `Target` fields on sub-effects:
  - `ShieldSlam` (Enemy target): Had `Shield` effect without explicit `Target = "Self"`.
  - `WrenchThrow` (Enemy target): Had `Shield` effect without explicit `Target = "Self"`.
  - `SoulHarvest` (Enemy target): Had `Heal` effect without explicit `Target = "Self"`.
  - `TimeWarp` (Enemy target): Had `Shield` effect without explicit `Target = "Self"`.
  - `DeployTurret` & `PackCall`: Had top-level `Target = "Self"`, which prevented client UI from allowing enemy targeting (`UIController.client.luau:646` requires `Target == "Enemy"` to select an enemy), rendering the offensive damage effect unexecutable.
- **Double-Counting Bonus Shield**: In `CombatService.luau`, class gimmick bonus shield was being added directly to `playerState.Resources.Shield` *and* passed as `ActionBonusShield` into `EffectResolver`. When a card contained a `Shield` effect, the bonus shield was resolved twice.

### 2. Implementation & Canonical Changes
- **Mixed-Target Card Corrections (`src/shared/CardData.luau`)**:
  - `ShieldSlam`: `Target = "Enemy"`, effects: `Shield -> Self` (8), `Damage -> Enemy` (8).
  - `WrenchThrow`: `Target = "Enemy"`, effects: `Damage -> Enemy` (7), `Shield -> Self` (3).
  - `SoulHarvest`: `Target = "Enemy"`, effects: `Damage -> Enemy` (7), `Heal -> Self` (3).
  - `DeployTurret`: Top-level `Target = "Enemy"`, effects: `Shield -> Self` (6), `Damage -> Enemy` (6). Description updated: sentry turret shields caster and fires at target enemy.
  - `TimeWarp`: `Target = "Enemy"`, effects: `Damage -> Enemy` (7), `Shield -> Self` (4).
  - `PackCall`: Top-level `Target = "Enemy"`, effects: `Shield -> Self` (7), `Damage -> Enemy` (4). Description updated: rally pack to shield caster and deal damage to target enemy.
  - Explicit `Target` added to `PoisonDart`, `FirstAid`, and `Contagion`.
- **Static Validation Engine (`CardData.luau`)**:
  - Implemented `CardData.validateCard(card: Card): (boolean, string?)` and `CardData.validateCardDefinitions(): (boolean, string?)`.
  - Validates 7 core rules:
    1. Every effect's effective target (`eff.Target or card.Target`) matches required target kind for the effect type.
    2. Explicit effect targets use valid `TargetType` (`Enemy`, `Self`, `Ally`, `None`).
    3. Mixed-target cards (containing both Enemy and Player effects) must explicitly declare `Target` on each sub-effect (no implicit fallback).
    4. `Damage` and `Poison` effects cannot inherit or target `Self` or `Ally`.
    5. `Shield`, `Heal`, and `Revive` effects cannot inherit or target `Enemy`.
    6. `ModifyResource` effects require a legal Player target (`Self` or `Ally`).
    7. All registered card definitions in `CardData` pass validation at runtime and startup.
- **Bonus Shield Gimmick Safety (`CombatService.luau`)**:
  - Checks `cardHasShieldEffect`. When a card has a `Shield` effect, `totalBonusShield` is passed exclusively through `ActionBonusShield` into `ModifierResolver`/`EffectResolver`. When a card lacks a `Shield` effect, bonus shield is applied directly to `playerState.Resources.Shield`. Zero double-counting occurs.

### 3. Test Coverage & Verification (38 Suites Total, 255 Verifier Checks)
- **Suite 37 (Static Card Effect Target Compatibility)**:
  - All registered cards in `CardData` pass static validation.
  - Verified explicit rejection of Damage inheriting `Self`/`Ally`.
  - Verified explicit rejection of Shield inheriting `Enemy`.
  - Verified explicit rejection of mixed-target cards missing effect `Target`.
  - Verified explicit rejection of ModifyResource targeting `Enemy`.
- **Suite 38 (End-to-End Mixed-Target Execution)**:
  - **ShieldSlam**: Caster gained 8 Shield, Enemy took 8 damage, Enemy gained 0 shield.
  - **WrenchThrow**: Enemy took 7 damage, Caster gained 3 Shield.
  - **SoulHarvest**: Enemy took 7 damage, injured Caster healed 3 HP.
  - **DeployTurret**: Caster gained 6 Shield, Enemy took 6 damage.
  - **TimeWarp**: Enemy took 7 damage, Caster gained 4 Shield.
  - **PackCall**: Caster gained 7 Shield, Enemy took 4 damage.
  - **Contagion**: Enemy took 8 damage, afflicted with 4 Poison stacks.
  - **FirstAid**: Downed ally revived to 30 HP (`IsDowned = false`), living ally healed 30 HP (40 -> 70).
  - **BonusShield Safety**: `ActionBonusShield` modifier applied exactly once (base 8 + 4 = 12 Shield, not 16).
- **Offline Integration Verifier (`verify_phase1_integration.py`)**:
  - **255 / 255 Checks Passed** (100% success rate, 0 failed).
- **Rojo Build**: Clean build with exit code 0.

---

## 10. Phase 2.4 Final Schema Hardening (CreateCard Destination & ModifyResource Strictness)

A final surgical schema-hardening pass was completed to eliminate silent fallbacks in `CreateCard` and `ModifyResource`:

### 1. Strict CreateCard Destination Validation
- **Problem**: Previously, `handlers["CreateCard"]` used `local dest = effect.DestinationPile or "Deck"` and placed the card in `Deck` on any unmatched value in the `if/elseif` chain, silently accepting typos and invalid strings. Additionally, the card instance was instantiated before validating `DestinationPile`.
- **Resolution**:
  - Enforce exact allowed values: `Deck`, `Hand`, `DiscardPile`, `ExhaustPile`.
  - `nil DestinationPile` defaults to `Deck` (allowed default).
  - Explicit valid destination places card directly into specified pile.
  - Invalid destination (e.g. `"Banana"`) returns `{ Success = false, Message = ... }`.
  - Empty string `""` is strictly rejected as an invalid destination with `{ Success = false }`.
  - Validation occurs *before* `CardService.createCardInstance` is called, ensuring zero card instances are created on failure.
  - Zero silent fallback to `Deck` on unrecognized destinations.
  - Verified static card validation in `CardData.validateCard` also rejects invalid `DestinationPile` configurations.

### 2. Removal of ModifyResource Implicit Gold Fallback
- **Problem**: Previously, `handlers["ModifyResource"]` contained `if not resType then resType = "Gold" end`, causing cards with missing or empty `Resource` fields to silently modify player Gold.
- **Resolution**:
  - Removed the implicit Gold fallback entirely.
  - Missing `Resource` (`nil`) or empty string `""` returns `{ Success = false, Message = "ModifyResource requires a valid non-empty Resource type." }`.
  - Invalid `Resource` strings fall through to the terminal rejection branch returning `{ Success = false }`.
  - Valid `ResourceType` union (`HP`, `MaxHP`, `Shield`, `Energy`, `MaxEnergy`, `Gold`) executes normally.
  - Zero accidental Gold modification occurs.
  - Maintained strict target awareness: `Self` modifies caster; `Ally` modifies ally while caster remains untouched.

### 3. Test Coverage & Verification (39 Suites Total, 270 Verifier Checks)
- **Suite 39 (Final Schema Strictness & Resource Boundary Safety)**:
  - **CreateCard Valid Destinations**: Verified `Deck`, `Hand`, `DiscardPile`, `ExhaustPile`, and default `nil -> Deck`.
  - **CreateCard Invalid Destinations**: Verified that `"Banana"` and `""` return `Success = false` and create zero cards across any pile.
  - **Card Pile Invariant Verification**: Validated single ownership across all card piles after card creations (`ok == true`).
  - **ModifyResource Missing/Invalid Rejection**: Verified `nil`, `""`, and `"InvalidResourceXYZ"` return `Success = false` with zero Gold modification.
  - **ModifyResource Valid Execution**: Verified `Gold`, `Energy`, `Self Energy`, and `Ally Energy` execute cleanly without cross-player side effects.
- **Offline Integration Verifier (`verify_phase1_integration.py`)**:
  - **270 / 270 Checks Passed** (100% success rate, 0 failed).
- **Rojo Build**: Clean build with exit code 0.

---

## 11. Strict Scope Boundary Confirmation
- Phase 2, Phase 2.1, Phase 2.2, Phase 2.3, and Phase 2.4 are complete and hardened.
- Equipment systems, passive skill trees, active skill trees, and large content rosters were **NOT** started.
- `PHASE 3 STARTED: NO`



