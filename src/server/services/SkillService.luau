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
local ActionTransaction = require(servicesFolder:WaitForChild("ActionTransaction") :: ModuleScript)

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
	slot: StateTypes.SkillSlot?
): StateTypes.SkillInstance?
	local def = SkillData.getSkill(definitionId)
	if not def then
		warn(string.format("[SkillService] Unknown skill definition '%s'.", definitionId))
		return nil
	end

	if slot ~= nil and not VALID_SKILL_SLOTS[slot] then
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

-- Retrieves an authoritative owned skill instance for a player by instanceId or definitionId
function SkillService.getOwnedSkill(
	playerState: StateTypes.PlayerState,
	identifier: string
): StateTypes.SkillInstance?
	if not playerState or not identifier or identifier == "" then
		return nil
	end

	if playerState.SkillInventory then
		for _, item in ipairs(playerState.SkillInventory) do
			if item.InstanceId == identifier or item.DefinitionId == identifier then
				if item.OwnerUserId == playerState.UserId and SkillService.hasSkill(playerState, item.DefinitionId) then
					return item
				end
			end
		end
	end

	if playerState.EquippedSkills then
		for _, item in playerState.EquippedSkills do
			if item and (item.InstanceId == identifier or item.DefinitionId == identifier) then
				if item.OwnerUserId == playerState.UserId and SkillService.hasSkill(playerState, item.DefinitionId) then
					return item
				end
			end
		end
	end

	return nil
end

-- Authoritatively unlocks a skill for a player and provisions it into their SkillInventory
function SkillService.unlockSkill(
	playerState: StateTypes.PlayerState,
	definitionId: string
): (boolean, string?, StateTypes.SkillInstance?)
	if not playerState then
		return false, "Player state is nil.", nil
	end

	local def = SkillData.getSkill(definitionId)
	if not def then
		return false, string.format("Unknown skill definition '%s'.", definitionId), nil
	end

	if def.RequiredClassId and def.RequiredClassId ~= playerState.ClassId then
		return false, string.format("Skill '%s' requires class '%s', but player is '%s'.", def.Name, def.RequiredClassId, playerState.ClassId), nil
	end

	if not playerState.UnlockedSkills then
		playerState.UnlockedSkills = {}
	end
	if not playerState.SkillInventory then
		playerState.SkillInventory = {}
	end

	-- Check if already unlocked; if so, return existing instance
	if playerState.UnlockedSkills[definitionId] then
		local existing = SkillService.getOwnedSkill(playerState, definitionId)
		if existing then
			return true, nil, existing
		end
	end

	-- Check if an unactivated instance already exists in SkillInventory
	for _, item in ipairs(playerState.SkillInventory) do
		if item.DefinitionId == definitionId and item.OwnerUserId == playerState.UserId then
			playerState.UnlockedSkills[definitionId] = true
			return true, nil, item
		end
	end

	local instance = SkillService.createInstance(definitionId, playerState.UserId, nil)
	if not instance then
		return false, "Failed to instantiate skill.", nil
	end

	playerState.UnlockedSkills[definitionId] = true
	table.insert(playerState.SkillInventory, instance)
	return true, nil, instance
end

-- Dedicated test/provisioning helper that authoritatively creates and registers an instance in SkillInventory
function SkillService.grantSkillForTesting(
	playerState: StateTypes.PlayerState,
	definitionId: string,
	slot: StateTypes.SkillSlot?
): StateTypes.SkillInstance?
	if not playerState then return nil end
	local def = SkillData.getSkill(definitionId)
	if not def then return nil end

	if not playerState.UnlockedSkills then
		playerState.UnlockedSkills = {}
	end
	if not playerState.SkillInventory then
		playerState.SkillInventory = {}
	end

	local instance = SkillService.createInstance(definitionId, playerState.UserId, slot)
	if not instance then return nil end

	playerState.UnlockedSkills[definitionId] = true
	table.insert(playerState.SkillInventory, instance)
	return instance
end

-- Equips a skill into the designated skill slot on the player's state
-- Accepts either an existing InstanceId string, DefinitionId string, or an authoritative SkillInstance proven to exist in SkillInventory
function SkillService.equipSkill(
	playerState: StateTypes.PlayerState,
	skillIdentifier: any,
	targetSlot: StateTypes.SkillSlot?
): (boolean, string?)
	if not playerState then
		return false, "Player state is nil."
	end
	if not skillIdentifier then
		return false, "Skill parameter is nil."
	end

	local targetInst: StateTypes.SkillInstance? = nil

	if typeof(skillIdentifier) == "string" then
		targetInst = SkillService.getOwnedSkill(playerState, skillIdentifier)
		if not targetInst then
			return false, string.format("Player %d does not own or has not unlocked skill '%s'.", playerState.UserId, skillIdentifier)
		end
	elseif typeof(skillIdentifier) == "table" and skillIdentifier.InstanceId then
		local supplied = skillIdentifier :: StateTypes.SkillInstance

		-- Look up strictly within player's authoritative SkillInventory or already-equipped EquippedSkills
		local authInst: StateTypes.SkillInstance? = nil
		if playerState.SkillInventory then
			for _, item in ipairs(playerState.SkillInventory) do
				if item.InstanceId == supplied.InstanceId then
					authInst = item
					break
				end
			end
		end
		if not authInst and playerState.EquippedSkills then
			for _, item in playerState.EquippedSkills do
				if item and item.InstanceId == supplied.InstanceId then
					authInst = item
					break
				end
			end
		end

		if not authInst then
			-- REJECT IMMEDIATELY. Never insert supplied candidate into SkillInventory.
			return false, string.format("Skill instance '%s' not found in player's skill inventory.", tostring(supplied.InstanceId))
		end

		-- Verify ownership
		if authInst.OwnerUserId ~= playerState.UserId then
			return false, string.format("Skill instance owner %d does not match player %d.", authInst.OwnerUserId, playerState.UserId)
		end

		-- Verify caller's supplied table matches authoritative stored record
		if supplied.DefinitionId ~= authInst.DefinitionId
			or supplied.OwnerUserId ~= authInst.OwnerUserId
		then
			return false, string.format("Supplied skill instance '%s' does not match authoritative inventory record.", supplied.InstanceId)
		end

		-- Verify definition entitlement
		if not SkillService.hasSkill(playerState, authInst.DefinitionId) then
			return false, string.format("Player %d has not unlocked skill '%s'.", playerState.UserId, authInst.DefinitionId)
		end

		-- Use strictly the authoritative instance, preserving its runtime CurrentCooldown
		targetInst = authInst
	else
		return false, "Invalid skill parameter: expected SkillInstance or string identifier (InstanceId / DefinitionId)."
	end

	assert(targetInst ~= nil, "Target skill instance must be resolved.")

	local resolvedSlot: StateTypes.SkillSlot? = targetSlot
	if not resolvedSlot and typeof(skillIdentifier) == "table" and skillIdentifier.Slot then
		resolvedSlot = skillIdentifier.Slot
	end
	if not resolvedSlot and targetInst.Slot then
		resolvedSlot = targetInst.Slot
	end

	if not resolvedSlot or not VALID_SKILL_SLOTS[resolvedSlot] then
		return false, string.format("Invalid skill slot '%s'. Must be Skill1, Skill2, Skill3, or Skill4.", tostring(resolvedSlot))
	end

	-- Class requirement check
	local def = SkillData.getSkill(targetInst.DefinitionId)
	if not def then
		return false, string.format("Invalid skill definition '%s'.", targetInst.DefinitionId)
	end
	if def.RequiredClassId and def.RequiredClassId ~= playerState.ClassId then
		return false, string.format("Skill '%s' requires class '%s', but player is '%s'.", def.Name, def.RequiredClassId, playerState.ClassId)
	end

	if not playerState.EquippedSkills then
		playerState.EquippedSkills = {}
	end

	-- Duplicate equipped check: cannot equip same instance in multiple distinct slots
	for s, equipped in playerState.EquippedSkills do
		if s ~= resolvedSlot and equipped and equipped.InstanceId == targetInst.InstanceId then
			return false, string.format("Skill instance '%s' is already equipped in slot '%s'.", targetInst.InstanceId, s)
		end
	end

	-- Idempotent re-equip into same slot preserves cooldown and state
	if playerState.EquippedSkills[resolvedSlot] == targetInst then
		targetInst.Slot = resolvedSlot
		return true, nil
	end

	-- Slot replacement: unseat previous skill if one exists in target slot
	local prevSkill = playerState.EquippedSkills[resolvedSlot]
	if prevSkill and prevSkill.InstanceId ~= targetInst.InstanceId then
		prevSkill.Slot = nil
	end

	targetInst.Slot = resolvedSlot
	playerState.EquippedSkills[resolvedSlot] = targetInst
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

	current.Slot = nil
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

function SkillService.resetCooldowns(playerState: StateTypes.PlayerState)
	if not playerState then return end
	if playerState.EquippedSkills then
		for _, skillInst in playerState.EquippedSkills do
			if skillInst then
				skillInst.CurrentCooldown = 0
			end
		end
	end
	if playerState.SkillInventory then
		for _, skillInst in ipairs(playerState.SkillInventory) do
			if skillInst then
				skillInst.CurrentCooldown = 0
			end
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
	local playerStats = StatResolver.resolvePlayerStats(playerState)
	local energyCost = def.Cost.Energy or 0
	if playerStats.CostReduction and playerStats.CostReduction > 0 then
		energyCost = math.max(0, energyCost - playerStats.CostReduction)
	end
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

	-- 5. Pre-validate effect types and conditions before capturing snapshot or executing
	local anyApplicable = false
	for _, eff in def.Effects do
		if not EffectResolver.isSupportedEffectType(eff.Type) then
			return false, "Unsupported effect type: " .. tostring(eff.Type)
		end
		local conditionApplies = true
		if eff.Condition and eff.Condition ~= "" then
			if eff.Condition == "TargetDowned" then
				conditionApplies = (resolvedTarget.PlayerTarget ~= nil and resolvedTarget.PlayerTarget.IsDowned == true)
			elseif eff.Condition == "TargetLiving" then
				conditionApplies = (resolvedTarget.PlayerTarget == nil or resolvedTarget.PlayerTarget.IsDowned ~= true)
			elseif eff.Condition == "LowHP" then
				local p = resolvedTarget.PlayerTarget or playerState
				conditionApplies = (p.Resources.HP < (p.Resources.MaxHP * 0.5))
			else
				return false, "Unknown effect condition: " .. tostring(eff.Condition)
			end
		end

		if conditionApplies then
			anyApplicable = true
			if eff.Type == "Damage" then
				if not resolvedTarget.EnemyTarget or resolvedTarget.EnemyTarget.HP <= 0 then
					return false, "No living enemy target."
				end
			elseif eff.Type == "Heal" then
				if resolvedTarget.PlayerTarget and resolvedTarget.PlayerTarget.IsDowned then
					return false, "Cannot heal downed player."
				end
			elseif eff.Type == "Revive" then
				if resolvedTarget.PlayerTarget and not resolvedTarget.PlayerTarget.IsDowned then
					return false, "Player is not downed."
				end
			end
		end
	end

	if #def.Effects > 0 and not anyApplicable then
		return false, "No applicable skill effects for target state."
	end

	-- 6. Collect modifiers deterministically
	local modifiers = StatResolver.collectPlayerModifiers(playerState)

	-- COMMIT PHASE: All validations passed. Capture atomic snapshot before mutating combat/player state
	local txSnapshot = ActionTransaction.beginCombatTransaction(playerState, combatState, party)

	local effectiveLogEvent = logEvent or function(eventType: string, sourceId: string, targetId: string, value: number?, text: string?)
		if ActionTransaction.isTransactionActive() then
			ActionTransaction.bufferEvent({
				Type = eventType,
				SourceId = sourceId,
				TargetId = targetId,
				Value = value,
				ExtraText = text,
				Timestamp = os.clock(),
			})
		end
	end

	-- 7. Build action context and execute effects
	local actionCtx: EffectResolver.ActionContext = {
		SourcePlayer = playerState,
		Target = resolvedTarget,
		CombatState = combatState,
		Party = party,
		CardInstance = nil,
		Modifiers = modifiers,
		LogEvent = effectiveLogEvent,
		OnKillCallback = function(defeatedEnemy)
			local RelicServiceMod = servicesFolder:FindFirstChild("RelicService")
			if RelicServiceMod and RelicServiceMod:IsA("ModuleScript") then
				local RelicService = require(RelicServiceMod) :: any
				if type(RelicService.triggerEvent) == "function" then
					local relicResult = RelicService.triggerEvent(playerState, combatState, "OnKill", { Enemy = defeatedEnemy })
					if relicResult then
						if relicResult.BonusEnergy > 0 then
							playerState.Resources.Energy += relicResult.BonusEnergy
						end
						if relicResult.BonusDraw > 0 then
							CardService.drawCards(playerState, relicResult.BonusDraw)
						end
					end
				end
			end
			local ClassServiceMod = servicesFolder:FindFirstChild("ClassService")
			if ClassServiceMod and ClassServiceMod:IsA("ModuleScript") then
				local ClassService = require(ClassServiceMod) :: any
				if type(ClassService.processGimmickOnKill) == "function" then
					ClassService.processGimmickOnKill(playerState)
				end
			end
		end,
		DidRevive = false,
	}

	local results = EffectResolver.resolveEffects(def.Effects, actionCtx)

	-- Transaction verification: all required effects must succeed (all-required-success)
	local hasFailure = false
	local failureMsg = "Skill effect execution failed."

	if #def.Effects > 0 and #results == 0 then
		hasFailure = true
		failureMsg = "No skill effects were satisfied or executed."
	else
		for _, r in ipairs(results) do
			if not r.Success then
				hasFailure = true
				failureMsg = r.Message or failureMsg
				break
			end
		end
	end

	if hasFailure then
		ActionTransaction.rollbackCombatTransaction(txSnapshot, playerState, combatState, party)
		return false, failureMsg
	end

	-- 8. Execution succeeded: deduct costs and trigger cooldown transactionally
	playerState.Resources.Energy -= energyCost
	if hpCost > 0 then
		playerState.Resources.HP -= hpCost
	end
	skillInst.CurrentCooldown = def.CooldownTurns

	if effectiveLogEvent then
		effectiveLogEvent("SkillUsed", playerState.DisplayName, def.Name, nil, string.format("Used %s", def.Name))
	end

	ActionTransaction.commitCombatTransaction(txSnapshot, combatState)

	return true, nil
end

function SkillService.init()
	print("[SkillService] Initialized active skill service with Phase 3.1 hardening.")
end

return SkillService
