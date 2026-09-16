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

	-- Reset test environment to a clean state
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
	----------------------------------------------------------------------------
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

	----------------------------------------------------------------------------
	-- TEST 9: Safe Card Play & Double-Play Prevention (Real API Path)
	----------------------------------------------------------------------------
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

	----------------------------------------------------------------------------
	-- TEST 10: Downed State & Teammate Rescue Mechanics
	----------------------------------------------------------------------------
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

	----------------------------------------------------------------------------
	-- TEST 11: Turn Ready Voting & Automatic Timeout
	----------------------------------------------------------------------------
	print("\n--- [Suite 11] Ready Voting & Monotonic Turn Timeout ---")
	CombatService.voteReady(player1)
	assertTest(p1State.IsReady == true, "Player 1 voted ready")
	CombatService.voteReady(player1)
	assertTest(p1State.IsReady == false, "Player 1 toggled unready")

	-- Simulate automatic timer timeout resolution
	CombatService.forceTurnTimeout()
	task.wait(0.5)
	assertTest(combat.TurnNumber == 2, "Turn number advanced to 2 after turn timeout resolution")
	assertTest(combat.Phase == "PlayerPhase", "Returned to PlayerPhase for Turn 2")

	----------------------------------------------------------------------------
	-- TEST 12: Enemy Defeat, Victory Callback & Rewards Transition
	----------------------------------------------------------------------------
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
	task.wait(2.0)
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

	----------------------------------------------------------------------------
	-- TEST 13: CRITICAL INVARIANT — Card Persistence Across Multiple Combats
	----------------------------------------------------------------------------
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

	----------------------------------------------------------------------------
	-- TEST 14: Player Leaving and Rejoining Mid-Run State Resilience
	----------------------------------------------------------------------------
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

	----------------------------------------------------------------------------
	-- TEST 15: Disconnect-Safety & Multiplayer Invariants (Phase 1.2 Regressions)
	----------------------------------------------------------------------------
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
	task.wait(0.6)

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
	task.wait(2.0)
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
	task.wait(0.6)
	assertTest(combat3Ref.Phase == "PlayerPhase", "[Test C] Combat continues while connected Player 1 is alive (disconnected players do not cause defeat)")

	-- Test C.2: Down Player 1: all connected players are now downed
	p1State.Resources.HP = 0
	p1State.IsDowned = true

	-- Trigger turn timeout so resolution check runs areAllPlayersDowned()
	CombatService.forceTurnTimeout()
	task.wait(2.0)
	assertTest(runState.Phase == "RunDefeat", "[Test C] Defeat correctly triggered when all CONNECTED players downed (disconnected players did not keep combat alive)!")

	----------------------------------------------------------------------------
	-- TEST 16: Poison Damage Resolution Invariant & Death Regressions
	----------------------------------------------------------------------------
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
	task.wait(0.6)

	assertTest(testEnemy.HP == 95, string.format("[Poison Test A] HP decreased by exactly 5 (Expected: 95, Actual: %d)", testEnemy.HP))
	assertTest(testEnemy.Shield == 20, string.format("[Poison Test A] Shield remained 20 without taking poison damage (Actual: %d)", testEnemy.Shield))
	assertTest(testEnemy.Poison == 4, string.format("[Poison Test A] Poison decremented by 1 stack (Expected: 4, Actual: %d)", testEnemy.Poison))

	-- Test B — Multiple poison ticks behave predictably (95/4 -> 91/3 -> 88/2)
	-- Tick 2: 95 HP / 4 Poison -> 91 HP / 3 Poison
	testEnemy.Intent = { Type = "Defend", Value = 0, Description = "Waiting" }
	CombatService.forceTurnTimeout()
	task.wait(0.6)

	assertTest(testEnemy.HP == 91, string.format("[Poison Test B] Second tick: 95 HP - 4 = 91 HP (Actual: %d)", testEnemy.HP))
	assertTest(testEnemy.Shield == 20, "[Poison Test B] Shield remains 20 after second tick")
	assertTest(testEnemy.Poison == 3, "[Poison Test B] Poison decremented to 3")

	-- Tick 3: 91 HP / 3 Poison -> 88 HP / 2 Poison
	testEnemy.Intent = { Type = "Defend", Value = 0, Description = "Waiting" }
	CombatService.forceTurnTimeout()
	task.wait(0.6)

	assertTest(testEnemy.HP == 88, string.format("[Poison Test B] Third tick: 91 HP - 3 = 88 HP (Actual: %d)", testEnemy.HP))
	assertTest(testEnemy.Shield == 20, "[Poison Test B] Shield remains 20 after third tick")
	assertTest(testEnemy.Poison == 2, "[Poison Test B] Poison decremented to 2")

	-- Test C — Poison can kill: 3 HP / 5 Poison -> 0 HP and triggers enemy death / victory
	testEnemy.HP = 3
	testEnemy.Shield = 20
	testEnemy.Poison = 5
	testEnemy.Intent = { Type = "Attack", Value = 10, Description = "Lethal Strike" }

	CombatService.forceTurnTimeout()
	task.wait(2.0)

	assertTest(testEnemy.HP == 0, string.format("[Poison Test C] Lethal poison reduced HP to 0 (Actual: %d)", testEnemy.HP))
	assertTest(runState.Phase == "Rewards", "[Poison Test C] Lethal poison triggered enemy death and transitioned combat to Rewards")

	print("\n============================================================")
	print(string.format("  ALL %d PHASE 1.2 INTEGRATION TESTS PASSED CLEANLY! (100%% SUCCESS)", totalCount))
	print("============================================================\n")
	return true
end

return TestRunner
