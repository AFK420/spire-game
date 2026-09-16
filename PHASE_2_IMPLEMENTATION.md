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

