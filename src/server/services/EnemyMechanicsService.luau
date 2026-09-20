--!strict

--[=[
	EnemyMechanicsService
	Owns reusable, server-authoritative enemy reactions that are triggered by
	combat events rather than by the acting enemy's normal move cycle.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local EnemyData = require(Shared:WaitForChild("EnemyData") :: ModuleScript)
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)

local EnemyMechanicsService = {}

export type MechanicResult = {
	MechanicId: string,
	SourceEnemyId: string,
	SourceEnemyName: string,
	TriggerEnemyId: string,
	AttackGain: number,
	NewAttackPower: number,
}

-- Processes one defeat exactly once. The marker is stored on EnemyState so it
-- participates in ActionTransaction snapshots and rolls back with failed actions.
function EnemyMechanicsService.processEnemyDefeat(
	defeatedEnemy: StateTypes.EnemyState,
	enemies: { [string]: StateTypes.EnemyState }
): ({ MechanicResult }, boolean)
	if defeatedEnemy.HP > 0 or defeatedEnemy.DefeatProcessed == true then
		return {}, false
	end

	defeatedEnemy.DefeatProcessed = true
	local results: { MechanicResult } = {}
	local sortedEnemyIds: { string } = {}
	for enemyId in enemies do
		table.insert(sortedEnemyIds, enemyId)
	end
	table.sort(sortedEnemyIds)

	for _, enemyId in sortedEnemyIds do
		local enemy = enemies[enemyId]
		if enemy ~= defeatedEnemy and enemy.HP > 0 then
			local definition = EnemyData.getEnemy(enemy.DefinitionId)
			local attackGain = if definition then definition.OnAllyDefeatedAttackGain or 0 else 0
			if attackGain > 0 then
				enemy.AttackPower += attackGain
				-- Keep a currently telegraphed attack honest after the passive changes
				-- AttackPower. Non-attack moves retain their authored fixed value.
				if enemy.Intent.Type == "Attack" then
					enemy.Intent = EnemyData.createIntent(
					enemy.DefinitionId,
					enemy.MoveIndex or 1,
					enemy.AttackPower,
					enemy.BossPhase
				)
				end

				table.insert(results, {
					MechanicId = "DevourFallen",
					SourceEnemyId = enemy.InstanceId,
					SourceEnemyName = enemy.Name,
					TriggerEnemyId = defeatedEnemy.InstanceId,
					AttackGain = attackGain,
					NewAttackPower = enemy.AttackPower,
				})
			end
		end
	end

	return results, true
end

return EnemyMechanicsService
