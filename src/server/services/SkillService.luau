--!strict
--[=[
	SkillService ModuleScript
	Mapped to: ServerScriptService.Server.services.SkillService

	Authoritative runtime engine for active skills (Phase 3 / 3.1):
	1. Instantiates runtime SkillInstance objects.
	2. Enforces authoritative skill unlock/ownership boundaries on PlayerState.UnlockedSkills.
	3. Rejects fabricated instances, unowned skills, invalid slots, and class mismatches.
	4. Enforces runtime SkillSlot validation ("Skill1".."Skill4") and prevents duplicate equipped instances.
	5. Transactional skill execution: validates party, connection, living state, phase, and target resolution
	   BEFORE deducting resource costs or setting cooldowns. If target resolution or execution fails,
	   zero costs are deducted and cooldown is unchanged.
]=]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)
local SkillData = require(Shared:WaitForChild("SkillData") :: ModuleScript)

local servicesFolder = script.Parent
local TargetResolver = require(servicesFolder:WaitForChild("TargetResolver") :: ModuleScript)
local EffectResolver = require(servicesFolder:WaitForChild("EffectResolver") :: ModuleScript)
local StatResolver = require(servicesFolder:WaitForChild("StatResolver") :: ModuleScript)

local SkillService = {}

local VALID_SKILL_SLOTS: { [string]: boolean } = {
	["Skill1"] = true,
	["Skill2"] = true,
	["Skill3"] = true,
	["Skill4"] = true,
}

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

	if not VALID_SKILL_SLOTS[slot] then
		warn(string.format("[SkillService] Invalid skill slot '%s'.", tostring(slot)))
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

-- Checks if a player has legitimately unlocked a skill definition
function SkillService.hasSkill(playerState: StateTypes.PlayerState, definitionId: string): boolean
	if not playerState or not playerState.UnlockedSkills then
		return false
	end
	return playerState.UnlockedSkills[definitionId] == true
end

-- Authoritatively unlocks a skill for a player
function SkillService.unlockSkill(
	playerState: StateTypes.PlayerState,
	definitionId: string
): (boolean, string?)
	if not playerState then
		return false, "Player state is nil."
	end

	local def = SkillData.getSkill(definitionId)
	if not def then
		return false, string.format("Unknown skill definition '%s'.", definitionId)
	end

	if def.RequiredClassId and def.RequiredClassId ~= playerState.ClassId then
		return false, string.format("Skill '%s' requires class '%s', but player is '%s'.", def.Name, def.RequiredClassId, playerState.ClassId)
	end

	if not playerState.UnlockedSkills then
		playerState.UnlockedSkills = {}
	end

	playerState.UnlockedSkills[definitionId] = true
	return true, nil
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

	-- 1. Runtime SkillSlot validation
	if not VALID_SKILL_SLOTS[skillInst.Slot] then
		return false, string.format("Invalid skill slot '%s'. Must be Skill1, Skill2, Skill3, or Skill4.", tostring(skillInst.Slot))
	end

	-- 2. Owner validation
	if skillInst.OwnerUserId ~= playerState.UserId then
		return false, string.format("Skill instance owner %d does not match player %d.", skillInst.OwnerUserId, playerState.UserId)
	end

	-- 3. Definition verification
	local def = SkillData.getSkill(skillInst.DefinitionId)
	if not def then
		return false, string.format("Invalid skill definition '%s'.", skillInst.DefinitionId)
	end

	-- 4. Class requirement check
	if def.RequiredClassId and def.RequiredClassId ~= playerState.ClassId then
		return false, string.format("Skill '%s' requires class '%s', but player is '%s'.", def.Name, def.RequiredClassId, playerState.ClassId)
	end

	-- 5. Authoritative Skill Ownership verification (Phase 3.1)
	if not SkillService.hasSkill(playerState, skillInst.DefinitionId) then
		return false, string.format("Player %d has not unlocked skill '%s'.", playerState.UserId, def.Name)
	end

	if not playerState.EquippedSkills then
		playerState.EquippedSkills = {}
	end

	-- 6. Duplicate equipped instance check: ensure instance is not already in another slot
	for s, equipped in playerState.EquippedSkills do
		if s ~= skillInst.Slot and equipped and equipped.InstanceId == skillInst.InstanceId then
			return false, string.format("Skill instance '%s' is already equipped in slot '%s'.", skillInst.InstanceId, s)
		end
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

	if not VALID_SKILL_SLOTS[slot] then
		return false, string.format("Invalid skill slot '%s'.", tostring(slot))
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

-- Authoritatively executes an equipped active skill with transactional rollback guarantees
function SkillService.useSkill(
	playerState: StateTypes.PlayerState,
	slot: StateTypes.SkillSlot,
	targetParam: any?,
	combatState: StateTypes.CombatState,
	party: { [number]: StateTypes.PlayerState },
	logEvent: ((eventType: string, sourceId: string, targetId: string, value: number?, text: string?) -> ())?
): (boolean, string?)
	-- 1. Precondition checks
	if not playerState then
		return false, "Player state is nil."
	end
	if not party or not party[playerState.UserId] then
		return false, "Player does not belong to the authoritative party."
	end
	if playerState.IsConnected == false then
		return false, "Disconnected players cannot use skills."
	end
	if playerState.IsDowned then
		return false, "Downed players cannot use skills."
	end
	if not combatState or combatState.Phase ~= "PlayerPhase" then
		return false, "Skills can only be used during PlayerPhase."
	end

	-- 2. Slot & skill validation
	if not VALID_SKILL_SLOTS[slot] then
		return false, string.format("Invalid skill slot '%s'.", tostring(slot))
	end

	local skillInst = SkillService.getEquippedSkill(playerState, slot)
	if not skillInst then
		return false, string.format("No skill equipped in slot '%s'.", tostring(slot))
	end

	local def = SkillData.getSkill(skillInst.DefinitionId)
	if not def then
		return false, string.format("Invalid skill definition '%s'.", skillInst.DefinitionId)
	end

	if skillInst.CurrentCooldown > 0 then
		return false, string.format("Skill '%s' is on cooldown (%d turns remaining).", def.Name, skillInst.CurrentCooldown)
	end

	-- 3. Cost validation (Zero mutation yet)
	local energyCost = def.Cost.Energy or 0
	if playerState.Resources.Energy < energyCost then
		return false, "Not enough Energy!"
	end

	local hpCost = def.Cost.HP or 0
	if hpCost > 0 and playerState.Resources.HP <= hpCost then
		return false, "Not enough HP to pay skill cost!"
	end

	-- 4. Target resolution (Zero mutation yet: failure leaves resources and cooldown untouched)
	local resolvedTarget = TargetResolver.resolveTarget(
		playerState,
		def.Target,
		targetParam,
		combatState,
		party
	)
	if not resolvedTarget.Success then
		return false, resolvedTarget.Error
	end

	-- 5. Collect modifiers deterministically
	local modifiers = StatResolver.collectPlayerModifiers(playerState)

	-- 6. Build action context and execute effects
	local actionCtx: EffectResolver.ActionContext = {
		SourcePlayer = playerState,
		Target = resolvedTarget,
		CombatState = combatState,
		Party = party,
		CardInstance = nil,
		Modifiers = modifiers,
		LogEvent = logEvent,
		OnKillCallback = function(defeatedEnemy)
			local RelicServiceMod = servicesFolder:FindFirstChild("RelicService")
			if RelicServiceMod and RelicServiceMod:IsA("ModuleScript") then
				local RelicService = require(RelicServiceMod) :: any
				if type(RelicService.triggerEvent) == "function" then
					RelicService.triggerEvent(playerState, combatState, "OnKill", { Enemy = defeatedEnemy })
				end
			end
		end,
		DidRevive = false,
	}

	local results = EffectResolver.resolveEffects(def.Effects, actionCtx)

	-- Check for execution failure: if all effects failed, do NOT deduct cost or set cooldown
	if #results > 0 then
		local anySuccess = false
		for _, r in ipairs(results) do
			if r.Success then
				anySuccess = true
				break
			end
		end
		if not anySuccess then
			return false, results[1].Message or "Skill effect execution failed."
		end
	end

	-- 7. Execution succeeded: deduct costs and trigger cooldown transactionally
	playerState.Resources.Energy -= energyCost
	if hpCost > 0 then
		playerState.Resources.HP -= hpCost
	end
	skillInst.CurrentCooldown = def.CooldownTurns

	if logEvent then
		logEvent("SkillUsed", playerState.DisplayName, def.Name, nil, string.format("Used %s", def.Name))
	end

	return true, nil
end

function SkillService.init()
	print("[SkillService] Initialized active skill service with Phase 3.1 hardening.")
end

return SkillService
