--!strict

--[=[
	EventService ModuleScript
	Mapped to: ServerScriptService.Server.services.EventService
	Server-authoritative manager for 3D procedural event rooms in Card Rift: Co-op Dungeon.
	1. Manages event state lifecycle: start, interact, validate, resolve, rewards/penalties, cleanup.
	2. Implements the Rune Sequence Puzzle and Statue Riddle vertical slices.
	3. Spawns physical 3D interactables in Workspace via WorldRoomService.
	4. Provides co-op data boundaries (PlayerSpecificClues, PlayerSpecificObjectives, SharedEventState).
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)
local EventData = require(Shared:WaitForChild("EventData") :: ModuleScript)

local servicesFolder = script.Parent
local WorldRoomService = require(servicesFolder:WaitForChild("WorldRoomService") :: ModuleScript)
local CardCollectionService = require(servicesFolder:WaitForChild("CardCollectionService") :: ModuleScript)
local PersistenceService = require(servicesFolder:WaitForChild("PersistenceService") :: ModuleScript)

local EventService = {}

local activeEventState: StateTypes.EventState? = nil
local activePartyRef: { [number]: StateTypes.PlayerState } = {}
local onEventCompletedCallback: ((outcome: "Success" | "Failure", eventState: StateTypes.EventState) -> ())? = nil

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function getRunManager()
	local rm = servicesFolder:FindFirstChild("RunManager")
	if rm then
		return require(rm :: ModuleScript)
	end
	return nil
end

function EventService.getActiveEvent(): StateTypes.EventState?
	return activeEventState
end

function EventService.cleanupEvent()
	activeEventState = nil
	table.clear(activePartyRef)
	onEventCompletedCallback = nil
end

--------------------------------------------------------------------------------
-- Event Initialization
--------------------------------------------------------------------------------

function EventService.startEvent(
	eventId: string,
	partyMembers: { [number]: StateTypes.PlayerState },
	seed: number,
	completionCallback: ((outcome: "Success" | "Failure", eventState: StateTypes.EventState) -> ())?
): StateTypes.EventState
	EventService.cleanupEvent()
	activePartyRef = partyMembers
	onEventCompletedCallback = completionCallback

	local def = EventData.getDefinition(eventId)
	if not def then
		-- Fallback to rune puzzle if unknown
		def = EventData.getDefinition("rune_sequence_puzzle") :: EventData.EventDefinition
		eventId = "rune_sequence_puzzle"
	end

	local rng = Random.new(seed)

	local interactablesMap: { [string]: StateTypes.EventInteractableState } = {}
	local targetSequence: { string }? = nil
	local currentStep: number? = nil
	local correctStatueId: string? = nil
	local clues: { [string]: string } = {}
	local playerSpecificClues: { [number]: string } = {}
	local playerSpecificObjectives: { [number]: string } = {}
	local sharedState: { [string]: any } = {}

	if def.Category == "Puzzle" and eventId == "rune_sequence_puzzle" then
		-- Deterministically shuffle rune sequence based on seed
		local symbols = { "Rune_Fire", "Rune_Water", "Rune_Earth", "Rune_Air" }
		-- Fisher-Yates shuffle
		for i = #symbols, 2, -1 do
			local j = rng:NextInteger(1, i)
			symbols[i], symbols[j] = symbols[j], symbols[i]
		end
		targetSequence = symbols
		currentStep = 1

		-- Physical placement positions for the 4 runes around the chamber dais
		local runePositions = {
			["Rune_Fire"] = Vector3.new(-12, 2.5, -6),
			["Rune_Water"] = Vector3.new(-12, 2.5, 6),
			["Rune_Earth"] = Vector3.new(12, 2.5, -6),
			["Rune_Air"] = Vector3.new(12, 2.5, 6),
		}

		for _, idef in def.Interactables do
			local pos = runePositions[idef.Id] or Vector3.new(0, 2.5, 0)
			interactablesMap[idef.Id] = {
				Id = idef.Id,
				Name = idef.Name,
				Type = idef.Type,
				IsActive = true,
				Position = pos,
				Label = idef.Label,
			}

			-- Spawn physical 3D interactable part in Workspace
			pcall(function()
				WorldRoomService.createInteractable(idef.Id, idef.Name, idef.Type, pos, idef.Label)
			end)
		end

		-- Format clues
		local runeDisplayNames: { [string]: string } = {
			["Rune_Fire"] = "Ignis (Fire)",
			["Rune_Water"] = "Aqua (Water)",
			["Rune_Earth"] = "Terra (Earth)",
			["Rune_Air"] = "Aero (Wind)",
		}
		local sequenceClue = string.format("Ancient Script: %s ➔ %s ➔ %s ➔ %s",
			runeDisplayNames[symbols[1]], runeDisplayNames[symbols[2]],
			runeDisplayNames[symbols[3]], runeDisplayNames[symbols[4]])
		clues["MainClue"] = sequenceClue

		-- Distribute co-op clues among party members
		local memberUserIds = {}
		for uId in partyMembers do table.insert(memberUserIds, uId) end
		table.sort(memberUserIds)

		for idx, uId in memberUserIds do
			local stepAssigned = ((idx - 1) % #symbols) + 1
			playerSpecificClues[uId] = string.format("Your fragment reveals Step %d: %s",
				stepAssigned, runeDisplayNames[symbols[stepAssigned]])
			playerSpecificObjectives[uId] = string.format("Ensure rune %s is activated at Step %d",
				runeDisplayNames[symbols[stepAssigned]], stepAssigned)
		end

	elseif def.Category == "Riddle" and eventId == "statue_riddle" then
		-- Select correct statue deterministically (Statue_Wisdom with AnswerKey = "Echo")
		correctStatueId = "Statue_Wisdom"
		clues["Riddle"] = def.RiddlePrompt or "Solve the riddle of the sentinels."

		local statuePositions = {
			["Statue_Valor"] = Vector3.new(-14, 4.5, -8),
			["Statue_Wisdom"] = Vector3.new(0, 4.5, -14),
			["Statue_Shadows"] = Vector3.new(14, 4.5, -8),
		}

		if def.Statues then
			for _, sChoice in def.Statues do
				clues[sChoice.StatueId] = sChoice.Clue
			end
		end

		for _, idef in def.Interactables do
			local pos = statuePositions[idef.Id] or Vector3.new(0, 4.5, 0)
			interactablesMap[idef.Id] = {
				Id = idef.Id,
				Name = idef.Name,
				Type = idef.Type,
				IsActive = true,
				Position = pos,
				Label = idef.Label,
			}

			pcall(function()
				WorldRoomService.createInteractable(idef.Id, idef.Name, idef.Type, pos, idef.Label)
			end)
		end
	end

	activeEventState = {
		EventId = eventId,
		DefinitionId = def.Id,
		Name = def.Name,
		Category = def.Category,
		IsCompleted = false,
		Outcome = "Pending",
		AttemptsRemaining = def.MaxAttempts,
		MaxAttempts = def.MaxAttempts,
		Interactables = interactablesMap,
		TargetSequence = targetSequence,
		CurrentStep = currentStep,
		CorrectStatueId = correctStatueId,
		Clues = clues,
		PlayerSpecificClues = playerSpecificClues,
		PlayerSpecificObjectives = playerSpecificObjectives,
		SharedEventState = sharedState,
		Message = string.format("Entered: %s", def.Name),
	}

	print(string.format("[EventService] Started event: %s (%s) with %d attempts.", def.Name, eventId, def.MaxAttempts))
	return activeEventState
end

--------------------------------------------------------------------------------
-- Player Interaction
--------------------------------------------------------------------------------

function EventService.interact(player: any, interactableId: string): (boolean, string?, boolean?, StateTypes.EventState?)
	if not activeEventState or activeEventState.IsCompleted then
		return false, "No active event chamber.", false, nil
	end

	local userId = (typeof(player) == "number") and player or (typeof(player) == "Instance" and player.UserId) or (typeof(player) == "table" and player.UserId)
	local pState = (typeof(userId) == "number") and activePartyRef[userId] or nil
	if not pState then
		return false, "Player is not a member of the current party.", false, activeEventState
	end
	if pState.IsDowned then
		return false, "Downed players cannot interact with event objects.", false, activeEventState
	end

	local interactable = activeEventState.Interactables[interactableId]
	if not interactable then
		return false, "Unknown interactable object.", false, activeEventState
	end
	if not interactable.IsActive then
		return false, "Interactable is currently inactive.", false, activeEventState
	end

	local def = EventData.getDefinition(activeEventState.DefinitionId)
	if not def then
		return false, "Missing event definition.", false, activeEventState
	end

	-- 1. Rune Sequence Puzzle Logic
	if activeEventState.Category == "Puzzle" and activeEventState.DefinitionId == "rune_sequence_puzzle" then
		local seq = activeEventState.TargetSequence
		local step = activeEventState.CurrentStep or 1

		if not seq then
			return false, "Puzzle sequence not configured.", false, activeEventState
		end

		local expectedRune = seq[step]
		if interactableId == expectedRune then
			-- Correct rune pressed!
			step += 1
			activeEventState.CurrentStep = step

			if step > #seq then
				-- Whole sequence completed successfully!
				activeEventState.Message = "✨ The runes chime in harmony! The chamber seal is broken!"
				EventService.resolveEvent("Success", activeEventState.Message)
				return true, "Puzzle solved successfully!", true, activeEventState
			else
				activeEventState.Message = string.format("Rune accepted! (%d/%d activated)", step - 1, #seq)
				return true, activeEventState.Message, false, activeEventState
			end
		else
			-- Wrong rune pressed! Sequence reset and attempt consumed
			activeEventState.CurrentStep = 1
			activeEventState.AttemptsRemaining -= 1

			if activeEventState.AttemptsRemaining <= 0 then
				activeEventState.Message = "💥 The runes destabilize! A violent shockwave erupts!"
				EventService.resolveEvent("Failure", activeEventState.Message)
				return false, "Puzzle failed: All attempts exhausted.", true, activeEventState
			else
				activeEventState.Message = string.format("⚠️ Sequence broken! Runes reset. (%d attempts remaining)", activeEventState.AttemptsRemaining)
				return false, activeEventState.Message, false, activeEventState
			end
		end

	-- 2. Statue Riddle Logic
	elseif activeEventState.Category == "Riddle" and activeEventState.DefinitionId == "statue_riddle" then
		if interactableId == activeEventState.CorrectStatueId then
			activeEventState.Message = "✨ The Sentinel of Wisdom bows. The truth has unlocked the offering!"
			EventService.resolveEvent("Success", activeEventState.Message)
			return true, "Riddle answered correctly!", true, activeEventState
		else
			activeEventState.AttemptsRemaining -= 1
			activeEventState.Message = "💀 The sentinel glares as dark energy lashes out!"
			EventService.resolveEvent("Failure", activeEventState.Message)
			return false, "Incorrect sentinel chosen: Curse triggered.", true, activeEventState
		end
	end

	return false, "Unhandled event category.", false, activeEventState
end

--------------------------------------------------------------------------------
-- Resolution, Rewards & Penalties
--------------------------------------------------------------------------------

function EventService.resolveEvent(outcome: "Success" | "Failure", message: string?)
	if not activeEventState or activeEventState.IsCompleted then return end

	activeEventState.IsCompleted = true
	activeEventState.Outcome = outcome
	activeEventState.Message = message or (if outcome == "Success" then "Event Completed!" else "Event Failed!")

	-- Deactivate all interactables
	for _, inst in activeEventState.Interactables do
		inst.IsActive = false
	end

	local def = EventData.getDefinition(activeEventState.DefinitionId)
	if def then
		if outcome == "Success" then
			-- Grant rewards to all living party members
			for _, pState in activePartyRef do
				if def.Reward.Gold and def.Reward.Gold > 0 then
					pState.Gold += def.Reward.Gold
				end
				if def.Reward.AetherShards and def.Reward.AetherShards > 0 and pState.PlayerInstance then
					PersistenceService.addAetherShards(pState.PlayerInstance, def.Reward.AetherShards)
				end
				if def.Reward.HealPercent and def.Reward.HealPercent > 0 and not pState.IsDowned then
					local heal = math.floor(pState.Resources.MaxHP * def.Reward.HealPercent)
					pState.Resources.HP = math.min(pState.Resources.MaxHP, pState.Resources.HP + heal)
				end
			end
		else
			-- Apply failure penalties to party
			for _, pState in activePartyRef do
				if def.FailurePenalty.DamagePercent and def.FailurePenalty.DamagePercent > 0 and not pState.IsDowned then
					local dmg = math.floor(pState.Resources.MaxHP * def.FailurePenalty.DamagePercent)
					pState.Resources.HP = math.max(1, pState.Resources.HP - dmg) -- Minimum 1 HP so event doesn't silently wipe party
				end
				if def.FailurePenalty.GoldLoss and def.FailurePenalty.GoldLoss > 0 then
					pState.Gold = math.max(0, pState.Gold - def.FailurePenalty.GoldLoss)
				end
			end
		end
	end

	print(string.format("[EventService] Event resolved: Outcome=%s, Msg=%s", outcome, tostring(message)))

	if onEventCompletedCallback then
		pcall(function()
			onEventCompletedCallback(outcome, activeEventState :: StateTypes.EventState)
		end)
	end
end

--------------------------------------------------------------------------------
-- Client View Snapshot
--------------------------------------------------------------------------------

function EventService.getEventSnapshotForPlayer(player: any): StateTypes.EventView?
	if not activeEventState then return nil end

	local userId = (typeof(player) == "number") and player or (typeof(player) == "Instance" and player.UserId) or (typeof(player) == "table" and player.UserId)

	local interactablesList: { StateTypes.EventInteractableView } = {}
	for _, inst in activeEventState.Interactables do
		table.insert(interactablesList, {
			Id = inst.Id,
			Name = inst.Name,
			Type = inst.Type,
			IsActive = inst.IsActive,
			Label = inst.Label,
		})
	end
	table.sort(interactablesList, function(a, b) return a.Id < b.Id end)

	local clueText = activeEventState.Clues and activeEventState.Clues["MainClue"] or activeEventState.Clues and activeEventState.Clues["Riddle"]
	local specificClue = (userId and activeEventState.PlayerSpecificClues) and activeEventState.PlayerSpecificClues[userId]
	if specificClue then
		clueText = string.format("%s\n[%s]", clueText or "", specificClue)
	end

	local objectiveText = (userId and activeEventState.PlayerSpecificObjectives) and activeEventState.PlayerSpecificObjectives[userId]

	return {
		EventId = activeEventState.EventId,
		Name = activeEventState.Name,
		Category = activeEventState.Category,
		IsCompleted = activeEventState.IsCompleted,
		Outcome = activeEventState.Outcome,
		AttemptsRemaining = activeEventState.AttemptsRemaining,
		Message = activeEventState.Message,
		ClueText = clueText,
		Interactables = interactablesList,
		ObjectiveText = objectiveText,
	}
end

function EventService.init()
	print("[EventService] Initialized authoritative 3D event and puzzle service.")
end

return EventService
