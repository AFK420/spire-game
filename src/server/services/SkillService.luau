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

local servicesFolder = script.Parent
local TargetResolver = require(servicesFolder:WaitForChild("TargetResolver") :: ModuleScript)
local EffectResolver = require(servicesFolder:WaitForChild("EffectResolver") :: ModuleScript)
local StatResolver = require(servicesFolder:WaitForChild("StatResolver") :: ModuleScript)

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

-- Authoritatively executes an equipped active skill
function SkillService.useSkill(
	playerState: StateTypes.PlayerState,
	slot: StateTypes.SkillSlot,
	targetParam: any?,
	combatState: StateTypes.CombatState,
	party: { [number]: StateTypes.PlayerState },
	logEvent: ((eventType: string, sourceId: string, targetId: string, value: number?, text: string?) -> ())?
): (boolean, string?)
	if not playerState then
		return false, "Player state is nil."
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

	local energyCost = def.Cost.Energy or 0
	if playerState.Resources.Energy < energyCost then
		return false, "Not enough Energy!"
	end

	local hpCost = def.Cost.HP or 0
	if hpCost > 0 and playerState.Resources.HP <= hpCost then
		return false, "Not enough HP to pay skill cost!"
	end

	-- Resolve target authoritatively via TargetResolver
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

	-- Deduct costs
	playerState.Resources.Energy -= energyCost
	if hpCost > 0 then
		playerState.Resources.HP -= hpCost
	end

	-- Collect modifiers deterministically
	local modifiers = StatResolver.collectPlayerModifiers(playerState)

	-- Set cooldown
	skillInst.CurrentCooldown = def.CooldownTurns

	-- Build action context and resolve effects
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

	if logEvent then
		logEvent("SkillUsed", playerState.DisplayName, def.Name, nil, string.format("Used %s", def.Name))
	end

	return true, nil
end

function SkillService.init()
	print("[SkillService] Initialized active skill service.")
end

return SkillService
