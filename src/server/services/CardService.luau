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
function CardService.toCardView(instance: StateTypes.CardInstance, playerState: StateTypes.PlayerState?): StateTypes.CardView
	local cost = instance.CardData.Cost
	if playerState then
		local StatResolver = require(script.Parent:WaitForChild("StatResolver") :: ModuleScript)
		local stats = StatResolver.resolvePlayerStats(playerState)
		if stats.CostReduction and stats.CostReduction > 0 then
			cost = math.max(0, cost - stats.CostReduction)
		end
	end

	return {
		InstanceId = instance.InstanceId,
		DefinitionId = instance.DefinitionId,
		Name = instance.CardData.Name,
		Cost = cost,
		Target = instance.CardData.Target,
		Description = instance.CardData.Description,
		Icon = instance.CardData.Icon,
		Color = instance.CardData.Color,
	}
end

-- Validates strict pile invariants across Deck, Hand, DiscardPile, and ExhaustPile
function CardService.validatePileInvariants(playerState: StateTypes.PlayerState): (boolean, string?)
	if not playerState then
		return false, "PlayerState is nil"
	end
	if typeof(playerState.Deck) ~= "table" then
		return false, "Deck is not a table"
	end
	if typeof(playerState.Hand) ~= "table" then
		return false, "Hand is not a table"
	end
	if typeof(playerState.DiscardPile) ~= "table" then
		return false, "DiscardPile is not a table"
	end
	if typeof(playerState.ExhaustPile) ~= "table" then
		return false, "ExhaustPile is not a table"
	end

	local seenInstances: { [string]: string } = {}

	-- Helper to validate an individual card instance
	local function checkCard(card: any, pileName: string, expectedKey: string?): (boolean, string?)
		if typeof(card) ~= "table" then
			return false, string.format("Card in %s is not a table", pileName)
		end
		if typeof(card.InstanceId) ~= "string" or card.InstanceId == "" then
			return false, string.format("Card in %s has missing or empty InstanceId", pileName)
		end
		if typeof(card.DefinitionId) ~= "string" or card.DefinitionId == "" then
			return false, string.format("Card %s in %s has missing or empty DefinitionId", tostring(card.InstanceId), pileName)
		end
		if card.OwnerUserId ~= playerState.UserId then
			return false, string.format("Card %s in %s has OwnerUserId %s, expected %d", card.InstanceId, pileName, tostring(card.OwnerUserId), playerState.UserId)
		end
		if expectedKey ~= nil and expectedKey ~= card.InstanceId then
			return false, string.format("Hand key '%s' does not match CardInstanceId '%s'", tostring(expectedKey), card.InstanceId)
		end
		if seenInstances[card.InstanceId] then
			return false, string.format("Duplicate CardInstance %s found in %s (already present in %s)", card.InstanceId, pileName, seenInstances[card.InstanceId])
		end
		seenInstances[card.InstanceId] = pileName
		return true, nil
	end

	-- 1. Check Hand
	for key, card in playerState.Hand do
		local ok, err = checkCard(card, "Hand", key)
		if not ok then return false, err end
	end

	-- 2. Check Deck
	for idx, card in ipairs(playerState.Deck) do
		local ok, err = checkCard(card, string.format("Deck[%d]", idx), nil)
		if not ok then return false, err end
	end

	-- 3. Check DiscardPile
	for idx, card in ipairs(playerState.DiscardPile) do
		local ok, err = checkCard(card, string.format("DiscardPile[%d]", idx), nil)
		if not ok then return false, err end
	end

	-- 4. Check ExhaustPile
	for idx, card in ipairs(playerState.ExhaustPile) do
		local ok, err = checkCard(card, string.format("ExhaustPile[%d]", idx), nil)
		if not ok then return false, err end
	end

	return true, nil
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

-- Moves a CardInstance from Hand, DiscardPile, or Deck into ExhaustPile, ensuring it exists in exactly one pile
function CardService.exhaustCard(playerState: StateTypes.PlayerState, instanceId: string): StateTypes.CardInstance?
	local foundCard: StateTypes.CardInstance? = nil

	-- 1. Check Hand
	if playerState.Hand[instanceId] then
		foundCard = playerState.Hand[instanceId]
		playerState.Hand[instanceId] = nil
	end

	-- 2. Check DiscardPile (removes all matching instances to eliminate duplicate leaks)
	for idx = #playerState.DiscardPile, 1, -1 do
		local card = playerState.DiscardPile[idx]
		if card.InstanceId == instanceId then
			if not foundCard then
				foundCard = card
			end
			table.remove(playerState.DiscardPile, idx)
		end
	end

	-- 3. Check Deck
	if not foundCard then
		for idx = #playerState.Deck, 1, -1 do
			local card = playerState.Deck[idx]
			if card.InstanceId == instanceId then
				foundCard = card
				table.remove(playerState.Deck, idx)
				break
			end
		end
	end

	if foundCard then
		-- Ensure not duplicated in ExhaustPile
		local alreadyExhausted = false
		for _, card in playerState.ExhaustPile do
			if card.InstanceId == instanceId then
				alreadyExhausted = true
				break
			end
		end
		if not alreadyExhausted then
			table.insert(playerState.ExhaustPile, foundCard)
		end
		return foundCard
	end

	return nil
end

function CardService.init()
	print("[CardService] Initialized Definition vs Instance card engine.")
end

return CardService
