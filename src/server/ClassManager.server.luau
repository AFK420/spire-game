--!strict

--[=[
	ClassManager Script
	Mapped to: ServerScriptService.Server.ClassManager
	Manages player class/subclass selections, starting deck and stat injection,
	and combat gimmick state tracking for Card Rift: Co-op Dungeon.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ClassData = require(Shared:WaitForChild("ClassData") :: ModuleScript)
local CardData = require(Shared:WaitForChild("CardData") :: ModuleScript)

local ClassManager = {}

--------------------------------------------------------------------------------
-- Remote Events Setup
--------------------------------------------------------------------------------

local classEventsFolder = ReplicatedStorage:FindFirstChild("ClassEvents")
if not classEventsFolder then
	local folder = Instance.new("Folder")
	folder.Name = "ClassEvents"
	folder.Parent = ReplicatedStorage
	classEventsFolder = folder
end

local function getOrCreateRemoteEvent(name: string): RemoteEvent
	local existing = classEventsFolder:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local event = Instance.new("RemoteEvent")
	event.Name = name
	event.Parent = classEventsFolder
	return event
end

local SelectClassEvent = getOrCreateRemoteEvent("SelectClass")
local ClassSelectionUpdateEvent = getOrCreateRemoteEvent("ClassSelectionUpdate")
local GimmickFeedbackEvent = getOrCreateRemoteEvent("GimmickFeedback")
local RequestClassSelectionEvent = getOrCreateRemoteEvent("RequestClassSelection")

--------------------------------------------------------------------------------
-- Type Definitions & Storage
--------------------------------------------------------------------------------

export type PlayerGimmickState = {
	ComboCount: number,             -- Shadowblade
	OverloadCharges: number,        -- Aether Mage
	SoulTokens: number,             -- Necrobinder
	BoneServants: number,           -- Necrobinder
	ScrapParts: number,             -- Mechanist
	ActiveTurrets: number,          -- Mechanist
	TotalSacrificedHP: number,      -- Blood Priest
	WolfHP: number,                 -- Beastmaster
	WolfMaxHP: number,              -- Beastmaster
	WolfAttack: number,             -- Beastmaster
	LastCardPlayed: any?,           -- Chronomancer
	LastDamageTaken: number,        -- Chronomancer
}

export type GimmickCardResult = {
	BonusDamage: number,
	BonusShield: number,
	AllowEnergyBypass: boolean,
	FreeEnergyCost: boolean,
	PoisonApplied: number,
}

export type GimmickTurnEndResult = {
	EndTurnDamage: number,
	EndTurnShield: number,
	EndTurnHeal: number,
}

-- Per-player selected Class and Subclass (Keyed by UserId)
local playerSelections: { [number]: { ClassId: string, SubclassId: string } } = {}

-- Per-player combat gimmick tracking state
local gimmickStates: { [number]: PlayerGimmickState } = {}

--------------------------------------------------------------------------------
-- Gimmick State Helpers
--------------------------------------------------------------------------------

local function getOrCreateGimmickState(userId: number): PlayerGimmickState
	if not gimmickStates[userId] then
		gimmickStates[userId] = {
			ComboCount = 0,
			OverloadCharges = 0,
			SoulTokens = 0,
			BoneServants = 0,
			ScrapParts = 0,
			ActiveTurrets = 0,
			TotalSacrificedHP = 0,
			WolfHP = 40,
			WolfMaxHP = 40,
			WolfAttack = 6,
			LastCardPlayed = nil,
			LastDamageTaken = 0,
		}
	end
	return gimmickStates[userId]
end

local function sendFeedback(player: Player, text: string, color: Color3?)
	GimmickFeedbackEvent:FireClient(player, {
		Text = text,
		Color = color or Color3.fromRGB(255, 220, 80),
	})
	print(string.format("[ClassManager Gimmick] %s: %s", player.Name, text))
end

--------------------------------------------------------------------------------
-- Class Selection API
--------------------------------------------------------------------------------

-- Returns the player's selected HeroClass definition
function ClassManager.getPlayerClass(player: Player): ClassData.HeroClass
	local sel = playerSelections[player.UserId]
	local classId = sel and sel.ClassId or "Warlord"
	return ClassData.getClass(classId) or ClassData.getClass("Warlord") :: ClassData.HeroClass
end

-- Returns the player's selected Subclass definition
function ClassManager.getPlayerSubclass(player: Player): ClassData.Subclass?
	local sel = playerSelections[player.UserId]
	if not sel then
		return ClassData.getSubclass("Warlord", "Berserker")
	end
	return ClassData.getSubclass(sel.ClassId, sel.SubclassId)
end

-- Sets the player's class & subclass
function ClassManager.selectClass(player: Player, classId: string, subclassId: string): boolean
	local heroClass = ClassData.getClass(classId)
	if not heroClass then
		warn("[ClassManager] Invalid class: " .. tostring(classId))
		return false
	end

	local subclass = ClassData.getSubclass(classId, subclassId)
	if not subclass then
		warn("[ClassManager] Invalid subclass: " .. tostring(subclassId))
		return false
	end

	playerSelections[player.UserId] = {
		ClassId = classId,
		SubclassId = subclassId,
	}

	ClassSelectionUpdateEvent:FireAllClients({
		UserId = player.UserId,
		PlayerName = player.DisplayName or player.Name,
		ClassId = classId,
		ClassName = heroClass.Name,
		SubclassId = subclassId,
		SubclassName = subclass.Name,
		Icon = heroClass.Icon,
	})

	sendFeedback(player, string.format("Locked in %s (%s)!", heroClass.Name, subclass.Name), heroClass.Color)
	print(string.format("[ClassManager] %s locked in %s (%s)", player.Name, heroClass.Name, subclass.Name))
	return true
end

-- Injects class starting stats and unique starting deck into a player's session
function ClassManager.applyClassToSession(player: Player, session: any)
	local heroClass = ClassManager.getPlayerClass(player)
	local subclass = ClassManager.getPlayerSubclass(player)

	local maxHp = heroClass.MaxHp
	if subclass and subclass.Id == "Titan" then
		maxHp += 10
	end

	session.MaxHP = maxHp
	session.HP = maxHp
	session.MaxEnergy = heroClass.StartingEnergy
	session.Energy = heroClass.StartingEnergy

	-- Build starting deck from class definition
	local newDeck: { CardData.Card } = {}
	for _, cardName in heroClass.StartingDeck do
		local card = CardData.getCard(cardName)
		if card then
			table.insert(newDeck, card)
		else
			warn("[ClassManager] Unknown card in starting deck: " .. cardName)
		end
	end

	session.Deck = newDeck
	table.clear(session.Hand)
	table.clear(session.DiscardPile)

	-- Reset transient gimmick tracking
	ClassManager.resetCombatGimmickState(player)

	print(string.format("[ClassManager] Injected %s deck (%d cards) and stats (HP: %d, Energy: %d) into %s",
		heroClass.Name, #newDeck, maxHp, heroClass.StartingEnergy, player.Name))
end

-- Resets combat gimmick runtime state
function ClassManager.resetCombatGimmickState(player: Player)
	local gState = getOrCreateGimmickState(player.UserId)
	gState.ComboCount = 0
	gState.OverloadCharges = 0
	gState.SoulTokens = 0
	gState.BoneServants = 0
	gState.ScrapParts = 0
	gState.ActiveTurrets = 0
	gState.TotalSacrificedHP = 0
	gState.WolfHP = 40
	gState.WolfMaxHP = 40
	gState.WolfAttack = 6
	gState.LastCardPlayed = nil
	gState.LastDamageTaken = 0
end

--------------------------------------------------------------------------------
-- Combat Gimmick Dispatchers
--------------------------------------------------------------------------------

--[=[
	Evaluates class gimmicks on card play.
	Handles:
	- Warlord: Rage scaling (+1 ATK per 10% missing HP; Berserker +4 bonus).
	- Shadowblade: Combo escalation (+2 damage/shield per card; Assassin 2x crit; Venomancer poison).
	- Blood Priest: Sacrifice HP to bypass 0 Energy.
	- Gambler: Luck damage variance and coin flips.
	- Mechanist: Scrap assembly and turret construction.
]=]
function ClassManager.processGimmickOnCardPlay(
	player: Player,
	card: CardData.Card,
	session: any,
	enemy: any
): GimmickCardResult
	local heroClass = ClassManager.getPlayerClass(player)
	local subclass = ClassManager.getPlayerSubclass(player)
	local gState = getOrCreateGimmickState(player.UserId)

	local result: GimmickCardResult = {
		BonusDamage = 0,
		BonusShield = 0,
		AllowEnergyBypass = false,
		FreeEnergyCost = false,
		PoisonApplied = 0,
	}

	local isAttack = false
	for _, eff in card.Effects do
		if eff.Type == "Damage" then
			isAttack = true
			break
		end
	end

	------------------------------------------------------------
	-- 1. Warlord: Rage Gimmick
	------------------------------------------------------------
	if heroClass.Id == "Warlord" and isAttack then
		local missingHpPercent = math.clamp((session.MaxHP - session.HP) / session.MaxHP, 0, 1)
		local rageBonus = math.floor(missingHpPercent * 10) -- +1 per 10% missing HP
		if rageBonus > 0 then
			result.BonusDamage += rageBonus
			sendFeedback(player, string.format("🔥 Rage: +%d Damage!", rageBonus), Color3.fromRGB(240, 80, 50))
		end

		-- Berserker Subclass: +4 flat damage when below 50% HP
		if subclass and subclass.Id == "Berserker" and session.HP < (session.MaxHP * 0.5) then
			result.BonusDamage += 4
			sendFeedback(player, "⚡ Berserker Frenzy: +4 Damage!", Color3.fromRGB(255, 60, 40))
		end

	------------------------------------------------------------
	-- 2. Shadowblade: Combo Gimmick
	------------------------------------------------------------
	elseif heroClass.Id == "Shadowblade" then
		gState.ComboCount += 1

		if gState.ComboCount > 1 then
			local comboBonus = (gState.ComboCount - 1) * 2
			if isAttack then
				result.BonusDamage += comboBonus
			else
				result.BonusShield += comboBonus
			end
			sendFeedback(player, string.format("🗡️ Combo x%d: +%d Effect!", gState.ComboCount, comboBonus), Color3.fromRGB(180, 100, 240))
		end

		-- Assassin Subclass: 3rd card is guaranteed Critical Strike (2x damage)
		if subclass and subclass.Id == "Assassin" and gState.ComboCount == 3 and isAttack then
			result.BonusDamage += 10
			sendFeedback(player, "💥 CRITICAL STRIKE! (2x Damage Burst)", Color3.fromRGB(255, 40, 80))
		end

		-- Venomancer Subclass: Apply +1 Poison on every card
		if subclass and subclass.Id == "Venomancer" then
			result.PoisonApplied += 1
			sendFeedback(player, "🧪 Venomous Blade: +1 Poison applied!", Color3.fromRGB(80, 220, 100))
		end

	------------------------------------------------------------
	-- 3. Blood Priest: Sacrifice Gimmick
	------------------------------------------------------------
	elseif heroClass.Id == "BloodPriest" then
		if session.Energy < card.Cost then
			local missingEnergy = card.Cost - session.Energy
			local hpCost = missingEnergy * 5

			if session.HP > hpCost then
				session.HP -= hpCost
				session.Energy = 0
				result.AllowEnergyBypass = true
				result.BonusDamage += 3

				gState.TotalSacrificedHP += hpCost
				sendFeedback(player, string.format("🩸 Sacrificed %d HP for Energy! (+3 DMG)", hpCost), Color3.fromRGB(220, 40, 60))

				-- Zealot Subclass: Below 50% HP grants 10 Shield
				if subclass and subclass.Id == "Zealot" and session.HP < (session.MaxHP * 0.5) then
					result.BonusShield += 10
					sendFeedback(player, "🛡️ Martyrdom: +10 Shield!", Color3.fromRGB(240, 160, 60))
				end

				-- Inquisitor Subclass: Every 15 HP sacrificed bursts 18 damage
				if subclass and subclass.Id == "Inquisitor" and gState.TotalSacrificedHP >= 15 then
					gState.TotalSacrificedHP -= 15
					result.BonusDamage += 18
					sendFeedback(player, "💥 RIGHTEOUS PURGE BURST! (+18 AoE DMG)", Color3.fromRGB(255, 80, 80))
				end
			end
		end

	------------------------------------------------------------
	-- 4. Gambler: Luck Rolls Gimmick
	------------------------------------------------------------
	elseif heroClass.Id == "Gambler" and isAttack then
		local rng = Random.new()
		local luckMultiplier = rng:NextNumber(0.5, 1.75)
		local baseBonus = math.round(card.Effects[1].Value * (luckMultiplier - 1.0))
		result.BonusDamage += baseBonus

		if card.Id == "CoinFlip" then
			local winChance = (subclass and subclass.Id == "HighRoller") and 0.70 or 0.50
			local roll = rng:NextNumber(0, 1)
			if roll <= winChance then
				result.BonusDamage += 8
				sendFeedback(player, "🪙 COIN FLIP: HEADS! (+8 Bonus DMG)", Color3.fromRGB(255, 215, 50))
			else
				sendFeedback(player, "🪙 COIN FLIP: TAILS! (Normal DMG)", Color3.fromRGB(180, 180, 180))
			end
		end

		if subclass and subclass.Id == "CardSharp" and luckMultiplier >= 1.65 then
			result.FreeEnergyCost = true
			sendFeedback(player, "🃏 Ace in the Hole! Energy refunded!", Color3.fromRGB(255, 230, 80))
		end

	------------------------------------------------------------
	-- 5. Mechanist: Gears & Scrap Gimmick
	------------------------------------------------------------
	elseif heroClass.Id == "Mechanist" then
		gState.ScrapParts += 1
		sendFeedback(player, string.format("⚙️ Scrap Collected (%d/4)", gState.ScrapParts), Color3.fromRGB(220, 150, 60))

		if gState.ScrapParts >= 4 then
			gState.ScrapParts -= 4
			gState.ActiveTurrets += 1
			sendFeedback(player, string.format("🤖 Sentry Turret Constructed! (Total: %d)", gState.ActiveTurrets), Color3.fromRGB(255, 180, 60))
		end

	------------------------------------------------------------
	-- 6. Chronomancer: Record Card for Rewind
	------------------------------------------------------------
	elseif heroClass.Id == "Chronomancer" then
		gState.LastCardPlayed = card
	end

	return result
end

--[=[
	Evaluates class gimmicks on turn end.
	Handles:
	- Aether Mage Overload detonation or crystal shields.
	- Mechanist Turret automated fire and shields.
	- Necrobinder Bone Servant strikes.
	- Beastmaster Spirit Wolf attacks.
]=]
function ClassManager.processGimmickOnTurnEnd(
	player: Player,
	session: any,
	enemy: any
): GimmickTurnEndResult
	local heroClass = ClassManager.getPlayerClass(player)
	local subclass = ClassManager.getPlayerSubclass(player)
	local gState = getOrCreateGimmickState(player.UserId)

	local result: GimmickTurnEndResult = {
		EndTurnDamage = 0,
		EndTurnShield = 0,
		EndTurnHeal = 0,
	}

	------------------------------------------------------------
	-- 1. Aether Mage: Overload
	------------------------------------------------------------
	if heroClass.Id == "AetherMage" then
		local unspent = session.Energy
		if unspent > 0 then
			gState.OverloadCharges += unspent

			if subclass and subclass.Id == "Pyromancer" then
				local pyroDmg = unspent * 5
				result.EndTurnDamage += pyroDmg
				sendFeedback(player, string.format("🔥 Pyromancy Detonation: %d DMG!", pyroDmg), Color3.fromRGB(255, 80, 40))
			elseif subclass and subclass.Id == "Cryomancer" then
				local cryoShield = unspent * 4
				result.EndTurnShield += cryoShield
				sendFeedback(player, string.format("❄️ Glacial Armor: +%d Shield!", cryoShield), Color3.fromRGB(80, 200, 255))
			else
				sendFeedback(player, string.format("🔮 Stored %d Overload charges for next turn!", unspent), Color3.fromRGB(120, 160, 255))
			end
		end

	------------------------------------------------------------
	-- 2. Mechanist: Automated Turrets
	------------------------------------------------------------
	elseif heroClass.Id == "Mechanist" and gState.ActiveTurrets > 0 then
		local turretDmg = gState.ActiveTurrets * 6
		result.EndTurnDamage += turretDmg
		sendFeedback(player, string.format("🤖 Turrets Fired for %d DMG!", turretDmg), Color3.fromRGB(240, 160, 60))

		if subclass and subclass.Id == "Artificer" then
			local artShield = gState.ActiveTurrets * 4
			result.EndTurnShield += artShield
			sendFeedback(player, string.format("🛡️ Artificer Alloy: +%d Shield!", artShield), Color3.fromRGB(100, 180, 240))
		end

	------------------------------------------------------------
	-- 3. Necrobinder: Bone Servants
	------------------------------------------------------------
	elseif heroClass.Id == "Necrobinder" and gState.BoneServants > 0 then
		local servantDmg = gState.BoneServants * 8
		result.EndTurnDamage += servantDmg
		sendFeedback(player, string.format("💀 Bone Servants attacked for %d DMG!", servantDmg), Color3.fromRGB(120, 220, 160))

	------------------------------------------------------------
	-- 4. Beastmaster: Spirit Wolf
	------------------------------------------------------------
	elseif heroClass.Id == "Beastmaster" and gState.WolfHP > 0 then
		local wolfDmg = gState.WolfAttack
		result.EndTurnDamage += wolfDmg
		sendFeedback(player, string.format("🐺 Spirit Wolf struck for %d DMG!", wolfDmg), Color3.fromRGB(190, 140, 80))
	end

	-- Reset turn-based Combo sequence for Shadowblade
	gState.ComboCount = 0

	return result
end

--[=[
	Evaluates class gimmicks on entity kill.
	Handles Necrobinder soul harvests and Reaper healing.
]=]
function ClassManager.processGimmickOnKill(player: Player, session: any, enemy: any)
	local heroClass = ClassManager.getPlayerClass(player)
	local subclass = ClassManager.getPlayerSubclass(player)
	local gState = getOrCreateGimmickState(player.UserId)

	if heroClass.Id == "Necrobinder" then
		local soulGain = (subclass and subclass.Id == "Reaper") and 2 or 1
		gState.SoulTokens += soulGain

		if subclass and subclass.Id == "Reaper" then
			session.HP = math.min(session.MaxHP, session.HP + 6)
			sendFeedback(player, "💀 Reaper Soul Siphon: +6 HP!", Color3.fromRGB(80, 240, 140))
		end

		if gState.SoulTokens >= 5 then
			gState.SoulTokens -= 5
			local maxServants = (subclass and subclass.Id == "SwarmLord") and 3 or 1
			if gState.BoneServants < maxServants then
				gState.BoneServants += 1
				sendFeedback(player, "💀 Summoned a Bone Servant!", Color3.fromRGB(100, 255, 180))
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Remote Event Handlers
--------------------------------------------------------------------------------

SelectClassEvent.OnServerEvent:Connect(function(player: Player, payload: any)
	if typeof(payload) ~= "table" then return end
	local classId = payload.ClassId
	local subclassId = payload.SubclassId

	if typeof(classId) == "string" and typeof(subclassId) == "string" then
		ClassManager.selectClass(player, classId, subclassId)
	end
end)

RequestClassSelectionEvent.OnServerEvent:Connect(function(player: Player)
	local heroClass = ClassManager.getPlayerClass(player)
	local subclass = ClassManager.getPlayerSubclass(player)

	ClassSelectionUpdateEvent:FireClient(player, {
		UserId = player.UserId,
		PlayerName = player.DisplayName or player.Name,
		ClassId = heroClass.Id,
		ClassName = heroClass.Name,
		SubclassId = subclass and subclass.Id or "",
		SubclassName = subclass and subclass.Name or "",
		Icon = heroClass.Icon,
	})
end)

--------------------------------------------------------------------------------
-- Player Lifecycle
--------------------------------------------------------------------------------

Players.PlayerAdded:Connect(function(player: Player)
	playerSelections[player.UserId] = {
		ClassId = "Warlord",
		SubclassId = "Berserker",
	}
	ClassManager.resetCombatGimmickState(player)
end)

Players.PlayerRemoving:Connect(function(player: Player)
	playerSelections[player.UserId] = nil
	gimmickStates[player.UserId] = nil
end)

for _, p in Players:GetPlayers() do
	if not playerSelections[p.UserId] then
		playerSelections[p.UserId] = {
			ClassId = "Warlord",
			SubclassId = "Berserker",
		}
		ClassManager.resetCombatGimmickState(p)
	end
end

--------------------------------------------------------------------------------
-- Global & Inter-Script Export
--------------------------------------------------------------------------------

_G.ClassManager = ClassManager

return ClassManager
