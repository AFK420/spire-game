--!strict

--[=[
	TargetResolver ModuleScript
	Mapped to: ServerScriptService.Server.services.TargetResolver
	Central authority for validating and resolving action targets (Enemy, Self, Ally, None)
	ensuring strict disconnect safety, entity existence, and party containment.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local CardData = require(Shared:WaitForChild("CardData") :: ModuleScript)
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)

local TargetResolver = {}

-- Validates and resolves a target entity for a card or skill action
function TargetResolver.resolveTarget(
	sourcePlayer: StateTypes.PlayerState,
	targetType: CardData.TargetType,
	targetParam: any?,
	combatState: StateTypes.CombatState?,
	party: { [number]: StateTypes.PlayerState }?
): StateTypes.ResolvedTarget
	if targetType == "None" then
		return {
			Success = true,
			Error = nil,
			TargetKind = "None",
			EnemyTarget = nil,
			PlayerTarget = nil,
			TargetId = "",
			TargetName = "None",
		}
	end

	if targetType == "Self" then
		if targetParam ~= nil and targetParam ~= sourcePlayer.UserId and targetParam ~= tostring(sourcePlayer.UserId) then
			return {
				Success = false,
				Error = "Self cards cannot target other entities.",
				TargetKind = "None",
				EnemyTarget = nil,
				PlayerTarget = nil,
				TargetId = "",
				TargetName = "",
			}
		end

		return {
			Success = true,
			Error = nil,
			TargetKind = "Player",
			EnemyTarget = nil,
			PlayerTarget = sourcePlayer,
			TargetId = tostring(sourcePlayer.UserId),
			TargetName = sourcePlayer.DisplayName,
		}
	end

	if targetType == "Ally" then
		if not party then
			return {
				Success = false,
				Error = "Target resolution requires Party state for Ally targets.",
				TargetKind = "None",
				EnemyTarget = nil,
				PlayerTarget = nil,
				TargetId = "",
				TargetName = "",
			}
		end

		if targetParam == nil then
			return {
				Success = false,
				Error = "Ally target is required.",
				TargetKind = "None",
				EnemyTarget = nil,
				PlayerTarget = nil,
				TargetId = "",
				TargetName = "",
			}
		end

		local targetUserId = tonumber(targetParam)
		if not targetUserId then
			return {
				Success = false,
				Error = "Invalid ally target.",
				TargetKind = "None",
				EnemyTarget = nil,
				PlayerTarget = nil,
				TargetId = "",
				TargetName = "",
			}
		end

		local allyState = party[targetUserId]
		if not allyState then
			return {
				Success = false,
				Error = "Target ally not in party.",
				TargetKind = "None",
				EnemyTarget = nil,
				PlayerTarget = nil,
				TargetId = "",
				TargetName = "",
			}
		end

		if allyState.IsConnected == false then
			return {
				Success = false,
				Error = "Cannot target a disconnected ally.",
				TargetKind = "None",
				EnemyTarget = nil,
				PlayerTarget = nil,
				TargetId = "",
				TargetName = "",
			}
		end

		return {
			Success = true,
			Error = nil,
			TargetKind = "Player",
			EnemyTarget = nil,
			PlayerTarget = allyState,
			TargetId = tostring(allyState.UserId),
			TargetName = allyState.DisplayName,
		}
	end

	if targetType == "Enemy" then
		if not combatState then
			return {
				Success = false,
				Error = "Target resolution requires active CombatState for Enemy targets.",
				TargetKind = "None",
				EnemyTarget = nil,
				PlayerTarget = nil,
				TargetId = "",
				TargetName = "",
			}
		end

		if targetParam == nil or typeof(targetParam) ~= "string" or targetParam == "" then
			return {
				Success = false,
				Error = "Enemy target is required.",
				TargetKind = "None",
				EnemyTarget = nil,
				PlayerTarget = nil,
				TargetId = "",
				TargetName = "",
			}
		end

		local enemy = combatState.Enemies[targetParam]
		if not enemy then
			return {
				Success = false,
				Error = "Invalid target enemy.",
				TargetKind = "None",
				EnemyTarget = nil,
				PlayerTarget = nil,
				TargetId = "",
				TargetName = "",
			}
		end

		if enemy.HP <= 0 then
			return {
				Success = false,
				Error = "Target enemy is already defeated.",
				TargetKind = "None",
				EnemyTarget = nil,
				PlayerTarget = nil,
				TargetId = "",
				TargetName = "",
			}
		end

		return {
			Success = true,
			Error = nil,
			TargetKind = "Enemy",
			EnemyTarget = enemy,
			PlayerTarget = nil,
			TargetId = enemy.InstanceId,
			TargetName = enemy.Name,
		}
	end

	return {
		Success = false,
		Error = "Unsupported card target type.",
		TargetKind = "None",
		EnemyTarget = nil,
		PlayerTarget = nil,
		TargetId = "",
		TargetName = "",
	}
end

function TargetResolver.init()
	print("[TargetResolver] Initialized authoritative target validation system.")
end

return TargetResolver
