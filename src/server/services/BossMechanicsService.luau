--!strict

--[=[
	BossMechanicsService
	Owns deterministic, server-authoritative boss phase transitions. Phase state
	lives on EnemyState so card and skill transactions can roll it back together
	with HP, shields, intents, and combat events.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local EnemyData = require(Shared:WaitForChild("EnemyData") :: ModuleScript)
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)

local BossMechanicsService = {}

export type PhaseTransitionResult = {
	EnemyId: string,
	EnemyName: string,
	FromPhase: number,
	ToPhase: number,
	PhaseName: string,
	ShieldGained: number,
	OpeningMoveId: string?,
}

function BossMechanicsService.initializeBoss(enemy: StateTypes.EnemyState): boolean
	local phase = EnemyData.getBossPhase(enemy.DefinitionId, 1)
	if not phase then
		return false
	end
	enemy.BossPhase = 1
	enemy.BossPhaseName = phase.Name
	enemy.MoveIndex = 1
	enemy.Intent = EnemyData.createIntent(enemy.DefinitionId, 1, enemy.AttackPower, 1)
	return true
end

function BossMechanicsService.getPhaseHealthFloor(enemy: StateTypes.EnemyState): number
	if not enemy.BossPhase then
		return 0
	end
	local nextPhase = EnemyData.getBossPhase(enemy.DefinitionId, enemy.BossPhase + 1)
	if not nextPhase then
		return 0
	end
	return math.max(1, math.ceil(enemy.MaxHP * nextPhase.StartHPRatio))
end

function BossMechanicsService.updatePhase(enemy: StateTypes.EnemyState): PhaseTransitionResult?
	if enemy.HP <= 0 then
		return nil
	end
	local desiredPhase = EnemyData.resolveBossPhase(enemy.DefinitionId, enemy.HP, enemy.MaxHP)
	if not desiredPhase then
		return nil
	end

	local currentPhase = enemy.BossPhase or 1
	if desiredPhase.Phase <= currentPhase then
		return nil
	end

	-- Advance exactly one phase per damage event. DamagePipeline enforces the
	-- next phase's HP floor, so a huge critical hit cannot skip authored phases.
	local nextPhase = EnemyData.getBossPhase(enemy.DefinitionId, currentPhase + 1) or desiredPhase
	local shieldGained = math.max(0, nextPhase.TransitionShield or 0)
	enemy.BossPhase = nextPhase.Phase
	enemy.BossPhaseName = nextPhase.Name
	enemy.MoveIndex = 1
	enemy.Intent = EnemyData.createIntent(
		enemy.DefinitionId,
		1,
		enemy.AttackPower,
		nextPhase.Phase
	)
	enemy.Shield += shieldGained

	return {
		EnemyId = enemy.InstanceId,
		EnemyName = enemy.Name,
		FromPhase = currentPhase,
		ToPhase = nextPhase.Phase,
		PhaseName = nextPhase.Name,
		ShieldGained = shieldGained,
		OpeningMoveId = enemy.Intent.MoveId,
	}
end

return BossMechanicsService
