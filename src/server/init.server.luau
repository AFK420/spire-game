--!strict

--[=[
	Server Bootstrap (init.server.luau)
	Mapped to: ServerScriptService.Server
	Initializes all core server services deterministically, hooks network listeners,
	and provides authoritative runtime coordination for Card Rift: Co-op Dungeon.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
local TestRunner = require(services:WaitForChild("TestRunner") :: ModuleScript)

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
RelicService.init()
EquipmentService.init()
SkillService.init()
PassiveService.init()
DungeonService.init()
ArenaVisualizer.init()
CombatService.init()
RunManager.init()

print("[Server] All core services deterministically initialized.")

-- 2. Execute Phase 1 automated verification test suite
task.spawn(function()
	local success, err = pcall(function()
		TestRunner.runAllTests()
	end)
	if not success then
		warn("[TestRunner] Test suite execution encountered error: " .. tostring(err))
	end
end)

--------------------------------------------------------------------------------
-- Remote Event Network Dispatchers
--------------------------------------------------------------------------------

-- 1. Start Run (From Lobby)
NetworkService.StartRunEvent.OnServerEvent:Connect(function(player: Player)
	if not NetworkService.checkRateLimit(player, "General") then return end
	print(string.format("[Server] Player %s triggered StartRun.", player.Name))
	RunManager.startRun()
end)

-- 2. Select Class & Subclass
NetworkService.SelectClassEvent.OnServerEvent:Connect(function(player: Player, classId: any, subclassId: any)
	if not NetworkService.checkRateLimit(player, "Class") then return end

	local cId = typeof(classId) == "table" and classId.ClassId or classId
	local scId = typeof(classId) == "table" and classId.SubclassId or subclassId
	if typeof(cId) ~= "string" or typeof(scId) ~= "string" then return end

	local pState = RunManager.getPlayerState(player.UserId)
	if not pState then return end

	local success = ClassService.selectClass(player, pState, cId, scId)
	if success then
		RunManager.broadcastRunSnapshots(string.format("%s selected %s (%s)", player.DisplayName, cId, scId))
	end
end)

-- 3. Vote / Travel to Map Node
NetworkService.VoteMapNodeEvent.OnServerEvent:Connect(function(player: Player, targetNodeId: any)
	if not NetworkService.checkRateLimit(player, "Map") then return end
	if typeof(targetNodeId) ~= "string" then return end

	local success, err = RunManager.voteMapNode(player, targetNodeId)
	if not success and err then
		warn(string.format("[Server] VoteMapNode failed for %s: %s", player.Name, err))
	end
end)

-- 4. Play Card by CardInstanceId
NetworkService.PlayCardEvent.OnServerEvent:Connect(function(player: Player, cardInstanceId: any, targetParam: any)
	if not NetworkService.checkRateLimit(player, "Combat") then return end
	if typeof(cardInstanceId) ~= "string" then return end

	local success, err = CombatService.playCard(player, cardInstanceId, targetParam)
	if not success and err then
		warn(string.format("[Server] PlayCard rejected for %s: %s", player.Name, err))
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
	if not NetworkService.checkRateLimit(player, "General") then return end
	if typeof(cardDefId) ~= "string" then return end

	local success, err = RunManager.claimRewardCard(player, cardDefId)
	if not success and err then
		warn(string.format("[Server] ClaimRewardCard failed for %s: %s", player.Name, err))
	end
end)

-- 8. Continue From Rewards
NetworkService.ContinueFromRewardsEvent.OnServerEvent:Connect(function(player: Player)
	if not NetworkService.checkRateLimit(player, "General") then return end
	RunManager.continueFromRewards(player)
end)

-- 9. Client Full State Sync Request
NetworkService.RequestStateSyncEvent.OnServerEvent:Connect(function(player: Player)
	if not NetworkService.checkRateLimit(player, "General") then return end

	local runSnapshot = RunManager.getRunSnapshotForPlayer(player)
	NetworkService.sendRunState(player, runSnapshot)

	local combatSnapshot = CombatService.getCombatSnapshotForPlayer(player)
	if combatSnapshot then
		NetworkService.sendCombatState(player, combatSnapshot)
	end
end)

-- 10. Equip Equipment
NetworkService.EquipEquipmentEvent.OnServerEvent:Connect(function(player: Player, equipmentInstanceId: any)
	if not NetworkService.checkRateLimit(player, "General") then return end
	if typeof(equipmentInstanceId) ~= "string" then return end

	local pState = RunManager.getPlayerState(player.UserId)
	if not pState then return end

	local success, err = EquipmentService.equipItem(pState, equipmentInstanceId)
	if success then
		RunManager.broadcastRunSnapshots(string.format("%s equipped gear.", player.DisplayName))
	elseif err then
		warn(string.format("[Server] EquipEquipment failed for %s: %s", player.Name, err))
	end
end)

-- 11. Unequip Equipment
NetworkService.UnequipEquipmentEvent.OnServerEvent:Connect(function(player: Player, slot: any)
	if not NetworkService.checkRateLimit(player, "General") then return end
	if typeof(slot) ~= "string" then return end

	local pState = RunManager.getPlayerState(player.UserId)
	if not pState then return end

	local success, err = EquipmentService.unequipItem(pState, slot :: any)
	if success then
		RunManager.broadcastRunSnapshots(string.format("%s unequipped %s.", player.DisplayName, tostring(slot)))
	elseif err then
		warn(string.format("[Server] UnequipEquipment failed for %s: %s", player.Name, err))
	end
end)

-- 12. Equip Skill
NetworkService.EquipSkillEvent.OnServerEvent:Connect(function(player: Player, skillDefId: any, slot: any)
	if not NetworkService.checkRateLimit(player, "General") then return end
	if typeof(skillDefId) ~= "string" or typeof(slot) ~= "string" then return end

	local pState = RunManager.getPlayerState(player.UserId)
	if not pState then return end

	local skillInst = SkillService.createInstance(skillDefId, player.UserId, slot :: any)
	if not skillInst then return end

	local success, err = SkillService.equipSkill(pState, skillInst)
	if success then
		RunManager.broadcastRunSnapshots(string.format("%s equipped skill %s.", player.DisplayName, skillDefId))
	elseif err then
		warn(string.format("[Server] EquipSkill failed for %s: %s", player.Name, err))
	end
end)

-- 13. Unequip Skill
NetworkService.UnequipSkillEvent.OnServerEvent:Connect(function(player: Player, slot: any)
	if not NetworkService.checkRateLimit(player, "General") then return end
	if typeof(slot) ~= "string" then return end

	local pState = RunManager.getPlayerState(player.UserId)
	if not pState then return end

	local success, err = SkillService.unequipSkill(pState, slot :: any)
	if success then
		RunManager.broadcastRunSnapshots(string.format("%s unequipped skill %s.", player.DisplayName, tostring(slot)))
	elseif err then
		warn(string.format("[Server] UnequipSkill failed for %s: %s", player.Name, err))
	end
end)

-- 14. Unlock Passive Node
NetworkService.UnlockPassiveEvent.OnServerEvent:Connect(function(player: Player, nodeId: any)
	if not NetworkService.checkRateLimit(player, "General") then return end
	if typeof(nodeId) ~= "string" then return end

	local pState = RunManager.getPlayerState(player.UserId)
	if not pState then return end

	local success, err = PassiveService.unlockNode(pState, nodeId)
	if success then
		RunManager.broadcastRunSnapshots(string.format("%s unlocked passive node %s.", player.DisplayName, nodeId))
	elseif err then
		warn(string.format("[Server] UnlockPassive failed for %s: %s", player.Name, err))
	end
end)

-- 15. Use Skill in Combat
NetworkService.UseSkillEvent.OnServerEvent:Connect(function(player: Player, slot: any, targetParam: any)
	if not NetworkService.checkRateLimit(player, "Combat") then return end
	if typeof(slot) ~= "string" then return end

	local success, err = CombatService.useSkill(player, slot :: any, targetParam)
	if not success and err then
		warn(string.format("[Server] UseSkill failed for %s: %s", player.Name, err))
	end
end)

print("[Server] Game network listeners successfully registered.")
print("============================================================")
