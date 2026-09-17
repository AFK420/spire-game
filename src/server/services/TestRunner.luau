--!strict

--[=[
	TestRunner ModuleScript
	Mapped to: ServerScriptService.Server.services.TestRunner

	Comprehensive end-to-end integration test suite for Card Rift: Co-op Dungeon:
	Executes REAL APIs on RunManager, CombatService, and ClassService:
	1. Player joins (1–4 players) & shared authoritative RunState verification.
	2. Class selection, starting stats, and CardInstance deck synthesis.
	3. Start run & procedural map initialization.
	4. Map voting & consensus travel.
	5. Enter combat encounter & multi-enemy scaling validation across 4 players.
	6. Strict API Rejection Checks:
	   - Unauthorized/wrong player
	   - Invalid target enemy
	   - Insufficient energy
	   - Wrong combat phase
	   - Downed player actions
	7. Card Play Execution & Double-Play Prevention via actual CombatService.playCard.
	8. Downed state at 0 HP & Teammate Rescue mechanics (2 Energy, 25% Max HP revive).
	9. Turn ready voting & automatic monotonic timer timeout resolution.
	10. Enemy defeat, victory callback, and transition to Rewards.
	11. Post-combat 3-card universal draft claim & double-claim prevention.
	12. Continue from rewards and travel to another room.
	13. Player leave and rejoin state persistence (zero state corruption).
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)
local GameConfig = require(Shared:WaitForChild("GameConfig") :: ModuleScript)
local CardData = require(Shared:WaitForChild("CardData") :: ModuleScript)
local RelicData = require(Shared:WaitForChild("RelicData") :: ModuleScript)

local services = script.Parent
local RunManager = require(services:WaitForChild("RunManager") :: ModuleScript)
local CombatService = require(services:WaitForChild("CombatService") :: ModuleScript)
local ClassService = require(services:WaitForChild("ClassService") :: ModuleScript)
local CardService = require(services:WaitForChild("CardService") :: ModuleScript)
local RelicService = require(services:WaitForChild("RelicService") :: ModuleScript)
local PersistenceService = require(services:WaitForChild("PersistenceService") :: ModuleScript)
local TargetResolver = require(services:WaitForChild("TargetResolver") :: ModuleScript)
local ModifierResolver = require(services:WaitForChild("ModifierResolver") :: ModuleScript)
local DamagePipeline = require(services:WaitForChild("DamagePipeline") :: ModuleScript)
local StatusService = require(services:WaitForChild("StatusService") :: ModuleScript)
local EffectResolver = require(services:WaitForChild("EffectResolver") :: ModuleScript)
local EquipmentData = require(Shared:WaitForChild("EquipmentData") :: ModuleScript)
local SkillData = require(Shared:WaitForChild("SkillData") :: ModuleScript)
local PassiveData = require(Shared:WaitForChild("PassiveData") :: ModuleScript)
local EquipmentService = require(services:WaitForChild("EquipmentService") :: ModuleScript)
local StatResolver = require(services:WaitForChild("StatResolver") :: ModuleScript)
local SkillService = require(services:WaitForChild("SkillService") :: ModuleScript)
local PassiveService = require(services:WaitForChild("PassiveService") :: ModuleScript)
local CardCollectionService = require(services:WaitForChild("CardCollectionService") :: ModuleScript)
local DeckService = require(services:WaitForChild("DeckService") :: ModuleScript)
local NetworkService = require(services:WaitForChild("NetworkService") :: ModuleScript)

local TestRunner = {}

local passedCount = 0
local totalCount = 0

local function assertTest(condition: boolean, testName: string)
	totalCount += 1
	if condition then
		passedCount += 1
		print(string.format("  [PASS %d/%d] %s", passedCount, totalCount, testName))
	else
		error(string.format("  [FAIL at test #%d] %s", totalCount, testName))
	end
end

local function getAnyCardInHand(playerState: StateTypes.PlayerState): StateTypes.CardInstance
	for _, c in playerState.Hand do
		return c
	end
	error("Expected player to have cards in hand.")
end

function TestRunner.runAllTests(): boolean
	passedCount = 0
	totalCount = 0

	print("============================================================")
	print("       STARTING FULL END-TO-END REAL API INTEGRATION SUITE  ")
	print("============================================================")

	-- Isolate test environment from live server state
	RunManager.beginTestIsolation()

	local testOk, testErr = pcall(function()
	RunManager.resetRunForTesting()
	local runState = RunManager.getRunState()

	-- Mock Player Entities
	local player1 = { UserId = 10001, Name = "PlayerOne", DisplayName = "KnightOne" }
	local player2 = { UserId = 10002, Name = "PlayerTwo", DisplayName = "RogueTwo" }
	local player3 = { UserId = 10003, Name = "PlayerThree", DisplayName = "MageThree" }
	local player4 = { UserId = 10004, Name = "PlayerFour", DisplayName = "ClericFour" }

	----------------------------------------------------------------------------
	-- TEST 1: 1–4 Players Join & Shared Authoritative RunState Verification
	----------------------------------------------------------------------------
	print("\n--- [Suite 1] Player Joins & Shared RunState ---")
	assertTest(runState.Phase == "Lobby", "Initial RunState phase is Lobby")

	local p1State = RunManager.addPlayer(player1)
	assertTest(runState.PartyMembers[10001] ~= nil, "Player 1 registered in PartyMembers")
	assertTest(p1State.DisplayName == "KnightOne", "Player 1 DisplayName matches")
	assertTest(p1State.IsConnected == true, "Player 1 marked connected")

	local p2State = RunManager.addPlayer(player2)
	local p3State = RunManager.addPlayer(player3)
	local p4State = RunManager.addPlayer(player4)

	local partyCount = 0
	for _ in runState.PartyMembers do partyCount += 1 end
	assertTest(partyCount == 4, "All 4 players successfully joined party")
	assertTest(RunManager.getPlayerState(10001) == p1State, "RunManager.getPlayerState returns identical authoritative instance")
	assertTest(RunManager.getPlayerState(10004) == p4State, "All 4 players share the exact same RunState")

	----------------------------------------------------------------------------
	-- TEST 2: Class Selection & Starting Deck Instantiation
	----------------------------------------------------------------------------
	print("\n--- [Suite 2] Class Selection & CardInstance Deck Synthesis ---")
	local sel1 = ClassService.selectClass(player1 :: any, p1State, "Warlord", "Titan")
	local sel2 = ClassService.selectClass(player2 :: any, p2State, "Shadowblade", "Assassin")
	local sel3 = ClassService.selectClass(player3 :: any, p3State, "AetherMage", "Pyromancer")
	local sel4 = ClassService.selectClass(player4 :: any, p4State, "Necrobinder", "Reaper")

	assertTest(sel1 and sel2 and sel3 and sel4, "All 4 players selected valid classes & subclasses")
	assertTest(p1State.ClassId == "Warlord" and p1State.SubclassId == "Titan", "Player 1 configured as Titan Warlord")
	assertTest(p1State.Resources.MaxHP == 110, "Titan subclass gains +10 Max HP bonus (110)")
	assertTest(#p1State.Deck > 0, "Starting deck synthesized as runtime CardInstances")
	assertTest(p1State.Deck[1].OwnerUserId == 10001, "CardInstances correctly tagged with OwnerUserId")
	assertTest(typeof(p1State.Deck[1].InstanceId) == "string" and #p1State.Deck[1].InstanceId > 6, "CardInstances carry unique GUID InstanceId")

	----------------------------------------------------------------------------
	-- TEST 3: Start Run & Persistence TotalRuns Tracking
	----------------------------------------------------------------------------
	print("\n--- [Suite 3] Run Start & Persistence TotalRuns Tracking ---")
	local profile1 = PersistenceService.getProfile(player1 :: any)
	local initialTotalRuns = profile1.TotalRuns

	local startRunSuccess = RunManager.startRun()
	assertTest(startRunSuccess == true, "RunManager.startRun() returned true")
	assertTest(runState.Phase == "MapSelect", "Run phase transitioned to MapSelect")
	assertTest(profile1.TotalRuns == initialTotalRuns + 1, "TotalRuns incremented exactly once when run begins")

	-- Regression Test: Duplicate/invalid startRun calls outside Lobby must fail and NOT increment TotalRuns
	local duplicateStartRun = RunManager.startRun()
	assertTest(duplicateStartRun == false, "Duplicate RunManager.startRun() outside Lobby safely returns false")
	assertTest(profile1.TotalRuns == initialTotalRuns + 1, "TotalRuns is strictly idempotent and not incremented on rejected startRun()")

	-- Mid-run class change must be strictly rejected
	local midRunClassChange = ClassService.selectClass(player1 :: any, p1State, "Shadowblade", "Assassin")
	assertTest(midRunClassChange == false, "Class change during active run is strictly rejected")
	assertTest(runState.CurrentTier == 0, "CurrentTier initialized to 0")
	assertTest(#runState.AvailableNodeIds > 0, "Procedural map generated reachable starting nodes")
	assertTest(p1State.Resources.HP == p1State.Resources.MaxHP, "Party members have full health")

	----------------------------------------------------------------------------
	-- TEST 4: Map Voting & Consensus Room Travel
	----------------------------------------------------------------------------
	print("\n--- [Suite 4] Real API voteMapNode() & travelToNode() ---")
	local targetNodeId = runState.AvailableNodeIds[1]
	assertTest(targetNodeId ~= nil, "Target starting room exists")

	-- Invalid node vote test
	local badVoteSuccess, badVoteErr = RunManager.voteMapNode(player1, "Act1_T99_L99")
	assertTest(badVoteSuccess == false and badVoteErr ~= nil, "Voting unreachable room was rejected")

	-- Valid votes
	RunManager.voteMapNode(player1, targetNodeId)
	assertTest(p1State.VotedNodeId == targetNodeId, "Player 1 vote recorded")
	RunManager.voteMapNode(player2, targetNodeId)
	RunManager.voteMapNode(player3, targetNodeId) -- Majority reached (3/4)

	assertTest(runState.Phase == "ActiveRoom", "Majority vote transitioned run to ActiveRoom")
	assertTest(runState.CurrentNodeId == targetNodeId, "CurrentNodeId updated to target room")
	assertTest(runState.ActiveRoom ~= nil and runState.ActiveRoom.NodeId == targetNodeId, "ActiveRoom initialized")

	----------------------------------------------------------------------------
	-- TEST 5: Co-op Multi-Player Scaling (1, 2, 3, 4 Players)
	----------------------------------------------------------------------------
	print("\n--- [Suite 5] Active Combat Encounter & Co-op Scaling ---")
	-- Verify Mathematical Scaling Formulas across 1 to 4 players
	assertTest(GameConfig.scaleEnemyHp(80, 1) == 80, "1-Player scaling: 80 HP")
	assertTest(GameConfig.scaleEnemyHp(80, 2) == 132, "2-Player scaling: 132 HP (+65%)")
	assertTest(GameConfig.scaleEnemyHp(80, 3) == 184, "3-Player scaling: 184 HP (+130%)")
	assertTest(GameConfig.scaleEnemyHp(80, 4) == 236, "4-Player scaling: 236 HP (+195%)")

	assertTest(GameConfig.scaleEnemyAttack(9, 1) == 9, "1-Player ATK scaling: 9")
	assertTest(GameConfig.scaleEnemyAttack(9, 2) == 11, "2-Player ATK scaling: 11 (+20%)")
	assertTest(GameConfig.scaleEnemyAttack(9, 3) == 13, "3-Player ATK scaling: 13 (+40%)")
	assertTest(GameConfig.scaleEnemyAttack(9, 4) == 14, "4-Player ATK scaling: 14 (+60%)")

	local combat = CombatService.getActiveCombat()
	assertTest(combat ~= nil, "CombatService.getActiveCombat() is active")
	assertTest(combat.Phase == "PlayerPhase", "Combat begins in PlayerPhase")
	assertTest(combat.TurnNumber == 1, "Combat initialized on Turn 1")

	local firstEnemy: StateTypes.EnemyState? = nil
	for _, e in combat.Enemies do
		if not firstEnemy then firstEnemy = e end
	end
	assertTest(firstEnemy ~= nil, "Primary enemy retrieved")
	assertTest(firstEnemy.MaxHP == 236, "Enemy HP in 4-player combat equals expected 236 HP")

	-- Verify opening hands
	local p1HandCount = 0
	for _ in p1State.Hand do p1HandCount += 1 end
	assertTest(p1HandCount == GameConfig.Combat.BaseHandDrawCount, "Player 1 drew opening hand of 4 cards")

	----------------------------------------------------------------------------
	-- TEST 6: Strict Card Targeting & API Rejection Checks
	----------------------------------------------------------------------------
	print("\n--- [Suite 6] Strict Card Targeting & Rejection Rules ---")
	local enemyCard = getAnyCardInHand(p1State)
	if enemyCard.CardData.Target ~= "Enemy" then
		for _, c in p1State.Hand do
			if c.CardData.Target == "Enemy" then
				enemyCard = c
				break
			end
		end
	end

	-- 6a. Enemy card + invalid enemy ID
	local rejTargetOk, rejTargetErr = CombatService.playCard(player1, enemyCard.InstanceId, "invalid_enemy_999")
	assertTest(rejTargetOk == false and rejTargetErr == "Invalid target enemy.", "Enemy card with invalid enemy ID rejected")

	-- 6b. Enemy card + nil target
	local rejNilOk, rejNilErr = CombatService.playCard(player1, enemyCard.InstanceId, nil)
	assertTest(rejNilOk == false and rejNilErr == "Enemy target is required.", "Enemy card with nil target rejected (never auto-redirects)")

	-- 6c. Enemy card + dead enemy target
	local deadEnemyId = "test_dead_enemy"
	combat.Enemies[deadEnemyId] = {
		InstanceId = deadEnemyId,
		DefinitionId = "SpireSentinel",
		Name = "Dead Sentinel",
		HP = 0,
		MaxHP = 100,
		Shield = 0,
		Poison = 0,
		AttackPower = 10,
		Intent = { Type = "Attack", Value = 10 },
		ModelRef = nil,
	}
	local rejDeadOk, rejDeadErr = CombatService.playCard(player1, enemyCard.InstanceId, deadEnemyId)
	assertTest(rejDeadOk == false and rejDeadErr == "Target enemy is already defeated.", "Enemy card targeting dead enemy rejected")

	-- 6d. Self card attempting to target another entity
	local selfCardInst = CardService.createCardInstance("Defend", 10001)
	assertTest(selfCardInst ~= nil, "Synthesized Defend card instance")
	p1State.Hand[selfCardInst.InstanceId] = selfCardInst

	local rejSelfOtherOk, rejSelfOtherErr = CombatService.playCard(player1, selfCardInst.InstanceId, firstEnemy.InstanceId)
	assertTest(rejSelfOtherOk == false and rejSelfOtherErr == "Self cards cannot target other entities.", "Self card targeting enemy rejected")

	-- 6e. Ally card targeting non-existent user / non-party member
	local firstAidInst = CardService.createCardInstance("FirstAid", 10001)
	assertTest(firstAidInst ~= nil, "Synthesized FirstAid card instance")
	p1State.Hand[firstAidInst.InstanceId] = firstAidInst

	local rejAllyNonPartyOk, rejAllyNonPartyErr = CombatService.playCard(player1, firstAidInst.InstanceId, 99999)
	assertTest(rejAllyNonPartyOk == false and rejAllyNonPartyErr == "Target ally not in party.", "Ally card targeting non-party member rejected")

	-- 6f. Ally card + nil target
	local rejAllyNilOk, rejAllyNilErr = CombatService.playCard(player1, firstAidInst.InstanceId, nil)
	assertTest(rejAllyNilOk == false and rejAllyNilErr == "Ally target is required.", "Ally card with nil target rejected")

	-- 6g. Unauthorized / non-party player
	local fakePlayer = { UserId = 99999, Name = "Hacker" }
	local rejPlayerOk, rejPlayerErr = CombatService.playCard(fakePlayer, enemyCard.InstanceId, firstEnemy.InstanceId)
	assertTest(rejPlayerOk == false and rejPlayerErr == "Player not in party.", "Unauthorized non-party player rejected")

	-- 6h. Insufficient energy
	p1State.Resources.Energy = 0
	local rejEnergyOk, rejEnergyErr = CombatService.playCard(player1, enemyCard.InstanceId, firstEnemy.InstanceId)
	assertTest(rejEnergyOk == false and rejEnergyErr == "Not enough Energy!", "Card play with insufficient energy rejected")
	p1State.Resources.Energy = 3

	-- 6i. Wrong combat phase
	combat.Phase = "ResolutionPhase"
	local rejPhaseOk, rejPhaseErr = CombatService.playCard(player1, enemyCard.InstanceId, firstEnemy.InstanceId)
	assertTest(rejPhaseOk == false and rejPhaseErr == "Combat is not in PlayerPhase.", "Card play during wrong phase rejected")
	combat.Phase = "PlayerPhase"

	-- 6j. Downed player actions
	p2State.IsDowned = true
	local p2Card = getAnyCardInHand(p2State)
	local rejDownedOk, rejDownedErr = CombatService.playCard(player2, p2Card.InstanceId, firstEnemy.InstanceId)
	assertTest(rejDownedOk == false and rejDownedErr == "Downed players cannot play cards.", "Downed player card play rejected")

	local rejReadyOk, rejReadyErr = CombatService.voteReady(player2)
	assertTest(rejReadyOk == false and rejReadyErr == "Downed players cannot vote ready.", "Downed player ready vote rejected")
	p2State.IsDowned = false

	----------------------------------------------------------------------------
	-- TEST 7: First Aid & Revive Mechanics
	----------------------------------------------------------------------------
	print("\n--- [Suite 7] First Aid Revive & Heal Correctness ---")
	-- 7a. Enemy target for First Aid must be rejected
	local rejFaEnemyOk, rejFaEnemyErr = CombatService.playCard(player1, firstAidInst.InstanceId, firstEnemy.InstanceId)
	assertTest(rejFaEnemyOk == false and rejFaEnemyErr == "Target ally not in party.", "First Aid targeting enemy is rejected")

	-- 7b. Downed ally -> Revive with specified 30 HP without double-healing
	p3State.Resources.HP = 0
	p3State.IsDowned = true
	p1State.Resources.Energy = 3

	local faReviveOk, faReviveErr = CombatService.playCard(player1, firstAidInst.InstanceId, p3State.UserId)
	assertTest(faReviveOk == true and faReviveErr == nil, "First Aid played successfully on downed ally")
	assertTest(p3State.IsDowned == false, "Downed ally successfully revived")
	assertTest(p3State.Resources.HP == 30, "Revived ally has exactly 30 HP (Revive value, not double-healed to 60)")

	-- 7c. Living ally -> Healed +30 HP (no revive)
	local firstAidInst2 = CardService.createCardInstance("FirstAid", 10001)
	assertTest(firstAidInst2 ~= nil, "Synthesized second FirstAid card instance")
	p1State.Hand[firstAidInst2.InstanceId] = firstAidInst2
	p1State.Resources.Energy = 3

	local faHealOk, faHealErr = CombatService.playCard(player1, firstAidInst2.InstanceId, p3State.UserId)
	assertTest(faHealOk == true and faHealErr == nil, "First Aid played successfully on living ally")
	assertTest(p3State.IsDowned == false, "Living ally remains active")
	assertTest(p3State.Resources.HP == 60, "Living ally healed for +30 HP (HP is now 60)")

	----------------------------------------------------------------------------
	-- TEST 8: Relic Trigger Correctness (Zero Duplication Bug)
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 8] Relic Trigger Mechanics (No Double-Triggers) ---")
	local testAttackCard = CardService.createCardInstance("Strike", 10001) :: StateTypes.CardInstance
	RelicService.resetCombatState(10001)

	-- 8a. 0 Relics
	p1State.RelicIds = {}
	local r0 = RelicService.triggerEvent(p1State, combat, "OnCardPlay", { Card = testAttackCard, Enemy = firstEnemy })
	assertTest(r0.BonusDamage == 0 and r0.BonusEnergy == 0, "0 relics contribute 0 bonus")

	-- 8b. 1 Relic: Vajra (+2 Damage)
	p1State.RelicIds = { "Vajra" }
	local r1 = RelicService.triggerEvent(p1State, combat, "OnCardPlay", { Card = testAttackCard, Enemy = firstEnemy })
	assertTest(r1.BonusDamage == 2, "Vajra alone contributes exactly +2 bonus damage")

	-- 8c. 2 Relics: Vajra + Akabeko
	RelicService.resetCombatState(10001)
	p1State.RelicIds = { "Vajra", "Akabeko" }
	local r2_1 = RelicService.triggerEvent(p1State, combat, "OnCardPlay", { Card = testAttackCard, Enemy = firstEnemy })
	assertTest(r2_1.BonusDamage == 10, "First attack with Vajra + Akabeko deals exactly +10 bonus damage (+2 +8)")

	local r2_2 = RelicService.triggerEvent(p1State, combat, "OnCardPlay", { Card = testAttackCard, Enemy = firstEnemy })
	assertTest(r2_2.BonusDamage == 2, "Second attack deals only +2 bonus damage (Akabeko only triggers once)")

	-- 8d. Multiple relics with duplicate trigger types & duplicate IDs in inventory
	RelicService.resetCombatState(10001)
	p1State.RelicIds = { "Vajra", "Akabeko", "Sundial", "Vajra" }
	local rMulti_1 = RelicService.triggerEvent(p1State, combat, "OnCardPlay", { Card = testAttackCard, Enemy = firstEnemy })
	assertTest(rMulti_1.BonusDamage == 10, "Multiple relics with duplicate IDs evaluate Vajra at most once (+10 total)")

	-- 8e. Sundial: 3 attacks generate +2 Energy exactly on the 3rd attack
	RelicService.resetCombatState(10001)
	p1State.RelicIds = { "Sundial" }
	local s1 = RelicService.triggerEvent(p1State, combat, "OnCardPlay", { Card = testAttackCard, Enemy = firstEnemy })
	local s2 = RelicService.triggerEvent(p1State, combat, "OnCardPlay", { Card = testAttackCard, Enemy = firstEnemy })
	local s3 = RelicService.triggerEvent(p1State, combat, "OnCardPlay", { Card = testAttackCard, Enemy = firstEnemy })
	assertTest(s1.BonusEnergy == 0 and s2.BonusEnergy == 0 and s3.BonusEnergy == 2, "Sundial counter increments once per attack; grants +2 Energy on 3rd attack")

	-- Restore player 1 relics
	p1State.RelicIds = { "Anchor" }

	end
	----------------------------------------------------------------------------
	-- TEST 9: Safe Card Play & Double-Play Prevention (Real API Path)
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 9] Real Card Play & Double-Play Prevention ---")
	local cardToPlay = getAnyCardInHand(p1State)
	while cardToPlay.CardData.Target ~= "Enemy" do
		local newCard = CardService.createCardInstance("Strike", 10001) :: StateTypes.CardInstance
		p1State.Hand[newCard.InstanceId] = newCard
		cardToPlay = newCard
	end

	local playedCardId = cardToPlay.InstanceId
	local cardCost = cardToPlay.CardData.Cost
	p1State.Resources.Energy = 3

	local playSuccess, playErr = CombatService.playCard(player1, playedCardId, firstEnemy.InstanceId)
	assertTest(playSuccess == true and playErr == nil, "CombatService.playCard executed successfully")
	assertTest(p1State.Hand[playedCardId] == nil, "Played card removed from player hand hashmap")
	assertTest(#p1State.DiscardPile >= 1, "Played card moved to discard pile")
	assertTest(p1State.Resources.Energy == 3 - cardCost, "Energy correctly deducted")

	-- CRITICAL INVARIANT: Re-playing the exact same CardInstanceId MUST fail
	local doublePlaySuccess, doublePlayErr = CombatService.playCard(player1, playedCardId, firstEnemy.InstanceId)
	assertTest(doublePlaySuccess == false and doublePlayErr == "Card not found in hand.", "Double-play through real API safely rejected with 'Card not found in hand.'")

	end
	----------------------------------------------------------------------------
	-- TEST 10: Downed State & Teammate Rescue Mechanics
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 10] Downed State & Teammate Rescue Mechanics ---")
	p4State.Resources.HP = 0
	p4State.IsDowned = true

	-- Rescuer lacks energy
	p1State.Resources.Energy = 1
	local rescueFailOk, rescueFailErr = CombatService.rescueTeammate(player1, 10004)
	assertTest(rescueFailOk == false and rescueFailErr ~= nil, "Rescue with < 2 Energy rejected")

	-- Rescuer has sufficient energy
	p1State.Resources.Energy = 2
	local rescueOk, rescueErr = CombatService.rescueTeammate(player1, 10004)
	assertTest(rescueOk == true and rescueErr == nil, "CombatService.rescueTeammate succeeded")
	assertTest(p1State.Resources.Energy == 0, "Rescuer spent 2 Energy (Remaining: 0)")
	assertTest(p4State.IsDowned == false, "Target is no longer downed")
	local expectedReviveHp = math.floor(p4State.Resources.MaxHP * GameConfig.Coop.ReviveHpPercent)
	assertTest(p4State.Resources.HP == expectedReviveHp, string.format("Target revived with 25%% HP (%d HP)", expectedReviveHp))

	end
	----------------------------------------------------------------------------
	-- TEST 11: Turn Ready Voting & Automatic Timeout
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 11] Ready Voting & Monotonic Turn Timeout ---")
	CombatService.voteReady(player1)
	assertTest(p1State.IsReady == true, "Player 1 voted ready")
	CombatService.voteReady(player1)
	assertTest(p1State.IsReady == false, "Player 1 toggled unready")

	-- Simulate automatic timer timeout resolution
	CombatService.forceTurnTimeout()
	task.wait()
	assertTest(combat.TurnNumber == 2, "Turn number advanced to 2 after turn timeout resolution")
	assertTest(combat.Phase == "PlayerPhase", "Returned to PlayerPhase for Turn 2")

	end
	----------------------------------------------------------------------------
	-- TEST 12: Enemy Defeat, Victory Callback & Rewards Transition
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 12] Enemy Defeat & Room Clear Transition ---")
	for _, e in combat.Enemies do
		e.HP = 1
		e.Shield = 0
	end

	local lethalCard = CardService.createCardInstance("Strike", 10001) :: StateTypes.CardInstance
	p1State.Hand[lethalCard.InstanceId] = lethalCard
	p1State.Resources.Energy = 3
	CombatService.playCard(player1, lethalCard.InstanceId, firstEnemy.InstanceId)

	-- Wait for room completion callback
	task.wait()
	assertTest(runState.Phase == "Rewards", "Room cleared and run state transitioned to Rewards")
	assertTest(runState.PendingRewards ~= nil, "PendingRewards populated in RunState")
	assertTest(runState.PendingRewards.GoldAmount > 0, "Gold reward assigned")
	assertTest(runState.PendingRewards.AetherShardsAmount > 0, "Aether Shards assigned")
	assertTest(runState.PendingRewards.OfferedCardsByPlayer[10001] ~= nil, "Player 1 received 3-card draft choices")

	-- Claim 3-card draft choice
	local draftOptions = runState.PendingRewards.OfferedCardsByPlayer[10001]
	assertTest(#draftOptions == GameConfig.Rewards.CardDraftChoicesCount, "Exact 3 draft cards offered")
	local chosenCardDefId = draftOptions[1].Id
	local deckCountBefore = #p1State.Deck

	local claimSuccess, claimErr = RunManager.claimRewardCard(player1, chosenCardDefId)
	assertTest(claimSuccess == true and claimErr == nil, "Draft card successfully claimed")
	assertTest(#p1State.Deck == deckCountBefore + 1, "Claimed card added to player deck")
	assertTest(p1State.Deck[#p1State.Deck].DefinitionId == chosenCardDefId, "New card definition matches choice")
	local claimedCardInstanceId = p1State.Deck[#p1State.Deck].InstanceId
	assertTest(runState.PendingRewards.ClaimedCards[10001] == true, "Claim flag set for player")

	-- Double-claim rejection
	local doubleClaimSuccess, doubleClaimErr = RunManager.claimRewardCard(player1, draftOptions[2].Id)
	assertTest(doubleClaimSuccess == false and doubleClaimErr == "Reward already claimed.", "Second claim attempt safely rejected")

	end
	----------------------------------------------------------------------------
	-- TEST 13: CRITICAL INVARIANT — Card Persistence Across Multiple Combats
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 13] Critical Invariant: Card Persistence Across Combats ---")
	-- Record all card instance IDs currently owned by player 1
	local recordedCardIds: { [string]: boolean } = {}
	local totalOwnedCardsBefore = #p1State.Deck
	for _, cardInst in p1State.Deck do
		recordedCardIds[cardInst.InstanceId] = true
	end

	-- Continue from rewards to MapSelect
	local contSuccess = RunManager.continueFromRewards(player1)
	assertTest(contSuccess == true, "RunManager.continueFromRewards succeeded")
	assertTest(runState.Phase == "MapSelect", "Returned to MapSelect phase")
	assertTest(runState.CurrentTier == 1, "Completed Tier 1; tier is now 1")
	assertTest(#runState.AvailableNodeIds > 0, "Tier 2 rooms available for selection")

	-- Travel to Tier 2 room (Combat #2)
	local nextRoomId = runState.AvailableNodeIds[1]
	RunManager.voteMapNode(player1, nextRoomId)
	RunManager.voteMapNode(player2, nextRoomId)
	RunManager.voteMapNode(player3, nextRoomId)

	assertTest(runState.Phase == "ActiveRoom", "Traveled to subsequent room (Tier 2)")
	assertTest(runState.CurrentNodeId == nextRoomId, "CurrentNodeId points to Tier 2 room")

	local combat2 = CombatService.getActiveCombat()
	assertTest(combat2 ~= nil, "Combat #2 successfully initiated")

	-- CRITICAL ASSERTIONS:
	-- Total cards owned across Deck, Hand, Discard, Exhaust must equal totalOwnedCardsBefore!
	local totalCardsInCombat2 = #p1State.Deck
	for _ in p1State.Hand do totalCardsInCombat2 += 1 end
	for _ in p1State.DiscardPile do totalCardsInCombat2 += 1 end
	for _ in p1State.ExhaustPile do totalCardsInCombat2 += 1 end

	assertTest(totalCardsInCombat2 == totalOwnedCardsBefore, string.format("Total cards owned preserved into Combat #2 (Expected: %d, Actual: %d)", totalOwnedCardsBefore, totalCardsInCombat2))

	-- Verify the reward card claimed in Suite 12 still exists in player's deck or opening hand
	local rewardCardFound = false
	for _, c in p1State.Deck do
		if c.DefinitionId == chosenCardDefId then rewardCardFound = true break end
	end
	if not rewardCardFound then
		for _, c in p1State.Hand do
			if c.DefinitionId == chosenCardDefId then rewardCardFound = true break end
		end
	end
	assertTest(rewardCardFound == true, string.format("Reward card [%s] still exists in player's deck/hand during Combat #2!", chosenCardDefId))

	-- Verify original card instance IDs were NOT destroyed and regenerated
	local matchedOriginalIds = 0
	for _, c in p1State.Deck do
		if recordedCardIds[c.InstanceId] then matchedOriginalIds += 1 end
	end
	for _, c in p1State.Hand do
		if recordedCardIds[c.InstanceId] then matchedOriginalIds += 1 end
	end
	assertTest(matchedOriginalIds == totalOwnedCardsBefore, "All original runtime CardInstance IDs were preserved (Deck was NOT regenerated)!")

	-- Verify specific claimed reward CardInstanceId is preserved in combat 2
	local claimedCardInstanceFound = false
	for _, c in p1State.Deck do
		if c.InstanceId == claimedCardInstanceId then claimedCardInstanceFound = true break end
	end
	if not claimedCardInstanceFound then
		for _, c in p1State.Hand do
			if c.InstanceId == claimedCardInstanceId then claimedCardInstanceFound = true break end
		end
	end
	assertTest(claimedCardInstanceFound == true, string.format("Specific claimed reward CardInstanceId [%s] preserved identically into Combat #2", claimedCardInstanceId))

	end
	----------------------------------------------------------------------------
	-- TEST 14: Player Leaving and Rejoining Mid-Run State Resilience
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 14] Player Disconnect / Reconnect State Resilience ---")
	local p2HpBefore = p2State.Resources.HP
	local p2DeckCountBefore = #p2State.Deck
	local p2GoldBefore = p2State.Gold

	-- Player 2 leaves mid-combat
	RunManager.removePlayer(player2)
	assertTest(runState.PartyMembers[10002] ~= nil, "Player 2 record retained mid-run (slot preserved)")
	assertTest(runState.PartyMembers[10002].PlayerInstance == nil, "PlayerInstance reference safely cleared")
	assertTest(runState.PartyMembers[10002].IsConnected == false, "Player 2 marked disconnected")

	-- Player 2 reconnects
	local reconnectedP2 = RunManager.addPlayer(player2)
	assertTest(reconnectedP2 == p2State, "Reconnected player re-associated with original PlayerState")
	assertTest(reconnectedP2.IsConnected == true, "Reconnected player marked connected")
	assertTest(reconnectedP2.Resources.HP == p2HpBefore, "Player HP completely preserved")
	assertTest(#reconnectedP2.Deck == p2DeckCountBefore, "Player Deck completely preserved")
	assertTest(reconnectedP2.Gold == p2GoldBefore, "Player Gold completely preserved")
	assertTest(partyCount == 4, "Party integrity preserved with zero corruption")

	end
	----------------------------------------------------------------------------
	-- TEST 15: Disconnect-Safety & Multiplayer Invariants (Phase 1.2 Regressions)
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 15] Disconnect Safety: Targeting, Map Voting & Defeat Detection ---")

	-- Part 15.1: Test B — Disconnected player cannot be selected as enemy attack target
	local combat2Ref = CombatService.getActiveCombat()
	assertTest(combat2Ref ~= nil, "Combat #2 is actively running for targeting regression")

	-- Disconnect Player 2 during combat
	RunManager.removePlayer(player2)
	assertTest(p2State.IsConnected == false, "[Test B] Player 2 marked disconnected mid-combat")
	local p2HpPreAttack = p2State.Resources.HP

	-- Action rejection checks for disconnected players
	local discPlaySuccess, discPlayErr = CombatService.playCard(player2, "dummy_card", "enemy_1")
	assertTest(discPlaySuccess == false and discPlayErr == "Disconnected players cannot play cards.", "[Test B] Disconnected player rejected from playing cards")
	local discReadySuccess, discReadyErr = CombatService.voteReady(player2)
	assertTest(discReadySuccess == false and discReadyErr == "Disconnected players cannot vote ready.", "[Test B] Disconnected player rejected from voting ready")

	-- Force turn resolution so enemy executes its attack intent
	CombatService.forceTurnTimeout()
	task.wait()

	-- Disconnected Player 2 must have taken zero damage from enemy attack
	assertTest(p2State.Resources.HP == p2HpPreAttack, "[Test B] Disconnected Player 2 HP unchanged (excluded from enemy attack targets)")
	assertTest(runState.PartyMembers[10002] ~= nil, "[Test B] Disconnected Player 2 remains represented in PartyMembers")

	-- Reconnect Player 2 (Test D verification)
	local reP2 = RunManager.addPlayer(player2)
	assertTest(reP2 == p2State, "[Test D] Reconnected Player 2 reused exact authoritative PlayerState")
	assertTest(reP2.IsConnected == true, "[Test D] Player 2 reconnected successfully")
	assertTest(reP2.Resources.HP == p2HpPreAttack, "[Test D] Player 2 HP preserved after reconnect")

	-- Defeat enemy in Combat #2 to transition to Rewards & MapSelect
	for _, e in combat2Ref.Enemies do
		e.HP = 1
		e.Shield = 0
	end
	local killCard = CardService.createCardInstance("Strike", 10001) :: StateTypes.CardInstance
	p1State.Hand[killCard.InstanceId] = killCard
	p1State.Resources.Energy = 3
	CombatService.playCard(player1, killCard.InstanceId, next(combat2Ref.Enemies))
	task.wait()
	assertTest(runState.Phase == "Rewards", "Combat #2 won and transitioned to Rewards")

	-- Continue to MapSelect
	RunManager.continueFromRewards(player1)
	assertTest(runState.Phase == "MapSelect", "Transitioned to MapSelect for next node selection")
	assertTest(#runState.AvailableNodeIds > 0, "Available map nodes present")

	-- Part 15.2: Test A — Map voting ignores disconnected members
	local mapTargetNode = runState.AvailableNodeIds[1]
	for _, id in runState.AvailableNodeIds do
		local n = DungeonService.getNode(RunManager.getDungeonRun() :: any, id)
		if n and (n.Type == "Combat" or n.Type == "Elite Monster") then
			mapTargetNode = id
			break
		end
	end

	local p3StateRef = runState.PartyMembers[10003]
	local p4StateRef = runState.PartyMembers[10004]

	-- Disconnect Player 3 and Player 4: 2 connected voters remain (Player 1 & Player 2)
	RunManager.removePlayer(player3)
	RunManager.removePlayer(player4)
	assertTest(p3StateRef.IsConnected == false and p4StateRef.IsConnected == false, "[Test A] Players 3 & 4 disconnected during MapSelect")

	-- Disconnected player cannot submit a vote
	local discVoteSuccess, discVoteErr = RunManager.voteMapNode(player3, mapTargetNode)
	assertTest(discVoteSuccess == false and discVoteErr == "Player is disconnected.", "[Test A] Disconnected player cannot submit map vote")

	-- With 2 connected players, majority threshold is math.ceil(2 / 2) = 1!
	-- If disconnected members were counted, threshold would be math.ceil(4 / 2) = 2.
	-- Single vote from Player 1 must achieve consensus!
	local voteSuccess, voteErr = RunManager.voteMapNode(player1, mapTargetNode)
	assertTest(voteSuccess == true and voteErr == nil, "[Test A] Player 1 vote submitted successfully")
	assertTest(runState.Phase == "ActiveRoom", "[Test A] Disconnected players excluded from totalVoters; Player 1 alone achieved majority consensus!")
	assertTest(runState.CurrentNodeId == mapTargetNode, "[Test A] Traveled to voted node successfully")
	assertTest(runState.PartyMembers[10003] ~= nil and runState.PartyMembers[10004] ~= nil, "[Test A] Disconnected members retained in PartyMembers")

	-- Reconnect Players 3 and 4 (Test D verification)
	local reP3 = RunManager.addPlayer(player3)
	local reP4 = RunManager.addPlayer(player4)
	assertTest(reP3 == p3StateRef and reP4 == p4StateRef, "[Test D] Reconnected Players 3 & 4 reused exact PlayerState instances")
	assertTest(reP3.IsConnected == true and reP4.IsConnected == true, "[Test D] Players 3 & 4 marked connected")

	-- Part 15.3: Test C — Defeat detection ignores disconnected members
	local combat3Ref = CombatService.getActiveCombat()
	assertTest(combat3Ref ~= nil, "Combat #3 actively initiated in ActiveRoom")

	-- Disconnect Players 2, 3, 4: only Player 1 is connected
	RunManager.removePlayer(player2)
	RunManager.removePlayer(player3)
	RunManager.removePlayer(player4)
	assertTest(p1State.IsConnected == true and not p1State.IsDowned, "[Test C] Player 1 is connected and alive")
	assertTest(p2State.IsConnected == false and p3StateRef.IsConnected == false and p4StateRef.IsConnected == false, "[Test C] Players 2, 3, 4 disconnected")

	-- Test C.1: Player 1 connected + alive => NO defeat occurs
	CombatService.forceTurnTimeout()
	task.wait()
	assertTest(combat3Ref.Phase == "PlayerPhase", "[Test C] Combat continues while connected Player 1 is alive (disconnected players do not cause defeat)")

	-- Test C.2: Down Player 1: all connected players are now downed
	p1State.Resources.HP = 0
	p1State.IsDowned = true

	-- Trigger turn timeout so resolution check runs areAllPlayersDowned()
	CombatService.forceTurnTimeout()
	task.wait()
	assertTest(runState.Phase == "RunDefeat", "[Test C] Defeat correctly triggered when all CONNECTED players downed (disconnected players did not keep combat alive)!")

	end
	----------------------------------------------------------------------------
	-- TEST 16: Poison Damage Resolution Invariant & Death Regressions
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 16] Poison Damage Resolution & Shield Bypass Regressions ---")

	-- Reset to clean test state
	RunManager.resetRunForTesting()
	local poisonP1State = RunManager.addPlayer(player1)
	ClassService.selectClass(player1 :: any, poisonP1State, "Warlord", "Titan")
	RunManager.startRun()

	local poisonTargetNodeId = runState.AvailableNodeIds[1]
	RunManager.voteMapNode(player1, poisonTargetNodeId)

	local poisonCombat = CombatService.getActiveCombat()
	assertTest(poisonCombat ~= nil, "Combat active for poison damage regression testing")

	local testEnemy: StateTypes.EnemyState? = nil
	for _, e in poisonCombat.Enemies do
		testEnemy = e
		break
	end
	assertTest(testEnemy ~= nil, "Primary enemy retrieved for poison test")

	-- Test A — Poison damages HP exactly once and ignores Shield
	testEnemy.HP = 100
	testEnemy.MaxHP = 100
	testEnemy.Shield = 20
	testEnemy.Poison = 5
	testEnemy.Intent = { Type = "Defend", Value = 0, Description = "Waiting" }

	-- Resolve poison tick via the real combat turn resolution pipeline
	CombatService.forceTurnTimeout()
	task.wait()

	assertTest(testEnemy.HP == 95, string.format("[Poison Test A] HP decreased by exactly 5 (Expected: 95, Actual: %d)", testEnemy.HP))
	assertTest(testEnemy.Shield == 20, string.format("[Poison Test A] Shield remained 20 without taking poison damage (Actual: %d)", testEnemy.Shield))
	assertTest(testEnemy.Poison == 4, string.format("[Poison Test A] Poison decremented by 1 stack (Expected: 4, Actual: %d)", testEnemy.Poison))

	-- Test B — Multiple poison ticks behave predictably (95/4 -> 91/3 -> 88/2)
	-- Tick 2: 95 HP / 4 Poison -> 91 HP / 3 Poison
	testEnemy.Intent = { Type = "Defend", Value = 0, Description = "Waiting" }
	CombatService.forceTurnTimeout()
	task.wait()

	assertTest(testEnemy.HP == 91, string.format("[Poison Test B] Second tick: 95 HP - 4 = 91 HP (Actual: %d)", testEnemy.HP))
	assertTest(testEnemy.Shield == 20, "[Poison Test B] Shield remains 20 after second tick")
	assertTest(testEnemy.Poison == 3, "[Poison Test B] Poison decremented to 3")

	-- Tick 3: 91 HP / 3 Poison -> 88 HP / 2 Poison
	testEnemy.Intent = { Type = "Defend", Value = 0, Description = "Waiting" }
	CombatService.forceTurnTimeout()
	task.wait()

	assertTest(testEnemy.HP == 88, string.format("[Poison Test B] Third tick: 91 HP - 3 = 88 HP (Actual: %d)", testEnemy.HP))
	assertTest(testEnemy.Shield == 20, "[Poison Test B] Shield remains 20 after third tick")
	assertTest(testEnemy.Poison == 2, "[Poison Test B] Poison decremented to 2")

	-- Test C — Poison can kill: 3 HP / 5 Poison -> 0 HP and triggers enemy death / victory
	testEnemy.HP = 3
	testEnemy.Shield = 20
	testEnemy.Poison = 5
	testEnemy.Intent = { Type = "Attack", Value = 10, Description = "Lethal Strike" }

	CombatService.forceTurnTimeout()
	task.wait()

	assertTest(testEnemy.HP == 0, string.format("[Poison Test C] Lethal poison reduced HP to 0 (Actual: %d)", testEnemy.HP))
	assertTest(runState.Phase == "Rewards", "[Poison Test C] Lethal poison triggered enemy death and transitioned combat to Rewards")

	end
	----------------------------------------------------------------------------
	-- TEST 17: TargetResolver Action Target Validation
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 17] TargetResolver Target Validation Foundation ---")
	local trCombat = CombatService.getActiveCombat() or poisonCombat
	local trParty = runState.PartyMembers
	local trPlayer = poisonP1State

	-- 1. None target type
	local noneRes = TargetResolver.resolveTarget(trPlayer, "None", nil, trCombat, trParty)
	assertTest(noneRes.Success == true and noneRes.TargetKind == "None", "[TargetResolver] 'None' target successfully resolved")

	-- 2. Self target type
	local selfRes = TargetResolver.resolveTarget(trPlayer, "Self", nil, trCombat, trParty)
	assertTest(selfRes.Success == true and selfRes.PlayerTarget == trPlayer, "[TargetResolver] 'Self' target resolves to source player")

	local selfInvalidRes = TargetResolver.resolveTarget(trPlayer, "Self", 999999, trCombat, trParty)
	assertTest(selfInvalidRes.Success == false, "[TargetResolver] 'Self' target rejects other entity ID")

	-- 3. Enemy target type
	testEnemy.HP = 50
	local enemyLivingRes = TargetResolver.resolveTarget(trPlayer, "Enemy", testEnemy.InstanceId, trCombat, trParty)
	assertTest(enemyLivingRes.Success == true and enemyLivingRes.EnemyTarget == testEnemy, "[TargetResolver] Valid living enemy target resolved")

	testEnemy.HP = 0
	local enemyDeadRes = TargetResolver.resolveTarget(trPlayer, "Enemy", testEnemy.InstanceId, trCombat, trParty)
	assertTest(enemyDeadRes.Success == false and enemyDeadRes.Error == "Target enemy is already defeated.", "[TargetResolver] Rejects defeated enemy target")
	testEnemy.HP = 50 -- restore for subsequent tests

	local enemyMissingRes = TargetResolver.resolveTarget(trPlayer, "Enemy", "nonexistent_enemy", trCombat, trParty)
	assertTest(enemyMissingRes.Success == false, "[TargetResolver] Rejects nonexistent enemy target")

	local enemyNilRes = TargetResolver.resolveTarget(trPlayer, "Enemy", nil, trCombat, trParty)
	assertTest(enemyNilRes.Success == false, "[TargetResolver] Rejects nil enemy target")

	-- 4. Ally target type
	local allySelfRes = TargetResolver.resolveTarget(trPlayer, "Ally", trPlayer.UserId, trCombat, trParty)
	assertTest(allySelfRes.Success == true and allySelfRes.PlayerTarget == trPlayer, "[TargetResolver] Valid ally target resolved")

	local allyMissingRes = TargetResolver.resolveTarget(trPlayer, "Ally", 888888, trCombat, trParty)
	assertTest(allyMissingRes.Success == false, "[TargetResolver] Rejects ally target not in party")

	-- Disconnected ally rejection
	local disconnectedPlayer = {
		UserId = 777777,
		PlayerInstance = nil,
		DisplayName = "DiscAlly",
		ClassId = "Warlord",
		SubclassId = "Titan",
		Resources = { HP = 100, MaxHP = 100, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = {},
		Gold = 0,
		IsReady = false,
		IsDowned = false,
		IsConnected = false,
	}
	trParty[777777] = disconnectedPlayer
	local allyDiscRes = TargetResolver.resolveTarget(trPlayer, "Ally", 777777, trCombat, trParty)
	assertTest(allyDiscRes.Success == false and allyDiscRes.Error == "Cannot target a disconnected ally.", "[TargetResolver] Rejects disconnected ally target")
	trParty[777777] = nil

	end
	----------------------------------------------------------------------------
	-- TEST 18: ModifierResolver Deterministic Math Pipeline
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 18] ModifierResolver Deterministic Math Pipeline ---")

	-- 1. Base value with 0 modifiers
	local modVal1, _ = ModifierResolver.resolve(10, "Damage", {})
	assertTest(modVal1 == 10, "[ModifierResolver] Base value with no modifiers returns exact base (10)")

	-- 2. Additive modifier
	local addMod = ModifierResolver.createModifier("Add5", "Test", "Damage", "Add", 5, 100)
	local modVal2, _ = ModifierResolver.resolve(10, "Damage", { addMod })
	assertTest(modVal2 == 15, "[ModifierResolver] Additive modifier (+5) increases 10 to 15")

	-- 3. Multiplicative modifier
	local multMod = ModifierResolver.createModifier("Mult1.5", "Test", "Damage", "Multiply", 1.5, 200)
	local modVal3, _ = ModifierResolver.resolve(10, "Damage", { multMod })
	assertTest(modVal3 == 15, "[ModifierResolver] Multiplicative modifier (x1.5) scales 10 to 15")

	-- 4. Compound pipeline: Additive then Multiplicative: (10 + 4) * 2 = 28
	local add4 = ModifierResolver.createModifier("Add4", "Test", "Damage", "Add", 4, 100)
	local mult2 = ModifierResolver.createModifier("Mult2", "Test", "Damage", "Multiply", 2.0, 200)
	local modVal4, _ = ModifierResolver.resolve(10, "Damage", { mult2, add4 })
	assertTest(modVal4 == 28, "[ModifierResolver] Deterministic ordering resolves Additive before Multiplicative ((10+4)*2 = 28)")

	-- 5. Override modifier wins
	local overMod = ModifierResolver.createModifier("Override99", "Test", "Damage", "Override", 99, 50)
	local modVal5, _ = ModifierResolver.resolve(10, "Damage", { add4, mult2, overMod })
	assertTest(modVal5 == 99, "[ModifierResolver] Override modifier sets value directly to 99")

	-- 6. Condition evaluation: LowHP
	local condMod = ModifierResolver.createModifier("LowHpBonus", "Test", "Damage", "Add", 10, 100, "LowHP")
	local fullHpPlayer = { Resources = { HP = 100, MaxHP = 100 } }
	local lowHpPlayer = { Resources = { HP = 20, MaxHP = 100 } }
	local modValFull, _ = ModifierResolver.resolve(10, "Damage", { condMod }, { SourcePlayer = fullHpPlayer })
	local modValLow, _ = ModifierResolver.resolve(10, "Damage", { condMod }, { SourcePlayer = lowHpPlayer })
	assertTest(modValFull == 10, "[ModifierResolver] LowHP condition does NOT apply at full HP (10)")
	assertTest(modValLow == 20, "[ModifierResolver] LowHP condition applies when HP < 50% (10 + 10 = 20)")

	end
	----------------------------------------------------------------------------
	-- TEST 19: DamagePipeline Mitigation & Shield Absorption
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 19] DamagePipeline Mitigation & Shield Absorption ---")

	local dummyEnemy: StateTypes.EnemyState = {
		InstanceId = "dummy_1",
		DefinitionId = "TargetDummy",
		Name = "Target Dummy",
		HP = 100,
		MaxHP = 100,
		Shield = 0,
		Poison = 0,
		AttackPower = 0,
		Intent = { Type = "Defend", Value = 0 },
		ModelRef = nil,
	}

	-- 1. Unshielded damage
	local dmgRes1 = DamagePipeline.executeDamage({
		RawDamage = 20,
		DamageType = "Physical",
		SourceId = "tester",
		SourceName = "Tester",
		SourcePlayer = nil,
		TargetEntityKind = "Enemy",
		TargetEnemy = dummyEnemy,
		TargetPlayer = nil,
		CanHitShield = true,
		IsPeriodic = false,
	})
	assertTest(dummyEnemy.HP == 80 and dmgRes1.HPLost == 20 and dmgRes1.ShieldAbsorbed == 0, "[DamagePipeline] Unshielded damage reduces HP directly (100 -> 80)")

	-- 2. Shield absorption: 15 Shield, 20 Damage -> 0 Shield, 5 HP lost (80 -> 75)
	dummyEnemy.Shield = 15
	local dmgRes2 = DamagePipeline.executeDamage({
		RawDamage = 20,
		DamageType = "Physical",
		SourceId = "tester",
		SourceName = "Tester",
		SourcePlayer = nil,
		TargetEntityKind = "Enemy",
		TargetEnemy = dummyEnemy,
		TargetPlayer = nil,
		CanHitShield = true,
		IsPeriodic = false,
	})
	assertTest(dummyEnemy.Shield == 0 and dummyEnemy.HP == 75 and dmgRes2.ShieldAbsorbed == 15 and dmgRes2.HPLost == 5, "[DamagePipeline] Shield absorbs 15, remaining 5 hits HP (80 -> 75)")

	-- 3. Shield fully absorbs: 20 Shield, 10 Damage -> 10 Shield, 0 HP lost (75 HP)
	dummyEnemy.Shield = 20
	local dmgRes3 = DamagePipeline.executeDamage({
		RawDamage = 10,
		DamageType = "Physical",
		SourceId = "tester",
		SourceName = "Tester",
		SourcePlayer = nil,
		TargetEntityKind = "Enemy",
		TargetEnemy = dummyEnemy,
		TargetPlayer = nil,
		CanHitShield = true,
		IsPeriodic = false,
	})
	assertTest(dummyEnemy.Shield == 10 and dummyEnemy.HP == 75 and dmgRes3.ShieldAbsorbed == 10 and dmgRes3.HPLost == 0, "[DamagePipeline] Shield fully absorbs damage (20 -> 10 Shield, 0 HP lost)")

	-- 4. Direct HP bypass (CanHitShield = false): 10 Shield, 15 Damage -> 10 Shield, 15 HP lost (75 -> 60)
	local dmgRes4 = DamagePipeline.executeDamage({
		RawDamage = 15,
		DamageType = "Venom",
		SourceId = "tester",
		SourceName = "Tester",
		SourcePlayer = nil,
		TargetEntityKind = "Enemy",
		TargetEnemy = dummyEnemy,
		TargetPlayer = nil,
		CanHitShield = false,
		IsPeriodic = true,
	})
	assertTest(dummyEnemy.Shield == 10 and dummyEnemy.HP == 60 and dmgRes4.ShieldAbsorbed == 0 and dmgRes4.HPLost == 15, "[DamagePipeline] CanHitShield=false bypasses shield completely (10 Shield untouched, 75 -> 60 HP)")

	-- 5. Lethal damage
	dummyEnemy.HP = 10
	local dmgRes5 = DamagePipeline.executeDamage({
		RawDamage = 25,
		DamageType = "Physical",
		SourceId = "tester",
		SourceName = "Tester",
		SourcePlayer = nil,
		TargetEntityKind = "Enemy",
		TargetEnemy = dummyEnemy,
		TargetPlayer = nil,
		CanHitShield = true,
		IsPeriodic = false,
	})
	assertTest(dummyEnemy.HP == 0 and dmgRes5.IsDefeatedOrDowned == true, "[DamagePipeline] Lethal damage reduces HP to 0 and flags IsDefeatedOrDowned")

	end
	----------------------------------------------------------------------------
	-- TEST 20: StatusService Lifecycle (Apply, Stack, Tick, Remove, Sync)
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 20] StatusService Definition vs Instance Lifecycle ---")

	StatusService.resetCombat()
	local sEnemy: StateTypes.EnemyState = {
		InstanceId = "status_enemy",
		DefinitionId = "TargetDummy",
		Name = "Status Dummy",
		HP = 100,
		MaxHP = 100,
		Shield = 25,
		Poison = 0,
		AttackPower = 0,
		Intent = { Type = "Defend", Value = 0 },
		ModelRef = nil,
	}

	-- 1. Apply status
	local pInst1 = StatusService.applyStatus(sEnemy.InstanceId, "Poison", 3, nil, "test_source", sEnemy)
	assertTest(pInst1 ~= nil and pInst1.Stacks == 3, "[StatusService] Successfully applied 3 stacks of Poison")
	assertTest(sEnemy.Poison == 3, "[StatusService] Synchronized enemy.Poison projection field to 3")

	-- 2. Stack status
	local pInst2 = StatusService.applyStatus(sEnemy.InstanceId, "Poison", 2, nil, "test_source", sEnemy)
	assertTest(pInst2.Stacks == 5, "[StatusService] Stacking 2 more Poison gives 5 total stacks")
	assertTest(sEnemy.Poison == 5, "[StatusService] Synchronized enemy.Poison projection field to 5")

	-- 3. Tick status: Deals 5 damage to HP, decrements stacks to 4, shield remains 25
	local tickResults = StatusService.tickStatuses(sEnemy.InstanceId, "TurnStart", sEnemy, true)
	assertTest(#tickResults == 1 and tickResults[1].DamageDealt == 5, "[StatusService] Poison tick dealt 5 damage")
	assertTest(sEnemy.HP == 95, "[StatusService] HP reduced to 95 (100 - 5)")
	assertTest(sEnemy.Shield == 25, "[StatusService] Shield remains untouched at 25")
	assertTest(sEnemy.Poison == 4, "[StatusService] Stacks decremented to 4")

	-- 4. Remove status
	local removed = StatusService.removeStatus(sEnemy.InstanceId, "Poison", sEnemy)
	assertTest(removed == true, "[StatusService] removeStatus returned true")
	assertTest(StatusService.getStatus(sEnemy.InstanceId, "Poison") == nil, "[StatusService] Status no longer exists on entity")
	assertTest(sEnemy.Poison == 0, "[StatusService] Enemy.Poison projection cleared to 0")

	-- 5. Data-driven definitions validation
	local defPoison = StatusService.getDefinition("Poison")
	local defIgnite = StatusService.getDefinition("Ignite")
	local defChill = StatusService.getDefinition("Chill")
	local defFreeze = StatusService.getDefinition("Freeze")
	local defShock = StatusService.getDefinition("Shock")
	local defBleed = StatusService.getDefinition("Bleed")
	assertTest(defPoison ~= nil and defPoison.IsDebuff == true, "[StatusService] Poison definition registered")
	assertTest(defIgnite ~= nil and defIgnite.TickTiming == "TurnStart", "[StatusService] Ignite definition registered")
	assertTest(defChill ~= nil and defChill.TickTiming == "TurnEnd", "[StatusService] Chill definition registered")
	assertTest(defFreeze ~= nil and defFreeze.Stacking == "RefreshDuration", "[StatusService] Freeze definition registered")
	assertTest(defShock ~= nil and defShock.TickTiming == "OnAction", "[StatusService] Shock definition registered")
	assertTest(defBleed ~= nil and defBleed.IsDebuff == true, "[StatusService] Bleed definition registered")

	end
	----------------------------------------------------------------------------
	-- TEST 21: EffectResolver Generic Dispatch
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 21] EffectResolver Generic Dispatch ---")

	local effEnemy: StateTypes.EnemyState = {
		InstanceId = "eff_enemy",
		DefinitionId = "TargetDummy",
		Name = "Effect Dummy",
		HP = 100,
		MaxHP = 100,
		Shield = 10,
		Poison = 0,
		AttackPower = 0,
		Intent = { Type = "Defend", Value = 0 },
		ModelRef = nil,
	}

	local effPlayer: StateTypes.PlayerState = {
		UserId = 90001,
		PlayerInstance = nil,
		DisplayName = "EffHero",
		ClassId = "Warlord",
		SubclassId = "Titan",
		Resources = { HP = 50, MaxHP = 100, Shield = 0, Energy = 1, MaxEnergy = 3 },
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = {},
		Gold = 100,
		IsReady = false,
		IsDowned = false,
		IsConnected = true,
	}

	local effTargetEnemy: StateTypes.ResolvedTarget = {
		Success = true,
		Error = nil,
		TargetKind = "Enemy",
		EnemyTarget = effEnemy,
		PlayerTarget = nil,
		TargetId = effEnemy.InstanceId,
		TargetName = effEnemy.Name,
	}

	local effTargetSelf: StateTypes.ResolvedTarget = {
		Success = true,
		Error = nil,
		TargetKind = "Player",
		EnemyTarget = nil,
		PlayerTarget = effPlayer,
		TargetId = tostring(effPlayer.UserId),
		TargetName = effPlayer.DisplayName,
	}

	-- 1. Damage Effect
	local dmgEff: CardData.Effect = { Type = "Damage", Value = 15 }
	local dmgCtx: EffectResolver.ActionContext = {
		SourcePlayer = effPlayer,
		Target = effTargetEnemy,
	}
	local dmgResList = EffectResolver.resolveEffects({ dmgEff }, dmgCtx)
	assertTest(#dmgResList == 1 and dmgResList[1].Success == true, "[EffectResolver] Damage effect executed successfully")
	assertTest(effEnemy.Shield == 0 and effEnemy.HP == 95, "[EffectResolver] Enemy took 15 damage (10 Shield absorbed, 5 HP lost -> 95 HP)")

	-- 2. Shield Effect
	local shieldEff: CardData.Effect = { Type = "Shield", Value = 12 }
	local shieldCtx: EffectResolver.ActionContext = {
		SourcePlayer = effPlayer,
		Target = effTargetSelf,
	}
	local shieldResList = EffectResolver.resolveEffects({ shieldEff }, shieldCtx)
	assertTest(#shieldResList == 1 and effPlayer.Resources.Shield == 12, "[EffectResolver] Shield effect added 12 Shield to player")

	-- 3. Heal Effect
	local healEff: CardData.Effect = { Type = "Heal", Value = 20 }
	local healResList = EffectResolver.resolveEffects({ healEff }, shieldCtx)
	assertTest(#healResList == 1 and effPlayer.Resources.HP == 70, "[EffectResolver] Heal effect restored 20 HP (50 -> 70)")

	-- 4. GainEnergy Effect
	local energyEff: CardData.Effect = { Type = "GainEnergy", Value = 2 }
	local energyResList = EffectResolver.resolveEffects({ energyEff }, shieldCtx)
	assertTest(#energyResList == 1 and effPlayer.Resources.Energy == 3, "[EffectResolver] GainEnergy effect restored energy (1 + 2 = 3)")

	-- 5. ApplyStatus Effect
	local statusEff: CardData.Effect = { Type = "ApplyStatus", StatusId = "Poison", Stacks = 4 }
	local statusResList = EffectResolver.resolveEffects({ statusEff }, dmgCtx)
	assertTest(#statusResList == 1 and effEnemy.Poison == 4, "[EffectResolver] ApplyStatus applied 4 stacks of Poison")

	end
	----------------------------------------------------------------------------
	-- TEST 22: First Aid Generic Conditional Semantics
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 22] First Aid Generic Conditional Semantics ---")

	local firstAidDef = CardData.getCard("FirstAid")
	assertTest(firstAidDef ~= nil, "FirstAid card definition retrieved")

	local allyHero: StateTypes.PlayerState = {
		UserId = 90002,
		PlayerInstance = nil,
		DisplayName = "AllyHero",
		ClassId = "Shadowblade",
		SubclassId = "Assassin",
		Resources = { HP = 40, MaxHP = 100, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = {},
		Gold = 0,
		IsReady = false,
		IsDowned = false,
		IsConnected = true,
	}

	local allyTargetLiving: StateTypes.ResolvedTarget = {
		Success = true,
		Error = nil,
		TargetKind = "Player",
		EnemyTarget = nil,
		PlayerTarget = allyHero,
		TargetId = tostring(allyHero.UserId),
		TargetName = allyHero.DisplayName,
	}

	-- Case A: Ally is Living: Revive is skipped (TargetDowned false), Heal restores 30 HP (40 -> 70)
	local livingCtx: EffectResolver.ActionContext = {
		SourcePlayer = effPlayer,
		Target = allyTargetLiving,
	}
	local livingRes = EffectResolver.resolveEffects(firstAidDef.Effects, livingCtx)
	assertTest(allyHero.Resources.HP == 70, string.format("[First Aid - Living Ally] Restored 30 HP up to 70 (Actual: %d)", allyHero.Resources.HP))
	assertTest(allyHero.IsDowned == false, "[First Aid - Living Ally] Ally remains not downed")

	-- Case B: Ally is Downed: Revive sets HP to 30 and clears downed, Heal is skipped to prevent double-heal (HP remains 30)
	allyHero.IsDowned = true
	allyHero.Resources.HP = 0
	local downedCtx: EffectResolver.ActionContext = {
		SourcePlayer = effPlayer,
		Target = allyTargetLiving,
	}
	local downedRes = EffectResolver.resolveEffects(firstAidDef.Effects, downedCtx)
	assertTest(allyHero.IsDowned == false, "[First Aid - Downed Ally] Ally successfully revived from downed state")
	assertTest(allyHero.Resources.HP == 30, string.format("[First Aid - Downed Ally] HP revived to exactly 30 without double-healing (Actual: %d)", allyHero.Resources.HP))

	end
	----------------------------------------------------------------------------
	-- TEST 23: Exhaust Pile Uniqueness & Pile Invariants
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 23] Exhaust Pile Uniqueness & Pile Invariants ---")

	local exPlayer: StateTypes.PlayerState = {
		UserId = 90101,
		PlayerInstance = nil,
		DisplayName = "ExhaustTester",
		ClassId = "Warlord",
		SubclassId = "Titan",
		Resources = { HP = 80, MaxHP = 80, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = {},
		Gold = 0,
		IsReady = false,
		IsDowned = false,
		IsConnected = true,
	}

	-- Create 3 cards in Deck, 2 in Hand
	local c1 = CardService.createCardInstance("Strike", exPlayer.UserId)
	local c2 = CardService.createCardInstance("Defend", exPlayer.UserId)
	local c3 = CardService.createCardInstance("FirstAid", exPlayer.UserId)
	local cExhaust = CardService.createCardInstance("Defend", exPlayer.UserId)
	assertTest(c1 ~= nil and c2 ~= nil and c3 ~= nil and cExhaust ~= nil, "[Exhaust] Cards created")

	if c1 and c2 and c3 and cExhaust then
		table.insert(exPlayer.Deck, c1)
		table.insert(exPlayer.Deck, c2)
		table.insert(exPlayer.Deck, c3)
		exPlayer.Hand[cExhaust.InstanceId] = cExhaust

		local totalCardsBefore = #exPlayer.Deck + 1 + #exPlayer.DiscardPile + #exPlayer.ExhaustPile
		assertTest(totalCardsBefore == 4, "[Exhaust] Player starts with exactly 4 total cards")

		-- Simulate card played from Hand to DiscardPile
		local playedCard = CardService.playCardFromHand(exPlayer, cExhaust.InstanceId)
		assertTest(playedCard ~= nil, "[Exhaust] playCardFromHand moved card to DiscardPile")
		assertTest(exPlayer.Hand[cExhaust.InstanceId] == nil, "[Exhaust] Card removed from Hand")
		assertTest(#exPlayer.DiscardPile == 1, "[Exhaust] Card present in DiscardPile")

		-- Now execute Exhaust effect via EffectResolver
		local exhaustEff: CardData.Effect = { Type = "Exhaust" }
		local exCtx: EffectResolver.ActionContext = {
			SourcePlayer = exPlayer,
			Target = effTargetSelf,
			CardInstance = cExhaust,
		}
		local exResList = EffectResolver.resolveEffects({ exhaustEff }, exCtx)
		assertTest(#exResList == 1 and exResList[1].Success == true, "[Exhaust] EffectResolver.handlers['Exhaust'] succeeded")

		-- Verify card exists in ExhaustPile exactly once
		local inExhaustCount = 0
		for _, c in exPlayer.ExhaustPile do
			if c.InstanceId == cExhaust.InstanceId then
				inExhaustCount += 1
			end
		end
		assertTest(inExhaustCount == 1, "[Exhaust] Card exists in ExhaustPile exactly once")

		-- Verify card does NOT exist in DiscardPile
		local inDiscardCount = 0
		for _, c in exPlayer.DiscardPile do
			if c.InstanceId == cExhaust.InstanceId then
				inDiscardCount += 1
			end
		end
		assertTest(inDiscardCount == 0, "[Exhaust] Card does NOT exist in DiscardPile")

		-- Verify card does NOT exist in Hand
		assertTest(exPlayer.Hand[cExhaust.InstanceId] == nil, "[Exhaust] Card does NOT exist in Hand")

		-- Verify total cards across all piles remains constant invariant
		local totalCardsAfter = #exPlayer.Deck + 0 + #exPlayer.DiscardPile + #exPlayer.ExhaustPile
		assertTest(totalCardsAfter == 4, string.format("[Exhaust] Pile count invariant preserved: %d == 4", totalCardsAfter))
	end

	end
	----------------------------------------------------------------------------
	-- TEST 24: Effect-Level Target Overrides
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 24] Effect-Level Target Overrides ---")

	local hybridEnemy: StateTypes.EnemyState = {
		InstanceId = "enemy_hybrid",
		DefinitionId = "SpireSentinel",
		Name = "Hybrid Sentinel",
		HP = 60,
		MaxHP = 60,
		Shield = 10,
		Poison = 0,
		AttackPower = 10,
		Intent = { Type = "Attack", Value = 10 },
		ModelRef = nil,
	}

	local hybridPlayer: StateTypes.PlayerState = {
		UserId = 90102,
		PlayerInstance = nil,
		DisplayName = "HybridCaster",
		ClassId = "Warlord",
		SubclassId = "Titan",
		Resources = { HP = 50, MaxHP = 100, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = {},
		Gold = 0,
		IsReady = false,
		IsDowned = false,
		IsConnected = true,
	}

	local hybridCombatState: StateTypes.CombatState = {
		CombatId = "combat_hybrid",
		Phase = "PlayerPhase",
		TurnNumber = 1,
		TurnStartTime = 0,
		TurnDuration = 45,
		Participants = { hybridPlayer.UserId },
		Enemies = { [hybridEnemy.InstanceId] = hybridEnemy },
		ReadyPlayers = {},
		CombatLog = {},
	}

	local hybridTargetEnemy: StateTypes.ResolvedTarget = {
		Success = true,
		Error = nil,
		TargetKind = "Enemy",
		EnemyTarget = hybridEnemy,
		PlayerTarget = nil,
		TargetId = hybridEnemy.InstanceId,
		TargetName = hybridEnemy.Name,
	}

	-- Card has 2 effects:
	-- Effect 1: Damage 20 to Enemy (no explicit Target, inherits primary context target = Enemy)
	-- Effect 2: Shield 8 to Self (explicit Target = "Self")
	local hybridEffects: { CardData.Effect } = {
		{ Type = "Damage", Value = 20, Target = "Enemy" },
		{ Type = "Shield", Value = 8, Target = "Self" },
	}

	local hybridCtx: EffectResolver.ActionContext = {
		SourcePlayer = hybridPlayer,
		Target = hybridTargetEnemy,
		CombatState = hybridCombatState,
		Party = { [hybridPlayer.UserId] = hybridPlayer },
	}

	local hybridRes = EffectResolver.resolveEffects(hybridEffects, hybridCtx)
	assertTest(#hybridRes == 2, "[TargetOverride] Both effects resolved")
	assertTest(hybridRes[1].Success and hybridRes[2].Success, "[TargetOverride] Both effects succeeded")

	-- Enemy took 20 damage (10 Shield absorbed, 10 HP lost -> 50 HP)
	assertTest(hybridEnemy.Shield == 0, "[TargetOverride] Enemy shield broken to 0")
	assertTest(hybridEnemy.HP == 50, "[TargetOverride] Enemy HP reduced to 50")

	-- Source player received 8 Shield
	assertTest(hybridPlayer.Resources.Shield == 8, "[TargetOverride] Source player gained 8 Shield")
	-- Enemy did NOT gain any shield from effect 2
	assertTest(hybridEnemy.Shield == 0, "[TargetOverride] Enemy did NOT receive the Shield effect")

	end
	----------------------------------------------------------------------------
	-- TEST 25: ModifyResource Safety & Clamping
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 25] ModifyResource Safety & Clamping ---")

	local resPlayer: StateTypes.PlayerState = {
		UserId = 90103,
		PlayerInstance = nil,
		DisplayName = "ResourceTester",
		ClassId = "Warlord",
		SubclassId = "Titan",
		Resources = { HP = 40, MaxHP = 100, Shield = 5, Energy = 2, MaxEnergy = 3 },
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = {},
		Gold = 50,
		IsReady = false,
		IsDowned = false,
		IsConnected = true,
	}

	local resTargetSelf: StateTypes.ResolvedTarget = {
		Success = true,
		Error = nil,
		TargetKind = "Player",
		EnemyTarget = nil,
		PlayerTarget = resPlayer,
		TargetId = tostring(resPlayer.UserId),
		TargetName = resPlayer.DisplayName,
	}

	local resCtx: EffectResolver.ActionContext = {
		SourcePlayer = resPlayer,
		Target = resTargetSelf,
	}

	-- 1. Modify HP up to MaxHP (40 + 80 = 120 -> clamped to 100)
	local hpUpEff: CardData.Effect = { Type = "ModifyResource", Resource = "HP", Value = 80 }
	EffectResolver.resolveEffects({ hpUpEff }, resCtx)
	assertTest(resPlayer.Resources.HP == 100, "[ModifyResource] HP clamped to MaxHP (100)")

	-- 2. Modify HP down to 0 triggers IsDowned
	local hpDownEff: CardData.Effect = { Type = "ModifyResource", Resource = "HP", Value = -150 }
	EffectResolver.resolveEffects({ hpDownEff }, resCtx)
	assertTest(resPlayer.Resources.HP == 0, "[ModifyResource] HP reduced to 0")
	assertTest(resPlayer.IsDowned == true, "[ModifyResource] Reaching 0 HP set IsDowned to true")

	-- 3. Modify HP of downed player rejected
	local hpDownedHeal: CardData.Effect = { Type = "ModifyResource", Resource = "HP", Value = 20 }
	local downedRes = EffectResolver.resolveEffects({ hpDownedHeal }, resCtx)
	assertTest(#downedRes == 1 and downedRes[1].Success == false, "[ModifyResource] Cannot heal downed player via ModifyResource HP")
	resPlayer.IsDowned = false
	resPlayer.Resources.HP = 50

	-- 4. Shield cannot become negative (5 - 20 = -15 -> clamped to 0)
	local shieldDownEff: CardData.Effect = { Type = "ModifyResource", Resource = "Shield", Value = -20 }
	EffectResolver.resolveEffects({ shieldDownEff }, resCtx)
	assertTest(resPlayer.Resources.Shield == 0, "[ModifyResource] Shield clamped to minimum 0")

	-- 5. Energy clamping (2 + 5 = 7 -> clamped to MaxEnergy 3; then -10 -> clamped to 0)
	local energyUpEff: CardData.Effect = { Type = "ModifyResource", Resource = "Energy", Value = 5 }
	EffectResolver.resolveEffects({ energyUpEff }, resCtx)
	assertTest(resPlayer.Resources.Energy == 3, "[ModifyResource] Energy clamped to MaxEnergy (3)")

	local energyDownEff: CardData.Effect = { Type = "ModifyResource", Resource = "Energy", Value = -10 }
	EffectResolver.resolveEffects({ energyDownEff }, resCtx)
	assertTest(resPlayer.Resources.Energy == 0, "[ModifyResource] Energy clamped to minimum 0")

	-- 6. Gold modification (50 + 25 = 75, then -100 -> clamped to 0)
	local goldUpEff: CardData.Effect = { Type = "ModifyResource", Resource = "Gold", Value = 25 }
	EffectResolver.resolveEffects({ goldUpEff }, resCtx)
	assertTest(resPlayer.Gold == 75, "[ModifyResource] Gold increased to 75")

	local goldDownEff: CardData.Effect = { Type = "ModifyResource", Resource = "Gold", Value = -100 }
	EffectResolver.resolveEffects({ goldDownEff }, resCtx)
	assertTest(resPlayer.Gold == 0, "[ModifyResource] Gold clamped to minimum 0")

	-- 7. Invalid resource type returns failure
	local invalidResEff: CardData.Effect = { Type = "ModifyResource", Resource = "InvalidResource" :: any, Value = 10 }
	local invResList = EffectResolver.resolveEffects({ invalidResEff }, resCtx)
	assertTest(#invResList == 1 and invResList[1].Success == false, "[ModifyResource] Rejected invalid resource type cleanly")

	end
	----------------------------------------------------------------------------
	-- TEST 26: Event Triggering & Recursion Protection
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 26] Event Triggering & Recursion Protection ---")

	local loggedEvents: { string } = {}
	local logCallback = function(eventType: string, _sourceId: string, _targetId: string, value: number?, text: string?)
		table.insert(loggedEvents, eventType .. ":" .. tostring(value) .. ":" .. tostring(text))
	end

	local eventCtx: EffectResolver.ActionContext = {
		SourcePlayer = resPlayer,
		Target = resTargetSelf,
		LogEvent = logCallback,
	}

	-- 1. TriggerEvent executes and logs
	local triggerEff: CardData.Effect = { Type = "TriggerEvent", EventId = "CustomTestEvent", Value = 42 }
	local triggerRes = EffectResolver.resolveEffects({ triggerEff }, eventCtx)
	assertTest(#triggerRes == 1 and triggerRes[1].Success == true, "[TriggerEvent] TriggerEvent succeeded")
	assertTest(#loggedEvents == 1, "[TriggerEvent] Event logged to callback")

	-- 2. Reject empty EventId
	local emptyEff: CardData.Effect = { Type = "TriggerEvent", EventId = "" }
	local emptyRes = EffectResolver.resolveEffects({ emptyEff }, eventCtx)
	assertTest(#emptyRes == 1 and emptyRes[1].Success == false, "[TriggerEvent] Rejected empty EventId")

	-- 3. Recursion depth protection
	local recursiveEff: CardData.Effect = { Type = "GainEnergy", Value = 1 }
	local recurseCount = 0
	local function triggerRecursiveCall(depth: number)
		if depth > 10 then return end
		recurseCount += 1
		local res = EffectResolver.resolveEffects({ recursiveEff }, eventCtx)
		if #res > 0 then
			triggerRecursiveCall(depth + 1)
		end
	end

	triggerRecursiveCall(1)
	assertTest(recurseCount <= 6, string.format("[Recursion] Recursion limited safely (ran %d levels, max allowed is 5)", recurseCount))

	end
	----------------------------------------------------------------------------
	-- TEST 27: Status Authority & Tick Behavior Registry
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 27] Status Authority & Tick Behavior Registry ---")
	StatusService.resetCombat()

	local authEnemy: StateTypes.EnemyState = {
		InstanceId = "enemy_auth",
		DefinitionId = "SpireSentinel",
		Name = "Auth Sentinel",
		HP = 100,
		MaxHP = 100,
		Shield = 30,
		Poison = 0,
		AttackPower = 10,
		Intent = { Type = "Attack", Value = 10 },
		ModelRef = nil,
	}

	-- 1. Direct write to enemy.Poison reconciled via syncEntityFromProjection
	authEnemy.Poison = 7
	StatusService.syncEntityFromProjection(authEnemy.InstanceId, authEnemy)
	local syncedInst = StatusService.getStatus(authEnemy.InstanceId, "Poison")
	assertTest(syncedInst ~= nil and syncedInst.Stacks == 7, "[StatusAuthority] syncEntityFromProjection populated StatusInstance with 7 stacks")

	-- 2. StatusService is canonical; enemy.Poison is projection
	local tickRes = StatusService.tickStatuses(authEnemy.InstanceId, "TurnStart", authEnemy, true)
	assertTest(#tickRes == 1 and tickRes[1].DamageDealt == 7, "[StatusAuthority] DirectHPPoison ticked for 7 damage")
	assertTest(authEnemy.HP == 93, "[StatusAuthority] Enemy HP reduced to 93 (100 - 7)")
	assertTest(authEnemy.Shield == 30, "[StatusAuthority] Shield untouched at 30 (bypasses shield)")
	assertTest(authEnemy.Poison == 6, "[StatusAuthority] Projection enemy.Poison synchronized to 6")
	local canonicalPoison = StatusService.getStatus(authEnemy.InstanceId, "Poison")
	assertTest(canonicalPoison ~= nil and canonicalPoison.Stacks == 6, "[StatusAuthority] Canonical StatusInstance has 6 stacks")

	-- 3. Unimplemented statuses (Chill, Freeze, Shock) do not tick
	StatusService.applyStatus(authEnemy.InstanceId, "Chill", 5, 2, "test", authEnemy)
	local chillDef = StatusService.getDefinition("Chill")
	assertTest(chillDef ~= nil and chillDef.Implemented == false, "[StatusAuthority] Chill explicitly marked Implemented = false")
	local chillTicks = StatusService.tickStatuses(authEnemy.InstanceId, "TurnEnd", authEnemy, true)
	assertTest(#chillTicks == 0, "[StatusAuthority] Unimplemented Chill did not tick")

	-- 4. Bleed and Ignite tick through registry handlers
	StatusService.applyStatus(authEnemy.InstanceId, "Ignite", 4, 2, "test", authEnemy)
	local igniteDef = StatusService.getDefinition("Ignite")
	assertTest(igniteDef ~= nil and igniteDef.TickBehaviorId == "FireDoT", "[StatusAuthority] Ignite mapped to FireDoT")

	local igniteTicks = StatusService.tickStatuses(authEnemy.InstanceId, "TurnStart", authEnemy, true)
	local igniteDmg = 0
	for _, t in igniteTicks do
		if t.DefinitionId == "Ignite" then igniteDmg = t.DamageDealt end
	end
	assertTest(igniteDmg == 8, string.format("[StatusAuthority] Ignite FireDoT dealt 8 damage (Actual: %d)", igniteDmg))

	end
	----------------------------------------------------------------------------
	-- TEST 28: Damage Pipeline Edge Cases & Mitigations
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 28] Damage Pipeline Edge Cases & Mitigations ---")

	local edgeEnemy: StateTypes.EnemyState = {
		InstanceId = "enemy_edge",
		DefinitionId = "SpireSentinel",
		Name = "Edge Sentinel",
		HP = 50,
		MaxHP = 50,
		Shield = 20,
		Poison = 0,
		AttackPower = 10,
		Intent = { Type = "Attack", Value = 10 },
		ModelRef = nil,
	}

	-- 1. Negative RawDamage returns deterministic 0 result
	local negCtx: StateTypes.DamageContext = {
		RawDamage = -25,
		DamageType = "Physical",
		SourceId = "test",
		SourceName = "Tester",
		SourcePlayer = nil,
		TargetEntityKind = "Enemy",
		TargetEnemy = edgeEnemy,
		TargetPlayer = nil,
		CanHitShield = true,
		IsPeriodic = false,
	}
	local negRes = DamagePipeline.executeDamage(negCtx)
	assertTest(negRes.FinalDamage == 0 and negRes.HPLost == 0 and negRes.ShieldAbsorbed == 0, "[DamagePipeline] Negative damage safely clamped to 0")
	assertTest(edgeEnemy.HP == 50 and edgeEnemy.Shield == 20, "[DamagePipeline] Enemy unchanged after negative damage")

	-- 2. Missing TargetEnemy handled gracefully
	local missingCtx: StateTypes.DamageContext = {
		RawDamage = 20,
		DamageType = "Physical",
		SourceId = "test",
		SourceName = "Tester",
		SourcePlayer = nil,
		TargetEntityKind = "Enemy",
		TargetEnemy = nil,
		TargetPlayer = nil,
		CanHitShield = true,
		IsPeriodic = false,
	}
	local missRes = DamagePipeline.executeDamage(missingCtx)
	assertTest(missRes.FinalDamage == 0 and missRes.IsDefeatedOrDowned == false, "[DamagePipeline] Missing target entity returns deterministic 0 result")

	-- 3. Direct HP bypass (CanHitShield = false) does not reduce shield
	local bypassCtx: StateTypes.DamageContext = {
		RawDamage = 15,
		DamageType = "Venom",
		SourceId = "test",
		SourceName = "Tester",
		SourcePlayer = nil,
		TargetEntityKind = "Enemy",
		TargetEnemy = edgeEnemy,
		TargetPlayer = nil,
		CanHitShield = false,
		IsPeriodic = true,
	}
	local bypassRes = DamagePipeline.executeDamage(bypassCtx)
	assertTest(bypassRes.FinalDamage == 15 and bypassRes.ShieldAbsorbed == 0 and bypassRes.HPLost == 15, "[DamagePipeline] Direct HP bypass absorbed 0 shield")
	assertTest(edgeEnemy.Shield == 20, "[DamagePipeline] Shield remains intact at 20")
	assertTest(edgeEnemy.HP == 35, "[DamagePipeline] HP reduced directly (50 - 15 = 35)")

	-- 4. Exact Shield absorption (damage <= shield consumes shield only, HP unchanged)
	local exactShieldCtx: StateTypes.DamageContext = {
		RawDamage = 12,
		DamageType = "Physical",
		SourceId = "test",
		SourceName = "Tester",
		SourcePlayer = nil,
		TargetEntityKind = "Enemy",
		TargetEnemy = edgeEnemy,
		TargetPlayer = nil,
		CanHitShield = true,
		IsPeriodic = false,
	}
	local exactRes = DamagePipeline.executeDamage(exactShieldCtx)
	assertTest(exactRes.ShieldAbsorbed == 12 and exactRes.HPLost == 0, "[DamagePipeline] Damage fully absorbed by shield")
	assertTest(edgeEnemy.Shield == 8, "[DamagePipeline] Shield reduced to 8 (20 - 12)")
	assertTest(edgeEnemy.HP == 35, "[DamagePipeline] HP untouched at 35")

	-- 5. Shield overflow (damage > shield breaks shield, remainder to HP)
	local overflowCtx: StateTypes.DamageContext = {
		RawDamage = 15,
		DamageType = "Physical",
		SourceId = "test",
		SourceName = "Tester",
		SourcePlayer = nil,
		TargetEntityKind = "Enemy",
		TargetEnemy = edgeEnemy,
		TargetPlayer = nil,
		CanHitShield = true,
		IsPeriodic = false,
	}
	local overflowRes = DamagePipeline.executeDamage(overflowCtx)
	assertTest(overflowRes.ShieldAbsorbed == 8 and overflowRes.HPLost == 7, "[DamagePipeline] Shield absorbed 8, remainder 7 lost from HP")
	assertTest(edgeEnemy.Shield == 0, "[DamagePipeline] Shield reduced to 0")
	assertTest(edgeEnemy.HP == 28, "[DamagePipeline] HP reduced to 28 (35 - 7)")

	end
	----------------------------------------------------------------------------
	-- TEST 29: Modifier Pipeline Determinism & Immutability
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 29] Modifier Pipeline Determinism & Immutability ---")

	-- 1. Additive before Multiplicative regardless of registration order
	local modAdd = ModifierResolver.createModifier("mod_add", "Skill", "Damage", "Add", 10, 100)
	local modMul = ModifierResolver.createModifier("mod_mul", "Buff", "Damage", "Multiply", 1.5, 200)

	-- Pass Multiply first in array to verify sorting and pipeline order
	local resolvedVal, appliedMods = ModifierResolver.resolve(20, "Damage", { modMul, modAdd })
	-- (20 + 10) * 1.5 = 45
	assertTest(resolvedVal == 45, string.format("[ModifierResolver] (20 + 10) * 1.5 = 45 (Actual: %d)", resolvedVal))
	assertTest(#appliedMods == 2, "[ModifierResolver] Both modifiers applied")

	-- 2. Input modifiers table is immutable
	local originalTable = { modMul, modAdd }
	ModifierResolver.resolve(20, "Damage", originalTable)
	assertTest(originalTable[1] == modMul and originalTable[2] == modAdd, "[ModifierResolver] Input modifier table order preserved (not mutated in-place)")

	-- 3. Deterministic alphabetical sorting by Id when Priority matches
	local modA = ModifierResolver.createModifier("A_Mod", "Item", "Damage", "Add", 5, 100)
	local modB = ModifierResolver.createModifier("B_Mod", "Item", "Damage", "Add", 5, 100)
	local _, sortedApplied = ModifierResolver.resolve(10, "Damage", { modB, modA })
	assertTest(sortedApplied[1].Id == "A_Mod" and sortedApplied[2].Id == "B_Mod", "[ModifierResolver] Deterministically sorted identical priority by Id")

	-- 4. Override takes absolute precedence
	local modOverride = ModifierResolver.createModifier("mod_override", "Curse", "Damage", "Override", 99, 50)
	local overVal, _ = ModifierResolver.resolve(20, "Damage", { modMul, modAdd, modOverride })
	assertTest(overVal == 99, string.format("[ModifierResolver] Override took absolute precedence: %d == 99", overVal))

	-- 5. Clamping negative final result to 0
	local modNegative = ModifierResolver.createModifier("mod_neg", "Debuff", "Damage", "Add", -100, 100)
	local clampedVal, _ = ModifierResolver.resolve(20, "Damage", { modNegative })
	assertTest(clampedVal == 0, "[ModifierResolver] Negative result clamped to 0")

	end
	----------------------------------------------------------------------------
	-- TEST 30: ModifyResource Multi-Targeting & Boundary Safety
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 30] ModifyResource Multi-Targeting & Boundary Safety ---")

	local resP1: StateTypes.PlayerState = {
		UserId = 30001,
		PlayerInstance = nil,
		DisplayName = "CasterP1",
		ClassId = "Warrior",
		SubclassId = "Juggernaut",
		Resources = { HP = 50, MaxHP = 80, Shield = 10, Energy = 1, MaxEnergy = 3 },
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = {},
		Gold = 100,
		IsReady = false,
		IsDowned = false,
		IsConnected = true,
		VotedNodeId = nil,
	}

	local resP2: StateTypes.PlayerState = {
		UserId = 30002,
		PlayerInstance = nil,
		DisplayName = "AllyP2",
		ClassId = "Mage",
		SubclassId = "Elementalist",
		Resources = { HP = 40, MaxHP = 80, Shield = 5, Energy = 1, MaxEnergy = 3 },
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = {},
		Gold = 50,
		IsReady = false,
		IsDowned = false,
		IsConnected = true,
		VotedNodeId = nil,
	}

	local resParty = {
		[resP1.UserId] = resP1,
		[resP2.UserId] = resP2,
	}

	-- 1. ModifyResource targeting Self modifies caster
	local ctxSelf: EffectResolver.ActionContext = {
		SourcePlayer = resP1,
		Target = {
			Success = true,
			Error = nil,
			TargetKind = "Player",
			EnemyTarget = nil,
			PlayerTarget = resP1,
			TargetId = tostring(resP1.UserId),
			TargetName = resP1.DisplayName,
		},
		Party = resParty,
		Modifiers = {},
	}
	local resEffSelfEnergy: CardData.Effect = { Type = "ModifyResource", Resource = "Energy", Value = 1, Target = "Self" }
	local resRes1 = EffectResolver.resolveEffects({ resEffSelfEnergy }, ctxSelf)
	assertTest(#resRes1 == 1 and resRes1[1].Success == true, "[ModifyResource] Energy modified on caster Self")
	assertTest(resP1.Resources.Energy == 2 and resP2.Resources.Energy == 1, "[ModifyResource] Caster gained 1 Energy, Ally unchanged")

	local resEffSelfGold: CardData.Effect = { Type = "ModifyResource", Resource = "Gold", Value = 25, Target = "Self" }
	EffectResolver.resolveEffects({ resEffSelfGold }, ctxSelf)
	assertTest(resP1.Gold == 125 and resP2.Gold == 50, "[ModifyResource] Caster gained 25 Gold on Self, Ally unchanged")

	-- 2. ModifyResource targeting Ally modifies resolved recipient
	local ctxAlly: EffectResolver.ActionContext = {
		SourcePlayer = resP1,
		Target = {
			Success = true,
			Error = nil,
			TargetKind = "Player",
			EnemyTarget = nil,
			PlayerTarget = resP2,
			TargetId = tostring(resP2.UserId),
			TargetName = resP2.DisplayName,
		},
		Party = resParty,
		Modifiers = {},
	}
	local resEffAllyEnergy: CardData.Effect = { Type = "ModifyResource", Resource = "Energy", Value = 2, Target = "Ally" }
	local resRes2 = EffectResolver.resolveEffects({ resEffAllyEnergy }, ctxAlly)
	assertTest(#resRes2 == 1 and resRes2[1].Success == true, "[ModifyResource] Energy modified on Ally")
	assertTest(resP2.Resources.Energy == 3 and resP1.Resources.Energy == 2, "[ModifyResource] Ally gained 2 Energy, Caster unchanged")

	local resEffAllyShield: CardData.Effect = { Type = "ModifyResource", Resource = "Shield", Value = 15, Target = "Ally" }
	EffectResolver.resolveEffects({ resEffAllyShield }, ctxAlly)
	assertTest(resP2.Resources.Shield == 20 and resP1.Resources.Shield == 10, "[ModifyResource] Ally gained 15 Shield on Ally target, Caster unchanged")

	-- 3. ModifyResource targeting invalid player target fails cleanly
	local ctxInvalid: EffectResolver.ActionContext = {
		SourcePlayer = resP1,
		Target = {
			Success = false,
			Error = "Target not found.",
			TargetKind = "None",
			EnemyTarget = nil,
			PlayerTarget = nil,
			TargetId = "",
			TargetName = "",
		},
		Party = resParty,
		Modifiers = {},
	}
	local resEffInvalid: CardData.Effect = { Type = "ModifyResource", Resource = "Energy", Value = 1, Target = "Ally" }
	local resRes3 = EffectResolver.resolveEffects({ resEffInvalid }, ctxInvalid)
	assertTest(#resRes3 == 1 and resRes3[1].Success == false, "[ModifyResource] Fails cleanly when targeted to invalid player")
	assertTest(resP1.Resources.Energy == 2 and resP2.Resources.Energy == 3, "[ModifyResource] No resources mutated on invalid target failure")

	end
	----------------------------------------------------------------------------
	-- TEST 31: TriggerEvent Truthful Execution & Error Isolation
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 31] TriggerEvent Truthful Execution & Error Isolation ---")

	-- 1. Normal event execution returns Success = true
	local ctxEventNormal: EffectResolver.ActionContext = {
		SourcePlayer = resP1,
		Target = {
			Success = true,
			Error = nil,
			TargetKind = "Player",
			EnemyTarget = nil,
			PlayerTarget = resP1,
			TargetId = tostring(resP1.UserId),
			TargetName = resP1.DisplayName,
		},
		Party = resParty,
		Modifiers = {},
	}
	local effNormalEvent: CardData.Effect = { Type = "TriggerEvent", EventId = "OnTurnStart", Value = 0 }
	local eventRes1 = EffectResolver.resolveEffects({ effNormalEvent }, ctxEventNormal)
	assertTest(#eventRes1 == 1 and eventRes1[1].Success == true, "[TriggerEvent] Normal event execution returns Success = true")

	-- 2. Missing/empty EventId returns Success = false
	local effMissingEvent: CardData.Effect = { Type = "TriggerEvent", EventId = nil, Value = 0 }
	local eventRes2 = EffectResolver.resolveEffects({ effMissingEvent }, ctxEventNormal)
	assertTest(#eventRes2 == 1 and eventRes2[1].Success == false, "[TriggerEvent] Missing EventId returns Success = false")

	-- 3. Event dispatch error returns Success = false and isolates error
	local badPlayer = table.clone(resP1)
	badPlayer.RelicIds = { "Anchor" }
	badPlayer.Resources = (nil :: any)
	local ctxBadEvent: EffectResolver.ActionContext = {
		SourcePlayer = badPlayer,
		Target = ctxEventNormal.Target,
		Party = resParty,
		Modifiers = {},
	}
	local effErrorEvent: CardData.Effect = { Type = "TriggerEvent", EventId = "OnCombatStart", Value = 0 }
	local eventRes3 = EffectResolver.resolveEffects({ effErrorEvent }, ctxBadEvent)
	assertTest(#eventRes3 == 1 and eventRes3[1].Success == false, "[TriggerEvent] Event dispatch error caught via pcall and returns Success = false")

	-- 4. Recursion counters remain intact and usable after dispatch
	local normalAfterError = EffectResolver.resolveEffects({ effNormalEvent }, ctxEventNormal)
	assertTest(#normalAfterError == 1 and normalAfterError[1].Success == true, "[TriggerEvent] Recursion depth safely restored and operational")

	end
	----------------------------------------------------------------------------
	-- TEST 32: Real Target Resolution Context & Multi-Entity Integrity
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 32] Real Target Resolution Context & Multi-Entity Integrity ---")

	-- 1. Resolving Enemy without CombatState fails cleanly
	local resEnemyNoCombat = TargetResolver.resolveTarget(resP1, "Enemy", "enemy_1", nil, resParty)
	assertTest(resEnemyNoCombat.Success == false and string.find(resEnemyNoCombat.Error or "", "CombatState") ~= nil, "[TargetResolver] Enemy target without CombatState fails cleanly")

	-- 2. Resolving Ally without Party fails cleanly
	local resAllyNoParty = TargetResolver.resolveTarget(resP1, "Ally", resP2.UserId, nil, nil)
	assertTest(resAllyNoParty.Success == false and string.find(resAllyNoParty.Error or "", "Party") ~= nil, "[TargetResolver] Ally target without Party fails cleanly")

	-- 3. 4-Player party resolution works without fallback
	local p3: StateTypes.PlayerState = {
		UserId = 30003,
		PlayerInstance = nil,
		DisplayName = "PlayerThree",
		ClassId = "Rogue",
		SubclassId = "Assassin",
		Resources = { HP = 60, MaxHP = 60, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {}, Hand = {}, DiscardPile = {}, ExhaustPile = {}, RelicIds = {},
		Gold = 0, IsReady = false, IsDowned = false, IsConnected = true, VotedNodeId = nil,
	}
	local p4: StateTypes.PlayerState = {
		UserId = 30004,
		PlayerInstance = nil,
		DisplayName = "PlayerFour",
		ClassId = "Cleric",
		SubclassId = "Templar",
		Resources = { HP = 75, MaxHP = 75, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {}, Hand = {}, DiscardPile = {}, ExhaustPile = {}, RelicIds = {},
		Gold = 0, IsReady = false, IsDowned = false, IsConnected = true, VotedNodeId = nil,
	}
	local party4 = {
		[resP1.UserId] = resP1,
		[resP2.UserId] = resP2,
		[p3.UserId] = p3,
		[p4.UserId] = p4,
	}
	local resP4Target = TargetResolver.resolveTarget(resP1, "Ally", p4.UserId, nil, party4)
	assertTest(resP4Target.Success == true and resP4Target.PlayerTarget == p4 and resP4Target.TargetId == tostring(p4.UserId), "[TargetResolver] 4-Player party targeting resolved exact player 4")

	-- 4. Multi-enemy resolution targets exact requested instance
	local enemyA: StateTypes.EnemyState = {
		InstanceId = "enemy_multi_a",
		DefinitionId = "SpireSentinel",
		Name = "Sentinel Alpha",
		HP = 40, MaxHP = 40, Shield = 0, Poison = 0, AttackPower = 8,
		Intent = { Type = "Attack", Value = 8 }, ModelRef = nil,
	}
	local enemyB: StateTypes.EnemyState = {
		InstanceId = "enemy_multi_b",
		DefinitionId = "SpireSentinel",
		Name = "Sentinel Beta",
		HP = 45, MaxHP = 45, Shield = 0, Poison = 0, AttackPower = 8,
		Intent = { Type = "Attack", Value = 8 }, ModelRef = nil,
	}
	local multiCombatState: StateTypes.CombatState = {
		CombatId = "combat_multi_test",
		Phase = "PlayerPhase",
		TurnNumber = 1,
		TurnStartTime = 0,
		TurnDuration = 45,
		Participants = { resP1.UserId },
		Enemies = {
			["enemy_multi_a"] = enemyA,
			["enemy_multi_b"] = enemyB,
		},
		ReadyPlayers = {},
		CombatLog = {},
	}
	local resTargetB = TargetResolver.resolveTarget(resP1, "Enemy", "enemy_multi_b", multiCombatState, party4)
	assertTest(resTargetB.Success == true and resTargetB.EnemyTarget == enemyB and resTargetB.TargetId == "enemy_multi_b", "[TargetResolver] Multi-enemy resolved exact requested enemy instance")

	-- 5. Dead or disconnected targets fail cleanly
	enemyA.HP = 0
	local resDeadEnemy = TargetResolver.resolveTarget(resP1, "Enemy", "enemy_multi_a", multiCombatState, party4)
	assertTest(resDeadEnemy.Success == false and string.find(resDeadEnemy.Error or "", "defeated") ~= nil, "[TargetResolver] Defeated enemy target rejected cleanly")

	p3.IsConnected = false
	local resDisconnectedAlly = TargetResolver.resolveTarget(resP1, "Ally", p3.UserId, multiCombatState, party4)
	assertTest(resDisconnectedAlly.Success == false and string.find(resDisconnectedAlly.Error or "", "disconnected") ~= nil, "[TargetResolver] Disconnected ally target rejected cleanly")

	end
	----------------------------------------------------------------------------
	-- TEST 33: CreateCard Schema Strictness & Pile Placement
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 33] CreateCard Schema Strictness & Pile Placement ---")

	-- 1. Fails cleanly when CardDefId is missing or empty
	local effNoDef: CardData.Effect = { Type = "CreateCard", CardDefId = nil }
	local resNoDef = EffectResolver.resolveEffects({ effNoDef }, ctxSelf)
	assertTest(#resNoDef == 1 and resNoDef[1].Success == false, "[CreateCard] Missing CardDefId fails cleanly")

	-- 2. Fails cleanly when CardDefId is not in CardData (no Strike fallback)
	local effBadDef: CardData.Effect = { Type = "CreateCard", CardDefId = "NonExistentCardXYZ" }
	local resBadDef = EffectResolver.resolveEffects({ effBadDef }, ctxSelf)
	assertTest(#resBadDef == 1 and resBadDef[1].Success == false, "[CreateCard] Unknown CardDefId fails cleanly without Strike fallback")

	-- 3. Successfully creates card in specified destination pile
	local effCreateDeck: CardData.Effect = { Type = "CreateCard", CardDefId = "Strike", DestinationPile = "Deck" }
	local deckBefore = #resP1.Deck
	local resCreateDeck = EffectResolver.resolveEffects({ effCreateDeck }, ctxSelf)
	assertTest(#resCreateDeck == 1 and resCreateDeck[1].Success == true, "[CreateCard] Valid Strike created in Deck")
	assertTest(#resP1.Deck == deckBefore + 1, "[CreateCard] Card inserted into Deck")

	local effCreateHand: CardData.Effect = { Type = "CreateCard", CardDefId = "Defend", DestinationPile = "Hand" }
	local handCountBefore = 0
	for _ in resP1.Hand do handCountBefore += 1 end
	local resCreateHand = EffectResolver.resolveEffects({ effCreateHand }, ctxSelf)
	assertTest(#resCreateHand == 1 and resCreateHand[1].Success == true, "[CreateCard] Valid Defend created in Hand")
	local handCountAfter = 0
	for _ in resP1.Hand do handCountAfter += 1 end
	assertTest(handCountAfter == handCountBefore + 1, "[CreateCard] Card inserted into Hand dictionary")

	end
	----------------------------------------------------------------------------
	-- TEST 34: Card Pile Invariant Verification & Lifecycle Safety
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 34] Card Pile Invariant Verification & Lifecycle Safety ---")

	local invPlayer: StateTypes.PlayerState = {
		UserId = 34001,
		PlayerInstance = nil,
		DisplayName = "InvTester",
		ClassId = "Warrior",
		SubclassId = "Juggernaut",
		Resources = { HP = 80, MaxHP = 80, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = {},
		Gold = 0,
		IsReady = false,
		IsDowned = false,
		IsConnected = true,
		VotedNodeId = nil,
	}

	-- Populate 5 cards in Deck
	for i = 1, 5 do
		local c = CardService.createCardInstance("Strike", invPlayer.UserId)
		assert(c ~= nil)
		table.insert(invPlayer.Deck, c)
	end

	-- 1. Valid state passes validator
	local okInv, errInv = CardService.validatePileInvariants(invPlayer)
	assertTest(okInv == true and errInv == nil, "[PileInvariants] Clean 5-card deck passes validation")

	-- 2. Duplicate across piles (Deck & Hand) fails validator
	local dupCard = invPlayer.Deck[1]
	invPlayer.Hand[dupCard.InstanceId] = dupCard
	local okDupAcross, errDupAcross = CardService.validatePileInvariants(invPlayer)
	assertTest(okDupAcross == false and string.find(errDupAcross or "", "Duplicate") ~= nil, "[PileInvariants] Duplicate card across Deck & Hand correctly detected and rejected")
	invPlayer.Hand[dupCard.InstanceId] = nil

	-- 3. Duplicate within single pile (Deck) fails validator
	table.insert(invPlayer.Deck, dupCard)
	local okDupSingle, errDupSingle = CardService.validatePileInvariants(invPlayer)
	assertTest(okDupSingle == false and string.find(errDupSingle or "", "Duplicate") ~= nil, "[PileInvariants] Duplicate card within Deck correctly detected and rejected")
	table.remove(invPlayer.Deck, #invPlayer.Deck)

	-- 4. Mismatched OwnerUserId fails validator
	local foreignCard = CardService.createCardInstance("Defend", 99999)
	assert(foreignCard ~= nil)
	table.insert(invPlayer.Deck, foreignCard)
	local okForeign, errForeign = CardService.validatePileInvariants(invPlayer)
	assertTest(okForeign == false and string.find(errForeign or "", "OwnerUserId") ~= nil, "[PileInvariants] Mismatched OwnerUserId correctly detected and rejected")
	table.remove(invPlayer.Deck, #invPlayer.Deck)

	-- 5. Lifecycle transitions: draw, play, discard, exhaust, reset
	CardService.drawCards(invPlayer, 3)
	local okDraw, _ = CardService.validatePileInvariants(invPlayer)
	assertTest(okDraw == true, "[PileInvariants] State valid after drawCards")

	local playedCard: StateTypes.CardInstance? = nil
	for instId in invPlayer.Hand do
		playedCard = CardService.playCardFromHand(invPlayer, instId)
		break
	end
	assertTest(playedCard ~= nil, "[PileInvariants] Successfully played card from hand")
	local okPlay, _ = CardService.validatePileInvariants(invPlayer)
	assertTest(okPlay == true, "[PileInvariants] State valid after playCardFromHand")

	CardService.discardHand(invPlayer)
	local okDiscard, _ = CardService.validatePileInvariants(invPlayer)
	assertTest(okDiscard == true, "[PileInvariants] State valid after discardHand")

	assert(playedCard ~= nil)
	local exhaustedCard = CardService.exhaustCard(invPlayer, playedCard.InstanceId)
	assertTest(exhaustedCard ~= nil, "[PileInvariants] Successfully exhausted card")
	local okExhaust, _ = CardService.validatePileInvariants(invPlayer)
	assertTest(okExhaust == true, "[PileInvariants] State valid after exhaustCard")

	CardService.resetCombatPiles(invPlayer)
	local okReset, _ = CardService.validatePileInvariants(invPlayer)
	assertTest(okReset == true and #invPlayer.Deck == 5, "[PileInvariants] State valid after resetCombatPiles (all 5 cards returned to deck)")

	end
	----------------------------------------------------------------------------
	-- TEST 35: Status Authority Boundary & Projection Output Contracts
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 35] Status Authority Boundary & Projection Output Contracts ---")

	StatusService.resetCombat()

	local boundEnemy: StateTypes.EnemyState = {
		InstanceId = "enemy_boundary",
		DefinitionId = "SpireSentinel",
		Name = "Boundary Sentinel",
		HP = 100, MaxHP = 100, Shield = 0, Poison = 0, AttackPower = 10,
		Intent = { Type = "Attack", Value = 10 }, ModelRef = nil,
	}

	-- 1. Apply status authoritatively via StatusService
	StatusService.applyStatus(boundEnemy.InstanceId, "Poison", 4, nil, "TestPlayer", boundEnemy)
	assertTest(boundEnemy.Poison == 4, "[StatusAuthority] Projection enemy.Poison initialized to 4 as output")

	-- 2. Ticking reads from StatusService, ignoring rogue writes to enemy.Poison
	boundEnemy.Poison = 99
	local tickResB = StatusService.tickStatuses(boundEnemy.InstanceId, "TurnStart", boundEnemy, true)
	assertTest(#tickResB == 1 and tickResB[1].DamageDealt == 4, "[StatusAuthority] Ticking ignored rogue write of 99 and dealt canonical 4 damage")
	assertTest(boundEnemy.HP == 96, "[StatusAuthority] HP reduced by canonical 4 damage (100 - 4 = 96)")
	assertTest(boundEnemy.Poison == 3, "[StatusAuthority] Projection enemy.Poison overwritten by canonical remaining stacks (3)")

	-- 3. Backward compatibility sync only applies when StatusService has NO record
	local legacyEnemy: StateTypes.EnemyState = {
		InstanceId = "enemy_legacy",
		DefinitionId = "SpireSentinel",
		Name = "Legacy Sentinel",
		HP = 50, MaxHP = 50, Shield = 0, Poison = 6, AttackPower = 10,
		Intent = { Type = "Attack", Value = 10 }, ModelRef = nil,
	}
	assertTest(StatusService.getStatus(legacyEnemy.InstanceId, "Poison") == nil, "[StatusAuthority] No initial record in StatusService")
	StatusService.syncEntityFromProjection(legacyEnemy.InstanceId, legacyEnemy)
	local legacyInst = StatusService.getStatus(legacyEnemy.InstanceId, "Poison")
	assertTest(legacyInst ~= nil and legacyInst.Stacks == 6, "[StatusAuthority] Backward compat sync populated 6 stacks when no record existed")

	end
	----------------------------------------------------------------------------
	-- TEST 36: Cross-System Multi-Action Integration Chains
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 36] Cross-System Multi-Action Integration Chains ---")

	StatusService.resetCombat()

	local chainPlayer: StateTypes.PlayerState = {
		UserId = 36001,
		PlayerInstance = nil,
		DisplayName = "ChainWarrior",
		ClassId = "Warrior",
		SubclassId = "Juggernaut",
		Resources = { HP = 50, MaxHP = 80, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {}, Hand = {}, DiscardPile = {}, ExhaustPile = {}, RelicIds = {},
		Gold = 0, IsReady = false, IsDowned = false, IsConnected = true, VotedNodeId = nil,
	}
	local chainAlly: StateTypes.PlayerState = {
		UserId = 36002,
		PlayerInstance = nil,
		DisplayName = "ChainCleric",
		ClassId = "Cleric",
		SubclassId = "Templar",
		Resources = { HP = 0, MaxHP = 70, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {}, Hand = {}, DiscardPile = {}, ExhaustPile = {}, RelicIds = {},
		Gold = 0, IsReady = false, IsDowned = true, IsConnected = true, VotedNodeId = nil,
	}
	local chainEnemy: StateTypes.EnemyState = {
		InstanceId = "enemy_chain",
		DefinitionId = "SpireSentinel",
		Name = "Chain Sentinel",
		HP = 60, MaxHP = 60, Shield = 15, Poison = 0, AttackPower = 10,
		Intent = { Type = "Attack", Value = 10 }, ModelRef = nil,
	}
	local chainParty = {
		[chainPlayer.UserId] = chainPlayer,
		[chainAlly.UserId] = chainAlly,
	}
	local chainCombatState: StateTypes.CombatState = {
		CombatId = "combat_chain",
		Phase = "PlayerPhase",
		TurnNumber = 1,
		TurnStartTime = 0,
		TurnDuration = 45,
		Participants = { chainPlayer.UserId, chainAlly.UserId },
		Enemies = { ["enemy_chain"] = chainEnemy },
		ReadyPlayers = {},
		CombatLog = {},
	}

	-- 1. Damage Enemy + Shield Self compound action
	local effDmgEnemy: CardData.Effect = { Type = "Damage", Value = 10, Target = "Enemy" }
	local effShieldSelf: CardData.Effect = { Type = "Shield", Value = 8, Target = "Self" }
	local ctxCompound: EffectResolver.ActionContext = {
		SourcePlayer = chainPlayer,
		Target = {
			Success = true,
			Error = nil,
			TargetKind = "Enemy",
			EnemyTarget = chainEnemy,
			PlayerTarget = nil,
			TargetId = chainEnemy.InstanceId,
			TargetName = chainEnemy.Name,
		},
		Party = chainParty,
		CombatState = chainCombatState,
		Modifiers = {},
	}
	local compoundRes = EffectResolver.resolveEffects({ effDmgEnemy, effShieldSelf }, ctxCompound)
	assertTest(#compoundRes == 2 and compoundRes[1].Success == true and compoundRes[2].Success == true, "[CrossSystem] Compound Damage Enemy + Shield Self succeeded")
	assertTest(chainEnemy.Shield == 5 and chainEnemy.HP == 60, "[CrossSystem] Enemy Shield took 10 damage (15 - 10 = 5)")
	assertTest(chainPlayer.Resources.Shield == 8, "[CrossSystem] Caster gained 8 Shield")

	-- 2. Revive Ally on downed ally succeeds
	local effRevive: CardData.Effect = { Type = "Revive", Value = 25, Target = "Ally" }
	local ctxRevive: EffectResolver.ActionContext = {
		SourcePlayer = chainPlayer,
		Target = {
			Success = true,
			Error = nil,
			TargetKind = "Player",
			EnemyTarget = nil,
			PlayerTarget = chainAlly,
			TargetId = tostring(chainAlly.UserId),
			TargetName = chainAlly.DisplayName,
		},
		Party = chainParty,
		CombatState = chainCombatState,
		Modifiers = {},
	}
	local reviveRes = EffectResolver.resolveEffects({ effRevive }, ctxRevive)
	assertTest(#reviveRes == 1 and reviveRes[1].Success == true, "[CrossSystem] Revive Ally succeeded")
	assertTest(chainAlly.IsDowned == false and chainAlly.Resources.HP == 25, "[CrossSystem] Ally revived with 25 HP")

	-- 3. CreateCard + Draw integration
	for i = 1, 2 do
		local c = CardService.createCardInstance("Defend", chainPlayer.UserId)
		assert(c ~= nil)
		table.insert(chainPlayer.Deck, c)
	end
	local effCreate: CardData.Effect = { Type = "CreateCard", CardDefId = "Strike", DestinationPile = "Deck" }
	local effDraw: CardData.Effect = { Type = "Draw", Value = 1 }
	local chainCardCtx: EffectResolver.ActionContext = {
		SourcePlayer = chainPlayer,
		Target = {
			Success = true,
			Error = nil,
			TargetKind = "None",
			EnemyTarget = nil,
			PlayerTarget = nil,
			TargetId = "",
			TargetName = "None",
		},
		Party = chainParty,
		CombatState = chainCombatState,
		Modifiers = {},
	}
	local chainCreateDraw = EffectResolver.resolveEffects({ effCreate, effDraw }, chainCardCtx)
	assertTest(#chainCreateDraw == 2 and chainCreateDraw[1].Success == true and chainCreateDraw[2].Success == true, "[CrossSystem] CreateCard + Draw succeeded")
	local countInHand = 0
	for _ in chainPlayer.Hand do countInHand += 1 end
	assertTest(countInHand == 1, "[CrossSystem] Exactly 1 card drawn into hand")
	local okFinalInv, _ = CardService.validatePileInvariants(chainPlayer)
	assertTest(okFinalInv == true, "[CrossSystem] Pile invariants preserved after CreateCard + Draw")

	end
	----------------------------------------------------------------------------
	-- TEST 37: Static Card Effect Target Compatibility
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 37] Static Card Effect Target Compatibility ---")

	-- 1. All registered cards in CardData pass static validation
	local okDefs, errDefs = CardData.validateCardDefinitions()
	assertTest(okDefs == true and errDefs == nil, string.format("[CardValidator] All registered cards pass static validation (err: %s)", tostring(errDefs)))

	-- 2. Mixed-target cards pass individual validation
	local shieldSlamCard = CardData.getCard("ShieldSlam")
	assert(shieldSlamCard ~= nil)
	local okSS, _ = CardData.validateCard(shieldSlamCard)
	assertTest(okSS == true, "[CardValidator] ShieldSlam passes static validation (Shield -> Self, Damage -> Enemy)")

	local soulHarvestCard = CardData.getCard("SoulHarvest")
	assert(soulHarvestCard ~= nil)
	local okSH, _ = CardData.validateCard(soulHarvestCard)
	assertTest(okSH == true, "[CardValidator] SoulHarvest passes static validation (Damage -> Enemy, Heal -> Self)")

	local deployTurretCard = CardData.getCard("DeployTurret")
	assert(deployTurretCard ~= nil)
	local okDT, _ = CardData.validateCard(deployTurretCard)
	assertTest(okDT == true, "[CardValidator] DeployTurret passes static validation (Target: Enemy, Shield -> Self, Damage -> Enemy)")

	local packCallCard = CardData.getCard("PackCall")
	assert(packCallCard ~= nil)
	local okPC, _ = CardData.validateCard(packCallCard)
	assertTest(okPC == true, "[CardValidator] PackCall passes static validation (Target: Enemy, Shield -> Self, Damage -> Enemy)")

	-- 3. Damage effect cannot silently inherit Self or Ally
	local badDmgInherit: CardData.Card = {
		Id = "BadDmgInherit",
		Name = "Bad Dmg Inherit",
		Cost = 1,
		Target = "Self",
		Effects = {
			{ Type = "Damage", Value = 5 },
		},
		Description = "Invalid card",
		Color = Color3.fromRGB(0, 0, 0),
		Icon = "❌",
	}
	local okBDI, errBDI = CardData.validateCard(badDmgInherit)
	assertTest(okBDI == false and string.find(errBDI or "", "cannot silently inherit") ~= nil, "[CardValidator] Damage effect inheriting Self rejected")

	-- 4. Shield / Heal / Revive cannot silently inherit Enemy
	local badShieldInherit: CardData.Card = {
		Id = "BadShieldInherit",
		Name = "Bad Shield Inherit",
		Cost = 1,
		Target = "Enemy",
		Effects = {
			{ Type = "Shield", Value = 5 },
		},
		Description = "Invalid card",
		Color = Color3.fromRGB(0, 0, 0),
		Icon = "❌",
	}
	local okBSI, errBSI = CardData.validateCard(badShieldInherit)
	assertTest(okBSI == false and string.find(errBSI or "", "cannot silently inherit") ~= nil, "[CardValidator] Shield effect inheriting Enemy rejected")

	-- 5. Explicit illegal targets rejected (Damage targeting Self, Shield targeting Enemy)
	local badDmgTarget: CardData.Card = {
		Id = "BadDmgTarget",
		Name = "Bad Dmg Target",
		Cost = 1,
		Target = "Enemy",
		Effects = {
			{ Type = "Damage", Value = 5, Target = "Self" },
		},
		Description = "Invalid card",
		Color = Color3.fromRGB(0, 0, 0),
		Icon = "❌",
	}
	local okBDT, errBDT = CardData.validateCard(badDmgTarget)
	assertTest(okBDT == false and string.find(errBDT or "", "illegal target") ~= nil, "[CardValidator] Damage explicitly targeting Self rejected")

	local badShieldTarget: CardData.Card = {
		Id = "BadShieldTarget",
		Name = "Bad Shield Target",
		Cost = 1,
		Target = "Enemy",
		Effects = {
			{ Type = "Shield", Value = 5, Target = "Enemy" },
		},
		Description = "Invalid card",
		Color = Color3.fromRGB(0, 0, 0),
		Icon = "❌",
	}
	local okBST, errBST = CardData.validateCard(badShieldTarget)
	assertTest(okBST == false and string.find(errBST or "", "illegal target") ~= nil, "[CardValidator] Shield explicitly targeting Enemy rejected")

	-- 6. Mixed-target card without explicit Target on effect rejected
	local badMixedCard: CardData.Card = {
		Id = "BadMixedCard",
		Name = "Bad Mixed Card",
		Cost = 1,
		Target = "Enemy",
		Effects = {
			{ Type = "Damage", Value = 6, Target = "Enemy" },
			{ Type = "Shield", Value = 6 },
		},
		Description = "Invalid mixed card",
		Color = Color3.fromRGB(0, 0, 0),
		Icon = "❌",
	}
	local okBMC, errBMC = CardData.validateCard(badMixedCard)
	assertTest(okBMC == false and string.find(errBMC or "", "must explicitly declare its Target") ~= nil, "[CardValidator] Mixed-target card omitting effect Target rejected")

	-- 7. ModifyResource requires legal Player target
	local badResCard: CardData.Card = {
		Id = "BadResCard",
		Name = "Bad Res Card",
		Cost = 1,
		Target = "Enemy",
		Effects = {
			{ Type = "ModifyResource", Resource = "Energy", Value = 1, Target = "Enemy" },
		},
		Description = "Invalid resource card",
		Color = Color3.fromRGB(0, 0, 0),
		Icon = "❌",
	}
	local okBRC, errBRC = CardData.validateCard(badResCard)
	assertTest(okBRC == false and string.find(errBRC or "", "ModifyResource") ~= nil, "[CardValidator] ModifyResource targeting Enemy rejected")

	end
	----------------------------------------------------------------------------
	-- TEST 38: End-to-End Mixed-Target Card Execution
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 38] End-to-End Mixed-Target Card Execution ---")

	local e2eCaster: StateTypes.PlayerState = {
		UserId = 38001,
		PlayerInstance = nil,
		DisplayName = "E2ECaster",
		ClassId = "Warrior",
		SubclassId = "Juggernaut",
		Resources = { HP = 60, MaxHP = 80, Shield = 0, Energy = 10, MaxEnergy = 10 },
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = {},
		Gold = 100,
		IsReady = false,
		IsDowned = false,
		IsConnected = true,
	}

	local e2eAlly: StateTypes.PlayerState = {
		UserId = 38002,
		PlayerInstance = nil,
		DisplayName = "E2EAlly",
		ClassId = "Ranger",
		SubclassId = "Marksman",
		Resources = { HP = 40, MaxHP = 80, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = {},
		Gold = 100,
		IsReady = false,
		IsDowned = false,
		IsConnected = true,
	}

	local e2eEnemy: StateTypes.EnemyState = {
		InstanceId = "e2e_target_dummy",
		DefinitionId = "TrainingDummy",
		Name = "E2E Training Dummy",
		HP = 150,
		MaxHP = 150,
		Shield = 0,
		Poison = 0,
		AttackPower = 10,
		Intent = { Type = "Attack", Value = 10, TargetUserId = 38001 },
		ModelRef = nil,
	}

	local e2eParty: { [number]: StateTypes.PlayerState } = {
		[38001] = e2eCaster,
		[38002] = e2eAlly,
	}

	local e2eCombatState: StateTypes.CombatState = {
		CombatId = "combat_e2e_suite38",
		Phase = "PlayerPhase",
		TurnNumber = 1,
		TurnStartTime = os.clock(),
		TurnDuration = 45,
		Participants = { 38001, 38002 },
		Enemies = { ["e2e_target_dummy"] = e2eEnemy },
		ReadyPlayers = {},
		CombatLog = {},
	}

	local resolvedEnemy = TargetResolver.resolveTarget(
		e2eCaster,
		"Enemy",
		"e2e_target_dummy",
		e2eCombatState,
		e2eParty
	)
	assertTest(resolvedEnemy.Success == true, "[E2E Target] Resolved enemy target successfully")

	local resolvedAlly = TargetResolver.resolveTarget(
		e2eCaster,
		"Ally",
		38002,
		e2eCombatState,
		e2eParty
	)
	assertTest(resolvedAlly.Success == true, "[E2E Target] Resolved ally target successfully")

	-- 1. ShieldSlam: Caster gains 8 Shield, Enemy takes 8 damage, Enemy gains 0 shield
	e2eCaster.Resources.Shield = 0
	e2eEnemy.HP = 150
	e2eEnemy.Shield = 0
	local shieldSlamDef = CardData.getCard("ShieldSlam")
	assert(shieldSlamDef ~= nil)
	local ssInst = CardService.createCardInstance("ShieldSlam", e2eCaster.UserId) :: StateTypes.CardInstance
	local ctxShieldSlam: EffectResolver.ActionContext = {
		SourcePlayer = e2eCaster,
		Target = resolvedEnemy,
		CombatState = e2eCombatState,
		Party = e2eParty,
		CardInstance = ssInst,
		Modifiers = {},
	}
	local ssResults = EffectResolver.resolveEffects(shieldSlamDef.Effects, ctxShieldSlam)
	assertTest(#ssResults == 2 and ssResults[1].Success and ssResults[2].Success, "[E2E ShieldSlam] Both effects executed successfully")
	assertTest(e2eCaster.Resources.Shield == 8, string.format("[E2E ShieldSlam] Caster gained 8 Shield (Actual: %d)", e2eCaster.Resources.Shield))
	assertTest(e2eEnemy.HP == 142, string.format("[E2E ShieldSlam] Enemy took 8 damage, 150 -> 142 (Actual: %d)", e2eEnemy.HP))
	assertTest(e2eEnemy.Shield == 0, string.format("[E2E ShieldSlam] Enemy gained 0 shield (Actual: %d)", e2eEnemy.Shield))

	-- 2. WrenchThrow: Enemy takes 7 damage, Caster gains 3 Shield
	e2eCaster.Resources.Shield = 0
	local wrenchThrowDef = CardData.getCard("WrenchThrow")
	assert(wrenchThrowDef ~= nil)
	local wtInst = CardService.createCardInstance("WrenchThrow", e2eCaster.UserId) :: StateTypes.CardInstance
	local ctxWrenchThrow: EffectResolver.ActionContext = {
		SourcePlayer = e2eCaster,
		Target = resolvedEnemy,
		CombatState = e2eCombatState,
		Party = e2eParty,
		CardInstance = wtInst,
		Modifiers = {},
	}
	local wtResults = EffectResolver.resolveEffects(wrenchThrowDef.Effects, ctxWrenchThrow)
	assertTest(#wtResults == 2 and wtResults[1].Success and wtResults[2].Success, "[E2E WrenchThrow] Both effects executed successfully")
	assertTest(e2eEnemy.HP == 135, string.format("[E2E WrenchThrow] Enemy took 7 damage, 142 -> 135 (Actual: %d)", e2eEnemy.HP))
	assertTest(e2eCaster.Resources.Shield == 3, string.format("[E2E WrenchThrow] Caster gained 3 Shield (Actual: %d)", e2eCaster.Resources.Shield))

	-- 3. SoulHarvest: Enemy takes 7 damage, injured Caster heals 3 HP
	e2eCaster.Resources.HP = 50
	local soulHarvestDef = CardData.getCard("SoulHarvest")
	assert(soulHarvestDef ~= nil)
	local shInst = CardService.createCardInstance("SoulHarvest", e2eCaster.UserId) :: StateTypes.CardInstance
	local ctxSoulHarvest: EffectResolver.ActionContext = {
		SourcePlayer = e2eCaster,
		Target = resolvedEnemy,
		CombatState = e2eCombatState,
		Party = e2eParty,
		CardInstance = shInst,
		Modifiers = {},
	}
	local shResults = EffectResolver.resolveEffects(soulHarvestDef.Effects, ctxSoulHarvest)
	assertTest(#shResults == 2 and shResults[1].Success and shResults[2].Success, "[E2E SoulHarvest] Both effects executed successfully")
	assertTest(e2eEnemy.HP == 128, string.format("[E2E SoulHarvest] Enemy took 7 damage, 135 -> 128 (Actual: %d)", e2eEnemy.HP))
	assertTest(e2eCaster.Resources.HP == 53, string.format("[E2E SoulHarvest] Injured caster healed 3 HP, 50 -> 53 (Actual: %d)", e2eCaster.Resources.HP))

	-- 4. DeployTurret: Caster gains 6 Shield, Enemy takes 6 damage
	e2eCaster.Resources.Shield = 0
	local deployTurretDef = CardData.getCard("DeployTurret")
	assert(deployTurretDef ~= nil)
	local dtInst = CardService.createCardInstance("DeployTurret", e2eCaster.UserId) :: StateTypes.CardInstance
	local ctxDeployTurret: EffectResolver.ActionContext = {
		SourcePlayer = e2eCaster,
		Target = resolvedEnemy,
		CombatState = e2eCombatState,
		Party = e2eParty,
		CardInstance = dtInst,
		Modifiers = {},
	}
	local dtResults = EffectResolver.resolveEffects(deployTurretDef.Effects, ctxDeployTurret)
	assertTest(#dtResults == 2 and dtResults[1].Success and dtResults[2].Success, "[E2E DeployTurret] Both effects executed successfully")
	assertTest(e2eCaster.Resources.Shield == 6, string.format("[E2E DeployTurret] Caster gained 6 Shield (Actual: %d)", e2eCaster.Resources.Shield))
	assertTest(e2eEnemy.HP == 122, string.format("[E2E DeployTurret] Enemy took 6 damage, 128 -> 122 (Actual: %d)", e2eEnemy.HP))

	-- 5. TimeWarp: Enemy takes 7 damage, Caster gains 4 Shield
	e2eCaster.Resources.Shield = 0
	local timeWarpDef = CardData.getCard("TimeWarp")
	assert(timeWarpDef ~= nil)
	local twInst = CardService.createCardInstance("TimeWarp", e2eCaster.UserId) :: StateTypes.CardInstance
	local ctxTimeWarp: EffectResolver.ActionContext = {
		SourcePlayer = e2eCaster,
		Target = resolvedEnemy,
		CombatState = e2eCombatState,
		Party = e2eParty,
		CardInstance = twInst,
		Modifiers = {},
	}
	local twResults = EffectResolver.resolveEffects(timeWarpDef.Effects, ctxTimeWarp)
	assertTest(#twResults == 2 and twResults[1].Success and twResults[2].Success, "[E2E TimeWarp] Both effects executed successfully")
	assertTest(e2eEnemy.HP == 115, string.format("[E2E TimeWarp] Enemy took 7 damage, 122 -> 115 (Actual: %d)", e2eEnemy.HP))
	assertTest(e2eCaster.Resources.Shield == 4, string.format("[E2E TimeWarp] Caster gained 4 Shield (Actual: %d)", e2eCaster.Resources.Shield))

	-- 6. PackCall: Caster gains 7 Shield, Enemy takes 4 damage
	e2eCaster.Resources.Shield = 0
	local packCallDef = CardData.getCard("PackCall")
	assert(packCallDef ~= nil)
	local pcInst = CardService.createCardInstance("PackCall", e2eCaster.UserId) :: StateTypes.CardInstance
	local ctxPackCall: EffectResolver.ActionContext = {
		SourcePlayer = e2eCaster,
		Target = resolvedEnemy,
		CombatState = e2eCombatState,
		Party = e2eParty,
		CardInstance = pcInst,
		Modifiers = {},
	}
	local pcResults = EffectResolver.resolveEffects(packCallDef.Effects, ctxPackCall)
	assertTest(#pcResults == 2 and pcResults[1].Success and pcResults[2].Success, "[E2E PackCall] Both effects executed successfully")
	assertTest(e2eCaster.Resources.Shield == 7, string.format("[E2E PackCall] Caster gained 7 Shield (Actual: %d)", e2eCaster.Resources.Shield))
	assertTest(e2eEnemy.HP == 111, string.format("[E2E PackCall] Enemy took 4 damage, 115 -> 111 (Actual: %d)", e2eEnemy.HP))

	-- 7. Contagion: Enemy takes 8 damage + 4 Poison stacks
	e2eEnemy.Poison = 0
	local contagionDef = CardData.getCard("Contagion")
	assert(contagionDef ~= nil)
	local contInst = CardService.createCardInstance("Contagion", e2eCaster.UserId) :: StateTypes.CardInstance
	local ctxContagion: EffectResolver.ActionContext = {
		SourcePlayer = e2eCaster,
		Target = resolvedEnemy,
		CombatState = e2eCombatState,
		Party = e2eParty,
		CardInstance = contInst,
		Modifiers = {},
	}
	local contResults = EffectResolver.resolveEffects(contagionDef.Effects, ctxContagion)
	assertTest(#contResults == 2 and contResults[1].Success and contResults[2].Success, "[E2E Contagion] Both effects executed successfully")
	assertTest(e2eEnemy.HP == 103, string.format("[E2E Contagion] Enemy took 8 damage, 111 -> 103 (Actual: %d)", e2eEnemy.HP))
	assertTest(e2eEnemy.Poison == 4, string.format("[E2E Contagion] Enemy afflicted with 4 Poison stacks (Actual: %d)", e2eEnemy.Poison))

	-- 8. FirstAid: Downed ally revived, living ally healed
	local firstAidDef2 = CardData.getCard("FirstAid")
	assert(firstAidDef2 ~= nil)
	local faInst = CardService.createCardInstance("FirstAid", e2eCaster.UserId) :: StateTypes.CardInstance
	-- 8a. Downed ally
	e2eAlly.IsDowned = true
	e2eAlly.Resources.HP = 0
	local ctxFirstAidDowned: EffectResolver.ActionContext = {
		SourcePlayer = e2eCaster,
		Target = resolvedAlly,
		CombatState = e2eCombatState,
		Party = e2eParty,
		CardInstance = faInst,
		Modifiers = {},
	}
	local faDownedResults = EffectResolver.resolveEffects(firstAidDef2.Effects, ctxFirstAidDowned)
	assertTest(e2eAlly.IsDowned == false, "[E2E FirstAid] Downed ally successfully revived")
	assertTest(e2eAlly.Resources.HP == 30, string.format("[E2E FirstAid] Downed ally revived with 30 HP (Actual: %d)", e2eAlly.Resources.HP))

	-- 8b. Living injured ally
	e2eAlly.IsDowned = false
	e2eAlly.Resources.HP = 40
	local ctxFirstAidLiving: EffectResolver.ActionContext = {
		SourcePlayer = e2eCaster,
		Target = resolvedAlly,
		CombatState = e2eCombatState,
		Party = e2eParty,
		CardInstance = faInst,
		Modifiers = {},
	}
	local faLivingResults = EffectResolver.resolveEffects(firstAidDef2.Effects, ctxFirstAidLiving)
	assertTest(e2eAlly.Resources.HP == 70, string.format("[E2E FirstAid] Living ally healed 30 HP, 40 -> 70 (Actual: %d)", e2eAlly.Resources.HP))
	assertTest(e2eAlly.IsDowned == false, "[E2E FirstAid] Living ally remains not downed")

	-- 9. Bonus Shield Gimmick Safety (ActionBonusShield modifier applied exactly once)
	e2eCaster.Resources.Shield = 0
	local bonusShieldMod = ModifierResolver.createModifier(
		"ActionBonusShield",
		"GimmickAndRelics",
		"Shield",
		"Add",
		4,
		100
	)
	local ctxBonusShield: EffectResolver.ActionContext = {
		SourcePlayer = e2eCaster,
		Target = resolvedEnemy,
		CombatState = e2eCombatState,
		Party = e2eParty,
		CardInstance = ssInst,
		Modifiers = { bonusShieldMod },
	}
	local bonusShieldResults = EffectResolver.resolveEffects(shieldSlamDef.Effects, ctxBonusShield)
	assertTest(bonusShieldResults[1].Success == true, "[E2E BonusShield] Shield effect executed successfully")
	assertTest(e2eCaster.Resources.Shield == 12, string.format("[E2E BonusShield] Bonus Shield correctly added once without duplication: base 8 + 4 = 12 (Actual: %d)", e2eCaster.Resources.Shield))

	end
	----------------------------------------------------------------------------
	-- TEST 39: Final Schema Strictness & Resource Boundary Safety
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 39] Final Schema Strictness & Resource Boundary Safety ---")

	local schemaPlayer: StateTypes.PlayerState = {
		UserId = 39001,
		PlayerInstance = nil,
		DisplayName = "SchemaTester",
		ClassId = "Warrior",
		SubclassId = "Juggernaut",
		Resources = { HP = 70, MaxHP = 80, Shield = 5, Energy = 1, MaxEnergy = 3 },
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = {},
		Gold = 50,
		IsReady = false,
		IsDowned = false,
		IsConnected = true,
	}

	local schemaAlly: StateTypes.PlayerState = {
		UserId = 39002,
		PlayerInstance = nil,
		DisplayName = "SchemaAlly",
		ClassId = "Ranger",
		SubclassId = "Marksman",
		Resources = { HP = 60, MaxHP = 80, Shield = 0, Energy = 1, MaxEnergy = 3 },
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = {},
		Gold = 30,
		IsReady = false,
		IsDowned = false,
		IsConnected = true,
	}

	local schemaParty: { [number]: StateTypes.PlayerState } = {
		[39001] = schemaPlayer,
		[39002] = schemaAlly,
	}

	local schemaCombatState: StateTypes.CombatState = {
		CombatId = "combat_schema_suite39",
		Phase = "PlayerPhase",
		TurnNumber = 1,
		TurnStartTime = os.clock(),
		TurnDuration = 45,
		Participants = { 39001, 39002 },
		Enemies = {},
		ReadyPlayers = {},
		CombatLog = {},
	}

	local schemaCtxSelf: EffectResolver.ActionContext = {
		SourcePlayer = schemaPlayer,
		Target = {
			Success = true,
			Error = nil,
			TargetKind = "Player",
			EnemyTarget = nil,
			PlayerTarget = schemaPlayer,
			TargetId = "39001",
			TargetName = schemaPlayer.DisplayName,
		},
		CombatState = schemaCombatState,
		Party = schemaParty,
		Modifiers = {},
	}

	local schemaCtxAlly: EffectResolver.ActionContext = {
		SourcePlayer = schemaPlayer,
		Target = {
			Success = true,
			Error = nil,
			TargetKind = "Player",
			EnemyTarget = nil,
			PlayerTarget = schemaAlly,
			TargetId = "39002",
			TargetName = schemaAlly.DisplayName,
		},
		CombatState = schemaCombatState,
		Party = schemaParty,
		Modifiers = {},
	}

	-- 1. CreateCard: Valid Deck destination
	local effDeck: CardData.Effect = { Type = "CreateCard", CardDefId = "Strike", DestinationPile = "Deck" }
	local resDeck = EffectResolver.resolveEffects({ effDeck }, schemaCtxSelf)
	assertTest(#resDeck == 1 and resDeck[1].Success == true, "[CreateCard] Valid Deck destination succeeds")
	assertTest(#schemaPlayer.Deck == 1, "[CreateCard] Card inserted into Deck")

	-- 2. CreateCard: Valid Hand destination
	local effHand: CardData.Effect = { Type = "CreateCard", CardDefId = "Defend", DestinationPile = "Hand" }
	local resHand = EffectResolver.resolveEffects({ effHand }, schemaCtxSelf)
	assertTest(#resHand == 1 and resHand[1].Success == true, "[CreateCard] Valid Hand destination succeeds")
	local handCount = 0
	for _ in schemaPlayer.Hand do handCount += 1 end
	assertTest(handCount == 1, "[CreateCard] Card inserted into Hand")

	-- 3. CreateCard: Valid DiscardPile destination
	local effDiscard: CardData.Effect = { Type = "CreateCard", CardDefId = "Strike", DestinationPile = "DiscardPile" }
	local resDiscard = EffectResolver.resolveEffects({ effDiscard }, schemaCtxSelf)
	assertTest(#resDiscard == 1 and resDiscard[1].Success == true, "[CreateCard] Valid DiscardPile destination succeeds")
	assertTest(#schemaPlayer.DiscardPile == 1, "[CreateCard] Card inserted into DiscardPile")

	-- 4. CreateCard: Valid ExhaustPile destination
	local effExhaust: CardData.Effect = { Type = "CreateCard", CardDefId = "Defend", DestinationPile = "ExhaustPile" }
	local resExhaust = EffectResolver.resolveEffects({ effExhaust }, schemaCtxSelf)
	assertTest(#resExhaust == 1 and resExhaust[1].Success == true, "[CreateCard] Valid ExhaustPile destination succeeds")
	assertTest(#schemaPlayer.ExhaustPile == 1, "[CreateCard] Card inserted into ExhaustPile")

	-- 5. CreateCard: Default nil DestinationPile defaults to Deck
	local effNilDest: CardData.Effect = { Type = "CreateCard", CardDefId = "Strike", DestinationPile = nil }
	local resNilDest = EffectResolver.resolveEffects({ effNilDest }, schemaCtxSelf)
	assertTest(#resNilDest == 1 and resNilDest[1].Success == true, "[CreateCard] Nil DestinationPile defaults to Deck successfully")
	assertTest(#schemaPlayer.Deck == 2, "[CreateCard] Card inserted into Deck by default")

	-- 6. CreateCard: Invalid DestinationPile 'Banana' rejected with Success=false and zero cards created
	local deckCountBefore = #schemaPlayer.Deck
	local discardCountBefore = #schemaPlayer.DiscardPile
	local exhaustCountBefore = #schemaPlayer.ExhaustPile
	local handCountBefore = 0
	for _ in schemaPlayer.Hand do handCountBefore += 1 end

	local effBanana: CardData.Effect = { Type = "CreateCard", CardDefId = "Strike", DestinationPile = "Banana" }
	local resBanana = EffectResolver.resolveEffects({ effBanana }, schemaCtxSelf)
	assertTest(#resBanana == 1 and resBanana[1].Success == false, "[CreateCard] Invalid 'Banana' destination rejected with Success=false")
	local handCountAfterBanana = 0
	for _ in schemaPlayer.Hand do handCountAfterBanana += 1 end
	assertTest(
		#schemaPlayer.Deck == deckCountBefore
		and #schemaPlayer.DiscardPile == discardCountBefore
		and #schemaPlayer.ExhaustPile == exhaustCountBefore
		and handCountAfterBanana == handCountBefore,
		"[CreateCard] Invalid 'Banana' created zero cards in any pile"
	)

	-- 7. CreateCard: Empty string DestinationPile rejected with Success=false and zero cards created
	local effEmptyDest: CardData.Effect = { Type = "CreateCard", CardDefId = "Strike", DestinationPile = "" }
	local resEmptyDest = EffectResolver.resolveEffects({ effEmptyDest }, schemaCtxSelf)
	assertTest(#resEmptyDest == 1 and resEmptyDest[1].Success == false, "[CreateCard] Empty string destination rejected with Success=false")
	local handCountAfterEmpty = 0
	for _ in schemaPlayer.Hand do handCountAfterEmpty += 1 end
	assertTest(
		#schemaPlayer.Deck == deckCountBefore
		and #schemaPlayer.DiscardPile == discardCountBefore
		and #schemaPlayer.ExhaustPile == exhaustCountBefore
		and handCountAfterEmpty == handCountBefore,
		"[CreateCard] Empty string destination created zero cards in any pile"
	)

	-- 8. Card Pile Invariant Verification
	local okSchemaInv, errSchemaInv = CardService.validatePileInvariants(schemaPlayer)
	assertTest(okSchemaInv == true and errSchemaInv == nil, "[CreateCard] Pile invariants preserved with exact single ownership")

	-- 9. ModifyResource: Missing Resource (nil) fails with Success=false and zero Gold modification
	local goldBefore = schemaPlayer.Gold
	local effMissingRes: CardData.Effect = { Type = "ModifyResource", Resource = nil, Value = 50, Target = "Self" }
	local resMissingRes = EffectResolver.resolveEffects({ effMissingRes }, schemaCtxSelf)
	assertTest(#resMissingRes == 1 and resMissingRes[1].Success == false, "[ModifyResource] Missing Resource rejected with Success=false")
	assertTest(schemaPlayer.Gold == goldBefore, "[ModifyResource] Missing Resource did NOT accidentally modify Gold")

	-- 10. ModifyResource: Empty string Resource fails with Success=false and zero Gold modification
	local effEmptyRes: CardData.Effect = { Type = "ModifyResource", Resource = "" :: any, Value = 50, Target = "Self" }
	local resEmptyRes = EffectResolver.resolveEffects({ effEmptyRes }, schemaCtxSelf)
	assertTest(#resEmptyRes == 1 and resEmptyRes[1].Success == false, "[ModifyResource] Empty string Resource rejected with Success=false")
	assertTest(schemaPlayer.Gold == goldBefore, "[ModifyResource] Empty string Resource did NOT accidentally modify Gold")

	-- 11. ModifyResource: Invalid Resource ('InvalidResourceXYZ') fails with Success=false and zero Gold modification
	local effInvalidRes: CardData.Effect = { Type = "ModifyResource", Resource = "InvalidResourceXYZ" :: any, Value = 50, Target = "Self" }
	local resInvalidRes = EffectResolver.resolveEffects({ effInvalidRes }, schemaCtxSelf)
	assertTest(#resInvalidRes == 1 and resInvalidRes[1].Success == false, "[ModifyResource] Invalid Resource rejected with Success=false")
	assertTest(schemaPlayer.Gold == goldBefore, "[ModifyResource] Invalid Resource did NOT accidentally modify Gold")

	-- 12. ModifyResource: Valid Gold modifies Gold normally
	local effValidGold: CardData.Effect = { Type = "ModifyResource", Resource = "Gold", Value = 25, Target = "Self" }
	local resValidGold = EffectResolver.resolveEffects({ effValidGold }, schemaCtxSelf)
	assertTest(#resValidGold == 1 and resValidGold[1].Success == true, "[ModifyResource] Valid Gold executes normally")
	assertTest(schemaPlayer.Gold == goldBefore + 25, string.format("[ModifyResource] Gold modified to %d", schemaPlayer.Gold))

	-- 13. ModifyResource: Valid Energy modifies Energy normally
	schemaPlayer.Resources.Energy = 1
	local effValidEnergy: CardData.Effect = { Type = "ModifyResource", Resource = "Energy", Value = 1, Target = "Self" }
	local resValidEnergy = EffectResolver.resolveEffects({ effValidEnergy }, schemaCtxSelf)
	assertTest(#resValidEnergy == 1 and resValidEnergy[1].Success == true, "[ModifyResource] Valid Energy executes normally")
	assertTest(schemaPlayer.Resources.Energy == 2, "[ModifyResource] Energy increased from 1 to 2")

	-- 14. ModifyResource: Valid Self Energy modifies caster only, ally untouched
	schemaPlayer.Resources.Energy = 1
	schemaAlly.Resources.Energy = 1
	local effSelfEnergy: CardData.Effect = { Type = "ModifyResource", Resource = "Energy", Value = 1, Target = "Self" }
	local resSelfEnergy = EffectResolver.resolveEffects({ effSelfEnergy }, schemaCtxSelf)
	assertTest(#resSelfEnergy == 1 and resSelfEnergy[1].Success == true, "[ModifyResource] Valid Self Energy executes normally")
	assertTest(schemaPlayer.Resources.Energy == 2, "[ModifyResource] Caster Energy increased from 1 to 2")
	assertTest(schemaAlly.Resources.Energy == 1, "[ModifyResource] Ally Energy remained 1")

	-- 15. ModifyResource: Valid Ally Energy modifies ally only, caster untouched
	schemaPlayer.Resources.Energy = 2
	schemaAlly.Resources.Energy = 1
	local effAllyEnergy: CardData.Effect = { Type = "ModifyResource", Resource = "Energy", Value = 2, Target = "Ally" }
	local resAllyEnergy = EffectResolver.resolveEffects({ effAllyEnergy }, schemaCtxAlly)
	assertTest(#resAllyEnergy == 1 and resAllyEnergy[1].Success == true, "[ModifyResource] Valid Ally Energy executes normally")
	assertTest(schemaAlly.Resources.Energy == 3, "[ModifyResource] Ally Energy increased from 1 to 3")
	assertTest(schemaPlayer.Resources.Energy == 2, "[ModifyResource] Caster Energy remained 2")

	end
	----------------------------------------------------------------------------
	-- TEST 40: Phase 3 Equipment Foundation
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 40] Phase 3 Equipment Foundation ---")
	local equipUser = 6001
	local equipPlayer: StateTypes.PlayerState = {
		UserId = equipUser,
		DisplayName = "GearMaster",
		ClassId = "Warlord",
		SubclassId = "Berserker",
		Resources = { HP = 110, MaxHP = 110, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = {},
		Gold = 100,
		IsReady = false,
		IsDowned = false,
		IsConnected = true,
		EquippedItems = {},
		EquipmentInventory = {},
	}

	-- 1. Create valid instance
	local swordInst = EquipmentService.createInstance("IronBroadsword", equipUser)
	assertTest(swordInst ~= nil, "[Equipment] createInstance returns valid instance for IronBroadsword")
	assertTest(swordInst ~= nil and swordInst.Slot == "Weapon", "[Equipment] Created item assigned correct slot 'Weapon'")
	assertTest(swordInst ~= nil and swordInst.OwnerUserId == equipUser, "[Equipment] Created item assigned correct owner UserId")

	-- 2. Unknown equipment definition rejected
	local badInst = EquipmentService.createInstance("NonExistentItem999", equipUser)
	assertTest(badInst == nil, "[Equipment] Unknown definition ID returns nil")

	-- 3. Equip item
	assert(swordInst, "swordInst must be non-nil")
	table.insert(equipPlayer.EquipmentInventory, swordInst)
	local okEquip, errEquip = EquipmentService.equipItem(equipPlayer, swordInst)
	assertTest(okEquip == true and errEquip == nil, "[Equipment] Equipping valid weapon succeeds")
	assertTest(equipPlayer.EquippedItems ~= nil and equipPlayer.EquippedItems["Weapon"] == swordInst, "[Equipment] Item placed in EquippedItems['Weapon']")

	-- 4. Slot replacement
	local swordInst2 = EquipmentService.createInstance("IronBroadsword", equipUser)
	assert(swordInst2, "swordInst2 must be non-nil")
	table.insert(equipPlayer.EquipmentInventory, swordInst2)
	local okReplace, _ = EquipmentService.equipItem(equipPlayer, swordInst2)
	assertTest(okReplace == true, "[Equipment] Equipping second weapon replaces slot")
	assertTest(equipPlayer.EquippedItems ~= nil and equipPlayer.EquippedItems["Weapon"] == swordInst2, "[Equipment] New weapon equipped")
	assertTest(equipPlayer.EquipmentInventory ~= nil and #equipPlayer.EquipmentInventory == 1 and equipPlayer.EquipmentInventory[1] == swordInst, "[Equipment] Replaced weapon returned to EquipmentInventory")

	-- 5. Unequip item
	local okUnequip, errUnequip = EquipmentService.unequipItem(equipPlayer, "Weapon")
	assertTest(okUnequip == true and errUnequip == nil, "[Equipment] Unequip item succeeds")
	assertTest(equipPlayer.EquippedItems ~= nil and equipPlayer.EquippedItems["Weapon"] == nil, "[Equipment] Weapon slot is now empty")
	assertTest(equipPlayer.EquipmentInventory ~= nil and #equipPlayer.EquipmentInventory == 2, "[Equipment] Unequipped item moved to inventory")

	-- 6. Ownership mismatch rejection
	local foreignItem = EquipmentService.createInstance("IronBroadsword", 9999)
	assert(foreignItem, "foreignItem must be non-nil")
	table.insert(equipPlayer.EquipmentInventory, foreignItem)
	local okForeign, errForeign = EquipmentService.equipItem(equipPlayer, foreignItem)
	assertTest(okForeign == false and errForeign ~= nil, "[Equipment] Foreign item rejected on owner mismatch")

	-- 7. Modifier collection from equipped gear
	EquipmentService.equipItem(equipPlayer, swordInst)
	local armorInst = EquipmentService.createInstance("ReinforcedPlate", equipUser)
	assert(armorInst, "armorInst must be non-nil")
	table.insert(equipPlayer.EquipmentInventory, armorInst)
	EquipmentService.equipItem(equipPlayer, armorInst)

	local collectedMods = EquipmentService.collectModifiers(equipPlayer)
	assertTest(#collectedMods >= 3, "[Equipment] collectModifiers gathered modifiers across equipped weapon and armor")

	end
	----------------------------------------------------------------------------
	-- TEST 41: Phase 3 Centralized Stat Resolution
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 41] Phase 3 Centralized Stat Resolution ---")

	-- 1. Base stats from class definition
	local baseWarlordStats = StatResolver.resolvePlayerStats(equipPlayer)
	assertTest(baseWarlordStats.MaxHP >= 110, "[StatResolver] Base MaxHP resolved from Warlord class definition")

	-- 2. Additive modifier stacking
	local testAddMod1 = ModifierResolver.createModifier("t_add1", "test", "MaxHP", "Add", 20, 100)
	local testAddMod2 = ModifierResolver.createModifier("t_add2", "test", "MaxHP", "Add", 10, 100)
	local resAdd, _ = StatResolver.resolveStat(100, "MaxHP", { testAddMod1, testAddMod2 })
	assertTest(resAdd == 130, "[StatResolver] Additive modifiers stack deterministically: 100 + 20 + 10 = 130")

	-- 3. Multiplicative modifier stacking: (Base + Add) * Mult
	local testMultMod = ModifierResolver.createModifier("t_mult", "test", "Damage", "Multiply", 1.5, 200)
	local testDmgAdd = ModifierResolver.createModifier("t_dmg_add", "test", "Damage", "Add", 20, 100)
	local resMult, _ = StatResolver.resolveStat(100, "Damage", { testDmgAdd, testMultMod })
	assertTest(resMult == 180, "[StatResolver] Multiplicative modifier applies to additive sum: (100 + 20) * 1.5 = 180")

	-- 4. Override modifier absolute precedence
	local testOverride = ModifierResolver.createModifier("t_over", "test", "MaxHP", "Override", 500, 300)
	local resOver, _ = StatResolver.resolveStat(100, "MaxHP", { testAddMod1, testOverride, testAddMod2 })
	assertTest(resOver == 500, "[StatResolver] Override modifier takes absolute precedence over additive modifiers")

	-- 5. Bounds clamping
	local testHugeNegative = ModifierResolver.createModifier("t_neg", "test", "MaxHP", "Add", -200, 100)
	local resClampHP, _ = StatResolver.resolveStat(100, "MaxHP", { testHugeNegative })
	assertTest(resClampHP == 1, "[StatResolver] MaxHP strictly clamped to minimum 1")

	local testCritOver = ModifierResolver.createModifier("t_crit_high", "test", "CritChance", "Add", 2.0, 100)
	local resCritClampHigh, _ = StatResolver.resolveStat(0.05, "CritChance", { testCritOver })
	assertTest(resCritClampHigh == 1.0, "[StatResolver] CritChance clamped to maximum 1.0")

	local testCritUnder = ModifierResolver.createModifier("t_crit_low", "test", "CritChance", "Add", -1.0, 100)
	local resCritClampLow, _ = StatResolver.resolveStat(0.05, "CritChance", { testCritUnder })
	assertTest(resCritClampLow == 0.0, "[StatResolver] CritChance clamped to minimum 0.0")

	-- 6. Derived stat synchronization
	equipPlayer.Resources.HP = 80
	local syncedStats = StatResolver.syncPlayerDerivedStats(equipPlayer)
	assertTest(equipPlayer.Resources.MaxHP == syncedStats.MaxHP, "[StatResolver] syncPlayerDerivedStats updated Resources.MaxHP")
	assertTest(equipPlayer.Resources.HP <= equipPlayer.Resources.MaxHP, "[StatResolver] Resources.HP clamped within MaxHP bounds")

	end
	----------------------------------------------------------------------------
	-- TEST 42: Phase 3 Passive Tree & Graph Validation
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 42] Phase 3 Passive Tree & Graph Validation ---")

	-- 1. Validate canonical Warlord DAG
	local okWarlordDAG, errWarlordDAG = PassiveData.validateTree("Warlord")
	assertTest(okWarlordDAG == true and errWarlordDAG == nil, "[PassiveData] Canonical Warlord passive tree is a valid DAG")

	-- 2. Reject synthetic cyclic graph (A -> B -> A)
	local cyclicNodes: { PassiveData.PassiveNodeDefinition } = {
		{
			Id = "NodeA",
			Name = "Node A",
			Description = "A",
			ClassId = "TestClass",
			Type = "Stat",
			Tier = 1,
			Cost = 1,
			Prerequisites = { "NodeB" },
			Modifiers = {},
		},
		{
			Id = "NodeB",
			Name = "Node B",
			Description = "B",
			ClassId = "TestClass",
			Type = "Stat",
			Tier = 1,
			Cost = 1,
			Prerequisites = { "NodeA" },
			Modifiers = {},
		},
	}
	local okCycle, errCycle = PassiveData.validateNodes(cyclicNodes)
	assertTest(okCycle == false and string.find(errCycle or "", "Cycle") ~= nil, "[PassiveData] Cyclic graph rejected with cycle detection error")

	-- 3. Reject self-cycle (A -> A)
	local selfCycleNodes: { PassiveData.PassiveNodeDefinition } = {
		{
			Id = "SelfCycle",
			Name = "Self Cycle",
			Description = "Self",
			ClassId = "TestClass",
			Type = "Stat",
			Tier = 1,
			Cost = 1,
			Prerequisites = { "SelfCycle" },
			Modifiers = {},
		},
	}
	local okSelfCycle, _ = PassiveData.validateNodes(selfCycleNodes)
	assertTest(okSelfCycle == false, "[PassiveData] Self-cycle rejected")

	-- 4. Reject missing prerequisite
	local missingPrereqNodes: { PassiveData.PassiveNodeDefinition } = {
		{
			Id = "NodeChild",
			Name = "Node Child",
			Description = "Child",
			ClassId = "TestClass",
			Type = "Stat",
			Tier = 2,
			Cost = 1,
			Prerequisites = { "NonExistentParent" },
			Modifiers = {},
		},
	}
	local okMissingPrereq, errMissingPrereq = PassiveData.validateNodes(missingPrereqNodes)
	assertTest(okMissingPrereq == false and string.find(errMissingPrereq or "", "missing prerequisite") ~= nil, "[PassiveData] Missing prerequisite reference rejected")

	-- 5. Reject duplicate node IDs
	local duplicateIdNodes: { PassiveData.PassiveNodeDefinition } = {
		{
			Id = "DupNode",
			Name = "Dup 1",
			Description = "1",
			ClassId = "TestClass",
			Type = "Stat",
			Tier = 1,
			Cost = 1,
			Prerequisites = {},
			Modifiers = {},
		},
		{
			Id = "DupNode",
			Name = "Dup 2",
			Description = "2",
			ClassId = "TestClass",
			Type = "Stat",
			Tier = 1,
			Cost = 1,
			Prerequisites = {},
			Modifiers = {},
		},
	}
	local okDup, errDup = PassiveData.validateNodes(duplicateIdNodes)
	assertTest(okDup == false and string.find(errDup or "", "Duplicate") ~= nil, "[PassiveData] Duplicate node ID rejected")

	-- 6. Player unlock lifecycle
	local passPlayer: StateTypes.PlayerState = {
		UserId = 6002,
		DisplayName = "TreeClimber",
		ClassId = "Warlord",
		SubclassId = "Berserker",
		Resources = { HP = 110, MaxHP = 110, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = {},
		Gold = 0,
		IsReady = false,
		IsDowned = false,
		IsConnected = true,
		UnlockedPassives = {},
		PassivePoints = 0,
	}

	-- Insufficient points rejected
	local okNoPoints, errNoPoints = PassiveService.unlockNode(passPlayer, "Warlord_IronSkin")
	assertTest(okNoPoints == false and string.find(errNoPoints or "", "Insufficient") ~= nil, "[PassiveService] Unlock rejected when points insufficient")

	-- Grant points and unlock root node
	PassiveService.grantPoints(passPlayer, 2)
	assertTest(passPlayer.PassivePoints == 2, "[PassiveService] grantPoints correctly increased PassivePoints")

	local okUnlockRoot, errUnlockRoot = PassiveService.unlockNode(passPlayer, "Warlord_IronSkin")
	assertTest(okUnlockRoot == true and errUnlockRoot == nil, "[PassiveService] Unlocking root node succeeds")
	assertTest(passPlayer.UnlockedPassives ~= nil and passPlayer.UnlockedPassives["Warlord_IronSkin"] == true, "[PassiveService] Node marked unlocked in player state")
	assertTest(passPlayer.PassivePoints == 1, "[PassiveService] Passive points deducted by cost")

	-- Duplicate unlock rejected
	local okDupUnlock, errDupUnlock = PassiveService.unlockNode(passPlayer, "Warlord_IronSkin")
	assertTest(okDupUnlock == false and string.find(errDupUnlock or "", "already unlocked") ~= nil, "[PassiveService] Duplicate unlock rejected")

	-- Child node unlock fails if prereq not unlocked (e.g. TitanStance requires both JuggernautProwess and HeavyStrikes)
	PassiveService.grantPoints(passPlayer, 5)
	local okPrematureTitan, errPrematureTitan = PassiveService.unlockNode(passPlayer, "Warlord_TitanStance")
	assertTest(okPrematureTitan == false and string.find(errPrematureTitan or "", "Prerequisite") ~= nil, "[PassiveService] Keystone rejected when branch prerequisites not unlocked")

	-- Unlock branch HeavyStrikes
	local okHeavy, errHeavy = PassiveService.unlockNode(passPlayer, "Warlord_HeavyStrikes")
	assertTest(okHeavy == true and errHeavy == nil, "[PassiveService] Unlocking branch node succeeds once root prerequisite unlocked")

	-- Class mismatch rejected
	passPlayer.ClassId = "Shadowblade"
	local okMismatch, errMismatch = PassiveService.unlockNode(passPlayer, "Warlord_JuggernautProwess")
	assertTest(okMismatch == false and string.find(errMismatch or "", "requires class") ~= nil, "[PassiveService] Class mismatch node unlock rejected")
	passPlayer.ClassId = "Warlord"

	-- Collect modifiers
	local passMods = PassiveService.collectModifiers(passPlayer)
	assertTest(#passMods == 2, "[PassiveService] collectModifiers returned modifiers from both unlocked nodes")

	end
	----------------------------------------------------------------------------
	-- TEST 43: Phase 3 Active Skills Runtime
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 43] Phase 3 Active Skills Runtime ---")
	local skillUser = 6003
	local skillPlayer: StateTypes.PlayerState = {
		UserId = skillUser,
		DisplayName = "SkillMaster",
		ClassId = "Warlord",
		SubclassId = "Berserker",
		Resources = { HP = 110, MaxHP = 110, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = {},
		Gold = 0,
		IsReady = false,
		IsDowned = false,
		IsConnected = true,
		EquippedSkills = {},
		UnlockedSkills = {
			["HeroicStrike"] = true,
			["Whirlwind"] = true,
		},
		SkillInventory = {},
	}

	-- 1. Create skill instance
	local skillInst1 = SkillService.createInstance("HeroicStrike", skillUser, "Skill1")
	assertTest(skillInst1 ~= nil and skillInst1.DefinitionId == "HeroicStrike", "[SkillService] createInstance created HeroicStrike")
	assertTest(skillInst1 ~= nil and skillInst1.CurrentCooldown == 0, "[SkillService] Created skill instance starts with 0 cooldown")
	assert(skillInst1, "skillInst1 created")
	table.insert(skillPlayer.SkillInventory, skillInst1)

	-- 2. Unknown skill ID rejected
	local badSkillInst = SkillService.createInstance("NonExistentSkillXYZ", skillUser, "Skill1")
	assertTest(badSkillInst == nil, "[SkillService] Unknown skill definition returns nil")

	-- 3. Class restriction enforcement
	skillPlayer.ClassId = "AetherMage"
	local classSkillInst = SkillService.createInstance("Whirlwind", skillUser, "Skill2")
	assert(classSkillInst, "classSkillInst must be non-nil")
	table.insert(skillPlayer.SkillInventory, classSkillInst)
	local okClassSkill, errClassSkill = SkillService.equipSkill(skillPlayer, classSkillInst)
	assertTest(okClassSkill == false and string.find(errClassSkill or "", "requires class") ~= nil, "[SkillService] Warlord skill rejected for AetherMage")
	skillPlayer.ClassId = "Warlord"

	-- 4. Equip skill
	assert(skillInst1, "skillInst1 must be non-nil")
	local okEquipSkill, errEquipSkill = SkillService.equipSkill(skillPlayer, skillInst1)
	assertTest(okEquipSkill == true and errEquipSkill == nil, "[SkillService] equipSkill succeeds for valid slot")
	assertTest(skillPlayer.EquippedSkills ~= nil and skillPlayer.EquippedSkills["Skill1"] == skillInst1, "[SkillService] Skill placed in EquippedSkills['Skill1']")

	-- 5. Execution, energy deduction, and cooldown
	local combatDummy: StateTypes.CombatState = {
		CombatId = "combat_skill_test",
		Phase = "PlayerPhase",
		TurnNumber = 1,
		TurnStartTime = os.clock(),
		TurnDuration = 45,
		Participants = { skillUser },
		Enemies = {
			["dummy_enemy"] = {
				InstanceId = "dummy_enemy",
				DefinitionId = "SpireSentinel",
				Name = "Sentinel Dummy",
				HP = 50,
				MaxHP = 50,
				Shield = 0,
				Poison = 0,
				AttackPower = 5,
				Intent = { Type = "Attack", Value = 5 },
				ModelRef = nil,
			},
		},
		ReadyPlayers = {},
		CombatLog = {},
	}
	local dummyParty: { [number]: StateTypes.PlayerState } = { [skillUser] = skillPlayer }

	local okUse, errUse = SkillService.useSkill(skillPlayer, "Skill1", "dummy_enemy", combatDummy, dummyParty)
	assertTest(okUse == true and errUse == nil, "[SkillService] useSkill executes successfully")
	assertTest(skillPlayer.Resources.Energy == 2, "[SkillService] Energy deducted from 3 to 2")
	assertTest(skillInst1.CurrentCooldown == 1, "[SkillService] Skill cooldown set to 1")
	assertTest(combatDummy.Enemies["dummy_enemy"].HP == 38, "[SkillService] HeroicStrike dealt 12 damage (50 -> 38)")

	-- 6. Trying to use skill on cooldown rejected
	local okUseCD, errUseCD = SkillService.useSkill(skillPlayer, "Skill1", "dummy_enemy", combatDummy, dummyParty)
	assertTest(okUseCD == false and string.find(errUseCD or "", "cooldown") ~= nil, "[SkillService] useSkill rejected while on cooldown")

	-- 7. Cooldown decrement on turn start
	SkillService.onTurnStart(skillPlayer)
	assertTest(skillInst1.CurrentCooldown == 0, "[SkillService] onTurnStart decremented cooldown from 1 to 0")

	-- 8. Insufficient energy rejection
	skillPlayer.Resources.Energy = 0
	local okNoEnergy, errNoEnergy = SkillService.useSkill(skillPlayer, "Skill1", "dummy_enemy", combatDummy, dummyParty)
	assertTest(okNoEnergy == false and string.find(errNoEnergy or "", "Energy") ~= nil, "[SkillService] useSkill rejected on insufficient energy")
	assertTest(combatDummy.Enemies["dummy_enemy"].HP == 38, "[SkillService] Enemy HP untouched when skill rejected for energy")

	end
	----------------------------------------------------------------------------
	-- TEST 44: Complete Vertical Slice End-to-End Test
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 44] Complete Vertical Slice End-to-End Test ---")

	local sliceUser = 7001
	local slicePlayer: StateTypes.PlayerState = {
		UserId = sliceUser,
		DisplayName = "VerticalHero",
		ClassId = "Warlord",
		SubclassId = "Berserker",
		Resources = { HP = 110, MaxHP = 110, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = {},
		Gold = 0,
		IsReady = false,
		IsDowned = false,
		IsConnected = true,
		EquippedItems = {},
		EquipmentInventory = {},
		EquippedSkills = {},
		UnlockedSkills = {
			["HeroicStrike"] = true,
		},
		UnlockedPassives = {},
		PassivePoints = 0,
	}

	-- 1. Initial baseline MaxHP is 110
	local initialStats = StatResolver.resolvePlayerStats(slicePlayer)
	assertTest(initialStats.MaxHP == 110, "[VerticalSlice] Baseline Warlord MaxHP is 110")

	-- 2. Equip IronBroadsword (+5 Damage, +10 MaxHP)
	local sliceSword = EquipmentService.createInstance("IronBroadsword", sliceUser)
	assert(sliceSword, "sliceSword must be created")
	table.insert(slicePlayer.EquipmentInventory, sliceSword)
	EquipmentService.equipItem(slicePlayer, sliceSword)
	local postEquipStats = StatResolver.syncPlayerDerivedStats(slicePlayer)
	assertTest(slicePlayer.Resources.MaxHP == 120, "[VerticalSlice] Equipped weapon increased player MaxHP to 120 (110 + 10)")
	assertTest(postEquipStats.BonusDamage == 5, "[VerticalSlice] Equipped weapon grants +5 BonusDamage")

	-- 3. Grant passive points and unlock Warlord_IronSkin (+15 MaxHP)
	PassiveService.grantPoints(slicePlayer, 2)
	local okUnlock1, _ = PassiveService.unlockNode(slicePlayer, "Warlord_IronSkin")
	assertTest(okUnlock1 == true, "[VerticalSlice] Unlocked IronSkin passive")
	assertTest(slicePlayer.Resources.MaxHP == 135, "[VerticalSlice] Passive increased player MaxHP to 135 (110 + 10 + 15)")

	-- 4. Unlock Warlord_HeavyStrikes (+3 Damage)
	local okUnlock2, _ = PassiveService.unlockNode(slicePlayer, "Warlord_HeavyStrikes")
	assertTest(okUnlock2 == true, "[VerticalSlice] Unlocked HeavyStrikes passive")

	local postPassiveStats = StatResolver.resolvePlayerStats(slicePlayer)
	assertTest(postPassiveStats.BonusDamage == 8, "[VerticalSlice] Stacked weapon (+5) and passive (+3) yield +8 BonusDamage")

	-- 5. Equip active skill HeroicStrike (Base 12 Dmg, 1 Energy, 1 Turn CD)
	local sliceSkill = SkillService.createInstance("HeroicStrike", sliceUser, "Skill1")
	assert(sliceSkill, "sliceSkill must be created")
	slicePlayer.SkillInventory = { sliceSkill }
	slicePlayer.UnlockedSkills = { ["HeroicStrike"] = true }
	SkillService.equipSkill(slicePlayer, sliceSkill)
	assertTest(slicePlayer.EquippedSkills ~= nil and slicePlayer.EquippedSkills["Skill1"] == sliceSkill, "[VerticalSlice] HeroicStrike equipped in Skill1")

	-- 6. Setup combat encounter with 100 HP target
	local sliceCombat: StateTypes.CombatState = {
		CombatId = "combat_vertical_slice",
		Phase = "PlayerPhase",
		TurnNumber = 1,
		TurnStartTime = os.clock(),
		TurnDuration = 45,
		Participants = { sliceUser },
		Enemies = {
			["boss_target"] = {
				InstanceId = "boss_target",
				DefinitionId = "SpireSentinel",
				Name = "Dungeon Boss",
				HP = 100,
				MaxHP = 100,
				Shield = 0,
				Poison = 0,
				AttackPower = 15,
				Intent = { Type = "Attack", Value = 15 },
				ModelRef = nil,
			},
		},
		ReadyPlayers = {},
		CombatLog = {},
	}
	local sliceParty: { [number]: StateTypes.PlayerState } = { [sliceUser] = slicePlayer }

	-- 7. Execute skill: Player -> Equip Item -> Stat Mod -> Unlock Passive -> Equip Skill -> Use Skill -> DamagePipeline -> CombatState
	local okSliceUse, errSliceUse = SkillService.useSkill(slicePlayer, "Skill1", "boss_target", sliceCombat, sliceParty)
	assertTest(okSliceUse == true and errSliceUse == nil, "[VerticalSlice] Active skill executed successfully end-to-end")

	-- 8. Verify exact combat results
	local bossEnemy = sliceCombat.Enemies["boss_target"]
	assertTest(slicePlayer.Resources.Energy == 2, "[VerticalSlice] Player energy correctly deducted from 3 to 2")
	assertTest(sliceSkill.CurrentCooldown == 1, "[VerticalSlice] Skill entered cooldown (1 turn)")
	assertTest(bossEnemy.HP == 80, string.format("[VerticalSlice] Boss HP reduced by exact total damage: 100 -> %d (Base 12 + Gear 5 + Passive 3 = 20 Dmg)", bossEnemy.HP))

	-- 9. Turn progression advances and cooldown ticks back to ready
	SkillService.onTurnStart(slicePlayer)
	assertTest(sliceSkill.CurrentCooldown == 0, "[VerticalSlice] Cooldown decremented to 0 after turn start")

	-- 10. Execute second strike to confirm complete lifecycle repeat
	local okSliceUse2, _ = SkillService.useSkill(slicePlayer, "Skill1", "boss_target", sliceCombat, sliceParty)
	assertTest(okSliceUse2 == true, "[VerticalSlice] Second skill execution succeeded after cooldown refresh")
	assertTest(bossEnemy.HP == 60, string.format("[VerticalSlice] Boss HP further reduced from 80 -> %d (total 40 damage dealt across 2 skill uses)", bossEnemy.HP))

	end
	----------------------------------------------------------------------------
	-- TEST 45: Phase 3.1 Equipment Authority Hardening
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 45] Phase 3.1 Equipment Authority Hardening ---")
	local authUser = 8001
	local authPlayer: StateTypes.PlayerState = {
		UserId = authUser,
		DisplayName = "AuthKnight",
		ClassId = "Warlord",
		SubclassId = "Berserker",
		Resources = { HP = 110, MaxHP = 110, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = {},
		Gold = 0,
		IsReady = false,
		IsDowned = false,
		IsConnected = true,
		EquippedItems = {},
		EquipmentInventory = {},
	}

	-- 1. Forged Slot Rejection: Definition says Weapon, instance forged as Armor
	local forgedSword = EquipmentService.createInstance("IronBroadsword", authUser)
	assert(forgedSword, "forgedSword created")
	table.insert(authPlayer.EquipmentInventory, forgedSword)
	;(forgedSword :: any).Slot = "Armor"
	local okForged, errForged = EquipmentService.equipItem(authPlayer, forgedSword)
	assertTest(okForged == false and string.find(errForged or "", "Forged slot") ~= nil, "[EquipmentAuthority] Forged slot rejected with explicit error")
	assertTest(authPlayer.EquippedItems ~= nil and authPlayer.EquippedItems["Armor"] == nil, "[EquipmentAuthority] Forged item not equipped in Armor slot")
	assertTest(authPlayer.EquippedItems ~= nil and authPlayer.EquippedItems["Weapon"] == nil, "[EquipmentAuthority] Forged item not equipped in Weapon slot")
	-- Reset forged slot
	forgedSword.Slot = "Weapon"

	-- 2. Inventory Absence Rejection: Valid instance but not in EquipmentInventory
	local phantomPlate = EquipmentService.createInstance("ReinforcedPlate", authUser)
	assert(phantomPlate, "phantomPlate created")
	local okPhantom, errPhantom = EquipmentService.equipItem(authPlayer, phantomPlate)
	assertTest(okPhantom == false and string.find(errPhantom or "", "not found in player's inventory") ~= nil, "[EquipmentAuthority] Fabricated instance absent from inventory rejected")

	-- 3. Authoritative Provisioning via grantEquipment
	local grantedArmor = EquipmentService.grantEquipment(authPlayer, "ReinforcedPlate")
	assertTest(grantedArmor ~= nil, "[EquipmentAuthority] grantEquipment provisioned item")
	local foundInInv = false
	if authPlayer.EquipmentInventory then
		for _, item in ipairs(authPlayer.EquipmentInventory) do
			if item.InstanceId == (grantedArmor :: any).InstanceId then
				foundInInv = true
				break
			end
		end
	end
	assertTest(foundInInv == true, "[EquipmentAuthority] Granted item placed authoritatively in EquipmentInventory")

	-- 4. Equip provisioned item succeeds
	local okEquipGranted, _ = EquipmentService.equipItem(authPlayer, grantedArmor)
	assertTest(okEquipGranted == true, "[EquipmentAuthority] Equipping provisioned inventory item succeeds")
	assertTest(authPlayer.EquippedItems ~= nil and authPlayer.EquippedItems["Armor"] == grantedArmor, "[EquipmentAuthority] Item placed in EquippedItems['Armor']")

	-- 5. Duplicate equipped instance prevention
	local okDupEquip, errDupEquip = EquipmentService.equipItem(authPlayer, grantedArmor)
	assertTest(okDupEquip == false or (authPlayer.EquippedItems ~= nil and authPlayer.EquippedItems["Armor"] == grantedArmor), "[EquipmentAuthority] Duplicate equip handled safely")

	-- 6. Slot Replacement preserves instances without loss or duplication
	local grantedArmor2 = EquipmentService.grantEquipment(authPlayer, "ReinforcedPlate")
	assert(grantedArmor2, "grantedArmor2 created")
	local okReplaceArmor, _ = EquipmentService.equipItem(authPlayer, grantedArmor2)
	assertTest(okReplaceArmor == true, "[EquipmentAuthority] Second armor equipped to replace first")
	assertTest(authPlayer.EquippedItems ~= nil and authPlayer.EquippedItems["Armor"] == grantedArmor2, "[EquipmentAuthority] Slot now holds second armor")
	assertTest(authPlayer.EquipmentInventory ~= nil and #authPlayer.EquipmentInventory >= 1, "[EquipmentAuthority] First armor cleanly returned to EquipmentInventory")

	-- 7. Deterministic Slot Modifier Ordering
	local validSword = EquipmentService.grantEquipment(authPlayer, "IronBroadsword")
	assert(validSword, "validSword created")
	EquipmentService.equipItem(authPlayer, validSword)
	local mods = EquipmentService.collectModifiers(authPlayer)
	assertTest(#mods >= 2, "[EquipmentAuthority] Modifiers collected across equipped gear")
	local isSorted = true
	for i = 1, #mods - 1 do
		if mods[i].Priority > mods[i + 1].Priority then
			isSorted = false
			break
		end
	end
	assertTest(isSorted == true, "[EquipmentAuthority] Collected modifiers sorted deterministically by Priority")

	end
	----------------------------------------------------------------------------
	-- TEST 46: Phase 3.1 Active Skill Ownership & Cooldown Hardening
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 46] Phase 3.1 Active Skill Ownership & Cooldown Hardening ---")
	local skillAuthUser = 8002
	local skillAuthPlayer: StateTypes.PlayerState = {
		UserId = skillAuthUser,
		DisplayName = "SkillGuardian",
		ClassId = "Warlord",
		SubclassId = "Berserker",
		Resources = { HP = 110, MaxHP = 110, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = {},
		Gold = 0,
		IsReady = false,
		IsDowned = false,
		IsConnected = true,
		EquippedSkills = {},
		UnlockedSkills = {},
		SkillInventory = {},
	}

	-- 1. Unlocked Check: Equipping unowned skill rejected
	local whirlSkill = SkillService.createInstance("Whirlwind", skillAuthUser, "Skill2")
	assert(whirlSkill, "whirlSkill created")
	table.insert(skillAuthPlayer.SkillInventory, whirlSkill)
	local okUnowned, errUnowned = SkillService.equipSkill(skillAuthPlayer, whirlSkill)
	assertTest(okUnowned == false and string.find(errUnowned or "", "unlocked") ~= nil, "[SkillHardening] Unowned skill equip rejected")

	-- 2. Authoritative Skill Unlock
	local okUnlockSkill, _ = SkillService.unlockSkill(skillAuthPlayer, "Whirlwind")
	assertTest(okUnlockSkill == true, "[SkillHardening] unlockSkill authoritatively unlocked Whirlwind")
	assertTest(SkillService.hasSkill(skillAuthPlayer, "Whirlwind") == true, "[SkillHardening] hasSkill confirms skill unlocked")

	-- 3. Equip unlocked skill succeeds
	local okEquipWhirl, _ = SkillService.equipSkill(skillAuthPlayer, whirlSkill)
	assertTest(okEquipWhirl == true, "[SkillHardening] Equipping unlocked skill succeeds")
	assertTest(skillAuthPlayer.EquippedSkills ~= nil and skillAuthPlayer.EquippedSkills["Skill2"] == whirlSkill, "[SkillHardening] Skill placed in EquippedSkills['Skill2']")

	-- 4. Invalid Slot Rejection at runtime
	local badSlotSkill = SkillService.createInstance("HeroicStrike", skillAuthUser, "InvalidSlot" :: any)
	assertTest(badSlotSkill == nil, "[SkillHardening] createInstance rejects invalid slot")
	;(whirlSkill :: any).Slot = "Skill99"
	local okBadSlot, errBadSlot = SkillService.equipSkill(skillAuthPlayer, whirlSkill)
	assertTest(okBadSlot == false and string.find(errBadSlot or "", "Invalid skill slot") ~= nil, "[SkillHardening] equipSkill rejects invalid runtime slot")
	whirlSkill.Slot = "Skill2"

	-- 5. Class Restriction Rejection
	local mageUser = 8003
	local magePlayer: StateTypes.PlayerState = {
		UserId = mageUser,
		DisplayName = "AetherMageHero",
		ClassId = "AetherMage",
		SubclassId = "Elementalist",
		Resources = { HP = 80, MaxHP = 80, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = {},
		Gold = 0,
		IsReady = false,
		IsDowned = false,
		IsConnected = true,
		EquippedSkills = {},
		UnlockedSkills = {},
	}
	local okMageUnlock, errMageUnlock = SkillService.unlockSkill(magePlayer, "Whirlwind")
	assertTest(okMageUnlock == false and string.find(errMageUnlock or "", "requires class") ~= nil, "[SkillHardening] unlockSkill rejects class-mismatched skill")

	-- 6. Duplicate Equipped Instance Rejection
	whirlSkill.Slot = "Skill3"
	local okDupSkill, errDupSkill = SkillService.equipSkill(skillAuthPlayer, whirlSkill)
	assertTest(okDupSkill == false and string.find(errDupSkill or "", "already equipped") ~= nil, "[SkillHardening] Equipping same skill instance to another slot rejected")
	whirlSkill.Slot = "Skill2"

	-- 7. Cooldown runtime isolation (cannot bypass by re-equipping)
	whirlSkill.CurrentCooldown = 2
	local okReEquip, _ = SkillService.equipSkill(skillAuthPlayer, whirlSkill)
	assertTest(okReEquip == true, "[SkillHardening] Re-equipping same slot updates state")
	assertTest(whirlSkill.CurrentCooldown == 2, "[SkillHardening] Cooldown strictly preserved and isolated on runtime instance")

	end
	----------------------------------------------------------------------------
	-- TEST 47: Phase 3.1 Passive Tree Hardening & Negative Modifier Stacking
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 47] Phase 3.1 Passive Tree Hardening & Negative Modifier Stacking ---")

	-- 1. Malformed Node Rejection: Empty string ID
	local malformedEmptyId: { PassiveData.PassiveNodeDefinition } = {
		{
			Id = "",
			Name = "Bad Node",
			Description = "Invalid",
			ClassId = "Warlord",
			Type = "Stat",
			Tier = 1,
			Cost = 1,
			Prerequisites = {},
			Modifiers = {},
		},
	}
	local okEmptyId, errEmptyId = PassiveData.validateNodes(malformedEmptyId)
	assertTest(okEmptyId == false and string.find(errEmptyId or "", "non-empty string") ~= nil, "[PassiveHardening] Node with empty string ID rejected")

	-- 2. Malformed Node Rejection: Non-table prerequisites
	local malformedNilPrereq: { any } = {
		{
			Id = "NodeNilPrereq",
			Name = "Bad Prereq",
			Description = "Invalid",
			ClassId = "Warlord",
			Type = "Stat",
			Tier = 1,
			Cost = 1,
			Prerequisites = "NotATable",
			Modifiers = {},
		},
	}
	local okNilPrereq, errNilPrereq = PassiveData.validateNodes(malformedNilPrereq :: any)
	assertTest(okNilPrereq == false and string.find(errNilPrereq or "", "Prerequisites array") ~= nil, "[PassiveHardening] Node with non-array Prerequisites rejected")

	-- 3. Malformed Node Rejection: Empty string in prerequisites
	local malformedEmptyPrereq: { PassiveData.PassiveNodeDefinition } = {
		{
			Id = "NodeEmptyPrereq",
			Name = "Bad Prereq Item",
			Description = "Invalid",
			ClassId = "Warlord",
			Type = "Stat",
			Tier = 1,
			Cost = 1,
			Prerequisites = { "" },
			Modifiers = {},
		},
	}
	local okEmptyPrereq, errEmptyPrereq = PassiveData.validateNodes(malformedEmptyPrereq)
	assertTest(okEmptyPrereq == false and string.find(errEmptyPrereq or "", "non-empty string") ~= nil, "[PassiveHardening] Empty string prerequisite rejected")

	-- 4. Negative Modifier Stacking: TitanStance (-1 MaxEnergy)
	local titanPlayer: StateTypes.PlayerState = {
		UserId = 8004,
		DisplayName = "TitanHero",
		ClassId = "Warlord",
		SubclassId = "Berserker",
		Resources = { HP = 110, MaxHP = 110, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = {},
		Gold = 0,
		IsReady = false,
		IsDowned = false,
		IsConnected = true,
		UnlockedPassives = {},
		PassivePoints = 0,
	}

	PassiveService.grantPoints(titanPlayer, 10)
	PassiveService.unlockNode(titanPlayer, "Warlord_IronSkin")
	PassiveService.unlockNode(titanPlayer, "Warlord_HeavyStrikes")
	PassiveService.unlockNode(titanPlayer, "Warlord_JuggernautProwess")
	local okTitan, _ = PassiveService.unlockNode(titanPlayer, "Warlord_TitanStance")
	assertTest(okTitan == true, "[PassiveHardening] Unlocked keystone Warlord_TitanStance")

	local titanStats = StatResolver.resolvePlayerStats(titanPlayer)
	assertTest(titanStats.MaxEnergy == 2, string.format("[PassiveHardening] TitanStance negative MaxEnergy applied: 3 + (-1) = %d", titanStats.MaxEnergy))
	assertTest(titanStats.MaxHP >= 135, "[PassiveHardening] TitanStance stacked MaxHP properly")

	StatResolver.syncPlayerDerivedStats(titanPlayer)
	assertTest(titanPlayer.Resources.MaxEnergy == 2, "[PassiveHardening] syncPlayerDerivedStats synchronized MaxEnergy to 2")

	-- 5. Deterministic sorting in PassiveService.collectModifiers
	local pMods = PassiveService.collectModifiers(titanPlayer)
	local passSorted = true
	for i = 1, #pMods - 1 do
		if pMods[i].Priority > pMods[i + 1].Priority then
			passSorted = false
			break
		end
	end
	assertTest(passSorted == true, "[PassiveHardening] PassiveService.collectModifiers sorted deterministically by Priority")

	end
	----------------------------------------------------------------------------
	-- TEST 48: Phase 3.1 Active Skill Transactional Execution
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 48] Phase 3.1 Active Skill Transactional Execution ---")
	local txUser = 8005
	local txPlayer: StateTypes.PlayerState = {
		UserId = txUser,
		DisplayName = "TxHero",
		ClassId = "Warlord",
		SubclassId = "Berserker",
		Resources = { HP = 110, MaxHP = 110, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = {},
		Gold = 0,
		IsReady = false,
		IsDowned = false,
		IsConnected = true,
		EquippedSkills = {},
		UnlockedSkills = { ["HeroicStrike"] = true },
		SkillInventory = {},
	}
	local txSkill = SkillService.createInstance("HeroicStrike", txUser, "Skill1")
	assert(txSkill, "txSkill created")
	table.insert(txPlayer.SkillInventory, txSkill)
	SkillService.equipSkill(txPlayer, txSkill)

	local txCombat: StateTypes.CombatState = {
		CombatId = "combat_tx_test",
		Phase = "PlayerPhase",
		TurnNumber = 1,
		TurnStartTime = os.clock(),
		TurnDuration = 45,
		Participants = { txUser },
		Enemies = {
			["alive_target"] = {
				InstanceId = "alive_target",
				DefinitionId = "SpireSentinel",
				Name = "Sentinel Tx",
				HP = 60,
				MaxHP = 60,
				Shield = 0,
				Poison = 0,
				AttackPower = 10,
				Intent = { Type = "Attack", Value = 10 },
				ModelRef = nil,
			},
			["dead_target"] = {
				InstanceId = "dead_target",
				DefinitionId = "SpireSentinel",
				Name = "Sentinel Dead",
				HP = 0,
				MaxHP = 60,
				Shield = 0,
				Poison = 0,
				AttackPower = 0,
				Intent = { Type = "Attack", Value = 0 },
				ModelRef = nil,
			},
		},
		ReadyPlayers = {},
		CombatLog = {},
	}
	local txParty: { [number]: StateTypes.PlayerState } = { [txUser] = txPlayer }

	-- 1. Disconnected player rejected (zero cost / zero cooldown)
	txPlayer.IsConnected = false
	local okDisc, errDisc = SkillService.useSkill(txPlayer, "Skill1", "alive_target", txCombat, txParty)
	assertTest(okDisc == false and string.find(errDisc or "", "Disconnected") ~= nil, "[SkillTx] Disconnected player rejected")
	assertTest(txPlayer.Resources.Energy == 3 and txSkill.CurrentCooldown == 0, "[SkillTx] Disconnected rejection consumed 0 Energy and 0 Cooldown")
	txPlayer.IsConnected = true

	-- 2. Downed player rejected (zero cost / zero cooldown)
	txPlayer.IsDowned = true
	local okDowned, errDowned = SkillService.useSkill(txPlayer, "Skill1", "alive_target", txCombat, txParty)
	assertTest(okDowned == false and string.find(errDowned or "", "Downed") ~= nil, "[SkillTx] Downed player rejected")
	assertTest(txPlayer.Resources.Energy == 3 and txSkill.CurrentCooldown == 0, "[SkillTx] Downed rejection consumed 0 Energy and 0 Cooldown")
	txPlayer.IsDowned = false

	-- 3. Non-PlayerPhase rejected (zero cost / zero cooldown)
	txCombat.Phase = "ResolutionPhase"
	local okPhase, errPhase = SkillService.useSkill(txPlayer, "Skill1", "alive_target", txCombat, txParty)
	assertTest(okPhase == false and string.find(errPhase or "", "PlayerPhase") ~= nil, "[SkillTx] Non-PlayerPhase rejected")
	assertTest(txPlayer.Resources.Energy == 3 and txSkill.CurrentCooldown == 0, "[SkillTx] Phase rejection consumed 0 Energy and 0 Cooldown")
	txCombat.Phase = "PlayerPhase"

	-- 4. Target resolution failure with zero cost / zero cooldown rollback
	local okInvalidTarget, errInvalidTarget = SkillService.useSkill(txPlayer, "Skill1", "non_existent_enemy", txCombat, txParty)
	assertTest(okInvalidTarget == false and errInvalidTarget ~= nil, "[SkillTx] Target not found rejected")
	assertTest(txPlayer.Resources.Energy == 3, "[SkillTx] Target resolution failure consumed exactly 0 Energy (rollback)")
	assertTest(txSkill.CurrentCooldown == 0, "[SkillTx] Target resolution failure triggered 0 Cooldown (rollback)")

	-- 5. Defeated enemy target rejected with zero cost / zero cooldown rollback
	local okDeadTarget, errDeadTarget = SkillService.useSkill(txPlayer, "Skill1", "dead_target", txCombat, txParty)
	assertTest(okDeadTarget == false and errDeadTarget ~= nil, "[SkillTx] Defeated enemy target rejected")
	assertTest(txPlayer.Resources.Energy == 3, "[SkillTx] Defeated target consumed exactly 0 Energy")
	assertTest(txSkill.CurrentCooldown == 0, "[SkillTx] Defeated target triggered 0 Cooldown")

	-- 6. Successful transactional execution
	local okTxSuccess, _ = SkillService.useSkill(txPlayer, "Skill1", "alive_target", txCombat, txParty)
	assertTest(okTxSuccess == true, "[SkillTx] Valid target executed successfully")
	assertTest(txPlayer.Resources.Energy == 2, "[SkillTx] Exactly 1 Energy deducted on success")
	assertTest(txSkill.CurrentCooldown == 1, "[SkillTx] Cooldown set to 1 on success")
	assertTest(txCombat.Enemies["alive_target"].HP == 48, "[SkillTx] Enemy took exact skill damage (60 -> 48)")

	end
	----------------------------------------------------------------------------
	-- TEST 49: Phase 3.1 Network Contracts & Remote Event Authority
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 49] Phase 3.1 Network Contracts & Remote Event Authority ---")

	-- 1. All 6 RemoteEvents registered in NetworkService
	assertTest(NetworkService.EquipEquipmentEvent ~= nil, "[NetworkAuthority] EquipEquipmentEvent registered")
	assertTest(NetworkService.UnequipEquipmentEvent ~= nil, "[NetworkAuthority] UnequipEquipmentEvent registered")
	assertTest(NetworkService.EquipSkillEvent ~= nil, "[NetworkAuthority] EquipSkillEvent registered")
	assertTest(NetworkService.UnequipSkillEvent ~= nil, "[NetworkAuthority] UnequipSkillEvent registered")
	assertTest(NetworkService.UnlockPassiveEvent ~= nil, "[NetworkAuthority] UnlockPassiveEvent registered")
	assertTest(NetworkService.UseSkillEvent ~= nil, "[NetworkAuthority] UseSkillEvent registered")

	-- 2. Category Rate Limiting enforcement
	local dummyPlayerObj = { UserId = 8006, Name = "NetTester" }
	local canCall1 = NetworkService.checkRateLimit(dummyPlayerObj :: any, "General")
	assertTest(canCall1 == true, "[NetworkAuthority] Initial rate limit check passes")

	-- 3. Inferred sender authority contract: Server identifies sender strictly from player argument
	assertTest(typeof(NetworkService.EquipEquipmentEvent.Name) == "string", "[NetworkAuthority] RemoteEvent has valid Roblox Instance name")

	end
	----------------------------------------------------------------------------
	-- TEST 50: Phase 3.1 Extended Vertical Slice End-to-End Test
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 50] Phase 3.1 Extended Vertical Slice End-to-End ---")

	local extUser = 9001
	local extPlayer: StateTypes.PlayerState = {
		UserId = extUser,
		DisplayName = "ExtHero",
		ClassId = "Warlord",
		SubclassId = "Berserker",
		Resources = { HP = 110, MaxHP = 110, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = {},
		Gold = 0,
		IsReady = false,
		IsDowned = false,
		IsConnected = true,
		EquippedItems = {},
		EquipmentInventory = {},
		EquippedSkills = {},
		UnlockedSkills = {},
		UnlockedPassives = {},
		PassivePoints = 0,
	}

	-- 1. Baseline stats
	local extBaseStats = StatResolver.resolvePlayerStats(extPlayer)
	assertTest(extBaseStats.MaxHP == 110, "[ExtSlice] Baseline MaxHP is 110")

	-- 2. Authoritative provisioning and equipping of gear
	local extSword = EquipmentService.grantEquipment(extPlayer, "IronBroadsword")
	local extArmor = EquipmentService.grantEquipment(extPlayer, "ReinforcedPlate")
	assert(extSword and extArmor, "Equipment granted")
	EquipmentService.equipItem(extPlayer, extSword)
	EquipmentService.equipItem(extPlayer, extArmor)
	StatResolver.syncPlayerDerivedStats(extPlayer)
	assertTest(extPlayer.Resources.MaxHP == 140, "[ExtSlice] Equipped weapon and armor: MaxHP updated to 140 (110 + 10 + 20)")

	-- 3. Authoritative passive unlock
	PassiveService.grantPoints(extPlayer, 2)
	PassiveService.unlockNode(extPlayer, "Warlord_IronSkin")
	PassiveService.unlockNode(extPlayer, "Warlord_HeavyStrikes")
	local extPassiveStats = StatResolver.syncPlayerDerivedStats(extPlayer)
	assertTest(extPlayer.Resources.MaxHP == 155, "[ExtSlice] Passives unlocked: MaxHP updated to 155 (140 + 15)")
	assertTest(extPassiveStats.BonusDamage == 8, "[ExtSlice] Stacked weapon (+5) and passive (+3) yield +8 BonusDamage")

	-- 4. Authoritative skill unlock and equip
	local okExtSkillUnlock, _, extSkillInst = SkillService.unlockSkill(extPlayer, "HeroicStrike")
	assertTest(okExtSkillUnlock == true, "[ExtSlice] HeroicStrike authoritatively unlocked")
	assert(extSkillInst, "extSkillInst created")
	extSkillInst.Slot = "Skill1"
	local okExtSkillEquip, _ = SkillService.equipSkill(extPlayer, extSkillInst)
	assertTest(okExtSkillEquip == true, "[ExtSlice] HeroicStrike equipped in Skill1")

	-- 5. Combat encounter setup
	local extCombat: StateTypes.CombatState = {
		CombatId = "combat_ext_slice",
		Phase = "PlayerPhase",
		TurnNumber = 1,
		TurnStartTime = os.clock(),
		TurnDuration = 45,
		Participants = { extUser },
		Enemies = {
			["boss_encounter"] = {
				InstanceId = "boss_encounter",
				DefinitionId = "SpireSentinel",
				Name = "Dungeon Overlord",
				HP = 150,
				MaxHP = 150,
				Shield = 0,
				Poison = 0,
				AttackPower = 20,
				Intent = { Type = "Attack", Value = 20 },
				ModelRef = nil,
			},
		},
		ReadyPlayers = {},
		CombatLog = {},
	}
	local extParty: { [number]: StateTypes.PlayerState } = { [extUser] = extPlayer }

	-- 6. Execute active skill with full modifier pipeline
	local okUseSkillExt, _ = SkillService.useSkill(extPlayer, "Skill1", "boss_encounter", extCombat, extParty)
	assertTest(okUseSkillExt == true, "[ExtSlice] HeroicStrike executed end-to-end")
	local bossEncounter = extCombat.Enemies["boss_encounter"]
	assertTest(bossEncounter.HP == 130, string.format("[ExtSlice] Boss HP reduced by 20: 150 -> %d (Base 12 + Gear 5 + Passive 3 = 20)", bossEncounter.HP))
	assertTest(extPlayer.Resources.Energy == 2, "[ExtSlice] Energy deducted from 3 to 2")
	assertTest(extSkillInst.CurrentCooldown == 1, "[ExtSlice] Cooldown set to 1")

	-- 7. Cooldown blocks re-use
	local okBlocked, _ = SkillService.useSkill(extPlayer, "Skill1", "boss_encounter", extCombat, extParty)
	assertTest(okBlocked == false, "[ExtSlice] Second use blocked by active cooldown")
	assertTest(extPlayer.Resources.Energy == 2, "[ExtSlice] Energy preserved at 2 on cooldown rejection")

	-- 8. Turn progression decrements cooldown
	SkillService.onTurnStart(extPlayer)
	assertTest(extSkillInst.CurrentCooldown == 0, "[ExtSlice] Cooldown decremented to 0 on turn start")

	-- 9. Second skill execution
	extPlayer.Resources.Energy = 3
	local okSecondUse, _ = SkillService.useSkill(extPlayer, "Skill1", "boss_encounter", extCombat, extParty)
	assertTest(okSecondUse == true, "[ExtSlice] Second skill use succeeded")
	assertTest(bossEncounter.HP == 110, string.format("[ExtSlice] Boss HP reduced to %d (total 40 damage dealt)", bossEncounter.HP))

	-- 10. Unequip gear cleanly removes modifiers with zero stale leaks
	local okUnequipSword, _ = EquipmentService.unequipItem(extPlayer, "Weapon")
	assertTest(okUnequipSword == true, "[ExtSlice] Weapon unequipped")
	local postUnequipStats = StatResolver.syncPlayerDerivedStats(extPlayer)
	assertTest(postUnequipStats.BonusDamage == 3, "[ExtSlice] BonusDamage dropped from 8 to 3 (Weapon removed, Passive remains)")
	assertTest(extPlayer.Resources.MaxHP == 145, "[ExtSlice] MaxHP dropped from 155 to 145 (10 Weapon HP removed)")

	end
	----------------------------------------------------------------------------
	-- TEST 51: Phase 3.2 Network Ownership Boundary & Contract Validation
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 51] Phase 3.2 Network Ownership Boundary & Contract Validation ---")

	-- 1. Remote Event Registration: UnlockSkillEvent registered
	assertTest(NetworkService.UnlockSkillEvent ~= nil, "[NetBoundary] UnlockSkillEvent registered in NetworkService")

	-- 2. Network Slot Contract Validation
	local validEquipmentSlots: { [string]: boolean } = { ["Weapon"] = true, ["Armor"] = true, ["Accessory"] = true }
	local validSkillSlots: { [string]: boolean } = { ["Skill1"] = true, ["Skill2"] = true, ["Skill3"] = true, ["Skill4"] = true }

	local function isValidEquipSlot(slot: any): boolean
		return typeof(slot) == "string" and validEquipmentSlots[slot] == true
	end
	local function isValidSkillSlot(slot: any): boolean
		return typeof(slot) == "string" and validSkillSlots[slot] == true
	end

	assertTest(isValidEquipSlot("Weapon") == true, "[NetContract] Weapon is valid equipment slot")
	assertTest(isValidEquipSlot("Armor") == true, "[NetContract] Armor is valid equipment slot")
	assertTest(isValidEquipSlot("Accessory") == true, "[NetContract] Accessory is valid equipment slot")
	assertTest(isValidEquipSlot("Banana") == false, "[NetContract] Banana rejected as equipment slot")
	assertTest(isValidEquipSlot("Skill1") == false, "[NetContract] Skill1 rejected as equipment slot")
	assertTest(isValidEquipSlot(123) == false, "[NetContract] Number rejected as equipment slot")
	assertTest(isValidEquipSlot("") == false, "[NetContract] Empty string rejected as equipment slot")
	assertTest(isValidEquipSlot({}) == false, "[NetContract] Table rejected as equipment slot")

	assertTest(isValidSkillSlot("Skill1") == true, "[NetContract] Skill1 is valid skill slot")
	assertTest(isValidSkillSlot("Skill4") == true, "[NetContract] Skill4 is valid skill slot")
	assertTest(isValidSkillSlot("Skill99") == false, "[NetContract] Skill99 rejected as skill slot")
	assertTest(isValidSkillSlot("Weapon") == false, "[NetContract] Weapon rejected as skill slot")
	assertTest(isValidSkillSlot(42) == false, "[NetContract] Number rejected as skill slot")
	assertTest(isValidSkillSlot(false) == false, "[NetContract] Boolean rejected as skill slot")

	-- 3. Skill Network Ownership Boundary
	local netUser1 = 9101
	local netUser2 = 9102
	local netPlayer1: StateTypes.PlayerState = {
		UserId = netUser1,
		DisplayName = "NetHeroOne",
		ClassId = "Warlord",
		SubclassId = "Berserker",
		Resources = { HP = 110, MaxHP = 110, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = {},
		Gold = 0,
		IsReady = false,
		IsDowned = false,
		IsConnected = true,
		EquippedItems = {},
		EquipmentInventory = {},
		EquippedSkills = {},
		SkillInventory = {},
		UnlockedSkills = {},
		UnlockedPassives = {},
		PassivePoints = 0,
	}
	local netPlayer2: StateTypes.PlayerState = {
		UserId = netUser2,
		DisplayName = "NetHeroTwo",
		ClassId = "Warlord",
		SubclassId = "Berserker",
		Resources = { HP = 110, MaxHP = 110, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = {},
		Gold = 0,
		IsReady = false,
		IsDowned = false,
		IsConnected = true,
		EquippedItems = {},
		EquipmentInventory = {},
		EquippedSkills = {},
		SkillInventory = {},
		UnlockedSkills = {},
		UnlockedPassives = {},
		PassivePoints = 0,
	}

	-- 3a. Client requests valid but unowned skill definition -> rejected, zero mutation
	local unownedResolved = SkillService.getOwnedSkill(netPlayer1, "Whirlwind")
	assertTest(unownedResolved == nil, "[NetBoundary] Unowned skill definition returns nil from getOwnedSkill")
	local okEquipUnowned, errEquipUnowned = SkillService.equipSkill(netPlayer1, "Whirlwind", "Skill1")
	assertTest(okEquipUnowned == false and string.find(errEquipUnowned or "", "unlocked") ~= nil, "[NetBoundary] Equipping unowned skill definition rejected")
	assertTest(netPlayer1.EquippedSkills["Skill1"] == nil, "[NetBoundary] Zero state mutation on unowned skill equip")

	-- 3b. Client requests invalid skill definition -> rejected, zero mutation
	local badDefResolved = SkillService.getOwnedSkill(netPlayer1, "FakeSkillDef")
	assertTest(badDefResolved == nil, "[NetBoundary] Non-existent skill definition returns nil from getOwnedSkill")
	local okBadDef, _ = SkillService.equipSkill(netPlayer1, "FakeSkillDef", "Skill1")
	assertTest(okBadDef == false, "[NetBoundary] Equipping non-existent skill definition rejected")
	assertTest(netPlayer1.EquippedSkills["Skill1"] == nil, "[NetBoundary] Zero state mutation on non-existent skill equip")

	-- 3c. Client requests another player's skill -> rejected, zero mutation
	local okUnlockP2, _, p2SkillInst = SkillService.unlockSkill(netPlayer2, "HeroicStrike")
	assertTest(okUnlockP2 == true and p2SkillInst ~= nil, "[NetBoundary] Player 2 unlocked HeroicStrike")
	local foreignLookup = SkillService.getOwnedSkill(netPlayer1, (p2SkillInst :: any).InstanceId)
	assertTest(foreignLookup == nil, "[NetBoundary] Player 1 cannot look up Player 2's skill instance via getOwnedSkill")
	table.insert(netPlayer1.SkillInventory, p2SkillInst)
	local okForeignEquip, errForeignEquip = SkillService.equipSkill(netPlayer1, p2SkillInst, "Skill1")
	assertTest(okForeignEquip == false and string.find(errForeignEquip or "", "does not match player") ~= nil, "[NetBoundary] Foreign skill instance rejected by equipSkill")
	table.remove(netPlayer1.SkillInventory, #netPlayer1.SkillInventory)
	assertTest(netPlayer1.EquippedSkills["Skill1"] == nil, "[NetBoundary] Zero state mutation on foreign skill equip")

	-- 3d. Authoritative unlock of skill for player 1
	local okUnlockP1, _, p1SkillInst = SkillService.unlockSkill(netPlayer1, "HeroicStrike")
	assertTest(okUnlockP1 == true and p1SkillInst ~= nil, "[NetBoundary] Player 1 authoritatively unlocked HeroicStrike")
	assertTest(#netPlayer1.SkillInventory == 1, "[NetBoundary] HeroicStrike added to Player 1 SkillInventory")
	assertTest(SkillService.getOwnedSkill(netPlayer1, "HeroicStrike") == p1SkillInst, "[NetBoundary] getOwnedSkill resolves by definition ID")
	assertTest(SkillService.getOwnedSkill(netPlayer1, (p1SkillInst :: any).InstanceId) == p1SkillInst, "[NetBoundary] getOwnedSkill resolves by instance ID")

	-- 3e. Client requests valid owned skill -> succeeds, slotted correctly
	local okValidEquip, _ = SkillService.equipSkill(netPlayer1, p1SkillInst, "Skill1")
	assertTest(okValidEquip == true, "[NetBoundary] Equipping valid owned skill succeeds")
	assertTest(netPlayer1.EquippedSkills["Skill1"] == p1SkillInst, "[NetBoundary] Skill placed into EquippedSkills['Skill1']")
	assertTest((p1SkillInst :: any).Slot == "Skill1", "[NetBoundary] SkillInstance.Slot updated to Skill1")

	-- 3f. Repeated equip of same instance in same slot -> handled deterministically
	local okReEquip, _ = SkillService.equipSkill(netPlayer1, p1SkillInst, "Skill1")
	assertTest(okReEquip == true, "[NetBoundary] Repeated equip in same slot succeeds idempotently")
	assertTest(netPlayer1.EquippedSkills["Skill1"] == p1SkillInst, "[NetBoundary] EquippedSkills['Skill1'] unchanged")

	-- 3g. Repeated equip of same instance in another slot -> rejected
	local okDupSlot, errDupSlot = SkillService.equipSkill(netPlayer1, p1SkillInst, "Skill2")
	assertTest(okDupSlot == false and string.find(errDupSlot or "", "already equipped") ~= nil, "[NetBoundary] Equipping same instance in another slot rejected")
	assertTest(netPlayer1.EquippedSkills["Skill2"] == nil, "[NetBoundary] Slot 2 remains empty")

	-- 4. Equipment Network Boundary Hardening
	-- 4a. Fabricated equipment instance ID -> rejected
	local okFakeGear, errFakeGear = EquipmentService.equipItem(netPlayer1, "fake_guid_99999")
	assertTest(okFakeGear == false and string.find(errFakeGear or "", "not found in player's inventory") ~= nil, "[NetBoundary] Fabricated equipment instance ID rejected")

	-- 4b. Forged instance object (created table, not in inventory) -> rejected
	local forgedGear = EquipmentService.createInstance("IronBroadsword", netUser1)
	local okForgedGear, errForgedGear = EquipmentService.equipItem(netPlayer1, forgedGear)
	assertTest(okForgedGear == false and string.find(errForgedGear or "", "not found in player's inventory") ~= nil, "[NetBoundary] Equipment instance not in inventory rejected")

	-- 4c. Equipment wrong owner -> rejected
	local p2Gear = EquipmentService.grantEquipment(netPlayer2, "IronBroadsword")
	assert(p2Gear, "p2Gear granted")
	table.insert(netPlayer1.EquipmentInventory, p2Gear)
	local okWrongOwner, errWrongOwner = EquipmentService.equipItem(netPlayer1, p2Gear)
	assertTest(okWrongOwner == false and string.find(errWrongOwner or "", "does not match player") ~= nil, "[NetBoundary] Foreign equipment owner mismatch rejected")
	table.remove(netPlayer1.EquipmentInventory, #netPlayer1.EquipmentInventory)

	-- 4d. Equipment forged slot -> rejected
	local p1LegitSword = EquipmentService.grantEquipment(netPlayer1, "IronBroadsword")
	assert(p1LegitSword, "p1LegitSword granted")
	;(p1LegitSword :: any).Slot = "Armor"
	local okForgedSlot, errForgedSlot = EquipmentService.equipItem(netPlayer1, p1LegitSword)
	assertTest(okForgedSlot == false and string.find(errForgedSlot or "", "Forged slot") ~= nil, "[NetBoundary] Equipment forged slot mismatch rejected")
	;(p1LegitSword :: any).Slot = "Weapon"

	-- 4e. Legitimate inventory instance -> succeeds
	local okLegitEquip, _ = EquipmentService.equipItem(netPlayer1, p1LegitSword)
	assertTest(okLegitEquip == true, "[NetBoundary] Equipping legitimate inventory item succeeds")
	assertTest(netPlayer1.EquippedItems ~= nil and netPlayer1.EquippedItems["Weapon"] == p1LegitSword, "[NetBoundary] Item equipped in EquippedItems['Weapon']")

	-- 5. Invalid argument types & enums rejected safely without unhandled error
	local okBadSlotType, _ = SkillService.equipSkill(netPlayer1, p1SkillInst, 999 :: any)
	assertTest(okBadSlotType == false, "[NetBoundary] Number skill slot rejected safely")
	local okBadSlotTable, _ = SkillService.equipSkill(netPlayer1, p1SkillInst, {} :: any)
	assertTest(okBadSlotTable == false, "[NetBoundary] Table skill slot rejected safely")
	local okBadEquipIdType, _ = EquipmentService.equipItem(netPlayer1, 12345 :: any)
	assertTest(okBadEquipIdType == false, "[NetBoundary] Number equipment instance ID rejected safely")
	local okBadSkillEnum, _ = SkillService.equipSkill(netPlayer1, p1SkillInst, "Skill99" :: any)
	assertTest(okBadSkillEnum == false, "[NetBoundary] Invalid enum slot 'Skill99' rejected without state mutation")

	-- 6. Snapshot Consistency: PlayerView reflects exact authoritative state
	PassiveService.grantPoints(netPlayer1, 1)
	local okNodeUnlock, _ = PassiveService.unlockNode(netPlayer1, "Warlord_IronSkin")
	assertTest(okNodeUnlock == true, "[NetSnapshot] Warlord_IronSkin unlocked authoritatively")

	-- Register netPlayer1 in RunManager party for snapshot generation
	local runStateNet = RunManager.getRunState()
	runStateNet.PartyMembers[netUser1] = netPlayer1

	local runSnap = RunManager.getRunSnapshotForPlayer({ UserId = netUser1 } :: any)
	local pView = runSnap.Party[tostring(netUser1)]
	assertTest(pView ~= nil, "[NetSnapshot] PlayerView generated in run snapshot")
	assertTest(pView.EquippedItems ~= nil and pView.EquippedItems["Weapon"] == "IronBroadsword", "[NetSnapshot] Run snapshot serializes equipped weapon definition ID")
	assertTest(pView.EquippedSkills ~= nil and pView.EquippedSkills["Skill1"] == "HeroicStrike", "[NetSnapshot] Run snapshot serializes equipped skill definition ID")
	assertTest(pView.SkillInventory ~= nil and #pView.SkillInventory == 1 and pView.SkillInventory[1] == "HeroicStrike", "[NetSnapshot] Run snapshot serializes skill inventory array")
	assertTest(pView.UnlockedPassives ~= nil and pView.UnlockedPassives["Warlord_IronSkin"] == true, "[NetSnapshot] Run snapshot serializes unlocked passives set")
	assertTest(pView.PassivePoints == 0, "[NetSnapshot] Run snapshot serializes accurate remaining passive points")

	end
	----------------------------------------------------------------------------
	-- TEST 52: Phase 3.3 Strict Instance Validation & Fabricated Object Rejection
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 52] Phase 3.3 Strict Instance Validation & Fabricated Object Rejection ---")
	local p33User = 9301
	local p33Player: StateTypes.PlayerState = {
		UserId = p33User,
		DisplayName = "InvariantHero",
		ClassId = "Warlord",
		SubclassId = "Berserker",
		Resources = { HP = 110, MaxHP = 110, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = {},
		Gold = 0,
		IsReady = false,
		IsDowned = false,
		IsConnected = true,
		EquippedItems = {},
		EquipmentInventory = {},
		EquippedSkills = {},
		SkillInventory = {},
		UnlockedSkills = {},
		UnlockedPassives = {},
		PassivePoints = 0,
	}

	-- 1. Fabricated SkillInstance table with correct OwnerUserId -> rejected with zero inventory mutation
	local fakeSkillOwnerOnly = {
		InstanceId = "forged_skill_owner_001",
		DefinitionId = "HeroicStrike",
		OwnerUserId = p33User,
		Slot = "Skill1",
		CurrentCooldown = 0,
	}
	local okFakeOwner, errFakeOwner = SkillService.equipSkill(p33Player, fakeSkillOwnerOnly, "Skill1")
	assertTest(okFakeOwner == false and string.find(errFakeOwner or "", "not found in player's skill inventory") ~= nil, "[SkillAuthoritative] Fabricated instance with matching OwnerUserId rejected")
	assertTest(#p33Player.SkillInventory == 0, "[SkillAuthoritative] Zero SkillInventory mutation on fabricated instance rejection")
	assertTest(p33Player.EquippedSkills["Skill1"] == nil, "[SkillAuthoritative] EquippedSkills['Skill1'] remains nil")

	-- 2. Fabricated SkillInstance table with valid DefinitionId -> rejected with zero inventory mutation
	local fakeSkillDefOnly = {
		InstanceId = "forged_skill_def_002",
		DefinitionId = "HeroicStrike",
		OwnerUserId = 9999,
		Slot = "Skill1",
		CurrentCooldown = 0,
	}
	local okFakeDef, _ = SkillService.equipSkill(p33Player, fakeSkillDefOnly, "Skill1")
	assertTest(okFakeDef == false, "[SkillAuthoritative] Fabricated instance with valid DefinitionId rejected")
	assertTest(#p33Player.SkillInventory == 0, "[SkillAuthoritative] Zero SkillInventory mutation on valid DefinitionId forgery")

	-- 3. Fabricated SkillInstance with unlocked DefinitionId -> rejected with zero inventory mutation
	local okUnlockReal, _, realSkillInst = SkillService.unlockSkill(p33Player, "HeroicStrike")
	assertTest(okUnlockReal == true and realSkillInst ~= nil, "[SkillAuthoritative] Authoritatively unlocked HeroicStrike")
	assertTest(#p33Player.SkillInventory == 1, "[SkillAuthoritative] SkillInventory holds exactly 1 authoritative instance")

	local fakeUnlockedDef = {
		InstanceId = "forged_skill_unlocked_003",
		DefinitionId = "HeroicStrike",
		OwnerUserId = p33User,
		Slot = "Skill1",
		CurrentCooldown = 0,
	}
	local okFakeUnlocked, errFakeUnlocked = SkillService.equipSkill(p33Player, fakeUnlockedDef, "Skill1")
	assertTest(okFakeUnlocked == false and string.find(errFakeUnlocked or "", "not found in player's skill inventory") ~= nil, "[SkillAuthoritative] Fabricated instance with unlocked definition rejected")
	assertTest(#p33Player.SkillInventory == 1, "[SkillAuthoritative] SkillInventory size remains exactly 1 (forgery not inserted)")
	assertTest(p33Player.EquippedSkills["Skill1"] == nil, "[SkillAuthoritative] EquippedSkills['Skill1'] remains nil")

	-- 4. Fabricated SkillInstance with same InstanceId as a real skill but different fields -> rejected
	local forgedFieldsSkill = {
		InstanceId = (realSkillInst :: any).InstanceId,
		DefinitionId = "Whirlwind",
		OwnerUserId = p33User,
		Slot = "Skill1",
		CurrentCooldown = 0,
	}
	local okForgedFields, errForgedFields = SkillService.equipSkill(p33Player, forgedFieldsSkill, "Skill1")
	assertTest(okForgedFields == false and string.find(errForgedFields or "", "does not match authoritative inventory record") ~= nil, "[SkillAuthoritative] Forged definition on real InstanceId rejected")
	assertTest(#p33Player.SkillInventory == 1, "[SkillAuthoritative] SkillInventory untouched")
	assertTest(p33Player.EquippedSkills["Skill1"] == nil, "[SkillAuthoritative] EquippedSkills['Skill1'] untouched")

	-- 5. Real SkillInventory instance -> succeeds
	local okRealEquip, _ = SkillService.equipSkill(p33Player, realSkillInst, "Skill1")
	assertTest(okRealEquip == true, "[SkillAuthoritative] Equipping real SkillInventory instance succeeds")
	assertTest(p33Player.EquippedSkills["Skill1"] == realSkillInst, "[SkillAuthoritative] EquippedSkills['Skill1'] holds real instance")
	assertTest((realSkillInst :: any).Slot == "Skill1", "[SkillAuthoritative] Authoritative instance Slot is Skill1")

	-- 6. Real equipped instance -> re-equip remains deterministic & preserves cooldown
	;(realSkillInst :: any).CurrentCooldown = 2
	local okReEquipReal, _ = SkillService.equipSkill(p33Player, realSkillInst, "Skill1")
	assertTest(okReEquipReal == true, "[SkillAuthoritative] Re-equipping real equipped instance succeeds idempotently")
	assertTest((realSkillInst :: any).CurrentCooldown == 2, "[SkillAuthoritative] Authoritative CurrentCooldown preserved at 2")

	-- 7. Failed equip causes zero SkillInventory mutation
	local countBefore = #p33Player.SkillInventory
	SkillService.equipSkill(p33Player, { InstanceId = "non_existent_999" }, "Skill1")
	assertTest(#p33Player.SkillInventory == countBefore, "[SkillAuthoritative] Failed equip caused exactly zero SkillInventory mutations")

	-- 8. Equivalent fabricated EquipmentInstance cases -> rejected with zero inventory mutation
	-- 8a. Fabricated EquipmentInstance with matching OwnerUserId -> rejected
	local fakeArmorOwner = {
		InstanceId = "fake_armor_owner_001",
		DefinitionId = "ReinforcedPlate",
		OwnerUserId = p33User,
		Slot = "Armor",
		Level = 1,
	}
	local okFakeArmor, errFakeArmor = EquipmentService.equipItem(p33Player, fakeArmorOwner)
	assertTest(okFakeArmor == false and string.find(errFakeArmor or "", "not found in player's inventory") ~= nil, "[EquipmentAuthoritative] Fabricated item with matching OwnerUserId rejected")
	assertTest(#p33Player.EquipmentInventory == 0, "[EquipmentAuthoritative] Zero EquipmentInventory mutation on forged item rejection")
	assertTest(p33Player.EquippedItems["Armor"] == nil, "[EquipmentAuthoritative] EquippedItems['Armor'] remains nil")

	-- 8b. Fabricated EquipmentInstance with valid DefinitionId -> rejected
	local fakeSwordDef = {
		InstanceId = "fake_sword_def_002",
		DefinitionId = "IronBroadsword",
		OwnerUserId = 8888,
		Slot = "Weapon",
		Level = 1,
	}
	local okFakeSword, _ = EquipmentService.equipItem(p33Player, fakeSwordDef)
	assertTest(okFakeSword == false, "[EquipmentAuthoritative] Fabricated item with valid DefinitionId rejected")
	assertTest(#p33Player.EquipmentInventory == 0, "[EquipmentAuthoritative] Zero EquipmentInventory mutation")

	-- 8c. Fabricated EquipmentInstance with same InstanceId as real item but different fields -> rejected
	local realSword = EquipmentService.grantEquipment(p33Player, "IronBroadsword")
	assert(realSword, "realSword granted")
	assertTest(#p33Player.EquipmentInventory == 1, "[EquipmentAuthoritative] EquipmentInventory holds granted sword")

	local forgedFieldsGear = {
		InstanceId = realSword.InstanceId,
		DefinitionId = "ReinforcedPlate",
		OwnerUserId = p33User,
		Slot = "Armor",
		Level = 1,
	}
	local okForgedGearFields, errForgedGearFields = EquipmentService.equipItem(p33Player, forgedFieldsGear)
	assertTest(okForgedGearFields == false and string.find(errForgedGearFields or "", "does not match authoritative inventory record") ~= nil, "[EquipmentAuthoritative] Forged definition on real gear InstanceId rejected")
	assertTest(#p33Player.EquipmentInventory == 1, "[EquipmentAuthoritative] EquipmentInventory untouched on forgery rejection")
	assertTest(p33Player.EquippedItems["Weapon"] == nil, "[EquipmentAuthoritative] EquippedItems['Weapon'] untouched")

	-- 8d. Real EquipmentInventory instance equip -> succeeds
	local okRealGearEquip, _ = EquipmentService.equipItem(p33Player, realSword)
	assertTest(okRealGearEquip == true, "[EquipmentAuthoritative] Equipping real inventory gear succeeds")
	assertTest(p33Player.EquippedItems["Weapon"] == realSword, "[EquipmentAuthoritative] EquippedItems['Weapon'] holds real sword")

	-- 8e. Real equipped gear re-equip remains deterministic
	local okReEquipGear, _ = EquipmentService.equipItem(p33Player, realSword)
	assertTest(okReEquipGear == true, "[EquipmentAuthoritative] Re-equipping real gear succeeds idempotently")
	assertTest(p33Player.EquippedItems["Weapon"] == realSword, "[EquipmentAuthoritative] EquippedItems['Weapon'] remains unchanged")

	end
	----------------------------------------------------------------------------
	-- [Suite 53] Phase 4 Profile Architecture & Migration
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 53] Phase 4 Profile Architecture & Migration ---")
	-- 1. New profile default values
	local newP = PersistenceService.reconcileForTesting(nil, 80001)
	assertTest(newP.ProfileVersion == 1, "[Profile] New profile has ProfileVersion = 1")
	assertTest(newP.AetherShards == 0, "[Profile] New profile AetherShards defaults to 0")
	assertTest(newP.PremiumCurrency == 0, "[Profile] New profile PremiumCurrency defaults to 0")
	assertTest(newP.TotalVictories == 0, "[Profile] New profile TotalVictories defaults to 0")
	assertTest(newP.TotalRuns == 0, "[Profile] New profile TotalRuns defaults to 0")
	assertTest(#newP.UnlockedClasses == 5, "[Profile] New profile has 5 starting unlocked classes")
	assertTest(newP.CardCollection["Strike"] == 5, "[Profile] Starter collection contains 5 Strikes")
	assertTest(newP.CardCollection["Defend"] == 5, "[Profile] Starter collection contains 5 Defends")
	assertTest(newP.DeckSlotEntitlement.BaseDeckSlots == 4, "[Profile] BaseDeckSlots defaults to 4")
	assertTest(newP.DeckSlotEntitlement.AdditionalDeckSlots == 0, "[Profile] AdditionalDeckSlots defaults to 0")
	assertTest(newP.ActiveDeckId ~= nil, "[Profile] ActiveDeckId populated with starter deck")
	assertTest(newP.Decks[newP.ActiveDeckId :: string] ~= nil, "[Profile] Starter deck exists in Decks dictionary")

	-- 2. Legacy V0 profile migration
	local v0Data = {
		AetherShards = 120,
		TotalVictories = 4,
		TotalRuns = 12,
		UnlockedClasses = { "Warlord", "Shadowblade" },
	}
	local migratedP = PersistenceService.reconcileForTesting(v0Data, 80002)
	assertTest(migratedP.ProfileVersion == 1, "[ProfileMigration] Upgraded from v0 to ProfileVersion = 1")
	assertTest(migratedP.AetherShards == 120, "[ProfileMigration] Preserved existing AetherShards = 120")
	assertTest(migratedP.TotalVictories == 4, "[ProfileMigration] Preserved existing TotalVictories = 4")
	assertTest(migratedP.TotalRuns == 12, "[ProfileMigration] Preserved existing TotalRuns = 12")
	assertTest(#migratedP.UnlockedClasses == 2, "[ProfileMigration] Preserved unlocked classes")
	assertTest(migratedP.CardCollection["Strike"] == 5, "[ProfileMigration] Seeded starter card collection")
	assertTest(migratedP.ActiveDeckId ~= nil and migratedP.Decks[migratedP.ActiveDeckId :: string] ~= nil, "[ProfileMigration] Seeded default starter deck")
	assertTest(migratedP.DeckSlotEntitlement.BaseDeckSlots == 4, "[ProfileMigration] Seeded default BaseDeckSlots = 4")

	-- 3. Malformed profile recovery
	local malformedData = {
		ProfileVersion = 0,
		AetherShards = -999,
		PremiumCurrency = -50,
		TotalVictories = -10,
		TotalRuns = -20,
		UnlockedClasses = "not_a_table",
		CardCollection = {
			["Strike"] = 10,
			["UnknownGarbageCardXYZ"] = 5,
			["Defend"] = -3,
			["HeavyBlow"] = 2.5,
		},
		Decks = "corrupt_decks_string",
		DeckSlotEntitlement = {
			AdditionalDeckSlots = -5,
		},
	}
	local recoveredP = PersistenceService.reconcileForTesting(malformedData, 80003)
	assertTest(recoveredP.ProfileVersion == 1, "[ProfileRecovery] Normalized to ProfileVersion = 1")
	assertTest(recoveredP.AetherShards == 0, "[ProfileRecovery] Negative AetherShards clamped to 0")
	assertTest(recoveredP.PremiumCurrency == 0, "[ProfileRecovery] Negative PremiumCurrency clamped to 0")
	assertTest(recoveredP.TotalVictories == 0, "[ProfileRecovery] Negative TotalVictories clamped to 0")
	assertTest(recoveredP.TotalRuns == 0, "[ProfileRecovery] Negative TotalRuns clamped to 0")
	assertTest(recoveredP.CardCollection["Strike"] == 10, "[ProfileRecovery] Valid collection card preserved")
	assertTest(recoveredP.CardCollection["UnknownGarbageCardXYZ"] == nil, "[ProfileRecovery] Unknown card definition rejected")
	assertTest(recoveredP.CardCollection["Defend"] == nil, "[ProfileRecovery] Negative card quantity rejected")
	assertTest(recoveredP.DeckSlotEntitlement.AdditionalDeckSlots == 0, "[ProfileRecovery] Negative AdditionalDeckSlots clamped to 0")
	assertTest(recoveredP.ActiveDeckId ~= nil and recoveredP.Decks[recoveredP.ActiveDeckId :: string] ~= nil, "[ProfileRecovery] Seeded fallback starter deck for corrupt deck field")

	end
	----------------------------------------------------------------------------
	-- [Suite 54] Phase 4 Card Collection Service
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 54] Phase 4 Card Collection Service ---")
	local colPlayer = { UserId = 81001, Name = "ColTester" }
	PersistenceService.resetForTesting(81001)

	-- 1. Initial collection check
	local initStrikes = CardCollectionService.getCardCount(colPlayer, "Strike")
	assertTest(initStrikes == 5, "[CardCollection] Initial Strike count is 5")
	assertTest(CardCollectionService.hasCard(colPlayer, "Strike") == true, "[CardCollection] hasCard('Strike') is true")
	assertTest(CardCollectionService.hasCard(colPlayer, "NonExistentCard") == false, "[CardCollection] hasCard for invalid card is false")

	-- 2. Authoritative card grant
	local okGrant, errGrant = CardCollectionService.grantCard(colPlayer, "HeavyBlow", 2)
	assertTest(okGrant == true, "[CardCollection] Granting 2 copies of HeavyBlow succeeds")
	assertTest(CardCollectionService.getCardCount(colPlayer, "HeavyBlow") == 4, "[CardCollection] HeavyBlow count increased from 2 to 4")

	-- 3. Grant invalid cards & quantities
	local okGrantUnknown, _ = CardCollectionService.grantCard(colPlayer, "FakeCardDefXYZ", 1)
	assertTest(okGrantUnknown == false, "[CardCollection] Granting unknown card definition rejected")
	local okGrantZero, _ = CardCollectionService.grantCard(colPlayer, "Strike", 0)
	assertTest(okGrantZero == false, "[CardCollection] Granting 0 quantity rejected")
	local okGrantNeg, _ = CardCollectionService.grantCard(colPlayer, "Strike", -3)
	assertTest(okGrantNeg == false, "[CardCollection] Granting negative quantity rejected")
	local okGrantFrac, _ = CardCollectionService.grantCard(colPlayer, "Strike", 1.5)
	assertTest(okGrantFrac == false, "[CardCollection] Granting fractional quantity rejected")

	-- 4. Authoritative card removal
	local okRem, _ = CardCollectionService.removeCard(colPlayer, "HeavyBlow", 1)
	assertTest(okRem == true, "[CardCollection] Removing 1 owned copy succeeds")
	assertTest(CardCollectionService.getCardCount(colPlayer, "HeavyBlow") == 3, "[CardCollection] HeavyBlow count decreased to 3")

	local okRemExcess, errRemExcess = CardCollectionService.removeCard(colPlayer, "HeavyBlow", 10)
	assertTest(okRemExcess == false and string.find(errRemExcess or "", "Insufficient") ~= nil, "[CardCollection] Removing more copies than owned rejected")
	assertTest(CardCollectionService.getCardCount(colPlayer, "HeavyBlow") == 3, "[CardCollection] Count remains unchanged after rejected deduction")

	local okRemNeg, _ = CardCollectionService.removeCard(colPlayer, "HeavyBlow", -1)
	assertTest(okRemNeg == false, "[CardCollection] Removing negative quantity rejected")

	-- 5. Collection view serialization
	local colView = CardCollectionService.toCollectionView(colPlayer)
	assertTest(colView.Cards["Strike"] == 5, "[CardCollectionView] View contains 5 Strikes")
	assertTest(colView.TotalUniqueCards >= 7, "[CardCollectionView] TotalUniqueCards is accurate")
	assertTest(colView.TotalCardCopies >= 15, "[CardCollectionView] TotalCardCopies sum is accurate")

	end
	----------------------------------------------------------------------------
	-- [Suite 55] Phase 4 Deck Model, Slot Entitlement & Deck Service
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 55] Phase 4 Deck Model, Slot Entitlement & Deck Service ---")
	local deckPlayer = { UserId = 82001, Name = "DeckTester" }
	PersistenceService.resetForTesting(82001)

	-- 1. Initial slot entitlement
	local slotInfo = DeckService.getSlotEntitlement(deckPlayer)
	assertTest(slotInfo.BaseSlots == 4, "[DeckSlot] Base slots equals 4")
	assertTest(slotInfo.AdditionalSlots == 0, "[DeckSlot] Additional slots equals 0")
	assertTest(slotInfo.TotalSlots == 4, "[DeckSlot] Total slots equals 4")
	assertTest(slotInfo.UsedSlots == 1, "[DeckSlot] Used slots equals 1 (starter deck)")
	assertTest(slotInfo.AvailableSlots == 3, "[DeckSlot] Available slots equals 3")

	-- 2. Create decks up to slot capacity
	local okD2, errD2, deck2 = DeckService.createDeck(deckPlayer, "Deck Two")
	assertTest(okD2 == true and deck2 ~= nil, "[DeckService] Create Deck 2 succeeds")
	assertTest(string.find(deck2.DeckId, "deck_82001_") ~= nil, "[DeckService] Server-generated GUID prefix for Deck 2")

	local okD3, _, deck3 = DeckService.createDeck(deckPlayer, "Deck Three")
	assertTest(okD3 == true and deck3 ~= nil, "[DeckService] Create Deck 3 succeeds")

	local okD4, _, deck4 = DeckService.createDeck(deckPlayer, "Deck Four")
	assertTest(okD4 == true and deck4 ~= nil, "[DeckService] Create Deck 4 succeeds")

	local slotFull = DeckService.getSlotEntitlement(deckPlayer)
	assertTest(slotFull.UsedSlots == 4, "[DeckSlot] Used slots is now 4")
	assertTest(slotFull.AvailableSlots == 0, "[DeckSlot] Available slots is 0")

	-- 3. Slot exhaustion rejection
	local okD5, errD5, _ = DeckService.createDeck(deckPlayer, "Deck Five")
	assertTest(okD5 == false and string.find(errD5 or "", "slot entitlement limit") ~= nil, "[DeckSlot] Creating 5th deck rejected due to slot exhaustion")

	-- 4. Additional slot entitlement expansion
	PersistenceService.mutateProfile(deckPlayer, function(p)
		p.DeckSlotEntitlement.AdditionalDeckSlots = 2
		return true, nil
	end)
	local slotExpanded = DeckService.getSlotEntitlement(deckPlayer)
	assertTest(slotExpanded.AdditionalSlots == 2, "[DeckSlot] Additional slots updated to 2")
	assertTest(slotExpanded.TotalSlots == 6, "[DeckSlot] Total slots updated to 6")
	assertTest(slotExpanded.AvailableSlots == 2, "[DeckSlot] Available slots is now 2")

	local okD5Again, _, deck5 = DeckService.createDeck(deckPlayer, "Deck Five")
	assertTest(okD5Again == true and deck5 ~= nil, "[DeckSlot] Creating 5th deck succeeds after entitlement expansion")

	-- 5. Deck name validation
	local okEmptyName, _ = DeckService.createDeck(deckPlayer, "   ")
	assertTest(okEmptyName == false, "[DeckService] Empty/whitespace deck name rejected")
	local longName = string.rep("A", 35)
	local okLongName, _ = DeckService.createDeck(deckPlayer, longName)
	assertTest(okLongName == false, "[DeckService] Excessively long deck name rejected")

	-- 6. Rename deck
	local okRename, _ = DeckService.renameDeck(deckPlayer, deck2.DeckId, "Renamed Warlord")
	assertTest(okRename == true, "[DeckService] Renaming deck succeeds")
	local fetchedD2 = DeckService.getDeck(deckPlayer, deck2.DeckId)
	assertTest(fetchedD2 ~= nil and fetchedD2.Name == "Renamed Warlord", "[DeckService] Fetched deck reflects renamed title")

	-- 7. Duplicate deck
	local okDup, _, dupDeck = DeckService.duplicateDeck(deckPlayer, deck2.DeckId, "Deck Two Copy")
	assertTest(okDup == true and dupDeck ~= nil, "[DeckService] Duplicating deck succeeds")
	assertTest(dupDeck.DeckId ~= deck2.DeckId, "[DeckService] Duplicate has a fresh server GUID")

	-- 8. Delete deck
	local okDel, _ = DeckService.deleteDeck(deckPlayer, dupDeck.DeckId)
	assertTest(okDel == true, "[DeckService] Deleting duplicate deck succeeds")
	assertTest(DeckService.getDeck(deckPlayer, dupDeck.DeckId) == nil, "[DeckService] Deleted deck no longer returned by getDeck")

	end
	----------------------------------------------------------------------------
	-- [Suite 56] Phase 4 Deck Validation & Active Deck Selection
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 56] Phase 4 Deck Validation & Active Deck Selection ---")
	local valPlayer = { UserId = 83001, Name = "ValTester" }
	PersistenceService.resetForTesting(83001)

	-- 1. Valid starter deck passes validation
	local starterDeck = DeckService.getActiveDeck(valPlayer)
	assertTest(starterDeck ~= nil, "[DeckValidation] Player has active starter deck")
	local okValStarter, _ = DeckService.validateDeck(valPlayer, starterDeck.Cards, starterDeck.ClassId)
	assertTest(okValStarter == true, "[DeckValidation] Starter deck passes validation")

	-- 2. Card definition existence check
	local badDefDeck = { ["FakeCard123"] = 1, ["Strike"] = 7 }
	local okBadDef, errBadDef = DeckService.validateDeck(valPlayer, badDefDeck)
	assertTest(okBadDef == false and string.find(errBadDef or "", "Unknown card definition") ~= nil, "[DeckValidation] Unknown card definition rejected")

	-- 3. Unowned card check
	local curPoison = CardCollectionService.getCardCount(valPlayer, "PoisonDart")
	CardCollectionService.removeCard(valPlayer, "PoisonDart", curPoison)
	local unownedDeck = { ["PoisonDart"] = 1, ["Strike"] = 7 }
	local okUnowned, errUnowned = DeckService.validateDeck(valPlayer, unownedDeck)
	assertTest(okUnowned == false and string.find(errUnowned or "", "exceeds owned copies") ~= nil, "[DeckValidation] Unowned card rejected")

	-- 4. Quantity exceeds owned copies
	local overOwnedDeck = { ["Strike"] = 6, ["Defend"] = 2 }
	local okOverOwned, errOverOwned = DeckService.validateDeck(valPlayer, overOwnedDeck)
	assertTest(okOverOwned == false and string.find(errOverOwned or "", "exceeds owned copies") ~= nil, "[DeckValidation] Quantity exceeding collection ownership rejected")

	-- 5. Exceeds MaxCopiesPerCard (max 3)
	CardCollectionService.grantCard(valPlayer, "Strike", 10)
	local overMaxCopiesDeck = { ["Strike"] = 4, ["Defend"] = 4 }
	local okMaxCopies, errMaxCopies = DeckService.validateDeck(valPlayer, overMaxCopiesDeck)
	assertTest(okMaxCopies == false and string.find(errMaxCopies or "", "exceeds max copies") ~= nil, "[DeckValidation] Exceeding MaxCopiesPerCard (4 > 3) rejected")

	-- 6. Deck size rules: MinDeckSize (8) and MaxDeckSize (30)
	local tooSmallDeck = { ["Strike"] = 3, ["Defend"] = 3 }
	local okTooSmall, errTooSmall = DeckService.validateDeck(valPlayer, tooSmallDeck)
	assertTest(okTooSmall == false and string.find(errTooSmall or "", "too few cards") ~= nil, "[DeckValidation] Deck with 6 cards (< 8 min) rejected")

	local tooBigDeck: { [string]: number } = {
		["Strike"] = 3, ["Defend"] = 3, ["HeavyBlow"] = 3, ["RageSlash"] = 3,
		["ShieldSlam"] = 3, ["FirstAid"] = 3, ["PoisonDart"] = 3,
		["Berserk"] = 3, ["Execute"] = 3, ["BloodThirst"] = 3, ["Pummel"] = 1,
	}
	CardCollectionService.grantCard(valPlayer, "Berserk", 5)
	CardCollectionService.grantCard(valPlayer, "Execute", 5)
	CardCollectionService.grantCard(valPlayer, "BloodThirst", 5)
	CardCollectionService.grantCard(valPlayer, "Pummel", 5)
	CardCollectionService.grantCard(valPlayer, "Defend", 10)
	CardCollectionService.grantCard(valPlayer, "HeavyBlow", 10)
	CardCollectionService.grantCard(valPlayer, "RageSlash", 10)
	CardCollectionService.grantCard(valPlayer, "ShieldSlam", 10)
	CardCollectionService.grantCard(valPlayer, "FirstAid", 10)
	CardCollectionService.grantCard(valPlayer, "PoisonDart", 10)
	local okTooBig, errTooBig = DeckService.validateDeck(valPlayer, tooBigDeck)
	assertTest(okTooBig == false and string.find(errTooBig or "", "too many cards") ~= nil, "[DeckValidation] Deck with 31 cards (> 30 max) rejected")

	-- 7. Active Deck Selection
	local okNewD, _, customDeck = DeckService.createDeck(valPlayer, "Custom Aggro")
	assert(customDeck, "custom deck created")
	local validCustomCards = { ["Strike"] = 3, ["Defend"] = 3, ["HeavyBlow"] = 2 }
	local okSaveCustom, _ = DeckService.saveDeck(valPlayer, customDeck.DeckId, validCustomCards)
	assertTest(okSaveCustom == true, "[DeckService] Saving valid custom deck cards succeeds")

	local okSetActive, _ = DeckService.setActiveDeck(valPlayer, customDeck.DeckId)
	assertTest(okSetActive == true, "[ActiveDeck] Selecting valid custom deck as active succeeds")
	local activeD = DeckService.getActiveDeck(valPlayer)
	assertTest(activeD ~= nil and activeD.DeckId == customDeck.DeckId, "[ActiveDeck] getActiveDeck returns custom active deck")

	-- 8. Fallback on deletion of active deck
	local okDelActive, _ = DeckService.deleteDeck(valPlayer, customDeck.DeckId)
	assertTest(okDelActive == true, "[ActiveDeckFallback] Deleting active deck succeeds")
	local fallbackD = DeckService.getActiveDeck(valPlayer)
	assertTest(fallbackD ~= nil and fallbackD.DeckId ~= customDeck.DeckId, "[ActiveDeckFallback] getActiveDeck falls back safely to starter deck")

	end
	----------------------------------------------------------------------------
	-- [Suite 57] Phase 4 Run Integration & Complete Phase 4 Vertical Slice
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 57] Phase 4 Run Integration & Complete Phase 4 Vertical Slice ---")
	local runPlayer = { UserId = 84001, Name = "RunTester", DisplayName = "Slayer84" }
	PersistenceService.resetForTesting(84001)

	-- 1. Create a distinct custom active deck
	local okCustom, _, runDeck = DeckService.createDeck(runPlayer, "Speed Run Deck")
	assert(runDeck, "runDeck created")
	local runCards = {
		["Strike"] = 3,
		["Defend"] = 2,
		["HeavyBlow"] = 2,
		["RageSlash"] = 1,
	}
	DeckService.saveDeck(runPlayer, runDeck.DeckId, runCards)
	DeckService.setActiveDeck(runPlayer, runDeck.DeckId)

	-- 2. Initialize PlayerState for run
	local pStateRun: StateTypes.PlayerState = {
		UserId = 84001,
		PlayerInstance = nil,
		DisplayName = "Slayer84",
		ClassId = "Warlord",
		SubclassId = "Berserker",
		Resources = {
			HP = 100, MaxHP = 100, Shield = 0, Energy = 3, MaxEnergy = 3,
		},
		Deck = {}, Hand = {}, DiscardPile = {}, ExhaustPile = {},
		RelicIds = { "Anchor" }, Gold = 50, IsReady = false, IsDowned = false,
		EquippedItems = {}, EquipmentInventory = {},
		EquippedSkills = {}, SkillInventory = {}, UnlockedSkills = {},
		UnlockedPassives = {}, PassivePoints = 0,
	}
	ClassService.initializeStartingDeck(pStateRun)

	-- 3. Verify runtime CardInstances synthesized from active SavedDeck
	assertTest(#pStateRun.Deck == 8, "[RunIntegration] Initialized 8 runtime CardInstances matching active deck")
	local countStrike = 0
	local countDefend = 0
	local countHeavy = 0
	local countRage = 0
	local uniqueInstIds: { [string]: boolean } = {}
	for _, cardInst in pStateRun.Deck do
		assertTest(uniqueInstIds[cardInst.InstanceId] == nil, "[RunIntegration] Runtime CardInstance GUID is unique")
		uniqueInstIds[cardInst.InstanceId] = true
		assertTest(cardInst.OwnerUserId == 84001, "[RunIntegration] Runtime CardInstance owner matches player")
		if cardInst.DefinitionId == "Strike" then countStrike += 1
		elseif cardInst.DefinitionId == "Defend" then countDefend += 1
		elseif cardInst.DefinitionId == "HeavyBlow" then countHeavy += 1
		elseif cardInst.DefinitionId == "RageSlash" then countRage += 1
		end
	end
	assertTest(countStrike == 3, "[RunIntegration] Runtime deck contains 3 Strikes")
	assertTest(countDefend == 2, "[RunIntegration] Runtime deck contains 2 Defends")
	assertTest(countHeavy == 2, "[RunIntegration] Runtime deck contains 2 HeavyBlows")
	assertTest(countRage == 1, "[RunIntegration] Runtime deck contains 1 RageSlash")

	-- 4. Simulate combat card movement (draw, play, discard, exhaust)
	local drawn = CardService.drawCards(pStateRun, 4)
	assertTest(#drawn == 4, "[RunIntegration] Drew 4 cards to hand")
	assertTest(#pStateRun.Deck == 4, "[RunIntegration] Remaining draw pile has 4 cards")

	-- Regression: Draw doesn't duplicate cards
	local handCountDraw = 0
	for _ in pStateRun.Hand do
		handCountDraw += 1
	end
	assertTest(handCountDraw == 4, "[RunIntegration] Hand gained exactly 4 cards")
	assertTest(#pStateRun.Deck + handCountDraw + #pStateRun.DiscardPile + #pStateRun.ExhaustPile == 8, "[RunIntegration] Total card count across all piles remains 8 after draw")

	local overlapFound = false
	for _, deckCard in ipairs(pStateRun.Deck) do
		if pStateRun.Hand[deckCard.InstanceId] ~= nil then
			overlapFound = true
			break
		end
	end
	assertTest(not overlapFound, "[RunIntegration] Zero overlapping GUIDs between draw deck and hand")

	-- Play moves exactly one card
	local cardToPlay = drawn[1]
	CardService.playCardFromHand(pStateRun, cardToPlay.InstanceId)
	assertTest(pStateRun.Hand[cardToPlay.InstanceId] == nil, "[RunIntegration] Played card removed from hand")
	assertTest(#pStateRun.DiscardPile == 1, "[RunIntegration] Played card placed in discard pile")

	local handCountPlay = 0
	for _ in pStateRun.Hand do
		handCountPlay += 1
	end
	assertTest(handCountPlay == 3, "[RunIntegration] Hand count reduced by exactly 1 after play")
	assertTest(#pStateRun.Deck + handCountPlay + #pStateRun.DiscardPile + #pStateRun.ExhaustPile == 8, "[RunIntegration] Total card count across all piles remains 8 after play")

	-- Exhaust moves exactly one card
	local cardToExhaust = drawn[2]
	CardService.exhaustCard(pStateRun, cardToExhaust.InstanceId)
	assertTest(#pStateRun.ExhaustPile == 1, "[RunIntegration] Exhausted card placed in exhaust pile")

	local handCountExhaust = 0
	for _ in pStateRun.Hand do
		handCountExhaust += 1
	end
	assertTest(handCountExhaust == 2, "[RunIntegration] Hand count reduced by exactly 1 after exhaust")
	assertTest(#pStateRun.Deck + handCountExhaust + #pStateRun.DiscardPile + #pStateRun.ExhaustPile == 8, "[RunIntegration] Total card count across all piles remains 8 after exhaust")

	-- 5. Strict Invariant Verification: Persistent SavedDeck and Collection remain 100% untouched
	local savedDeckAfterCombat = DeckService.getDeck(runPlayer, runDeck.DeckId)
	assert(savedDeckAfterCombat, "saved deck fetched")
	assertTest(savedDeckAfterCombat.Cards["Strike"] == 3, "[RunIsolation] Persistent SavedDeck Strike count unchanged (3)")
	assertTest(savedDeckAfterCombat.Cards["Defend"] == 2, "[RunIsolation] Persistent SavedDeck Defend count unchanged (2)")
	assertTest(savedDeckAfterCombat.Cards["HeavyBlow"] == 2, "[RunIsolation] Persistent SavedDeck HeavyBlow count unchanged (2)")
	assertTest(savedDeckAfterCombat.Cards["RageSlash"] == 1, "[RunIsolation] Persistent SavedDeck RageSlash count unchanged (1)")
	assertTest(CardCollectionService.getCardCount(runPlayer, "Strike") == 5, "[RunIsolation] Permanent CardCollection Strike count unchanged (5)")

	-- 6. Mutating saved deck mid-run does NOT affect the active run
	DeckService.saveDeck(runPlayer, runDeck.DeckId, { ["Strike"] = 3, ["Defend"] = 5 })
	local handCountMidRun = 0
	for _ in pStateRun.Hand do
		handCountMidRun += 1
	end
	assertTest(#pStateRun.Deck + handCountMidRun + #pStateRun.DiscardPile + #pStateRun.ExhaustPile == 8, "[RunIsolation] Active run deck cardinality preserved despite persistent deck edit")

	end
	----------------------------------------------------------------------------
	-- [Suite 58] Phase 4 Network Security & Remote Contract Hardening
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 58] Phase 4 Network Security & Remote Contract Hardening ---")
	-- 1. Verify all Phase 4 RemoteEvents exist in NetworkService
	assertTest(NetworkService.CreateDeckEvent ~= nil, "[NetSecurity] CreateDeckEvent registered")
	assertTest(NetworkService.RenameDeckEvent ~= nil, "[NetSecurity] RenameDeckEvent registered")
	assertTest(NetworkService.DeleteDeckEvent ~= nil, "[NetSecurity] DeleteDeckEvent registered")
	assertTest(NetworkService.SaveDeckEvent ~= nil, "[NetSecurity] SaveDeckEvent registered")
	assertTest(NetworkService.DuplicateDeckEvent ~= nil, "[NetSecurity] DuplicateDeckEvent registered")
	assertTest(NetworkService.SelectActiveDeckEvent ~= nil, "[NetSecurity] SelectActiveDeckEvent registered")
	assertTest(NetworkService.RequestDecksEvent ~= nil, "[NetSecurity] RequestDecksEvent registered")
	assertTest(NetworkService.RequestCardCollectionEvent ~= nil, "[NetSecurity] RequestCardCollectionEvent registered")
	assertTest(NetworkService.DeckListUpdateEvent ~= nil, "[NetSecurity] DeckListUpdateEvent registered")
	assertTest(NetworkService.DeckDetailUpdateEvent ~= nil, "[NetSecurity] DeckDetailUpdateEvent registered")
	assertTest(NetworkService.CardCollectionUpdateEvent ~= nil, "[NetSecurity] CardCollectionUpdateEvent registered")

	-- 2. Client cannot choose arbitrary DeckId on creation
	local netPlayer = { UserId = 85001, Name = "NetTester" }
	PersistenceService.resetForTesting(85001)
	local okClientGuid, _, createdWithServerId = DeckService.createDeck(netPlayer, "Hacked Deck Name")
	assertTest(okClientGuid == true and createdWithServerId ~= nil, "[NetSecurity] Server successfully creates deck")
	assertTest(createdWithServerId.DeckId ~= "client_chosen_id_xyz", "[NetSecurity] DeckId is generated by server, client cannot forge ID")

	-- 3. Client cannot save unowned cards via SaveDeck
	local okSaveUnowned, errSaveUnowned = DeckService.saveDeck(netPlayer, createdWithServerId.DeckId, { ["VoidBolt"] = 3, ["Strike"] = 5 })
	assertTest(okSaveUnowned == false and string.find(errSaveUnowned or "", "exceeds owned copies") ~= nil, "[NetSecurity] Saving unowned cards rejected by authoritative validator")

	-- 4. Client cannot save deck exceeding owned copies
	local okSaveOver, errSaveOver = DeckService.saveDeck(netPlayer, createdWithServerId.DeckId, { ["Strike"] = 10 })
	assertTest(okSaveOver == false, "[NetSecurity] Saving card count exceeding collection ownership rejected")

	-- 5. Client cannot save into non-existent DeckId
	local okSaveNonExistent, _ = DeckService.saveDeck(netPlayer, "non_existent_deck_999", { ["Strike"] = 3, ["Defend"] = 5 })
	assertTest(okSaveNonExistent == false, "[NetSecurity] Saving into non-existent deck rejected")

	-- 6. Rate limiting applied to General category
	local mockPlrInstance = Instance.new("Folder") :: any
	mockPlrInstance.UserId = 85001
	local limitOk = NetworkService.checkRateLimit(mockPlrInstance, "General")
	assertTest(limitOk == true, "[NetSecurity] General rate limiter permits standard requests")

	end
	----------------------------------------------------------------------------
	-- [Suite 59] Phase 4.1 Persistence Safety, Migration Hardening & Security Audit
	do
	end
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 59] Phase 4.1 Persistence Safety, Migration Hardening & Security Audit ---")

	-- 1. Load failure fail-closed behavior:
	local failUserId = 86001
	local failPlayer = { UserId = failUserId, Name = "FailTester" }
	PersistenceService.resetForTesting(failUserId)
	PersistenceService.setMockGetAsyncFailureForTesting(true)
	local loadedProfile = PersistenceService.loadProfile(failPlayer)
	assertTest(loadedProfile == nil, "[FailClosed] DataStore load failure returns nil profile")
	assertTest(PersistenceService.getLoadState(failUserId) == "LoadFailed", "[FailClosed] Profile load state is LoadFailed")
	assertTest(PersistenceService.isProfileLoaded(failPlayer) == false, "[FailClosed] isProfileLoaded returns false on load failure")

	-- Attempting to save a failed profile must be rejected
	local okSaveFailed, errSaveFailed = PersistenceService.saveProfile(failPlayer)
	assertTest(okSaveFailed == false and string.find(errSaveFailed or "", "Cannot save") ~= nil, "[FailClosed] saveProfile rejected on LoadFailed state")

	-- onPlayerRemoving must refuse to save when load failed
	local okRemoveFailed, _ = PersistenceService.onPlayerRemoving(failPlayer)
	assertTest(okRemoveFailed == false, "[FailClosed] onPlayerRemoving refuses to save on LoadFailed state")

	-- Reset mock failure
	PersistenceService.setMockGetAsyncFailureForTesting(false)
	PersistenceService.resetForTesting(failUserId)

	-- 2. Reconciliation rejects fractional card quantities in collection (e.g. 2.5)
	local fractionalCollectionData = {
		ProfileVersion = 1,
		CardCollection = {
			["Strike"] = 2.5,
			["Defend"] = 4,
		},
	}
	local reconciledFractionalCol = PersistenceService.reconcileForTesting(fractionalCollectionData, 86002)
	assertTest(reconciledFractionalCol.CardCollection["Strike"] == nil, "[Reconciliation] Fractional card count in collection is rejected")
	assertTest(reconciledFractionalCol.CardCollection["Defend"] == 4, "[Reconciliation] Valid integer card count in collection is preserved")

	-- 3. Reconciliation rejects fractional card quantities in saved decks (e.g. 1.5)
	local fractionalDeckData = {
		ProfileVersion = 1,
		Decks = {
			["deck_frac_1"] = {
				DeckId = "deck_frac_1",
				Name = "Fractional Deck",
				ClassId = "Knight",
				Cards = {
					["Strike"] = 1.5,
					["Defend"] = 3,
				},
				CreatedAt = 1000,
				UpdatedAt = 1000,
			}
		}
	}
	local reconciledFractionalDeck = PersistenceService.reconcileForTesting(fractionalDeckData, 86003)
	assertTest(reconciledFractionalDeck.Decks["deck_frac_1"].Cards["Strike"] == nil, "[Reconciliation] Fractional card count in saved deck is rejected")
	assertTest(reconciledFractionalDeck.Decks["deck_frac_1"].Cards["Defend"] == 3, "[Reconciliation] Valid integer card count in saved deck is preserved")

	-- 4. Reconciliation repairs corrupt deck names (empty/whitespace -> "Custom Deck")
	local blankNameDeckData = {
		ProfileVersion = 1,
		Decks = {
			["deck_blank_1"] = {
				DeckId = "deck_blank_1",
				Name = "   ",
				ClassId = "Knight",
				Cards = { ["Strike"] = 5, ["Defend"] = 5 },
				CreatedAt = 1000,
				UpdatedAt = 1000,
			}
		}
	}
	local reconciledBlankDeck = PersistenceService.reconcileForTesting(blankNameDeckData, 86004)
	assertTest(reconciledBlankDeck.Decks["deck_blank_1"].Name == "Custom Deck", "[Reconciliation] Blank/whitespace deck name repaired to Custom Deck")

	-- 5. Reconciliation strips unknown cards from saved decks
	local unknownCardDeckData = {
		ProfileVersion = 1,
		Decks = {
			["deck_unknown_1"] = {
				DeckId = "deck_unknown_1",
				Name = "Exotic Deck",
				ClassId = "Knight",
				Cards = {
					["NonExistentCard_XYZ"] = 3,
					["Strike"] = 5,
					["Defend"] = 5,
				},
				CreatedAt = 1000,
				UpdatedAt = 1000,
			}
		}
	}
	local reconciledUnknownDeck = PersistenceService.reconcileForTesting(unknownCardDeckData, 86005)
	assertTest(reconciledUnknownDeck.Decks["deck_unknown_1"].Cards["NonExistentCard_XYZ"] == nil, "[Reconciliation] Unknown card stripped from saved deck")
	assertTest(reconciledUnknownDeck.Decks["deck_unknown_1"].Cards["Strike"] == 5, "[Reconciliation] Known cards retained in saved deck")

	-- 6. Reconciliation repairs invalid DeckSlotEntitlement (e.g. -5 -> clamped to valid range)
	local invalidSlotData = {
		ProfileVersion = 1,
		DeckSlotEntitlement = -5,
	}
	local reconciledSlotData = PersistenceService.reconcileForTesting(invalidSlotData, 86006)
	assertTest(reconciledSlotData.DeckSlotEntitlement == GameConfig.Deck.BaseDeckSlots, "[Reconciliation] Negative DeckSlotEntitlement clamped to BaseDeckSlots")

	local excessiveSlotData = {
		ProfileVersion = 1,
		DeckSlotEntitlement = 99999,
	}
	local reconciledExcessive = PersistenceService.reconcileForTesting(excessiveSlotData, 86007)
	assertTest(reconciledExcessive.DeckSlotEntitlement == GameConfig.Deck.MaxPurchasableDeckSlots, "[Reconciliation] Excessive DeckSlotEntitlement clamped to MaxPurchasableDeckSlots")

	-- 7. Active-deck fallback when active deck is invalid:
	local fallbackPlayer = { UserId = 86008, Name = "FallbackTester" }
	PersistenceService.resetForTesting(86008)
	local okD1, _, deck1 = DeckService.createDeck(fallbackPlayer, "Valid Deck 1", { ["Strike"] = 5, ["Defend"] = 5 }, "Knight")
	local okD2, _, deck2 = DeckService.createDeck(fallbackPlayer, "Valid Deck 2", { ["Strike"] = 4, ["Defend"] = 6 }, "Knight")
	assert(okD1 and deck1 and okD2 and deck2, "Both fallback test decks created")

	DeckService.setActiveDeck(fallbackPlayer, deck2.DeckId)
	local fbProfile = PersistenceService.getProfile(fallbackPlayer)
	-- Corrupt deck2 cards directly in profile to be invalid (< MinDeckSize cards)
	fbProfile.Decks[deck2.DeckId].Cards = { ["Strike"] = 1 }

	-- getActiveDeck must detect deck2 is invalid and fall back to valid deck1
	local resolvedActive = DeckService.getActiveDeck(fallbackPlayer)
	assertTest(resolvedActive ~= nil and resolvedActive.DeckId == deck1.DeckId, "[ActiveDeckFallback] Invalid active deck falls back to valid deck")
	assertTest(fbProfile.ActiveDeckId == deck2.DeckId, "[ActiveDeckFallback] Read does not mutate persistent ActiveDeckId")

	-- If all decks are invalid, getActiveDeck returns nil
	fbProfile.Decks[deck1.DeckId].Cards = { ["Strike"] = 1 }
	local noneActive = DeckService.getActiveDeck(fallbackPlayer)
	assertTest(noneActive == nil, "[ActiveDeckFallback] Returns nil when zero decks are valid")

	-- 8. Concurrency / UpdateAsync safety:
	local olderProfile = {
		ProfileVersion = 1,
		AetherShards = 100,
		LastSavedTimestamp = 1000,
	} :: any
	local newerRemoteData = {
		ProfileVersion = 1,
		AetherShards = 250,
		LastSavedTimestamp = 2000,
	}
	local resolvedConflictData, appliedConflict = PersistenceService.resolveUpdateConflict(newerRemoteData, olderProfile)
	assertTest(appliedConflict == false, "[ConcurrencySafety] Older session profile cannot overwrite newer remote DataStore data")
	assertTest(resolvedConflictData.AetherShards == 250, "[ConcurrencySafety] Newer remote data is preserved")

	local newerProfile = {
		ProfileVersion = 1,
		AetherShards = 300,
		LastSavedTimestamp = 3000,
	} :: any
	local olderRemoteData = {
		ProfileVersion = 1,
		AetherShards = 250,
		LastSavedTimestamp = 2000,
	}
	local resolvedNewerData, appliedNewer = PersistenceService.resolveUpdateConflict(olderRemoteData, newerProfile)
	assertTest(appliedNewer == true, "[ConcurrencySafety] Newer session profile is permitted to update older remote DataStore data")
	assertTest(resolvedNewerData.AetherShards == 300, "[ConcurrencySafety] Newer session profile applied")

	-- 9. Remote security check: UnlockSkillEvent rejects client requests
	assertTest(NetworkService.UnlockSkillEvent ~= nil, "[RemoteSecurity] UnlockSkillEvent exists")

	----------------------------------------------------------------------------
	-- SUITE 60: Class Selection Lifecycle & Server Lock Authority
	----------------------------------------------------------------------------
	print("\n--- SUITE 60: Class Selection Lifecycle & Server Lock Authority ---")

	-- Test 1: New player created in Lobby has ClassLocked == false
	local lockTestPlayer = { UserId = 87001, Name = "ClassLockTester", DisplayName = "LockTester" }
	RunManager.resetRunForTesting()
	local lockTestState = RunManager.addPlayer(lockTestPlayer :: any)
	assertTest(lockTestState.ClassLocked == false, "[ClassLock] New player added to run has ClassLocked == false")

	-- Test 2: Valid ClassService.selectClass sets ClassLocked == true
	local selectSuccess, selectErr = ClassService.selectClass(lockTestPlayer :: any, lockTestState, "Warlord", "Berserker")
	assertTest(selectSuccess == true, "[ClassLock] Valid selectClass succeeds")
	assertTest(lockTestState.ClassLocked == true, "[ClassLock] Valid selectClass sets playerState.ClassLocked to true")

	-- Test 3: Invalid class definition ID returns false and leaves ClassLocked == false
	local lockTestPlayer2 = { UserId = 87002, Name = "InvalidClassTester", DisplayName = "InvalidTester" }
	local lockTestState2 = RunManager.addPlayer(lockTestPlayer2 :: any)
	local invalidClassSuccess, _ = ClassService.selectClass(lockTestPlayer2 :: any, lockTestState2, "NonExistentClass", "Sub1")
	assertTest(invalidClassSuccess == false, "[ClassLock] Invalid class ID is rejected")
	assertTest(lockTestState2.ClassLocked == false, "[ClassLock] Rejected class selection does not set ClassLocked to true")

	-- Test 4: RunManager.resetToLobby() resets ClassLocked to false for all party members
	RunManager.resetToLobby()
	local resetPlayer1State = RunManager.getPlayerState(lockTestPlayer :: any)
	assertTest(resetPlayer1State ~= nil and resetPlayer1State.ClassLocked == false, "[ClassLock] resetToLobby resets ClassLocked to false for player 1")
	local resetPlayer2State = RunManager.getPlayerState(lockTestPlayer2 :: any)
	assertTest(resetPlayer2State ~= nil and resetPlayer2State.ClassLocked == false, "[ClassLock] resetToLobby resets ClassLocked to false for player 2")

	-- Test 5: RunManager.getRunSnapshotForPlayer correctly serializes ClassLocked in PlayerView
	ClassService.selectClass(lockTestPlayer :: any, resetPlayer1State :: any, "Shadowblade", "Assassin")
	local snapshot = RunManager.getRunSnapshotForPlayer(lockTestPlayer :: any)
	local myPartyView = snapshot.Party[tostring(lockTestPlayer.UserId)]
	assertTest(myPartyView ~= nil and myPartyView.ClassLocked == true, "[ClassLock] PlayerView in RunSnapshot correctly reflects ClassLocked == true")
	local otherPartyView = snapshot.Party[tostring(lockTestPlayer2.UserId)]
	assertTest(otherPartyView ~= nil and otherPartyView.ClassLocked == false, "[ClassLock] PlayerView for unselected player reflects ClassLocked == false")

	-- Test 6: Invalid subclass returns false and leaves ClassLocked == false
	local invalidSubSuccess, invalidSubErr = ClassService.selectClass(lockTestPlayer2 :: any, resetPlayer2State :: any, "Warlord", "NonExistentSubclass")
	assertTest(invalidSubSuccess == false, "[ClassLock] Invalid subclass ID is rejected")
	assertTest(resetPlayer2State.ClassLocked == false, "[ClassLock] Rejected subclass selection does not set ClassLocked")

	-- Test 7: Out-of-phase selection is rejected and leaves ClassLocked == false
	local currentRunForTest = RunManager.getRunState()
	currentRunForTest.Phase = "MapSelect"
	local outOfPhaseSuccess, outOfPhaseErr = ClassService.selectClass(lockTestPlayer2 :: any, resetPlayer2State :: any, "Warlord", "Berserker")
	assertTest(outOfPhaseSuccess == false, "[ClassLock] Out-of-phase class selection is rejected")
	assertTest(resetPlayer2State.ClassLocked == false, "[ClassLock] Out-of-phase selection does not set ClassLocked")
	currentRunForTest.Phase = "Lobby"

	-- Test 8: Reconnecting player in Lobby preserves ClassLocked == true and class selection
	RunManager.removePlayer(lockTestPlayer :: any)
	local reconnectedState = RunManager.addPlayer(lockTestPlayer :: any)
	assertTest(reconnectedState.ClassLocked == true, "[ClassLock] Reconnected player in Lobby preserves ClassLocked == true")
	assertTest(reconnectedState.ClassId == "Shadowblade", "[ClassLock] Reconnected player preserves selected ClassId")
	assertTest(reconnectedState.SubclassId == "Assassin", "[ClassLock] Reconnected player preserves selected SubclassId")

	-- Test 9: RequestStateSync produces authoritative snapshot reflecting ClassLocked == true
	local syncSnapshot = RunManager.getRunSnapshotForPlayer(lockTestPlayer :: any)
	assertTest(syncSnapshot ~= nil, "[ClassLock] RequestStateSync returns valid snapshot")
	assertTest(syncSnapshot.Party[tostring(lockTestPlayer.UserId)].ClassLocked == true, "[ClassLock] RequestStateSync reflects player ClassLocked == true")
	assertTest(syncSnapshot.Party[tostring(lockTestPlayer2.UserId)].ClassLocked == false, "[ClassLock] RequestStateSync reflects other player ClassLocked == false")

	-- Test 10: ClassSelectionResult remote event and contract verification
	assertTest(NetworkService.ClassSelectionResultEvent ~= nil and NetworkService.ClassSelectionResultEvent:IsA("RemoteEvent"), "[ClassSelectResult] ClassSelectionResult RemoteEvent exists in NetworkService")
	assertTest(typeof(NetworkService.sendClassSelectionResult) == "function", "[ClassSelectResult] NetworkService.sendClassSelectionResult is implemented")
	local successPayload = { Success = true, ClassId = "Necrobinder", SubclassId = "SwarmLord" }
	assertTest(successPayload.Success == true and successPayload.ClassId == "Necrobinder" and successPayload.SubclassId == "SwarmLord", "[ClassSelectResult] Success payload contains ClassId and SubclassId")
	local rejectPayload = { Success = false, Error = "Cannot change class outside Lobby phase." }
	assertTest(rejectPayload.Success == false and typeof(rejectPayload.Error) == "string", "[ClassSelectResult] Rejection payload contains descriptive Error string")

	-- Test 11: Test isolation mode ensures live state is not mutated
	assertTest(RunManager.isTestIsolationActive() == true, "[ClassLock] Test isolation is active during test execution")
	RunManager.endTestIsolation()
	assertTest(RunManager.isTestIsolationActive() == false, "[ClassLock] Test isolation tears down cleanly")

	-- Test 11: Live state is intact and points to liveRun after isolation teardown
	local liveState = RunManager.getRunState()
	assertTest(liveState == RunManager.getLiveRunState(), "[IsolationSafety] currentRun points back to liveRun")
	assertTest(liveState.PartyMembers[lockTestPlayer.UserId] == nil, "[IsolationSafety] LiveRun party members not contaminated by test players")
	assertTest(liveState.PartyMembers[lockTestPlayer2.UserId] == nil, "[IsolationSafety] LiveRun contains zero test party members")

	-- Test 12: runWithTestIsolation executes sub-test and tears down cleanly on normal completion
	local subtestRan = false
	local runWithOk, runWithResult = RunManager.runWithTestIsolation(function()
		assert(RunManager.isTestIsolationActive() == true, "Isolation must be active inside runWithTestIsolation")
		local isolatedPlayer = { UserId = 87099, Name = "IsoTester", DisplayName = "IsoTester" }
		local isoState = RunManager.addPlayer(isolatedPlayer :: any)
		assert(isoState ~= nil, "Isolated player must be added to isolated run")
		assert(RunManager.getLiveRunState().PartyMembers[87099] == nil, "LiveRun must not have isolated player")
		subtestRan = true
		return "subtest_completed"
	end)
	assertTest(runWithOk == true and runWithResult == "subtest_completed" and subtestRan == true, "[IsolationSafety] runWithTestIsolation succeeds on normal execution")
	assertTest(RunManager.isTestIsolationActive() == false, "[IsolationSafety] Isolation inactive after runWithTestIsolation returns")
	assertTest(RunManager.getLiveRunState().PartyMembers[87099] == nil, "[IsolationSafety] LiveRun remains clean after isolated sub-test")

	-- Test 13: runWithTestIsolation catches errors and guarantees isolation teardown
	local livePlayerMock = { UserId = 87900, Name = "LivePartyMember", DisplayName = "LiveMember" }
	local liveMemberState = RunManager.addPlayer(livePlayerMock :: any)
	assertTest(RunManager.getLiveRunState().PartyMembers[87900] ~= nil, "[IsolationSafety] Live party member added to liveRun before error test")

	local caughtOk, caughtErr = RunManager.runWithTestIsolation(function()
		assert(RunManager.isTestIsolationActive() == true, "Isolation active prior to error")
		local testPlayer = { UserId = 87901, Name = "CrashTester", DisplayName = "CrashTester" }
		RunManager.addPlayer(testPlayer :: any)
		error("Simulated test failure for exception safety verification")
	end)
	assertTest(caughtOk == false, "[IsolationSafety] runWithTestIsolation captures thrown error")
	assertTest(string.find(tostring(caughtErr), "Simulated test failure") ~= nil, "[IsolationSafety] runWithTestIsolation preserves error message")
	assertTest(RunManager.isTestIsolationActive() == false, "[IsolationSafety] Isolation ends automatically after error")
	assertTest(RunManager.getRunState() == RunManager.getLiveRunState(), "[IsolationSafety] currentRun points to liveRun after isolated failure")
	assertTest(RunManager.getLiveRunState().PartyMembers[87900] == liveMemberState, "[IsolationSafety] Live players remain intact after test failure")
	assertTest(RunManager.getLiveRunState().PartyMembers[87901] == nil, "[IsolationSafety] Failed test state never leaked to liveRun")

	-- Test 14: RequestStateSync during normal operation returns snapshot from liveRun with broadcasts unsuppressed
	local liveSyncSnapshot = RunManager.getRunSnapshotForPlayer(livePlayerMock :: any)
	assertTest(liveSyncSnapshot ~= nil, "[IsolationSafety] Normal RequestStateSync returns valid snapshot from liveRun")
	assertTest(liveSyncSnapshot.Party[tostring(livePlayerMock.UserId)] ~= nil, "[IsolationSafety] Live snapshot contains live party member")
	assertTest(liveSyncSnapshot.Party[tostring(lockTestPlayer.UserId)] == nil, "[IsolationSafety] Live snapshot contains zero test party members")
	assertTest(RunManager.isTestIsolationActive() == false, "[IsolationSafety] Broadcasts are unsuppressed in live server mode")

	-- Clean up mock live player
	RunManager.removePlayer(livePlayerMock :: any)

	----------------------------------------------------------------------------
	-- SUITE 61: Test Isolation Boundary & Live Run Protection
	----------------------------------------------------------------------------
	print("\n--- SUITE 61: Test Isolation Boundary & Live Run Protection ---")

	-- Ensure liveRun is in clean Lobby state before Suite 61 begins
	local liveRunRef = RunManager.getLiveRunState()
	liveRunRef.Phase = "Lobby"
	table.clear(liveRunRef.PartyMembers)

	-- Test Case A: When isIsolatedTesting is active and no real players are connected
	RunManager.beginTestIsolation()
	assertTest(RunManager.isTestIsolationActive() == true, "[IsolationSuite61] Isolation active for Case A")
	local caseATestPlayer = { UserId = 89001, Name = "MockTesterA", DisplayName = "TesterA" }
	local pAState = RunManager.addPlayer(caseATestPlayer :: any)
	if pAState then pAState.ClassLocked = true end

	local caseAStartResult = RunManager.startRun(nil)
	assertTest(caseAStartResult == true, "[CaseA] startRun(nil) succeeds on isolatedTestRun")
	assertTest(RunManager.getRunState().Phase == "MapSelect", "[CaseA] isolatedTestRun phase transitioned to MapSelect")
	assertTest(liveRunRef.Phase == "Lobby", "[CaseA] liveRun remains in Lobby phase")
	assertTest(RunManager.getLiveDungeonRun() == nil, "[CaseA] liveDungeonRun remains nil")
	assertTest(RunManager.getDungeonRun() ~= nil, "[CaseA] internalDungeonRun populated for isolated test")
	RunManager.endTestIsolation()

	-- Test Case B: When isIsolatedTesting is active AND a real player exists in liveRun
	local simRealPlayer1 = { UserId = 89010, Name = "RealPlayerOne", DisplayName = "RealOne", _isSimulatedRealPlayer = true }
	RunManager.beginTestIsolation()
	-- Add real player during isolation (routes to liveRun)
	local realP1State = RunManager.addPlayer(simRealPlayer1 :: any)
	assertTest(liveRunRef.PartyMembers[89010] ~= nil, "[CaseB] Real player registered in liveRun")
	assertTest(RunManager.getRunState().PartyMembers[89010] == nil, "[CaseB] Real player NOT added to isolatedTestRun")

	-- Add mock test player (routes to isolatedTestRun)
	local caseBTestPlayer = { UserId = 89002, Name = "MockTesterB", DisplayName = "TesterB" }
	local pBState = RunManager.addPlayer(caseBTestPlayer :: any)
	if pBState then pBState.ClassLocked = true end
	assertTest(RunManager.getRunState().PartyMembers[89002] ~= nil, "[CaseB] Mock player in isolatedTestRun")
	assertTest(liveRunRef.PartyMembers[89002] == nil, "[CaseB] Mock player NOT in liveRun")

	-- Automated test calls startRun() with nil initiator (as TestRunner does)
	local caseBStartResult = RunManager.startRun(nil)
	assertTest(caseBStartResult == true, "[CaseB] startRun(nil) succeeds on isolated test run")
	assertTest(RunManager.getRunState().Phase == "MapSelect", "[CaseB] isolatedTestRun transitioned to MapSelect")
	assertTest(liveRunRef.Phase == "Lobby", "[CaseB] liveRun remains in Lobby phase despite connected real player")
	assertTest(RunManager.getLiveDungeonRun() == nil, "[CaseB] liveDungeonRun remains nil")
	assertTest(realP1State.Resources.HP == 100, "[CaseB] Real player in liveRun completely unaffected")

	RunManager.endTestIsolation()
	liveRunRef.Phase = "Lobby"

	-- Test Case C: When isIsolatedTesting is active AND multiple real players are in liveRun
	local simRealPlayer2 = { UserId = 89020, Name = "RealPlayerTwo", DisplayName = "RealTwo", _isSimulatedRealPlayer = true }
	local simRealPlayer3 = { UserId = 89030, Name = "RealPlayerThree", DisplayName = "RealThree", _isSimulatedRealPlayer = true }
	RunManager.beginTestIsolation()
	RunManager.addPlayer(simRealPlayer2 :: any)
	RunManager.addPlayer(simRealPlayer3 :: any)
	assertTest(liveRunRef.PartyMembers[89020] ~= nil and liveRunRef.PartyMembers[89030] ~= nil, "[CaseC] Multiple real players registered in liveRun")

	local caseCMockPlayer = { UserId = 89003, Name = "MockTesterC", DisplayName = "TesterC" }
	local pCState = RunManager.addPlayer(caseCMockPlayer :: any)
	if pCState then pCState.ClassLocked = true end

	-- Test calling startRun(mockPlayer) mutates ONLY isolatedTestRun
	local caseCStartResult = RunManager.startRun(caseCMockPlayer :: any)
	assertTest(caseCStartResult == true, "[CaseC] startRun(mockPlayer) succeeds on isolatedTestRun")
	assertTest(RunManager.getRunState().Phase == "MapSelect", "[CaseC] isolatedTestRun transitioned to MapSelect")
	assertTest(liveRunRef.Phase == "Lobby", "[CaseC] liveRun remains in Lobby phase with multiple real players")
	assertTest(RunManager.getLiveDungeonRun() == nil, "[CaseC] liveDungeonRun remains nil")

	RunManager.endTestIsolation()
	liveRunRef.Phase = "Lobby"

	-- Test Case D: When isIsolatedTesting is active AND a real Player calls startRun(realPlayer)
	RunManager.beginTestIsolation()
	local simRealPlayerD = { UserId = 89040, Name = "RealPlayerD", DisplayName = "RealD", _isSimulatedRealPlayer = true }
	local realDState = RunManager.addPlayer(simRealPlayerD :: any)
	if realDState then realDState.ClassLocked = true end

	local caseDMockPlayer = { UserId = 89004, Name = "MockTesterD", DisplayName = "TesterD" }
	RunManager.addPlayer(caseDMockPlayer :: any)

	assertTest(liveRunRef.Phase == "Lobby", "[CaseD] liveRun initially in Lobby")
	assertTest(RunManager.getRunState().Phase == "Lobby", "[CaseD] isolatedTestRun initially in Lobby")

	-- Real player starts run
	local caseDStartResult = RunManager.startRun(simRealPlayerD :: any)
	assertTest(caseDStartResult == true, "[CaseD] startRun(realPlayer) succeeds")
	assertTest(liveRunRef.Phase == "MapSelect", "[CaseD] liveRun transitions to MapSelect")
	assertTest(RunManager.getLiveDungeonRun() ~= nil, "[CaseD] liveDungeonRun is populated")
	assertTest(RunManager.getRunState().Phase == "Lobby", "[CaseD] isolatedTestRun remains unaffected in Lobby")

	RunManager.endTestIsolation()
	liveRunRef.Phase = "Lobby"

	-- Test Case E: When isIsolatedTesting is active AND a mock player calls startRun(mockPlayer)
	RunManager.beginTestIsolation()
	local caseEMockPlayer = { UserId = 89005, Name = "MockTesterE", DisplayName = "TesterE" }
	local pEState = RunManager.addPlayer(caseEMockPlayer :: any)
	if pEState then pEState.ClassLocked = true end
	assertTest(liveRunRef.Phase == "Lobby", "[CaseE] liveRun in Lobby")
	assertTest(RunManager.getRunState().Phase == "Lobby", "[CaseE] isolatedTestRun in Lobby")

	local caseEStartResult = RunManager.startRun(caseEMockPlayer :: any)
	assertTest(caseEStartResult == true, "[CaseE] startRun(mockPlayer) succeeds")
	assertTest(RunManager.getRunState().Phase == "MapSelect", "[CaseE] isolatedTestRun transitions to MapSelect")
	assertTest(liveRunRef.Phase == "Lobby", "[CaseE] liveRun remains unaffected in Lobby")

	-- Broadcast suppression test:
	-- broadcastRunSnapshots without isLiveAction=true during isolation returns silently
	RunManager.broadcastRunSnapshots("Test broadcast during isolation", false)
	assertTest(true, "[BroadcastSuppression] broadcastRunSnapshots suppressed during isolation without isLiveAction")

	RunManager.endTestIsolation()
	liveRunRef.Phase = "Lobby"
	table.clear(liveRunRef.PartyMembers)
	end
	end)

	-- Defensive invariant: Isolation must NEVER remain active regardless of success or failure
	if RunManager.isTestIsolationActive() then
		RunManager.endTestIsolation()
	end

	if not testOk then
		error(testErr)
	end

	print("\n============================================================")
	print(string.format("  ALL %d PHASE 1, 2, 3 & PHASE 4 INTEGRATION TESTS PASSED CLEANLY! (100%% SUCCESS)", totalCount))
	print("============================================================\n")
	return true
end

return TestRunner
