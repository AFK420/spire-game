--!strict

--[=[
	CombatServer Script
	1. Spawns 3D Battle Arena & Boss Monster on the Workspace grid.
	2. Manages turn-based card battler state, RemoteEvents, and networking.
	3. Integrates with DungeonMap (4 Acts, 10 Tiers) for room-to-room progression.
	4. Provides both real-time player combat and an automated simulation loop.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CardData = require(Shared:WaitForChild("CardData") :: ModuleScript)
local DungeonMap = require(Shared:WaitForChild("DungeonMap") :: ModuleScript)

--------------------------------------------------------------------------------
-- Remote Events Setup
--------------------------------------------------------------------------------

local combatEventsFolder = ReplicatedStorage:FindFirstChild("CombatEvents")
if not combatEventsFolder then
	local folder = Instance.new("Folder")
	folder.Name = "CombatEvents"
	folder.Parent = ReplicatedStorage
	combatEventsFolder = folder
end

local function getOrCreateRemoteEvent(name: string): RemoteEvent
	local existing = combatEventsFolder:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local event = Instance.new("RemoteEvent")
	event.Name = name
	event.Parent = combatEventsFolder
	return event
end

local PlayCardEvent = getOrCreateRemoteEvent("PlayCard")
local EndTurnEvent = getOrCreateRemoteEvent("EndTurn")
local StateUpdateEvent = getOrCreateRemoteEvent("StateUpdate")
local CombatActionEvent = getOrCreateRemoteEvent("CombatAction")
local SelectMapNodeEvent = getOrCreateRemoteEvent("SelectMapNode")
local MapUpdateEvent = getOrCreateRemoteEvent("MapUpdate")

--------------------------------------------------------------------------------
-- Type Definitions
--------------------------------------------------------------------------------

export type PlayerCombatant = {
	PlayerInstance: Player?,
	Name: string,
	MaxHP: number,
	HP: number,
	Shield: number,
	Poison: number,
	Energy: number,
	MaxEnergy: number,
	Deck: { CardData.Card },
	Hand: { CardData.Card },
	DiscardPile: { CardData.Card },
	DungeonRun: DungeonMap.DungeonRun,
	InCombat: boolean,
	TurnNumber: number,
}

export type BossCombatant = {
	Name: string,
	MaxHP: number,
	HP: number,
	Shield: number,
	Poison: number,
	AttackPower: number,
	Model: Model?,
	OverheadGui: BillboardGui?,
}

--------------------------------------------------------------------------------
-- 3D World Spawner (Arena & Boss on the Grid)
--------------------------------------------------------------------------------

local ARENA_ORIGIN = Vector3.new(0, 0, 0)
local PLAYER_STAND_POS = Vector3.new(0, 1.2, 16)
local BOSS_STAND_POS = Vector3.new(0, 1.2, -16)

local function buildArena(): Model
	local existing = Workspace:FindFirstChild("CombatArena")
	if existing and existing:IsA("Model") then
		existing:Destroy()
	end

	local arenaModel = Instance.new("Model")
	arenaModel.Name = "CombatArena"

	-- Main stone platform
	local floor = Instance.new("Part")
	floor.Name = "ArenaFloor"
	floor.Size = Vector3.new(50, 2, 50)
	floor.Position = ARENA_ORIGIN + Vector3.new(0, 0, 0)
	floor.Anchored = true
	floor.Material = Enum.Material.Cobblestone
	floor.Color = Color3.fromRGB(38, 40, 46)
	floor.TopSurface = Enum.SurfaceType.Smooth
	floor.Parent = arenaModel

	-- Glowing border ring
	local border = Instance.new("Part")
	border.Name = "ArenaBorder"
	border.Size = Vector3.new(52, 0.4, 52)
	border.Position = ARENA_ORIGIN + Vector3.new(0, 1.05, 0)
	border.Anchored = true
	border.Material = Enum.Material.Neon
	border.Color = Color3.fromRGB(60, 140, 220)
	border.CanCollide = false
	border.Transparency = 0.4
	border.Parent = arenaModel

	-- Player Pad
	local playerPad = Instance.new("Part")
	playerPad.Name = "PlayerPedestal"
	playerPad.Shape = Enum.PartType.Cylinder
	playerPad.Size = Vector3.new(0.6, 8, 8)
	playerPad.CFrame = CFrame.new(PLAYER_STAND_POS) * CFrame.Angles(0, 0, math.rad(90))
	playerPad.Anchored = true
	playerPad.Material = Enum.Material.Neon
	playerPad.Color = Color3.fromRGB(45, 120, 240)
	playerPad.Parent = arenaModel

	-- SpawnLocation
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "ArenaSpawn"
	spawn.Size = Vector3.new(6, 0.5, 6)
	spawn.Position = PLAYER_STAND_POS + Vector3.new(0, 0.4, 0)
	spawn.Anchored = true
	spawn.Material = Enum.Material.Neon
	spawn.Color = Color3.fromRGB(50, 150, 255)
	spawn.Transparency = 0.7
	spawn.CanCollide = true
	spawn.Duration = 0
	spawn.Parent = arenaModel

	-- Boss Pad
	local bossPad = Instance.new("Part")
	bossPad.Name = "BossPedestal"
	bossPad.Shape = Enum.PartType.Cylinder
	bossPad.Size = Vector3.new(0.6, 10, 10)
	bossPad.CFrame = CFrame.new(BOSS_STAND_POS) * CFrame.Angles(0, 0, math.rad(90))
	bossPad.Anchored = true
	bossPad.Material = Enum.Material.Neon
	bossPad.Color = Color3.fromRGB(200, 45, 45)
	bossPad.Parent = arenaModel

	-- Perimeter Pillars
	local pillarPositions = {
		Vector3.new(-22, 6, -22),
		Vector3.new(22, 6, -22),
		Vector3.new(-22, 6, 22),
		Vector3.new(22, 6, 22),
	}

	for i, pos in pillarPositions do
		local pillar = Instance.new("Part")
		pillar.Name = "Pillar_" .. i
		pillar.Size = Vector3.new(3, 12, 3)
		pillar.Position = pos
		pillar.Anchored = true
		pillar.Material = Enum.Material.SmoothPlastic
		pillar.Color = Color3.fromRGB(28, 30, 36)
		pillar.Parent = arenaModel

		local beacon = Instance.new("Part")
		beacon.Name = "Beacon"
		beacon.Size = Vector3.new(1.8, 1.8, 1.8)
		beacon.Position = pos + Vector3.new(0, 6.5, 0)
		beacon.Anchored = true
		beacon.Material = Enum.Material.Neon
		beacon.Color = (pos.Z < 0) and Color3.fromRGB(240, 60, 60) or Color3.fromRGB(60, 160, 255)
		beacon.Parent = arenaModel

		local light = Instance.new("PointLight")
		light.Color = beacon.Color
		light.Range = 18
		light.Brightness = 2
		light.Parent = beacon
	end

	arenaModel.Parent = Workspace
	return arenaModel
end

local function buildBossModel(): Model
	local existing = Workspace:FindFirstChild("BossEntity")
	if existing and existing:IsA("Model") then
		existing:Destroy()
	end

	local boss = Instance.new("Model")
	boss.Name = "BossEntity"

	-- Main Torso
	local torso = Instance.new("Part")
	torso.Name = "HumanoidRootPart"
	torso.Size = Vector3.new(4, 5, 3)
	torso.CFrame = CFrame.new(BOSS_STAND_POS + Vector3.new(0, 5, 0)) * CFrame.Angles(0, 0, 0)
	torso.Anchored = true
	torso.Material = Enum.Material.Granite
	torso.Color = Color3.fromRGB(35, 35, 42)
	torso.Parent = boss
	boss.PrimaryPart = torso

	-- Glowing Core Chest
	local chestCore = Instance.new("Part")
	chestCore.Name = "ChestCore"
	chestCore.Size = Vector3.new(2, 2.5, 0.6)
	chestCore.CFrame = torso.CFrame * CFrame.new(0, 0.4, -1.3)
	chestCore.Anchored = true
	chestCore.Material = Enum.Material.Neon
	chestCore.Color = Color3.fromRGB(230, 45, 45)
	chestCore.Parent = boss

	local coreLight = Instance.new("PointLight")
	coreLight.Color = chestCore.Color
	coreLight.Range = 14
	coreLight.Brightness = 3
	coreLight.Parent = chestCore

	-- Head
	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(2.4, 2.4, 2.4)
	head.CFrame = torso.CFrame * CFrame.new(0, 3.7, 0)
	head.Anchored = true
	head.Material = Enum.Material.Obsidian
	head.Color = Color3.fromRGB(22, 22, 28)
	head.Parent = boss

	-- Visor
	local visor = Instance.new("Part")
	visor.Name = "Visor"
	visor.Size = Vector3.new(1.8, 0.5, 0.4)
	visor.CFrame = head.CFrame * CFrame.new(0, 0.2, -1.1)
	visor.Anchored = true
	visor.Material = Enum.Material.Neon
	visor.Color = Color3.fromRGB(255, 60, 60)
	visor.Parent = boss

	-- Shoulders & Horns
	for _, side in { -1, 1 } do
		local shoulder = Instance.new("Part")
		shoulder.Name = (side == -1) and "LeftShoulder" or "RightShoulder"
		shoulder.Size = Vector3.new(2.2, 3, 2.4)
		shoulder.CFrame = torso.CFrame * CFrame.new(side * 3.2, 1.2, 0)
		shoulder.Anchored = true
		shoulder.Material = Enum.Material.Granite
		shoulder.Color = Color3.fromRGB(45, 45, 52)
		shoulder.Parent = boss

		local horn = Instance.new("Part")
		horn.Name = "Horn"
		horn.Size = Vector3.new(0.8, 1.8, 0.8)
		horn.CFrame = shoulder.CFrame * CFrame.new(0, 2, 0) * CFrame.Angles(0, 0, math.rad(side * -20))
		horn.Anchored = true
		horn.Material = Enum.Material.Neon
		horn.Color = Color3.fromRGB(220, 50, 50)
		horn.Parent = boss
	end

	-- Overhead BillboardGui
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "OverheadDisplay"
	billboard.Size = UDim2.new(8, 0, 3.5, 0)
	billboard.StudsOffset = Vector3.new(0, 6.5, 0)
	billboard.AlwaysOnTop = true
	billboard.Adornee = head

	local container = Instance.new("Frame")
	container.Name = "Container"
	container.Size = UDim2.new(1, 0, 1, 0)
	container.BackgroundTransparency = 1
	container.Parent = billboard

	local title = Instance.new("TextLabel")
	title.Name = "BossTitle"
	title.Size = UDim2.new(1, 0, 0.28, 0)
	title.Position = UDim2.new(0, 0, 0, 0)
	title.BackgroundTransparency = 1
	title.Text = "👹 THE SPIRE GUARDIAN"
	title.TextColor3 = Color3.fromRGB(255, 80, 80)
	title.TextScaled = true
	title.Font = Enum.Font.GothamBold
	title.Parent = container

	local hpBg = Instance.new("Frame")
	hpBg.Name = "HPBackground"
	hpBg.Size = UDim2.new(0.9, 0, 0.22, 0)
	hpBg.Position = UDim2.new(0.05, 0, 0.32, 0)
	hpBg.BackgroundColor3 = Color3.fromRGB(40, 15, 15)
	hpBg.BorderSizePixel = 0
	hpBg.Parent = container

	local hpBgCorner = Instance.new("UICorner")
	hpBgCorner.CornerRadius = UDim.new(0, 6)
	hpBgCorner.Parent = hpBg

	local hpFill = Instance.new("Frame")
	hpFill.Name = "HPFill"
	hpFill.Size = UDim2.new(1, 0, 1, 0)
	hpFill.BackgroundColor3 = Color3.fromRGB(220, 45, 45)
	hpFill.BorderSizePixel = 0
	hpFill.Parent = hpBg

	local hpFillCorner = Instance.new("UICorner")
	hpFillCorner.CornerRadius = UDim.new(0, 6)
	hpFillCorner.Parent = hpFill

	local hpText = Instance.new("TextLabel")
	hpText.Name = "HPText"
	hpText.Size = UDim2.new(1, 0, 1, 0)
	hpText.BackgroundTransparency = 1
	hpText.Text = "200 / 200 HP"
	hpText.TextColor3 = Color3.fromRGB(255, 255, 255)
	hpText.TextScaled = true
	hpText.Font = Enum.Font.GothamBold
	hpText.Parent = hpBg

	local statusBar = Instance.new("TextLabel")
	statusBar.Name = "StatusBar"
	statusBar.Size = UDim2.new(1, 0, 0.28, 0)
	statusBar.Position = UDim2.new(0, 0, 0.62, 0)
	statusBar.BackgroundTransparency = 1
	statusBar.Text = "🛡️ 0   🧪 0   |   ⚔️ Intent: Attack (12)"
	statusBar.TextColor3 = Color3.fromRGB(240, 230, 180)
	statusBar.TextScaled = true
	statusBar.Font = Enum.Font.GothamMedium
	statusBar.Parent = container

	billboard.Parent = boss
	boss.Parent = Workspace
	return boss
end

--------------------------------------------------------------------------------
-- Global Battle State
--------------------------------------------------------------------------------

local currentBoss: BossCombatant = {
	Name = "The Spire Guardian",
	MaxHP = 200,
	HP = 200,
	Shield = 0,
	Poison = 0,
	AttackPower = 12,
	Model = nil,
	OverheadGui = nil,
}

local activeSessions: { [Player]: PlayerCombatant } = {}

-- Updates the overhead billboard above the Boss
local function updateBossBillboard()
	if not currentBoss.Model then return end
	local head = currentBoss.Model:FindFirstChild("Head")
	if not head then return end
	local billboard = head:FindFirstChild("OverheadDisplay") :: BillboardGui?
	if not billboard then return end

	local container = billboard:FindFirstChild("Container") :: Frame?
	if not container then return end

	local title = container:FindFirstChild("BossTitle") :: TextLabel?
	if title then
		title.Text = "👹 " .. currentBoss.Name
	end

	local hpBg = container:FindFirstChild("HPBackground") :: Frame?
	if hpBg then
		local hpFill = hpBg:FindFirstChild("HPFill") :: Frame?
		local hpText = hpBg:FindFirstChild("HPText") :: TextLabel?
		if hpFill and hpText then
			local ratio = math.clamp(currentBoss.HP / currentBoss.MaxHP, 0, 1)
			hpFill.Size = UDim2.new(ratio, 0, 1, 0)
			hpText.Text = string.format("%d / %d HP", currentBoss.HP, currentBoss.MaxHP)
		end
	end

	local statusBar = container:FindFirstChild("StatusBar") :: TextLabel?
	if statusBar then
		statusBar.Text = string.format(
			"🛡️ Shield: %d   🧪 Poison: %d   |   ⚔️ Intent: Attack (%d)",
			currentBoss.Shield,
			currentBoss.Poison,
			currentBoss.AttackPower
		)
	end
end

-- Sends the map state payload to the client
local function syncMapState(player: Player, shouldOpenMap: boolean?)
	local session = activeSessions[player]
	if not session or not session.DungeonRun then return end

	local run = session.DungeonRun
	local currentAct = run.Acts[run.CurrentActIndex]
	local availableNodes = DungeonMap.getAvailableNextNodes(run)

	local availableIds: { string } = {}
	for _, node in availableNodes do
		table.insert(availableIds, node.Id)
	end

	local payload = {
		ActNumber = currentAct.ActNumber,
		ActName = currentAct.Name,
		CurrentTier = run.CurrentTier,
		CurrentNodeId = run.CurrentNodeId,
		ClearedNodeIds = run.ClearedNodeIds,
		AvailableNodeIds = availableIds,
		IsCompleted = run.IsCompleted,
		Tiers = currentAct.Tiers,
		ShouldOpen = shouldOpenMap or false,
	}

	MapUpdateEvent:FireClient(player, payload)
end

-- Sends a combat state update payload to a player
local function syncPlayerState(player: Player, turnMessage: string?)
	local session = activeSessions[player]
	if not session then return end

	local payload = {
		Player = {
			Name = session.Name,
			HP = session.HP,
			MaxHP = session.MaxHP,
			Shield = session.Shield,
			Energy = session.Energy,
			MaxEnergy = session.MaxEnergy,
			DeckCount = #session.Deck,
			DiscardCount = #session.DiscardPile,
			Hand = session.Hand,
			InCombat = session.InCombat,
		},
		Boss = {
			Name = currentBoss.Name,
			HP = currentBoss.HP,
			MaxHP = currentBoss.MaxHP,
			Shield = currentBoss.Shield,
			Poison = currentBoss.Poison,
			AttackPower = currentBoss.AttackPower,
		},
		Message = turnMessage or "",
	}

	StateUpdateEvent:FireClient(player, payload)
	updateBossBillboard()
end

--------------------------------------------------------------------------------
-- Core Combat Functions
--------------------------------------------------------------------------------

local function drawCards(session: PlayerCombatant, count: number)
	for _ = 1, count do
		if #session.Deck == 0 and #session.DiscardPile > 0 then
			for _, c in session.DiscardPile do
				table.insert(session.Deck, c)
			end
			table.clear(session.DiscardPile)

			local rng = Random.new()
			for i = #session.Deck, 2, -1 do
				local j = rng:NextInteger(1, i)
				session.Deck[i], session.Deck[j] = session.Deck[j], session.Deck[i]
			end
		end

		if #session.Deck > 0 then
			local card = table.remove(session.Deck, 1) :: CardData.Card
			table.insert(session.Hand, card)
		else
			break
		end
	end
end

local function applyDamage(targetName: string, target: { HP: number, Shield: number }, amount: number): (number, number)
	local absorbed = math.min(target.Shield, amount)
	target.Shield -= absorbed
	local rem = amount - absorbed
	target.HP = math.max(0, target.HP - rem)
	return rem, absorbed
end

local function executeEffects(card: CardData.Card, session: PlayerCombatant, player: Player)
	local bonusDmg = 0
	local relicMgr = _G.RelicManager
	if relicMgr then
		local cardTrig = relicMgr.triggerEvent(player, "OnCardPlay", {
			Session = session,
			Card = card,
			Enemy = currentBoss,
		})
		if cardTrig.BonusDamage then
			bonusDmg = cardTrig.BonusDamage
		end
		if cardTrig.BonusEnergy and cardTrig.BonusEnergy > 0 then
			session.Energy += cardTrig.BonusEnergy
		end
	end

	local classMgr = _G.ClassManager
	if classMgr then
		local gRes = classMgr.processGimmickOnCardPlay(player, card, session, currentBoss)
		bonusDmg += (gRes.BonusDamage or 0)
		if gRes.BonusShield and gRes.BonusShield > 0 then
			session.Shield += gRes.BonusShield
		end
		if gRes.PoisonApplied and gRes.PoisonApplied > 0 then
			currentBoss.Poison += gRes.PoisonApplied
		end
		if gRes.FreeEnergyCost then
			session.Energy = math.min(session.MaxEnergy, session.Energy + card.Cost)
		end
	end

	for _, effect in card.Effects do
		if effect.Type == "Damage" then
			local totalDmg = effect.Value + bonusDmg
			local remDmg, absorbed = applyDamage(currentBoss.Name, currentBoss, totalDmg)
			CombatActionEvent:FireClient(player, {
				Target = "Boss",
				Type = "Damage",
				Value = totalDmg,
				Text = string.format("-%d HP", remDmg),
			})
		elseif effect.Type == "Shield" then
			session.Shield += effect.Value
			CombatActionEvent:FireClient(player, {
				Target = "Player",
				Type = "Shield",
				Value = effect.Value,
				Text = string.format("+%d Shield", effect.Value),
			})
		elseif effect.Type == "Poison" then
			currentBoss.Poison += effect.Value
			CombatActionEvent:FireClient(player, {
				Target = "Boss",
				Type = "Poison",
				Value = effect.Value,
				Text = string.format("+%d Poison", effect.Value),
			})
		end
	end
end

local function handleBossAttack(player: Player, session: PlayerCombatant)
	-- Visual attack animation
	if currentBoss.Model and currentBoss.Model.PrimaryPart then
		local originalCF = currentBoss.Model.PrimaryPart.CFrame
		local lungeCF = originalCF * CFrame.new(0, 0, 4)
		local tweenInfo = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, true)
		local tween = TweenService:Create(currentBoss.Model.PrimaryPart, tweenInfo, { CFrame = lungeCF })
		tween:Play()
	end

	task.wait(0.3)

	-- Apply Boss damage
	local remDmg, _ = applyDamage(session.Name, session, currentBoss.AttackPower)
	CombatActionEvent:FireClient(player, {
		Target = "Player",
		Type = "Damage",
		Value = currentBoss.AttackPower,
		Text = string.format("-%d HP", remDmg),
	})

	-- OnDamageTaken relic triggers (e.g. Bronze Scales thorns, Centennial Puzzle draw)
	local relicMgr = _G.RelicManager
	if remDmg > 0 and relicMgr then
		local dmgTrig = relicMgr.triggerEvent(player, "OnDamageTaken", {
			Session = session,
			Damage = remDmg,
			Enemy = currentBoss,
		})
		if dmgTrig.BonusDamage > 0 then
			local cRem, _ = applyDamage(currentBoss.Name, currentBoss, dmgTrig.BonusDamage)
			CombatActionEvent:FireClient(player, {
				Target = "Boss",
				Type = "Damage",
				Value = dmgTrig.BonusDamage,
				Text = string.format("-%d Thorns", cRem),
			})
		end
		if dmgTrig.BonusDraw > 0 then
			drawCards(session, dmgTrig.BonusDraw)
		end
	end

	-- Poison tick on Boss
	if currentBoss.Poison > 0 then
		local poisonDmg = currentBoss.Poison
		currentBoss.HP = math.max(0, currentBoss.HP - poisonDmg)
		currentBoss.Poison -= 1
		CombatActionEvent:FireClient(player, {
			Target = "Boss",
			Type = "PoisonTick",
			Value = poisonDmg,
			Text = string.format("-%d Poison DMG", poisonDmg),
		})
	end
end

-- Configures a room encounter based on its NodeType
local function startRoomEncounter(player: Player, session: PlayerCombatant, node: DungeonMap.DungeonNode)
	session.Shield = 0
	session.Energy = session.MaxEnergy
	table.clear(session.Hand)
	drawCards(session, 4)

	if node.Type == "Combat" then
		session.InCombat = true
		currentBoss.Name = "Spire Sentinel"
		currentBoss.MaxHP = 75
		currentBoss.HP = 75
		currentBoss.Shield = 0
		currentBoss.Poison = 0
		currentBoss.AttackPower = 8
		syncPlayerState(player, string.format("Entered Room: %s (Tier %d)", node.Type, node.Tier))
	elseif node.Type == "Elite Monster" then
		session.InCombat = true
		currentBoss.Name = "Gremlin Nob (Elite)"
		currentBoss.MaxHP = 135
		currentBoss.HP = 135
		currentBoss.Shield = 0
		currentBoss.Poison = 0
		currentBoss.AttackPower = 14
		syncPlayerState(player, string.format("⚠️ ELITE ENCOUNTER! %s (Tier %d)", node.Type, node.Tier))
	elseif node.Type == "Campfire Rest" then
		session.InCombat = false
		local healAmount = math.floor(session.MaxHP * 0.3)
		session.HP = math.min(session.MaxHP, session.HP + healAmount)
		CombatActionEvent:FireClient(player, {
			Target = "Player",
			Type = "Shield",
			Value = healAmount,
			Text = string.format("+%d HP (Rested)", healAmount),
		})
		syncPlayerState(player, string.format("🔥 Campfire Rest: Restored %d HP! Open Map to continue.", healAmount))
		task.delay(1.0, function()
			syncMapState(player, true)
		end)
	elseif node.Type == "Merchant Shop" then
		session.InCombat = false
		syncPlayerState(player, "💰 Merchant Shop: Supplies replenished! Open Map to continue.")
		task.delay(1.0, function()
			syncMapState(player, true)
		end)
	elseif node.Type == "Act Boss" then
		session.InCombat = true
		currentBoss.Name = "The Spire Guardian (Boss)"
		currentBoss.MaxHP = 200
		currentBoss.HP = 200
		currentBoss.Shield = 0
		currentBoss.Poison = 0
		currentBoss.AttackPower = 12
		syncPlayerState(player, string.format("👹 ACT BOSS BATTLE! %s", node.Type))
	end

	updateBossBillboard()
	syncMapState(player, false)

	-- Relic Trigger: OnCombatStart and Turn 1 OnTurnStart
	session.TurnNumber = 1
	local relicMgr = _G.RelicManager
	if session.InCombat and relicMgr then
		relicMgr.resetCombatState(player)

		local combatTrig = relicMgr.triggerEvent(player, "OnCombatStart", {
			Session = session,
			Enemy = currentBoss,
			TurnNumber = 1,
		})
		if combatTrig.BonusShield > 0 then
			session.Shield += combatTrig.BonusShield
		end
		if combatTrig.HealAmount > 0 then
			session.HP = math.min(session.MaxHP, session.HP + combatTrig.HealAmount)
		end
		if combatTrig.PoisonApplied > 0 then
			currentBoss.Poison += combatTrig.PoisonApplied
		end

		local turnTrig = relicMgr.triggerEvent(player, "OnTurnStart", {
			Session = session,
			Enemy = currentBoss,
			TurnNumber = 1,
		})
		if turnTrig.BonusEnergy > 0 then
			session.Energy += turnTrig.BonusEnergy
		end
		if turnTrig.BonusDraw > 0 then
			drawCards(session, turnTrig.BonusDraw)
		end

		syncPlayerState(player, "Combat Begins! Relics activated.")
	end
end

--------------------------------------------------------------------------------
-- Player Initializer
--------------------------------------------------------------------------------

local function initPlayerSession(player: Player): PlayerCombatant
	local run = DungeonMap.generateRun()

	local session: PlayerCombatant = {
		PlayerInstance = player,
		Name = player.DisplayName or player.Name,
		MaxHP = 100,
		HP = 100,
		Shield = 0,
		Poison = 0,
		Energy = 3,
		MaxEnergy = 3,
		Deck = {
			CardData.Strike,
			CardData.Defend,
			CardData.HeavyBlow,
			CardData.PoisonDart,
			CardData.Strike,
			CardData.Defend,
			CardData.Strike,
			CardData.Defend,
		},
		Hand = {},
		DiscardPile = {},
		DungeonRun = run,
		InCombat = false,
		TurnNumber = 1,
	}

	activeSessions[player] = session

	-- Inject selected Class starting stats & signature deck
	local classMgr = _G.ClassManager
	if classMgr and typeof(classMgr.applyClassToSession) == "function" then
		classMgr.applyClassToSession(player, session)
	end

	-- Position character on the player pedestal
	task.spawn(function()
		local char = player.Character or player.CharacterAdded:Wait()
		local root = char:WaitForChild("HumanoidRootPart") :: BasePart?
		if root then
			root.CFrame = CFrame.lookAt(PLAYER_STAND_POS + Vector3.new(0, 3, 0), BOSS_STAND_POS)
		end
	end)

	syncPlayerState(player, "Welcome to the Spire! Open Map to choose your starting path.")
	syncMapState(player, true) -- Automatically open map on game start!
	return session
end

--------------------------------------------------------------------------------
-- Remote Event Listeners
--------------------------------------------------------------------------------

PlayCardEvent.OnServerEvent:Connect(function(player: Player, handIndex: any)
	local session = activeSessions[player]
	if not session or not session.InCombat then return end
	if typeof(handIndex) ~= "number" then return end

	local index = math.floor(handIndex)
	if index < 1 or index > #session.Hand then return end

	local card = session.Hand[index]
	local classMgr = _G.ClassManager
	local heroClass = classMgr and classMgr.getPlayerClass(player)
	local isBloodPriest = heroClass and heroClass.Id == "BloodPriest"

	if session.Energy < card.Cost and not isBloodPriest then
		syncPlayerState(player, "Not enough Energy!")
		return
	end

	session.Energy = math.max(0, session.Energy - card.Cost)
	table.remove(session.Hand, index)
	table.insert(session.DiscardPile, card)

	executeEffects(card, session, player)

	-- Check Victory
	if currentBoss.HP <= 0 then
		local relicMgr = _G.RelicManager
		if relicMgr then
			relicMgr.triggerEvent(player, "OnKill", {
				Session = session,
				Enemy = currentBoss,
			})
		end
		if classMgr then
			classMgr.processGimmickOnKill(player, session, currentBoss)
		end
		session.InCombat = false
		syncPlayerState(player, "VICTORY! Room cleared! Open Map to choose next path.")
		print("[Combat] Victory! Room cleared.")
		task.delay(1.2, function()
			syncMapState(player, true) -- Prompt player to select next path on map
		end)
		return
	end

	syncPlayerState(player, string.format("Played [%s]!", card.Name))
end)

EndTurnEvent.OnServerEvent:Connect(function(player: Player)
	local session = activeSessions[player]
	if not session or not session.InCombat then return end

	syncPlayerState(player, currentBoss.Name .. " is counterattacking...")

	local classMgr = _G.ClassManager

	-- Class Gimmick: OnTurnEnd (Overload charges, Turrets firing, Bone Servants, Spirit Wolf)
	if classMgr then
		local gEnd = classMgr.processGimmickOnTurnEnd(player, session, currentBoss)
		if gEnd.EndTurnDamage > 0 then
			local tRem, _ = applyDamage(currentBoss.Name, currentBoss, gEnd.EndTurnDamage)
			CombatActionEvent:FireClient(player, {
				Target = "Boss",
				Type = "Damage",
				Value = gEnd.EndTurnDamage,
				Text = string.format("-%d Gimmick DMG", tRem),
			})
		end
		if gEnd.EndTurnShield > 0 then
			session.Shield += gEnd.EndTurnShield
		end
		if gEnd.EndTurnHeal > 0 then
			session.HP = math.min(session.MaxHP, session.HP + gEnd.EndTurnHeal)
		end
	end

	-- Relic Trigger: OnTurnEnd (Orichalcum shield, Pocketwatch card draw, Calipers retention)
	local retainShield = false
	local relicMgr = _G.RelicManager
	if relicMgr then
		local endTrig = relicMgr.triggerEvent(player, "OnTurnEnd", {
			Session = session,
			Enemy = currentBoss,
			UnspentEnergy = session.Energy,
		})
		if endTrig.BonusShield > 0 then
			session.Shield += endTrig.BonusShield
		end
		retainShield = endTrig.RetainShield
	end

	-- Discard remaining hand
	for _, c in session.Hand do
		table.insert(session.DiscardPile, c)
	end
	table.clear(session.Hand)

	-- Boss counterattacks
	task.spawn(function()
		handleBossAttack(player, session)

		-- Check Defeat
		if session.HP <= 0 then
			session.InCombat = false
			syncPlayerState(player, "DEFEAT! You were slain in battle.")
			return
		end

		-- Check Boss Defeat (e.g. from Poison or Thorns)
		if currentBoss.HP <= 0 then
			if relicMgr then
				relicMgr.triggerEvent(player, "OnKill", {
					Session = session,
					Enemy = currentBoss,
				})
			end
			session.InCombat = false
			syncPlayerState(player, "VICTORY! Room cleared! Open Map to choose next path.")
			task.delay(1.2, function()
				syncMapState(player, true)
			end)
			return
		end

		-- Reset shield & replenish energy (respecting Calipers retention)
		if not retainShield then
			session.Shield = 0
		else
			session.Shield = math.min(15, session.Shield)
		end
		session.Energy = session.MaxEnergy
		session.TurnNumber += 1

		local bonusDraw = 0
		if relicMgr then
			local startTrig = relicMgr.triggerEvent(player, "OnTurnStart", {
				Session = session,
				Enemy = currentBoss,
				TurnNumber = session.TurnNumber,
			})
			if startTrig.BonusEnergy > 0 then
				session.Energy += startTrig.BonusEnergy
			end
			if startTrig.BonusDraw > 0 then
				bonusDraw += startTrig.BonusDraw
			end
		end

		drawCards(session, 4 + bonusDraw)

		syncPlayerState(player, string.format("Your Turn (Turn %d)! Draw %d cards.", session.TurnNumber, 4 + bonusDraw))
	end)
end)

SelectMapNodeEvent.OnServerEvent:Connect(function(player: Player, targetNodeId: any)
	local session = activeSessions[player]
	if not session then return end
	if typeof(targetNodeId) ~= "string" then return end

	local success, err = DungeonMap.selectNextNode(session.DungeonRun, targetNodeId)
	if not success then
		syncPlayerState(player, err or "Invalid room selection.")
		return
	end

	local node = DungeonMap.getNode(session.DungeonRun, targetNodeId)
	if node then
		startRoomEncounter(player, session, node)
	end
end)

--------------------------------------------------------------------------------
-- Player Join Handling
--------------------------------------------------------------------------------

Players.PlayerAdded:Connect(function(player: Player)
	initPlayerSession(player)
end)

Players.PlayerRemoving:Connect(function(player: Player)
	activeSessions[player] = nil
end)

--------------------------------------------------------------------------------
-- Startup: Build 3D Arena & Boss
--------------------------------------------------------------------------------

buildArena()
local bossModel = buildBossModel()
currentBoss.Model = bossModel
updateBossBillboard()

for _, player in Players:GetPlayers() do
	initPlayerSession(player)
end

--------------------------------------------------------------------------------
-- Standalone Simulation (Prints to Output)
--------------------------------------------------------------------------------

local function runConsoleSimulation()
	print("============================================================")
	print("       STARTING TURN-BASED CARD BATTLER SIMULATION          ")
	print("============================================================")
	local pSim = {
		Name = "Hero",
		HP = 100, MaxHP = 100,
		Shield = 0, Poison = 0,
		Energy = 3, MaxEnergy = 3,
		Deck = { CardData.Strike, CardData.Defend, CardData.HeavyBlow },
		Hand = {} :: { CardData.Card },
		DiscardPile = {} :: { CardData.Card },
	}
	local bSim = {
		Name = "Boss",
		HP = 200, MaxHP = 200,
		Shield = 0, Poison = 0,
		AttackPower = 12,
	}

	for _ = 1, 3 do
		table.insert(pSim.Hand, table.remove(pSim.Deck, 1) :: CardData.Card)
	end

	pSim.Energy -= 1
	bSim.HP -= 6

	pSim.Energy -= 1
	pSim.Shield += 5

	local absorbed = math.min(pSim.Shield, bSim.AttackPower)
	pSim.Shield -= absorbed
	pSim.HP -= (bSim.AttackPower - absorbed)
	pSim.Energy = pSim.MaxEnergy

	print(string.format("Player [%s]: HP: %d/%d, Shield: %d, Energy: %d/%d", pSim.Name, pSim.HP, pSim.MaxHP, pSim.Shield, pSim.Energy, pSim.MaxEnergy))
	print(string.format("Enemy [%s]: HP: %d/%d, Shield: %d, Poison: %d", bSim.Name, bSim.HP, bSim.MaxHP, bSim.Shield, bSim.Poison))
	print("============================================================")
end

runConsoleSimulation()
