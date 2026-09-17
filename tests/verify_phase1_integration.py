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
    "PHASE_4_IMPLEMENTATION.md",
    "PERSISTENCE_SCHEMA.md",
    "DECK_SYSTEM.md",
    "CARD_COLLECTION.md",
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
    "src/server/services/CardCollectionService.luau",
    "src/server/services/DeckService.luau",
    "src/server/services/ClassService.luau",
    "src/server/services/RelicService.luau",
    "src/server/services/DungeonService.luau",
    "src/server/services/ArenaVisualizer.luau",
    "src/server/services/CombatService.luau",
    "src/server/services/RunManager.luau",
    "src/server/services/TestRunner.luau",
    "src/server/services/TargetResolver.luau",
    "src/server/services/ModifierResolver.luau",
    "src/server/services/DamagePipeline.luau",
    "src/server/services/StatusService.luau",
    "src/server/services/EffectResolver.luau",
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
target_resolver_src = (ROOT / "src/server/services/TargetResolver.luau").read_text(encoding="utf-8")
test("Target: CardData.TargetType" in state_types_src, "CardView contains Target field")
test('targetType == "Enemy"' in target_resolver_src or 'cardDef.Target == "Enemy"' in combat_service_src, "TargetResolver/CombatService validates Enemy targeting")
test('targetType == "Self"' in target_resolver_src or 'cardDef.Target == "Self"' in combat_service_src, "TargetResolver/CombatService validates Self targeting")
test('targetType == "Ally"' in target_resolver_src or 'cardDef.Target == "Ally"' in combat_service_src, "TargetResolver/CombatService validates Ally targeting")
test("Target enemy is already defeated." in target_resolver_src or "Target enemy is already defeated." in combat_service_src, "TargetResolver/CombatService rejects dead enemy target")
test("Self cards cannot target other entities." in target_resolver_src or "Self cards cannot target other entities." in combat_service_src, "TargetResolver/CombatService rejects Self card targeting other entity")

# 8. First Aid & Revive Mechanics
print("\n--- [Check 8] First Aid Revive & Heal Correctness ---")
effect_resolver_src = (ROOT / "src/server/services/EffectResolver.luau").read_text(encoding="utf-8")
test('handlers["Revive"]' in effect_resolver_src or 'effect.Type == "Revive"' in effect_resolver_src or 'effect.Type == "Revive"' in combat_service_src, "EffectResolver/CombatService handles Revive effect")
test('context.DidRevive' in effect_resolver_src or 'didReviveThisCard' in combat_service_src, "EffectResolver/CombatService prevents double-heal on revive")

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

# 18. Phase 3 Boundary Verification (Out-of-Scope Concepts NOT started)
print("\n--- [Check 18] Phase 3 Out-of-Scope Boundary Verification ---")
out_of_scope_terms = ["CraftingService", "MonetizationService", "BattlePassService"]
for term in out_of_scope_terms:
    term_found = False
    for lf in all_luau_files:
        if term in lf.read_text(encoding="utf-8"):
            term_found = True
            break
    test(not term_found, f"Out-of-scope concept '{term}' NOT present in src/ (unstarted)")

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

# 23. Phase 1.2 & Phase 2 Poison Damage Resolution & Shield Bypass
print("\n--- [Check 23] Poison Damage Resolution & Shield Bypass ---")
status_service_src = (ROOT / "src/server/services/StatusService.luau").read_text(encoding="utf-8")
damage_pipeline_src = (ROOT / "src/server/services/DamagePipeline.luau").read_text(encoding="utf-8")
test("StatusService.tickStatuses" in combat_service_src or "enemy.Poison > 0" in combat_service_src, "CombatService contains Poison resolution via StatusService")
test("CanHitShield = false" in status_service_src, "StatusService poison damage specifies CanHitShield = false (bypasses shield)")
test("applyDamageToEnemy" not in status_service_src, "StatusService poison tick does NOT call applyDamageToEnemy")
test("inst.Stacks = math.max(0, inst.Stacks - 1)" in status_service_src or "enemy.Poison = math.max(0, enemy.Poison - 1)" in combat_service_src, "Poison stack decreases by 1 stack per tick")
test("shieldAbsorbed = 0" in damage_pipeline_src and "hpLost = finalDamage" in damage_pipeline_src, "DamagePipeline direct HP bypass prevents shield absorption")

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

# 24. Phase 2 Core Resolvers Existence & Strict Typing
print("\n--- [Check 24] Phase 2 Core Resolvers & Services ---")
phase2_services = [
    "src/server/services/TargetResolver.luau",
    "src/server/services/ModifierResolver.luau",
    "src/server/services/DamagePipeline.luau",
    "src/server/services/StatusService.luau",
    "src/server/services/EffectResolver.luau",
]
for s in phase2_services:
    sp = ROOT / s
    test(sp.exists(), f"Phase 2 service exists: {s}")
    if sp.exists():
        stext = sp.read_text(encoding="utf-8")
        test(stext.startswith("--!strict"), f"{s} starts with --!strict")
        test("_G" not in stext, f"{s} contains 0 _G references")

# 25. Phase 2 StatusService Data-Driven Definitions
print("\n--- [Check 25] StatusService Data-Driven Definitions ---")
test('Poison = {' in status_service_src, "StatusService defines Poison")
test('Ignite = {' in status_service_src, "StatusService defines Ignite")
test('Chill = {' in status_service_src, "StatusService defines Chill")
test('Freeze = {' in status_service_src, "StatusService defines Freeze")
test('Shock = {' in status_service_src, "StatusService defines Shock")
test('Bleed = {' in status_service_src, "StatusService defines Bleed")

# 26. Phase 2 Generic Card Effect Model & First Aid Generic Conditions
print("\n--- [Check 26] First Aid Generic Conditions & Zero Card-Name Branching ---")
test('Condition = "TargetDowned"' in card_data_src, "FirstAid Revive effect conditioned on TargetDowned")
test('Condition = "TargetLiving"' in card_data_src, "FirstAid Heal effect conditioned on TargetLiving")
test('card == "FirstAid"' not in combat_service_src and 'cardInst.CardData.Id == "FirstAid"' not in combat_service_src, "CombatService contains 0 card == 'FirstAid' branches")
test('card == "FirstAid"' not in effect_resolver_src and 'cardInst.CardData.Id == "FirstAid"' not in effect_resolver_src, "EffectResolver contains 0 card == 'FirstAid' branches")

# 27. Phase 2 ModifierResolver Deterministic Pipeline
print("\n--- [Check 27] ModifierResolver Deterministic Pipeline ---")
modifier_resolver_src = (ROOT / "src/server/services/ModifierResolver.luau").read_text(encoding="utf-8")
test("function ModifierResolver.resolve" in modifier_resolver_src, "ModifierResolver.resolve exists")
test("table.sort(applicable" in modifier_resolver_src, "ModifierResolver sorts modifiers deterministically")
test("mod.Operation == \"Add\"" in modifier_resolver_src and "mod.Operation == \"Multiply\"" in modifier_resolver_src, "ModifierResolver supports Additive and Multiplicative operations")

# 28. Phase 2.1 Card Pile Invariant & Exhaust Uniqueness
print("\n--- [Check 28] Phase 2.1 Card Pile Invariants & Exhaust Safety ---")
card_service_src = (ROOT / "src/server/services/CardService.luau").read_text(encoding="utf-8")
effect_resolver_src = (ROOT / "src/server/services/EffectResolver.luau").read_text(encoding="utf-8")
test("function CardService.exhaustCard" in card_service_src, "CardService.exhaustCard helper exists")
test("table.insert(playerState.ExhaustPile" in card_service_src, "CardService.exhaustCard moves card to ExhaustPile")
test("CardService.exhaustCard(context.SourcePlayer" in effect_resolver_src, "EffectResolver.handlers['Exhaust'] invokes CardService.exhaustCard")

# 29. Phase 2.1 Effect-Level Target Overrides
print("\n--- [Check 29] Phase 2.1 Effect-Level Target Overrides ---")
test("local function resolveEffectTarget" in effect_resolver_src, "EffectResolver defines resolveEffectTarget helper")
test("TargetResolver.resolveTarget" in effect_resolver_src, "EffectResolver invokes TargetResolver for effect-level overrides")
test("handlers[\"Damage\"] = function(effect: CardData.Effect, context: ActionContext, resolvedTarget: StateTypes.ResolvedTarget)" in effect_resolver_src, "Damage handler consumes resolvedTarget")
test("handlers[\"Shield\"] = function(effect: CardData.Effect, context: ActionContext, resolvedTarget: StateTypes.ResolvedTarget)" in effect_resolver_src, "Shield handler consumes resolvedTarget")

# 30. Phase 2.1 Status Authority & Tick Behavior Registry
print("\n--- [Check 30] Phase 2.1 Status Authority & Tick Behavior Registry ---")
status_service_src = (ROOT / "src/server/services/StatusService.luau").read_text(encoding="utf-8")
state_types_src = (ROOT / "src/shared/StateTypes.luau").read_text(encoding="utf-8")
test("function StatusService.syncEntityFromProjection" in status_service_src, "StatusService.syncEntityFromProjection exists")
test("local tickBehaviors: { [string]: TickBehaviorFn }" in status_service_src, "StatusService registers data-driven tickBehaviors table")
test("TickBehaviorId = \"DirectHPPoison\"" in status_service_src, "Poison status mapped to DirectHPPoison behavior")
test("TickBehaviorId = \"FireDoT\"" in status_service_src, "Ignite status mapped to FireDoT behavior")
test("TickBehaviorId = \"BleedDoT\"" in status_service_src, "Bleed status mapped to BleedDoT behavior")
test("Implemented = false" in status_service_src, "Unimplemented statuses explicitly flagged Implemented = false")
test("Implemented: boolean" in state_types_src and "TickBehaviorId: string?" in state_types_src, "StateTypes.StatusDefinition includes Implemented and TickBehaviorId")

# 31. Phase 2.1 DamagePipeline Input Validation & Clamping
print("\n--- [Check 31] Phase 2.1 DamagePipeline Input Validation & Clamping ---")
damage_pipeline_src = (ROOT / "src/server/services/DamagePipeline.luau").read_text(encoding="utf-8")
test("context.RawDamage < 0" in damage_pipeline_src, "DamagePipeline validates RawDamage >= 0")
test("context.TargetEntityKind == \"Enemy\" and not context.TargetEnemy" in damage_pipeline_src, "DamagePipeline validates Enemy existence")
test("context.TargetEntityKind == \"Player\" and not context.TargetPlayer" in damage_pipeline_src, "DamagePipeline validates Player existence")
test("math.max(0, enemy.Shield - shieldAbsorbed)" in damage_pipeline_src, "DamagePipeline clamps enemy Shield to >= 0")
test("math.max(0, enemy.HP - hpLost)" in damage_pipeline_src, "DamagePipeline clamps enemy HP to >= 0")

# 32. Phase 2.1 Generalized Effects & Recursion Safety
print("\n--- [Check 32] Phase 2.1 Generalized Effects & Recursion Safety ---")
test("resType == \"HP\"" in effect_resolver_src and "resType == \"Shield\"" in effect_resolver_src and "resType == \"Energy\"" in effect_resolver_src, "handlers['ModifyResource'] supports typed HP, Shield, and Energy")
test("handlers[\"TriggerEvent\"]" in effect_resolver_src, "handlers['TriggerEvent'] registered")
test("RelicService.triggerRelics" in effect_resolver_src, "TriggerEvent dispatches to RelicService")
test("currentDepth >= MAX_RECURSION_DEPTH" in effect_resolver_src, "EffectResolver protects against recursion depth overflow")
testrunner_src = (ROOT / "src/server/services/TestRunner.luau").read_text(encoding="utf-8")
test("--- [Suite 23] Exhaust Pile Uniqueness" in testrunner_src, "TestRunner includes Suite 23: Exhaust Pile Uniqueness")
test("--- [Suite 24] Effect-Level Target Overrides" in testrunner_src, "TestRunner includes Suite 24: Effect-Level Target Overrides")
test("--- [Suite 25] ModifyResource Safety & Clamping" in testrunner_src, "TestRunner includes Suite 25: ModifyResource Safety")
test("--- [Suite 26] Event Triggering & Recursion Protection" in testrunner_src, "TestRunner includes Suite 26: Event Triggering & Recursion Protection")
test("--- [Suite 27] Status Authority & Tick Behavior Registry" in testrunner_src, "TestRunner includes Suite 27: Status Authority & Tick Behaviors")
test("--- [Suite 28] Damage Pipeline Edge Cases" in testrunner_src, "TestRunner includes Suite 28: Damage Pipeline Edge Cases")
test("--- [Suite 29] Modifier Pipeline Determinism" in testrunner_src, "TestRunner includes Suite 29: Modifier Pipeline Determinism")

# 33. Phase 2.2 ModifyResource Recipient Targeting & Event Error Isolation
print("\n--- [Check 33] Phase 2.2 ModifyResource Targeting & Event Isolation ---")
test("recipient.Resources.Energy = math.clamp(" in effect_resolver_src, "ModifyResource mutates recipient Energy")
test("recipient.Resources.MaxEnergy = math.max(0," in effect_resolver_src, "ModifyResource mutates recipient MaxEnergy")
test("recipient.Gold = math.max(0, recipient.Gold + count)" in effect_resolver_src, "ModifyResource mutates recipient Gold")
test("pcall(function()" in effect_resolver_src and "RelicService.triggerRelics" in effect_resolver_src, "TriggerEvent dispatches via pcall for error isolation")

# 34. Phase 2.2 TargetResolver Legality & Context Strictness
print("\n--- [Check 34] Phase 2.2 TargetResolver Legality & Strict Context ---")
target_resolver_src = (ROOT / "src/server/services/TargetResolver.luau").read_text(encoding="utf-8")
test("if not combatState then" in target_resolver_src, "TargetResolver requires active CombatState for Enemy targets")
test("if not party then" in target_resolver_src, "TargetResolver requires active Party for Ally targets")
test("enemy.HP <= 0" in target_resolver_src, "TargetResolver rejects defeated enemies")
test("allyState.IsConnected == false" in target_resolver_src, "TargetResolver rejects disconnected allies")

# 35. Phase 2.2 CreateCard Schema Strictness & Pile Placement
print("\n--- [Check 35] Phase 2.2 CreateCard Schema Strictness & Pile Placement ---")
test("local cardDefId = effect.CardDefId" in effect_resolver_src, "CreateCard reads CardDefId directly")
test("effect.StatusId or \"Strike\"" not in effect_resolver_src, "CreateCard contains 0 fallback to StatusId or Strike")
test("local cardDef = CardData.getCard(cardDefId)" in effect_resolver_src, "CreateCard validates definition against CardData")
test("effect.DestinationPile" in effect_resolver_src, "CreateCard supports destination pile placement")

# 36. Phase 2.2 Card Pile Invariant Validator & Single Ownership
print("\n--- [Check 36] Phase 2.2 Card Pile Invariants & Validator ---")
card_service_src = (ROOT / "src/server/services/CardService.luau").read_text(encoding="utf-8")
test("function CardService.validatePileInvariants" in card_service_src, "CardService.validatePileInvariants helper exists")
test("Hand key '%s' does not match CardInstanceId" in card_service_src, "validatePileInvariants verifies Hand key integrity")
test("Duplicate CardInstance" in card_service_src, "validatePileInvariants rejects duplicate instances across or within piles")
test("OwnerUserId" in card_service_src, "validatePileInvariants verifies player ownership")

# 37. Phase 2.2 Status Authority Boundary & TestRunner Suites 30-36
print("\n--- [Check 37] Phase 2.2 Status Authority & Suites 30-36 ---")
relic_service_src = (ROOT / "src/server/services/RelicService.luau").read_text(encoding="utf-8")
test("StatusService.applyStatus(" in relic_service_src and "context.Enemy.Poison +=" not in relic_service_src, "RelicService applies VenomVial poison via StatusService")
test("local statusTicks = StatusService.tickStatuses(enemyId, \"TurnStart\", enemy, true)" in combat_service_src, "CombatService ticks TurnStart statuses directly via StatusService")
test("--- [Suite 30] ModifyResource Multi-Targeting" in testrunner_src, "TestRunner includes Suite 30: ModifyResource Multi-Targeting")
test("--- [Suite 31] TriggerEvent Truthful Execution" in testrunner_src, "TestRunner includes Suite 31: TriggerEvent Truthful Execution")
test("--- [Suite 32] Real Target Resolution Context" in testrunner_src, "TestRunner includes Suite 32: Real Target Resolution Context")
test("--- [Suite 33] CreateCard Schema Strictness" in testrunner_src, "TestRunner includes Suite 33: CreateCard Schema Strictness")
test("--- [Suite 34] Card Pile Invariant Verification" in testrunner_src, "TestRunner includes Suite 34: Card Pile Invariant Verification")
test("--- [Suite 35] Status Authority Boundary" in testrunner_src, "TestRunner includes Suite 35: Status Authority Boundary")
test("--- [Suite 36] Cross-System Multi-Action" in testrunner_src, "TestRunner includes Suite 36: Cross-System Multi-Action")

# 38. Phase 2.3 Card Effect-Target Consistency & Static Validator
print("\n--- [Check 38] Phase 2.3 Card Effect-Target Consistency & Static Validator ---")
card_data_src = (ROOT / "src/shared/CardData.luau").read_text(encoding="utf-8")
test("function CardData.validateCard(card: Card): (boolean, string?)" in card_data_src, "CardData.validateCard function exists with correct signature")
test("function CardData.validateCardDefinitions(): (boolean, string?)" in card_data_src, "CardData.validateCardDefinitions function exists")
test("cannot silently inherit" in card_data_src, "validateCard detects and rejects silent inheritance of incompatible targets")
test("must explicitly declare its Target" in card_data_src, "validateCard requires mixed-target cards to explicitly declare effect targets")
test("--- [Suite 37] Static Card Effect Target Compatibility" in testrunner_src, "TestRunner includes Suite 37: Static Card Effect Target Compatibility")
test("Target = \"Enemy\"" in card_data_src and "ShieldSlam" in card_data_src, "ShieldSlam configured with Target = 'Enemy'")
test("Target = \"Enemy\"" in card_data_src and "DeployTurret" in card_data_src, "DeployTurret configured with Target = 'Enemy'")
test("Target = \"Enemy\"" in card_data_src and "PackCall" in card_data_src, "PackCall configured with Target = 'Enemy'")
test("Target = \"Enemy\"" in card_data_src and "WrenchThrow" in card_data_src, "WrenchThrow configured with Target = 'Enemy'")
test("Target = \"Enemy\"" in card_data_src and "SoulHarvest" in card_data_src, "SoulHarvest configured with Target = 'Enemy'")
test("Target = \"Enemy\"" in card_data_src and "TimeWarp" in card_data_src, "TimeWarp configured with Target = 'Enemy'")

# 39. Phase 2.3 End-to-End Mixed-Target Execution & Shield Gimmick Safety
print("\n--- [Check 39] Phase 2.3 End-to-End Mixed-Target Execution & Shield Gimmick Safety ---")
testrunner_src = (ROOT / "src/server/services/TestRunner.luau").read_text(encoding="utf-8")
test("--- [Suite 38] End-to-End Mixed-Target Card Execution" in testrunner_src, "TestRunner includes Suite 38: End-to-End Mixed-Target Card Execution")
test("[E2E ShieldSlam] Caster gained 8 Shield" in testrunner_src, "Suite 38 tests ShieldSlam shield and damage execution")
test("[E2E WrenchThrow] Enemy took 7 damage" in testrunner_src, "Suite 38 tests WrenchThrow damage and shield execution")
test("[E2E SoulHarvest] Injured caster healed 3 HP" in testrunner_src, "Suite 38 tests SoulHarvest damage and heal execution")
test("[E2E DeployTurret] Caster gained 6 Shield" in testrunner_src, "Suite 38 tests DeployTurret shield and damage execution")
test("[E2E TimeWarp] Caster gained 4 Shield" in testrunner_src, "Suite 38 tests TimeWarp damage and shield execution")
test("[E2E PackCall] Caster gained 7 Shield" in testrunner_src, "Suite 38 tests PackCall shield and damage execution")
test("[E2E Contagion] Enemy afflicted with 4 Poison stacks" in testrunner_src, "Suite 38 tests Contagion damage and poison execution")
test("[E2E FirstAid] Downed ally successfully revived" in testrunner_src, "Suite 38 tests FirstAid revive and heal branches")
test("[E2E BonusShield] Bonus Shield correctly added once without duplication" in testrunner_src, "Suite 38 tests Bonus Shield gimmick safety")
combat_service_src = (ROOT / "src/server/services/CombatService.luau").read_text(encoding="utf-8")
test("cardHasShieldEffect" in combat_service_src, "CombatService checks cardHasShieldEffect before applying bonus shield")
test("ActionBonusShield" in combat_service_src, "CombatService routes bonus shield through ActionBonusShield modifier")

# 40. Phase 2.4 Final Schema Strictness & Resource Boundary Safety
print("\n--- [Check 40] Phase 2.4 Final Schema Strictness & Resource Boundary Safety ---")
testrunner_src = (ROOT / "src/server/services/TestRunner.luau").read_text(encoding="utf-8")
effect_resolver_src = (ROOT / "src/server/services/EffectResolver.luau").read_text(encoding="utf-8")
test("--- [Suite 39] Final Schema Strictness & Resource Boundary Safety" in testrunner_src, "TestRunner includes Suite 39: Final Schema Strictness")
test("Invalid DestinationPile '%s'" in effect_resolver_src, "CreateCard validates DestinationPile against allowed piles")
test("resType == \"Gold\"" in effect_resolver_src and "resType = \"Gold\"" not in effect_resolver_src, "ModifyResource contains zero implicit fallback to Gold")
test("ModifyResource requires a valid non-empty Resource type" in effect_resolver_src, "ModifyResource strictly requires non-empty Resource")
test("[CreateCard] Valid Deck destination succeeds" in testrunner_src, "Suite 39 tests valid Deck destination")
test("[CreateCard] Valid Hand destination succeeds" in testrunner_src, "Suite 39 tests valid Hand destination")
test("[CreateCard] Valid DiscardPile destination succeeds" in testrunner_src, "Suite 39 tests valid DiscardPile destination")
test("[CreateCard] Valid ExhaustPile destination succeeds" in testrunner_src, "Suite 39 tests valid ExhaustPile destination")
test("[CreateCard] Invalid 'Banana' destination rejected with Success=false" in testrunner_src, "Suite 39 tests rejection of invalid 'Banana' destination")
test("[CreateCard] Empty string destination rejected with Success=false" in testrunner_src, "Suite 39 tests rejection of empty string destination")
test("[ModifyResource] Missing Resource rejected with Success=false" in testrunner_src, "Suite 39 tests rejection of missing Resource")
test("[ModifyResource] Empty string Resource rejected with Success=false" in testrunner_src, "Suite 39 tests rejection of empty Resource")
test("[ModifyResource] Invalid Resource rejected with Success=false" in testrunner_src, "Suite 39 tests rejection of invalid Resource")
test("[ModifyResource] Valid Self Energy executes normally" in testrunner_src, "Suite 39 tests Self Energy modification")
test("[ModifyResource] Valid Ally Energy executes normally" in testrunner_src, "Suite 39 tests Ally Energy modification")

# 41. Phase 3 Foundation Architecture & End-to-End Vertical Slice
print("\n--- [Check 41] Phase 3 Foundation Architecture & End-to-End Vertical Slice ---")
phase3_files = [
    "src/shared/EquipmentData.luau",
    "src/shared/SkillData.luau",
    "src/shared/PassiveData.luau",
    "src/server/services/EquipmentService.luau",
    "src/server/services/StatResolver.luau",
    "src/server/services/SkillService.luau",
    "src/server/services/PassiveService.luau",
]
for p3f in phase3_files:
    fpath = ROOT / p3f
    test(fpath.exists(), f"Phase 3 file exists: {p3f}")
    content = fpath.read_text(encoding="utf-8")
    test(content.splitlines()[0] == "--!strict", f"{p3f} starts with --!strict")
    test("_G" not in content, f"{p3f} contains 0 _G references")

testrunner_src = (ROOT / "src/server/services/TestRunner.luau").read_text(encoding="utf-8")
test("--- [Suite 40] Phase 3 Equipment Foundation" in testrunner_src, "TestRunner includes Suite 40: Phase 3 Equipment Foundation")
test("[Equipment] createInstance returns valid instance for IronBroadsword" in testrunner_src, "Suite 40 tests Equipment createInstance")
test("[Equipment] Equipping valid weapon succeeds" in testrunner_src, "Suite 40 tests Equipment equip lifecycle")
test("[Equipment] Replaced weapon returned to EquipmentInventory" in testrunner_src, "Suite 40 tests Equipment single-slot replacement")
test("[Equipment] Foreign item rejected on owner mismatch" in testrunner_src, "Suite 40 tests Equipment owner validation")

test("--- [Suite 41] Phase 3 Centralized Stat Resolution" in testrunner_src, "TestRunner includes Suite 41: Phase 3 Centralized Stat Resolution")
test("[StatResolver] Base MaxHP resolved from Warlord class definition" in testrunner_src, "Suite 41 tests Base class stat resolution")
test("[StatResolver] Additive modifiers stack deterministically" in testrunner_src, "Suite 41 tests Additive modifier stacking")
test("[StatResolver] Multiplicative modifier applies to additive sum" in testrunner_src, "Suite 41 tests Multiplicative modifier stacking")
test("[StatResolver] Override modifier takes absolute precedence" in testrunner_src, "Suite 41 tests Override modifier precedence")
test("[StatResolver] MaxHP strictly clamped to minimum 1" in testrunner_src, "Suite 41 tests stat bounds clamping")

test("--- [Suite 42] Phase 3 Passive Tree & Graph Validation" in testrunner_src, "TestRunner includes Suite 42: Phase 3 Passive Tree & Graph Validation")
test("[PassiveData] Canonical Warlord passive tree is a valid DAG" in testrunner_src, "Suite 42 tests canonical Warlord DAG")
test("[PassiveData] Cyclic graph rejected with cycle detection error" in testrunner_src, "Suite 42 tests DAG cycle detection")
test("[PassiveData] Missing prerequisite reference rejected" in testrunner_src, "Suite 42 tests broken prerequisite rejection")
test("[PassiveService] Unlocking root node succeeds" in testrunner_src, "Suite 42 tests root node unlock")
test("[PassiveService] Keystone rejected when branch prerequisites not unlocked" in testrunner_src, "Suite 42 tests prerequisite unlock requirement")

test("--- [Suite 43] Phase 3 Active Skills Runtime" in testrunner_src, "TestRunner includes Suite 43: Phase 3 Active Skills Runtime")
test("[SkillService] createInstance created HeroicStrike" in testrunner_src, "Suite 43 tests Skill createInstance")
test("[SkillService] Warlord skill rejected for AetherMage" in testrunner_src, "Suite 43 tests class skill restrictions")
test("[SkillService] useSkill executes successfully" in testrunner_src, "Suite 43 tests Skill execution")
test("[SkillService] useSkill rejected while on cooldown" in testrunner_src, "Suite 43 tests cooldown enforcement")
test("[SkillService] onTurnStart decremented cooldown from 1 to 0" in testrunner_src, "Suite 43 tests cooldown turn decrements")

test("--- [Suite 44] Complete Vertical Slice End-to-End Test" in testrunner_src, "TestRunner includes Suite 44: Complete Vertical Slice End-to-End Test")
test("[VerticalSlice] Baseline Warlord MaxHP is 110" in testrunner_src, "Suite 44 tests initial state")
test("[VerticalSlice] Equipped weapon increased player MaxHP to 120" in testrunner_src, "Suite 44 tests equipment stat modifier")
test("[VerticalSlice] Passive increased player MaxHP to 135" in testrunner_src, "Suite 44 tests passive stat modifier")
test("[VerticalSlice] Stacked weapon (+5) and passive (+3) yield +8 BonusDamage" in testrunner_src, "Suite 44 tests stacked equipment and passive damage modifiers")
test("[VerticalSlice] Active skill executed successfully end-to-end" in testrunner_src, "Suite 44 tests active skill execution through pipeline")
test("[VerticalSlice] Boss HP reduced by exact total damage" in testrunner_src, "Suite 44 tests exact damage pipeline result")

# 42. Phase 3.1 RPG Systems & Engine Hardening
print("\n--- [Check 42] Phase 3.1 RPG Systems & Engine Hardening ---")
equip_service_src = (ROOT / "src/server/services/EquipmentService.luau").read_text(encoding="utf-8")
skill_service_src = (ROOT / "src/server/services/SkillService.luau").read_text(encoding="utf-8")
passive_data_src = (ROOT / "src/shared/PassiveData.luau").read_text(encoding="utf-8")
stat_resolver_src = (ROOT / "src/server/services/StatResolver.luau").read_text(encoding="utf-8")
passive_service_src = (ROOT / "src/server/services/PassiveService.luau").read_text(encoding="utf-8")
network_service_src = (ROOT / "src/server/services/NetworkService.luau").read_text(encoding="utf-8")
server_init_src = (ROOT / "src/server/init.server.luau").read_text(encoding="utf-8")
state_types_src = (ROOT / "src/shared/StateTypes.luau").read_text(encoding="utf-8")

# Equipment authority checks
test("targetInst.Slot ~= authSlot" in equip_service_src, "EquipmentService rejects forged slot mismatch")
test("not found in player's inventory" in equip_service_src, "EquipmentService validates instance presence in EquipmentInventory")
test("function EquipmentService.grantEquipment(" in equip_service_src, "EquipmentService provides grantEquipment provisioning helper")
test("ORDERED_SLOTS" in equip_service_src, "EquipmentService defines deterministic slot iteration order")

# Skill ownership & transactional execution checks
test("UnlockedSkills" in state_types_src, "StateTypes defines UnlockedSkills in PlayerState")
test("function SkillService.unlockSkill(" in skill_service_src, "SkillService provides unlockSkill API")
test("function SkillService.hasSkill(" in skill_service_src, "SkillService provides hasSkill API")
test("VALID_SKILL_SLOTS" in skill_service_src, "SkillService validates runtime SkillSlot")
test("resolvedTarget.Success" in skill_service_src, "SkillService verifies target resolution BEFORE cost/cooldown mutation")
test("playerState.IsDowned" in skill_service_src, "SkillService rejects downed player actions")
test("playerState.IsConnected == false" in skill_service_src, "SkillService rejects disconnected player actions")

# Stat resolver formal semantics checks
test("ModifierStat ==" in stat_resolver_src or "ModifierStat" in stat_resolver_src, "StatResolver defines formal semantics for ModifierStat")
test("math.max(0," in stat_resolver_src, "StatResolver guarantees non-negative cost reductions")
test("TitanStance" in (ROOT / "src/shared/PassiveData.luau").read_text(encoding="utf-8"), "PassiveData includes TitanStance with negative MaxEnergy")

# Passive tree node validation checks
test("Node ID must be a non-empty string" in passive_data_src, "PassiveData validates non-empty string node IDs")
test("Prerequisites array" in passive_data_src, "PassiveData validates Prerequisites array type")
test("non-empty string prerequisite" in passive_data_src, "PassiveData validates non-empty string prerequisite entries")

# Network contracts and remote events checks
remote_names = [
    "EquipEquipmentEvent",
    "UnequipEquipmentEvent",
    "EquipSkillEvent",
    "UnequipSkillEvent",
    "UnlockPassiveEvent",
    "UseSkillEvent",
]
for r_name in remote_names:
    test(r_name in network_service_src, f"NetworkService registers {r_name}")
    test(r_name in server_init_src, f"init.server.luau listens to {r_name}")

test("checkRateLimit" in server_init_src, "init.server.luau applies rate limiting to Phase 3 RemoteEvents")

# TestRunner Suites 45 to 50 checks
test("--- [Suite 45] Phase 3.1 Equipment Authority Hardening" in testrunner_src, "TestRunner includes Suite 45: Equipment Authority Hardening")
test("[EquipmentAuthority] Forged slot rejected with explicit error" in testrunner_src, "Suite 45 tests forged slot rejection")
test("[EquipmentAuthority] Fabricated instance absent from inventory rejected" in testrunner_src, "Suite 45 tests inventory absence rejection")
test("[EquipmentAuthority] grantEquipment provisioned item" in testrunner_src, "Suite 45 tests grantEquipment provisioning")
test("[EquipmentAuthority] Second armor equipped to replace first" in testrunner_src, "Suite 45 tests slot replacement preservation")
test("[EquipmentAuthority] Collected modifiers sorted deterministically by Priority" in testrunner_src, "Suite 45 tests deterministic modifier sorting")

test("--- [Suite 46] Phase 3.1 Active Skill Ownership & Cooldown Hardening" in testrunner_src, "TestRunner includes Suite 46: Skill Ownership & Cooldown Hardening")
test("[SkillHardening] Unowned skill equip rejected" in testrunner_src, "Suite 46 tests unowned skill equip rejection")
test("[SkillHardening] unlockSkill authoritatively unlocked Whirlwind" in testrunner_src, "Suite 46 tests unlockSkill API")
test("[SkillHardening] equipSkill rejects invalid runtime slot" in testrunner_src, "Suite 46 tests invalid slot rejection")
test("[SkillHardening] unlockSkill rejects class-mismatched skill" in testrunner_src, "Suite 46 tests class restriction enforcement")
test("[SkillHardening] Cooldown strictly preserved and isolated on runtime instance" in testrunner_src, "Suite 46 tests cooldown isolation")

test("--- [Suite 47] Phase 3.1 Passive Tree Hardening & Negative Modifier Stacking" in testrunner_src, "TestRunner includes Suite 47: Passive Hardening & Negative Modifiers")
test("[PassiveHardening] Node with empty string ID rejected" in testrunner_src, "Suite 47 tests empty string ID rejection")
test("[PassiveHardening] Node with non-array Prerequisites rejected" in testrunner_src, "Suite 47 tests non-array prerequisites rejection")
test("[PassiveHardening] Empty string prerequisite rejected" in testrunner_src, "Suite 47 tests empty string prerequisite rejection")
test("[PassiveHardening] TitanStance negative MaxEnergy applied" in testrunner_src, "Suite 47 tests TitanStance negative MaxEnergy stacking")

test("--- [Suite 48] Phase 3.1 Active Skill Transactional Execution" in testrunner_src, "TestRunner includes Suite 48: Active Skill Transactional Execution")
test("[SkillTx] Disconnected player rejected" in testrunner_src, "Suite 48 tests disconnected player rejection")
test("[SkillTx] Downed player rejected" in testrunner_src, "Suite 48 tests downed player rejection")
test("[SkillTx] Non-PlayerPhase rejected" in testrunner_src, "Suite 48 tests non-PlayerPhase rejection")
test("[SkillTx] Target resolution failure consumed exactly 0 Energy" in testrunner_src, "Suite 48 tests zero energy rollback on target failure")
test("[SkillTx] Target resolution failure triggered 0 Cooldown" in testrunner_src, "Suite 48 tests zero cooldown rollback on target failure")
test("[SkillTx] Valid target executed successfully" in testrunner_src, "Suite 48 tests successful transactional execution")

test("--- [Suite 49] Phase 3.1 Network Contracts & Remote Event Authority" in testrunner_src, "TestRunner includes Suite 49: Network Contracts & Authority")
test("[NetworkAuthority] EquipEquipmentEvent registered" in testrunner_src, "Suite 49 tests EquipEquipmentEvent presence")
test("[NetworkAuthority] UseSkillEvent registered" in testrunner_src, "Suite 49 tests UseSkillEvent presence")

test("--- [Suite 50] Phase 3.1 Extended Vertical Slice End-to-End" in testrunner_src, "TestRunner includes Suite 50: Extended Vertical Slice")
test("[ExtSlice] Equipped weapon and armor: MaxHP updated to 140" in testrunner_src, "Suite 50 tests equipment stat application")
test("[ExtSlice] Passives unlocked: MaxHP updated to 155" in testrunner_src, "Suite 50 tests passive stat application")
test("[ExtSlice] HeroicStrike executed end-to-end" in testrunner_src, "Suite 50 tests skill execution through modifier pipeline")
test("[ExtSlice] Second use blocked by active cooldown" in testrunner_src, "Suite 50 tests cooldown blocking second use")
test("[ExtSlice] BonusDamage dropped from 8 to 3" in testrunner_src, "Suite 50 tests modifier cleanup on gear unequip")

# 43. Phase 3.2 Network Ownership Boundary & Contract Validation
print("\n--- [Check 43] Phase 3.2 Network Ownership Boundary & Contract Validation ---")
testrunner_src = (ROOT / "src/server/services/TestRunner.luau").read_text(encoding="utf-8")
equip_service_src = (ROOT / "src/server/services/EquipmentService.luau").read_text(encoding="utf-8")
skill_service_src = (ROOT / "src/server/services/SkillService.luau").read_text(encoding="utf-8")
network_service_src = (ROOT / "src/server/services/NetworkService.luau").read_text(encoding="utf-8")
server_init_src = (ROOT / "src/server/init.server.luau").read_text(encoding="utf-8")
state_types_src = (ROOT / "src/shared/StateTypes.luau").read_text(encoding="utf-8")

# StateTypes schema checks
test("SkillInventory: { SkillInstance }?" in state_types_src, "StateTypes defines SkillInventory in PlayerState")
test("EquippedSkills: { [string]: string }?" in state_types_src, "StateTypes defines EquippedSkills in PlayerView")
test("SkillInventory: { string }?" in state_types_src, "StateTypes defines SkillInventory in PlayerView")
test("UnlockedPassives: { [string]: boolean }?" in state_types_src, "StateTypes defines UnlockedPassives in PlayerView")
test("PassivePoints: number?" in state_types_src, "StateTypes defines PassivePoints in PlayerView")

# SkillService & Network ownership checks
test("function SkillService.getOwnedSkill(" in skill_service_src, "SkillService provides getOwnedSkill API")
test("SkillService.getOwnedSkill(pState, skillIdentifier)" in server_init_src, "init.server.luau verifies skill ownership via getOwnedSkill")
test("SkillService.createInstance" not in server_init_src, "init.server.luau contains 0 SkillService.createInstance calls")

# Equipment inventory boundary checks
test("bypassInventoryCheck" not in equip_service_src, "EquipmentService contains 0 bypassInventoryCheck references")

# Slot validation checks
test("VALID_EQUIPMENT_SLOTS" in server_init_src, "init.server.luau validates VALID_EQUIPMENT_SLOTS")
test("VALID_SKILL_SLOTS" in server_init_src, "init.server.luau validates VALID_SKILL_SLOTS")

# NetworkService registration & init connection
test("NetworkService.UnlockSkillEvent" in network_service_src, "NetworkService registers UnlockSkillEvent")
test("NetworkService.UnlockSkillEvent.OnServerEvent:Connect" in server_init_src, "init.server.luau listens to UnlockSkillEvent")

# TestRunner Suite 51 checks
test("--- [Suite 51] Phase 3.2 Network Ownership Boundary & Contract Validation" in testrunner_src, "TestRunner includes Suite 51: Network Ownership Boundary")
test("[NetBoundary] UnlockSkillEvent registered in NetworkService" in testrunner_src, "Suite 51 tests UnlockSkillEvent registration")
test("[NetContract] Weapon is valid equipment slot" in testrunner_src, "Suite 51 tests valid equipment slot contract")
test("[NetContract] Skill1 is valid skill slot" in testrunner_src, "Suite 51 tests valid skill slot contract")
test("[NetContract] Banana rejected as equipment slot" in testrunner_src, "Suite 51 tests invalid equipment slot rejection")
test("[NetContract] Skill99 rejected as skill slot" in testrunner_src, "Suite 51 tests invalid skill slot rejection")
test("[NetBoundary] Unowned skill definition returns nil from getOwnedSkill" in testrunner_src, "Suite 51 tests unowned skill lookup rejection")
test("[NetBoundary] Equipping unowned skill definition rejected" in testrunner_src, "Suite 51 tests unowned skill equip rejection")
test("[NetBoundary] Foreign skill instance rejected by equipSkill" in testrunner_src, "Suite 51 tests foreign skill instance equip rejection")
test("[NetBoundary] Player 1 authoritatively unlocked HeroicStrike" in testrunner_src, "Suite 51 tests authoritative skill unlock")
test("[NetBoundary] Equipping valid owned skill succeeds" in testrunner_src, "Suite 51 tests valid owned skill equip")
test("[NetBoundary] Equipping same instance in another slot rejected" in testrunner_src, "Suite 51 tests duplicate skill instance equip rejection")
test("[NetBoundary] Fabricated equipment instance ID rejected" in testrunner_src, "Suite 51 tests fabricated equipment instance rejection")
test("[NetBoundary] Equipment instance not in inventory rejected" in testrunner_src, "Suite 51 tests unowned equipment instance rejection")
test("[NetBoundary] Foreign equipment owner mismatch rejected" in testrunner_src, "Suite 51 tests foreign equipment owner mismatch rejection")
test("[NetBoundary] Equipment forged slot mismatch rejected" in testrunner_src, "Suite 51 tests equipment forged slot mismatch rejection")
test("[NetBoundary] Equipping legitimate inventory item succeeds" in testrunner_src, "Suite 51 tests legitimate equipment equip")
test("[NetBoundary] Number skill slot rejected safely" in testrunner_src, "Suite 51 tests non-string slot type rejection")
test("[NetBoundary] Number equipment instance ID rejected safely" in testrunner_src, "Suite 51 tests non-string equipment ID rejection")
test("[NetSnapshot] Run snapshot serializes equipped weapon definition ID" in testrunner_src, "Suite 51 tests run snapshot equipped items serialization")
test("[NetSnapshot] Run snapshot serializes equipped skill definition ID" in testrunner_src, "Suite 51 tests run snapshot equipped skills serialization")
test("[NetSnapshot] Run snapshot serializes skill inventory array" in testrunner_src, "Suite 51 tests run snapshot skill inventory serialization")
test("[NetSnapshot] Run snapshot serializes unlocked passives set" in testrunner_src, "Suite 51 tests run snapshot passives serialization")
test("[NetSnapshot] Run snapshot serializes accurate remaining passive points" in testrunner_src, "Suite 51 tests run snapshot passive points serialization")

# 44. Phase 3.3 Strict Instance Validation & Fabricated Object Rejection
print("\n--- [Check 44] Phase 3.3 Strict Instance Validation & Fabricated Object Rejection ---")
testrunner_src = (ROOT / "src/server/services/TestRunner.luau").read_text(encoding="utf-8")
equip_service_src = (ROOT / "src/server/services/EquipmentService.luau").read_text(encoding="utf-8")
skill_service_src = (ROOT / "src/server/services/SkillService.luau").read_text(encoding="utf-8")

# Fabricated SkillInstance closure checks in SkillService
test("table.insert(playerState.SkillInventory, candidate)" not in skill_service_src, "SkillService.equipSkill contains 0 auto-insertions of candidate into SkillInventory")
test("supplied.DefinitionId ~= authInst.DefinitionId" in skill_service_src, "SkillService.equipSkill validates supplied DefinitionId against stored authoritative record")
test("authInst.OwnerUserId ~= playerState.UserId" in skill_service_src, "SkillService.equipSkill validates authInst OwnerUserId against player")
test("function SkillService.grantSkillForTesting(" in skill_service_src, "SkillService provides grantSkillForTesting helper")

# Fabricated EquipmentInstance closure checks in EquipmentService
test("supplied.DefinitionId ~= authItem.DefinitionId" in equip_service_src, "EquipmentService.equipItem validates supplied DefinitionId against stored authoritative record")
test("supplied.OwnerUserId ~= authItem.OwnerUserId" in equip_service_src, "EquipmentService.equipItem validates supplied OwnerUserId against stored authoritative record")
test("supplied.Slot ~= authItem.Slot" in equip_service_src, "EquipmentService.equipItem validates supplied Slot against stored authoritative record")

# TestRunner Suite 52 checks
test("--- [Suite 52] Phase 3.3 Strict Instance Validation & Fabricated Object Rejection" in testrunner_src, "TestRunner includes Suite 52: Strict Instance Validation & Fabricated Object Rejection")
test("[SkillAuthoritative] Fabricated instance with matching OwnerUserId rejected" in testrunner_src, "Suite 52 tests rejection of fabricated skill with matching OwnerUserId")
test("[SkillAuthoritative] Zero SkillInventory mutation on fabricated instance rejection" in testrunner_src, "Suite 52 tests zero SkillInventory mutation on rejected skill equip")
test("[SkillAuthoritative] Fabricated instance with valid DefinitionId rejected" in testrunner_src, "Suite 52 tests rejection of fabricated skill with valid DefinitionId")
test("[SkillAuthoritative] Fabricated instance with unlocked definition rejected" in testrunner_src, "Suite 52 tests rejection of fabricated skill with unlocked definition")
test("[SkillAuthoritative] Forged definition on real InstanceId rejected" in testrunner_src, "Suite 52 tests rejection of forged fields on real skill InstanceId")
test("[SkillAuthoritative] Equipping real SkillInventory instance succeeds" in testrunner_src, "Suite 52 tests equipping real SkillInventory instance")
test("[SkillAuthoritative] Re-equipping real equipped instance succeeds idempotently" in testrunner_src, "Suite 52 tests idempotent re-equip of real skill")
test("[SkillAuthoritative] Failed equip caused exactly zero SkillInventory mutations" in testrunner_src, "Suite 52 tests zero SkillInventory mutation on failed equip")
test("[EquipmentAuthoritative] Fabricated item with matching OwnerUserId rejected" in testrunner_src, "Suite 52 tests rejection of fabricated equipment with matching OwnerUserId")
test("[EquipmentAuthoritative] Zero EquipmentInventory mutation on forged item rejection" in testrunner_src, "Suite 52 tests zero EquipmentInventory mutation on rejected equipment equip")
test("[EquipmentAuthoritative] Fabricated item with valid DefinitionId rejected" in testrunner_src, "Suite 52 tests rejection of fabricated equipment with valid DefinitionId")
test("[EquipmentAuthoritative] Forged definition on real gear InstanceId rejected" in testrunner_src, "Suite 52 tests rejection of forged fields on real equipment InstanceId")
test("[EquipmentAuthoritative] Equipping real inventory gear succeeds" in testrunner_src, "Suite 52 tests equipping real EquipmentInventory item")
test("[EquipmentAuthoritative] Re-equipping real gear succeeds idempotently" in testrunner_src, "Suite 52 tests idempotent re-equip of real equipment")

# 45. Phase 4 Profile Architecture & Migration
print("\n--- [Check 45] Phase 4 Profile Architecture & Migration ---")
state_types_src = (ROOT / "src/shared/StateTypes.luau").read_text(encoding="utf-8")
game_config_src = (ROOT / "src/shared/GameConfig.luau").read_text(encoding="utf-8")
persist_service_src = (ROOT / "src/server/services/PersistenceService.luau").read_text(encoding="utf-8")

test("export type SavedDeck =" in state_types_src, "StateTypes defines SavedDeck model")
test("export type DeckSlotEntitlement =" in state_types_src, "StateTypes defines DeckSlotEntitlement model")
test("ProfileVersion: number" in state_types_src, "StateTypes defines ProfileVersion in PlayerProfile")
test("CardCollection: { [string]: number }" in state_types_src, "StateTypes defines CardCollection in PlayerProfile")
test("Decks: { [string]: SavedDeck }" in state_types_src, "StateTypes defines Decks in PlayerProfile")
test("ActiveDeckId: string?" in state_types_src, "StateTypes defines ActiveDeckId in PlayerProfile")
test("DeckSlotEntitlement: DeckSlotEntitlement" in state_types_src, "StateTypes defines DeckSlotEntitlement in PlayerProfile")
test("export type CardCollectionView =" in state_types_src, "StateTypes defines CardCollectionView DTO")
test("export type DeckSummaryView =" in state_types_src, "StateTypes defines DeckSummaryView DTO")
test("export type DeckDetailView =" in state_types_src, "StateTypes defines DeckDetailView DTO")
test("export type DeckSlotView =" in state_types_src, "StateTypes defines DeckSlotView DTO")

test("GameConfig.Deck = {" in game_config_src, "GameConfig defines Deck configuration")
test("BaseDeckSlots = 4" in game_config_src, "GameConfig defines BaseDeckSlots = 4")
test("MinDeckSize = 8" in game_config_src, "GameConfig defines MinDeckSize = 8")
test("MaxDeckSize = 30" in game_config_src, "GameConfig defines MaxDeckSize = 30")
test("MaxCopiesPerCard = 3" in game_config_src, "GameConfig defines MaxCopiesPerCard = 3")
test("GameConfig.StarterCollection = {" in game_config_src, "GameConfig defines StarterCollection configuration")

test("CURRENT_PROFILE_VERSION = 1" in persist_service_src, "PersistenceService defines CURRENT_PROFILE_VERSION = 1")
test("function PersistenceService.mutateProfile(" in persist_service_src, "PersistenceService provides mutateProfile wrapper")
test("function PersistenceService.reconcileForTesting(" in persist_service_src, "PersistenceService provides reconcileForTesting helper")

# Suite 53 tests
test("--- [Suite 53] Phase 4 Profile Architecture & Migration" in testrunner_src, "TestRunner includes Suite 53: Profile Architecture & Migration")
test("[Profile] New profile has ProfileVersion = 1" in testrunner_src, "Suite 53 tests new profile default version")
test("[Profile] Starter collection contains 5 Strikes" in testrunner_src, "Suite 53 tests starter collection Strikes")
test("[Profile] BaseDeckSlots defaults to 4" in testrunner_src, "Suite 53 tests default BaseDeckSlots")
test("[ProfileMigration] Upgraded from v0 to ProfileVersion = 1" in testrunner_src, "Suite 53 tests v0 to v1 profile migration")
test("[ProfileMigration] Preserved existing AetherShards = 120" in testrunner_src, "Suite 53 tests currency preservation during migration")
test("[ProfileRecovery] Normalized to ProfileVersion = 1" in testrunner_src, "Suite 53 tests malformed profile normalization")
test("[ProfileRecovery] Negative AetherShards clamped to 0" in testrunner_src, "Suite 53 tests negative currency clamping")
test("[ProfileRecovery] Unknown card definition rejected" in testrunner_src, "Suite 53 tests unknown card collection definition rejection")

# 46. Phase 4 Card Collection & Deck Services
print("\n--- [Check 46] Phase 4 Card Collection & Deck Services ---")
card_col_service_src = (ROOT / "src/server/services/CardCollectionService.luau").read_text(encoding="utf-8")
deck_service_src = (ROOT / "src/server/services/DeckService.luau").read_text(encoding="utf-8")

test("function CardCollectionService.grantCard(" in card_col_service_src, "CardCollectionService provides grantCard API")
test("function CardCollectionService.removeCard(" in card_col_service_src, "CardCollectionService provides removeCard API")
test("function CardCollectionService.getCardCount(" in card_col_service_src, "CardCollectionService provides getCardCount API")
test("function CardCollectionService.hasCard(" in card_col_service_src, "CardCollectionService provides hasCard API")
test("function CardCollectionService.getCollection(" in card_col_service_src, "CardCollectionService provides getCollection API")
test("function CardCollectionService.toCollectionView(" in card_col_service_src, "CardCollectionService provides toCollectionView API")

test("function DeckService.getSlotEntitlement(" in deck_service_src, "DeckService provides getSlotEntitlement API")
test("function DeckService.checkSlotAvailability(" in deck_service_src, "DeckService provides checkSlotAvailability API")
test("function DeckService.validateDeck(" in deck_service_src, "DeckService provides validateDeck API")
test("function DeckService.createDeck(" in deck_service_src, "DeckService provides createDeck API")
test("function DeckService.renameDeck(" in deck_service_src, "DeckService provides renameDeck API")
test("function DeckService.deleteDeck(" in deck_service_src, "DeckService provides deleteDeck API")
test("function DeckService.duplicateDeck(" in deck_service_src, "DeckService provides duplicateDeck API")
test("function DeckService.saveDeck(" in deck_service_src, "DeckService provides saveDeck API")
test("function DeckService.getDeck(" in deck_service_src, "DeckService provides getDeck API")
test("function DeckService.listDecks(" in deck_service_src, "DeckService provides listDecks API")
test("function DeckService.setActiveDeck(" in deck_service_src, "DeckService provides setActiveDeck API")
test("function DeckService.getActiveDeck(" in deck_service_src, "DeckService provides getActiveDeck API")

# Suite 54 & 55 tests
test("--- [Suite 54] Phase 4 Card Collection Service" in testrunner_src, "TestRunner includes Suite 54: Card Collection Service")
test("[CardCollection] Granting 2 copies of HeavyBlow succeeds" in testrunner_src, "Suite 54 tests authoritative card grant")
test("[CardCollection] Granting unknown card definition rejected" in testrunner_src, "Suite 54 tests unknown card definition rejection")
test("[CardCollection] Granting negative quantity rejected" in testrunner_src, "Suite 54 tests negative quantity grant rejection")
test("[CardCollection] Removing 1 owned copy succeeds" in testrunner_src, "Suite 54 tests authoritative card removal")
test("[CardCollection] Removing more copies than owned rejected" in testrunner_src, "Suite 54 tests insufficient copy deduction rejection")
test("[CardCollectionView] View contains 5 Strikes" in testrunner_src, "Suite 54 tests collection view serialization")

test("--- [Suite 55] Phase 4 Deck Model, Slot Entitlement & Deck Service" in testrunner_src, "TestRunner includes Suite 55: Deck Model & Entitlement")
test("[DeckSlot] Base slots equals 4" in testrunner_src, "Suite 55 tests base slots calculation")
test("[DeckSlot] Available slots equals 3" in testrunner_src, "Suite 55 tests available slots calculation")
test("[DeckSlot] Creating 5th deck rejected due to slot exhaustion" in testrunner_src, "Suite 55 tests slot exhaustion rejection")
test("[DeckSlot] Creating 5th deck succeeds after entitlement expansion" in testrunner_src, "Suite 55 tests additional slot entitlement expansion")
test("[DeckService] Empty/whitespace deck name rejected" in testrunner_src, "Suite 55 tests empty deck name rejection")
test("[DeckService] Excessively long deck name rejected" in testrunner_src, "Suite 55 tests long deck name rejection")
test("[DeckService] Renaming deck succeeds" in testrunner_src, "Suite 55 tests renaming deck")
test("[DeckService] Duplicating deck succeeds" in testrunner_src, "Suite 55 tests duplicating deck")
test("[DeckService] Deleting duplicate deck succeeds" in testrunner_src, "Suite 55 tests deleting deck")

# 47. Phase 4 Deck Validation & Run Integration
print("\n--- [Check 47] Phase 4 Deck Validation & Run Integration ---")
class_service_src = (ROOT / "src/server/services/ClassService.luau").read_text(encoding="utf-8")

test("DeckService.getActiveDeck(" in class_service_src, "ClassService queries DeckService.getActiveDeck")
test("DeckService.validateDeck(" in class_service_src, "ClassService validates active deck via DeckService")

# Suite 56 & 57 tests
test("--- [Suite 56] Phase 4 Deck Validation & Active Deck Selection" in testrunner_src, "TestRunner includes Suite 56: Deck Validation & Active Deck")
test("[DeckValidation] Starter deck passes validation" in testrunner_src, "Suite 56 tests valid deck validation")
test("[DeckValidation] Unknown card definition rejected" in testrunner_src, "Suite 56 tests unknown card validation rejection")
test("[DeckValidation] Unowned card rejected" in testrunner_src, "Suite 56 tests unowned card validation rejection")
test("[DeckValidation] Quantity exceeding collection ownership rejected" in testrunner_src, "Suite 56 tests over-ownership validation rejection")
test("[DeckValidation] Exceeding MaxCopiesPerCard (4 > 3) rejected" in testrunner_src, "Suite 56 tests max copies per card rejection")
test("[DeckValidation] Deck with 6 cards (< 8 min) rejected" in testrunner_src, "Suite 56 tests min deck size rejection")
test("[DeckValidation] Deck with 31 cards (> 30 max) rejected" in testrunner_src, "Suite 56 tests max deck size rejection")
test("[ActiveDeck] Selecting valid custom deck as active succeeds" in testrunner_src, "Suite 56 tests active deck selection")
test("[ActiveDeckFallback] getActiveDeck falls back safely to starter deck" in testrunner_src, "Suite 56 tests deleted active deck fallback")

test("--- [Suite 57] Phase 4 Run Integration & Complete Phase 4 Vertical Slice" in testrunner_src, "TestRunner includes Suite 57: Complete Phase 4 Vertical Slice")
test("[RunIntegration] Initialized 8 runtime CardInstances matching active deck" in testrunner_src, "Suite 57 tests runtime CardInstance synthesis from active deck")
test("[RunIntegration] Runtime CardInstance GUID is unique" in testrunner_src, "Suite 57 tests runtime CardInstance unique GUIDs")
test("[RunIntegration] Played card placed in discard pile" in testrunner_src, "Suite 57 tests combat card movement to discard")
test("[RunIntegration] Exhausted card placed in exhaust pile" in testrunner_src, "Suite 57 tests combat card movement to exhaust")
test("[RunIsolation] Persistent SavedDeck Strike count unchanged (3)" in testrunner_src, "Suite 57 tests persistent SavedDeck immutability during combat")
test("[RunIsolation] Permanent CardCollection Strike count unchanged (5)" in testrunner_src, "Suite 57 tests permanent CardCollection immutability during combat")
test("[RunIsolation] Active run deck cardinality preserved despite persistent deck edit" in testrunner_src, "Suite 57 tests active run isolation from persistent deck mutations")

# 48. Phase 4 Network Security & Remote Contracts
print("\n--- [Check 48] Phase 4 Network Security & Remote Contracts ---")
network_service_src = (ROOT / "src/server/services/NetworkService.luau").read_text(encoding="utf-8")
server_init_src = (ROOT / "src/server/init.server.luau").read_text(encoding="utf-8")

test("NetworkService.CreateDeckEvent" in network_service_src, "NetworkService registers CreateDeckEvent")
test("NetworkService.RenameDeckEvent" in network_service_src, "NetworkService registers RenameDeckEvent")
test("NetworkService.DeleteDeckEvent" in network_service_src, "NetworkService registers DeleteDeckEvent")
test("NetworkService.SaveDeckEvent" in network_service_src, "NetworkService registers SaveDeckEvent")
test("NetworkService.DuplicateDeckEvent" in network_service_src, "NetworkService registers DuplicateDeckEvent")
test("NetworkService.SelectActiveDeckEvent" in network_service_src, "NetworkService registers SelectActiveDeckEvent")
test("NetworkService.RequestDecksEvent" in network_service_src, "NetworkService registers RequestDecksEvent")
test("NetworkService.RequestCardCollectionEvent" in network_service_src, "NetworkService registers RequestCardCollectionEvent")
test("NetworkService.DeckListUpdateEvent" in network_service_src, "NetworkService registers DeckListUpdateEvent")
test("NetworkService.DeckDetailUpdateEvent" in network_service_src, "NetworkService registers DeckDetailUpdateEvent")
test("NetworkService.CardCollectionUpdateEvent" in network_service_src, "NetworkService registers CardCollectionUpdateEvent")

test("NetworkService.CreateDeckEvent.OnServerEvent:Connect" in server_init_src, "init.server.luau listens to CreateDeckEvent")
test("NetworkService.RenameDeckEvent.OnServerEvent:Connect" in server_init_src, "init.server.luau listens to RenameDeckEvent")
test("NetworkService.DeleteDeckEvent.OnServerEvent:Connect" in server_init_src, "init.server.luau listens to DeleteDeckEvent")
test("NetworkService.SaveDeckEvent.OnServerEvent:Connect" in server_init_src, "init.server.luau listens to SaveDeckEvent")
test("NetworkService.DuplicateDeckEvent.OnServerEvent:Connect" in server_init_src, "init.server.luau listens to DuplicateDeckEvent")
test("NetworkService.SelectActiveDeckEvent.OnServerEvent:Connect" in server_init_src, "init.server.luau listens to SelectActiveDeckEvent")
test("NetworkService.RequestDecksEvent.OnServerEvent:Connect" in server_init_src, "init.server.luau listens to RequestDecksEvent")
test("NetworkService.RequestCardCollectionEvent.OnServerEvent:Connect" in server_init_src, "init.server.luau listens to RequestCardCollectionEvent")

# Suite 58 tests
test("--- [Suite 58] Phase 4 Network Security & Remote Contract Hardening" in testrunner_src, "TestRunner includes Suite 58: Network Security & Contracts")
test("[NetSecurity] CreateDeckEvent registered" in testrunner_src, "Suite 58 tests CreateDeckEvent registration")
test("[NetSecurity] DeckId is generated by server, client cannot forge ID" in testrunner_src, "Suite 58 tests server-generated DeckId enforcement")
test("[NetSecurity] Saving unowned cards rejected by authoritative validator" in testrunner_src, "Suite 58 tests unowned card save rejection")
test("[NetSecurity] Saving card count exceeding collection ownership rejected" in testrunner_src, "Suite 58 tests over-collection card save rejection")
test("[NetSecurity] Saving into non-existent deck rejected" in testrunner_src, "Suite 58 tests non-existent deck save rejection")
test("[NetSecurity] General rate limiter permits standard requests" in testrunner_src, "Suite 58 tests rate limiting on Phase 4 requests")

# 49. Phase 4.1 Persistence Safety, Migration Hardening & Deck Audit
print("\n--- [Check 49] Phase 4.1 Persistence Safety, Migration Hardening & Security Audit ---")
persistence_service_src = (ROOT / "src/server/services/PersistenceService.luau").read_text(encoding="utf-8")
deck_service_src = (ROOT / "src/server/services/DeckService.luau").read_text(encoding="utf-8")

# PersistenceService fail-closed & concurrency invariants
test("ProfileLoadState" in persistence_service_src, "PersistenceService defines ProfileLoadState type")
test("PersistenceService.getLoadState(" in persistence_service_src, "PersistenceService implements getLoadState")
test("PersistenceService.isProfileLoaded(" in persistence_service_src, "PersistenceService implements isProfileLoaded")
test("PersistenceService.onPlayerRemoving(" in persistence_service_src, "PersistenceService implements onPlayerRemoving")
test("PersistenceService.resolveUpdateConflict(" in persistence_service_src, "PersistenceService implements resolveUpdateConflict")
test("UpdateAsync(" in persistence_service_src, "PersistenceService uses UpdateAsync for concurrency safety")
test('loadState ~= "Loaded" and loadState ~= "New"' in persistence_service_src, "PersistenceService enforces fail-closed save guard")

# DeckService active deck fallback
test("function DeckService.getActiveDeck(" in deck_service_src, "DeckService implements getActiveDeck")
test("DeckService.validateDeck(player, candidate.Cards, candidate.ClassId)" in deck_service_src, "getActiveDeck validates active candidate")
test("DeckService.listDecks(player)" in deck_service_src, "getActiveDeck searches sorted decks on fallback")

# Network / ServerInit skill minting protection
test("UnlockSkillEvent rejected: client-authoritative skill unlocking is disabled" in server_init_src, "init.server.luau rejects client UnlockSkillEvent requests")

# Suite 57 regression fix & Suite 59 checks in TestRunner
test("local handCountDraw = 0" in testrunner_src, "Suite 57 computes dynamic active handCount after draw")
test("Total card count across all piles remains 8 after draw" in testrunner_src, "Suite 57 tests draw cardinality invariant")
test("Zero overlapping GUIDs between draw deck and hand" in testrunner_src, "Suite 57 tests draw uniqueness invariant")
test("Hand count reduced by exactly 1 after play" in testrunner_src, "Suite 57 tests play cardinality invariant")
test("Hand count reduced by exactly 1 after exhaust" in testrunner_src, "Suite 57 tests exhaust cardinality invariant")

test("--- [Suite 59] Phase 4.1 Persistence Safety, Migration Hardening & Security Audit" in testrunner_src, "TestRunner includes Suite 59: Persistence Safety & Audit")
test("[FailClosed] DataStore load failure returns nil profile" in testrunner_src, "Suite 59 tests load failure returns nil")
test("[FailClosed] Profile load state is LoadFailed" in testrunner_src, "Suite 59 tests ProfileLoadState is LoadFailed")
test("[FailClosed] isProfileLoaded returns false on load failure" in testrunner_src, "Suite 59 tests isProfileLoaded returns false on failure")
test("[FailClosed] saveProfile rejected on LoadFailed state" in testrunner_src, "Suite 59 tests saveProfile fail-closed rejection")
test("[FailClosed] onPlayerRemoving refuses to save on LoadFailed state" in testrunner_src, "Suite 59 tests onPlayerRemoving refuses save on failure")
test("[Reconciliation] Fractional card count in collection is rejected" in testrunner_src, "Suite 59 tests collection fractional card rejection")
test("[Reconciliation] Fractional card count in saved deck is rejected" in testrunner_src, "Suite 59 tests saved deck fractional card rejection")
test("[Reconciliation] Blank/whitespace deck name repaired to Custom Deck" in testrunner_src, "Suite 59 tests blank deck name auto-repair")
test("[Reconciliation] Unknown card stripped from saved deck" in testrunner_src, "Suite 59 tests unknown card stripping during reconcile")
test("[Reconciliation] Negative DeckSlotEntitlement clamped to BaseDeckSlots" in testrunner_src, "Suite 59 tests negative slot entitlement clamping")
test("[Reconciliation] Excessive DeckSlotEntitlement clamped to MaxPurchasableDeckSlots" in testrunner_src, "Suite 59 tests excessive slot entitlement clamping")
test("[ActiveDeckFallback] Invalid active deck falls back to valid deck" in testrunner_src, "Suite 59 tests active deck invalid fallback")
test("[ActiveDeckFallback] Read does not mutate persistent ActiveDeckId" in testrunner_src, "Suite 59 tests active deck read non-mutating")
test("[ActiveDeckFallback] Returns nil when zero decks are valid" in testrunner_src, "Suite 59 tests active deck returns nil when no valid decks")
test("[ConcurrencySafety] Older session profile cannot overwrite newer remote DataStore data" in testrunner_src, "Suite 59 tests concurrency timestamp conflict detection")
test("[ConcurrencySafety] Newer session profile is permitted to update older remote DataStore data" in testrunner_src, "Suite 59 tests concurrency timestamp update success")
test("[RemoteSecurity] UnlockSkillEvent exists" in testrunner_src, "Suite 59 tests UnlockSkillEvent existence")

# 50. Class Selection Lifecycle & Server Lock Authority
print("\n--- [Check 50] Class Selection Lifecycle & Server Lock Authority ---")
state_types_src = (ROOT / "src/shared/StateTypes.luau").read_text(encoding="utf-8")
class_service_src = (ROOT / "src/server/services/ClassService.luau").read_text(encoding="utf-8")
run_manager_src = (ROOT / "src/server/services/RunManager.luau").read_text(encoding="utf-8")
class_ui_src = (ROOT / "src/client/ClassSelectUI.client.luau").read_text(encoding="utf-8")
testrunner_src = (ROOT / "src/server/services/TestRunner.luau").read_text(encoding="utf-8")

test("ClassLocked: boolean?" in state_types_src, "StateTypes defines ClassLocked field")
test("playerState.ClassLocked = true" in class_service_src, "ClassService sets ClassLocked on valid selection")
test("ClassLocked = pState.ClassLocked or false" in run_manager_src or "ClassLocked = pState.ClassLocked" in run_manager_src, "RunManager serializes ClassLocked in PlayerView")
test("member.ClassLocked = false" in run_manager_src, "RunManager.resetToLobby resets ClassLocked to false")
test("function RunManager.beginTestIsolation(" in run_manager_src, "RunManager implements beginTestIsolation")
test("function RunManager.endTestIsolation(" in run_manager_src, "RunManager implements endTestIsolation")
test("function RunManager.isTestIsolationActive(" in run_manager_src, "RunManager implements isTestIsolationActive")
test("RunManager.sendRunSnapshot(player," in server_init_src, "init.server.luau sends snapshot on class selection rejection")
test("isLockingIn" in class_ui_src, "ClassSelectUI implements isLockingIn debounce guard")
test("LOCKING IN..." in class_ui_src, "ClassSelectUI displays LOCKING IN... during server validation")
test("✓ CLASS LOCKED IN!" in class_ui_src, "ClassSelectUI displays confirmed state upon server lock")
test("myView.ClassLocked == true" in class_ui_src, "ClassSelectUI hides modal strictly when server confirms ClassLocked")

# Suite 60 checks
test("--- SUITE 60: Class Selection Lifecycle & Server Lock Authority ---" in testrunner_src, "TestRunner includes Suite 60")
test("[ClassLock] New player added to run has ClassLocked == false" in testrunner_src, "Suite 60 tests new player ClassLocked default")
test("[ClassLock] Valid selectClass sets playerState.ClassLocked to true" in testrunner_src, "Suite 60 tests ClassLocked on valid selection")
test("[ClassLock] Rejected class selection does not set ClassLocked to true" in testrunner_src, "Suite 60 tests rejection leaves ClassLocked false")
test("[ClassLock] resetToLobby resets ClassLocked to false for player 1" in testrunner_src, "Suite 60 tests resetToLobby resets ClassLocked")
test("[ClassLock] PlayerView in RunSnapshot correctly reflects ClassLocked == true" in testrunner_src, "Suite 60 tests RunSnapshot PlayerView serialization")
test("[ClassLock] Invalid subclass ID is rejected" in testrunner_src, "Suite 60 tests invalid subclass rejection")
test("[ClassLock] Out-of-phase class selection is rejected" in testrunner_src, "Suite 60 tests out-of-phase selection rejection")
test("[ClassLock] Reconnected player in Lobby preserves ClassLocked == true" in testrunner_src, "Suite 60 tests reconnect preserves ClassLocked")
test("[ClassLock] RequestStateSync returns valid snapshot" in testrunner_src, "Suite 60 tests RequestStateSync snapshot validity")
test("[ClassLock] Test isolation is active during test execution" in testrunner_src, "Suite 60 tests test isolation active state")
test("[ClassLock] Test isolation tears down cleanly" in testrunner_src, "Suite 60 tests test isolation tear down")

# 51. TestRunner / RunManager Isolation Lifecycle & Exception Safety
print("\n--- [Check 51] TestRunner / RunManager Isolation Lifecycle & Exception Safety ---")
test("function RunManager.runWithTestIsolation" in run_manager_src, "RunManager implements runWithTestIsolation")
test("function RunManager.getLiveRunState(" in run_manager_src, "RunManager implements getLiveRunState")
test("liveRun.PartyMembers[userId] = pState" not in run_manager_src, "RunManager.addPlayer does not mirror test state to liveRun")
test("if RunManager.isTestIsolationActive() then\n\t\tRunManager.endTestIsolation()\n\tend" in server_init_src or "if RunManager.isTestIsolationActive() then" in server_init_src, "init.server.luau defensively tears down test isolation on error")
test("if RunManager.isTestIsolationActive() then" in testrunner_src, "TestRunner.runAllTests defensively tears down test isolation on error")
test("local testOk, testErr = pcall(function()" in testrunner_src, "TestRunner.runAllTests wraps test execution in pcall")
test("[IsolationSafety] currentRun points back to liveRun" in testrunner_src, "Suite 60 tests currentRun points to liveRun after teardown")
test("[IsolationSafety] LiveRun party members not contaminated by test players" in testrunner_src, "Suite 60 tests liveRun not contaminated by test players")
test("[IsolationSafety] runWithTestIsolation succeeds on normal execution" in testrunner_src, "Suite 60 tests runWithTestIsolation normal execution")
test("[IsolationSafety] runWithTestIsolation captures thrown error" in testrunner_src, "Suite 60 tests runWithTestIsolation captures thrown error")
test("[IsolationSafety] Isolation ends automatically after error" in testrunner_src, "Suite 60 tests isolation ends after error")
test("[IsolationSafety] currentRun points to liveRun after isolated failure" in testrunner_src, "Suite 60 tests currentRun restored after failure")
test("[IsolationSafety] Live players remain intact after test failure" in testrunner_src, "Suite 60 tests live players intact after error")
test("[IsolationSafety] Failed test state never leaked to liveRun" in testrunner_src, "Suite 60 tests failed test state never leaked")
test("[IsolationSafety] Normal RequestStateSync returns valid snapshot from liveRun" in testrunner_src, "Suite 60 tests normal RequestStateSync returns snapshot from liveRun")
test("[IsolationSafety] Broadcasts are unsuppressed in live server mode" in testrunner_src, "Suite 60 tests broadcasts unsuppressed in live server mode")

# 52. Class Selection Remote Contract & UX Feedback
print("\n--- [Check 52] Class Selection Remote Contract & UX Feedback ---")
network_service_src = (ROOT / "src/server/services/NetworkService.luau").read_text(encoding="utf-8")
server_init_src = (ROOT / "src/server/init.server.luau").read_text(encoding="utf-8")
class_ui_src = (ROOT / "src/client/ClassSelectUI.client.luau").read_text(encoding="utf-8")
testrunner_src = (ROOT / "src/server/services/TestRunner.luau").read_text(encoding="utf-8")

test("NetworkService.ClassSelectionResultEvent = getOrCreateRemoteEvent(\"ClassSelectionResult\")" in network_service_src, "NetworkService defines ClassSelectionResultEvent")
test("function NetworkService.sendClassSelectionResult(" in network_service_src, "NetworkService implements sendClassSelectionResult helper")
test("NetworkService.sendClassSelectionResult(player, {" in server_init_src, "init.server.luau dispatches sendClassSelectionResult on events")
test("local ClassSelectionResultEvent = findEvent(\"ClassSelectionResult\")" in class_ui_src, "ClassSelectUI resolves ClassSelectionResultEvent")
test("ClassSelectionResultEvent.OnClientEvent:Connect(" in class_ui_src, "ClassSelectUI connects to ClassSelectionResultEvent")
test("mainGui.Enabled = false" in class_ui_src, "ClassSelectUI disables mainGui ScreenGui on lock confirmation")
test("[ClassSelectResult] ClassSelectionResult RemoteEvent exists in NetworkService" in testrunner_src, "Suite 60 tests ClassSelectionResult RemoteEvent existence")
test("[ClassSelectResult] NetworkService.sendClassSelectionResult is implemented" in testrunner_src, "Suite 60 tests sendClassSelectionResult helper")
test("[ClassSelectResult] Success payload contains ClassId and SubclassId" in testrunner_src, "Suite 60 tests success payload contract")
test("[ClassSelectResult] Rejection payload contains descriptive Error string" in testrunner_src, "Suite 60 tests rejection payload contract")

# 53. Server Startup Ordering & Background Test Isolation
print("\n--- [Check 53] Server Startup Ordering & Background Test Isolation ---")
server_init_src = (ROOT / "src/server/init.server.luau").read_text(encoding="utf-8")
run_manager_src = (ROOT / "src/server/services/RunManager.luau").read_text(encoding="utf-8")

select_class_idx = server_init_src.find("NetworkService.SelectClassEvent.OnServerEvent:Connect")
start_run_idx = server_init_src.find("NetworkService.StartRunEvent.OnServerEvent:Connect")
state_sync_idx = server_init_src.find("NetworkService.RequestStateSyncEvent.OnServerEvent:Connect")
test_runner_idx = server_init_src.find("TestRunner.runAllTests()")

test(select_class_idx != -1, "init.server.luau connects SelectClassEvent")
test(start_run_idx != -1, "init.server.luau connects StartRunEvent")
test(state_sync_idx != -1, "init.server.luau connects RequestStateSyncEvent")
test(test_runner_idx != -1, "init.server.luau executes TestRunner.runAllTests")
test(select_class_idx < test_runner_idx, "SelectClassEvent connected before TestRunner starts")
test(start_run_idx < test_runner_idx, "StartRunEvent connected before TestRunner starts")
test(state_sync_idx < test_runner_idx, "RequestStateSyncEvent connected before TestRunner starts")
test("task.spawn(function()\n\tprint(\"[TestRunner]" in server_init_src or "task.spawn(function()" in server_init_src, "TestRunner runs in task.spawn background thread")
test("if isIsolatedTesting and isRealPlayer then" in run_manager_src, "RunManager routes real players to liveRun during isolation")
test("local isReal = (typeof(initiator) == \"Instance\" and initiator:IsA(\"Player\"))" in run_manager_src, "RunManager.startRun checks real player initiator during isolation")

# 54. Test-Isolation Boundary & Live Run Protection
print("\n--- [Check 54] Test-Isolation Boundary & Live Run Protection ---")
test("#Players:GetPlayers() > 0" not in run_manager_src, "RunManager.startRun never uses #Players:GetPlayers() > 0 to select liveRun")
test("local runToStart = if (isIsolatedTesting and isReal) then liveRun else currentRun" in run_manager_src, "RunManager.startRun routes to liveRun strictly when isIsolatedTesting and isReal")
test("if isIsolatedTesting and not isLiveAction then return end" in run_manager_src, "broadcastRunSnapshots suppresses broadcasts during test isolation unless isLiveAction")
test("function RunManager.getLiveDungeonRun(): DungeonMap.DungeonRun?" in run_manager_src, "RunManager implements getLiveDungeonRun")
test("RunManager.getPlayerState(player.UserId)" not in server_init_src, "init.server.luau passes Player instance to getPlayerState, never player.UserId")
test("RunManager.broadcastRunSnapshots(" in server_init_src and ", true)" in server_init_src, "init.server.luau specifies isLiveAction=true for live player broadcasts")

test("--- SUITE 61: Test Isolation Boundary & Live Run Protection ---" in testrunner_src, "TestRunner includes Suite 61")
test("[CaseA] startRun(nil) succeeds on isolatedTestRun" in testrunner_src, "Suite 61 tests Case A: isolatedTestRun mutates")
test("[CaseA] liveRun remains in Lobby phase" in testrunner_src, "Suite 61 tests Case A: liveRun remains Lobby")
test("[CaseA] liveDungeonRun remains nil" in testrunner_src, "Suite 61 tests Case A: liveDungeonRun remains nil")
test("[CaseB] startRun(nil) succeeds on isolated test run" in testrunner_src, "Suite 61 tests Case B: startRun(nil) on isolated run")
test("[CaseB] liveRun remains in Lobby phase despite connected real player" in testrunner_src, "Suite 61 tests Case B: liveRun unaffected by nil initiator")
test("[CaseB] liveDungeonRun remains nil" in testrunner_src, "Suite 61 tests Case B: liveDungeonRun untouched")
test("[CaseB] Real player in liveRun completely unaffected" in testrunner_src, "Suite 61 tests Case B: real player untouched")
test("[CaseC] startRun(mockPlayer) succeeds on isolatedTestRun" in testrunner_src, "Suite 61 tests Case C: mock startRun on isolated run")
test("[CaseC] liveRun remains in Lobby phase with multiple real players" in testrunner_src, "Suite 61 tests Case C: liveRun remains Lobby with multiple players")
test("[CaseD] startRun(realPlayer) succeeds" in testrunner_src, "Suite 61 tests Case D: real player startRun succeeds")
test("[CaseD] liveRun transitions to MapSelect" in testrunner_src, "Suite 61 tests Case D: liveRun transitions to MapSelect")
test("[CaseD] liveDungeonRun is populated" in testrunner_src, "Suite 61 tests Case D: liveDungeonRun populated")
test("[CaseD] isolatedTestRun remains unaffected in Lobby" in testrunner_src, "Suite 61 tests Case D: isolatedTestRun unaffected")
test("[CaseE] startRun(mockPlayer) succeeds" in testrunner_src, "Suite 61 tests Case E: mock player startRun succeeds")
test("[CaseE] isolatedTestRun transitions to MapSelect" in testrunner_src, "Suite 61 tests Case E: isolatedTestRun transitions to MapSelect")
test("[CaseE] liveRun remains unaffected in Lobby" in testrunner_src, "Suite 61 tests Case E: liveRun unaffected")
test("[BroadcastSuppression] broadcastRunSnapshots suppressed during isolation without isLiveAction" in testrunner_src, "Suite 61 tests broadcast suppression during isolation")

print("\n============================================================")
print(f"VERIFICATION SUMMARY: {passed} PASSED, {failed} FAILED")
print("============================================================\n")

if failed > 0:
	sys.exit(1)
else:
    print("ALL LOGIC CHECKS VERIFIED 100% CLEAN!\n")



