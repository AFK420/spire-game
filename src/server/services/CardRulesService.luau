--!strict

--[=[
	CardRulesService
	Owns server-authoritative card accuracy, enemy evasion, definition-level use
	limits, and combat/run counter resets. Class choice never restricts cards.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local CardData = require(Shared:WaitForChild("CardData") :: ModuleScript)
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)
local GameConfig = require(Shared:WaitForChild("GameConfig") :: ModuleScript)

local CardRulesService = {}

export type HitResult = {
	DidHit: boolean,
	HitChance: number,
	Roll: number,
}

local randomHook: (() -> number)? = nil

function CardRulesService.setRandomHookForTesting(hook: (() -> number)?)
	randomHook = hook
end

local function getCounter(playerState: StateTypes.PlayerState, scope: CardData.UseLimitScope): { [string]: number }
	if scope == "Run" then
		if not playerState.CardUsesThisRun then
			playerState.CardUsesThisRun = {}
		end
		return playerState.CardUsesThisRun
	end
	if not playerState.CardUsesThisBattle then
		playerState.CardUsesThisBattle = {}
	end
	return playerState.CardUsesThisBattle
end

function CardRulesService.resetBattleUsage(playerState: StateTypes.PlayerState)
	playerState.CardUsesThisBattle = {}
end

function CardRulesService.resetRunUsage(playerState: StateTypes.PlayerState)
	playerState.CardUsesThisRun = {}
	playerState.CardUsesThisBattle = {}
end

function CardRulesService.getRemainingUses(playerState: StateTypes.PlayerState, card: CardData.Card): number?
	local limit = card.UseLimit
	if not limit then
		return nil
	end
	local counter = getCounter(playerState, limit.Scope)
	return math.max(0, limit.MaxUses - (counter[card.Id] or 0))
end

function CardRulesService.canUseCard(playerState: StateTypes.PlayerState, card: CardData.Card): (boolean, string?)
	local remaining = CardRulesService.getRemainingUses(playerState, card)
	if remaining == nil or remaining > 0 then
		return true, nil
	end
	local scopeText = if card.UseLimit and card.UseLimit.Scope == "Run" then "this run" else "this battle"
	return false, string.format("%s has reached its %s use limit.", card.Name, scopeText)
end

function CardRulesService.recordUse(playerState: StateTypes.PlayerState, card: CardData.Card): number?
	local limit = card.UseLimit
	if not limit then
		return nil
	end
	local counter = getCounter(playerState, limit.Scope)
	counter[card.Id] = math.min(limit.MaxUses, (counter[card.Id] or 0) + 1)
	return math.max(0, limit.MaxUses - counter[card.Id])
end

function CardRulesService.getAbilityHitChance(accuracy: number, tags: { string }?, enemy: StateTypes.EnemyState): number
	if tags and table.find(tags, "Unerring") then
		return 1
	end
	return math.clamp(accuracy - math.max(0, enemy.Evasion or 0), GameConfig.Combat.MinimumCardHitChance, 1)
end

function CardRulesService.getHitChance(card: CardData.Card, enemy: StateTypes.EnemyState): number
	if card.Target ~= "Enemy" then
		return 1
	end
	return CardRulesService.getAbilityHitChance(card.Accuracy or 1, card.Tags, enemy)
end

function CardRulesService.resolveHit(card: CardData.Card, enemy: StateTypes.EnemyState): HitResult
	local hitChance = CardRulesService.getHitChance(card, enemy)
	local roll = if randomHook then randomHook() else math.random()
	return {
		DidHit = roll < hitChance,
		HitChance = hitChance,
		Roll = roll,
	}
end

function CardRulesService.resolveAbilityHit(accuracy: number, tags: { string }?, enemy: StateTypes.EnemyState): HitResult
	local hitChance = CardRulesService.getAbilityHitChance(accuracy, tags, enemy)
	local roll = if randomHook then randomHook() else math.random()
	return {
		DidHit = roll < hitChance,
		HitChance = hitChance,
		Roll = roll,
	}
end

return CardRulesService
