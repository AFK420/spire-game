--!strict

--[=[
	Server Bootstrap (init.server.luau)
	Mapped to: ServerScriptService.Server
	Initializes all core server services deterministically, hooks network listeners,
	and provides authoritative runtime coordination for Card Rift: Co-op Dungeon.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local services = script:WaitForChild("services")
local NetworkService = require(services:WaitForChild("NetworkService") :: ModuleScript)
local PersistenceService = require(services:WaitForChild("PersistenceService") :: ModuleScript)
local ModifierResolver = require(services:WaitForChild("ModifierResolver") :: ModuleScript)
local TargetResolver = require(services:WaitForChild("TargetResolver") :: ModuleScript)
local DamagePipeline = require(services:WaitForChild("DamagePipeline") :: ModuleScript)
local StatusService = require(services:WaitForChild("StatusService") :: ModuleScript)
local CardService = require(services:WaitForChild("CardService") :: ModuleScript)
local EffectResolver = require(services:WaitForChild("EffectResolver") :: ModuleScript)
local ClassService = require(services:WaitForChild("ClassService") :: ModuleScript)
local RelicService = require(services:WaitForChild("RelicService") :: ModuleScript)
local DungeonService = require(services:WaitForChild("DungeonService") :: ModuleScript)
local ArenaVisualizer = require(services:WaitForChild("ArenaVisualizer") :: ModuleScript)
local CombatService = require(services:WaitForChild("CombatService") :: ModuleScript)
local RunManager = require(services:WaitForChild("RunManager") :: ModuleScript)
local EquipmentService = require(services:WaitForChild("EquipmentService") :: ModuleScript)
local SkillService = require(services:WaitForChild("SkillService") :: ModuleScript)
local PassiveService = require(services:WaitForChild("PassiveService") :: ModuleScript)
local CardCollectionService = require(services:WaitForChild("CardCollectionService") :: ModuleScript)
local DeckService = require(services:WaitForChild("DeckService") :: ModuleScript)
local TestRunner = require(services:WaitForChild("TestRunner") :: ModuleScript)

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig") :: ModuleScript)
local SkillData = require(Shared:WaitForChild("SkillData") :: ModuleScript)
local PassiveData = require(Shared:WaitForChild("PassiveData") :: ModuleScript)

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

print("============================================================")
print("       CARD RIFT: CO-OP DUNGEON — SERVER STARTUP            ")
print("============================================================")

-- 1. Initialize services deterministically
NetworkService.init()
PersistenceService.init()
ModifierResolver.init()
TargetResolver.init()
DamagePipeline.init()
StatusService.init()
CardService.init()
EffectResolver.init()
ClassService.init()
CardCollectionService.init()
DeckService.init()
RelicService.init()
EquipmentService.init()
SkillService.init()
PassiveService.init()
DungeonService.init()
ArenaVisualizer.init()
CombatService.init()
RunManager.init()

print("[Server] All core services deterministically initialized.")

--------------------------------------------------------------------------------
-- Remote Event Network Dispatchers
--------------------------------------------------------------------------------

-- 1. Start Run (From Lobby)
NetworkService.StartRunEvent.OnServerEvent:Connect(function(player: Player)
	if not NetworkService.checkRateLimit(player, "General") then
		NetworkService.sendActionResult(player, { Action = "StartRun", Success = false, Message = "Rate limit exceeded. Please wait a moment." })
		return
	end
	if not PersistenceService.isProfileLoaded(player) then
		NetworkService.sendActionResult(player, { Action = "StartRun", Success = false, Message = "Your profile failed to load. Starting runs is blocked." })
		return
	end
	print(string.format("[Server] Player %s triggered StartRun.", player.Name))
	local success, err = RunManager.startRun(player)
	if not success then
		NetworkService.sendActionResult(player, { Action = "StartRun", Success = false, Message = tostring(err or "Failed to start run.") })
	else
		NetworkService.sendActionResult(player, { Action = "StartRun", Success = true })
	end
end)

-- 2. Select Class & Subclass
NetworkService.SelectClassEvent.OnServerEvent:Connect(function(player: Player, classId: any, subclassId: any)
	if not NetworkService.checkRateLimit(player, "Class") then
		NetworkService.sendClassSelectionResult(player, {
			Success = false,
			Error = "Rate limit exceeded. Please wait a moment.",
		})
		return
	end

	local cId = typeof(classId) == "table" and classId.ClassId or classId
	local scId = typeof(classId) == "table" and classId.SubclassId or subclassId
	if typeof(cId) ~= "string" or typeof(scId) ~= "string" then
		NetworkService.sendClassSelectionResult(player, {
			Success = false,
			Error = "Invalid class selection parameters.",
		})
		return
	end

	if not PersistenceService.isProfileLoaded(player) then
		warn(string.format("[Server] SelectClass rejected for %s: profile is not loaded.", player.Name))
		NetworkService.sendClassSelectionResult(player, {
			Success = false,
			Error = "Your player profile failed to load. Class selection is disabled.",
		})
		return
	end

	local pState = RunManager.getPlayerState(player)
	if not pState then
		if RunManager.getRunState().Phase == "Lobby" then
			print(string.format("[Server] PlayerState missing for %s (UserId %d); adding to expedition party.", player.Name, player.UserId))
			pState = RunManager.addPlayer(player)
		end
	end

	if not pState then
		warn(string.format("[Server] Cannot select class for %s: not in party or run active.", player.Name))
		NetworkService.sendClassSelectionResult(player, {
			Success = false,
			Error = "Unable to select class: not in party or run already active.",
		})
		return
	end

	local success, err = ClassService.selectClass(player, pState, cId, scId)
	if success then
		print(string.format("[Server] Player %s successfully locked in class %s (%s).", player.DisplayName, cId, scId))
		NetworkService.sendClassSelectionResult(player, {
			Success = true,
			ClassId = cId,
			SubclassId = scId,
		})
		RunManager.broadcastRunSnapshots(string.format("%s selected %s (%s)", player.DisplayName, cId, scId), true)
	else
		warn(string.format("[Server] Class selection rejected for %s: %s", player.DisplayName, tostring(err)))
		NetworkService.sendClassSelectionResult(player, {
			Success = false,
			Error = tostring(err),
		})
		RunManager.sendRunSnapshot(player, string.format("Class selection rejected: %s", tostring(err)))
	end
end)

-- 3. Vote / Travel to Map Node
NetworkService.VoteMapNodeEvent.OnServerEvent:Connect(function(player: Player, targetNodeId: any)
	if not NetworkService.checkRateLimit(player, "Map") then
		NetworkService.sendActionResult(player, { Action = "VoteMapNode", Success = false, Message = "Rate limit exceeded. Please wait a moment." })
		return
	end
	if typeof(targetNodeId) ~= "string" then
		NetworkService.sendActionResult(player, { Action = "VoteMapNode", Success = false, Message = "Invalid target node parameter." })
		return
	end

	local success, err = RunManager.voteMapNode(player, targetNodeId)
	if not success then
		if err then
			warn(string.format("[Server] VoteMapNode failed for %s: %s", player.Name, err))
		end
		NetworkService.sendActionResult(player, { Action = "VoteMapNode", Success = false, Message = tostring(err or "Failed to vote for map node.") })
	else
		NetworkService.sendActionResult(player, { Action = "VoteMapNode", Success = true })
	end
end)

-- 4. Play Card by CardInstanceId
NetworkService.PlayCardEvent.OnServerEvent:Connect(function(player: Player, cardInstanceId: any, targetParam: any)
	if not NetworkService.checkRateLimit(player, "Combat") then
		NetworkService.sendActionResult(player, { Action = "PlayCard", Success = false, Message = "Rate limit exceeded. Please wait a moment." })
		return
	end
	if typeof(cardInstanceId) ~= "string" then
		NetworkService.sendActionResult(player, { Action = "PlayCard", Success = false, Message = "Invalid card instance parameter." })
		return
	end

	local success, err = CombatService.playCard(player, cardInstanceId, targetParam)
	if not success then
		if err then
			warn(string.format("[Server] PlayCard rejected for %s: %s", player.Name, err))
		end
		NetworkService.sendActionResult(player, { Action = "PlayCard", Success = false, Message = tostring(err or "Cannot play card.") })
	else
		NetworkService.sendActionResult(player, { Action = "PlayCard", Success = true })
	end
end)

-- 5. Turn Ready Voting
NetworkService.PlayerVoteReadyEvent.OnServerEvent:Connect(function(player: Player)
	if not NetworkService.checkRateLimit(player, "Combat") then return end
	CombatService.voteReady(player)
end)

-- 6. Teammate Rescue
NetworkService.RescueTeammateEvent.OnServerEvent:Connect(function(player: Player, targetUserId: any)
	if not NetworkService.checkRateLimit(player, "Combat") then return end
	if typeof(targetUserId) ~= "number" then return end

	local success, err = CombatService.rescueTeammate(player, math.floor(targetUserId))
	if not success and err then
		warn(string.format("[Server] Rescue failed for %s: %s", player.Name, err))
	end
end)

-- 7. Draft Card Reward Claim
NetworkService.ClaimRewardCardEvent.OnServerEvent:Connect(function(player: Player, cardDefId: any)
	if not NetworkService.checkRateLimit(player, "General") then
		NetworkService.sendActionResult(player, { Action = "ClaimRewardCard", Success = false, Message = "Rate limit exceeded." })
		return
	end
	if typeof(cardDefId) ~= "string" then
		NetworkService.sendActionResult(player, { Action = "ClaimRewardCard", Success = false, Message = "Invalid card definition ID." })
		return
	end

	local success, err = RunManager.claimRewardCard(player, cardDefId)
	if not success then
		if err then
			warn(string.format("[Server] ClaimRewardCard failed for %s: %s", player.Name, err))
		end
		NetworkService.sendActionResult(player, { Action = "ClaimRewardCard", Success = false, Message = tostring(err or "Failed to claim reward card.") })
	else
		NetworkService.sendActionResult(player, { Action = "ClaimRewardCard", Success = true })
	end
end)

-- 8. Continue From Rewards
NetworkService.ContinueFromRewardsEvent.OnServerEvent:Connect(function(player: Player)
	if not NetworkService.checkRateLimit(player, "General") then
		NetworkService.sendActionResult(player, { Action = "ContinueFromRewards", Success = false, Message = "Rate limit exceeded." })
		return
	end
	local success, err = RunManager.continueFromRewards(player)
	if not success then
		NetworkService.sendActionResult(player, { Action = "ContinueFromRewards", Success = false, Message = tostring(err or "Cannot continue from rewards.") })
	else
		NetworkService.sendActionResult(player, { Action = "ContinueFromRewards", Success = true })
	end
end)

-- 9. Client Full State Sync Request
NetworkService.RequestStateSyncEvent.OnServerEvent:Connect(function(player: Player)
	if not NetworkService.checkRateLimit(player, "General") then return end

	if not RunManager.getPlayerState(player) then
		if RunManager.getRunState().Phase == "Lobby" then
			RunManager.addPlayer(player)
		end
	end

	if PersistenceService.getLoadState(player) == "LoadFailed" then
		NetworkService.sendActionResult(player, {
			Action = "DataStore",
			Success = false,
			Message = "Your player profile failed to load. Persistent features and data saving are disabled.",
		})
	end

	local runSnapshot = RunManager.getRunSnapshotForPlayer(player)
	NetworkService.sendRunState(player, runSnapshot)

	local combatSnapshot = CombatService.getCombatSnapshotForPlayer(player)
	if combatSnapshot then
		NetworkService.sendCombatState(player, combatSnapshot)
	end
end)

-- 10. Equip Equipment
NetworkService.EquipEquipmentEvent.OnServerEvent:Connect(function(player: Player, equipmentInstanceId: any)
	if not NetworkService.checkRateLimit(player, "General") then
		NetworkService.sendActionResult(player, { Action = "EquipEquipment", Success = false, Message = "Rate limit exceeded." })
		return
	end
	if typeof(equipmentInstanceId) ~= "string" or #equipmentInstanceId == 0 then
		NetworkService.sendActionResult(player, { Action = "EquipEquipment", Success = false, Message = "Invalid equipment ID." })
		return
	end

	local pState = RunManager.getPlayerState(player)
	if not pState then
		NetworkService.sendActionResult(player, { Action = "EquipEquipment", Success = false, Message = "Player not in party." })
		return
	end

	local success, err = EquipmentService.equipItem(pState, equipmentInstanceId)
	if success then
		RunManager.broadcastRunSnapshots(string.format("%s equipped gear.", player.DisplayName), true)
		NetworkService.sendActionResult(player, { Action = "EquipEquipment", Success = true })
	else
		if err then
			warn(string.format("[Server] EquipEquipment failed for %s: %s", player.Name, err))
		end
		NetworkService.sendActionResult(player, { Action = "EquipEquipment", Success = false, Message = tostring(err or "Failed to equip item.") })
	end
end)

-- 11. Unequip Equipment
NetworkService.UnequipEquipmentEvent.OnServerEvent:Connect(function(player: Player, slot: any)
	if not NetworkService.checkRateLimit(player, "General") then
		NetworkService.sendActionResult(player, { Action = "UnequipEquipment", Success = false, Message = "Rate limit exceeded." })
		return
	end
	if typeof(slot) ~= "string" or not VALID_EQUIPMENT_SLOTS[slot] then
		NetworkService.sendActionResult(player, { Action = "UnequipEquipment", Success = false, Message = "Invalid equipment slot." })
		return
	end

	local pState = RunManager.getPlayerState(player)
	if not pState then
		NetworkService.sendActionResult(player, { Action = "UnequipEquipment", Success = false, Message = "Player not in party." })
		return
	end

	local success, err = EquipmentService.unequipItem(pState, slot :: any)
	if success then
		RunManager.broadcastRunSnapshots(string.format("%s unequipped %s.", player.DisplayName, tostring(slot)), true)
		NetworkService.sendActionResult(player, { Action = "UnequipEquipment", Success = true })
	else
		if err then
			warn(string.format("[Server] UnequipEquipment failed for %s: %s", player.Name, err))
		end
		NetworkService.sendActionResult(player, { Action = "UnequipEquipment", Success = false, Message = tostring(err or "Failed to unequip item.") })
	end
end)

-- 12. Equip Skill
NetworkService.EquipSkillEvent.OnServerEvent:Connect(function(player: Player, skillIdentifier: any, slot: any)
	if not NetworkService.checkRateLimit(player, "General") then
		NetworkService.sendActionResult(player, { Action = "EquipSkill", Success = false, Message = "Rate limit exceeded." })
		return
	end
	if typeof(skillIdentifier) ~= "string" or #skillIdentifier == 0 then
		NetworkService.sendActionResult(player, { Action = "EquipSkill", Success = false, Message = "Invalid skill identifier." })
		return
	end
	if typeof(slot) ~= "string" or not VALID_SKILL_SLOTS[slot] then
		NetworkService.sendActionResult(player, { Action = "EquipSkill", Success = false, Message = "Invalid skill slot." })
		return
	end

	local pState = RunManager.getPlayerState(player)
	if not pState then
		NetworkService.sendActionResult(player, { Action = "EquipSkill", Success = false, Message = "Player not in party." })
		return
	end

	-- Authoritative Ownership Check: look up player's already-owned skill instance
	local ownedSkill = SkillService.getOwnedSkill(pState, skillIdentifier)
	if not ownedSkill then
		warn(string.format("[Server] EquipSkill rejected unowned skill '%s' for %s.", tostring(skillIdentifier), player.Name))
		NetworkService.sendActionResult(player, { Action = "EquipSkill", Success = false, Message = "Skill not owned." })
		return
	end

	local success, err = SkillService.equipSkill(pState, ownedSkill, slot :: any)
	if success then
		RunManager.broadcastRunSnapshots(string.format("%s equipped skill %s.", player.DisplayName, ownedSkill.DefinitionId), true)
		NetworkService.sendActionResult(player, { Action = "EquipSkill", Success = true })
	else
		if err then
			warn(string.format("[Server] EquipSkill failed for %s: %s", player.Name, err))
		end
		NetworkService.sendActionResult(player, { Action = "EquipSkill", Success = false, Message = tostring(err or "Failed to equip skill.") })
	end
end)

-- 13. Unequip Skill
NetworkService.UnequipSkillEvent.OnServerEvent:Connect(function(player: Player, slot: any)
	if not NetworkService.checkRateLimit(player, "General") then
		NetworkService.sendActionResult(player, { Action = "UnequipSkill", Success = false, Message = "Rate limit exceeded." })
		return
	end
	if typeof(slot) ~= "string" or not VALID_SKILL_SLOTS[slot] then
		NetworkService.sendActionResult(player, { Action = "UnequipSkill", Success = false, Message = "Invalid skill slot." })
		return
	end

	local pState = RunManager.getPlayerState(player)
	if not pState then
		NetworkService.sendActionResult(player, { Action = "UnequipSkill", Success = false, Message = "Player not in party." })
		return
	end

	local success, err = SkillService.unequipSkill(pState, slot :: any)
	if success then
		RunManager.broadcastRunSnapshots(string.format("%s unequipped skill %s.", player.DisplayName, tostring(slot)), true)
		NetworkService.sendActionResult(player, { Action = "UnequipSkill", Success = true })
	else
		if err then
			warn(string.format("[Server] UnequipSkill failed for %s: %s", player.Name, err))
		end
		NetworkService.sendActionResult(player, { Action = "UnequipSkill", Success = false, Message = tostring(err or "Failed to unequip skill.") })
	end
end)

-- 14. Unlock Passive Node
NetworkService.UnlockPassiveEvent.OnServerEvent:Connect(function(player: Player, nodeId: any)
	if not NetworkService.checkRateLimit(player, "General") then
		NetworkService.sendActionResult(player, { Action = "UnlockPassive", Success = false, Message = "Rate limit exceeded." })
		return
	end
	if typeof(nodeId) ~= "string" or #nodeId == 0 then
		NetworkService.sendActionResult(player, { Action = "UnlockPassive", Success = false, Message = "Invalid passive node parameter." })
		return
	end

	local def = PassiveData.getNode(nodeId)
	if not def then
		warn(string.format("[Server] UnlockPassive rejected invalid nodeId '%s' for %s.", tostring(nodeId), player.Name))
		NetworkService.sendActionResult(player, { Action = "UnlockPassive", Success = false, Message = "Invalid passive node." })
		return
	end

	local pState = RunManager.getPlayerState(player)
	if not pState then
		NetworkService.sendActionResult(player, { Action = "UnlockPassive", Success = false, Message = "Player not in party." })
		return
	end

	local success, err = PassiveService.unlockNode(pState, nodeId)
	if success then
		RunManager.broadcastRunSnapshots(string.format("%s unlocked passive node %s.", player.DisplayName, nodeId), true)
		NetworkService.sendActionResult(player, { Action = "UnlockPassive", Success = true })
	else
		if err then
			warn(string.format("[Server] UnlockPassive failed for %s: %s", player.Name, err))
		end
		NetworkService.sendActionResult(player, { Action = "UnlockPassive", Success = false, Message = tostring(err or "Failed to unlock passive node.") })
	end
end)

-- 15. Unlock Skill Definition (DISABLED: Client cannot authoritatively unlock skills)
NetworkService.UnlockSkillEvent.OnServerEvent:Connect(function(player: Player, skillDefId: any)
	if not NetworkService.checkRateLimit(player, "General") then return end
	warn(string.format("[Server] UnlockSkillEvent rejected: client-authoritative skill unlocking is disabled for %s.", player.Name))
	NetworkService.sendActionResult(player, { Action = "UnlockSkill", Success = false, Message = "Client-authoritative skill unlocking is disabled." })
	-- Strictly reject client-requested skill unlocks; skill acquisition is server-only.
end)

-- 16. Use Skill in Combat
NetworkService.UseSkillEvent.OnServerEvent:Connect(function(player: Player, slot: any, targetParam: any)
	if not NetworkService.checkRateLimit(player, "Combat") then
		NetworkService.sendActionResult(player, { Action = "UseSkill", Success = false, Message = "Rate limit exceeded." })
		return
	end
	if typeof(slot) ~= "string" or not VALID_SKILL_SLOTS[slot] then
		NetworkService.sendActionResult(player, { Action = "UseSkill", Success = false, Message = "Invalid skill slot." })
		return
	end

	local success, err = CombatService.useSkill(player, slot :: any, targetParam)
	if not success then
		if err then
			warn(string.format("[Server] UseSkill failed for %s: %s", player.Name, err))
		end
		NetworkService.sendActionResult(player, { Action = "UseSkill", Success = false, Message = tostring(err or "Failed to use skill.") })
	else
		NetworkService.sendActionResult(player, { Action = "UseSkill", Success = true })
	end
end)

--------------------------------------------------------------------------------
-- Phase 4 Deck & Collection Network Dispatchers
--------------------------------------------------------------------------------

local function sendDeckListUpdate(player: Player)
	local decks = DeckService.listDecks(player)
	local summaries = {}
	for _, d in decks do
		table.insert(summaries, DeckService.toDeckSummaryView(player, d))
	end
	local active = DeckService.getActiveDeck(player)
	local activeId = active and active.DeckId or ""
	local slotInfo = DeckService.getSlotEntitlement(player)
	NetworkService.DeckListUpdateEvent:FireClient(player, summaries, activeId, slotInfo)
end

-- 17. Create Deck
NetworkService.CreateDeckEvent.OnServerEvent:Connect(function(player: Player, name: any, cards: any, classId: any)
	if not NetworkService.checkRateLimit(player, "General") then
		NetworkService.sendActionResult(player, { Action = "CreateDeck", Success = false, Message = "Rate limit exceeded." })
		return
	end
	if not PersistenceService.isProfileLoaded(player) then
		NetworkService.sendActionResult(player, { Action = "CreateDeck", Success = false, Message = "Profile unavailable. Cannot create deck." })
		return
	end
	if typeof(name) ~= "string" or #name == 0 then
		NetworkService.sendActionResult(player, { Action = "CreateDeck", Success = false, Message = "Invalid deck name." })
		return
	end
	if cards ~= nil and typeof(cards) ~= "table" then
		NetworkService.sendActionResult(player, { Action = "CreateDeck", Success = false, Message = "Invalid cards table." })
		return
	end
	if classId ~= nil and (typeof(classId) ~= "string" or #classId == 0) then
		NetworkService.sendActionResult(player, { Action = "CreateDeck", Success = false, Message = "Invalid class ID." })
		return
	end

	local success, err, createdDeck = DeckService.createDeck(player, name, cards, classId)
	if success and createdDeck then
		sendDeckListUpdate(player)
		local detailView = DeckService.toDeckDetailView(player, createdDeck)
		NetworkService.DeckDetailUpdateEvent:FireClient(player, detailView)
		NetworkService.sendActionResult(player, { Action = "CreateDeck", Success = true })
	else
		if err then
			warn(string.format("[Server] CreateDeck rejected for %s: %s", player.Name, err))
		end
		NetworkService.sendActionResult(player, { Action = "CreateDeck", Success = false, Message = tostring(err or "Failed to create deck.") })
	end
end)

-- 18. Rename Deck
NetworkService.RenameDeckEvent.OnServerEvent:Connect(function(player: Player, deckId: any, newName: any)
	if not NetworkService.checkRateLimit(player, "General") then
		NetworkService.sendActionResult(player, { Action = "RenameDeck", Success = false, Message = "Rate limit exceeded." })
		return
	end
	if not PersistenceService.isProfileLoaded(player) then
		NetworkService.sendActionResult(player, { Action = "RenameDeck", Success = false, Message = "Profile unavailable. Cannot rename deck." })
		return
	end
	if typeof(deckId) ~= "string" or #deckId == 0 then
		NetworkService.sendActionResult(player, { Action = "RenameDeck", Success = false, Message = "Invalid deck ID." })
		return
	end
	if typeof(newName) ~= "string" or #newName == 0 then
		NetworkService.sendActionResult(player, { Action = "RenameDeck", Success = false, Message = "Invalid deck name." })
		return
	end

	local success, err = DeckService.renameDeck(player, deckId, newName)
	if success then
		sendDeckListUpdate(player)
		NetworkService.sendActionResult(player, { Action = "RenameDeck", Success = true })
	else
		if err then
			warn(string.format("[Server] RenameDeck rejected for %s: %s", player.Name, err))
		end
		NetworkService.sendActionResult(player, { Action = "RenameDeck", Success = false, Message = tostring(err or "Failed to rename deck.") })
	end
end)

-- 19. Delete Deck
NetworkService.DeleteDeckEvent.OnServerEvent:Connect(function(player: Player, deckId: any)
	if not NetworkService.checkRateLimit(player, "General") then
		NetworkService.sendActionResult(player, { Action = "DeleteDeck", Success = false, Message = "Rate limit exceeded." })
		return
	end
	if not PersistenceService.isProfileLoaded(player) then
		NetworkService.sendActionResult(player, { Action = "DeleteDeck", Success = false, Message = "Profile unavailable. Cannot delete deck." })
		return
	end
	if typeof(deckId) ~= "string" or #deckId == 0 then
		NetworkService.sendActionResult(player, { Action = "DeleteDeck", Success = false, Message = "Invalid deck ID." })
		return
	end

	local success, err = DeckService.deleteDeck(player, deckId)
	if success then
		sendDeckListUpdate(player)
		NetworkService.sendActionResult(player, { Action = "DeleteDeck", Success = true })
	else
		if err then
			warn(string.format("[Server] DeleteDeck rejected for %s: %s", player.Name, err))
		end
		NetworkService.sendActionResult(player, { Action = "DeleteDeck", Success = false, Message = tostring(err or "Failed to delete deck.") })
	end
end)

-- 20. Save / Update Deck
NetworkService.SaveDeckEvent.OnServerEvent:Connect(function(player: Player, deckId: any, cards: any)
	if not NetworkService.checkRateLimit(player, "General") then
		NetworkService.sendActionResult(player, { Action = "SaveDeck", Success = false, Message = "Rate limit exceeded." })
		return
	end
	if not PersistenceService.isProfileLoaded(player) then
		NetworkService.sendActionResult(player, { Action = "SaveDeck", Success = false, Message = "Profile unavailable. Cannot save deck." })
		return
	end
	if typeof(deckId) ~= "string" or #deckId == 0 then
		NetworkService.sendActionResult(player, { Action = "SaveDeck", Success = false, Message = "Invalid deck ID." })
		return
	end
	if typeof(cards) ~= "table" then
		NetworkService.sendActionResult(player, { Action = "SaveDeck", Success = false, Message = "Invalid cards table." })
		return
	end

	local success, err = DeckService.saveDeck(player, deckId, cards)
	if success then
		sendDeckListUpdate(player)
		local updatedDeck = DeckService.getDeck(player, deckId)
		if updatedDeck then
			local detailView = DeckService.toDeckDetailView(player, updatedDeck)
			NetworkService.DeckDetailUpdateEvent:FireClient(player, detailView)
		end
		NetworkService.sendActionResult(player, { Action = "SaveDeck", Success = true })
	else
		if err then
			warn(string.format("[Server] SaveDeck rejected for %s: %s", player.Name, err))
		end
		NetworkService.sendActionResult(player, { Action = "SaveDeck", Success = false, Message = tostring(err or "Failed to save deck.") })
	end
end)

-- 21. Duplicate Deck
NetworkService.DuplicateDeckEvent.OnServerEvent:Connect(function(player: Player, sourceDeckId: any, newName: any)
	if not NetworkService.checkRateLimit(player, "General") then
		NetworkService.sendActionResult(player, { Action = "DuplicateDeck", Success = false, Message = "Rate limit exceeded." })
		return
	end
	if not PersistenceService.isProfileLoaded(player) then
		NetworkService.sendActionResult(player, { Action = "DuplicateDeck", Success = false, Message = "Profile unavailable. Cannot duplicate deck." })
		return
	end
	if typeof(sourceDeckId) ~= "string" or #sourceDeckId == 0 then
		NetworkService.sendActionResult(player, { Action = "DuplicateDeck", Success = false, Message = "Invalid source deck ID." })
		return
	end
	local optName = (typeof(newName) == "string" and #newName > 0) and newName or nil

	local success, err = DeckService.duplicateDeck(player, sourceDeckId, optName)
	if success then
		sendDeckListUpdate(player)
		NetworkService.sendActionResult(player, { Action = "DuplicateDeck", Success = true })
	else
		if err then
			warn(string.format("[Server] DuplicateDeck rejected for %s: %s", player.Name, err))
		end
		NetworkService.sendActionResult(player, { Action = "DuplicateDeck", Success = false, Message = tostring(err or "Failed to duplicate deck.") })
	end
end)

-- 22. Select Active Deck
NetworkService.SelectActiveDeckEvent.OnServerEvent:Connect(function(player: Player, deckId: any)
	if not NetworkService.checkRateLimit(player, "General") then
		NetworkService.sendActionResult(player, { Action = "SelectActiveDeck", Success = false, Message = "Rate limit exceeded." })
		return
	end
	if not PersistenceService.isProfileLoaded(player) then
		NetworkService.sendActionResult(player, { Action = "SelectActiveDeck", Success = false, Message = "Profile unavailable. Cannot select active deck." })
		return
	end
	if typeof(deckId) ~= "string" or #deckId == 0 then
		NetworkService.sendActionResult(player, { Action = "SelectActiveDeck", Success = false, Message = "Invalid deck ID." })
		return
	end

	local success, err = DeckService.setActiveDeck(player, deckId)
	if success then
		sendDeckListUpdate(player)
		NetworkService.sendActionResult(player, { Action = "SelectActiveDeck", Success = true })
	else
		if err then
			warn(string.format("[Server] SelectActiveDeck rejected for %s: %s", player.Name, err))
		end
		NetworkService.sendActionResult(player, { Action = "SelectActiveDeck", Success = false, Message = tostring(err or "Failed to select active deck.") })
	end
end)

-- 23. Request Decks
NetworkService.RequestDecksEvent.OnServerEvent:Connect(function(player: Player)
	if not NetworkService.checkRateLimit(player, "General") then return end
	if not PersistenceService.isProfileLoaded(player) then
		NetworkService.sendActionResult(player, { Action = "DataStore", Success = false, Message = "Profile unavailable. Cannot load decks." })
		return
	end
	sendDeckListUpdate(player)
end)

-- 24. Request Card Collection
NetworkService.RequestCardCollectionEvent.OnServerEvent:Connect(function(player: Player)
	if not NetworkService.checkRateLimit(player, "General") then return end
	if not PersistenceService.isProfileLoaded(player) then
		NetworkService.sendActionResult(player, { Action = "DataStore", Success = false, Message = "Profile unavailable. Cannot load card collection." })
		return
	end
	local collectionView = CardCollectionService.toCollectionView(player)
	NetworkService.CardCollectionUpdateEvent:FireClient(player, collectionView)
end)

-- 25. Return to Lobby from Victory/Defeat
NetworkService.ReturnToLobbyEvent.OnServerEvent:Connect(function(player: Player)
	if not NetworkService.checkRateLimit(player, "General") then
		NetworkService.sendActionResult(player, { Action = "ReturnToLobby", Success = false, Message = "Rate limit exceeded." })
		return
	end
	local runState = RunManager.getRunState()
	if runState.Phase == "RunVictory" or runState.Phase == "RunDefeat" then
		RunManager.resetToLobby()
		NetworkService.sendActionResult(player, { Action = "ReturnToLobby", Success = true })
	else
		NetworkService.sendActionResult(player, { Action = "ReturnToLobby", Success = false, Message = "Cannot return to lobby while run is in progress." })
	end
end)

print("[Server] Game network listeners successfully registered.")
print("[Server] Server is ready for live gameplay.")
print("============================================================")

-- 3. Execute Phase 1 automated verification test suite in background task (Studio only)
if RunService:IsStudio() and GameConfig.Testing and GameConfig.Testing.AutoRunTestsInStudio == true then
	task.spawn(function()
		print("[TestRunner] Spawning background automated test suites in isolated mode...")
		local success, err = pcall(function()
			TestRunner.runAllTests()
		end)
		-- Defensive invariant: Isolation must NEVER remain active on live server
		if RunManager.isTestIsolationActive() then
			RunManager.endTestIsolation()
		end
		if not success then
			warn("[TestRunner] Test suite execution encountered error: " .. tostring(err))
		end
	end)
else
	print("[TestRunner] Background test runner skipped (only runs in Studio when GameConfig.Testing.AutoRunTestsInStudio is enabled).")
end
