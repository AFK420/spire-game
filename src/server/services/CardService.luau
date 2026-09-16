--!strict

--[=[
	CardService ModuleScript
	Mapped to: ServerScriptService.Server.services.CardService
	Manages Card Definitions vs Runtime Card Instances for Card Rift: Co-op Dungeon:
	1. Enforces stable CardInstanceId generation (GUID).
	2. Manages Deck, Hand (keyed by CardInstanceId), DiscardPile, and ExhaustPile.
	3. Handles safe draw logic with discard pile shuffling.
	4. Converts internal CardInstances to serializable client CardViews.
]=]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CardData = require(Shared:WaitForChild("CardData") :: ModuleScript)
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)

local CardService = {}

local instanceCounter = 0

-- Generates a unique runtime CardInstance from an immutable CardData definition
function CardService.createCardInstance(definitionId: string, ownerUserId: number): StateTypes.CardInstance?
	local cardDef = CardData.getCard(definitionId)
	if not cardDef then
		warn("[CardService] Failed to create CardInstance: Unknown definition " .. tostring(definitionId))
		return nil
	end

	instanceCounter += 1
	local uniqueId = string.format("card_%d_%d_%s", ownerUserId, instanceCounter, HttpService:GenerateGUID(false):sub(1, 6))

	local instance: StateTypes.CardInstance = {
		InstanceId = uniqueId,
		DefinitionId = cardDef.Id,
		CardData = cardDef,
		OwnerUserId = ownerUserId,
	}

	return instance
end

-- Converts a runtime CardInstance into a serializable client snapshot
function CardService.toCardView(instance: StateTypes.CardInstance): StateTypes.CardView
	return {
		InstanceId = instance.InstanceId,
		DefinitionId = instance.DefinitionId,
		Name = instance.CardData.Name,
		Cost = instance.CardData.Cost,
		Target = instance.CardData.Target,
		Description = instance.CardData.Description,
		Icon = instance.CardData.Icon,
		Color = instance.CardData.Color,
	}
end

-- Resets combat card piles between encounters without losing any acquired cards
function CardService.resetCombatPiles(playerState: StateTypes.PlayerState)
	-- Gather all cards from hand, discard pile, and exhaust pile back into deck
	for _, cardInst in playerState.Hand do
		table.insert(playerState.Deck, cardInst)
	end
	table.clear(playerState.Hand)

	for _, cardInst in playerState.DiscardPile do
		table.insert(playerState.Deck, cardInst)
	end
	table.clear(playerState.DiscardPile)

	for _, cardInst in playerState.ExhaustPile do
		table.insert(playerState.Deck, cardInst)
	end
	table.clear(playerState.ExhaustPile)

	-- Shuffle deck for initial draw
	local rng = Random.new()
	for i = #playerState.Deck, 2, -1 do
		local j = rng:NextInteger(1, i)
		playerState.Deck[i], playerState.Deck[j] = playerState.Deck[j], playerState.Deck[i]
	end
end

-- Draws N cards from player's draw pile into their hand
function CardService.drawCards(playerState: StateTypes.PlayerState, count: number): { StateTypes.CardInstance }
	local drawn: { StateTypes.CardInstance } = {}
	if playerState.IsDowned then return drawn end

	for _ = 1, count do
		-- Reshuffle discard pile into deck if empty
		if #playerState.Deck == 0 and #playerState.DiscardPile > 0 then
			for _, c in playerState.DiscardPile do
				table.insert(playerState.Deck, c)
			end
			table.clear(playerState.DiscardPile)

			local rng = Random.new()
			for i = #playerState.Deck, 2, -1 do
				local j = rng:NextInteger(1, i)
				playerState.Deck[i], playerState.Deck[j] = playerState.Deck[j], playerState.Deck[i]
			end
		end

		if #playerState.Deck > 0 then
			local cardInst = table.remove(playerState.Deck, 1) :: StateTypes.CardInstance
			playerState.Hand[cardInst.InstanceId] = cardInst
			table.insert(drawn, cardInst)
		else
			break
		end
	end

	return drawn
end

-- Locates a card in a player's hand by its stable instance ID
function CardService.getCardInHand(playerState: StateTypes.PlayerState, instanceId: string): StateTypes.CardInstance?
	return playerState.Hand[instanceId]
end

-- Removes a card from hand and moves it to discard pile
function CardService.playCardFromHand(playerState: StateTypes.PlayerState, instanceId: string): StateTypes.CardInstance?
	local cardInst = playerState.Hand[instanceId]
	if not cardInst then return nil end

	playerState.Hand[instanceId] = nil
	table.insert(playerState.DiscardPile, cardInst)
	return cardInst
end

-- Discards all remaining cards in hand to discard pile
function CardService.discardHand(playerState: StateTypes.PlayerState)
	for _, cardInst in playerState.Hand do
		table.insert(playerState.DiscardPile, cardInst)
	end
	table.clear(playerState.Hand)
end

function CardService.init()
	print("[CardService] Initialized Definition vs Instance card engine.")
end

return CardService
