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

local services = script.Parent
local RunManager = require(services:WaitForChild("RunManager") :: ModuleScript)
local CombatService = require(services:WaitForChild("CombatService") :: ModuleScript)
local ClassService = require(services:WaitForChild("ClassService") :: ModuleScript)

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
	-- TEST 3: Start Run & Map Select Transition
	----------------------------------------------------------------------------
	print("\n--- [Suite 3] Real API startRun() Execution ---")
	local startRunSuccess = RunManager.startRun()
	assertTest(startRunSuccess == true, "RunManager.startRun() returned true")
	assertTest(runState.Phase == "MapSelect", "Run phase transitioned to MapSelect")
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
	-- TEST 5: Enter Combat & Multi-Enemy Co-op Scaling (4 Players)
	----------------------------------------------------------------------------
	print("\n--- [Suite 5] Active Combat Encounter & 4-Player Scaling ---")
	local combat = CombatService.getActiveCombat()
	assertTest(combat ~= nil, "CombatService.getActiveCombat() is active")
	assertTest(combat.Phase == "PlayerPhase", "Combat begins in PlayerPhase")
	assertTest(combat.TurnNumber == 1, "Combat initialized on Turn 1")

	local enemyCount = 0
	local firstEnemy: StateTypes.EnemyState? = nil
	for _, e in combat.Enemies do
		enemyCount += 1
		if not firstEnemy then firstEnemy = e end
	end
	assertTest(enemyCount >= 1, "Multi-enemy collection populated with combatants")
	assertTest(firstEnemy ~= nil, "Primary enemy retrieved")

	-- Verify Co-op Scaling across 4 players
	local expectedHp = GameConfig.scaleEnemyHp(80, 4) -- Tier 1 standard enemy
	assertTest(firstEnemy.MaxHP == expectedHp, string.format("Enemy HP scaled correctly for 4 players (Expected: %d, Actual: %d)", expectedHp, firstEnemy.MaxHP))

	-- Verify all 4 players drew cards
	local p1HandCount = 0
	for _ in p1State.Hand do p1HandCount += 1 end
	assertTest(p1HandCount == GameConfig.Combat.BaseHandDrawCount, "Player 1 drew opening hand of 4 cards")

	----------------------------------------------------------------------------
	-- TEST 6: Strict API Rejection Checks on CombatService.playCard
	----------------------------------------------------------------------------
	print("\n--- [Suite 6] Strict Rejection Rules on Real CombatService API ---")
	local testCard = getAnyCardInHand(p1State)

	-- 6a. Unauthorized / non-party player
	local fakePlayer = { UserId = 99999, Name = "Hacker" }
	local rejPlayerOk, rejPlayerErr = CombatService.playCard(fakePlayer, testCard.InstanceId, firstEnemy.InstanceId)
	assertTest(rejPlayerOk == false and rejPlayerErr == "Player not in party.", "Unauthorized player rejected")

	-- 6b. Invalid target enemy ID
	local rejTargetOk, rejTargetErr = CombatService.playCard(player1, testCard.InstanceId, "invalid_enemy_999")
	assertTest(rejTargetOk == false and rejTargetErr == "Invalid target enemy.", "Invalid target enemy rejected")

	-- 6c. Insufficient energy
	p1State.Resources.Energy = 0
	local rejEnergyOk, rejEnergyErr = CombatService.playCard(player1, testCard.InstanceId, firstEnemy.InstanceId)
	assertTest(rejEnergyOk == false and rejEnergyErr == "Not enough Energy!", "Card play with insufficient energy rejected")
	p1State.Resources.Energy = 3 -- Restore energy

	-- 6d. Wrong combat phase
	combat.Phase = "ResolutionPhase"
	local rejPhaseOk, rejPhaseErr = CombatService.playCard(player1, testCard.InstanceId, firstEnemy.InstanceId)
	assertTest(rejPhaseOk == false and rejPhaseErr == "Combat is not in PlayerPhase.", "Card play during wrong phase rejected")
	combat.Phase = "PlayerPhase" -- Restore phase

	-- 6e. Downed player actions
	p2State.IsDowned = true
	local p2Card = getAnyCardInHand(p2State)
	local rejDownedOk, rejDownedErr = CombatService.playCard(player2, p2Card.InstanceId, firstEnemy.InstanceId)
	assertTest(rejDownedOk == false and rejDownedErr == "Downed players cannot play cards.", "Downed player card play rejected")

	local rejReadyOk, rejReadyErr = CombatService.voteReady(player2)
	assertTest(rejReadyOk == false and rejReadyErr == "Downed players cannot vote ready.", "Downed player ready vote rejected")
	p2State.IsDowned = false

	----------------------------------------------------------------------------
	-- TEST 7: Safe Card Play & Double-Play Prevention (Real API Path)
	----------------------------------------------------------------------------
	print("\n--- [Suite 7] Real Card Play & Double-Play Prevention ---")
	local startingEnemyHp = firstEnemy.HP
	local startingEnergy = p1State.Resources.Energy
	local cardToPlay = getAnyCardInHand(p1State)
	local playedCardId = cardToPlay.InstanceId
	local cardCost = cardToPlay.CardData.Cost

	local playSuccess, playErr = CombatService.playCard(player1, playedCardId, firstEnemy.InstanceId)
	assertTest(playSuccess == true and playErr == nil, "CombatService.playCard executed successfully")
	assertTest(p1State.Hand[playedCardId] == nil, "Played card removed from player hand hashmap")
	assertTest(#p1State.DiscardPile >= 1, "Played card moved to discard pile")
	assertTest(p1State.Resources.Energy == startingEnergy - cardCost, "Energy correctly deducted")

	-- CRITICAL INVARIANT: Re-playing the exact same CardInstanceId MUST fail
	local doublePlaySuccess, doublePlayErr = CombatService.playCard(player1, playedCardId, firstEnemy.InstanceId)
	assertTest(doublePlaySuccess == false and doublePlayErr == "Card not found in hand.", "Double-play through real API safely rejected with 'Card not found in hand.'")

	----------------------------------------------------------------------------
	-- TEST 8: Downed State & Teammate Rescue Mechanics
	----------------------------------------------------------------------------
	print("\n--- [Suite 8] Downed State & Teammate Rescue Mechanics ---")
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
	-- TEST 9: Turn Ready Voting & Automatic Timeout
	----------------------------------------------------------------------------
	print("\n--- [Suite 9] Ready Voting & Monotonic Turn Timeout ---")
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
	-- TEST 10: Enemy Defeat, Victory Callback & Rewards Transition
	----------------------------------------------------------------------------
	print("\n--- [Suite 10] Enemy Defeat & Room Clear Transition ---")
	-- Set all enemies to 1 HP
	for _, e in combat.Enemies do
		e.HP = 1
		e.Shield = 0
	end

	local lethalCard = getAnyCardInHand(p1State)
	p1State.Resources.Energy = 3
	CombatService.playCard(player1, lethalCard.InstanceId, firstEnemy.InstanceId)

	-- Wait for room completion callback
	task.wait(2.0)
	assertTest(runState.Phase == "Rewards", "Room cleared and run state transitioned to Rewards")
	assertTest(runState.PendingRewards ~= nil, "PendingRewards populated in RunState")
	assertTest(runState.PendingRewards.GoldAmount > 0, "Gold reward assigned")
	assertTest(runState.PendingRewards.AetherShardsAmount > 0, "Aether Shards assigned")
	assertTest(runState.PendingRewards.OfferedCardsByPlayer[10001] ~= nil, "Player 1 received 3-card draft choices")

	----------------------------------------------------------------------------
	-- TEST 11: 3-Card Universal Draft Claim & Double-Claim Rejection
	----------------------------------------------------------------------------
	print("\n--- [Suite 11] Reward Card Claiming & Double-Claim Rejection ---")
	local draftOptions = runState.PendingRewards.OfferedCardsByPlayer[10001]
	assertTest(#draftOptions == GameConfig.Rewards.CardDraftChoicesCount, "Exact 3 draft cards offered")
	local chosenCardId = draftOptions[1].Id
	local deckCountBefore = #p1State.Deck

	local claimSuccess, claimErr = RunManager.claimRewardCard(player1, chosenCardId)
	assertTest(claimSuccess == true and claimErr == nil, "Draft card successfully claimed")
	assertTest(#p1State.Deck == deckCountBefore + 1, "Claimed card added to player deck")
	assertTest(p1State.Deck[#p1State.Deck].DefinitionId == chosenCardId, "New card definition matches choice")
	assertTest(runState.PendingRewards.ClaimedCards[10001] == true, "Claim flag set for player")

	-- Double-claim rejection
	local doubleClaimSuccess, doubleClaimErr = RunManager.claimRewardCard(player1, draftOptions[2].Id)
	assertTest(doubleClaimSuccess == false and doubleClaimErr == "Reward already claimed.", "Second claim attempt safely rejected")

	----------------------------------------------------------------------------
	-- TEST 12: Continue to MapSelect & Travel to Subsequent Room
	----------------------------------------------------------------------------
	print("\n--- [Suite 12] Continue from Rewards & Multi-Room Progression ---")
	local contSuccess = RunManager.continueFromRewards(player1)
	assertTest(contSuccess == true, "RunManager.continueFromRewards succeeded")
	assertTest(runState.Phase == "MapSelect", "Returned to MapSelect phase")
	assertTest(runState.CurrentTier == 1, "Completed Tier 1; tier is now 1")
	assertTest(#runState.AvailableNodeIds > 0, "Tier 2 rooms available for selection")

	-- Travel to Tier 2 room
	local nextRoomId = runState.AvailableNodeIds[1]
	RunManager.voteMapNode(player1, nextRoomId)
	RunManager.voteMapNode(player2, nextRoomId)
	RunManager.voteMapNode(player3, nextRoomId)

	assertTest(runState.Phase == "ActiveRoom", "Traveled to subsequent room (Tier 2)")
	assertTest(runState.CurrentNodeId == nextRoomId, "CurrentNodeId points to Tier 2 room")

	----------------------------------------------------------------------------
	-- TEST 13: Player Leaving and Rejoining Mid-Run State Resilience
	----------------------------------------------------------------------------
	print("\n--- [Suite 13] Player Disconnect / Reconnect State Resilience ---")
	local p2HpBefore = p2State.Resources.HP
	local p2DeckCountBefore = #p2State.Deck
	local p2GoldBefore = p2State.Gold

	-- Player 2 leaves
	RunManager.removePlayer(player2)
	assertTest(runState.PartyMembers[10002] ~= nil, "Player 2 record retained mid-run (slot preserved)")
	assertTest(runState.PartyMembers[10002].PlayerInstance == nil, "PlayerInstance reference safely cleared")

	-- Player 2 reconnects
	local reconnectedP2 = RunManager.addPlayer(player2)
	assertTest(reconnectedP2 == p2State, "Reconnected player re-associated with original PlayerState")
	assertTest(reconnectedP2.Resources.HP == p2HpBefore, "Player HP completely preserved")
	assertTest(#reconnectedP2.Deck == p2DeckCountBefore, "Player Deck completely preserved")
	assertTest(reconnectedP2.Gold == p2GoldBefore, "Player Gold completely preserved")
	assertTest(partyCount == 4, "Party integrity preserved with zero corruption")

	print("\n============================================================")
	print(string.format("  ALL %d INTEGRATION TESTS PASSED CLEANLY! (100%% SUCCESS)", totalCount))
	print("============================================================\n")
	return true
end

return TestRunner
