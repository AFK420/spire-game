# PHASE 3.2 — NETWORK OWNERSHIP BOUNDARY & CONTRACT HARDENING

## Card Rift: Co-op Dungeon

This document details the architectural audit, network security boundary closures, strict contract validations, and verification matrix implemented for **Phase 3.2 — Close Network Ownership Boundary**.

---

## 1. Executive Summary & Goals

In Phase 3.1, the foundational RPG mechanics and RemoteEvents were introduced. However, a remaining network authority flaw was identified:
`NetworkService.EquipSkillEvent` previously received a client-supplied `skillDefId` and dynamically created a new `SkillInstance` via `SkillService.createInstance(...)` before equipping it. This defeated the intended skill ownership boundary and allowed a client to equip unearned skills at will.

Phase 3.2 completely closes this network authority boundary:
1. **Authoritative Skill Ownership Enforcement**: Added an authoritative `SkillInventory: { SkillInstance }` to `PlayerState`. `SkillService.unlockSkill` is the only legitimate runtime gateway for provisioning skill instances into a player's inventory. `EquipSkill` strictly queries `SkillService.getOwnedSkill(playerState, identifier)` and requires existing inventory ownership. Calling `createInstance` from network event handlers is completely prohibited.
2. **Complete Removal of Inventory Bypasses**: `bypassInventoryCheck` has been excised from `EquipmentService.equipItem`. Public `equipItem` strictly mandates that the item instance must already exist within `playerState.EquipmentInventory`. Initial provisioning is strictly reserved for authoritative server helpers (`grantEquipment` / `unlockSkill`).
3. **Strict Network Slot Validation**: Added strict lookup tables (`VALID_EQUIPMENT_SLOTS` and `VALID_SKILL_SLOTS`) at the network boundary in `init.server.luau`. String types, non-empty lengths, and valid slot names are enforced before invoking services, avoiding unchecked Luau type casts (`:: any`).
4. **Snapshot & Serialization Consistency**: Both `RunManager.getRunSnapshotForPlayer` and `CombatService.getCombatSnapshotForPlayer` serialize complete and consistent `PlayerView` records (including `EquippedItems`, `EquippedSkills`, `SkillInventory`, `UnlockedPassives`, and `PassivePoints`). The sequencing invariant is strictly enforced: `Client requests action -> server resolves authoritative owned object -> service validates -> state mutation -> snapshot broadcast`. Rejected actions never broadcast snapshots.
5. **Comprehensive Endpoint Audit**: Audited all 16 RemoteEvent endpoints to guarantee that zero client-to-server pathways allow arbitrary resource, card, gear, skill, or turn minting.

---

## 2. Implemented Architecture & Security Closures

### 2.1 Authoritative Skill Ownership Flow

```
[ Client ] 
   │  FireServer("HeroicStrike", "Skill1")
   ▼
[ Network Listener: EquipSkillEvent ]
   │  1. Check category rate limit ("General")
   │  2. Validate typeof(skillIdentifier) == "string" and #skillIdentifier > 0
   │  3. Validate VALID_SKILL_SLOTS[slot] == true
   ▼
[ SkillService.getOwnedSkill(playerState, identifier) ]
   │  1. Scan playerState.SkillInventory
   │  2. Verify item.OwnerUserId == playerState.UserId
   │  3. Verify SkillService.hasSkill(playerState, item.DefinitionId)
   │  ├── If not owned ──> WARN & REJECT (Zero state mutation, zero broadcast)
   │  └── If owned     ──> Return authoritative SkillInstance
   ▼
[ SkillService.equipSkill(playerState, ownedInstance, slot) ]
   │  1. Validate class requirement against playerState.ClassId
   │  2. Prevent duplicate instance in multiple slots
   │  3. If replacing an existing skill in target slot, unslot safely (Slot = nil), retaining cooldown
   │  4. Assign instance to playerState.EquippedSkills[slot] and update instance.Slot = slot
   ▼
[ RunManager.broadcastRunSnapshots ]
   └── Snapshot contains updated EquippedSkills, SkillInventory, and Derived Stats
```

### 2.2 Equipment Inventory Authority & Bypass Removal

- `EquipmentService.equipItem(playerState, equipInstOrId)` now strictly enforces that the item exists within `playerState.EquipmentInventory`.
- Attempting to equip an unowned item ID or an unowned instance table returns:
  `false, "Equipment instance '<id>' not found in player's inventory."`
- Foreign item ownership mismatches are explicitly rejected:
  `false, "Equipment instance owner <X> does not match player <Y>."`
- Forged slots that do not match the canonical immutable definition (`EquipmentData.getEquipment(defId).Slot`) are rejected:
  `false, "Forged slot '<slot>' on equipment '<name>'. Authoritative slot is '<authSlot>'."`
- Zero occurrences of `bypassInventoryCheck` exist in the entire codebase.

### 2.3 Strict Network Slot Validation

In `src/server/init.server.luau`:
```luau
local VALID_EQUIPMENT_SLOTS: { [string]: boolean } = {
	["Weapon"] = true,
	["Armor"] = true,
	["Accessory"] = true,
}

local VALID_SKILL_SLOTS: { [string]: boolean } = {
	["Skill1"] = true,
	["Skill2"] = true,
	["Skill3"] = true,
	["Skill4"] = true,
}
```
All endpoints (`EquipEquipmentEvent`, `UnequipEquipmentEvent`, `EquipSkillEvent`, `UnequipSkillEvent`, `UseSkillEvent`, `UnlockPassiveEvent`, `UnlockSkillEvent`) validate:
- Payload type is strictly `"string"`
- Payload length `#string > 0`
- Slot identifier is a valid key in the corresponding whitelist table.
Any malformed, non-string, unexpected, or out-of-range value immediately aborts without invoking service methods or mutating state.

---

## 3. Remote Event Surface Audit (All 16 Endpoints)

| # | RemoteEvent | Arguments Verified | Server-Side Validation & Security Controls | Minting Risk |
|---|---|---|---|---|
| 1 | `StartRunEvent` | `(player: Player)` | Rate limited ("General"). Verifies lobby phase in `RunManager`. | None |
| 2 | `SelectClassEvent` | `(player, classId, subclassId)` | Rate limited ("Class"). Verifies string types and canonical classes in `ClassService`. | None |
| 3 | `VoteMapNodeEvent` | `(player, targetNodeId)` | Rate limited ("Map"). Verifies reachable map node ID in `RunManager`. | None |
| 4 | `PlayCardEvent` | `(player, cardInstanceId, target)` | Rate limited ("Combat"). Authoritatively verifies card in player's hand and target validity. | None |
| 5 | `PlayerVoteReadyEvent` | `(player)` | Rate limited ("Combat"). Toggles player readiness authoritatively. | None |
| 6 | `RescueTeammateEvent` | `(player, targetUserId)` | Rate limited ("Combat"). Verifies 2 Energy cost, downed teammate, and proximity. | None |
| 7 | `ClaimRewardCardEvent` | `(player, cardDefId)` | Rate limited ("General"). Validates card was actually offered in authoritative pending draft. Single-claim guarded. | None |
| 8 | `ContinueFromRewardsEvent` | `(player)` | Rate limited ("General"). Verifies draft completion before proceeding. | None |
| 9 | `RequestStateSyncEvent` | `(player)` | Rate limited ("General"). Read-only; pushes run/combat snapshots to caller. | None |
| 10 | `EquipEquipmentEvent` | `(player, equipInstanceId)` | Rate limited ("General"). Verifies non-empty string ID, presence in `EquipmentInventory`, owner match, and slot match. | None |
| 11 | `UnequipEquipmentEvent` | `(player, slot)` | Rate limited ("General"). Verifies slot in `VALID_EQUIPMENT_SLOTS`, authoritatively returns item to inventory. | None |
| 12 | `EquipSkillEvent` | `(player, skillIdentifier, slot)` | Rate limited ("General"). Verifies non-empty string ID, slot in `VALID_SKILL_SLOTS`, looks up owned instance via `getOwnedSkill`. Never instantiates unowned skills. | None |
| 13 | `UnequipSkillEvent` | `(player, slot)` | Rate limited ("General"). Verifies slot in `VALID_SKILL_SLOTS`, authoritatively clears slot while preserving cooldown in inventory. | None |
| 14 | `UnlockPassiveEvent` | `(player, nodeId)` | Rate limited ("General"). Validates canonical node definition in `PassiveData`, verifies sufficient `PassivePoints` and unlocked prerequisites in `PassiveService`. | None |
| 15 | `UnlockSkillEvent` | `(player, skillDefId)` | Rate limited ("General"). Validates canonical skill definition in `SkillData`, verifies class requirements, provisions into `SkillInventory`. | None |
| 16 | `UseSkillEvent` | `(player, slot, targetParam)` | Rate limited ("Combat"). Verifies slot in `VALID_SKILL_SLOTS`, transactional cost/cooldown pre-validation, target resolution pre-check. | None |

---

## 4. Verification & Testing Matrix

### 4.1 Test Suite 51 (TestRunner.luau)
Suite 51 executes comprehensive integration assertions covering:
- `UnlockSkillEvent` RemoteEvent registration.
- Whitelist slot contracts (`VALID_EQUIPMENT_SLOTS` and `VALID_SKILL_SLOTS`) rejecting malformed types, non-strings, empty strings, and out-of-range enums.
- Equipping valid but unowned skill definition -> `getOwnedSkill` returns `nil`, `equipSkill` rejects with `"unlocked"`, 0 state mutations.
- Equipping invalid skill definition -> `getOwnedSkill` returns `nil`, `equipSkill` rejects, 0 state mutations.
- Equipping foreign player's skill -> `getOwnedSkill` on requester returns `nil`, direct call to `equipSkill` rejects with `"does not match player"`, 0 state mutations.
- Authoritative skill unlock via `SkillService.unlockSkill` -> successfully provisions instance into `SkillInventory`, resolvable by definition ID and instance ID.
- Equipping valid owned skill -> succeeds, correctly slotted in `EquippedSkills`.
- Repeated equip of same instance in same slot -> succeeds idempotently without duplication.
- Repeated equip of same instance into another slot -> rejected with `"already equipped"`, slot remains empty.
- Fabricated equipment instance ID -> rejected with `"not found in player's inventory"`.
- Forged equipment instance object -> rejected with `"not found in player's inventory"`.
- Foreign equipment owner mismatch -> rejected with `"does not match player"`.
- Forged equipment slot mismatch -> rejected with `"Forged slot"`.
- Legitimate inventory equipment -> equip succeeds cleanly.
- Invalid argument types (number, boolean, table) -> safely rejected without runtime exceptions.
- Snapshot consistency -> `RunManager.getRunSnapshotForPlayer` serializes complete and accurate `PlayerView` (`EquippedItems`, `EquippedSkills`, `SkillInventory`, `UnlockedPassives`, `PassivePoints`).

### 4.2 Automated Python Verifier (Check 43)
- Verifies `SkillInventory` added to `PlayerState`.
- Verifies `EquippedSkills`, `SkillInventory`, `UnlockedPassives`, and `PassivePoints` present in `PlayerView`.
- Verifies `SkillService.getOwnedSkill` exists and is called in `init.server.luau`.
- Verifies 0 occurrences of `SkillService.createInstance` in `init.server.luau`.
- Verifies 0 occurrences of `bypassInventoryCheck` across `EquipmentService.luau`.
- Verifies `VALID_EQUIPMENT_SLOTS` and `VALID_SKILL_SLOTS` in `init.server.luau`.
- Verifies `NetworkService.UnlockSkillEvent` registered and wired.
- Verifies all 25 Suite 51 assertions in `TestRunner.luau`.

### 4.3 Results Summary
- **Total Test Suites**: 51 suites (Suites 1–51).
- **Total Verifier Logic Checks**: 432 / 432 checks passed (100% success).
- **Rojo Build**: Successfully compiles to `test.rbxl` with 0 errors.
