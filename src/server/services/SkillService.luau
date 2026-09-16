--!strict
--[=[
	SkillService ModuleScript
	Mapped to: ServerScriptService.Server.services.SkillService

	Authoritative runtime engine for active skills (Phase 3):
	1. Instantiates runtime SkillInstance objects.
	2. Validates class eligibility and equips skills to dedicated slots (Skill1..Skill4).
	3. Manages per-turn cooldown decrements.
	4. Dispatches authoritative skill execution through TargetResolver and EffectResolver.
]=]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)
local SkillData = require(Shared:WaitForChild("SkillData") :: ModuleScript)

local SkillService = {}

-- Instantiates a new runtime SkillInstance
function SkillService.createInstance(
	definitionId: string,
	ownerUserId: number,
	slot: StateTypes.SkillSlot
): StateTypes.SkillInstance?
	local def = SkillData.getSkill(definitionId)
	if not def then
		warn(string.format("[SkillService] Unknown skill definition '%s'.", definitionId))
		return nil
	end

	local guid = string.gsub(HttpService:GenerateGUID(false), "-", ""):sub(1, 12)
	local instanceId = string.format("skill_%s_%s", definitionId, guid)

	local instance: StateTypes.SkillInstance = {
		InstanceId = instanceId,
		DefinitionId = definitionId,
		OwnerUserId = ownerUserId,
		Slot = slot,
		CurrentCooldown = 0,
	}

	return instance
end

-- Equips a skill into the designated skill slot on the player's state
function SkillService.equipSkill(
	playerState: StateTypes.PlayerState,
	skillInst: StateTypes.SkillInstance
): (boolean, string?)
	if not playerState then
		return false, "Player state is nil."
	end
	if not skillInst then
		return false, "Skill instance is nil."
	end
	if skillInst.OwnerUserId ~= playerState.UserId then
		return false, string.format("Skill instance owner %d does not match player %d.", skillInst.OwnerUserId, playerState.UserId)
	end

	local def = SkillData.getSkill(skillInst.DefinitionId)
	if not def then
		return false, string.format("Invalid skill definition '%s'.", skillInst.DefinitionId)
	end

	-- Check class requirements
	if def.RequiredClassId and def.RequiredClassId ~= playerState.ClassId then
		return false, string.format("Skill '%s' requires class '%s', but player is '%s'.", def.Name, def.RequiredClassId, playerState.ClassId)
	end

	if not playerState.EquippedSkills then
		playerState.EquippedSkills = {}
	end

	playerState.EquippedSkills[skillInst.Slot] = skillInst
	return true, nil
end

-- Unequips a skill from a given slot
function SkillService.unequipSkill(
	playerState: StateTypes.PlayerState,
	slot: StateTypes.SkillSlot
): (boolean, string?)
	if not playerState then
		return false, "Player state is nil."
	end
	if not playerState.EquippedSkills then
		playerState.EquippedSkills = {}
	end

	local current = playerState.EquippedSkills[slot]
	if not current then
		return false, string.format("No skill currently equipped in slot '%s'.", tostring(slot))
	end

	playerState.EquippedSkills[slot] = nil
	return true, nil
end

-- Decrements cooldowns on all equipped skills at turn start
function SkillService.onTurnStart(playerState: StateTypes.PlayerState)
	if not playerState or not playerState.EquippedSkills then
		return
	end

	for _, skillInst in playerState.EquippedSkills do
		if skillInst.CurrentCooldown > 0 then
			skillInst.CurrentCooldown = math.max(0, skillInst.CurrentCooldown - 1)
		end
	end
end

-- Retrieves the skill equipped in a specific slot
function SkillService.getEquippedSkill(
	playerState: StateTypes.PlayerState,
	slot: StateTypes.SkillSlot
): StateTypes.SkillInstance?
	if not playerState or not playerState.EquippedSkills then
		return nil
	end
	return playerState.EquippedSkills[slot]
end

function SkillService.init()
	print("[SkillService] Initialized active skill service.")
end

return SkillService
