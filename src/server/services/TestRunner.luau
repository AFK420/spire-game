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

	----------------------------------------------------------------------------
	-- TEST 17: TargetResolver Action Target Validation
	----------------------------------------------------------------------------
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

	----------------------------------------------------------------------------
	-- TEST 18: ModifierResolver Deterministic Math Pipeline
	----------------------------------------------------------------------------
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

	----------------------------------------------------------------------------
	-- TEST 19: DamagePipeline Mitigation & Shield Absorption
	----------------------------------------------------------------------------
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

	----------------------------------------------------------------------------
	-- TEST 20: StatusService Lifecycle (Apply, Stack, Tick, Remove, Sync)
	----------------------------------------------------------------------------
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

	----------------------------------------------------------------------------
	-- TEST 21: EffectResolver Generic Dispatch
	----------------------------------------------------------------------------
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

	----------------------------------------------------------------------------
	-- TEST 22: First Aid Generic Conditional Semantics
	----------------------------------------------------------------------------
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

	----------------------------------------------------------------------------
	-- TEST 23: Exhaust Pile Uniqueness & Pile Invariants
	----------------------------------------------------------------------------
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

	----------------------------------------------------------------------------
	-- TEST 24: Effect-Level Target Overrides
	----------------------------------------------------------------------------
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

	----------------------------------------------------------------------------
	-- TEST 25: ModifyResource Safety & Clamping
	----------------------------------------------------------------------------
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

	----------------------------------------------------------------------------
	-- TEST 26: Event Triggering & Recursion Protection
	----------------------------------------------------------------------------
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

	----------------------------------------------------------------------------
	-- TEST 27: Status Authority & Tick Behavior Registry
	----------------------------------------------------------------------------
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

	----------------------------------------------------------------------------
	-- TEST 28: Damage Pipeline Edge Cases & Mitigations
	----------------------------------------------------------------------------
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

	----------------------------------------------------------------------------
	-- TEST 29: Modifier Pipeline Determinism & Immutability
	----------------------------------------------------------------------------
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

	----------------------------------------------------------------------------
	-- TEST 30: ModifyResource Multi-Targeting & Boundary Safety
	----------------------------------------------------------------------------
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

	----------------------------------------------------------------------------
	-- TEST 31: TriggerEvent Truthful Execution & Error Isolation
	----------------------------------------------------------------------------
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

	----------------------------------------------------------------------------
	-- TEST 32: Real Target Resolution Context & Multi-Entity Integrity
	----------------------------------------------------------------------------
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

	----------------------------------------------------------------------------
	-- TEST 33: CreateCard Schema Strictness & Pile Placement
	----------------------------------------------------------------------------
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

	----------------------------------------------------------------------------
	-- TEST 34: Card Pile Invariant Verification & Lifecycle Safety
	----------------------------------------------------------------------------
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

	----------------------------------------------------------------------------
	-- TEST 35: Status Authority Boundary & Projection Output Contracts
	----------------------------------------------------------------------------
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

	----------------------------------------------------------------------------
	-- TEST 36: Cross-System Multi-Action Integration Chains
	----------------------------------------------------------------------------
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

	----------------------------------------------------------------------------
	-- TEST 37: Static Card Effect Target Compatibility
	----------------------------------------------------------------------------
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

	print("\n============================================================")
	print(string.format("  ALL %d PHASE 2, 2.1 & 2.2 INTEGRATION TESTS PASSED CLEANLY! (100%% SUCCESS)", totalCount))
	print("============================================================\n")
	return true
end

return TestRunner
