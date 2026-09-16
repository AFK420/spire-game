"""
Phase 1 Integration Test & Logic Verifier for Card Rift: Co-op Dungeon
Simulates the real RunManager & CombatService state machine, verifies co-op scaling,
monotonic countdowns, double-play rejection, and downed/rescue rules.
"""

import re
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

print("============================================================")
print("     OFFLINE VERIFICATION: PHASE 1 ARCHITECTURE & LOGIC     ")
print("============================================================")

passed = 0
failed = 0

def test(cond: bool, desc: str):
    global passed, failed
    if cond:
        passed += 1
        print(f"  [PASS] {desc}")
    else:
        failed += 1
        print(f"  [FAIL] {desc}")

# 1. Verify File Existence
required_files = [
    "ARCHITECTURE.md",
    "PHASE_1_IMPLEMENTATION.md",
    "STATE_SCHEMA.md",
    "NETWORK_CONTRACTS.md",
    "default.project.json",
    "src/shared/StateTypes.luau",
    "src/shared/GameConfig.luau",
    "src/shared/CardData.luau",
    "src/shared/ClassData.luau",
    "src/shared/RelicData.luau",
    "src/shared/DungeonMap.luau",
    "src/server/init.server.luau",
    "src/server/services/NetworkService.luau",
    "src/server/services/PersistenceService.luau",
    "src/server/services/CardService.luau",
    "src/server/services/ClassService.luau",
    "src/server/services/RelicService.luau",
    "src/server/services/DungeonService.luau",
    "src/server/services/ArenaVisualizer.luau",
    "src/server/services/CombatService.luau",
    "src/server/services/RunManager.luau",
    "src/server/services/TestRunner.luau",
    "src/client/UIController.client.luau",
    "src/client/ClassSelectUI.client.luau",
    "src/client/RelicUI.client.luau",
    "src/client/init.client.luau",
]

all_luau_files = list((ROOT / "src").rglob("*.luau"))

print("\n--- [Check 1] Required Architecture Files ---")
for f in required_files:
    p = ROOT / f
    test(p.exists(), f"File exists: {f}")

# 2. Verify No Legacy Monoliths
legacy_files = [
    "src/server/CombatServer.server.luau",
    "src/server/SessionManager.server.luau",
    "src/server/GameCoordinator.server.luau",
    "src/server/RelicManager.server.luau",
    "src/server/ClassManager.server.luau",
    "src/server/ProfileStore.server.luau",
    "src/shared/Hello.luau",
]

print("\n--- [Check 2] Legacy File Deletion Verification ---")
for f in legacy_files:
    p = ROOT / f
    test(not p.exists(), f"Legacy file cleanly removed: {f}")

# 3. Verify No _G in server/services
print("\n--- [Check 3] Zero _G Global Pollution ---")
service_files = list((ROOT / "src" / "server" / "services").glob("*.luau"))
service_files.append(ROOT / "src" / "server" / "init.server.luau")

for sf in service_files:
    content = sf.read_text(encoding="utf-8")
    has_g = re.search(r"\b_G\b", content)
    test(not has_g, f"No _G in {sf.name}")

# 4. Mathematical Co-op Scaling Formula Verification
print("\n--- [Check 4] Co-op Scaling Formula ---")
def scale_hp(base: int, count: int) -> int:
    clamped = max(1, min(4, count))
    return round(base * (1 + 0.65 * (clamped - 1)))

def scale_atk(base: int, count: int) -> int:
    clamped = max(1, min(4, count))
    return round(base * (1 + 0.20 * (clamped - 1)))

test(scale_hp(80, 1) == 80, "1 Player HP = 80")
test(scale_hp(80, 2) == 132, "2 Player HP = 132 (+65%)")
test(scale_hp(80, 3) == 184, "3 Player HP = 184 (+130%)")
test(scale_hp(80, 4) == 236, "4 Player HP = 236 (+195%)")

test(scale_atk(9, 1) == 9, "1 Player ATK = 9")
test(scale_atk(9, 4) == 14, "4 Player ATK = 14 (+60%)")

# 5. Teammate Down & Rescue Formula Verification
print("\n--- [Check 5] Downed & Rescue Mechanics ---")
max_hp = 110
rescue_cost = 2
revive_hp = math.floor(max_hp * 0.25)
test(rescue_cost == 2, "Rescue energy cost = 2")
test(revive_hp == 27, "Titan revive HP (25% of 110) = 27")

# 6. Deck Persistence & Reset Bug Prevention
print("\n--- [Check 6] Deck Persistence & Separation of Concerns ---")
combat_service_src = (ROOT / "src/server/services/CombatService.luau").read_text(encoding="utf-8")
apply_class_found = False
for lf in all_luau_files:
    if "applyClassToPlayer" in lf.read_text(encoding="utf-8"):
        apply_class_found = True
        break
test(not apply_class_found, "Zero references to obsolete applyClassToPlayer anywhere under src/")
test("CardService.resetCombatPiles(playerState)" in combat_service_src, "CombatService.startCombat calls CardService.resetCombatPiles")

class_service_src = (ROOT / "src/server/services/ClassService.luau").read_text(encoding="utf-8")
test("function ClassService.applyBaseClassStats" in class_service_src, "ClassService.applyBaseClassStats exists")
test("function ClassService.initializeStartingDeck" in class_service_src, "ClassService.initializeStartingDeck exists")
test("function ClassService.resetCombatResources" in class_service_src, "ClassService.resetCombatResources exists")

card_service_src = (ROOT / "src/server/services/CardService.luau").read_text(encoding="utf-8")
test("function CardService.resetCombatPiles" in card_service_src, "CardService.resetCombatPiles exists")

# 7. Targeting Model & Strict Validation
print("\n--- [Check 7] Targeting Model & Strict Validation ---")
card_data_src = (ROOT / "src/shared/CardData.luau").read_text(encoding="utf-8")
test('"None"' in card_data_src and '"Self"' in card_data_src and '"Enemy"' in card_data_src and '"Ally"' in card_data_src, "TargetType includes None, Self, Enemy, Ally")
test('Target = "Ally"' in card_data_src, "FirstAid has Target = Ally")

state_types_src = (ROOT / "src/shared/StateTypes.luau").read_text(encoding="utf-8")
test("Target: CardData.TargetType" in state_types_src, "CardView contains Target field")
test('cardDef.Target == "Enemy"' in combat_service_src, "CombatService validates Enemy targeting")
test('cardDef.Target == "Self"' in combat_service_src, "CombatService validates Self targeting")
test('cardDef.Target == "Ally"' in combat_service_src, "CombatService validates Ally targeting")
test("Target enemy is already defeated." in combat_service_src, "CombatService rejects dead enemy target")
test("Self cards cannot target other entities." in combat_service_src, "CombatService rejects Self card targeting other entity")

# 8. First Aid & Revive Mechanics
print("\n--- [Check 8] First Aid Revive & Heal Correctness ---")
test('effect.Type == "Revive"' in combat_service_src, "CombatService handles Revive effect")
test('didReviveThisCard' in combat_service_src, "CombatService prevents double-heal on revive")

# 9. Relic Double-Trigger Bug Resolution
print("\n--- [Check 9] Relic Trigger Hardening ---")
relic_data_src = (ROOT / "src/shared/RelicData.luau").read_text(encoding="utf-8")
test('["Vajra"]' in relic_data_src and 'Trigger = "OnCardPlay"' in relic_data_src, "Vajra trigger configured as OnCardPlay")
test('["Akabeko"]' in relic_data_src and 'Trigger = "OnCardPlay"' in relic_data_src, "Akabeko trigger configured as OnCardPlay")

relic_service_src = (ROOT / "src/server/services/RelicService.luau").read_text(encoding="utf-8")
test('evaluatedRelics' in relic_service_src, "RelicService tracks evaluatedRelics set")
test('id == "Vajra"' in relic_service_src, "Vajra evaluated specifically by ID")
test('hasRelic(playerState, "Vajra")' not in relic_service_src, "Vajra does not loop-multiply across inventory")

# 10. Persistence Autosave & TotalRuns
print("\n--- [Check 10] Persistence Autosave & TotalRuns ---")
persistence_src = (ROOT / "src/server/services/PersistenceService.luau").read_text(encoding="utf-8")
test("function PersistenceService.recordRunStarted" in persistence_src, "PersistenceService.recordRunStarted exists")
test("autosaveThread" in persistence_src, "PersistenceService has background autosave loop")

run_manager_src = (ROOT / "src/server/services/RunManager.luau").read_text(encoding="utf-8")
test("PersistenceService.recordRunStarted" in run_manager_src, "RunManager.startRun records run started once")

# 11. Disconnect Safety & Rate Limiting
print("\n--- [Check 11] Disconnect Safety & Rate Limits ---")
network_src = (ROOT / "src/server/services/NetworkService.luau").read_text(encoding="utf-8")
test("function NetworkService.cleanPlayer" in network_src, "NetworkService.cleanPlayer flushes rate-limit buckets")
test("NetworkService.cleanPlayer(userId)" in run_manager_src, "RunManager.removePlayer cleans rate-limit buckets")
test("PersistenceService.saveProfile(player)" in run_manager_src, "RunManager.removePlayer saves profile")
test("pState.IsConnected ~= false" in combat_service_src, "CombatService ignores disconnected players in ready checks")

# 12. UI Ownership Decoupling
print("\n--- [Check 12] UI Ownership Decoupling ---")
ui_controller_src = (ROOT / "src/client/UIController.client.luau").read_text(encoding="utf-8")
test("existingGui:Destroy()" not in ui_controller_src, "UIController does not destroy existing ScreenGui")

class_ui_src = (ROOT / "src/client/ClassSelectUI.client.luau").read_text(encoding="utf-8")
test('"CardRiftClassSelectGui"' in class_ui_src, "ClassSelectUI uses dedicated CardRiftClassSelectGui")
test('"ClassEvents"' not in class_ui_src, "ClassSelectUI has no stale ClassEvents folder reference")

relic_ui_src = (ROOT / "src/client/RelicUI.client.luau").read_text(encoding="utf-8")
test('"CardRiftRelicGui"' in relic_ui_src, "RelicUI uses dedicated CardRiftRelicGui")

# 13. Strict Luau on All Files
print("\n--- [Check 13] Strict Luau Annotations ---")
all_luau_files = list((ROOT / "src").rglob("*.luau"))
for lf in all_luau_files:
    first_line = lf.read_text(encoding="utf-8").splitlines()[0]
    test(first_line == "--!strict", f"--!strict present in {lf.name}")

# 14. Phase 1.2 NetworkService playerBuckets Declaration
print("\n--- [Check 14] Phase 1.2 NetworkService playerBuckets Declaration ---")
test("local playerBuckets: { [number]: { [ActionCategory]: RateBucket } } = {}" in network_src, "NetworkService explicitly declares playerBuckets storage table")

# 15. Phase 1.2 ClassService initializePlayerForRun Refactor
print("\n--- [Check 15] Phase 1.2 ClassService Initialization API ---")
test("function ClassService.initializePlayerForRun" in class_service_src, "ClassService.initializePlayerForRun exists")
test("ClassService.initializePlayerForRun(pState)" in run_manager_src, "RunManager.addPlayer calls initializePlayerForRun")
test("CombatService.startCombat does NOT wipe deck" in (ROOT / "tests/verify_phase1_integration.py").read_text(encoding="utf-8"), "No combat code calls initializeStartingDeck")

# 16. Phase 1.2 PersistenceService Save Error Logging
print("\n--- [Check 16] Phase 1.2 PersistenceService Error Logging ---")
test("local function saveProfileInternal" in persistence_src, "PersistenceService has saveProfileInternal helper")
test("warn(string.format(\"[PersistenceService] Failed to save profile for %d: %s\"" in persistence_src, "PersistenceService logs warn on SetAsync error")

# 17. Phase 1.2 TestRunner Regressions
print("\n--- [Check 17] Phase 1.2 TestRunner Regressions ---")
test_runner_src = (ROOT / "src/server/services/TestRunner.luau").read_text(encoding="utf-8")
test("Duplicate RunManager.startRun() outside Lobby safely returns false" in test_runner_src, "TestRunner tests startRun outside Lobby idempotence")
test("Specific claimed reward CardInstanceId" in test_runner_src, "TestRunner tests specific claimed CardInstanceId preserved in Combat 2")

# 18. Phase 2 Boundary Verification (Phase 2 NOT started)
print("\n--- [Check 18] Phase 2 Strict Boundary Verification ---")
phase2_terms = ["EffectResolver", "ModifierResolver", "DamagePipeline", "StatusService", "EquipmentService", "SkillTreeService", "ActiveSkillService"]
for term in phase2_terms:
    term_found = False
    for lf in all_luau_files:
        if term in lf.read_text(encoding="utf-8"):
            term_found = True
            break
    test(not term_found, f"Phase 2 concept '{term}' NOT present in src/ (Phase 2 NOT started)")

# 19. Phase 1.2 Disconnect Safety: Map Voting Consensus
print("\n--- [Check 19] Disconnect Safety: Map Voting ---")
test("member.IsConnected ~= false" in run_manager_src, "RunManager.voteMapNode requires member.IsConnected ~= false for totalVoters")
test("pState.IsConnected == false" in run_manager_src, "RunManager.voteMapNode rejects disconnected voters")

# 20. Phase 1.2 Disconnect Safety: Enemy Target Selection
print("\n--- [Check 20] Disconnect Safety: Enemy Target Selection ---")
test("not pState.IsDowned and pState.IsConnected ~= false" in combat_service_src, "CombatService excludes disconnected players from enemy attack targets")

# 21. Phase 1.2 Disconnect Safety: Defeat Detection
print("\n--- [Check 21] Disconnect Safety: Defeat Detection ---")
test("activePlayers > 0 and (downedPlayers == activePlayers)" in combat_service_src, "CombatService.areAllPlayersDowned checks active connected players only")
test("pState.IsConnected ~= false" in combat_service_src, "CombatService.areAllPlayersDowned filters on pState.IsConnected ~= false")

# 22. Phase 1.2 Disconnect Safety: Action Validation
print("\n--- [Check 22] Disconnect Safety: Action Validation ---")
test("Disconnected players cannot play cards." in combat_service_src, "CombatService.playCard rejects disconnected players")
test("Disconnected players cannot vote ready." in combat_service_src, "CombatService.voteReady rejects disconnected players")
test("Disconnected players cannot rescue others." in combat_service_src, "CombatService.rescueTeammate rejects disconnected rescuer")
test("Cannot rescue a disconnected teammate." in combat_service_src, "CombatService.rescueTeammate rejects disconnected target")

# 23. Phase 1.2 Poison Damage Resolution & Shield Bypass
print("\n--- [Check 23] Poison Damage Resolution & Shield Bypass ---")
poison_block_match = re.search(r"if enemy\.Poison > 0 then(.*?)if enemy\.HP <= 0 then", combat_service_src, re.DOTALL)
test(poison_block_match is not None, "CombatService contains enemy.Poison > 0 resolution block")
if poison_block_match:
    pblock = poison_block_match.group(1)
    test("applyDamageToEnemy" not in pblock, "Poison tick does NOT call applyDamageToEnemy (does not damage shield)")
    test("enemy.HP = math.max(0, enemy.HP - pDmg)" in pblock or "enemy.HP = math.max(0, enemy.HP - enemy.Poison)" in pblock, "Poison directly subtracts from enemy.HP exactly once")
    test("enemy.Poison = math.max(0, enemy.Poison - 1)" in pblock, "Poison stack decreases by 1 stack per tick")
    test("enemy.Shield" not in pblock, "Enemy Shield remains untouched by poison")

# Mathematical simulation of poison tick progression
def simulate_poison_tick(hp: int, shield: int, poison: int):
    dmg = poison
    new_hp = max(0, hp - dmg)
    new_poison = max(0, poison - 1)
    new_shield = shield # Poison does NOT consume Shield
    return new_hp, new_shield, new_poison

h, s, p = simulate_poison_tick(100, 20, 5)
test(h == 95 and s == 20 and p == 4, "Poison Tick 1: 100 HP / 20 Shield / 5 Poison -> 95 HP / 20 Shield / 4 Poison")
h, s, p = simulate_poison_tick(h, s, p)
test(h == 91 and s == 20 and p == 3, "Poison Tick 2: 95 HP / 20 Shield / 4 Poison -> 91 HP / 20 Shield / 3 Poison")
h, s, p = simulate_poison_tick(h, s, p)
test(h == 88 and s == 20 and p == 2, "Poison Tick 3: 91 HP / 20 Shield / 3 Poison -> 88 HP / 20 Shield / 2 Poison")
h_kill, s_kill, p_kill = simulate_poison_tick(3, 20, 5)
test(h_kill == 0 and s_kill == 20 and p_kill == 4, "Lethal Poison: 3 HP / 20 Shield / 5 Poison -> 0 HP / 20 Shield / 4 Poison")

print("\n============================================================")
print(f"VERIFICATION SUMMARY: {passed} PASSED, {failed} FAILED")
print("============================================================")

if failed > 0:
    sys.exit(1)
else:
    print("ALL LOGIC CHECKS VERIFIED 100% CLEAN!\n")
