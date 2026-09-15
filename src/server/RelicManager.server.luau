--!strict

--[=[
	RelicManager Script
	Mapped to: ServerScriptService.Server.RelicManager
	Manages player relic inventories and dispatches combat triggers for Card Rift: Co-op Dungeon:
	1. Stores and manages passive relic inventories per player.
	2. Dispatches event-driven triggers (OnCombatStart, OnTurnStart, OnCardPlay, OnTurnEnd, OnDamageTaken, OnKill).
	3. Dynamically executes modular mechanical effects (shields, energy, healing, cards, poison, multipliers).
	4. Synchronizes relic states to clients with RemoteEvents and notifies on relic activations.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RelicData = require(Shared:WaitForChild("RelicData") :: ModuleScript)

local RelicManager = {}

--------------------------------------------------------------------------------
-- Remote Events Setup
--------------------------------------------------------------------------------

local relicEventsFolder = ReplicatedStorage:FindFirstChild("RelicEvents")
if not relicEventsFolder then
	local folder = Instance.new("Folder")
	folder.Name = "RelicEvents"
	folder.Parent = ReplicatedStorage
	relicEventsFolder = folder
end

local function getOrCreateRemoteEvent(name: string): RemoteEvent
	local existing = relicEventsFolder:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local event = Instance.new("RemoteEvent")
	event.Name = name
	event.Parent = relicEventsFolder
	return event
end

local RelicInventoryUpdateEvent = getOrCreateRemoteEvent("RelicInventoryUpdate")
local RelicTriggerNotificationEvent = getOrCreateRemoteEvent("RelicTriggerNotification")
local RequestRelicInventoryEvent = getOrCreateRemoteEvent("RequestRelicInventory")

--------------------------------------------------------------------------------
-- Type Definitions & Storage
--------------------------------------------------------------------------------

export type RelicTriggerContext = {
	Session: any?,
	Enemy: any?,
	Card: any?,
	Damage: number?,
	TurnNumber: number?,
	UnspentEnergy: number?,
	IsFirstAttack: boolean?,
}

export type RelicTriggerResult = {
	BonusDamage: number,
	BonusShield: number,
	BonusEnergy: number,
	BonusDraw: number,
	HealAmount: number,
	PoisonApplied: number,
	RetainShield: boolean,
	IsIntangible: boolean,
	BonusRelicAwarded: boolean,
}

export type CombatRuntimeState = {
	AttacksPlayedThisCombat: number,
	FirstAttackUsed: boolean,
	CentennialTriggered: boolean,
	PendingBonusDraw: number,
	IsIntangible: boolean,
}

-- Per-player active relic inventories (Keyed by UserId)
local playerInventories: { [number]: { RelicData.Relic } } = {}

-- Per-player combat transient state
local combatStates: { [number]: CombatRuntimeState } = {}

--------------------------------------------------------------------------------
-- State Helpers
--------------------------------------------------------------------------------

local function getOrCreateCombatState(userId: number): CombatRuntimeState
	if not combatStates[userId] then
		combatStates[userId] = {
			AttacksPlayedThisCombat = 0,
			FirstAttackUsed = false,
			CentennialTriggered = false,
			PendingBonusDraw = 0,
			IsIntangible = false,
		}
	end
	return combatStates[userId]
end

-- Sends the player their updated relic inventory list
local function syncRelicsToClient(player: Player)
	local inventory = playerInventories[player.UserId] or {}
	RelicInventoryUpdateEvent:FireClient(player, inventory)
end

-- Broadcasts a trigger notification banner/badge to the client
local function notifyRelicTrigger(player: Player, relic: RelicData.Relic, detail: string)
	RelicTriggerNotificationEvent:FireClient(player, {
		RelicId = relic.Id,
		RelicName = relic.Name,
		Icon = relic.Icon or "✨",
		Text = string.format("%s: %s", relic.Name, detail),
		Rarity = relic.Rarity,
	})
	print(string.format("[Relic Trigger] [%s] on %s: %s", relic.Name, player.Name, detail))
end

--------------------------------------------------------------------------------
-- Inventory Management API
--------------------------------------------------------------------------------

-- Returns the player's active relic inventory
function RelicManager.getInventory(player: Player): { RelicData.Relic }
	return playerInventories[player.UserId] or {}
end

-- Checks if a player owns a specific relic
function RelicManager.hasRelic(player: Player, relicId: string): boolean
	local list = playerInventories[player.UserId]
	if not list then return false end
	for _, relic in list do
		if relic.Id == relicId then
			return true
		end
	end
	return false
end

-- Adds a relic to the player's active inventory (prevents duplicate passives)
function RelicManager.addRelic(player: Player, relicId: string): boolean
	local relicDef = RelicData.getRelic(relicId)
	if not relicDef then
		warn(string.format("[RelicManager] Unknown relic ID: %s", relicId))
		return false
	end

	if not playerInventories[player.UserId] then
		playerInventories[player.UserId] = {}
	end

	-- Check duplicate
	if RelicManager.hasRelic(player, relicId) then
		print(string.format("[RelicManager] %s already owns relic %s", player.Name, relicDef.Name))
		return false
	end

	table.insert(playerInventories[player.UserId], relicDef)
	print(string.format("[RelicManager] Granted [%s] (%s) to %s", relicDef.Name, relicDef.Rarity, player.Name))

	syncRelicsToClient(player)
	notifyRelicTrigger(player, relicDef, "Acquired relic!")
	return true
end

-- Removes a relic from the player's active inventory
function RelicManager.removeRelic(player: Player, relicId: string): boolean
	local list = playerInventories[player.UserId]
	if not list then return false end

	for index, relic in list do
		if relic.Id == relicId then
			table.remove(list, index)
			syncRelicsToClient(player)
			print(string.format("[RelicManager] Removed [%s] from %s", relic.Name, player.Name))
			return true
		end
	end
	return false
end

-- Resets combat-specific transient counters for a fresh battle
function RelicManager.resetCombatState(player: Player)
	combatStates[player.UserId] = {
		AttacksPlayedThisCombat = 0,
		FirstAttackUsed = false,
		CentennialTriggered = false,
		PendingBonusDraw = 0,
		IsIntangible = false,
	}
end

-- Grants default starter relics upon entering a run or joining
function RelicManager.grantStartingRelics(player: Player)
	playerInventories[player.UserId] = {}
	RelicManager.resetCombatState(player)

	-- Default Starter Relic: Burning Blood (+6 HP on combat start)
	RelicManager.addRelic(player, "BurningBlood")
end

--------------------------------------------------------------------------------
-- Event-Driven Dispatcher
--------------------------------------------------------------------------------

--[=[
	Dispatches a combat trigger event across all equipped relics for a player.
	Executes mechanical effects and returns accumulated modifications.
]=]
function RelicManager.triggerEvent(
	player: Player,
	triggerType: RelicData.RelicTrigger,
	context: RelicTriggerContext
): RelicTriggerResult
	local inventory = playerInventories[player.UserId]
	local cState = getOrCreateCombatState(player.UserId)

	local result: RelicTriggerResult = {
		BonusDamage = 0,
		BonusShield = 0,
		BonusEnergy = 0,
		BonusDraw = 0,
		HealAmount = 0,
		PoisonApplied = 0,
		RetainShield = false,
		IsIntangible = false,
		BonusRelicAwarded = false,
	}

	if not inventory or #inventory == 0 then
		return result
	end

	-- Apply pending draws stored from previous turn (e.g. Pocketwatch)
	if triggerType == "OnTurnStart" and cState.PendingBonusDraw > 0 then
		result.BonusDraw += cState.PendingBonusDraw
		cState.PendingBonusDraw = 0
	end

	-- Reset turn-based intangible
	if triggerType == "OnTurnStart" then
		cState.IsIntangible = false
	end

	for _, relic in inventory do
		if relic.Trigger == triggerType then
			local relicId = relic.Id

			------------------------------------------------------------
			-- 1. OnCombatStart Triggers
			------------------------------------------------------------
			if triggerType == "OnCombatStart" then
				if relicId == "Anchor" then
					result.BonusShield += relic.Value
					notifyRelicTrigger(player, relic, string.format("+%d Shield at combat start!", relic.Value))

				elseif relicId == "Vajra" then
					notifyRelicTrigger(player, relic, string.format("+%d permanent Attack strength active!", relic.Value))

				elseif relicId == "VenomVial" then
					result.PoisonApplied += relic.Value
					notifyRelicTrigger(player, relic, string.format("Injected %d Poison into the enemy!", relic.Value))

				elseif relicId == "BloodVial" then
					result.HealAmount += relic.Value
					notifyRelicTrigger(player, relic, string.format("Healed +%d HP!", relic.Value))

				elseif relicId == "BurningBlood" then
					result.HealAmount += relic.Value
					notifyRelicTrigger(player, relic, string.format("Healed +%d HP!", relic.Value))

				elseif relicId == "MeatOnTheBone" then
					if context.Session and context.Session.HP < (context.Session.MaxHP * 0.5) then
						result.HealAmount += relic.Value
						notifyRelicTrigger(player, relic, string.format("Emergency feast: Healed +%d HP!", relic.Value))
					end
				end

			------------------------------------------------------------
			-- 2. OnTurnStart Triggers
			------------------------------------------------------------
			elseif triggerType == "OnTurnStart" then
				if relicId == "Lantern" then
					local turn = context.TurnNumber or 1
					if turn == 1 then
						result.BonusEnergy += relic.Value
						notifyRelicTrigger(player, relic, string.format("+%d bonus Energy on Turn 1!", relic.Value))
					end

				elseif relicId == "CoffeeDripper" then
					result.BonusEnergy += relic.Value
					notifyRelicTrigger(player, relic, string.format("+%d Energy this turn!", relic.Value))

				elseif relicId == "IncenseBurner" then
					local turn = context.TurnNumber or 1
					if turn > 0 and (turn % 5 == 0) then
						cState.IsIntangible = true
						result.IsIntangible = true
						notifyRelicTrigger(player, relic, "Intangible activated! All damage blocked this turn!")
					end

				elseif relicId == "Akabeko" then
					-- Preps first attack bonus if not used yet
					if not cState.FirstAttackUsed then
						print(string.format("[RelicManager] Akabeko primed for first attack (+%d DMG)", relic.Value))
					end
				end

			------------------------------------------------------------
			-- 3. OnCardPlay Triggers
			------------------------------------------------------------
			elseif triggerType == "OnCardPlay" then
				local card = context.Card
				local isAttack = false

				if card and card.Effects then
					for _, eff in card.Effects do
						if eff.Type == "Damage" then
							isAttack = true
							break
						end
					end
				end

				-- Vajra passive: +2 damage on every attack
				if isAttack and RelicManager.hasRelic(player, "Vajra") then
					local vajra = RelicData.getRelic("Vajra")
					if vajra then
						result.BonusDamage += vajra.Value
					end
				end

				-- Akabeko: +8 damage on the first attack of combat
				if isAttack and not cState.FirstAttackUsed then
					cState.FirstAttackUsed = true
					result.BonusDamage += relic.Value
					notifyRelicTrigger(player, relic, string.format("+%d extra damage on first attack!", relic.Value))
				end

				-- Sundial: Every 3 attacks played gives +2 Energy
				if relicId == "Sundial" and isAttack then
					cState.AttacksPlayedThisCombat += 1
					if cState.AttacksPlayedThisCombat % 3 == 0 then
						result.BonusEnergy += relic.Value
						notifyRelicTrigger(player, relic, string.format("3rd attack struck! Gained +%d Energy!", relic.Value))
					end
				end

			------------------------------------------------------------
			-- 4. OnTurnEnd Triggers
			------------------------------------------------------------
			elseif triggerType == "OnTurnEnd" then
				if relicId == "Pocketwatch" then
					local unspent = context.UnspentEnergy or 0
					if unspent > 0 then
						cState.PendingBonusDraw += relic.Value
						notifyRelicTrigger(player, relic, string.format("Unspent energy stored: +%d cards next turn!", relic.Value))
					end

				elseif relicId == "Orichalcum" then
					local currentShield = 0
					if context.Session and typeof(context.Session.Shield) == "number" then
						currentShield = context.Session.Shield
					end
					if currentShield == 0 then
						result.BonusShield += relic.Value
						notifyRelicTrigger(player, relic, string.format("0 Shield protected: Gained +%d Shield!", relic.Value))
					end

				elseif relicId == "Calipers" then
					result.RetainShield = true
					notifyRelicTrigger(player, relic, string.format("Retained up to %d Shield for next turn!", relic.Value))
				end

			------------------------------------------------------------
			-- 5. OnDamageTaken Triggers
			------------------------------------------------------------
			elseif triggerType == "OnDamageTaken" then
				if relicId == "BronzeScales" then
					result.BonusDamage += relic.Value
					notifyRelicTrigger(player, relic, string.format("Dealt %d Thorns counter-damage to attacker!", relic.Value))

				elseif relicId == "CentennialPuzzle" then
					if not cState.CentennialTriggered then
						cState.CentennialTriggered = true
						result.BonusDraw += relic.Value
						notifyRelicTrigger(player, relic, string.format("Puzzle triggered! Drew %d cards!", relic.Value))
					end
				end

			------------------------------------------------------------
			-- 6. OnKill Triggers
			------------------------------------------------------------
			elseif triggerType == "OnKill" then
				if relicId == "GremlinHorn" then
					result.BonusEnergy += relic.Value
					result.BonusDraw += relic.Value
					notifyRelicTrigger(player, relic, "+1 Energy & +1 Card draw from vanquished foe!")

				elseif relicId == "BlackStar" then
					result.BonusRelicAwarded = true
					notifyRelicTrigger(player, relic, "Elite slain! Bonus Relic unlocked!")
				end
			end
		end
	end

	return result
end

--------------------------------------------------------------------------------
-- Remote Event Handlers
--------------------------------------------------------------------------------

RequestRelicInventoryEvent.OnServerEvent:Connect(function(player: Player)
	syncRelicsToClient(player)
end)

--------------------------------------------------------------------------------
-- Player Lifecycle
--------------------------------------------------------------------------------

Players.PlayerAdded:Connect(function(player: Player)
	RelicManager.grantStartingRelics(player)
end)

Players.PlayerRemoving:Connect(function(player: Player)
	playerInventories[player.UserId] = nil
	combatStates[player.UserId] = nil
end)

for _, p in Players:GetPlayers() do
	RelicManager.grantStartingRelics(p)
end

--------------------------------------------------------------------------------
-- Global & Inter-Script Export
--------------------------------------------------------------------------------

-- Expose to _G for seamless server-side inter-script access
_G.RelicManager = RelicManager

return RelicManager
