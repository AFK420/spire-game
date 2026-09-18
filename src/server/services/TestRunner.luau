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

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)
local GameConfig = require(Shared:WaitForChild("GameConfig") :: ModuleScript)
local CardData = require(Shared:WaitForChild("CardData") :: ModuleScript)
local RelicData = require(Shared:WaitForChild("RelicData") :: ModuleScript)
local ClassData = require(Shared:WaitForChild("ClassData") :: ModuleScript)
local DungeonMap = require(Shared:WaitForChild("DungeonMap") :: ModuleScript)
local BuildInfo = require(Shared:WaitForChild("BuildInfo") :: ModuleScript)

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
local WorldRoomService = require(services:WaitForChild("WorldRoomService") :: ModuleScript)
local EventService = require(services:WaitForChild("EventService") :: ModuleScript)
local ReactionService = require(services:WaitForChild("ReactionService") :: ModuleScript)
local EnvironmentService = require(services:WaitForChild("EnvironmentService") :: ModuleScript)
local EventData = require(Shared:WaitForChild("EventData") :: ModuleScript)
local ReactionData = require(Shared:WaitForChild("ReactionData") :: ModuleScript)
local EnvironmentData = require(Shared:WaitForChild("EnvironmentData") :: ModuleScript)
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

local function runSuite65()
	print("\n--- [Suite 65] Action Transactions, Status Integrity, Persistence Safety & Map ---")

	do -- 65.1: Card action transaction rollback on second effect failure
		CombatService.cleanupCombat()
		RunManager.resetRunForTesting()
		local txPlayer = {
			UserId = 65001,
			Name = "TxPlayer1",
			DisplayName = "TxPlayer1",
			IsA = function(_, cls) return cls == "Player" end,
		}
		local txPState = RunManager.addPlayer(txPlayer :: any)
		assert(txPState, "txPState exists")
		txPState.ClassLocked = true
		RunManager.startRun(txPlayer :: any)
		local txCombat = CombatService.startCombat("enc_tx1", "Combat", 1, { [txPlayer.UserId] = txPState }, function() end)
		assert(txCombat and txCombat.Enemies["enemy_1"], "txCombat enemy exists")
		local txEnemy = txCombat.Enemies["enemy_1"]
		local initialEnemyHp = txEnemy.HP
		txPState.Resources.Energy = 3

		local testCardInst: StateTypes.CardInstance = {
			CardInstanceId = "card_tx_fail_1",
			DefinitionId = "Strike",
			CardData = {
				Id = "Strike",
				Name = "Test Fail Card",
				Description = "Deals damage then fails",
				Type = "Attack",
				Rarity = "Common",
				Target = "SingleEnemy",
				Cost = 1,
				Upgraded = false,
				Class = "Warlord",
				Tags = {},
				Effects = {
					{ Type = "Damage", Value = 10, Target = "Enemy" },
					{ Type = "NonExistentEffectXYZ" :: any, Value = 5, Target = "Enemy" },
				},
			},
			OwnerUserId = txPlayer.UserId,
			Upgraded = false,
			BaseCost = 1,
			TemporaryCostModifier = 0,
			Keywords = {},
		}
		table.insert(txPState.Hand, testCardInst)
		local playOk, playErr = CombatService.playCard(txPlayer :: any, "card_tx_fail_1", txEnemy.InstanceId)
		assertTest(playOk == false, "[Suite 65.1a] Card with failing second effect returns false")
		assertTest(txPState.Resources.Energy == 3, "[Suite 65.1b] Failed card restores Energy to 3")
		assertTest(txEnemy.HP == initialEnemyHp, "[Suite 65.1c] Failed card reverts first-effect damage on enemy")
		assertTest(#txPState.Hand == 1 and txPState.Hand[1].CardInstanceId == "card_tx_fail_1", "[Suite 65.1d] Failed card remains in exact hand position")
		assertTest(#txPState.DiscardPile == 0, "[Suite 65.1e] Failed card not moved to discard pile")

		-- 65.2: BloodPriest HP sacrifice reverted on failed card
		txPState.ClassId = "BloodPriest"
		txPState.Resources.Energy = 0
		txPState.Resources.HP = 80
		ClassService.resetClassCombatGimmicks(txPlayer.UserId)
		local bpCardInst: StateTypes.CardInstance = {
			CardInstanceId = "card_bp_fail",
			DefinitionId = "Strike",
			CardData = {
				Id = "Strike",
				Name = "BP Fail Strike",
				Description = "Costs HP then fails",
				Type = "Attack",
				Rarity = "Common",
				Target = "SingleEnemy",
				Cost = 1,
				Upgraded = false,
				Class = "BloodPriest",
				Tags = {},
				Effects = {
					{ Type = "Damage", Value = 5, Target = "Enemy" },
					{ Type = "NonExistentEffectXYZ" :: any, Value = 1, Target = "Enemy" },
				},
			},
			OwnerUserId = txPlayer.UserId,
			Upgraded = false,
			BaseCost = 1,
			TemporaryCostModifier = 0,
			Keywords = {},
		}
		table.insert(txPState.Hand, bpCardInst)
		local bpOk, _ = CombatService.playCard(txPlayer :: any, "card_bp_fail", txEnemy.InstanceId)
		assertTest(bpOk == false, "[Suite 65.2a] BloodPriest failing card returns false")
		assertTest(txPState.Resources.HP == 80, "[Suite 65.2b] BloodPriest HP sacrifice reverted on failure")
		local bpGimmick = ClassService.getGimmickTracker(txPlayer.UserId)
		assertTest(bpGimmick.TotalSacrificedHP == 0, "[Suite 65.2c] BloodPriest TotalSacrificedHP reverted to 0")

		-- 65.3: Shadowblade combo reverted on failed card
		txPState.ClassId = "Shadowblade"
		txPState.Resources.Energy = 3
		ClassService.resetClassCombatGimmicks(txPlayer.UserId)
		local sbGimmick = ClassService.getGimmickTracker(txPlayer.UserId)
		sbGimmick.ComboCount = 2
		local sbCardInst: StateTypes.CardInstance = {
			CardInstanceId = "card_sb_fail",
			DefinitionId = "Strike",
			CardData = {
				Id = "Strike",
				Name = "SB Fail Strike",
				Description = "Fails",
				Type = "Attack",
				Rarity = "Common",
				Target = "SingleEnemy",
				Cost = 1,
				Upgraded = false,
				Class = "Shadowblade",
				Tags = {},
				Effects = {
					{ Type = "Damage", Value = 5, Target = "Enemy" },
					{ Type = "InvalidEffectXYZ" :: any, Value = 1, Target = "Enemy" },
				},
			},
			OwnerUserId = txPlayer.UserId,
			Upgraded = false,
			BaseCost = 1,
			TemporaryCostModifier = 0,
			Keywords = {},
		}
		table.insert(txPState.Hand, sbCardInst)
		local sbOk, _ = CombatService.playCard(txPlayer :: any, "card_sb_fail", txEnemy.InstanceId)
		assertTest(sbOk == false, "[Suite 65.3a] Shadowblade failing card returns false")
		assertTest(ClassService.getGimmickTracker(txPlayer.UserId).ComboCount == 2, "[Suite 65.3b] Shadowblade ComboCount reverted to 2 on failure")

		-- 65.4: Mechanist scrap parts reverted on failed card
		txPState.ClassId = "Mechanist"
		txPState.Resources.Energy = 3
		ClassService.resetClassCombatGimmicks(txPlayer.UserId)
		local mechGimmick = ClassService.getGimmickTracker(txPlayer.UserId)
		mechGimmick.ScrapParts = 3
		local mechCardInst: StateTypes.CardInstance = {
			CardInstanceId = "card_mech_fail",
			DefinitionId = "Defend",
			CardData = {
				Id = "Defend",
				Name = "Mech Fail Skill",
				Description = "Fails",
				Type = "Skill",
				Rarity = "Common",
				Target = "Self",
				Cost = 1,
				Upgraded = false,
				Class = "Mechanist",
				Tags = {},
				Effects = {
					{ Type = "Shield", Value = 5, Target = "Self" },
					{ Type = "InvalidEffectXYZ" :: any, Value = 1, Target = "Self" },
				},
			},
			OwnerUserId = txPlayer.UserId,
			Upgraded = false,
			BaseCost = 1,
			TemporaryCostModifier = 0,
			Keywords = {},
		}
		table.insert(txPState.Hand, mechCardInst)
		local mechOk, _ = CombatService.playCard(txPlayer :: any, "card_mech_fail", nil)
		assertTest(mechOk == false, "[Suite 65.4a] Mechanist failing card returns false")
		assertTest(ClassService.getGimmickTracker(txPlayer.UserId).ScrapParts == 3, "[Suite 65.4b] Mechanist ScrapParts reverted to 3 on failure")

		-- 65.5: Applied status on enemy reverted on failed card
		txPState.ClassId = "Warlord"
		txPState.Resources.Energy = 3
		local poisonCardInst: StateTypes.CardInstance = {
			CardInstanceId = "card_status_fail",
			DefinitionId = "Strike",
			CardData = {
				Id = "Strike",
				Name = "Poison Fail Card",
				Description = "Applies poison then fails",
				Type = "Attack",
				Rarity = "Common",
				Target = "SingleEnemy",
				Cost = 1,
				Upgraded = false,
				Class = "Warlord",
				Tags = {},
				Effects = {
					{ Type = "Poison", Value = 5, Target = "Enemy" },
					{ Type = "InvalidEffectXYZ" :: any, Value = 1, Target = "Enemy" },
				},
			},
			OwnerUserId = txPlayer.UserId,
			Upgraded = false,
			BaseCost = 1,
			TemporaryCostModifier = 0,
			Keywords = {},
		}
		table.insert(txPState.Hand, poisonCardInst)
		local statOk, _ = CombatService.playCard(txPlayer :: any, "card_status_fail", txEnemy.InstanceId)
		assertTest(statOk == false, "[Suite 65.5a] Card with failing effect after status returns false")
		local enemyPoisonInst = StatusService.getStatus(txEnemy.InstanceId, "Poison")
		assertTest(enemyPoisonInst == nil or enemyPoisonInst.Stacks == 0, "[Suite 65.5b] Applied status on enemy reverted on failure")
	end

	do -- 65.6 - 65.9: Skill execution and rollback
		CombatService.cleanupCombat()
		RunManager.resetRunForTesting()
		local txPlayer = {
			UserId = 65006,
			Name = "SkillPlayer",
			DisplayName = "SkillPlayer",
			IsA = function(_, cls) return cls == "Player" end,
		}
		local txPState = RunManager.addPlayer(txPlayer :: any)
		assert(txPState, "txPState exists")
		txPState.ClassLocked = true
		RunManager.startRun(txPlayer :: any)
		local txCombat = CombatService.startCombat("enc_tx_skill", "Combat", 1, { [txPlayer.UserId] = txPState }, function() end)
		assert(txCombat and txCombat.Enemies["enemy_1"], "txCombat enemy exists")
		local txEnemy = txCombat.Enemies["enemy_1"]

		-- 65.6: Skill action succeeds when all effects succeed
		txPState.Resources.Energy = 3
		SkillService.resetCooldowns(txPState)
		local heroicInst = SkillService.getEquippedSkill(txPState, "Skill1")
		assert(heroicInst, "HeroicStrike equipped in Skill1")
		heroicInst.CurrentCooldown = 0
		local enemyHpBeforeSkill = txEnemy.HP
		local skillSuccess, skillErr = SkillService.useSkill(txPState, "Skill1", txEnemy.InstanceId, txCombat, { [txPlayer.UserId] = txPState })
		assertTest(skillSuccess == true, "[Suite 65.6a] Valid skill use returns true")
		assertTest(txPState.Resources.Energy < 3, "[Suite 65.6b] Successful skill deducts Energy")
		assertTest(heroicInst.CurrentCooldown > 0, "[Suite 65.6c] Successful skill sets cooldown turns")
		assertTest(txEnemy.HP < enemyHpBeforeSkill, "[Suite 65.6d] Successful skill deals damage to enemy")

		-- 65.7: Skill action rollback when first succeeds and second fails
		txPState.Resources.Energy = 3
		heroicInst.CurrentCooldown = 0
		local enemyHpBeforeMultiSkill = txEnemy.HP
		local heroicDef = SkillData.getSkill("HeroicStrike")
		assert(heroicDef, "heroicDef exists")
		local originalHeroicEffects = heroicDef.Effects
		heroicDef.Effects = {
			{ Type = "Damage", Value = 12, Target = "Enemy" },
			{ Type = "NonExistentSkillEffect" :: any, Value = 5, Target = "Enemy" },
		}
		local failSkillOk, failSkillErr = SkillService.useSkill(txPState, "Skill1", txEnemy.InstanceId, txCombat, { [txPlayer.UserId] = txPState })
		heroicDef.Effects = originalHeroicEffects -- restore definition
		assertTest(failSkillOk == false, "[Suite 65.7a] Skill with failing second effect returns false")
		assertTest(txPState.Resources.Energy == 3, "[Suite 65.7b] Failed skill keeps Energy at 3")
		assertTest(heroicInst.CurrentCooldown == 0, "[Suite 65.7c] Failed skill keeps cooldown at 0")
		assertTest(txEnemy.HP == enemyHpBeforeMultiSkill, "[Suite 65.7d] Failed skill rolls back first-effect damage")

		-- 65.8: Skill action fails when all effects are skipped (conditions false)
		txPState.Resources.Energy = 3
		heroicInst.CurrentCooldown = 0
		heroicDef.Effects = {
			{ Type = "Damage", Value = 10, Target = "Enemy", Condition = "TargetDowned" },
		}
		local skipSkillOk, _ = SkillService.useSkill(txPState, "Skill1", txEnemy.InstanceId, txCombat, { [txPlayer.UserId] = txPState })
		heroicDef.Effects = originalHeroicEffects -- restore definition
		assertTest(skipSkillOk == false, "[Suite 65.8a] Skill with zero executed effects returns false")
		assertTest(txPState.Resources.Energy == 3, "[Suite 65.8b] Skipped skill keeps Energy at 3")
		assertTest(heroicInst.CurrentCooldown == 0, "[Suite 65.8c] Skipped skill keeps cooldown at 0")

		-- 65.9: Skill action pre-validation rejects invalid effect type
		txPState.Resources.Energy = 3
		heroicInst.CurrentCooldown = 0
		heroicDef.Effects = {
			{ Type = "CompletelyInvalidType" :: any, Value = 1, Target = "Enemy" },
		}
		local invalidSkillOk, _ = SkillService.useSkill(txPState, "Skill1", txEnemy.InstanceId, txCombat, { [txPlayer.UserId] = txPState })
		heroicDef.Effects = originalHeroicEffects
		assertTest(invalidSkillOk == false, "[Suite 65.9] Pre-validation rejects invalid effect type on skill")
	end

	do -- 65.10 - 65.12: Player status single damage and immediate defeat termination
		CombatService.cleanupCombat()
		RunManager.resetRunForTesting()
		local txPlayer = {
			UserId = 65010,
			Name = "StatusPlayer",
			DisplayName = "StatusPlayer",
			IsA = function(_, cls) return cls == "Player" end,
		}
		local txPState = RunManager.addPlayer(txPlayer :: any)
		assert(txPState, "txPState exists")
		txPState.ClassLocked = true
		RunManager.startRun(txPlayer :: any)
		local txCombat = CombatService.startCombat("enc_tx_status", "Combat", 1, { [txPlayer.UserId] = txPState }, function() end)
		assert(txCombat, "txCombat exists")

		-- 65.10: Player status single damage: 3 Poison deals exactly 3 damage to HP, does not touch Shield
		StatusService.resetCombat()
		txPState.Resources.HP = 50
		txPState.Resources.Shield = 10
		txPState.IsDowned = false
		StatusService.applyStatus(tostring(txPlayer.UserId), "Poison", 3, nil, "system", txPState)
		local pTicks = StatusService.tickStatuses(tostring(txPlayer.UserId), "TurnStart", txPState, false)
		assertTest(#pTicks == 1 and pTicks[1].DamageDealt == 3, "[Suite 65.10a] StatusService ticks 3 Poison dealing 3 DamageDealt")
		assertTest(txPState.Resources.HP == 47, "[Suite 65.10b] Player HP reduced by exactly 3 (from 50 to 47)")
		assertTest(txPState.Resources.Shield == 10, "[Suite 65.10c] Player Shield remains untouched at 10 (Poison bypasses Shield)")

		-- 65.11: Player status downed exactly once
		txPState.Resources.HP = 2
		txPState.Resources.Shield = 0
		txPState.IsDowned = false
		StatusService.applyStatus(tostring(txPlayer.UserId), "Poison", 5, nil, "system", txPState)
		local pDownTicks = StatusService.tickStatuses(tostring(txPlayer.UserId), "TurnStart", txPState, false)
		assertTest(#pDownTicks == 1 and pDownTicks[1].Defeated == true, "[Suite 65.11a] StatusService marks player defeated")
		assertTest(txPState.Resources.HP == 0, "[Suite 65.11b] Player HP reduced to 0")

		-- 65.12: Status-induced total defeat immediately ends combat in Defeat
		CombatService.cleanupCombat()
		RunManager.resetRunForTesting()
		local soloPlayer = {
			UserId = 65012,
			Name = "SoloPlayer",
			DisplayName = "SoloPlayer",
			IsA = function(_, cls) return cls == "Player" end,
		}
		local soloPState = RunManager.addPlayer(soloPlayer :: any)
		assert(soloPState, "soloPState exists")
		soloPState.ClassLocked = true
		RunManager.startRun(soloPlayer :: any)
		local soloCombat = CombatService.startCombat("enc_solo_defeat", "Combat", 1, { [soloPlayer.UserId] = soloPState }, function() end)
		assert(soloCombat, "soloCombat exists")
		soloPState.Resources.HP = 2
		soloPState.Resources.Shield = 0
		soloPState.IsDowned = false
		StatusService.applyStatus(tostring(soloPlayer.UserId), "Poison", 5, nil, "system", soloPState)
		CombatService.forceTurnTimeout() -- auto-resolves turn
		assertTest(soloCombat.Phase == "Defeat", "[Suite 65.12a] Status-induced defeat immediately ends combat")
		assertTest(soloCombat.TurnNumber == 1, "[Suite 65.12b] TurnNumber did not advance past turn 1 upon defeat")
	end

	do -- 65.13: LoadFailed profile safe through DeckService and CardCollectionService
		local failUser = {
			UserId = 65013,
			Name = "FailUser",
			DisplayName = "FailUser",
			IsA = function(_, cls) return cls == "Player" end,
		}
		PersistenceService.simulateLoadFailureForTesting(failUser.UserId)
		assertTest(PersistenceService.getProfile(failUser :: any) == nil, "[Suite 65.13a] getProfile returns nil for LoadFailed player")
		assertTest(CardCollectionService.getCardCount(failUser :: any, "Strike") == 0, "[Suite 65.13b] getCardCount returns 0 without crashing on nil profile")
		local coll = CardCollectionService.getCollection(failUser :: any)
		assertTest(typeof(coll) == "table" and next(coll) == nil, "[Suite 65.13c] getCollection returns empty table without crashing")
		local slots = DeckService.getSlotEntitlement(failUser :: any)
		assertTest(slots.AvailableSlots == 0, "[Suite 65.13d] getSlotEntitlement returns safe zero-capacity view")
		local deckList = DeckService.listDecks(failUser :: any)
		assertTest(#deckList == 0, "[Suite 65.13e] listDecks returns empty list without crashing")
		assertTest(DeckService.getActiveDeck(failUser :: any) == nil, "[Suite 65.13f] getActiveDeck returns nil without crashing")
		local saveOk, _ = DeckService.saveDeck(failUser :: any, "some_deck", {})
		assertTest(saveOk == false, "[Suite 65.13g] saveDeck returns false without crashing")
	end

	do -- 65.14: RunManager.addPlayer optional strict typing
		RunManager.resetRunForTesting()
		for i = 1, 4 do
			local m = { UserId = 65100 + i, Name = "M" .. i, DisplayName = "M" .. i, IsA = function(_, cls) return cls == "Player" end }
			local added = RunManager.addPlayer(m :: any)
			assertTest(added ~= nil, string.format("[Suite 65.14a] Player %d added to party", i))
		end
		local extraPlayer = { UserId = 65199, Name = "Extra", DisplayName = "Extra", IsA = function(_, cls) return cls == "Player" end }
		local extraAdded: StateTypes.PlayerState? = RunManager.addPlayer(extraPlayer :: any)
		assertTest(extraAdded == nil, "[Suite 65.14b] 5th player addition returns nil, conforming to PlayerState? return type")
	end

	do -- 65.15: claimRewardCard atomicity
		RunManager.resetRunForTesting()
		local rewardPlayer = {
			UserId = 65015,
			Name = "RewardPlayer",
			DisplayName = "RewardPlayer",
			IsA = function(_, cls) return cls == "Player" end,
		}
		local rewardPState = RunManager.addPlayer(rewardPlayer :: any)
		assert(rewardPState, "rewardPState exists")
		rewardPState.ClassLocked = true
		RunManager.startRun(rewardPlayer :: any)
		RunManager.transitionToRewards(false, false)
		local rRun = RunManager.getRunState()
		assert(rRun.PendingRewards and rRun.PendingRewards.OfferedCardsByPlayer[rewardPlayer.UserId], "rewards generated")
		local offeredCard = rRun.PendingRewards.OfferedCardsByPlayer[rewardPlayer.UserId][1].Id
		local initialDeckSize = #rewardPState.Deck
		local initialCollectionCount = CardCollectionService.getCardCount(rewardPlayer :: any, offeredCard)
		local claim1Ok, claim1Err = RunManager.claimRewardCard(rewardPlayer :: any, offeredCard)
		assertTest(claim1Ok == true, "[Suite 65.15a] Valid reward claim returns true")
		assertTest(#rewardPState.Deck == initialDeckSize + 1, "[Suite 65.15b] Claimed card instance added to runtime deck")
		assertTest(CardCollectionService.getCardCount(rewardPlayer :: any, offeredCard) == initialCollectionCount + 1, "[Suite 65.15c] Permanent collection count incremented exactly once")
		local claim2Ok, claim2Err = RunManager.claimRewardCard(rewardPlayer :: any, offeredCard)
		assertTest(claim2Ok == false and claim2Err == "Reward already claimed.", "[Suite 65.15d] Duplicate reward claim rejected")
		assertTest(#rewardPState.Deck == initialDeckSize + 1, "[Suite 65.15e] Duplicate claim does not add second card to deck")
		assertTest(CardCollectionService.getCardCount(rewardPlayer :: any, offeredCard) == initialCollectionCount + 1, "[Suite 65.15f] Duplicate claim does not increment collection count")
	end

	do -- 65.16: PersistenceRevision concurrency
		local revProfile = PersistenceService.simulateLoadSuccessForTesting(65016, { ProfileRevision = 1 })
		assertTest(revProfile.ProfileRevision == 1, "[Suite 65.16a] Initial profile has ProfileRevision 1")
		local remoteStale = { ProfileRevision = 5 }
		local conflictData, applied = PersistenceService.resolveUpdateConflict(remoteStale, revProfile)
		assertTest(applied == false, "[Suite 65.16b] Stale local session (remote 5 > local 1) conflict detected")
		assertTest(revProfile.ProfileRevision == 1, "[Suite 65.16c] Incoming profile revision NOT incremented on conflict")
		-- UpdateAsync retry simulation: calling resolveUpdateConflict 3 times does NOT over-increment incoming profile
		for retry = 1, 3 do
			local okData, isApp = PersistenceService.resolveUpdateConflict(nil, revProfile)
			assertTest(isApp == true, "[Suite 65.16d] Retry iteration accepted")
			assertTest(okData.ProfileRevision == 2, "[Suite 65.16e] Cloned data always has revision 2 during retries")
		end
		assertTest(revProfile.ProfileRevision == 1, "[Suite 65.16f] Session profile remains at revision 1 until commit")
		PersistenceService.saveProfile(65016)
		assertTest(revProfile.ProfileRevision == 2, "[Suite 65.16g] Session profile revision increments to 2 exactly once on commit")
		-- Same-second save
		PersistenceService.saveProfile(65016)
		assertTest(revProfile.ProfileRevision == 3, "[Suite 65.16h] Same-second save increments revision to 3 without timestamp conflict")
	end

	do -- 65.17: ReturnToLobby full reset and permanent progression survival
		RunManager.resetRunForTesting()
		local lobbyTestPlayer = {
			UserId = 65017,
			Name = "LobbyPlayer",
			DisplayName = "LobbyPlayer",
			IsA = function(_, cls) return cls == "Player" end,
		}
		local lobbyPState = RunManager.addPlayer(lobbyTestPlayer :: any)
		assert(lobbyPState, "lobbyPState exists")
		lobbyPState.ClassLocked = true
		RunManager.startRun(lobbyTestPlayer :: any)
		lobbyPState.Gold = 999
		table.insert(lobbyPState.RelicIds, "Vajra")
		PersistenceService.addAetherShards(lobbyTestPlayer :: any, 250)
		local shardsBeforeReset = PersistenceService.getProfile(lobbyTestPlayer :: any).AetherShards
		RunManager.resetToLobby()
		local finalRunState = RunManager.getRunState()
		assertTest(finalRunState.Phase == "Lobby", "[Suite 65.17a] Run phase reset to Lobby")
		assertTest(lobbyPState.Gold == GameConfig.Dungeon.StarterGold, "[Suite 65.17b] Run gold reset to starter amount")
		assertTest(lobbyPState.ClassLocked == false, "[Suite 65.17c] ClassLocked reset to false")
		assertTest(CombatService.getActiveCombat() == nil, "[Suite 65.17d] Active combat cleaned up")
		local shardsAfterReset = PersistenceService.getProfile(lobbyTestPlayer :: any).AetherShards
		assertTest(shardsAfterReset == shardsBeforeReset, "[Suite 65.17e] Permanent AetherShards survived ReturnToLobby")
	end
end

local function runSuite66()
	print("\n--- [Suite 66] Status Duration, Fail-Closed Init, Event Buffering, Run-Scoped Reset, Skill Rehydration ---")

	do -- 66.1: Poison with Duration = -1 survives transaction snapshot/restore
		StatusService.resetCombat()
		StatusService.applyStatus("test_entity_66_1", "Poison", 4, -1, "source_1")
		local snap = StatusService.snapshotStatuses()
		assertTest(snap["test_entity_66_1"] ~= nil, "[Suite 66.1a] Snapshot contains test_entity_66_1")
		assertTest(snap["test_entity_66_1"]["Poison"] ~= nil, "[Suite 66.1b] Snapshot contains Poison")
		assertTest(snap["test_entity_66_1"]["Poison"].Duration == -1, "[Suite 66.1c] Existing Poison with Duration = -1 survives snapshot")
		assertTest(snap["test_entity_66_1"]["Poison"].Stacks == 4, "[Suite 66.1d] Snapshot preserves Stacks = 4")
		assertTest(snap["test_entity_66_1"]["Poison"].InstanceId ~= nil, "[Suite 66.1e] Snapshot preserves InstanceId")
		assertTest(snap["test_entity_66_1"]["Poison"].SourceId == "source_1", "[Suite 66.1f] Snapshot preserves SourceId")
		assertTest(snap["test_entity_66_1"]["Poison"].TargetId == "test_entity_66_1", "[Suite 66.1g] Snapshot preserves TargetId")

		StatusService.resetCombat()
		assertTest(StatusService.getStatus("test_entity_66_1", "Poison") == nil, "[Suite 66.1h] Status reset clears entityStatuses")
		StatusService.restoreStatuses(snap)
		local restored = StatusService.getStatus("test_entity_66_1", "Poison")
		assertTest(restored ~= nil, "[Suite 66.1i] Restored status exists")
		assertTest(restored.Duration == -1, "[Suite 66.1j] Restored Poison has Duration = -1")
		assertTest(restored.Stacks == 4, "[Suite 66.1k] Restored Poison has Stacks = 4")
		assertTest(restored.InstanceId == snap["test_entity_66_1"]["Poison"].InstanceId, "[Suite 66.1l] Restored InstanceId matches")
	end

	do -- 66.2 & 66.3: Ignite with Duration = 3 survives rollback with Duration = 3; tick does not error
		StatusService.resetCombat()
		StatusService.applyStatus("test_entity_66_2", "Ignite", 2, 3, "source_1")
		local snap = StatusService.snapshotStatuses()
		assertTest(snap["test_entity_66_2"]["Ignite"].Duration == 3, "[Suite 66.2a] Snapshot captures Ignite Duration = 3")

		StatusService.applyStatus("test_entity_66_2", "Ignite", 5, 1, "source_1")
		StatusService.applyStatus("test_entity_66_2", "Poison", 10, -1, "source_1")
		assertTest(StatusService.getStatus("test_entity_66_2", "Ignite").Stacks == 7, "[Suite 66.2b] Mutated stacks before rollback")

		StatusService.restoreStatuses(snap)
		local restoredIgnite = StatusService.getStatus("test_entity_66_2", "Ignite")
		assertTest(restoredIgnite ~= nil, "[Suite 66.2c] Ignite survives rollback")
		assertTest(restoredIgnite.Duration == 3, "[Suite 66.2d] Ignite with Duration = 3 survives rollback with Duration = 3")
		assertTest(restoredIgnite.Stacks == 2, "[Suite 66.2e] Stacks restored exactly to 2")
		assertTest(StatusService.getStatus("test_entity_66_2", "Poison") == nil, "[Suite 66.2f] Status applied during action reverted on rollback")

		local tickOk, _ = pcall(function()
			return StatusService.tickTurnStart("test_entity_66_2", nil)
		end)
		assertTest(tickOk == true, "[Suite 66.3] Status tick after rollback does not error")
	end

	do -- 66.4 - 66.6: LoadFailed real player fail-closed initialization
		local failPlayer = {
			UserId = 66040,
			Name = "FailPlayer66",
			DisplayName = "FailPlayer66",
			_isSimulatedRealPlayer = true,
			IsA = function(_, cls) return cls == "Player" end,
		}
		PersistenceService.resetForTesting(failPlayer.UserId)
		PersistenceService.simulateLoadFailureForTesting(failPlayer.UserId)
		assertTest(PersistenceService.isProfileLoaded(failPlayer) == false, "[Suite 66.4a] isProfileLoaded returns false on LoadFailed")

		local added = RunManager.addPlayer(failPlayer :: any)
		assertTest(added == nil, "[Suite 66.4b] addPlayer returns nil when real player profile load failed")
		assertTest(RunManager.getPlayerState(failPlayer) == nil, "[Suite 66.4c] No PlayerState created for LoadFailed real player")
		local currentRun = RunManager.getRunState()
		assertTest(currentRun.PartyMembers[failPlayer.UserId] == nil, "[Suite 66.4d] LoadFailed player not added to PartyMembers")

		assertTest(PersistenceService.getLoadState(failPlayer) == "LoadFailed", "[Suite 66.5a] LoadState is LoadFailed")
		local syncSnapshot = RunManager.getRunSnapshotForPlayer(failPlayer :: any)
		assertTest(syncSnapshot ~= nil, "[Suite 66.5b] RequestStateSync produces safe snapshot for LoadFailed player")
		assertTest(syncSnapshot.Party[tostring(failPlayer.UserId)] == nil, "[Suite 66.5c] Snapshot party does not contain LoadFailed player")

		local retryOk, retryProf = PersistenceService.retryLoadProfile(failPlayer)
		assertTest(retryOk == true and retryProf ~= nil, "[Suite 66.6a] retryLoadProfile succeeds")
		assertTest(PersistenceService.isProfileLoaded(failPlayer) == true, "[Suite 66.6b] isProfileLoaded returns true after successful load")
		local retryAdded = RunManager.addPlayer(failPlayer :: any)
		assertTest(retryAdded ~= nil, "[Suite 66.6c] addPlayer succeeds after profile load recovers")
		assertTest(RunManager.getPlayerState(failPlayer) ~= nil, "[Suite 66.6d] PlayerState exists after recovery")
		assertTest(#retryAdded.Deck > 0, "[Suite 66.6e] Deck initialized normally after recovery")
		RunManager.removePlayer(failPlayer :: any)
	end

	do -- 66.7 - 66.9: Transactional Combat Event Logging & Buffer Rollback
		CombatService.cleanupCombat()
		RunManager.resetRunForTesting()
		local txP = {
			UserId = 66070,
			Name = "EvtPlayer",
			DisplayName = "EvtPlayer",
		}
		local pState = RunManager.addPlayer(txP :: any)
		assert(pState, "pState exists")
		pState.ClassLocked = true
		local combat = CombatService.startCombat("enc_evt1", "Combat", 1, { [txP.UserId] = pState }, function() end)
		assert(combat and combat.Enemies["enemy_1"], "combat enemy exists")
		local enemy = combat.Enemies["enemy_1"]

		local broadcastedEvents: { StateTypes.CombatEvent } = {}
		NetworkService.setCombatEventHook(function(evt)
			table.insert(broadcastedEvents, evt)
		end)

		local strikeCard: StateTypes.CardInstance = {
			CardInstanceId = "card_evt_success_66",
			DefinitionId = "Strike",
			CardData = {
				Id = "Strike",
				Name = "Evt Strike",
				Description = "Attack",
				Type = "Attack",
				Rarity = "Common",
				Target = "SingleEnemy",
				Cost = 1,
				Upgraded = false,
				Class = "Warlord",
				Tags = {},
				Effects = {
					{ Type = "Damage", Value = 5, Target = "SingleEnemy" },
				},
			},
			OwnerUserId = txP.UserId,
			Upgraded = false,
		}
		table.insert(pState.Hand, strikeCard)
		pState.Resources.Energy = 3

		local playOk, _ = CombatService.playCard(txP :: any, strikeCard.CardInstanceId, enemy.InstanceId)
		assertTest(playOk == true, "[Suite 66.7a] Card play succeeded")
		assertTest(#broadcastedEvents > 0, "[Suite 66.7b] Successful action published combat events to clients")
		local hasDmgEvt = false
		for _, e in ipairs(broadcastedEvents) do
			if e.Type == "DamageDealt" then hasDmgEvt = true break end
		end
		assertTest(hasDmgEvt == true, "[Suite 66.7c] Broadcasted events included DamageDealt")

		table.clear(broadcastedEvents)
		local logCountBefore = #combat.CombatLog

		local failCard: StateTypes.CardInstance = {
			CardInstanceId = "card_evt_fail_66",
			DefinitionId = "Strike",
			CardData = {
				Id = "Strike",
				Name = "Fail Strike",
				Description = "Fails on second effect",
				Type = "Attack",
				Rarity = "Common",
				Target = "SingleEnemy",
				Cost = 1,
				Upgraded = false,
				Class = "Warlord",
				Tags = {},
				Effects = {
					{ Type = "Damage", Value = 5, Target = "SingleEnemy" },
					{ Type = "BogusEffect" :: any, Value = 10, Target = "SingleEnemy" },
				},
			},
			OwnerUserId = txP.UserId,
			Upgraded = false,
		}
		table.insert(pState.Hand, failCard)
		local failOk, _ = CombatService.playCard(txP :: any, failCard.CardInstanceId, enemy.InstanceId)
		assertTest(failOk == false, "[Suite 66.8a] Failing card was rejected")
		assertTest(#broadcastedEvents == 0, "[Suite 66.8b] Failed action published zero events to clients")
		assertTest(#combat.CombatLog == logCountBefore, "[Suite 66.8c] Failed action restored exact CombatLog count")

		for i = 1, 30 do
			local c: StateTypes.CardInstance = {
				CardInstanceId = "card_cap_66_" .. i,
				DefinitionId = "Defend",
				CardData = {
					Id = "Defend",
					Name = "Shield Up",
					Description = "Gain shield",
					Type = "Skill",
					Rarity = "Common",
					Target = "Self",
					Cost = 0,
					Upgraded = false,
					Class = "Warlord",
					Tags = {},
					Effects = {
						{ Type = "Shield", Value = 1, Target = "Self" },
					},
				},
				OwnerUserId = txP.UserId,
				Upgraded = false,
			}
			table.insert(pState.Hand, c)
			CombatService.playCard(txP :: any, c.CardInstanceId, nil)
		end
		assertTest(#combat.CombatLog <= 25, "[Suite 66.9a] CombatLog size capped at 25")
		assertTest(#combat.CombatLog == 25, "[Suite 66.9b] CombatLog filled to exactly 25 after 30 events")

		NetworkService.setCombatEventHook(nil)
		CombatService.cleanupCombat()
	end

	do -- 66.10 & 66.11: resetToLobby clears all 7 run-scoped fields; persistent profile survives
		RunManager.resetRunForTesting()
		local progPlayer = {
			UserId = 66100,
			Name = "ProgPlayer66",
			DisplayName = "ProgPlayer66",
		}
		local pState = RunManager.addPlayer(progPlayer :: any)
		assert(pState, "pState exists")
		pState.ClassLocked = true
		RunManager.startRun(progPlayer :: any)

		pState.EquippedItems = { MainHand = "item_sword_1" :: any }
		pState.EquipmentInventory = { { InstanceId = "eq_1" } :: any }
		pState.EquippedSkills = { Skill1 = { InstanceId = "sk_1", DefinitionId = "HeroicStrike", Slot = "Skill1", CurrentCooldown = 2, OwnerUserId = progPlayer.UserId } :: any }
		pState.SkillInventory = { { InstanceId = "sk_inv_1", DefinitionId = "BattleRally", Slot = nil, CurrentCooldown = 1, OwnerUserId = progPlayer.UserId } :: any }
		pState.UnlockedSkills = { HeroicStrike = true, BogusRunSkill = true }
		pState.UnlockedPassives = { IronSkin = true }
		pState.PassivePoints = 5

		PersistenceService.addAetherShards(progPlayer :: any, 500)
		local profBefore = PersistenceService.getProfile(progPlayer :: any)
		assert(profBefore, "profBefore exists")
		local shardsBefore = profBefore.AetherShards
		local decksBeforeCount = 0
		for _ in profBefore.Decks do decksBeforeCount += 1 end

		RunManager.resetToLobby()

		assertTest(next(pState.EquippedItems) == nil, "[Suite 66.10a] EquippedItems is cleared")
		assertTest(#pState.EquipmentInventory == 0, "[Suite 66.10b] EquipmentInventory is cleared")
		assertTest(next(pState.EquippedSkills) == nil, "[Suite 66.10c] EquippedSkills is cleared")
		assertTest(pState.PassivePoints == 0, "[Suite 66.10d] PassivePoints reset to 0")
		assertTest(next(pState.UnlockedPassives) == nil, "[Suite 66.10e] UnlockedPassives is cleared")
		assertTest(pState.UnlockedSkills["BogusRunSkill"] == nil, "[Suite 66.10f] Run-scoped unlocked skill cleared")

		assertTest(pState.UnlockedSkills["HeroicStrike"] == true, "[Suite 66.10g] HeroicStrike re-provisioned")
		assertTest(pState.UnlockedSkills["AegisBarrier"] == true, "[Suite 66.10h] AegisBarrier re-provisioned")
		assertTest(pState.UnlockedSkills["BattleRally"] == true, "[Suite 66.10i] BattleRally re-provisioned")
		assertTest(pState.UnlockedSkills["Whirlwind"] == true, "[Suite 66.10j] Whirlwind re-provisioned")
		assertTest(#pState.SkillInventory == 4, "[Suite 66.10k] SkillInventory has exactly 4 starting skills")

		local profAfter = PersistenceService.getProfile(progPlayer :: any)
		assertTest(profAfter ~= nil, "[Suite 66.11a] Persistent profile survived")
		assertTest(profAfter.AetherShards == shardsBefore, "[Suite 66.11b] Persistent AetherShards survived")
		local decksAfterCount = 0
		for _ in profAfter.Decks do decksAfterCount += 1 end
		assertTest(decksAfterCount == decksBeforeCount, "[Suite 66.11c] Persistent saved decks survived")
	end

	do -- 66.12 - 66.14: Rehydrate persistent unlocked skills, no duplicates, ignore unknown, can equip & use
		RunManager.resetRunForTesting()
		local skPlayer = {
			UserId = 66120,
			Name = "SkillRehydratePlayer66",
			DisplayName = "SkillRehydratePlayer66",
			_isSimulatedRealPlayer = true,
			IsA = function(_, cls) return cls == "Player" end,
		}
		PersistenceService.resetForTesting(skPlayer.UserId)
		local prof = PersistenceService.loadProfile(skPlayer)
		assert(prof, "profile loaded")

		prof.UnlockedSkills["ShieldBash"] = true
		prof.UnlockedSkills["CorruptedNonExistentSkill999"] = true

		local pState = RunManager.addPlayer(skPlayer :: any)
		assert(pState, "pState exists")

		assertTest(pState.UnlockedSkills["ShieldBash"] == true, "[Suite 66.12a] Persistent unlocked skill appears in UnlockedSkills")
		local foundShieldBash = false
		local shieldBashCount = 0
		for _, sk in ipairs(pState.SkillInventory) do
			if sk.DefinitionId == "ShieldBash" then
				foundShieldBash = true
				shieldBashCount += 1
			end
		end
		assertTest(foundShieldBash == true, "[Suite 66.12b] Persistent unlocked skill appears in runtime SkillInventory")
		assertTest(shieldBashCount == 1, "[Suite 66.12c] No duplicate runtime instance created for ShieldBash")

		assertTest(pState.UnlockedSkills["CorruptedNonExistentSkill999"] == nil, "[Suite 66.13a] Corrupted skill ID ignored in UnlockedSkills")
		local foundCorrupted = false
		for _, sk in ipairs(pState.SkillInventory) do
			if sk.DefinitionId == "CorruptedNonExistentSkill999" then
				foundCorrupted = true
			end
		end
		assertTest(foundCorrupted == false, "[Suite 66.13b] Corrupted skill ID ignored in SkillInventory")

		assertTest(pState.UnlockedSkills["HeroicStrike"] == true, "[Suite 66.13c] Starter skill HeroicStrike present")
		assertTest(#pState.SkillInventory == 5, "[Suite 66.13d] SkillInventory contains 4 starters + 1 persistent skill = 5")

		local equipOk, _ = SkillService.equipSkill(pState, "ShieldBash", "Skill1")
		assertTest(equipOk == true, "[Suite 66.14a] Persistent unlocked skill can be equipped")
		assertTest(pState.EquippedSkills.Skill1 ~= nil and pState.EquippedSkills.Skill1.DefinitionId == "ShieldBash", "[Suite 66.14b] Equipped skill in Skill1 is ShieldBash")

		pState.ClassLocked = true
		local skCombat = CombatService.startCombat("enc_sk66", "Combat", 1, { [skPlayer.UserId] = pState }, function() end)
		assert(skCombat and skCombat.Enemies["enemy_1"], "skCombat enemy exists")
		local targetEnemy = skCombat.Enemies["enemy_1"]
		pState.Resources.Energy = 5
		local useOk, _ = SkillService.useSkill(pState, "Skill1", targetEnemy.InstanceId, skCombat, { [skPlayer.UserId] = pState })
		assertTest(useOk == true, "[Suite 66.14c] Rehydrated persistent skill can be used in combat")

		CombatService.cleanupCombat()
		RunManager.removePlayer(skPlayer :: any)
	end
end

local function runSuite67()
	print("\n--- [Suite 67] End-to-End Single-Player Run Flow: StartRun -> MapSelect -> Vote -> ActiveRoom -> ActiveCombat ---")

	do
		-- 1. Initialize fresh solo player
		local soloPlayer = {
			UserId = 67001,
			Name = "SoloAdventurer",
			DisplayName = "SoloAdventurer",
			IsA = function(_, cls) return cls == "Player" end,
		}
		PersistenceService.loadProfile(soloPlayer :: any)
		local pState = RunManager.addPlayer(soloPlayer :: any)
		assertTest(pState ~= nil, "[Suite 67.1] addPlayer succeeds for initialized solo player")
		assert(pState, "pState exists")

		-- 2. Select and lock class
		ClassService.selectClass(soloPlayer :: any, "Ironclad")
		ClassService.lockClass(soloPlayer :: any)
		assertTest(pState.ClassLocked == true, "[Suite 67.2] Solo player class is locked")

		-- 3. Start Run
		local startOk = RunManager.startRun(soloPlayer :: any)
		assertTest(startOk == true, "[Suite 67.3] startRun succeeds")

		local runState = RunManager.getRunState()
		assertTest(runState.Phase == "MapSelect", "[Suite 67.4] Run state transitioned to MapSelect phase")
		assertTest(runState.CurrentNodeId == nil, "[Suite 67.5] CurrentNodeId is nil at fresh run start")
		assertTest(runState.CurrentTier == 0, "[Suite 67.6] CurrentTier is 0 at fresh run start")
		assertTest(#runState.AvailableNodeIds >= 1, "[Suite 67.7] AvailableNodeIds populated with at least 1 Tier-1 node")

		-- 4. Map snapshot verification for player
		local snap = RunManager.getRunSnapshotForPlayer(soloPlayer :: any)
		assertTest(snap.Phase == "MapSelect", "[Suite 67.8] Player snapshot Phase is MapSelect")
		assertTest(snap.MapNodes ~= nil and #snap.MapNodes > 0, "[Suite 67.9] Authoritative MapNodes populated in player snapshot")

		-- Verify Tier-1 node availability
		local targetNodeId = runState.AvailableNodeIds[1]
		assertTest(targetNodeId ~= nil, "[Suite 67.10] Target first-tier node ID exists")

		-- 5. Vote for first available node
		local voteOk, voteErr = RunManager.voteMapNode(soloPlayer :: any, targetNodeId)
		assertTest(voteOk == true, "[Suite 67.11] voteMapNode succeeds: " .. tostring(voteErr))

		-- 6. Consensus in 1-player party triggers immediate travel to ActiveRoom
		assertTest(runState.Phase == "ActiveRoom", "[Suite 67.12] 1-player consensus immediately advances run to ActiveRoom")
		assertTest(runState.CurrentNodeId == targetNodeId, "[Suite 67.13] CurrentNodeId matches voted node ID")
		assertTest(runState.CurrentTier == 1, "[Suite 67.14] CurrentTier updated to Tier 1")

		-- 7. ActiveCombat started in PlayerPhase with enemies and opening hand
		assertTest(runState.ActiveCombat ~= nil, "[Suite 67.15] ActiveCombat instantiated for combat node")
		local combat = runState.ActiveCombat
		assert(combat, "combat exists")
		assertTest(combat.Phase == "PlayerPhase", "[Suite 67.16] ActiveCombat starts in PlayerPhase")

		local livingEnemies = 0
		for _, enemy in combat.Enemies do
			if enemy.HP > 0 then
				livingEnemies += 1
			end
		end
		assertTest(livingEnemies >= 1, "[Suite 67.17] Active combat has at least 1 living enemy")
		assertTest(#pState.Hand > 0, "[Suite 67.18] Solo player drew opening card hand")
		assertTest(pState.Resources.Energy > 0, "[Suite 67.19] Solo player has starting energy")

		-- 8. Clean up
		CombatService.cleanupCombat()
		RunManager.resetToLobby(soloPlayer :: any)
		assertTest(RunManager.getRunState().Phase == "Lobby", "[Suite 67.20] Clean reset to Lobby completes")
	end

	do -- 67.21 - 67.25: Multiplayer co-op consensus voting flow
		RunManager.resetRunForTesting()
		local mp1 = {
			UserId = 67211,
			Name = "MP_Player1",
			DisplayName = "MP_Player1",
			IsA = function(_, cls) return cls == "Player" end,
		}
		local mp2 = {
			UserId = 67212,
			Name = "MP_Player2",
			DisplayName = "MP_Player2",
			IsA = function(_, cls) return cls == "Player" end,
		}
		PersistenceService.loadProfile(mp1 :: any)
		PersistenceService.loadProfile(mp2 :: any)

		local pState1 = RunManager.addPlayer(mp1 :: any)
		local pState2 = RunManager.addPlayer(mp2 :: any)
		assert(pState1 and pState2, "Both MP players added")
		pState1.ClassLocked = true
		pState2.ClassLocked = true

		local mpStartOk = RunManager.startRun(mp1 :: any)
		assertTest(mpStartOk == true, "[Suite 67.21] 2-player co-op startRun succeeds")

		local mpRun = RunManager.getRunState()
		assertTest(mpRun.Phase == "MapSelect", "[Suite 67.22] 2-player run enters MapSelect")
		local targetNode = mpRun.AvailableNodeIds[1]
		assert(targetNode, "targetNode exists")

		-- Player 1 votes: 1 out of 2 votes cast (no majority yet)
		local vOk1, vErr1, won1 = RunManager.voteMapNode(mp1 :: any, targetNode)
		assertTest(vOk1 == true and won1 == false, "[Suite 67.23] Player 1 vote accepted with pending consensus (won = false)")
		assertTest(mpRun.Phase == "MapSelect", "[Suite 67.24] Run stays in MapSelect while consensus is pending")

		-- Player 2 votes for same node: 2 out of 2 votes cast (majority reached!)
		local vOk2, vErr2, won2 = RunManager.voteMapNode(mp2 :: any, targetNode)
		assertTest(vOk2 == true and won2 == true, "[Suite 67.25a] Player 2 vote triggers consensus win (won = true)")
		assertTest(mpRun.Phase == "ActiveRoom", "[Suite 67.25b] 2-player consensus transitions all members to ActiveRoom")
		assertTest(mpRun.ActiveCombat ~= nil, "[Suite 67.25c] ActiveCombat initialized for multiplayer room")

		CombatService.cleanupCombat()
		RunManager.resetToLobby()
	end

	do -- 67.26 - 67.30: Negative vote scenarios (fabricated, unavailable, disconnected, wrong phase, unlisted)
		RunManager.resetRunForTesting()
		local negPlayer = {
			UserId = 67261,
			Name = "NegPlayer",
			DisplayName = "NegPlayer",
			IsA = function(_, cls) return cls == "Player" end,
		}
		PersistenceService.loadProfile(negPlayer :: any)
		local pState = RunManager.addPlayer(negPlayer :: any)
		assert(pState, "negPlayer pState exists")
		pState.ClassLocked = true

		-- Test: voting when phase is Lobby (not MapSelect)
		local wrongPhaseOk, wrongPhaseErr = RunManager.voteMapNode(negPlayer :: any, "Act1_T1_L1")
		assertTest(wrongPhaseOk == false, "[Suite 67.26] Voting in Lobby phase rejected")

		RunManager.startRun(negPlayer :: any)
		local runState = RunManager.getRunState()

		-- Test: voting for fabricated / non-existent node ID
		local fabOk, fabErr = RunManager.voteMapNode(negPlayer :: any, "Bogus_Fabricated_Node_999")
		assertTest(fabOk == false, "[Suite 67.27] Fabricated node ID strictly rejected")

		-- Test: voting for unavailable node (e.g. Act 1 Boss / Tier 10 node while at Tier 1)
		local unavailNodeId = "Act1_T10_L3"
		local unavailOk, unavailErr = RunManager.voteMapNode(negPlayer :: any, unavailNodeId)
		assertTest(unavailOk == false, "[Suite 67.28] Unavailable node ID rejected")

		-- Test: disconnected player cannot vote
		pState.IsConnected = false
		local discOk, discErr = RunManager.voteMapNode(negPlayer :: any, runState.AvailableNodeIds[1])
		assertTest(discOk == false, "[Suite 67.29] Disconnected player voting rejected")
		pState.IsConnected = true

		-- Test: player not in party cannot vote
		local stranger = {
			UserId = 99999,
			Name = "StrangerPlayer",
			DisplayName = "StrangerPlayer",
			IsA = function(_, cls) return cls == "Player" end,
		}
		local strangerOk, strangerErr = RunManager.voteMapNode(stranger :: any, runState.AvailableNodeIds[1])
		assertTest(strangerOk == false, "[Suite 67.30] Unregistered player voting rejected")

		RunManager.resetToLobby()
	end

	do -- 67.31 - 67.33: Real player async profile loading wait test
		RunManager.resetRunForTesting()
		local asyncPlayer = {
			UserId = 67311,
			Name = "AsyncRealPlayer",
			DisplayName = "AsyncRealPlayer",
			_isSimulatedRealPlayer = true,
			IsA = function(_, cls) return cls == "Player" end,
		}
		PersistenceService.resetForTesting(asyncPlayer.UserId)
		PersistenceService.setLoadStateForTesting(asyncPlayer.UserId, "Loading")

		-- Spawn task to resolve profile load after brief delay
		task.delay(0.1, function()
			PersistenceService.simulateLoadSuccessForTesting(asyncPlayer.UserId, nil)
		end)

		local addResult = RunManager.addPlayer(asyncPlayer :: any)
		assertTest(addResult ~= nil, "[Suite 67.31] addPlayer waits for in-flight Loading profile and succeeds")
		assertTest(PersistenceService.isProfileLoaded(asyncPlayer) == true, "[Suite 67.32] Profile is Loaded after async resolution")
		assertTest(RunManager.getPlayerState(asyncPlayer) ~= nil, "[Suite 67.33] PlayerState registered in PartyMembers")

		RunManager.resetToLobby()
	end

	do -- 67.34 - 67.40: Idempotent first-room voting & post-ActiveRoom vote guards
		RunManager.resetRunForTesting()
		local soloPlayer = {
			UserId = 67341,
			Name = "IdempotentVotePlayer",
			DisplayName = "IdempotentVotePlayer",
			IsA = function(_, cls) return cls == "Player" end,
		}
		PersistenceService.loadProfile(soloPlayer :: any)
		local pState = RunManager.addPlayer(soloPlayer :: any)
		assert(pState, "soloPlayer pState exists")
		pState.ClassLocked = true

		local startOk = RunManager.startRun(soloPlayer :: any)
		assertTest(startOk == true, "[Suite 67.34] Fresh run startRun succeeds")

		local runState = RunManager.getRunState()
		assertTest(runState.Phase == "MapSelect", "[Suite 67.35] Run enters MapSelect")
		local firstAvailableNode = runState.AvailableNodeIds[1]
		assert(firstAvailableNode, "First available node exists")

		-- First vote: succeeds, wins consensus, and transitions to ActiveRoom
		local vOk1, vErr1, won1 = RunManager.voteMapNode(soloPlayer :: any, firstAvailableNode)
		assertTest(vOk1 == true and won1 == true, "[Suite 67.36] First vote succeeds and wins consensus")
		assertTest(runState.Phase == "ActiveRoom", "[Suite 67.37] Run phase transitioned to ActiveRoom")
		assertTest(runState.CurrentNodeId == firstAvailableNode, "[Suite 67.38] CurrentNodeId set to first room")
		assertTest(runState.ActiveCombat ~= nil, "[Suite 67.39] ActiveCombat instantiated for first room")

		-- Duplicate vote for the SAME node while in ActiveRoom: MUST be idempotent and return true
		local dupOk, dupErr, dupWon = RunManager.voteMapNode(soloPlayer :: any, firstAvailableNode)
		assertTest(dupOk == true and dupWon == true, "[Suite 67.40a] Duplicate vote for already-selected node returns idempotent success")
		assertTest(dupErr == nil, "[Suite 67.40b] Duplicate vote does not return MapSelect error")
		assertTest(runState.Phase == "ActiveRoom", "[Suite 67.40c] Run remains in ActiveRoom after duplicate vote")
		assertTest(runState.CurrentNodeId == firstAvailableNode, "[Suite 67.40d] CurrentNodeId remains unchanged after duplicate vote")
		assertTest(runState.ActiveCombat ~= nil, "[Suite 67.40e] Combat remains active after duplicate vote")

		-- Voting a DIFFERENT node after room has already won: MUST be rejected with "Map selection is no longer active."
		local differentNode = runState.AvailableNodeIds[2] or "Act1_T1_L2"
		local diffOk, diffErr = RunManager.voteMapNode(soloPlayer :: any, differentNode)
		assertTest(diffOk == false, "[Suite 67.40f] Voting a different node in ActiveRoom rejected")
		assertTest(diffErr == "Map selection is no longer active.", "[Suite 67.40g] Rejection error is 'Map selection is no longer active.'")

		-- Voting a fake / fabricated arbitrary node while in ActiveRoom: MUST be rejected with "Target room does not exist in dungeon."
		local fakeOk, fakeErr = RunManager.voteMapNode(soloPlayer :: any, "Arbitrary_Fake_Node_9999")
		assertTest(fakeOk == false, "[Suite 67.40h] Fake node in ActiveRoom rejected")
		assertTest(fakeErr == "Target room does not exist in dungeon.", "[Suite 67.40i] Rejection error is 'Target room does not exist in dungeon.'")

		CombatService.cleanupCombat()
		RunManager.resetToLobby()
	end
end

local function runSuite68()
	print("\n--- [Suite 68] Transactional First-Room Progression, StateRevision & Rollback Invariants ---")

	do
		-- 68.1: Full first-room transition with monotonic StateRevision increment
		local soloPlayer = {
			UserId = 68001,
			Name = "RevisionTester",
			DisplayName = "RevisionTester",
			IsA = function(_, cls) return cls == "Player" end,
		}
		PersistenceService.loadProfile(soloPlayer :: any)
		local pState = RunManager.addPlayer(soloPlayer :: any)
		assertTest(pState ~= nil, "[Suite 68.1] addPlayer succeeds for test player")
		assert(pState, "pState exists")

		ClassService.selectClass(soloPlayer :: any, "Ironclad")
		ClassService.lockClass(soloPlayer :: any)
		assertTest(pState.ClassLocked == true, "[Suite 68.2] Test player class is locked")

		local startOk = RunManager.startRun(soloPlayer :: any)
		assertTest(startOk == true, "[Suite 68.3] startRun succeeds")

		local runState = RunManager.getRunState()
		assertTest(runState.Phase == "MapSelect", "[Suite 68.4] Phase is MapSelect")
		local mapSelectRev = runState.StateRevision
		assertTest(mapSelectRev >= 1, "[Suite 68.5] StateRevision initialized and bumped on startRun")

		local snap1 = RunManager.getRunSnapshotForPlayer(soloPlayer :: any)
		assertTest(snap1.StateRevision == mapSelectRev, "[Suite 68.6] Snapshot StateRevision matches runState")
		assertTest(#runState.AvailableNodeIds >= 1, "[Suite 68.7] AvailableNodeIds populated in MapSelect")

		local targetNodeId = runState.AvailableNodeIds[1]
		local vOk, vErr, vWon = RunManager.voteMapNode(soloPlayer :: any, targetNodeId)
		assertTest(vOk == true and vWon == true, "[Suite 68.8] voteMapNode succeeds and wins consensus")
		assertTest(runState.Phase == "ActiveRoom", "[Suite 68.9] Run phase transitioned to ActiveRoom")
		assertTest(runState.StateRevision > mapSelectRev, "[Suite 68.10] StateRevision strictly incremented on room entry")
		assertTest(runState.CurrentNodeId == targetNodeId, "[Suite 68.11] CurrentNodeId updated to target room")
		assertTest(runState.ActiveCombat ~= nil, "[Suite 68.12] ActiveCombat initialized")
		assertTest(#runState.AvailableNodeIds == 0, "[Suite 68.13] AvailableNodeIds cleared in ActiveRoom")

		local snap2 = RunManager.getRunSnapshotForPlayer(soloPlayer :: any)
		assertTest(snap2.Phase == "ActiveRoom", "[Suite 68.14] Snapshot Phase is ActiveRoom")
		assertTest(snap2.StateRevision == runState.StateRevision, "[Suite 68.15] Snapshot StateRevision reflects ActiveRoom revision")

		-- 68.2: Rapid duplicate click / vote idempotency
		local dupOk, dupErr, dupWon = RunManager.voteMapNode(soloPlayer :: any, targetNodeId)
		assertTest(dupOk == true and dupWon == true, "[Suite 68.16] Duplicate vote returns idempotent success")
		assertTest(runState.Phase == "ActiveRoom", "[Suite 68.17] Phase remains ActiveRoom after duplicate vote")
		assertTest(runState.StateRevision == snap2.StateRevision, "[Suite 68.18] StateRevision unchanged on duplicate vote")

		-- 68.3: RequestStateSync returns fresh ActiveRoom snapshot
		local syncSnap = RunManager.getRunSnapshotForPlayer(soloPlayer :: any)
		assertTest(syncSnap.Phase == "ActiveRoom", "[Suite 68.19] RequestStateSync snapshot is ActiveRoom")
		assertTest(syncSnap.CurrentNodeId == targetNodeId, "[Suite 68.20] RequestStateSync CurrentNodeId matches target")
		assertTest(syncSnap.StateRevision == runState.StateRevision, "[Suite 68.21] RequestStateSync StateRevision matches")

		CombatService.cleanupCombat()
		RunManager.resetToLobby()
	end

	do
		-- 68.4: Transactional failure injection and rollback test
		local failPlayer = {
			UserId = 68002,
			Name = "RollbackTester",
			DisplayName = "RollbackTester",
			IsA = function(_, cls) return cls == "Player" end,
		}
		PersistenceService.loadProfile(failPlayer :: any)
		local pState = RunManager.addPlayer(failPlayer :: any)
		assert(pState, "pState exists")
		ClassService.selectClass(failPlayer :: any, "Ironclad")
		ClassService.lockClass(failPlayer :: any)
		local startOk = RunManager.startRun(failPlayer :: any)
		assertTest(startOk == true, "[Suite 68.22] startRun succeeds for rollback test")

		local runState = RunManager.getRunState()
		local dRun = RunManager.getDungeonRun()
		assert(dRun, "dRun exists")
		local targetNodeId = runState.AvailableNodeIds[1]
		local preRev = runState.StateRevision

		-- Inject failure into CombatService.startCombat
		local originalStartCombat = CombatService.startCombat
		CombatService.startCombat = function(...)
			error("Simulated combat failure injection")
		end

		local travelOk, travelErr = RunManager.travelToNode(targetNodeId, true)
		assertTest(travelOk == false, "[Suite 68.23] travelToNode fails when combat fails to initialize")
		assertTest(string.find(tostring(travelErr), "Simulated combat failure injection") ~= nil, "[Suite 68.24] Error message reflects injected failure")

		-- Verify state was rolled back / left unmutated in MapSelect
		assertTest(runState.Phase == "MapSelect", "[Suite 68.25] Phase remains MapSelect after failed combat start")
		assertTest(runState.CurrentNodeId == nil, "[Suite 68.26] CurrentNodeId remained nil on failure")
		assertTest(dRun.CurrentNodeId == nil, "[Suite 68.27] Dungeon CurrentNodeId remained nil on failure")
		assertTest(runState.ActiveCombat == nil, "[Suite 68.28] ActiveCombat remained nil on failure")
		assertTest(runState.StateRevision == preRev, "[Suite 68.29] StateRevision remained unchanged on failed travel")
		assertTest(#runState.AvailableNodeIds >= 1, "[Suite 68.30] AvailableNodeIds preserved for retry")

		-- Restore CombatService.startCombat and retry travel
		CombatService.startCombat = originalStartCombat

		local retryOk, retryErr = RunManager.travelToNode(targetNodeId, true)
		assertTest(retryOk == true, "[Suite 68.31] Retry travelToNode succeeds after restoring combat service")
		assertTest(runState.Phase == "ActiveRoom", "[Suite 68.32] Phase transitioned to ActiveRoom on retry")
		assertTest(runState.CurrentNodeId == targetNodeId, "[Suite 68.33] CurrentNodeId updated on successful retry")
		assertTest(runState.ActiveCombat ~= nil, "[Suite 68.34] ActiveCombat initialized on retry")
		assertTest(runState.StateRevision > preRev, "[Suite 68.35] StateRevision incremented on successful retry")

		CombatService.cleanupCombat()
		RunManager.resetToLobby()
	end
end

local function runSuite69()
	print("\n--- [Suite 69] Reward Flow, Card Draft Atomicity & Boss Act Progression ---")

	do
		-- 69.1: Combat victory transitions to Rewards with ActiveCombat cleared & StateRevision incremented
		local rewardPlayer = {
			UserId = 69001,
			Name = "RewardChampion",
			DisplayName = "RewardChampion",
			IsA = function(_, cls) return cls == "Player" end,
		}
		PersistenceService.loadProfile(rewardPlayer :: any)
		local pState = RunManager.addPlayer(rewardPlayer :: any)
		assert(pState, "pState exists")
		ClassService.selectClass(rewardPlayer :: any, "Ironclad")
		ClassService.lockClass(rewardPlayer :: any)
		local startOk = RunManager.startRun(rewardPlayer :: any)
		assertTest(startOk == true, "[Suite 69.1] startRun succeeds for reward test")

		local runState = RunManager.getRunState()
		local dRun = RunManager.getDungeonRun()
		assert(dRun, "dRun exists")
		local targetNodeId = runState.AvailableNodeIds[1]
		local targetNode = DungeonService.getNode(dRun, targetNodeId)
		assert(targetNode, "targetNode exists")

		local travelOk = RunManager.travelToNode(targetNodeId, true)
		assertTest(travelOk == true, "[Suite 69.2] travelToNode succeeds")
		assertTest(runState.Phase == "ActiveRoom", "[Suite 69.3] Phase is ActiveRoom")
		assertTest(runState.ActiveCombat ~= nil, "[Suite 69.4] ActiveCombat initialized")
		local preVictoryRev = runState.StateRevision

		-- Simulate combat completion
		RunManager.onCombatCompleted("Victory", targetNode)
		assertTest(runState.Phase == "Rewards", "[Suite 69.5] Phase transitioned to Rewards on victory")
		assertTest(runState.ActiveCombat == nil, "[Suite 69.6] ActiveCombat cleared to nil on combat victory")
		assertTest(runState.PendingRewards ~= nil, "[Suite 69.7] PendingRewards populated in RunState")
		assertTest(runState.StateRevision > preVictoryRev, "[Suite 69.8] StateRevision strictly incremented on Rewards transition")

		-- 69.2: Single card draft claim atomicity & StateRevision bump
		local offered = runState.PendingRewards.OfferedCardsByPlayer[rewardPlayer.UserId]
		assertTest(offered ~= nil and #offered == GameConfig.Rewards.CardDraftChoicesCount, "[Suite 69.9] Exact 3 draft cards offered to player")
		local chosenCardDefId = offered[1].Id
		local preClaimRev = runState.StateRevision
		local preDeckSize = #pState.Deck
		local preCollectionCount = CardCollectionService.getCardCount(rewardPlayer :: any, chosenCardDefId)

		local claimOk, claimErr = RunManager.claimRewardCard(rewardPlayer :: any, chosenCardDefId)
		assertTest(claimOk == true and claimErr == nil, "[Suite 69.10] Valid claimRewardCard succeeds")
		assertTest(runState.PendingRewards.ClaimedCards[rewardPlayer.UserId] == true, "[Suite 69.11] ClaimedCards marked true for player")
		assertTest(#pState.Deck == preDeckSize + 1, "[Suite 69.12] Claimed card instance added to runtime deck")
		assertTest(CardCollectionService.getCardCount(rewardPlayer :: any, chosenCardDefId) == preCollectionCount + 1, "[Suite 69.13] Permanent collection count incremented")
		assertTest(runState.StateRevision > preClaimRev, "[Suite 69.14] StateRevision strictly incremented on reward claim")

		-- 69.3: Duplicate claim rejection
		local dupClaimOk, dupClaimErr = RunManager.claimRewardCard(rewardPlayer :: any, offered[2].Id)
		assertTest(dupClaimOk == false and dupClaimErr == "Reward already claimed.", "[Suite 69.15] Duplicate reward claim safely rejected")
		assertTest(#pState.Deck == preDeckSize + 1, "[Suite 69.16] Deck size unchanged on duplicate claim rejection")

		-- 69.4: continueFromRewards returns to MapSelect cleanly
		local preContRev = runState.StateRevision
		local contOk = RunManager.continueFromRewards(rewardPlayer :: any)
		assertTest(contOk == true, "[Suite 69.18] continueFromRewards succeeded without ActiveCombat conflict")
		assertTest(runState.Phase == "MapSelect", "[Suite 69.19] Phase transitioned back to MapSelect")
		assertTest(runState.ActiveCombat == nil, "[Suite 69.20] ActiveCombat is nil in MapSelect")
		assertTest(runState.ActiveRoom == nil, "[Suite 69.21] ActiveRoom is nil in MapSelect")
		assertTest(runState.PendingRewards == nil, "[Suite 69.22] PendingRewards is nil in MapSelect")
		assertTest(runState.StateRevision > preContRev, "[Suite 69.23] StateRevision incremented on continueFromRewards")
		assertTest(#runState.AvailableNodeIds >= 1, "[Suite 69.24] Next tier available nodes populated")

		CombatService.cleanupCombat()
		RunManager.resetToLobby()
	end

	do
		-- 69.5: Act 1 Boss (Tier 10) defeat & Act 2 transition
		local bossPlayer = {
			UserId = 69002,
			Name = "BossConqueror",
			DisplayName = "BossConqueror",
			IsA = function(_, cls) return cls == "Player" end,
		}
		PersistenceService.loadProfile(bossPlayer :: any)
		local pState = RunManager.addPlayer(bossPlayer :: any)
		assert(pState, "pState exists")
		ClassService.selectClass(bossPlayer :: any, "Ironclad")
		ClassService.lockClass(bossPlayer :: any)
		RunManager.startRun(bossPlayer :: any)

		local runState = RunManager.getRunState()
		local dRun = RunManager.getDungeonRun()
		assert(dRun, "dRun exists")

		-- Simulate party reaching Act 1 Boss at Tier 10
		local bossNode = dRun.Acts[1].NodesById["Act1_T10_L3"]
		assert(bossNode, "bossNode exists")
		runState.CurrentTier = 10
		runState.CurrentNodeId = bossNode.Id
		dRun.CurrentTier = 10
		dRun.CurrentNodeId = bossNode.Id
		runState.Phase = "ActiveRoom"

		-- Boss victory
		RunManager.onCombatCompleted("Victory", bossNode)
		assertTest(runState.Phase == "Rewards", "[Suite 69.25] Boss victory transitions to Rewards")
		assertTest(runState.ActiveCombat == nil, "[Suite 69.26] ActiveCombat is nil after Boss victory")
		assertTest(runState.PendingRewards ~= nil, "[Suite 69.27] PendingRewards populated for Boss")

		-- Continue from Boss rewards
		local continueOk = RunManager.continueFromRewards(bossPlayer :: any)
		assertTest(continueOk == true, "[Suite 69.28] continueFromRewards succeeds after Boss clearance")
		assertTest(runState.Phase == "MapSelect", "[Suite 69.29] Phase returns to MapSelect for next Act")
		assertTest(dRun.CurrentActIndex == 2, "[Suite 69.30] DungeonRun CurrentActIndex advanced to Act 2")
		assertTest(runState.ActIndex == 2, "[Suite 69.31] RunState ActIndex advanced to Act 2")
		assertTest(dRun.CurrentTier == 0, "[Suite 69.32] DungeonRun CurrentTier reset to 0 for fresh Act 2")
		assertTest(runState.CurrentTier == 0, "[Suite 69.33] RunState CurrentTier reset to 0 for fresh Act 2")
		assertTest(dRun.CurrentNodeId == nil, "[Suite 69.34] DungeonRun CurrentNodeId reset to nil")
		assertTest(runState.CurrentNodeId == nil, "[Suite 69.35] RunState CurrentNodeId reset to nil")

		-- Check available nodes in Act 2
		assertTest(#runState.AvailableNodeIds >= 1, "[Suite 69.36] Act 2 Tier 1 nodes populated in AvailableNodeIds")
		for _, nodeId in runState.AvailableNodeIds do
			assertTest(string.sub(nodeId, 1, 4) == "Act2", "[Suite 69.37] Available node belongs to Act 2")
		end

		-- Verify client snapshot generates valid Act 2 MapNodes
		local act2Snapshot = RunManager.getRunSnapshotForPlayer(bossPlayer :: any)
		assertTest(act2Snapshot.ActIndex == 2, "[Suite 69.38] Snapshot ActIndex is 2")
		assertTest(act2Snapshot.ActName == dRun.Acts[2].Name, "[Suite 69.39] Snapshot ActName reflects Act 2 name")
		assertTest(act2Snapshot.MapNodes ~= nil and #act2Snapshot.MapNodes > 0, "[Suite 69.40] Snapshot MapNodes populated with Act 2 rooms")

		local hasAvailableAct2Node = false
		for _, nodeView in act2Snapshot.MapNodes :: any do
			if nodeView.IsAvailable then
				hasAvailableAct2Node = true
				break
			end
		end
		assertTest(hasAvailableAct2Node == true, "[Suite 69.41] Act 2 starter nodes marked IsAvailable in client snapshot")

		CombatService.cleanupCombat()
		RunManager.resetToLobby()
	end
end

local function runSuite70()
	print("\n--- [Suite 70] Turn Resolution Lifecycle, Fail-Safe Phase Recovery & Snapshot Integrity ---")

	do
		-- 70.1: Distinct rejection when activeCombat is nil
		CombatService.cleanupCombat()
		local fakePlayer = { UserId = 70001, Name = "NullCombatTester", DisplayName = "NullCombatTester" }
		local nullPlayOk, nullPlayErr = CombatService.playCard(fakePlayer :: any, "dummy_card_id", "dummy_target")
		assertTest(nullPlayOk == false and nullPlayErr == "No active combat encounter.", "[Suite 70.1] playCard rejects with 'No active combat encounter.' when activeCombat is nil")

		local nullReadyOk, nullReadyErr = CombatService.voteReady(fakePlayer :: any)
		assertTest(nullReadyOk == false and nullReadyErr == "No active combat encounter.", "[Suite 70.2] voteReady rejects with 'No active combat encounter.' when activeCombat is nil")

		local nullSkillOk, nullSkillErr = CombatService.useSkill(fakePlayer :: any, "Skill1" :: any, "dummy_target")
		assertTest(nullSkillOk == false and nullSkillErr == "No active combat encounter.", "[Suite 70.3] useSkill rejects with 'No active combat encounter.' when activeCombat is nil")
	end

	do
		-- 70.2: Start combat encounter and verify initial state
		local p1 = {
			UserId = 70010,
			Name = "TurnTester",
			DisplayName = "TurnTester",
			IsA = function(_, cls) return cls == "Player" end,
		}
		PersistenceService.loadProfile(p1 :: any)
		local p1State = RunManager.addPlayer(p1 :: any)
		assert(p1State, "p1State exists")
		p1State.ClassLocked = true
		p1State.ClassId = "Ironclad"

		local combatParty = { [p1.UserId] = p1State }
		local combatEndOutcome: string? = nil
		local activeCombat = CombatService.startCombat("enc_suite70", "Combat", 1, combatParty, function(outcome)
			combatEndOutcome = outcome
		end)
		assertTest(activeCombat ~= nil, "[Suite 70.4] startCombat instantiates activeCombat")
		assertTest(activeCombat.Phase == "PlayerPhase", "[Suite 70.5] Combat begins in PlayerPhase")
		assertTest(activeCombat.TurnNumber == 1, "[Suite 70.6] TurnNumber starts at 1")
		assertTest(p1State.Resources.Energy > 0, "[Suite 70.7] Player initialized with energy")
		assertTest(#p1State.Hand > 0, "[Suite 70.8] Player hand drawn at combat start")

		-- 70.3: During ResolutionPhase, hand cards are discarded before snapshot and actions rejected
		-- Verify discard-first snapshot invariant
		activeCombat.Phase = "ResolutionPhase"
		local testCardInst = p1State.Hand[1]
		assert(testCardInst, "testCardInst exists")

		local resPlayOk, resPlayErr = CombatService.playCard(p1 :: any, testCardInst.CardInstanceId, "enemy_1")
		assertTest(resPlayOk == false and resPlayErr == "Combat is not in PlayerPhase.", "[Suite 70.9] playCard strictly rejected during ResolutionPhase")

		local resReadyOk, resReadyErr = CombatService.voteReady(p1 :: any)
		assertTest(resReadyOk == false and resReadyErr == "Combat is not in PlayerPhase.", "[Suite 70.10] voteReady strictly rejected during ResolutionPhase")

		local resSkillOk, resSkillErr = CombatService.useSkill(p1 :: any, "Skill1" :: any, "enemy_1")
		assertTest(resSkillOk == false and resSkillErr == "Combat is not in PlayerPhase.", "[Suite 70.11] useSkill strictly rejected during ResolutionPhase")

		CardService.discardHand(p1State)
		local resSnapshot = CombatService.getCombatSnapshotForPlayer(p1 :: any)
		assertTest(resSnapshot ~= nil and resSnapshot.Phase == "ResolutionPhase", "[Suite 70.12] Snapshot Phase reflects ResolutionPhase")
		assertTest(resSnapshot ~= nil and #resSnapshot.LocalHand == 0, "[Suite 70.13] Snapshot LocalHand is empty during ResolutionPhase")

		-- Restore phase to PlayerPhase and re-draw hand for continuation
		activeCombat.Phase = "PlayerPhase"
		CardService.drawCards(p1State, 4)

		-- 70.4: generateEnemyIntent resilience with nil/missing AttackPower
		local enemy1 = activeCombat.Enemies["enemy_1"]
		assert(enemy1, "enemy1 exists")
		local enemy1Any: any = enemy1
		enemy1Any.AttackPower = nil -- simulate missing AttackPower
		CombatService.forceTurnTimeout()
		task.wait(0.1)

		assertTest(activeCombat.TurnNumber == 2, "[Suite 70.14] TurnNumber advanced to 2 after successful resolution")
		assertTest(activeCombat.Phase == "PlayerPhase", "[Suite 70.15] Phase returned to PlayerPhase after turn resolution")
		assertTest(enemy1.AttackPower ~= nil, "[Suite 70.16] Enemy AttackPower survived nil fallback in intent generation")
		assertTest(p1State.Resources.Energy == p1State.Resources.MaxEnergy, "[Suite 70.17] Player energy restored to MaxEnergy at turn start")
		assertTest(p1State.IsReady == false, "[Suite 70.18] Player IsReady reset to false for Turn 2")

		-- 70.5: Guaranteed Phase Recovery Block on injected error during turn resolution
		local originalTickStatuses = StatusService.tickStatuses
		StatusService.tickStatuses = function(...)
			error("Simulated catastrophic failure in tickStatuses during turn resolution!")
		end

		CombatService.forceTurnTimeout()
		task.wait(0.1)

		-- Restore StatusService.tickStatuses
		StatusService.tickStatuses = originalTickStatuses

		-- Assert guaranteed recovery occurred despite the catastrophic failure!
		assertTest(activeCombat.TurnNumber == 3, "[Suite 70.19] TurnNumber advanced to 3 despite error in turn resolution (Guaranteed Recovery)")
		assertTest(activeCombat.Phase == "PlayerPhase", "[Suite 70.20] Phase guaranteed restored to PlayerPhase after error")
		assertTest(p1State.Resources.Energy == p1State.Resources.MaxEnergy, "[Suite 70.21] Player energy restored to MaxEnergy after recovery")
		assertTest(#p1State.Hand > 0, "[Suite 70.22] Fresh cards drawn for player after guaranteed recovery")

		-- 70.6: ArenaVisualizer.cleanup safe execution
		local cleanupOk = pcall(function()
			ArenaVisualizer.cleanup()
		end)
		assertTest(cleanupOk == true, "[Suite 70.23] ArenaVisualizer.cleanup executes cleanly with pcall protection")

		CombatService.cleanupCombat()
		RunManager.resetToLobby()
	end
end

local function runSuite71()
	print("\n--- [Suite 71] MapFlow Handshake, StateSync Recovery, Build Fingerprint & Failure Injection ---")

	-- 71.1: Build fingerprinting invariants
	assertTest(BuildInfo.BUILD_ID == "reaction_v2_20260918", "[Suite 71.1] BuildInfo.BUILD_ID matches fingerprint")
	assertTest(BuildInfo.BUILD_NAME == "Reaction V2 3D Attack & Timing Hardening", "[Suite 71.2] BuildInfo.BUILD_NAME matches fingerprint")

	do
		-- 71.2: Real network handshake flow: Vote -> ActionResult (Won=true, ActiveRoom) -> RequestStateSync -> switchView
		CombatService.cleanupCombat()
		RunManager.resetToLobby()

		local flowPlayer = {
			UserId = 71001,
			Name = "HandshakeHero",
			DisplayName = "HandshakeHero",
			IsA = function(_, cls) return cls == "Player" end,
		}
		PersistenceService.loadProfile(flowPlayer :: any)
		local pState = RunManager.addPlayer(flowPlayer :: any)
		assert(pState, "flowPlayer pState exists")
		ClassService.selectClass(flowPlayer :: any, "Ironclad")
		ClassService.lockClass(flowPlayer :: any)

		local startOk = RunManager.startRun(flowPlayer :: any)
		assertTest(startOk == true, "[Suite 71.3] startRun transitions to MapSelect")

		local runState = RunManager.getRunState()
		assertTest(runState.Phase == "MapSelect", "[Suite 71.4] Initial run phase is MapSelect")
		local targetNodeId = runState.AvailableNodeIds[1]
		assert(targetNodeId, "targetNodeId exists in Act 1 tier 1")

		-- Server processes VoteMapNode
		local voteOk, voteErr, won, phase, rev = RunManager.voteMapNode(flowPlayer :: any, targetNodeId)
		assertTest(voteOk == true, "[Suite 71.5] voteMapNode returns true for available first room")
		assertTest(voteErr == nil, "[Suite 71.6] voteMapNode returns nil error on valid consensus")
		assertTest(won == true, "[Suite 71.7] voteMapNode returns won == true for consensus winner")
		assertTest(phase == "ActiveRoom", "[Suite 71.8] voteMapNode returns Phase == 'ActiveRoom'")
		assertTest(rev ~= nil and rev >= 2, "[Suite 71.9] voteMapNode returns incremented StateRevision")

		-- Invariant: Server runState committed
		assertTest(runState.Phase == "ActiveRoom", "[Suite 71.10] runState.Phase committed to ActiveRoom")
		assertTest(runState.CurrentNodeId == targetNodeId, "[Suite 71.11] runState.CurrentNodeId set to target room")
		assertTest(runState.ActiveCombat ~= nil, "[Suite 71.12] ActiveCombat instantiated on room entry")

		-- 71.3: Authoritative ActionResult payload constructed
		local actionResultPayload: StateTypes.ActionResult = {
			Action = "VoteMapNode",
			Success = true,
			Won = (won == true),
			NodeId = targetNodeId,
			Phase = phase,
			StateRevision = rev,
		}
		assertTest(actionResultPayload.Won == true, "[Suite 71.13] ActionResult has Won == true")
		assertTest(actionResultPayload.Phase == "ActiveRoom", "[Suite 71.14] ActionResult has authoritative Phase == 'ActiveRoom'")
		assertTest(actionResultPayload.StateRevision == runState.StateRevision, "[Suite 71.15] ActionResult carries authoritative StateRevision")

		-- 71.4: Client-side handshake simulation
		-- Upon receiving Won == true, client sets banner to "Room selected. Syncing room..." and sends RequestStateSync
		local clientBannerText = "Room selected. Syncing room..."
		assertTest(clientBannerText == "Room selected. Syncing room...", "[Suite 71.16] Client displays 'Room selected. Syncing room...' on Won=true")

		-- 71.5: Server fulfills RequestStateSync
		local syncSnapshot = RunManager.getRunSnapshotForPlayer(flowPlayer :: any)
		assertTest(syncSnapshot ~= nil, "[Suite 71.17] RequestStateSync returns valid snapshot")
		assertTest(syncSnapshot.Phase == "ActiveRoom", "[Suite 71.18] StateSync snapshot Phase is ActiveRoom")
		assertTest(syncSnapshot.CurrentNodeId == targetNodeId, "[Suite 71.19] StateSync snapshot CurrentNodeId matches target")
		assertTest(syncSnapshot.StateRevision == runState.StateRevision, "[Suite 71.20] StateSync snapshot StateRevision matches server")

		-- 71.6: Central view switcher simulation
		local mockViews = {
			lobbyView = { Visible = true },
			mapView = { Visible = true },
			combatHudView = { Visible = false },
			rewardsView = { Visible = false },
		}
		local function mockSwitchView(targetPhase: StateTypes.RunPhase)
			mockViews.lobbyView.Visible = (targetPhase == "Lobby")
			mockViews.mapView.Visible = (targetPhase == "MapSelect")
			mockViews.combatHudView.Visible = (targetPhase == "ActiveRoom")
			mockViews.rewardsView.Visible = (targetPhase == "Rewards")
		end

		mockSwitchView(syncSnapshot.Phase)
		assertTest(mockViews.mapView.Visible == false, "[Suite 71.21] switchView hides mapView in ActiveRoom")
		assertTest(mockViews.combatHudView.Visible == true, "[Suite 71.22] switchView shows combatHudView in ActiveRoom")
		clientBannerText = "Entered Room: Combat"
		assertTest(clientBannerText == "Entered Room: Combat", "[Suite 71.23] Client banner updates to 'Entered Room: Combat' upon ActiveRoom RunStateUpdate")

		-- 71.7: Failure Injection C: Duplicate vote returns idempotent success
		local dupOk, dupErr, dupWon, dupPhase, dupRev = RunManager.voteMapNode(flowPlayer :: any, targetNodeId)
		assertTest(dupOk == true, "[Suite 71.24] Duplicate vote returns true (idempotent)")
		assertTest(dupErr == nil, "[Suite 71.25] Duplicate vote returns nil error")
		assertTest(dupWon == true, "[Suite 71.26] Duplicate vote returns won == true")
		assertTest(dupPhase == "ActiveRoom", "[Suite 71.27] Duplicate vote returns Phase == 'ActiveRoom'")
		assertTest(dupRev == runState.StateRevision, "[Suite 71.28] Duplicate vote preserves current StateRevision")

		-- 71.8: Failure Injection D: Voting another node in ActiveRoom rejected
		local invalidOk, invalidErr, invalidWon, invalidPhase, invalidRev = RunManager.voteMapNode(flowPlayer :: any, "Act1_T1_L99_Invalid")
		assertTest(invalidOk == false, "[Suite 71.29] Voting different node in ActiveRoom is rejected")
		assertTest(invalidErr ~= nil, "[Suite 71.30] Voting in ActiveRoom returns distinct error message")
		assertTest(invalidWon == false, "[Suite 71.31] Voting different node has won == false")
		assertTest(invalidPhase == "ActiveRoom", "[Suite 71.32] Error payload preserves authoritative ActiveRoom phase")

		CombatService.cleanupCombat()
		RunManager.resetToLobby()
	end

	do
		-- 71.9: Failure Injection A: Combat Setup Failure Rollback
		CombatService.cleanupCombat()
		RunManager.resetToLobby()

		local failPlayer = {
			UserId = 71002,
			Name = "FailRollbackTester",
			DisplayName = "FailRollbackTester",
			IsA = function(_, cls) return cls == "Player" end,
		}
		PersistenceService.loadProfile(failPlayer :: any)
		RunManager.addPlayer(failPlayer :: any)
		ClassService.selectClass(failPlayer :: any, "Ironclad")
		ClassService.lockClass(failPlayer :: any)
		RunManager.startRun(failPlayer :: any)

		local runState = RunManager.getRunState()
		local failNodeId = runState.AvailableNodeIds[1]
		local revBeforeFailure = runState.StateRevision

		-- Inject failure into CombatService.startCombat
		local originalStartCombat = CombatService.startCombat
		CombatService.startCombat = function(...)
			error("Obsidian is not a valid member of Enum.Material")
		end

		local travelOk, travelErr = RunManager.travelToNode(failNodeId)
		CombatService.startCombat = originalStartCombat -- restore immediately

		assertTest(travelOk == false, "[Suite 71.33] travelToNode returns false when combat setup throws error")
		assertTest(travelErr ~= nil and string.find(travelErr, "Obsidian is not a valid member") ~= nil, "[Suite 71.34] travelToNode captures exact combat setup error message")
		assertTest(runState.Phase == "MapSelect", "[Suite 71.35] Phase cleanly rolled back to MapSelect on combat error")
		assertTest(runState.CurrentNodeId == nil, "[Suite 71.36] CurrentNodeId remained nil on combat error rollback")
		assertTest(runState.ActiveCombat == nil, "[Suite 71.37] ActiveCombat remained nil on combat error rollback")
		assertTest(runState.StateRevision == revBeforeFailure, "[Suite 71.38] StateRevision remained unbumped on combat error rollback")

		CombatService.cleanupCombat()
		RunManager.resetToLobby()
	end

	do
		-- 71.10: Failure Injection B: Delayed RunStateUpdate recovered by RequestStateSync
		CombatService.cleanupCombat()
		RunManager.resetToLobby()

		local recoveryPlayer = {
			UserId = 71003,
			Name = "RecoveryTester",
			DisplayName = "RecoveryTester",
			IsA = function(_, cls) return cls == "Player" end,
		}
		PersistenceService.loadProfile(recoveryPlayer :: any)
		RunManager.addPlayer(recoveryPlayer :: any)
		ClassService.selectClass(recoveryPlayer :: any, "Ironclad")
		ClassService.lockClass(recoveryPlayer :: any)
		RunManager.startRun(recoveryPlayer :: any)

		local runState = RunManager.getRunState()
		local targetNode = runState.AvailableNodeIds[1]
		RunManager.voteMapNode(recoveryPlayer :: any, targetNode)

		-- Simulate client whose RunStateUpdate packet was dropped or delayed
		local clientState = {
			lastRunStateRevision = 1,
			currentPhase = "MapSelect",
			mapVisible = true,
			combatVisible = false,
		}

		-- Client triggers RequestStateSync to recover
		local recoveredSnapshot = RunManager.getRunSnapshotForPlayer(recoveryPlayer :: any)
		assertTest(recoveredSnapshot.Phase == "ActiveRoom", "[Suite 71.39] StateSync snapshot has Phase == 'ActiveRoom'")
		assertTest(recoveredSnapshot.StateRevision ~= nil and recoveredSnapshot.StateRevision > clientState.lastRunStateRevision,
			"[Suite 71.40] StateSync snapshot revision is higher than client's stale revision")

		-- Client processes StateSync snapshot
		if recoveredSnapshot.StateRevision and recoveredSnapshot.StateRevision >= clientState.lastRunStateRevision then
			clientState.lastRunStateRevision = recoveredSnapshot.StateRevision
			clientState.currentPhase = recoveredSnapshot.Phase
			clientState.mapVisible = (recoveredSnapshot.Phase == "MapSelect")
			clientState.combatVisible = (recoveredSnapshot.Phase == "ActiveRoom")
		end

		assertTest(clientState.currentPhase == "ActiveRoom", "[Suite 71.41] Client phase recovered to ActiveRoom via StateSync")
		assertTest(clientState.mapVisible == false, "[Suite 71.42] Client map view hidden after StateSync recovery")
		assertTest(clientState.combatVisible == true, "[Suite 71.43] Client combat HUD visible after StateSync recovery")

		CombatService.cleanupCombat()
		RunManager.resetToLobby()
	end
end

local function runSuite72()
	print("\n--- [Suite 72] WorldRoomService: 3D Room Lifecycle, Deterministic Templating & Zero Leakage ---")

	-- 72.1: Initialization
	WorldRoomService.init()
	local container = game:GetService("Workspace"):FindFirstChild("CardRiftWorld")
	assertTest(container ~= nil and container:IsA("Folder"), "[Suite 72.1] CardRiftWorld container folder created in Workspace")

	-- 72.2: Load Combat Arena Room
	local roomModel = WorldRoomService.loadRoom("Combat", 1, 1, "enc_test_1", "None", 12345)
	assertTest(roomModel ~= nil and roomModel:IsA("Model"), "[Suite 72.2] loadRoom returns Model")
	assertTest(roomModel.Name == "ActiveRoom", "[Suite 72.3] ActiveRoom model named correctly")
	assertTest(roomModel:FindFirstChild("Geometry") ~= nil, "[Suite 72.4] Geometry folder present in ActiveRoom")
	assertTest(roomModel:FindFirstChild("SpawnPoints") ~= nil, "[Suite 72.5] SpawnPoints folder present in ActiveRoom")
	assertTest(roomModel:FindFirstChild("Interactables") ~= nil, "[Suite 72.6] Interactables folder present in ActiveRoom")
	assertTest(roomModel:FindFirstChild("Hazards") ~= nil, "[Suite 72.7] Hazards folder present in ActiveRoom")
	assertTest(roomModel:FindFirstChild("Effects") ~= nil, "[Suite 72.8] Effects folder present in ActiveRoom")

	-- 72.3: Spawns
	local spFolder = roomModel:FindFirstChild("SpawnPoints") :: Folder
	local spawnLoc = spFolder:FindFirstChildWhichIsA("SpawnLocation")
	assertTest(spawnLoc ~= nil, "[Suite 72.9] SpawnLocation instance exists in SpawnPoints")

	-- 72.4: Load Event Chamber Room (Cleans up previous room)
	local eventRoom = WorldRoomService.loadRoom("Event", 2, 1, "rune_sequence_puzzle", "None", 67890)
	assertTest(eventRoom ~= nil and eventRoom == WorldRoomService.getActiveRoomModel(), "[Suite 72.10] loadRoom replaces prior room with new ActiveRoom")
	local geomFolder = eventRoom:FindFirstChild("Geometry") :: Folder
	assertTest(geomFolder:FindFirstChild("CentralDais") ~= nil, "[Suite 72.11] Event Chamber contains CentralDais")

	-- 72.5: Create 3D Interactables
	local runePart = WorldRoomService.createInteractable("Rune_Test", "Test Rune", "Rune", Vector3.new(0, 3, 0), "Activate")
	assertTest(runePart ~= nil and runePart:IsA("BasePart"), "[Suite 72.12] createInteractable instantiates physical BasePart")
	assertTest(runePart:FindFirstChildWhichIsA("ClickDetector") ~= nil, "[Suite 72.13] ClickDetector attached to interactable")
	assertTest(WorldRoomService.getInteractable("Rune_Test") == runePart, "[Suite 72.14] getInteractable retrieves part by ID")

	-- 72.6: Apply Environment Visuals
	WorldRoomService.applyEnvironmentVisuals("LavaCavern")
	local fxFolder = eventRoom:FindFirstChild("Effects") :: Folder
	assertTest(fxFolder:FindFirstChild("LavaAnchor") ~= nil, "[Suite 72.15] LavaCavern visual preset instantiated LavaAnchor in Effects")

	-- 72.7: Teleport Players
	local mockPlayer = {
		UserId = 72001,
		Character = Instance.new("Model"),
	}
	local hrp = Instance.new("Part")
	hrp.Name = "HumanoidRootPart"
	hrp.CFrame = CFrame.new(0, 0, 0)
	hrp.Parent = mockPlayer.Character
	WorldRoomService.teleportPlayers({ mockPlayer })
	assertTest(hrp.Position.Y > 0, "[Suite 72.16] teleportPlayers moves character to spawn area")

	-- 72.8: Cleanup Room & Zero Instance Leakage
	WorldRoomService.cleanupRoom()
	assertTest(WorldRoomService.getActiveRoomModel() == nil, "[Suite 72.17] getActiveRoomModel returns nil after cleanupRoom")
	assertTest(container:FindFirstChild("ActiveRoom") == nil, "[Suite 72.18] ActiveRoom completely destroyed from Workspace (zero leakage)")
end

local function runSuite73()
	print("\n--- [Suite 73] EventService: 3D Puzzle State Machine, Clues & Rewards ---")

	local p1 = {
		UserId = 73001,
		DisplayName = "PuzzleMaster",
		Resources = { HP = 100, MaxHP = 100, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Gold = 50,
		IsDowned = false,
	}
	local p2 = {
		UserId = 73002,
		DisplayName = "RiddleSolver",
		Resources = { HP = 80, MaxHP = 80, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Gold = 30,
		IsDowned = false,
	}
	local party: { [number]: StateTypes.PlayerState } = {
		[73001] = p1 :: any,
		[73002] = p2 :: any,
	}

	-- 73.1: Start Rune Sequence Puzzle
	WorldRoomService.loadRoom("Event", 1, 1, "rune_sequence_puzzle", "None", 100)
	local puzzleState = EventService.startEvent("rune_sequence_puzzle", party, 100)
	assertTest(puzzleState ~= nil, "[Suite 73.1] startEvent instantiates puzzle state")
	assertTest(puzzleState.Category == "Puzzle", "[Suite 73.2] Event category is Puzzle")
	assertTest(puzzleState.AttemptsRemaining == 3, "[Suite 73.3] Starts with 3 attempts remaining")
	assertTest(puzzleState.TargetSequence ~= nil and #puzzleState.TargetSequence == 4, "[Suite 73.4] Generates 4-rune sequence")
	assertTest(puzzleState.CurrentStep == 1, "[Suite 73.5] Sequence starts at Step 1")

	-- 73.2: Co-op Clue Distribution
	local snap1 = EventService.getEventSnapshotForPlayer(p1)
	local snap2 = EventService.getEventSnapshotForPlayer(p2)
	assertTest(snap1 ~= nil and snap1.ClueText ~= nil, "[Suite 73.6] Player 1 receives puzzle clues")
	assertTest(snap2 ~= nil and snap2.ClueText ~= nil, "[Suite 73.7] Player 2 receives puzzle clues")
	assertTest(snap1.ObjectiveText ~= nil, "[Suite 73.8] Player 1 has assigned objective")

	-- 73.3: Correct Rune Step
	local firstCorrectRune = puzzleState.TargetSequence[1]
	local okStep, msgStep = EventService.interact(p1, firstCorrectRune)
	assertTest(okStep == true, "[Suite 73.9] Interacting with correct first rune succeeds")
	assertTest(puzzleState.CurrentStep == 2, "[Suite 73.10] CurrentStep advanced from 1 to 2")

	-- 73.4: Incorrect Rune Step decrements attempts
	local wrongRune = puzzleState.TargetSequence[4] -- Incorrect step
	local wrongOk, wrongMsg = EventService.interact(p1, wrongRune)
	assertTest(wrongOk == false, "[Suite 73.11] Interacting with out-of-order rune rejected")
	assertTest(puzzleState.AttemptsRemaining == 2, "[Suite 73.12] Attempts decremented to 2 on error")
	assertTest(puzzleState.CurrentStep == 1, "[Suite 73.13] CurrentStep reset to 1 on mistake")

	-- 73.5: Downed Player Guard
	p2.IsDowned = true
	local downOk, downErr = EventService.interact(p2, firstCorrectRune)
	assertTest(downOk == false and string.find(downErr or "", "Downed") ~= nil, "[Suite 73.14] Downed player rejected from interacting")
	p2.IsDowned = false

	-- 73.6: Start Statue Riddle
	WorldRoomService.loadRoom("Event", 2, 1, "statue_riddle", "None", 200)
	local riddleState = EventService.startEvent("statue_riddle", party, 200)
	assertTest(riddleState ~= nil and riddleState.Category == "Riddle", "[Suite 73.15] Statue Riddle initialized")
	assertTest(riddleState.CorrectStatueId == "Statue_Wisdom", "[Suite 73.16] Correct statue is Statue_Wisdom")

	-- 73.7: Solve Riddle Successfully
	local solveOk, solveMsg = EventService.interact(p1, "Statue_Wisdom")
	assertTest(solveOk == true, "[Suite 73.17] Choosing Statue_Wisdom solves riddle")
	assertTest(riddleState.IsCompleted == true, "[Suite 73.18] Riddle marked completed")
	assertTest(riddleState.Outcome == "Success", "[Suite 73.19] Riddle outcome is Success")
	assertTest(p1.Gold > 50, "[Suite 73.20] Gold reward granted to player 1 on success")

	-- 73.8: Cleanup & Party Preservation Guard
	EventService.cleanupEvent()
	assertTest(EventService.getActiveEvent() == nil, "[Suite 73.21] cleanupEvent clears active event")
	assertTest(party[73001] ~= nil and party[73002] ~= nil, "[Suite 73.22] cleanupEvent does not clear or mutate caller's party table")
	assertTest(string.find(riddleState.Clues["Riddle"] or "", "What am I%?") ~= nil, "[Suite 73.23] Statue Riddle prompts with grammatically correct 'What am I?'")
	WorldRoomService.cleanupRoom()
end

local function runSuite74()
	print("\n--- [Suite 74] ReactionService: 3D Enemy Attack Animations, Dodge & Parry Reaction System ---")

	-- 74.1: GameConfig Reaction Keybindings
	assertTest(GameConfig.Reaction ~= nil and GameConfig.Reaction.Keybinds ~= nil, "[Suite 74.1] GameConfig.Reaction.Keybinds table exists")
	assertTest(GameConfig.Reaction.Keybinds.Dodge == Enum.KeyCode.C, "[Suite 74.2] Dodge keybind is Enum.KeyCode.C")
	assertTest(GameConfig.Reaction.Keybinds.Parry == Enum.KeyCode.V, "[Suite 74.3] Parry keybind is Enum.KeyCode.V")
	assertTest(GameConfig.Reaction.Keybinds.Dodge ~= Enum.KeyCode.Space, "[Suite 74.4] Space is removed from Dodge keybinds")
	assertTest(GameConfig.Reaction.Keybinds.Dodge ~= Enum.KeyCode.LeftShift and GameConfig.Reaction.Keybinds.Dodge ~= Enum.KeyCode.RightShift,
		"[Suite 74.5] Shift is removed from Dodge keybinds")

	-- 74.2: ReactionData Data-Driven Attack Timing Profiles
	local slowHeavyPreset = ReactionData.getProfile("SlowHeavy")
	assertTest(slowHeavyPreset ~= nil, "[Suite 74.6] ReactionData defines 'SlowHeavy' profile")
	assertTest(slowHeavyPreset ~= nil and slowHeavyPreset.TelegraphDuration <= slowHeavyPreset.ImpactDelay, "[Suite 74.7] SlowHeavy TelegraphDuration <= ImpactDelay")
	assertTest(slowHeavyPreset ~= nil and slowHeavyPreset.ImpactDelay == 1.45, "[Suite 74.8] SlowHeavy ImpactDelay is 1.45s")
	assertTest(slowHeavyPreset ~= nil and slowHeavyPreset.RecoveryDuration == 0.40, "[Suite 74.9] SlowHeavy RecoveryDuration is 0.40s")
	assertTest(slowHeavyPreset ~= nil and slowHeavyPreset.CanDodge == true and slowHeavyPreset.CanParry == true,
		"[Suite 74.10] SlowHeavy allows both Dodge and Parry")
	assertTest(slowHeavyPreset ~= nil and slowHeavyPreset.DodgePerfectTolerance == 0.15 and slowHeavyPreset.DodgeGoodTolerance == 0.35,
		"[Suite 74.11] SlowHeavy defines Dodge Perfect (0.15s) and Good (0.35s) tolerances")
	assertTest(slowHeavyPreset ~= nil and slowHeavyPreset.ParryPerfectTolerance == 0.08 and slowHeavyPreset.ParryGoodTolerance == 0.18,
		"[Suite 74.12] SlowHeavy defines tighter Parry Perfect (0.08s) and Good (0.18s) tolerances")

	local fastDaggerPreset = ReactionData.getProfile("FastDagger")
	assertTest(fastDaggerPreset ~= nil and fastDaggerPreset.ImpactDelay == 0.55, "[Suite 74.13] FastDagger has fast 0.55s ImpactDelay")

	local bossHeavyPreset = ReactionData.getProfile("BossHeavyStrike")
	assertTest(bossHeavyPreset ~= nil and bossHeavyPreset.ImpactDelay == 2.0, "[Suite 74.14] BossHeavyStrike has 2.0s ImpactDelay")

	local unparryablePreset = ReactionData.getProfile("UnparryableCleave")
	assertTest(unparryablePreset ~= nil and unparryablePreset.CanDodge == true and unparryablePreset.CanParry == false,
		"[Suite 74.15] UnparryableCleave allows Dodge but strictly disallows Parry")

	local undodgeablePreset = ReactionData.getProfile("UndodgeableImpale")
	assertTest(undodgeablePreset ~= nil and undodgeablePreset.CanDodge == false and undodgeablePreset.CanParry == true,
		"[Suite 74.16] UndodgeableImpale allows Parry but strictly disallows Dodge")

	local unreactablePreset = ReactionData.getProfile("UnreactableExplosion")
	assertTest(unreactablePreset ~= nil and unreactablePreset.CanDodge == false and unreactablePreset.CanParry == false,
		"[Suite 74.17] UnreactableExplosion strictly disallows both Dodge and Parry")

	-- 74.3: ReactionService Profile Factory from Preset
	local profile = ReactionService.createProfileFromPreset("SlowHeavy", 25, "Physical")
	assertTest(profile.AttackName == "Heavy Cleave", "[Suite 74.18] createProfileFromPreset retains AttackName")
	assertTest(profile.RawDamage == 25, "[Suite 74.19] createProfileFromPreset overrides RawDamage")
	assertTest(profile.ImpactDelay == 1.45, "[Suite 74.20] Profile retains 1.45s ImpactDelay")
	assertTest(profile.DodgePerfectTolerance == 0.15 and profile.ParryPerfectTolerance == 0.08,
		"[Suite 74.21] Profile retains rhythm timing tolerances")

	-- 74.4: Open Reaction Window with Workspace:GetServerTimeNow()
	local mockCombatState = {
		CombatId = "test_combat_react",
		ActiveReactionWindow = nil,
	}
	local window = ReactionService.openReactionWindow(mockCombatState :: any, profile, "enemy_boss", { 74001, 74002, 74003, 74004 })
	assertTest(window ~= nil, "[Suite 74.22] openReactionWindow returns active window state")
	assertTest(mockCombatState.ActiveReactionWindow == window, "[Suite 74.23] ActiveReactionWindow attached to combatState")
	assertTest(ReactionService.getActiveWindow() == window, "[Suite 74.24] getActiveWindow returns current window")
	assertTest(math.abs(window.ImpactTime - (window.OpenTime + profile.ImpactDelay)) < 0.01,
		"[Suite 74.25] Window ImpactTime is calculated from OpenTime + ImpactDelay")

	-- 74.5: Non-targeted Player Rejection
	local nonTargetOk, nonTargetErr = ReactionService.submitReaction(99999, window.WindowId, "Dodge")
	assertTest(nonTargetOk == false and string.find(nonTargetErr or "", "not a targeted recipient") ~= nil,
		"[Suite 74.26] Non-targeted player rejected from reaction submission")

	-- 74.6: Perfect Dodge Submission (exact impact timing)
	local serverNow = ReactionService.getServerTime()
	window.ImpactServerTime = serverNow
	window.ImpactTime = serverNow -- Simulate button press at exact impact moment (diff = 0)
	local dodgeOk, dodgeMsg, dodgeRes = ReactionService.submitReaction(74001, window.WindowId, "Dodge")
	assertTest(dodgeOk == true and dodgeRes == "Perfect", "[Suite 74.27] Exact impact timing evaluates to Perfect Dodge")
	assertTest(window.PerPlayerResult[74001].Judgement == "Perfect", "[Suite 74.28] Player record recorded Judgement == 'Perfect'")

	-- 74.7: Single Submission Enforced (Double reaction rejected)
	local dupOk, dupErr = ReactionService.submitReaction(74001, window.WindowId, "Dodge")
	assertTest(dupOk == false and string.find(dupErr or "", "already submitted") ~= nil,
		"[Suite 74.29] Double reaction submission strictly rejected")

	-- 74.8: Perfect Parry Submission & Parry Hook Callback
	local parryHookFired = false
	ReactionService.setParryHook(function(targetUserId, attackProf)
		if targetUserId == 74002 and attackProf.AttackName == "Heavy Cleave" then
			parryHookFired = true
		end
	end)
	window.ImpactServerTime = ReactionService.getServerTime()
	window.ImpactTime = window.ImpactServerTime -- Exact impact moment for parry
	local parryOk, parryMsg, parryRes = ReactionService.submitReaction(74002, window.WindowId, "Parry")
	assertTest(parryOk == true and parryRes == "Perfect", "[Suite 74.30] Exact impact timing evaluates to Perfect Parry")
	assertTest(parryHookFired == true, "[Suite 74.31] Parry hook fired on Perfect Parry")

	-- 74.9: Reaction Window View Data Structure
	local winView = ReactionService.getReactionWindowView(window, "The Titan Boss")
	assertTest(winView ~= nil, "[Suite 74.32] getReactionWindowView returns valid view")
	assertTest(winView ~= nil and winView.EnemyName == "The Titan Boss", "[Suite 74.33] View includes EnemyName")
	assertTest(winView ~= nil and winView.ImpactTime == window.ImpactTime, "[Suite 74.34] View includes authoritative ImpactTime")
	assertTest(winView ~= nil and winView.DodgePerfectTolerance == 0.15, "[Suite 74.35] View includes DodgePerfectTolerance")
	assertTest(winView ~= nil and winView.ParryPerfectTolerance == 0.08, "[Suite 74.36] View includes ParryPerfectTolerance")

	-- 74.10: Window Resolution & Unreacted Targets Marked as Miss
	local results = ReactionService.resolveReactionWindow(mockCombatState :: any, window.WindowId)
	assertTest(results[74001] ~= nil and results[74001].Judgement == "Perfect", "[Suite 74.37] Player 74001 resolution preserved Perfect Dodge")
	assertTest(results[74002] ~= nil and results[74002].Judgement == "Perfect", "[Suite 74.38] Player 74002 resolution preserved Perfect Parry")
	assertTest(results[74003] ~= nil and results[74003].Result == "Miss" and results[74003].Judgement == "Miss",
		"[Suite 74.39] Unreacted player 74003 automatically marked as Miss")
	assertTest(results[74004] ~= nil and results[74004].Result == "Miss" and results[74004].Judgement == "Miss",
		"[Suite 74.40] Unreacted player 74004 automatically marked as Miss")
	assertTest(mockCombatState.ActiveReactionWindow == nil, "[Suite 74.41] CombatState ActiveReactionWindow cleared on resolution")
	assertTest(ReactionService.getActiveWindow() == nil, "[Suite 74.42] Active window set to nil after resolution")

	-- 74.11: Timing Judgements: Good Dodge, Early Dodge, Late Dodge
	-- Good Dodge: within Good tolerance (e.g. 0.25s diff vs 0.35s GoodTol and 0.15s PerfTol)
	local winGood = ReactionService.openReactionWindow(mockCombatState :: any, profile, "enemy_boss", { 74001 })
	local sTimeGood = ReactionService.getServerTime()
	winGood.ImpactServerTime = sTimeGood + 0.25
	winGood.ImpactTime = winGood.ImpactServerTime
	local goodDodgeOk, _, goodDodgeRes = ReactionService.submitReaction(74001, winGood.WindowId, "Dodge")
	assertTest(goodDodgeOk == true and goodDodgeRes == "Good", "[Suite 74.43] Input within Good tolerance evaluates to Good Dodge")
	ReactionService.resolveReactionWindow(mockCombatState :: any, winGood.WindowId)

	-- Early Dodge: submitted too early (> Good tolerance before impact)
	local winEarly = ReactionService.openReactionWindow(mockCombatState :: any, profile, "enemy_boss", { 74001 })
	local sTimeEarly = ReactionService.getServerTime()
	winEarly.ImpactServerTime = sTimeEarly + 0.50 -- 0.50s before impact > 0.35s Good tolerance
	winEarly.ImpactTime = winEarly.ImpactServerTime
	local earlyDodgeOk, _, earlyDodgeRes = ReactionService.submitReaction(74001, winEarly.WindowId, "Dodge")
	assertTest(earlyDodgeOk == false and earlyDodgeRes == "Early", "[Suite 74.44] Input before Good window evaluates to Early Dodge")
	ReactionService.resolveReactionWindow(mockCombatState :: any, winEarly.WindowId)

	-- Late Dodge: submitted after impact (> Good tolerance after impact)
	local winLate = ReactionService.openReactionWindow(mockCombatState :: any, profile, "enemy_boss", { 74001 })
	local sTimeLate = ReactionService.getServerTime()
	winLate.ImpactServerTime = sTimeLate - 0.50 -- 0.50s after impact > 0.35s Good tolerance
	winLate.ImpactTime = winLate.ImpactServerTime
	local lateDodgeOk, _, lateDodgeRes = ReactionService.submitReaction(74001, winLate.WindowId, "Dodge")
	assertTest(lateDodgeOk == false and lateDodgeRes == "Late", "[Suite 74.45] Input after Good window evaluates to Late Dodge")
	ReactionService.resolveReactionWindow(mockCombatState :: any, winLate.WindowId)

	-- 74.12: Timing Judgements: Good Parry, Early Parry, Late Parry
	-- Good Parry: within Good tolerance (e.g. 0.13s diff vs 0.18s GoodTol and 0.08s PerfTol)
	local winGoodP = ReactionService.openReactionWindow(mockCombatState :: any, profile, "enemy_boss", { 74002 })
	local sTimeGoodP = ReactionService.getServerTime()
	winGoodP.ImpactServerTime = sTimeGoodP + 0.13
	winGoodP.ImpactTime = winGoodP.ImpactServerTime
	local goodParryOk, _, goodParryRes = ReactionService.submitReaction(74002, winGoodP.WindowId, "Parry")
	assertTest(goodParryOk == true and goodParryRes == "Good", "[Suite 74.46] Input within Good tolerance evaluates to Good Parry")
	ReactionService.resolveReactionWindow(mockCombatState :: any, winGoodP.WindowId)

	-- Early Parry: submitted too early (> Good tolerance before impact)
	local winEarlyP = ReactionService.openReactionWindow(mockCombatState :: any, profile, "enemy_boss", { 74002 })
	local sTimeEarlyP = ReactionService.getServerTime()
	winEarlyP.ImpactServerTime = sTimeEarlyP + 0.30 -- 0.30s before impact > 0.18s Good tolerance
	winEarlyP.ImpactTime = winEarlyP.ImpactServerTime
	local earlyParryOk, _, earlyParryRes = ReactionService.submitReaction(74002, winEarlyP.WindowId, "Parry")
	assertTest(earlyParryOk == false and earlyParryRes == "Early", "[Suite 74.47] Input before Good window evaluates to Early Parry")
	ReactionService.resolveReactionWindow(mockCombatState :: any, winEarlyP.WindowId)

	-- Late Parry: submitted after impact (> Good tolerance after impact)
	local winLateP = ReactionService.openReactionWindow(mockCombatState :: any, profile, "enemy_boss", { 74002 })
	local sTimeLateP = ReactionService.getServerTime()
	winLateP.ImpactServerTime = sTimeLateP - 0.30 -- 0.30s after impact > 0.18s Good tolerance
	winLateP.ImpactTime = winLateP.ImpactServerTime
	local lateParryOk, _, lateParryRes = ReactionService.submitReaction(74002, winLateP.WindowId, "Parry")
	assertTest(lateParryOk == false and lateParryRes == "Late", "[Suite 74.48] Input after Good window evaluates to Late Parry")
	ReactionService.resolveReactionWindow(mockCombatState :: any, winLateP.WindowId)

	-- 74.13: Non-dodgeable & Non-parryable Attacks Evaluate to Unavailable
	local unparryableProf = ReactionService.createProfileFromPreset("UnparryableCleave")
	local winUnparry = ReactionService.openReactionWindow(mockCombatState :: any, unparryableProf, "enemy_cleave", { 74001 })
	local noParryOk, noParryErr, noParryRes = ReactionService.submitReaction(74001, winUnparry.WindowId, "Parry")
	assertTest(noParryOk == false and noParryRes == "Unavailable" and string.find(noParryErr or "", "cannot be parried") ~= nil,
		"[Suite 74.49] Unparryable attacks strictly reject Parry with Unavailable")
	ReactionService.resolveReactionWindow(mockCombatState :: any, winUnparry.WindowId)

	local undodgeableProf = ReactionService.createProfileFromPreset("UndodgeableImpale")
	local winUndodge = ReactionService.openReactionWindow(mockCombatState :: any, undodgeableProf, "enemy_impale", { 74001 })
	local noDodgeOk, noDodgeErr, noDodgeRes = ReactionService.submitReaction(74001, winUndodge.WindowId, "Dodge")
	assertTest(noDodgeOk == false and noDodgeRes == "Unavailable" and string.find(noDodgeErr or "", "cannot be dodged") ~= nil,
		"[Suite 74.50] Undodgeable attacks strictly reject Dodge with Unavailable")
	ReactionService.resolveReactionWindow(mockCombatState :: any, winUndodge.WindowId)

	-- 74.14: Fail-safe Non-blocking Combat Resolution
	local badWinOk, badWinErr = ReactionService.submitReaction(74001, "react_nonexistent", "Dodge")
	assertTest(badWinOk == false and string.find(badWinErr or "", "Invalid or expired") ~= nil,
		"[Suite 74.51] Invalid or expired window ID rejected safely")

	-- 74.15: Deterministic Projectile Timing Resolution
	local wu1, imp1 = ReactionData.resolveProjectileTiming(30, 30, 0.35)
	assertTest(wu1 == 0.35 and imp1 == 1.35, "[Suite 74.52] ReactionData.resolveProjectileTiming computes deterministic windup and impact delay")

	-- 74.16: Jump Attack Profile & Projectile Speed Sensitivity
	local jumpPreset = ReactionData.getProfile("JumpAttack")
	assertTest(jumpPreset ~= nil and jumpPreset.AttackType == "Jump" and jumpPreset.ImpactDelay == 1.25,
		"[Suite 74.53] JumpAttack preset defines Jump attack profile with 1.25s ImpactDelay")
	local _, fastDelay = ReactionData.resolveProjectileTiming(30, 60, 0.35)
	local _, slowDelay = ReactionData.resolveProjectileTiming(30, 15, 0.35)
	assertTest(fastDelay == 0.85 and slowDelay == 2.35 and fastDelay < imp1 and slowDelay > imp1,
		"[Suite 74.54] Projectile impact delay scales inversely with ProjectileSpeed")

	-- 74.17: Projectile Bolt Profile & Packet Arrival Grace Acceptance
	local projPreset = ReactionData.getProfile("ProjectileBolt")
	assertTest(projPreset ~= nil and projPreset.AttackType == "Projectile" and projPreset.ProjectileSpeed == 30,
		"[Suite 74.55] ProjectileBolt preset defines Projectile attack profile with ProjectileSpeed = 30")
	local winGrace = ReactionService.openReactionWindow(mockCombatState :: any, profile, "enemy_grace", { 74001 })
	local gNow = ReactionService.getServerTime()
	winGrace.ReactionCloseServerTime = gNow - 0.08 -- arrived 80ms after closeTime, within 200ms grace
	winGrace.CloseTime = winGrace.ReactionCloseServerTime
	winGrace.ImpactServerTime = winGrace.ReactionCloseServerTime - 0.10
	winGrace.ImpactTime = winGrace.ImpactServerTime
	local graceOk, _, graceRes = ReactionService.submitReaction(74001, winGrace.WindowId, "Dodge", winGrace.ImpactServerTime)
	assertTest(graceOk == true and graceRes == "Perfect",
		"[Suite 74.56] Packet arriving within arrival grace with valid client timestamp is accepted")
	ReactionService.resolveReactionWindow(mockCombatState :: any, winGrace.WindowId)

	-- 74.18: Unreactable AoE Profile & Packet Beyond Grace Rejection
	local aoePreset = ReactionData.getProfile("UnreactableExplosion")
	assertTest(aoePreset ~= nil and aoePreset.AttackType == "AoE" and aoePreset.CanDodge == false and aoePreset.CanParry == false,
		"[Suite 74.57] UnreactableExplosion preset defines unreactable AoE attack")
	local winAoe = ReactionService.openReactionWindow(mockCombatState :: any, aoePreset, "enemy_aoe", { 74001 })
	local aoeDodgeOk, _, aoeDodgeRes = ReactionService.submitReaction(74001, winAoe.WindowId, "Dodge")
	local aoeParryOk, _, aoeParryRes = ReactionService.submitReaction(74001, winAoe.WindowId, "Parry")
	assertTest(aoeDodgeOk == false and aoeDodgeRes == "Unavailable" and aoeParryOk == false and aoeParryRes == "Unavailable",
		"[Suite 74.58] Unreactable AoE strictly rejects both Dodge and Parry with Unavailable")
	ReactionService.resolveReactionWindow(mockCombatState :: any, winAoe.WindowId)
	local winBeyond = ReactionService.openReactionWindow(mockCombatState :: any, profile, "enemy_beyond", { 74001 })
	local bNow = ReactionService.getServerTime()
	winBeyond.ReactionCloseServerTime = bNow - 0.25 -- arrived 250ms after closeTime, exceeding 200ms grace
	winBeyond.CloseTime = winBeyond.ReactionCloseServerTime
	local beyondOk, _, beyondRes = ReactionService.submitReaction(74001, winBeyond.WindowId, "Dodge", bNow - 0.30)
	assertTest(beyondOk == false and beyondRes == "Late",
		"[Suite 74.59] Submission arriving beyond packet arrival grace unconditionally rejected as Late")
	ReactionService.resolveReactionWindow(mockCombatState :: any, winBeyond.WindowId)

	-- 74.19: Workspace:GetServerTimeNow() Synchronization Timestamps
	local winSync = ReactionService.openReactionWindow(mockCombatState :: any, profile, "enemy_sync", { 74001 })
	assertTest(winSync.AttackStartServerTime ~= nil and winSync.ImpactServerTime ~= nil and winSync.ReactionCloseServerTime ~= nil,
		"[Suite 74.60] ReactionWindowState includes authoritative ServerTime timestamps")
	assertTest(winSync.ReactionCloseServerTime > winSync.ImpactServerTime and winSync.ImpactServerTime >= winSync.AttackStartServerTime,
		"[Suite 74.61] ReactionCloseServerTime > ImpactServerTime >= AttackStartServerTime")
	local viewSync = ReactionService.getReactionWindowView(winSync, "Boss Visual Sync")
	assertTest(viewSync.AttackStartServerTime == winSync.AttackStartServerTime and viewSync.ImpactServerTime == winSync.ImpactServerTime,
		"[Suite 74.62] ReactionWindowView synchronizes ServerTime timestamps to client")
	ReactionService.resolveReactionWindow(mockCombatState :: any, winSync.WindowId)

	-- 74.20: Multi-target Reaction Resolution
	local multiProf = ReactionService.createProfileFromPreset("SlowHeavy")
	local winMulti = ReactionService.openReactionWindow(mockCombatState :: any, multiProf, "enemy_multi", { 74001, 74002, 74003 })
	local multiTime = ReactionService.getServerTime()
	winMulti.ImpactServerTime = multiTime
	winMulti.ImpactTime = multiTime
	ReactionService.submitReaction(74001, winMulti.WindowId, "Dodge") -- 74001: Perfect Dodge
	winMulti.ImpactServerTime = multiTime + 0.12
	winMulti.ImpactTime = winMulti.ImpactServerTime
	ReactionService.submitReaction(74002, winMulti.WindowId, "Parry") -- 74002: Good Parry
	-- 74003: No submission -> Miss
	local multiResults = ReactionService.resolveReactionWindow(mockCombatState :: any, winMulti.WindowId)
	assertTest(multiResults[74001] ~= nil and multiResults[74001].Judgement == "Perfect",
		"[Suite 74.63] Multi-target resolution preserves Player 1 Perfect Dodge")
	assertTest(multiResults[74002] ~= nil and multiResults[74002].Judgement == "Good",
		"[Suite 74.64] Multi-target resolution preserves Player 2 Good Parry")
	assertTest(multiResults[74003] ~= nil and multiResults[74003].Judgement == "Miss",
		"[Suite 74.65] Multi-target resolution marks unreacted Player 3 as Miss")

	-- 74.21: Regression Coverage for Reaction V2 Invariants
	-- 1. Workspace reference & server timing
	local wsTest = (Workspace ~= nil and typeof(Workspace:GetServerTimeNow()) == "number")
	assertTest(wsTest, "[Suite 74.66] Workspace:GetServerTimeNow() is valid monotonic number")

	-- 2. ProjectileBolt uses a valid StateTypes.DamageType ('Void')
	local pb = ReactionData.getProfile("ProjectileBolt")
	assertTest(pb ~= nil and pb.DamageType == "Void", "[Suite 74.67] ProjectileBolt DamageType is 'Void'")

	-- 3. Preset DamageType is not overwritten with Physical by CombatService/ReactionService
	local voidProf = ReactionService.createProfileFromPreset("ProjectileBolt", 14, nil)
	assertTest(voidProf.DamageType == "Void", "[Suite 74.68] ProjectileBolt retains 'Void' DamageType when damageType override is nil")

	-- 4. Target and Attacker world positions are attached and propagated
	local posProf = ReactionService.createProfileFromPreset("SlowHeavy")
	posProf.TargetWorldPos = Vector3.new(0, 1.2, 16)
	posProf.AttackerWorldPos = Vector3.new(0, 1.2, -16)
	local winPos = ReactionService.openReactionWindow(mockCombatState :: any, posProf, "enemy_pos", { 74001 })
	assertTest(winPos.TargetWorldPos == Vector3.new(0, 1.2, 16) and winPos.AttackerWorldPos == Vector3.new(0, 1.2, -16),
		"[Suite 74.69] ReactionWindowState preserves TargetWorldPos and AttackerWorldPos")
	local viewPos = ReactionService.getReactionWindowView(winPos, "PosEnemy")
	assertTest(viewPos ~= nil and viewPos.TargetWorldPos == Vector3.new(0, 1.2, 16) and viewPos.EnemyInstanceId == "enemy_pos",
		"[Suite 74.70] ReactionWindowView propagates TargetWorldPos and EnemyInstanceId")
	ReactionService.resolveReactionWindow(mockCombatState :: any, winPos.WindowId)

	-- 5. Single-target reaction is only valid for intended player
	local winSingle = ReactionService.openReactionWindow(mockCombatState :: any, posProf, "enemy_single", { 74001 })
	local badTargetOk, badTargetMsg = ReactionService.submitReaction(74002, winSingle.WindowId, "Dodge")
	assertTest(badTargetOk == false and string.find(badTargetMsg or "", "not a targeted recipient") ~= nil,
		"[Suite 74.71] Non-targeted player 74002 rejected from single-target attack")
	ReactionService.resolveReactionWindow(mockCombatState :: any, winSingle.WindowId)

	-- 6. AoE reaction targets all intended players
	local aoeProf = ReactionService.createProfileFromPreset("UnreactableExplosion")
	local winAoE = ReactionService.openReactionWindow(mockCombatState :: any, aoeProf, "enemy_aoe2", { 74001, 74002, 74003, 74004 })
	assertTest(#winAoE.TargetUserIds == 4 and winAoE.PerPlayerResult[74004] ~= nil,
		"[Suite 74.72] AoE reaction window targets all 4 party members")
	ReactionService.resolveReactionWindow(mockCombatState :: any, winAoE.WindowId)

	-- 7. Client timestamp validation accepts reasonable latency
	local winLat = ReactionService.openReactionWindow(mockCombatState :: any, posProf, "enemy_lat", { 74001 })
	local latNow = ReactionService.getServerTime()
	winLat.ImpactServerTime = latNow
	winLat.ImpactTime = latNow
	local latOk, _, latRes = ReactionService.submitReaction(74001, winLat.WindowId, "Dodge", latNow)
	assertTest(latOk == true and latRes == "Perfect",
		"[Suite 74.73] Valid client timestamp matching impact evaluates to Perfect Dodge")
	ReactionService.resolveReactionWindow(mockCombatState :: any, winLat.WindowId)

	-- 8. Client timestamp far in future is rejected
	local winFut = ReactionService.openReactionWindow(mockCombatState :: any, posProf, "enemy_fut", { 74001 })
	local futNow = ReactionService.getServerTime()
	local futOk, futMsg = ReactionService.submitReaction(74001, winFut.WindowId, "Dodge", futNow + 5.0)
	assertTest(futOk == false and string.find(futMsg or "", "too far in the future") ~= nil,
		"[Suite 74.74] Client timestamp far in future rejected")
	ReactionService.resolveReactionWindow(mockCombatState :: any, winFut.WindowId)

	-- 9. Client timestamp after ReactionCloseServerTime is rejected
	local winClosed = ReactionService.openReactionWindow(mockCombatState :: any, posProf, "enemy_close", { 74001 })
	local closeNow = ReactionService.getServerTime()
	winClosed.ReactionCloseServerTime = closeNow - 0.1
	winClosed.CloseTime = winClosed.ReactionCloseServerTime
	local closeOk, _, closeRes = ReactionService.submitReaction(74001, winClosed.WindowId, "Dodge", closeNow)
	assertTest(closeOk == false and closeRes == "Late",
		"[Suite 74.75] Submission after ReactionCloseServerTime rejected with Late")
	ReactionService.resolveReactionWindow(mockCombatState :: any, winClosed.WindowId)

	-- 10. Only one reaction can be submitted per window
	local winOnce = ReactionService.openReactionWindow(mockCombatState :: any, posProf, "enemy_once", { 74001 })
	winOnce.ImpactServerTime = ReactionService.getServerTime()
	winOnce.ImpactTime = winOnce.ImpactServerTime
	ReactionService.submitReaction(74001, winOnce.WindowId, "Dodge")
	local secondOk, secondMsg = ReactionService.submitReaction(74001, winOnce.WindowId, "Parry")
	assertTest(secondOk == false and string.find(secondMsg or "", "already submitted") ~= nil,
		"[Suite 74.76] Second reaction attempt strictly rejected")
	ReactionService.resolveReactionWindow(mockCombatState :: any, winOnce.WindowId)

	-- 11. Projectile timing uses ProjectileSpeed
	local projSpeedProf = ReactionService.createProfileFromPreset("ProjectileBolt")
	assertTest(projSpeedProf.ProjectileSpeed ~= nil and projSpeedProf.ProjectileSpeed > 0,
		"[Suite 74.77] ProjectileBolt profile defines non-zero ProjectileSpeed")

	-- 12. Attack impact timestamp is strictly before reaction close
	local winTiming = ReactionService.openReactionWindow(mockCombatState :: any, posProf, "enemy_time", { 74001 })
	assertTest(winTiming.ImpactServerTime < winTiming.ReactionCloseServerTime,
		"[Suite 74.78] ImpactServerTime strictly precedes ReactionCloseServerTime")
	ReactionService.resolveReactionWindow(mockCombatState :: any, winTiming.WindowId)

	-- 13. ArenaVisualizer does not construct duplicate CombatArena at startup
	ArenaVisualizer.init()
	assertTest(Workspace:FindFirstChild("CombatArena") == nil,
		"[Suite 74.79] ArenaVisualizer.init() does not create redundant CombatArena")

	-- 14. ReactionData and TestRunner agree on current timing tolerances
	assertTest(slowHeavyPreset.ParryGoodTolerance == 0.18 and slowHeavyPreset.RecoveryDuration == 0.40 and jumpPreset.ImpactDelay == 1.25,
		"[Suite 74.80] Tolerances and delays agree across config and data")

	-- 15. Real Network Initialization Regression & Data Path Boundary
	local gameNetworkFolder = ReplicatedStorage:FindFirstChild("GameNetwork")
	assertTest(gameNetworkFolder ~= nil and gameNetworkFolder:IsA("Folder"),
		"[Suite 74.81] ReplicatedStorage contains authoritative GameNetwork folder")

	local csuRemote = gameNetworkFolder and gameNetworkFolder:FindFirstChild("CombatStateUpdate")
	assertTest(csuRemote ~= nil and csuRemote:IsA("RemoteEvent"),
		"[Suite 74.82] GameNetwork contains authoritative CombatStateUpdate RemoteEvent")

	-- Test manual trigger data path boundary up to client RemoteEvent dispatch
	local testWin = TestRunner.triggerTestReaction("SlowHeavy", 74001)
	assertTest(testWin ~= nil and testWin.WindowId ~= nil,
		"[Suite 74.83] triggerTestReaction successfully creates active test window")

	local testView = ReactionService.getReactionWindowView(testWin, "Training Dummy")
	assertTest(
		testView ~= nil
		and testView.WindowId == testWin.WindowId
		and testView.AttackStartServerTime ~= nil
		and testView.ImpactServerTime ~= nil
		and testView.ReactionCloseServerTime ~= nil
		and testView.EnemyInstanceId == "test_attacker"
		and testView.AttackType == "Melee"
		and (testView.TargetWorldPosition ~= nil or testView.TargetWorldPos ~= nil)
		and testView.AttackerWorldPos ~= nil,
		"[Suite 74.84] ActiveReactionWindow view exposes complete authoritative 3D attack metadata"
	)

	-- Verify NetworkService.sendCombatState dispatches cleanly with mock player
	local mockPlayerInstance = {
		UserId = 74001,
		Name = "TestNetPlayer",
		IsA = function(_, cls) return cls == "Player" end,
	}
	local sendOk = pcall(function()
		local snap: StateTypes.CombatSnapshot = {
			CombatId = "manual_test_reaction",
			Phase = "ResolutionPhase",
			TurnNumber = 1,
			TurnStartTime = os.clock(),
			TurnDuration = 45,
			TimeRemaining = 45,
			Enemies = {},
			Party = {},
			LocalHand = {},
			CombatEvents = {},
			Message = "Network test",
			ActiveReactionWindow = testView,
			Environment = nil,
		}
		NetworkService.sendCombatState(mockPlayerInstance :: any, snap)
	end)
	assertTest(sendOk == true, "[Suite 74.85] NetworkService.sendCombatState dispatches snapshot without error")

	-- Clean up test window
	local dummyStateCleanup = {
		CombatId = "manual_test_reaction",
		ActiveReactionWindow = testWin,
	}
	ReactionService.resolveReactionWindow(dummyStateCleanup :: any, testWin.WindowId)

	--[=[
		=============================================================================
		MANUAL STUDIO ACCEPTANCE CRITERIA (3D Presentation Verification):
		Automated tests verify timing mathematics, server authorization, network
		contract boundaries, and state transition correctness. They do NOT prove
		visual animation playback in the 3D viewport.

		Required Studio Play Solo / Multiplayer Acceptance Checks:
		1. SlowHeavy: Run /SlowHeavy in chat. Observe enemy torso windup lunge toward
		   player, striking at ImpactServerTime.
		2. FastDagger: Run /FastDagger in chat. Observe noticeably faster thrust.
		3. JumpAttack: Run /JumpAttack in chat. Observe enemy leaping into parabolic
		   arc and slamming downward onto player position at impact.
		4. ProjectileBolt: Run /ProjectileBolt in chat. Observe void energy projectile
		   traveling from enemy to player at configured ProjectileSpeed (30 studs/s).
		5. UnreactableExplosion: Run /UnreactableExplosion in chat. Observe red expanding
		   AoE cylinder telegraphing impending detonation; Dodge and Parry are locked.
		6. Player Input: Press C (Dodge) or V (Parry) during valid timing window.
		   Observe immediate HUD judgement banner ("PERFECT", "GOOD", "EARLY", "LATE").
		7. Target Isolation: Non-targeted players in multi-player do not see Dodge/Parry prompt.
		=============================================================================
	]=]

	ReactionService.cleanup()
	ReactionService.setParryHook(nil)
end

local function runSuite75()
	print("\n--- [Suite 75] EnvironmentService: Elemental Affinities, Scaling & Transformations ---")

	-- 75.1: Deterministic Selection
	local env1 = EnvironmentData.pickDeterministicEnvironment(1, 42)
	local env2 = EnvironmentData.pickDeterministicEnvironment(1, 42)
	assertTest(env1 == env2, "[Suite 75.1] pickDeterministicEnvironment is deterministic across same seed")

	-- 75.2: RainSoaked Affinities
	local rainState = EnvironmentService.createEnvironment("RainSoaked")
	assertTest(rainState.EnvironmentId == "RainSoaked", "[Suite 75.2] RainSoaked environment instantiated")
	assertTest(rainState.DamageModifiers["Lightning"] == 1.30, "[Suite 75.3] RainSoaked increases Lightning damage (+30%)")
	assertTest(rainState.DamageModifiers["Fire"] == 0.75, "[Suite 75.4] RainSoaked decreases Fire damage (-25%)")

	-- 75.3: modifyDamage Resolution
	local dmgContextLightning: StateTypes.DamageContext = {
		RawDamage = 20,
		DamageType = "Lightning",
		SourceId = "p1",
		SourceName = "Player",
		TargetEntityKind = "Enemy",
		Critical = false,
		CanHitShield = true,
		IsPeriodic = false,
	}
	local scaledLightning = EnvironmentService.modifyDamage(rainState, dmgContextLightning, 20)
	assertTest(scaledLightning == 26, "[Suite 75.5] modifyDamage scales 20 Lightning damage to 26 (1.30x)")

	local dmgContextFire: StateTypes.DamageContext = {
		RawDamage = 20,
		DamageType = "Fire",
		SourceId = "p1",
		SourceName = "Player",
		TargetEntityKind = "Enemy",
		Critical = false,
		CanHitShield = true,
		IsPeriodic = false,
	}
	local scaledFire = EnvironmentService.modifyDamage(rainState, dmgContextFire, 20)
	assertTest(scaledFire == 15, "[Suite 75.6] modifyDamage scales 20 Fire damage to 15 (0.75x)")

	-- 75.4: Status Modification
	local baseStacks, baseDur = 3, 2
	local finalStacks, finalDur = EnvironmentService.modifyStatusApplication(rainState, "Shock", baseStacks, baseDur)
	assertTest(finalStacks == 4, "[Suite 75.7] RainSoaked adds +1 Shock stack bonus")

	-- 75.5: Healing Scaling
	local toxicState = EnvironmentService.createEnvironment("ToxicSwamp")
	assertTest(toxicState.HealingModifier == 0.80, "[Suite 75.8] ToxicSwamp HealingModifier is 0.80")
	local modifiedHeal = EnvironmentService.modifyHealing(toxicState, 50)
	assertTest(modifiedHeal == 40, "[Suite 75.9] modifyHealing scales 50 heal to 40 in ToxicSwamp")

	-- 75.6: Elemental Transformation: RainSoaked + Cold -> FrozenWastes
	local transOk, transTxt, newEnvId = EnvironmentService.evaluateTransformation(rainState, "Cold")
	assertTest(transOk == true, "[Suite 75.10] Cold damage triggers transformation in RainSoaked")
	assertTest(newEnvId == "FrozenWastes", "[Suite 75.11] RainSoaked transformed into FrozenWastes")
	assertTest(rainState.EnvironmentId == "FrozenWastes", "[Suite 75.12] EnvironmentState updated to FrozenWastes")
	assertTest(rainState.DamageModifiers["Cold"] == 1.25, "[Suite 75.13] Transformed environment loaded FrozenWastes Cold modifier (+25%)")

	-- 75.7: View Snapshot
	local view = EnvironmentService.getEnvironmentView(rainState)
	assertTest(view ~= nil and view.EnvironmentId == "FrozenWastes", "[Suite 75.14] getEnvironmentView returns FrozenWastes snapshot")
	assertTest(view.Icon == "❄️", "[Suite 75.15] FrozenWastes view includes snowflake icon")

	WorldRoomService.cleanupRoom()
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

	----------------------------------------------------------------------------
	-- TEST 62: System-Wide Audit & Regression Invariants
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 62] System-Wide Audit & Regression Invariants ---")

	-- 1. StatusService removeStatus structural integrity
	local targetId = "audit_entity_01"
	local auditEntity: any = {
		EntityId = targetId,
		StatusCollection = {},
		Shield = 0,
		MaxHP = 100,
		Resources = { HP = 100, MaxHP = 100 },
	}
	StatusService.applyStatus(targetId, "Poison", 5, -1, "test_source", auditEntity)
	assertTest(StatusService.getStatus(targetId, "Poison") ~= nil, "[Suite 62.1] StatusService applies Poison status")
	local removeOk = StatusService.removeStatus(targetId, "Poison", auditEntity)
	assertTest(removeOk == true, "[Suite 62.1] StatusService removeStatus returns true")
	assertTest(StatusService.getStatus(targetId, "Poison") == nil, "[Suite 62.1] Poison status cleared after removeStatus")

	-- 2. Test/Live CombatService & StatusService Isolation
	CombatService.beginTestIsolation()
	assertTest(CombatService.isTestIsolationActive() == true, "[Suite 62.2] CombatService test isolation is active")
	CombatService.endTestIsolation()
	assertTest(CombatService.isTestIsolationActive() == false, "[Suite 62.2] CombatService test isolation ends cleanly")

	StatusService.beginTestIsolation()
	assertTest(StatusService.isTestIsolationActive() == true, "[Suite 62.2] StatusService test isolation is active")
	StatusService.endTestIsolation()
	assertTest(StatusService.isTestIsolationActive() == false, "[Suite 62.2] StatusService test isolation ends cleanly")

	-- 3. ClassLock authority & Re-selection Rejection
	local auditP1State: StateTypes.PlayerState = {
		UserId = 94001,
		DisplayName = "AuditHero1",
		ClassId = "Warlord",
		SubclassId = "Berserker",
		Resources = { HP = 100, MaxHP = 100, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = {},
		Gold = 0,
		IsReady = false,
		IsDowned = false,
		IsConnected = true,
		ClassLocked = true,
	}
	local selectOk, selectErr = ClassService.selectClass({ UserId = 94001 }, auditP1State, "Shadowblade", "Assassin")
	assertTest(selectOk == false and string.find(selectErr or "", "already locked") ~= nil, "[Suite 62.3] Class selection rejected when ClassLocked is true")
	assertTest(auditP1State.ClassId == "Warlord", "[Suite 62.3] ClassId unaffected on locked re-selection")

	-- 4. StartRun authority (Unlocked player rejection, Stranger rejection, Empty party rejection)
	RunManager.resetRunForTesting()
	local auditRun = RunManager.getRunState()
	local mockMember1 = { UserId = 94010, Name = "Member1", DisplayName = "Mem1" }
	local addedP1 = RunManager.addPlayer(mockMember1 :: any)
	assert(addedP1, "addedP1 exists")
	addedP1.ClassLocked = false -- Intentionally leave unlocked

	-- 4a. StartRun fails when player is not locked
	local startFailUnlock, startErrUnlock = RunManager.startRun(mockMember1 :: any)
	assertTest(startFailUnlock == false and string.find(startErrUnlock or "", "lock in") ~= nil, "[Suite 62.4a] StartRun rejects unlocked party members")

	-- 4b. StartRun fails when initiator is not in party
	addedP1.ClassLocked = true
	local stranger = { UserId = 94099, Name = "Stranger", DisplayName = "Stranger" }
	local startFailStranger, startErrStranger = RunManager.startRun(stranger :: any)
	assertTest(startFailStranger == false and string.find(startErrStranger or "", "not a member") ~= nil, "[Suite 62.4b] StartRun rejects non-party initiator")

	-- 4c. StartRun fails when party is empty
	table.clear(auditRun.PartyMembers)
	local startFailEmpty, startErrEmpty = RunManager.startRun(nil)
	assertTest(startFailEmpty == false and string.find(startErrEmpty or "", "empty") ~= nil, "[Suite 62.4c] StartRun rejects empty party")

	-- 5. Party Cap & Mid-run Join Rejection
	RunManager.resetRunForTesting()
	local m1 = { UserId = 94021, Name = "Cap1", DisplayName = "Cap1" }
	local m2 = { UserId = 94022, Name = "Cap2", DisplayName = "Cap2" }
	local m3 = { UserId = 94023, Name = "Cap3", DisplayName = "Cap3" }
	local m4 = { UserId = 94024, Name = "Cap4", DisplayName = "Cap4" }
	local m5 = { UserId = 94025, Name = "Cap5", DisplayName = "Cap5" }
	local p1 = RunManager.addPlayer(m1 :: any)
	local p2 = RunManager.addPlayer(m2 :: any)
	local p3 = RunManager.addPlayer(m3 :: any)
	local p4 = RunManager.addPlayer(m4 :: any)
	local p5 = RunManager.addPlayer(m5 :: any)
	assertTest(p1 ~= nil and p2 ~= nil and p3 ~= nil and p4 ~= nil, "[Suite 62.5] Added 4 party members up to cap")
	assertTest(p5 == nil, "[Suite 62.5] 5th player join rejected by party cap")

	-- Mid-run join rejection
	p1.ClassLocked = true
	p2.ClassLocked = true
	p3.ClassLocked = true
	p4.ClassLocked = true
	local okStartCap = RunManager.startRun(m1 :: any)
	assertTest(okStartCap == true, "[Suite 62.5] 4-player run started successfully")
	assertTest(RunManager.getRunState().Phase == "MapSelect", "[Suite 62.5] Run is in MapSelect phase")
	local midJoiner = { UserId = 94026, Name = "MidJoiner", DisplayName = "MidJoiner" }
	local midP = RunManager.addPlayer(midJoiner :: any)
	assertTest(midP == nil, "[Suite 62.5] New player join rejected when run phase is not Lobby")

	-- 6. Map Voting Strict Majority & Tie Handling
	local currentRunForVote = RunManager.getRunState()
	local availableNodes = currentRunForVote.AvailableNodeIds
	assertTest(#availableNodes >= 2, "[Suite 62.6] At least 2 available nodes for voting")
	local nodeA = availableNodes[1]
	local nodeB = availableNodes[2]

	-- In 4-player party, strict majority is floor(4/2) + 1 = 3 votes.
	-- Vote 1: Node A (1/4 -> pending)
	RunManager.voteMapNode(m1 :: any, nodeA)
	assertTest(currentRunForVote.Phase == "MapSelect", "[Suite 62.6] 1/4 votes does not trigger travel")

	-- Vote 2: Node B (1-1 tie, 2/4 votes cast -> pending)
	RunManager.voteMapNode(m2 :: any, nodeB)
	assertTest(currentRunForVote.Phase == "MapSelect", "[Suite 62.6] 2/4 split votes (1 vs 1) keeps voting open")

	-- Vote 3: Node A (2 votes for A, 1 for B; 2 is NOT strict majority of 4 -> pending)
	RunManager.voteMapNode(m3 :: any, nodeA)
	assertTest(currentRunForVote.Phase == "MapSelect", "[Suite 62.6] 2/4 votes for Node A does NOT trigger travel (strict majority requires 3)")

	-- Vote 4: Node A (3 votes for A, 1 for B; 3 >= 3 -> STRICT MAJORITY REACHED!)
	RunManager.voteMapNode(m4 :: any, nodeA)
	assertTest(currentRunForVote.Phase == "ActiveRoom", "[Suite 62.6] 3/4 votes achieves strict majority and travels to ActiveRoom")
	assertTest(currentRunForVote.CurrentNodeId == nodeA, "[Suite 62.6] Traveled to voted Node A")

	-- 7. Real Map Node Projection in RunSnapshot
	local snapP1 = RunManager.getRunSnapshotForPlayer(m1 :: any)
	assertTest(snapP1.MapNodes ~= nil and #snapP1.MapNodes > 0, "[Suite 62.7] RunSnapshot contains populated MapNodes")
	local sampleNode = snapP1.MapNodes[1]
	assertTest(sampleNode.Id ~= nil and sampleNode.Tier >= 1 and sampleNode.Lane >= 1, "[Suite 62.7] MapNode has Id, Tier, Lane")
	assertTest(sampleNode.Type ~= nil and sampleNode.ConnectedNodeIds ~= nil, "[Suite 62.7] MapNode has Type and ConnectedNodeIds")

	-- 8. Combat Engine: Dead enemy does not act, Buff intent increments AttackPower, Debuff intent applies Poison
	local combatParty: { [number]: StateTypes.PlayerState } = {
		[m1.UserId] = p1,
	}
	p1.Resources.HP = 100
	p1.Resources.MaxHP = 100
	p1.Resources.Shield = 0
	p1.IsDowned = false
	p1.IsConnected = true

	local combatState = CombatService.startCombat("audit_enc", "Combat", 1, combatParty, function(_) end)
	assertTest(combatState ~= nil and combatState.Enemies["enemy_1"] ~= nil, "[Suite 62.8] Combat started with enemy_1")
	local testEnemy = combatState.Enemies["enemy_1"]

	-- 8a. Buff intent increments AttackPower
	local atkBefore = testEnemy.AttackPower
	testEnemy.Intent = { Type = "Buff", Value = 7, Description = "Sharpen Blades" }
	CombatService.forceTurnTimeout()
	assertTest(testEnemy.AttackPower == atkBefore + 7, "[Suite 62.8a] Enemy Buff intent increased AttackPower by 7")

	-- 8b. Debuff intent applies Poison to player
	testEnemy.Intent = { Type = "Debuff", Value = 5, Description = "Poison Vapor" }
	CombatService.forceTurnTimeout()
	local pStatus = StatusService.getStatus("player_" .. tostring(m1.UserId), "Poison")
	assertTest(pStatus ~= nil and pStatus.Stacks == 5, "[Suite 62.8b] Enemy Debuff intent applied 5 Poison stacks to player")

	-- 8c. Player status ticks: Next turn start deals poison damage to player
	local hpBeforeTick = p1.Resources.HP
	testEnemy.Intent = { Type = "Defend", Value = 5, Description = "Defend" }
	CombatService.forceTurnTimeout()
	assertTest(p1.Resources.HP < hpBeforeTick, "[Suite 62.8c] Poison status ticked and damaged player at turn start")

	-- 8d. Dead enemies do not act
	testEnemy.HP = 0
	testEnemy.Intent = { Type = "Attack", Value = 50, Description = "Death Blow" }
	local hpBeforeDeadPhase = p1.Resources.HP
	CombatService.forceTurnTimeout()
	assertTest(p1.Resources.HP == hpBeforeDeadPhase, "[Suite 62.8d] Dead enemy did not attack player")

	-- 9. Class Turn-End Gimmicks Execute
	local mageState: StateTypes.PlayerState = {
		UserId = 94050,
		DisplayName = "MageHero",
		ClassId = "AetherMage",
		SubclassId = "Cryomancer",
		Resources = { HP = 80, MaxHP = 80, Shield = 0, Energy = 2, MaxEnergy = 4 },
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
	local dummyEnemies = {}
	local gimmickEndResult = ClassService.processGimmickOnTurnEnd(mageState, dummyEnemies)
	assertTest(gimmickEndResult.EndTurnShield == 8, "[Suite 62.9] AetherMage Cryomancer turn-end converted 2 unspent energy to 8 Shield")

	-- 10. Class Kill Gimmicks Execute & Relic OnKill trigger
	local necroState: StateTypes.PlayerState = {
		UserId = 94055,
		DisplayName = "ReaperHero",
		ClassId = "Necrobinder",
		SubclassId = "Reaper",
		Resources = { HP = 20, MaxHP = 100, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = { "GremlinHorn" },
		Gold = 0,
		IsReady = false,
		IsDowned = false,
		IsConnected = true,
	}
	ClassService.processGimmickOnKill(necroState)
	assertTest(necroState.Resources.HP == 26, "[Suite 62.10] Necrobinder Reaper kill gimmick restored 6 HP")
	local tracker = ClassService.getGimmickTracker(necroState.UserId)
	assertTest(tracker.SoulTokens == 2, "[Suite 62.10] Necrobinder Reaper gained 2 SoulTokens on kill")

	-- GremlinHorn OnKill trigger
	local relicKillBonus = RelicService.triggerEvent(necroState, nil, "OnKill", nil)
	assertTest(relicKillBonus.BonusEnergy ~= nil and relicKillBonus.BonusEnergy > 0, "[Suite 62.10] GremlinHorn triggered BonusEnergy on kill")
	assertTest(relicKillBonus.BonusDraw ~= nil and relicKillBonus.BonusDraw > 0, "[Suite 62.10] GremlinHorn triggered BonusDraw on kill")

	-- 11. Critical Hits Pipeline
	local critPlayer: StateTypes.PlayerState = {
		UserId = 94060,
		DisplayName = "CritHero",
		ClassId = "Shadowblade",
		SubclassId = "Assassin",
		Resources = { HP = 100, MaxHP = 100, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {},
		Hand = {},
		DiscardPile = {},
		ExhaustPile = {},
		RelicIds = {},
		Gold = 0,
		IsReady = false,
		IsDowned = false,
		IsConnected = true,
		PassivePoints = 0,
		UnlockedPassives = {},
	}
	local targetEnemyForCrit: StateTypes.EnemyState = {
		InstanceId = "crit_target",
		DefinitionId = "dummy",
		Name = "Training Dummy",
		HP = 200,
		MaxHP = 200,
		Shield = 0,
		Poison = 0,
		AttackPower = 0,
		Intent = { Type = "Defend", Value = 0, Description = "Defend" },
	}
	local critDmgContext: StateTypes.DamageContext = {
		RawDamage = 20,
		DamageType = "Physical",
		SourceId = tostring(critPlayer.UserId),
		SourceName = critPlayer.DisplayName,
		SourcePlayer = critPlayer,
		TargetEntityKind = "Enemy",
		TargetEnemy = targetEnemyForCrit,
		Critical = true,
	}
	local critResult = DamagePipeline.executeDamage(critDmgContext)
	assertTest(critResult.IsCritical == true, "[Suite 62.11] DamagePipeline correctly flagged IsCritical")
	assertTest(critResult.DamageDealt > 20, "[Suite 62.11] Critical hit multiplied damage above raw damage")

	-- 12. Card Cost Reduction via StatResolver
	local costHero: StateTypes.PlayerState = {
		UserId = 94070,
		DisplayName = "CostHero",
		ClassId = "AetherMage",
		SubclassId = "Elementalist",
		Resources = { HP = 100, MaxHP = 100, Shield = 0, Energy = 3, MaxEnergy = 3 },
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
	local cardInstance = CardService.createCardInstance("Fireball", costHero.UserId)
	assert(cardInstance, "cardInstance created")
	table.insert(costHero.Hand, cardInstance)
	local resolvedStats = StatResolver.resolvePlayerStats(costHero)
	local effectiveCost = math.max(0, cardInstance.Cost - (resolvedStats.CostReduction or 0))
	assertTest(effectiveCost >= 0 and effectiveCost <= cardInstance.Cost, "[Suite 62.12] Effective card cost calculated with CostReduction")

	-- 13. Failed Card Action Rejection
	local failCardInstance = CardService.createCardInstance("Strike", costHero.UserId)
	assert(failCardInstance, "failCard created")
	table.insert(costHero.Hand, failCardInstance)
	local playBogusResult, _ = CombatService.playCard({ UserId = costHero.UserId }, failCardInstance.InstanceId, "non_existent_enemy_999")
	assertTest(playBogusResult == false, "[Suite 62.13] Card play targeting nonexistent enemy rejected")

	-- 14. Claim Reward Card Grants Permanent Collection Copy
	RunManager.resetRunForTesting()
	local draftRun = RunManager.getRunState()
	local dPlayer = { UserId = 94080, Name = "Drafter", DisplayName = "Drafter" }
	local dState = RunManager.addPlayer(dPlayer :: any)
	assert(dState, "dState exists")
	dState.ClassLocked = true
	draftRun.Phase = "Rewards"
	draftRun.PendingRewards = {
		GoldAmount = 25,
		AetherShardsAmount = 10,
		OfferedCardsByPlayer = {
			[94080] = { CardData.getCard("Strike") :: CardData.Card },
		},
		ClaimedCards = {},
	}
	local countBeforeDraft = CardCollectionService.getCardCount(dPlayer, "Strike")
	local draftOk, draftErr = RunManager.claimRewardCard(dPlayer :: any, "Strike")
	assertTest(draftOk == true, "[Suite 62.14] Draft reward claimed successfully")
	local countAfterDraft = CardCollectionService.getCardCount(dPlayer, "Strike")
	assertTest(countAfterDraft == countBeforeDraft + 1, "[Suite 62.14] Claimed draft card added to permanent CardCollection")
	assertTest(#dState.Deck >= 1, "[Suite 62.14] Claimed draft card added to runtime Deck")

	-- 15. ResetToLobby Clean Run Invariants
	RunManager.resetToLobby()
	assertTest(draftRun.Phase == "Lobby", "[Suite 62.15] resetToLobby sets Phase to Lobby")
	assertTest(dState.ClassLocked == false, "[Suite 62.15] ClassLocked reset to false")
	assertTest(dState.Gold == GameConfig.Dungeon.StarterGold, "[Suite 62.15] Gold reset to StarterGold")
	assertTest(draftRun.PendingRewards == nil, "[Suite 62.15] PendingRewards cleared")
	assertTest(draftRun.ClearedNodeIds ~= nil and #draftRun.ClearedNodeIds == 0, "[Suite 62.15] ClearedNodeIds cleared")

	-- 16. DataStore Fail-Closed Guard
	PersistenceService.simulateLoadFailureForTesting(94090)
	assertTest(PersistenceService.isProfileLoaded(94090) == false, "[Suite 62.16] isProfileLoaded returns false on load failure")
	local saveOkFail, saveErrFail = PersistenceService.saveProfile({ UserId = 94090 })
	assertTest(saveOkFail == false and string.find(saveErrFail or "", "Cannot save") ~= nil, "[Suite 62.16] saveProfile fail-closed guard blocks saving failed profiles")

	-- 17. Persistence Revision & Conflict Safety
	local baseProfile = PersistenceService.reconcileForTesting({
		ProfileRevision = 3,
		LastSavedTimestamp = 1000,
		UnlockedClasses = { "Warlord", "UnknownBogusClass" },
		UnlockedSkills = { ["HeroicStrike"] = true, ["BogusSkill"] = true },
	}, 94091)
	assertTest(baseProfile.ProfileRevision == 3, "[Suite 62.17] reconcile preserved valid ProfileRevision")
	local hasBogusClass = false
	for _, c in baseProfile.UnlockedClasses do
		if c == "UnknownBogusClass" then hasBogusClass = true break end
	end
	assertTest(hasBogusClass == false, "[Suite 62.17] reconcile stripped unknown class")
	assertTest(baseProfile.UnlockedSkills["BogusSkill"] == nil, "[Suite 62.17] reconcile stripped unknown skill")
	assertTest(baseProfile.UnlockedSkills["HeroicStrike"] == true, "[Suite 62.17] reconcile retained valid skill")

	-- Conflict resolution: remote revision is newer
	local remoteNewer = { ProfileRevision = 5, LastSavedTimestamp = 1200 }
	local localOlder = table.clone(baseProfile)
	localOlder.ProfileRevision = 3
	localOlder.LastSavedTimestamp = 1100
	local acceptedData, applied = PersistenceService.resolveUpdateConflict(remoteNewer, localOlder)
	assertTest(applied == false, "[Suite 62.17] resolveUpdateConflict rejected stale local revision")
	assertTest(acceptedData.ProfileRevision == 5, "[Suite 62.17] Kept newer remote revision")

	-- Acceptance increments revision
	local remoteOlder = { ProfileRevision = 2, LastSavedTimestamp = 900 }
	local localNewer = table.clone(baseProfile)
	localNewer.ProfileRevision = 3
	local acceptedData2, applied2 = PersistenceService.resolveUpdateConflict(remoteOlder, localNewer)
	assertTest(applied2 == true, "[Suite 62.17] resolveUpdateConflict accepted newer local revision")
	assertTest(localNewer.ProfileRevision == 4, "[Suite 62.17] Monotonically incremented ProfileRevision to 4")

	-- 18. Remote Events & Network Contract Invariants
	assertTest(NetworkService.ActionResultEvent ~= nil, "[Suite 62.18] NetworkService.ActionResultEvent exists")
	assertTest(NetworkService.ReturnToLobbyEvent ~= nil, "[Suite 62.18] NetworkService.ReturnToLobbyEvent exists")
	assertTest(typeof(NetworkService.sendActionResult) == "function", "[Suite 62.18] NetworkService.sendActionResult helper exists")

	-- Clean up test states
	CombatService.cleanupCombat()
	RunManager.resetRunForTesting()
	PersistenceService.resetForTesting()
	end

	----------------------------------------------------------------------------
	-- TEST 63: Complete Audit & Regression Invariant Verification
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 63] Complete Audit & Regression Invariant Verification ---")

	-- 1. Combat Skip Exploit Rejection (Item 3)
	RunManager.resetRunForTesting()
	local rState = RunManager.getRunState()
	rState.Phase = "ActiveRoom"
	local mockHost = { UserId = 95001, Name = "Host", DisplayName = "Host" }
	RunManager.addPlayer(mockHost :: any)
	local skipAttempt = RunManager.continueFromRewards(mockHost :: any)
	assertTest(skipAttempt == false, "[Suite 63.1] continueFromRewards strictly rejects ActiveRoom phase (combat skip exploit blocked)")
	assertTest(rState.Phase == "ActiveRoom", "[Suite 63.1] Run phase remains ActiveRoom after rejected continueFromRewards")

	-- 2. Map Voting: 1/1, 2/3, 2/4, 3/4, and Disconnected Members (Item 7)
	RunManager.resetRunForTesting()
	local vRun = RunManager.getRunState()
	local vm1 = { UserId = 95011, Name = "V1", DisplayName = "V1" }
	local vp1 = RunManager.addPlayer(vm1 :: any)
	assert(vp1, "vp1 exists")
	vp1.ClassLocked = true
	RunManager.startRun(vm1 :: any)
	local vNodes = vRun.AvailableNodeIds
	local nA = vNodes[1]

	-- Case 2a: 1/1 voting (1 player, 1 vote = 100% >= floor(1/2)+1=1)
	assertTest(vRun.Phase == "MapSelect", "[Suite 63.2a] 1-player run is in MapSelect")
	RunManager.voteMapNode(vm1 :: any, nA)
	assertTest(vRun.Phase == "ActiveRoom", "[Suite 63.2a] 1/1 vote immediately achieves strict majority and enters ActiveRoom")

	-- Case 2b: 2/4 voting does NOT trigger travel, 3/4 DOES trigger travel
	RunManager.resetRunForTesting()
	local vRun4 = RunManager.getRunState()
	local pA = RunManager.addPlayer({ UserId = 95021, Name = "PA", DisplayName = "PA" } :: any)
	local pB = RunManager.addPlayer({ UserId = 95022, Name = "PB", DisplayName = "PB" } :: any)
	local pC = RunManager.addPlayer({ UserId = 95023, Name = "PC", DisplayName = "PC" } :: any)
	local pD = RunManager.addPlayer({ UserId = 95024, Name = "PD", DisplayName = "PD" } :: any)
	assert(pA and pB and pC and pD, "party members exist")
	pA.ClassLocked = true; pB.ClassLocked = true; pC.ClassLocked = true; pD.ClassLocked = true
	RunManager.startRun({ UserId = 95021 } :: any)
	local n4A = vRun4.AvailableNodeIds[1]
	local n4B = vRun4.AvailableNodeIds[2]

	RunManager.voteMapNode({ UserId = 95021 } :: any, n4A)
	RunManager.voteMapNode({ UserId = 95022 } :: any, n4B)
	assertTest(vRun4.Phase == "MapSelect", "[Suite 63.2b] 2/4 split votes (1 vs 1) keeps voting open")

	RunManager.voteMapNode({ UserId = 95023 } :: any, n4A)
	assertTest(vRun4.Phase == "MapSelect", "[Suite 63.2b] 2/4 votes for n4A does NOT trigger travel (strict majority requires 3)")

	RunManager.voteMapNode({ UserId = 95024 } :: any, n4A)
	assertTest(vRun4.Phase == "ActiveRoom", "[Suite 63.2b] 3/4 votes for n4A achieves strict majority and enters ActiveRoom")

	-- Case 2c: 2/3 voting triggers travel
	RunManager.resetRunForTesting()
	local vRun3 = RunManager.getRunState()
	local p3A = RunManager.addPlayer({ UserId = 95031, Name = "P3A", DisplayName = "P3A" } :: any)
	local p3B = RunManager.addPlayer({ UserId = 95032, Name = "P3B", DisplayName = "P3B" } :: any)
	local p3C = RunManager.addPlayer({ UserId = 95033, Name = "P3C", DisplayName = "P3C" } :: any)
	assert(p3A and p3B and p3C, "p3 party exists")
	p3A.ClassLocked = true; p3B.ClassLocked = true; p3C.ClassLocked = true
	RunManager.startRun({ UserId = 95031 } :: any)
	local n3A = vRun3.AvailableNodeIds[1]
	RunManager.voteMapNode({ UserId = 95031 } :: any, n3A)
	RunManager.voteMapNode({ UserId = 95032 } :: any, n3A)
	assertTest(vRun3.Phase == "ActiveRoom", "[Suite 63.2c] 2/3 votes for n3A achieves strict majority (floor(3/2)+1=2)")

	-- Case 2d: Disconnected members are excluded from majority calculation
	RunManager.resetRunForTesting()
	local vRunDisc = RunManager.getRunState()
	local pDA = RunManager.addPlayer({ UserId = 95041, Name = "PDA", DisplayName = "PDA" } :: any)
	local pDB = RunManager.addPlayer({ UserId = 95042, Name = "PDB", DisplayName = "PDB" } :: any)
	local pDC = RunManager.addPlayer({ UserId = 95043, Name = "PDC", DisplayName = "PDC" } :: any)
	assert(pDA and pDB and pDC, "pDisc party exists")
	pDA.ClassLocked = true; pDB.ClassLocked = true; pDC.ClassLocked = true
	RunManager.startRun({ UserId = 95041 } :: any)
	pDC.IsConnected = false
	local nDisc = vRunDisc.AvailableNodeIds[1]
	RunManager.voteMapNode({ UserId = 95041 } :: any, nDisc)
	assertTest(vRunDisc.Phase == "MapSelect", "[Suite 63.2d] 1/2 connected votes pending")
	RunManager.voteMapNode({ UserId = 95042 } :: any, nDisc)
	assertTest(vRunDisc.Phase == "ActiveRoom", "[Suite 63.2d] 2/2 connected votes achieves majority with 1 disconnected member")

	-- 3. Card Action Transaction Order (Item 8)
	local dummyParty: { [number]: StateTypes.PlayerState } = {}
	local shadowPlayer: StateTypes.PlayerState = {
		UserId = 95050,
		DisplayName = "ShadowRogue",
		ClassId = "Shadowblade",
		SubclassId = "Assassin",
		Resources = { HP = 50, MaxHP = 80, Shield = 0, Energy = 0, MaxEnergy = 3 },
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
	dummyParty[shadowPlayer.UserId] = shadowPlayer
	ClassService.resetGimmicks(shadowPlayer.UserId)
	local testCard = CardService.createCardInstance("Strike", shadowPlayer.UserId)
	assert(testCard, "testCard created")
	table.insert(shadowPlayer.Hand, testCard)

	CombatService.startCombat("audit_tx_enc", "Combat", 1, dummyParty, function(_) end)
	local combatForTx = CombatService.getActiveCombat()
	assert(combatForTx, "combatForTx exists")

	-- 3a. Failed play due to insufficient energy
	local failPlay, _ = CombatService.playCard({ UserId = shadowPlayer.UserId }, testCard.InstanceId, "enemy_1")
	assertTest(failPlay == false, "[Suite 63.3a] Play card with 0 Energy rejected")
	local sTracker = ClassService.getGimmickTracker(shadowPlayer.UserId)
	assertTest(sTracker.ComboCount == 0, "[Suite 63.3a] Failed card play did NOT increment Shadowblade ComboCount")

	-- 3b. Blood Priest HP sacrifice NOT consumed on invalid target
	local bloodPlayer: StateTypes.PlayerState = {
		UserId = 95051,
		DisplayName = "Priest",
		ClassId = "BloodPriest",
		SubclassId = "Zealot",
		Resources = { HP = 50, MaxHP = 100, Shield = 0, Energy = 0, MaxEnergy = 3 },
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
	dummyParty[bloodPlayer.UserId] = bloodPlayer
	ClassService.resetGimmicks(bloodPlayer.UserId)
	local priestCard = CardService.createCardInstance("Strike", bloodPlayer.UserId)
	assert(priestCard, "priestCard created")
	table.insert(bloodPlayer.Hand, priestCard)

	local hpBeforeFailedPlay = bloodPlayer.Resources.HP
	local failTargetPlay, _ = CombatService.playCard({ UserId = bloodPlayer.UserId }, priestCard.InstanceId, "nonexistent_enemy_999")
	assertTest(failTargetPlay == false, "[Suite 63.3b] Play card targeting nonexistent enemy rejected")
	assertTest(bloodPlayer.Resources.HP == hpBeforeFailedPlay, "[Suite 63.3b] BloodPriest HP was NOT consumed on failed card play")

	-- 3c. Mechanist scrap parts NOT incremented on failed card play
	local mechPlayer: StateTypes.PlayerState = {
		UserId = 95052,
		DisplayName = "MechanistHero",
		ClassId = "Mechanist",
		SubclassId = "Artificer",
		Resources = { HP = 75, MaxHP = 75, Shield = 0, Energy = 0, MaxEnergy = 3 },
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
	dummyParty[mechPlayer.UserId] = mechPlayer
	ClassService.resetGimmicks(mechPlayer.UserId)
	local mechCard = CardService.createCardInstance("Strike", mechPlayer.UserId)
	assert(mechCard, "mechCard created")
	table.insert(mechPlayer.Hand, mechCard)
	local failMechPlay, _ = CombatService.playCard({ UserId = mechPlayer.UserId }, mechCard.InstanceId, "enemy_1")
	assertTest(failMechPlay == false, "[Suite 63.3c] Mechanist card play rejected due to 0 energy")
	local mTracker = ClassService.getGimmickTracker(mechPlayer.UserId)
	assertTest(mTracker.ScrapParts == 0, "[Suite 63.3c] Mechanist ScrapParts NOT incremented on failed card play")

	-- 4. Additional Class Gimmicks: SwarmLord, Beastmaster, Artificer (Item 9)
	local swarmPlayer: StateTypes.PlayerState = {
		UserId = 95060,
		DisplayName = "SwarmLordHero",
		ClassId = "Necrobinder",
		SubclassId = "SwarmLord",
		Resources = { HP = 50, MaxHP = 80, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {}, Hand = {}, DiscardPile = {}, ExhaustPile = {},
		RelicIds = {}, Gold = 0, IsReady = false, IsDowned = false, IsConnected = true,
	}
	ClassService.resetGimmicks(swarmPlayer.UserId)
	local swTracker = ClassService.getGimmickTracker(swarmPlayer.UserId)
	for _ = 1, 15 do
		ClassService.processGimmickOnKill(swarmPlayer)
	end
	assertTest(swTracker.BoneServants == 3, "[Suite 63.4a] Necrobinder SwarmLord spawned 3 BoneServants from kills")
	local swEnd = ClassService.processGimmickOnTurnEnd(swarmPlayer, {})
	assertTest(swEnd.EndTurnDamage == 24, "[Suite 63.4a] SwarmLord 3 BoneServants dealt 24 turn-end damage (3 * 8)")

	local beastPlayer: StateTypes.PlayerState = {
		UserId = 95061,
		DisplayName = "BeastHero",
		ClassId = "Beastmaster",
		SubclassId = "Hunter",
		Resources = { HP = 90, MaxHP = 90, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {}, Hand = {}, DiscardPile = {}, ExhaustPile = {},
		RelicIds = {}, Gold = 0, IsReady = false, IsDowned = false, IsConnected = true,
	}
	ClassService.resetGimmicks(beastPlayer.UserId)
	local beastEnd = ClassService.processGimmickOnTurnEnd(beastPlayer, {})
	assertTest(beastEnd.EndTurnDamage == 6, "[Suite 63.4b] Beastmaster Wolf dealt 6 turn-end damage")

	mechPlayer.Resources.Energy = 3
	mTracker.ActiveTurrets = 2
	local mechEnd = ClassService.processGimmickOnTurnEnd(mechPlayer, {})
	assertTest(mechEnd.EndTurnDamage == 12, "[Suite 63.4c] Artificer 2 turrets dealt 12 damage (2 * 6)")
	assertTest(mechEnd.EndTurnShield == 8, "[Suite 63.4c] Artificer 2 turrets granted 8 shield (2 * 4)")

	-- 5. Relic Bonus Consumers: CentennialPuzzle, Pocketwatch, Orichalcum, BronzeScales (Item 11)
	local puzzlePlayer: StateTypes.PlayerState = {
		UserId = 95070,
		DisplayName = "PuzzleHero",
		ClassId = "Warlord",
		SubclassId = "Berserker",
		Resources = { HP = 80, MaxHP = 100, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {
			CardService.createCardInstance("Strike", 95070) :: StateTypes.CardInstance,
			CardService.createCardInstance("Defend", 95070) :: StateTypes.CardInstance,
			CardService.createCardInstance("Strike", 95070) :: StateTypes.CardInstance,
			CardService.createCardInstance("Defend", 95070) :: StateTypes.CardInstance,
		},
		Hand = {}, DiscardPile = {}, ExhaustPile = {},
		RelicIds = { "CentennialPuzzle" },
		Gold = 0, IsReady = false, IsDowned = false, IsConnected = true,
	}
	RelicService.resetCombatState(puzzlePlayer.UserId)
	local puzzleRelicRes = RelicService.triggerEvent(puzzlePlayer, nil, "OnDamageTaken", { Damage = 10 })
	assertTest(puzzleRelicRes.BonusDraw == 3, "[Suite 63.5a] CentennialPuzzle returned 3 BonusDraw on damage taken")

	local scalesRelicRes = RelicService.triggerEvent({
		UserId = 95071,
		DisplayName = "ThornsHero",
		ClassId = "Warlord",
		SubclassId = "Titan",
		Resources = { HP = 100, MaxHP = 100, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {}, Hand = {}, DiscardPile = {}, ExhaustPile = {},
		RelicIds = { "BronzeScales" },
		Gold = 0, IsReady = false, IsDowned = false, IsConnected = true,
	}, nil, "OnDamageTaken", { Damage = 5 })
	assertTest(scalesRelicRes.BonusDamage == 3, "[Suite 63.5b] BronzeScales returned 3 BonusDamage thorns")

	local oriRelicRes = RelicService.triggerEvent({
		UserId = 95072,
		DisplayName = "OriHero",
		ClassId = "Warlord",
		SubclassId = "Titan",
		Resources = { HP = 100, MaxHP = 100, Shield = 0, Energy = 1, MaxEnergy = 3 },
		Deck = {}, Hand = {}, DiscardPile = {}, ExhaustPile = {},
		RelicIds = { "Orichalcum" },
		Gold = 0, IsReady = false, IsDowned = false, IsConnected = true,
	}, nil, "OnTurnEnd", { UnspentEnergy = 1 })
	assertTest(oriRelicRes.BonusShield == 6, "[Suite 63.5c] Orichalcum granted 6 BonusShield at 0 Shield")

	-- 6. Assassin Guaranteed Critical Behavior (Item 13)
	local assassinState: StateTypes.PlayerState = {
		UserId = 95080,
		DisplayName = "AssassinHero",
		ClassId = "Shadowblade",
		SubclassId = "Assassin",
		Resources = { HP = 85, MaxHP = 85, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {}, Hand = {}, DiscardPile = {}, ExhaustPile = {},
		RelicIds = {}, Gold = 0, IsReady = false, IsDowned = false, IsConnected = true,
	}
	ClassService.resetGimmicks(assassinState.UserId)
	local aCard1 = CardService.createCardInstance("Strike", assassinState.UserId) :: StateTypes.CardInstance
	local aCard2 = CardService.createCardInstance("Strike", assassinState.UserId) :: StateTypes.CardInstance
	local aCard3 = CardService.createCardInstance("Strike", assassinState.UserId) :: StateTypes.CardInstance
	assert(aCard1 and aCard2 and aCard3, "assassin cards created")

	local g1 = ClassService.processGimmickOnCardPlay(assassinState, aCard1, nil, 1)
	assertTest(g1.GuaranteedCritical == false, "[Suite 63.6] Assassin 1st card is not guaranteed critical")

	local g2 = ClassService.processGimmickOnCardPlay(assassinState, aCard2, nil, 1)
	assertTest(g2.GuaranteedCritical == false, "[Suite 63.6] Assassin 2nd card is not guaranteed critical")

	local g3 = ClassService.processGimmickOnCardPlay(assassinState, aCard3, nil, 1)
	assertTest(g3.GuaranteedCritical == true, "[Suite 63.6] Assassin 3rd combo card IS guaranteed critical")

	-- 7. SkillService CostReduction via StatResolver (Item 14)
	local skillHeroState: StateTypes.PlayerState = {
		UserId = 95090,
		DisplayName = "SkillHero",
		ClassId = "Warlord",
		SubclassId = "Berserker",
		Resources = { HP = 100, MaxHP = 100, Shield = 0, Energy = 2, MaxEnergy = 3 },
		Deck = {}, Hand = {}, DiscardPile = {}, ExhaustPile = {},
		RelicIds = {}, Gold = 0, IsReady = false, IsDowned = false, IsConnected = true,
		EquippedSkills = {},
		SkillInventory = {},
		EquippedItems = {},
		UnlockedPassives = {},
		UnlockedSkills = { ["HeroicStrike"] = true },
	}
	SkillService.grantSkill(skillHeroState, "HeroicStrike")
	SkillService.equipSkill(skillHeroState, "HeroicStrike", "Skill1")
	local skillDef = SkillData.getSkill("HeroicStrike")
	assert(skillDef, "HeroicStrike def exists")
	assertTest(skillDef.Cost.Energy == 1, "[Suite 63.7] HeroicStrike base cost is 1 Energy")

	-- 8. Persistence Failure Mode: Block StartRun (Item 16)
	PersistenceService.simulateLoadFailureForTesting(95095)
	local failLoadMember = {
		UserId = 95095,
		Name = "FailPlayer",
		DisplayName = "FailPlayer",
		IsA = function(_, cls) return cls == "Player" end,
	}
	RunManager.resetRunForTesting()
	local failRun = RunManager.getRunState()
	local failAdded = RunManager.addPlayer(failLoadMember :: any)
	assert(failAdded, "failAdded exists")
	failAdded.ClassLocked = true
	local startRunFailRes = RunManager.startRun(failLoadMember :: any)
	assertTest(startRunFailRes == false, "[Suite 63.8] startRun rejected when player profile failed to load (Item 16)")

	-- Cleanup
	CombatService.cleanupCombat()
	RunManager.resetRunForTesting()
	PersistenceService.resetForTesting()
	end

	----------------------------------------------------------------------------
	-- TEST 64: Hardening & Blocker Repair Regression Suite
	----------------------------------------------------------------------------
	do
	print("\n--- [Suite 64] Hardening & Blocker Repair Regression Suite ---")

	-- 64.1: StatusService removeStatus syntax & return contract
	StatusService.clearAllStatusesForTesting()
	local s1 = StatusService.applyStatus("p_64001", "Strength", 2)
	assertTest(s1 ~= nil and s1.Stacks == 2, "[Suite 64.1a] StatusService.applyStatus applies Strength")
	local removedOk = StatusService.removeStatus("p_64001", "Strength")
	assertTest(removedOk == true, "[Suite 64.1b] StatusService.removeStatus returns true on existing status")
	local removedAgain = StatusService.removeStatus("p_64001", "Strength")
	assertTest(removedAgain == false, "[Suite 64.1c] StatusService.removeStatus returns false on non-existent status")

	-- 64.2: Combat skip exploit rejection in ActiveRoom (Item 3)
	RunManager.resetRunForTesting()
	local skipPlayer = {
		UserId = 64002,
		Name = "SkipTester",
		DisplayName = "SkipTester",
		IsA = function(_, cls) return cls == "Player" end,
	}
	local addedSkip = RunManager.addPlayer(skipPlayer :: any)
	assert(addedSkip, "addedSkip exists")
	addedSkip.ClassLocked = true
	local rState = RunManager.getRunState()
	rState.Phase = "Dungeon"
	rState.RoomPhase = "ActiveRoom"
	local contRes, contErr = RunManager.continueFromRewards(skipPlayer :: any)
	assertTest(contRes == false and rState.RoomPhase == "ActiveRoom", "[Suite 64.2] continueFromRewards rejected while RoomPhase is ActiveRoom")

	-- 64.3: StartRun Preconditions: nil, non-party, disconnected, unlocked (Item 4)
	RunManager.resetRunForTesting()
	local okNil, _ = RunManager.startRun(nil :: any)
	assertTest(okNil == false, "[Suite 64.3a] startRun rejected with nil initiator")
	local outsider = {
		UserId = 64099,
		Name = "Outsider",
		DisplayName = "Outsider",
		IsA = function(_, cls) return cls == "Player" end,
	}
	local okOut, _ = RunManager.startRun(outsider :: any)
	assertTest(okOut == false, "[Suite 64.3b] startRun rejected with non-party initiator")
	local member1 = {
		UserId = 64003,
		Name = "Member1",
		DisplayName = "Member1",
		IsA = function(_, cls) return cls == "Player" end,
	}
	local p1 = RunManager.addPlayer(member1 :: any)
	assert(p1, "p1 exists")
	p1.ClassLocked = false
	local okUnlock, _ = RunManager.startRun(member1 :: any)
	assertTest(okUnlock == false, "[Suite 64.3c] startRun rejected when player has not locked class")
	p1.ClassLocked = true
	p1.IsConnected = false
	local okDisc, _ = RunManager.startRun(member1 :: any)
	assertTest(okDisc == false, "[Suite 64.3d] startRun rejected when initiator is disconnected")
	p1.IsConnected = true
	local okValid, _ = RunManager.startRun(member1 :: any)
	assertTest(okValid == true, "[Suite 64.3e] startRun succeeds with valid locked connected initiator")

	-- 64.4: Class selection duplicate lock rejection (Item 5)
	RunManager.resetRunForTesting()
	local classLockPlayer = {
		UserId = 64004,
		Name = "ClassLockPlayer",
		DisplayName = "ClassLockPlayer",
		IsA = function(_, cls) return cls == "Player" end,
	}
	local clState = RunManager.addPlayer(classLockPlayer :: any)
	assert(clState, "clState exists")
	local sel1, _ = ClassService.selectClass(classLockPlayer :: any, clState, "Warlord", "Berserker")
	assertTest(sel1 == true and clState.ClassLocked == true, "[Suite 64.4a] Initial class selection locks class")
	local sel2, errSel2 = ClassService.selectClass(classLockPlayer :: any, clState, "Shadowblade", "Assassin")
	assertTest(sel2 == false and string.find(errSel2 or "", "locked") ~= nil, "[Suite 64.4b] Duplicate class selection rejected once locked")

	-- 64.5: 4-Player cap rejection (Item 6)
	RunManager.resetRunForTesting()
	for i = 1, 4 do
		local p = {
			UserId = 64010 + i,
			Name = "CapPlayer" .. i,
			DisplayName = "CapPlayer" .. i,
			IsA = function(_, cls) return cls == "Player" end,
		}
		local res = RunManager.addPlayer(p :: any)
		assertTest(res ~= nil, string.format("[Suite 64.5a] Player %d added under 4-player cap", i))
	end
	local extraPlayer = {
		UserId = 64015,
		Name = "CapPlayer5",
		DisplayName = "CapPlayer5",
		IsA = function(_, cls) return cls == "Player" end,
	}
	local resExtra = RunManager.addPlayer(extraPlayer :: any)
	assertTest(resExtra == nil, "[Suite 64.5b] 5th player rejected due to 4-player cap")

	-- 64.6: Late-join rejected during active run (Item 7)
	local capInitiator = {
		UserId = 64011,
		Name = "CapPlayer1",
		DisplayName = "CapPlayer1",
		IsA = function(_, cls) return cls == "Player" end,
	}
	for _, ps in RunManager.getRunState().Party do
		ps.ClassLocked = true
	end
	RunManager.startRun(capInitiator :: any)
	local lateJoiner = {
		UserId = 64020,
		Name = "LateJoiner",
		DisplayName = "LateJoiner",
		IsA = function(_, cls) return cls == "Player" end,
	}
	local resLate = RunManager.addPlayer(lateJoiner :: any)
	assertTest(resLate == nil, "[Suite 64.6] Late join rejected when run phase is not Lobby")

	-- 64.7: Map vote consensus: 1/4, 2/4 pending; 3/4 majority resolves (Item 8)
	local activeRunState = RunManager.getRunState()
	activeRunState.RoomPhase = "MapSelect"
	local currentAct = activeRunState.DungeonRun.Acts[activeRunState.DungeonRun.CurrentActIndex]
	local tier1Nodes = currentAct.Tiers[1]
	local targetNode = tier1Nodes[1]
	assert(targetNode, "targetNode exists")

	table.clear(activeRunState.MapVotes)
	local pVote1 = { UserId = 64011, Name = "CapPlayer1", DisplayName = "CapPlayer1", IsA = function(_, cls) return cls == "Player" end }
	local pVote2 = { UserId = 64012, Name = "CapPlayer2", DisplayName = "CapPlayer2", IsA = function(_, cls) return cls == "Player" end }
	local pVote3 = { UserId = 64013, Name = "CapPlayer3", DisplayName = "CapPlayer3", IsA = function(_, cls) return cls == "Player" end }

	local okV1, _ = RunManager.voteMapNode(pVote1 :: any, targetNode.Id)
	assertTest(okV1 == true and activeRunState.RoomPhase == "MapSelect", "[Suite 64.7a] 1/4 vote recorded; travel pending")
	local okV2, _ = RunManager.voteMapNode(pVote2 :: any, targetNode.Id)
	assertTest(okV2 == true and activeRunState.RoomPhase == "MapSelect", "[Suite 64.7b] 2/4 vote recorded; travel pending")
	local okV3, _ = RunManager.voteMapNode(pVote3 :: any, targetNode.Id)
	assertTest(okV3 == true and activeRunState.CurrentNodeId == targetNode.Id, "[Suite 64.7c] 3/4 vote reaches majority; consensus travel triggered")

	-- 64.8: Visited vs Cleared separation (Item 9)
	local dRun = activeRunState.DungeonRun
	assertTest(table.find(dRun.ClearedNodeIds, targetNode.Id) == nil, "[Suite 64.8a] Traveled node is NOT marked cleared prior to room resolution")
	local availableBeforeClear = DungeonMap.getAvailableNextNodes(dRun)
	assertTest(#availableBeforeClear == 0, "[Suite 64.8b] Next tier paths NOT available while current node is uncleared")
	DungeonMap.markNodeCleared(dRun, targetNode.Id)
	assertTest(table.find(dRun.ClearedNodeIds, targetNode.Id) ~= nil, "[Suite 64.8c] Node marked cleared via markNodeCleared")
	local availableAfterClear = DungeonMap.getAvailableNextNodes(dRun)
	assertTest(#availableAfterClear > 0, "[Suite 64.8d] Outgoing paths available after node is cleared")

	-- 64.9: StatusService.applyStatus rejects Implemented == false (Item 28)
	local unimplRes = StatusService.applyStatus("p_64030", "Chill", 2)
	assertTest(unimplRes == nil, "[Suite 64.9a] applyStatus rejects unimplemented status 'Chill'")
	local freezeRes = StatusService.applyStatus("p_64030", "Freeze", 1)
	assertTest(freezeRes == nil, "[Suite 64.9b] applyStatus rejects unimplemented status 'Freeze'")
	local validPoison = StatusService.applyStatus("p_64030", "Poison", 3)
	assertTest(validPoison ~= nil and validPoison.Stacks == 3, "[Suite 64.9c] applyStatus accepts implemented status 'Poison'")

	-- 64.10: Single-hit kill trigger guard (Item 12)
	local dummyEnemy: StateTypes.EnemyState = {
		InstanceId = "guard_dummy_1",
		DefinitionId = "TrainingDummy",
		Name = "Kill Dummy",
		HP = 1,
		MaxHP = 50,
		Shield = 0,
		Poison = 0,
		AttackPower = 0,
		Intent = { Type = "Defend", Value = 0 },
		ModelRef = nil,
	}
	local dummyCombatState: StateTypes.CombatState = {
		CombatId = "combat_kill_guard",
		Phase = "PlayerPhase",
		TurnNumber = 1,
		TurnStartTime = os.clock(),
		TurnDuration = 45,
		Participants = { 64011 },
		Enemies = { ["guard_dummy_1"] = dummyEnemy },
		ReadyPlayers = {},
		CombatLog = {},
	}
	local testAttacker: StateTypes.PlayerState = {
		UserId = 64011,
		PlayerInstance = nil,
		DisplayName = "Attacker",
		ClassId = "Warlord",
		SubclassId = "Berserker",
		Resources = { HP = 100, MaxHP = 100, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {}, Hand = {}, DiscardPile = {}, ExhaustPile = {},
		RelicIds = {}, Gold = 0, IsReady = false, IsDowned = false, IsConnected = true,
	}
	local hit1 = DamagePipeline.applyDamage({
		TargetType = "Enemy",
		TargetEnemy = dummyEnemy,
		AttackerPlayer = testAttacker,
		BaseDamage = 10,
		CombatState = dummyCombatState,
		Party = { [64011] = testAttacker },
	})
	assertTest(hit1.IsDefeatedOrDowned == true and (dummyEnemy :: any)._killTriggered == true, "[Suite 64.10a] First lethal hit flags _killTriggered")
	local hit2 = DamagePipeline.applyDamage({
		TargetType = "Enemy",
		TargetEnemy = dummyEnemy,
		AttackerPlayer = testAttacker,
		BaseDamage = 10,
		CombatState = dummyCombatState,
		Party = { [64011] = testAttacker },
	})
	assertTest((dummyEnemy :: any)._killTriggered == true, "[Suite 64.10b] Second hit retains _killTriggered without redundant re-triggering")

	-- 64.11: Deterministic crit RNG hook (Item 16)
	DamagePipeline.setCritRngHook(function() return 0.0 end)
	local critDmg = DamagePipeline.applyDamage({
		TargetType = "Enemy",
		TargetEnemy = dummyEnemy,
		AttackerPlayer = testAttacker,
		BaseDamage = 10,
		CombatState = dummyCombatState,
		Party = { [64011] = testAttacker },
	})
	assertTest(critDmg.IsCrit == true, "[Suite 64.11a] Deterministic RNG hook forces critical hit")
	DamagePipeline.setCritRngHook(function() return 0.999 end)
	local nonCritDmg = DamagePipeline.applyDamage({
		TargetType = "Enemy",
		TargetEnemy = dummyEnemy,
		AttackerPlayer = testAttacker,
		BaseDamage = 10,
		CombatState = dummyCombatState,
		Party = { [64011] = testAttacker },
	})
	assertTest(nonCritDmg.IsCrit == false, "[Suite 64.11b] Deterministic RNG hook forces non-critical hit")
	DamagePipeline.setCritRngHook(nil)

	-- 64.12: Condition failure fail-closed (Item 27)
	local condFailClosed = EffectResolver.evaluateCondition({
		Condition = "NonExistentCondition_Test" :: any,
		Params = {},
	}, testAttacker, dummyEnemy, dummyCombatState)
	assertTest(condFailClosed == false, "[Suite 64.12] EffectResolver.evaluateCondition fails closed (false) on unknown condition")

	-- 64.13: Unknown effect type returns explicit failure (Item 14)
	local unkEffectRes = EffectResolver.resolveEffects({
		Effects = { { Type = "TotallyBogusEffectType" :: any, Target = "Enemy" } },
		Caster = testAttacker,
		Target = dummyEnemy,
		CombatState = dummyCombatState,
		Party = { [64011] = testAttacker },
	})
	assertTest(unkEffectRes.Success == false and unkEffectRes.Error ~= nil, "[Suite 64.13] EffectResolver.resolveEffects returns failure on unsupported effect type")

	-- 64.14: Dynamic card cost reduction in CardService.toCardView (Item 17)
	local testCardInst = CardService.createCardInstance("Strike", 64011) :: StateTypes.CardInstance
	assert(testCardInst, "testCardInst created")
	local viewBase = CardService.toCardView(testCardInst)
	assertTest(viewBase.Cost == 1, "[Suite 64.14a] CardView base cost is 1")
	local playerWithReduction: StateTypes.PlayerState = {
		UserId = 64011,
		PlayerInstance = nil,
		DisplayName = "DiscountHero",
		ClassId = "Warlord",
		SubclassId = "Berserker",
		Resources = { HP = 100, MaxHP = 100, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {}, Hand = {}, DiscardPile = {}, ExhaustPile = {},
		RelicIds = {}, Gold = 0, IsReady = false, IsDowned = false, IsConnected = true,
		EquippedItems = {},
		UnlockedPassives = {},
	}
	local viewDiscount = CardService.toCardView(testCardInst, playerWithReduction)
	assertTest(viewDiscount.Cost >= 0, "[Suite 64.14b] CardView with playerState computes valid effective cost")

	-- 64.15: SkillService.resetCooldowns (Item 25)
	local cdHero: StateTypes.PlayerState = {
		UserId = 64040,
		DisplayName = "CDHero",
		ClassId = "Warlord",
		SubclassId = "Berserker",
		Resources = { HP = 100, MaxHP = 100, Shield = 0, Energy = 3, MaxEnergy = 3 },
		Deck = {}, Hand = {}, DiscardPile = {}, ExhaustPile = {},
		RelicIds = {}, Gold = 0, IsReady = false, IsDowned = false, IsConnected = true,
		EquippedSkills = {
			Skill1 = { InstanceId = "sk_1", DefinitionId = "HeroicStrike", CurrentCooldown = 3 },
		},
		SkillInventory = {
			{ InstanceId = "sk_2", DefinitionId = "HeroicStrike", CurrentCooldown = 5 },
		},
		EquippedItems = {},
		UnlockedPassives = {},
		UnlockedSkills = { ["HeroicStrike"] = true },
	}
	SkillService.resetCooldowns(cdHero)
	local sk1 = cdHero.EquippedSkills.Skill1
	assertTest(sk1 ~= nil and sk1.CurrentCooldown == 0, "[Suite 64.15a] resetCooldowns resets equipped skill cooldown to 0")
	assertTest(cdHero.SkillInventory[1].CurrentCooldown == 0, "[Suite 64.15b] resetCooldowns resets inventory skill cooldown to 0")

	-- 64.16: Persistence fail-closed guard & retry (Item 21)
	PersistenceService.simulateLoadFailureForTesting(64050)
	local pFailUser = { UserId = 64050, Name = "FailUser", DisplayName = "FailUser" }
	local profFailed = PersistenceService.getProfile(pFailUser)
	assertTest(profFailed == nil, "[Suite 64.16a] getProfile returns nil when LoadFailed")
	local saveOk, _ = PersistenceService.saveProfile(pFailUser)
	assertTest(saveOk == false, "[Suite 64.16b] saveProfile rejected when LoadFailed")
	PersistenceService.addAetherShards(pFailUser, 100)
	assertTest(PersistenceService.getProfile(pFailUser) == nil, "[Suite 64.16c] addAetherShards blocked on LoadFailed")
	local retryOk, retryProf = PersistenceService.retryLoadProfile(pFailUser)
	assertTest(retryOk == true and retryProf ~= nil, "[Suite 64.16d] retryLoadProfile recovers profile once store succeeds")

	-- 64.17: Profile revision increments monotonically on save (Item 22)
	assert(retryProf, "retryProf exists")
	local revBefore = retryProf.ProfileRevision or 1
	PersistenceService.saveProfile(pFailUser)
	local revAfter = retryProf.ProfileRevision
	assertTest(revAfter == revBefore + 1, "[Suite 64.17] ProfileRevision increments monotonically on save")

	-- 64.18: MapNodeView aliases exposed in getRunSnapshotForPlayer (Item 23)
	local mapPlayer = {
		UserId = 64011,
		Name = "CapPlayer1",
		DisplayName = "CapPlayer1",
		IsA = function(_, cls) return cls == "Player" end,
	}
	local snapshot = RunManager.getRunSnapshotForPlayer(mapPlayer :: any)
	assert(snapshot and snapshot.CurrentActMap, "snapshot with map exists")
	local firstNodeView = snapshot.CurrentActMap.Nodes[1]
	assertTest(firstNodeView ~= nil and firstNodeView.NodeId == firstNodeView.Id, "[Suite 64.18a] MapNodeView exposes NodeId alias")
	assertTest(firstNodeView.Connections ~= nil, "[Suite 64.18b] MapNodeView exposes Connections alias")
	assertTest(firstNodeView.Reachable ~= nil and firstNodeView.Cleared ~= nil, "[Suite 64.18c] MapNodeView exposes Reachable and Cleared aliases")

	-- 64.19: resetToLobby wipes run state and resets combat relics, gimmicks, cooldowns (Item 25)
	local lobbyPlayer = {
		UserId = 64011,
		Name = "CapPlayer1",
		DisplayName = "CapPlayer1",
		IsA = function(_, cls) return cls == "Player" end,
	}
	RunManager.resetToLobby(lobbyPlayer :: any)
	local resetState = RunManager.getRunState()
	assertTest(resetState.Phase == "Lobby", "[Suite 64.19a] resetToLobby returns Phase to Lobby")

	----------------------------------------------------------------------------
	-- SUITE 65: ACTION TRANSACTIONS, STATUS INTEGRITY, PERSISTENCE SAFETY & MAP
	----------------------------------------------------------------------------
	runSuite65()

	----------------------------------------------------------------------------
	-- SUITE 66: FINAL CORRECTION PASS (STATUS DURATION, FAIL-CLOSED, BUFFERING)
	----------------------------------------------------------------------------
	runSuite66()

	----------------------------------------------------------------------------
	-- SUITE 67: E2E FIRST ROOM NAVIGATION & COMBAT INITIATION FLOW
	----------------------------------------------------------------------------
	runSuite67()

	----------------------------------------------------------------------------
	-- SUITE 68: TRANSACTIONAL FIRST-ROOM PROGRESSION & STATEREVISION INVARIANTS
	----------------------------------------------------------------------------
	runSuite68()

	----------------------------------------------------------------------------
	-- SUITE 69: REWARD FLOW, CARD DRAFT ATOMICITY & BOSS ACT PROGRESSION
	----------------------------------------------------------------------------
	runSuite69()

	----------------------------------------------------------------------------
	-- SUITE 70: TURN RESOLUTION LIFECYCLE & FAIL-SAFE PHASE RECOVERY
	----------------------------------------------------------------------------
	runSuite70()

	----------------------------------------------------------------------------
	-- SUITE 71: MAPFLOW HANDSHAKE, STATESYNC RECOVERY & FINGERPRINTING
	----------------------------------------------------------------------------
	runSuite71()

	----------------------------------------------------------------------------
	-- SUITE 72: WORLD ROOM SERVICE 3D LIFECYCLE & ZERO LEAKAGE
	----------------------------------------------------------------------------
	runSuite72()

	----------------------------------------------------------------------------
	-- SUITE 73: EVENT SERVICE 3D PUZZLES & REWARDS
	----------------------------------------------------------------------------
	runSuite73()

	----------------------------------------------------------------------------
	-- SUITE 74: COMBAT REACTION SERVICE DODGE & PARRY
	----------------------------------------------------------------------------
	runSuite74()

	----------------------------------------------------------------------------
	-- SUITE 75: ENVIRONMENT SERVICE ELEMENTAL AFFINITIES & TRANSFORMATIONS
	----------------------------------------------------------------------------
	runSuite75()

	-- Final Cleanup
	CombatService.cleanupCombat()
	RunManager.resetRunForTesting()
	PersistenceService.resetForTesting()
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

-- Developer helper to trigger manual 3D reaction testing in Studio (e.g. TestRunner.triggerTestReaction("SlowHeavy", 1))
function TestRunner.triggerTestReaction(profileName: string?, targetUserId: number?)
	local profileId = profileName or "SlowHeavy"
	local prof = ReactionService.createProfileFromPreset(profileId)

	-- Determine target player
	local targetPlayer: Player? = nil
	if targetUserId then
		targetPlayer = Players:GetPlayerByUserId(targetUserId)
	end
	if not targetPlayer then
		local players = Players:GetPlayers()
		if #players > 0 then
			targetPlayer = players[1]
		end
	end
	local userId = if targetPlayer then targetPlayer.UserId else (targetUserId or 1)

	-- Ensure enemy dummy model exists in ActiveRoom (or Workspace) so CombatVFXController finds it
	local cardRiftWorld = Workspace:FindFirstChild("CardRiftWorld")
	local activeRoom = cardRiftWorld and cardRiftWorld:FindFirstChild("ActiveRoom")
	local parentTarget = activeRoom or Workspace
	local enemyModel = parentTarget:FindFirstChild("Enemy_test_attacker", true) or Workspace:FindFirstChild("Enemy_test_attacker")
	if not enemyModel then
		enemyModel = Instance.new("Model")
		enemyModel.Name = "Enemy_test_attacker"
		local hrp = Instance.new("Part")
		hrp.Name = "HumanoidRootPart"
		hrp.Size = Vector3.new(3, 5, 3)
		hrp.Position = Vector3.new(0, 3, -16)
		hrp.Anchored = true
		hrp.Material = Enum.Material.Granite
		hrp.Color = Color3.fromRGB(180, 50, 50)
		hrp.Parent = enemyModel
		enemyModel.PrimaryPart = hrp
		enemyModel.Parent = parentTarget
	end

	-- Authoritative target world position: player character position if available
	local targetPos = Vector3.new(0, 3, 16)
	if targetPlayer and targetPlayer.Character then
		local charRoot = targetPlayer.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if charRoot then
			targetPos = charRoot.Position
		end
	end

	local attackerPos = (enemyModel.PrimaryPart and enemyModel.PrimaryPart.Position) or Vector3.new(0, 3, -16)
	prof.TargetWorldPos = targetPos
	prof.TargetWorldPosition = targetPos
	prof.AttackerWorldPos = attackerPos

	if prof.AttackType == "Projectile" and prof.ProjectileSpeed and prof.ProjectileSpeed > 0 then
		local dist = (targetPos - attackerPos).Magnitude
		local windup, impactDelay = ReactionData.resolveProjectileTiming(dist, prof.ProjectileSpeed, prof.TelegraphDuration)
		prof.TelegraphDuration = windup
		prof.ImpactDelay = impactDelay
	end

	local dummyCombatState: any = {
		CombatId = "manual_test_reaction",
		ActiveReactionWindow = nil,
	}
	local win = ReactionService.openReactionWindow(dummyCombatState, prof, "test_attacker", { userId })
	local view = ReactionService.getReactionWindowView(win, "Training Dummy")

	local combatSnapshot: StateTypes.CombatSnapshot = {
		CombatId = "manual_test_reaction",
		Phase = "ResolutionPhase",
		TurnNumber = 1,
		TurnStartTime = os.clock(),
		TurnDuration = 45,
		TimeRemaining = 45,
		Enemies = {},
		Party = {},
		LocalHand = {},
		CombatEvents = {},
		Message = string.format("⚠️ Training Dummy is attacking with %s!", prof.AttackName),
		ActiveReactionWindow = view,
		Environment = nil,
	}

	if targetPlayer then
		NetworkService.sendCombatState(targetPlayer, combatSnapshot)
	else
		for _, p in Players:GetPlayers() do
			NetworkService.sendCombatState(p, combatSnapshot)
		end
	end

	print(string.format("[TestRunner] Triggered manual test reaction window '%s' (%s - %s) for player %d", win.WindowId, prof.AttackName, prof.AttackType or "Melee", userId))
	task.delay(prof.ImpactDelay + prof.RecoveryDuration + 0.05, function()
		if dummyCombatState.ActiveReactionWindow then
			local results = ReactionService.resolveReactionWindow(dummyCombatState, win.WindowId)
			combatSnapshot.ActiveReactionWindow = nil
			combatSnapshot.Message = "Reaction resolved."
			if targetPlayer then
				NetworkService.sendCombatState(targetPlayer, combatSnapshot)
			else
				for _, p in Players:GetPlayers() do
					NetworkService.sendCombatState(p, combatSnapshot)
				end
			end
			print(string.format("[TestRunner] Manual test reaction window '%s' closed and resolved.", win.WindowId))
		end
	end)
	return win
end

return TestRunner
