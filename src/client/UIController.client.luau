--!strict

--[=[
	UIController LocalScript
	Mapped to: StarterPlayer.StarterPlayerScripts.Client.UIController
	Centralized client UI controller for Card Rift: Co-op Dungeon:
	1. Listens to ReplicatedStorage.GameNetwork state updates (RunSnapshot, CombatSnapshot).
	2. Manages UI transitions across Run Phases (Lobby, MapSelect, ActiveRoom, Rewards).
	3. Renders the interactive procedural Dungeon Map tree for party voting and navigation.
	4. Renders the Active Combat HUD: multi-enemy targets, card hand (by CardInstanceId),
	   monotonic turn timer (45s), ready voting, and teammate rescue.
	5. Renders post-combat 3-card draft reward selection and gold progression.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)
local DungeonMap = require(Shared:WaitForChild("DungeonMap") :: ModuleScript)
local GameConfig = require(Shared:WaitForChild("GameConfig") :: ModuleScript)

--------------------------------------------------------------------------------
-- Remote Events Resolution via GameNetwork
--------------------------------------------------------------------------------

local function getEvent(name: string): RemoteEvent?
	local folder = ReplicatedStorage:WaitForChild("GameNetwork", 10) :: Folder?
	if folder then
		local ev = folder:WaitForChild(name, 5)
		if ev and ev:IsA("RemoteEvent") then
			return ev
		end
	end
	return nil
end

-- Client -> Server Actions
local StartRunEvent = getEvent("StartRun")
local VoteMapNodeEvent = getEvent("VoteMapNode")
local PlayCardEvent = getEvent("PlayCard")
local PlayerVoteReadyEvent = getEvent("PlayerVoteReady")
local RescueTeammateEvent = getEvent("RescueTeammate")
local ClaimRewardCardEvent = getEvent("ClaimRewardCard")
local ContinueFromRewardsEvent = getEvent("ContinueFromRewards")
local RequestStateSyncEvent = getEvent("RequestStateSync")

-- Server -> Client State
local RunStateUpdateEvent = getEvent("RunStateUpdate")
local CombatStateUpdateEvent = getEvent("CombatStateUpdate")
local CombatEventLoggedEvent = getEvent("CombatEventLogged")
local AnnouncementEvent = getEvent("Announcement")

--------------------------------------------------------------------------------
-- Modular UI Component Factory
--------------------------------------------------------------------------------

local UIFactory = {}

function UIFactory.createCorner(parent: Instance, radius: number): UICorner
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
	return corner
end

function UIFactory.createStroke(parent: Instance, color: Color3, thickness: number): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = parent
	return stroke
end

function UIFactory.createButton(parent: Instance, text: string, color: Color3, onClick: () -> ()): TextButton
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(1, 0, 1, 0)
	btn.BackgroundColor3 = color
	btn.BorderSizePixel = 0
	btn.Text = text
	btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	btn.Font = Enum.Font.GothamBold
	btn.TextSize = 15
	btn.AutoButtonColor = true
	btn.Parent = parent

	UIFactory.createCorner(btn, 8)
	btn.MouseButton1Click:Connect(onClick)
	return btn
end

function UIFactory.createProgressBar(parent: Instance, fillColor: Color3): (Frame, TextLabel, (number, number) -> ())
	local bg = Instance.new("Frame")
	bg.Size = UDim2.new(1, 0, 1, 0)
	bg.BackgroundColor3 = Color3.fromRGB(40, 20, 20)
	bg.BorderSizePixel = 0
	bg.Parent = parent
	UIFactory.createCorner(bg, 6)

	local fill = Instance.new("Frame")
	fill.Size = UDim2.new(1, 0, 1, 0)
	fill.BackgroundColor3 = fillColor
	fill.BorderSizePixel = 0
	fill.Parent = bg
	UIFactory.createCorner(fill, 6)

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = "100 / 100"
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 12
	label.Parent = bg

	local function update(current: number, max: number)
		local ratio = math.clamp(current / math.max(1, max), 0, 1)
		TweenService:Create(fill, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = UDim2.new(ratio, 0, 1, 0),
		}):Play()
		label.Text = string.format("%d / %d HP", current, max)
	end

	return fill, label, update
end

--------------------------------------------------------------------------------
-- Build Main ScreenGui Root
--------------------------------------------------------------------------------

local screenGui = playerGui:FindFirstChild("CardRiftScreenGui") :: ScreenGui?
if not screenGui then
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "CardRiftScreenGui"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = playerGui
else
	screenGui:ClearAllChildren()
end

local mainFrame = Instance.new("Frame")
mainFrame.Name = "MainFrame"
mainFrame.Size = UDim2.new(1, 0, 1, 0)
mainFrame.BackgroundTransparency = 1
mainFrame.Parent = screenGui

--------------------------------------------------------------------------------
-- Top Banner / Announcement Bar
--------------------------------------------------------------------------------

local bannerLabel = Instance.new("TextLabel")
bannerLabel.Name = "FlowBanner"
bannerLabel.Size = UDim2.new(0, 560, 0, 38)
bannerLabel.Position = UDim2.new(0.5, -280, 0, 14)
bannerLabel.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
bannerLabel.BackgroundTransparency = 0.2
bannerLabel.Text = "Welcome to Card Rift: Co-op Dungeon!"
bannerLabel.TextColor3 = Color3.fromRGB(255, 225, 90)
bannerLabel.Font = Enum.Font.GothamBold
bannerLabel.TextSize = 15
bannerLabel.Parent = mainFrame
UIFactory.createCorner(bannerLabel, 8)
UIFactory.createStroke(bannerLabel, Color3.fromRGB(70, 80, 100), 1)

--------------------------------------------------------------------------------
-- VIEW 1: Lobby View
--------------------------------------------------------------------------------

local lobbyView = Instance.new("Frame")
lobbyView.Name = "LobbyView"
lobbyView.Size = UDim2.new(0, 480, 0, 320)
lobbyView.Position = UDim2.new(0.5, -240, 0.5, -160)
lobbyView.BackgroundColor3 = Color3.fromRGB(22, 24, 32)
lobbyView.BackgroundTransparency = 0.1
lobbyView.BorderSizePixel = 0
lobbyView.Visible = true
lobbyView.Parent = mainFrame
UIFactory.createCorner(lobbyView, 14)
UIFactory.createStroke(lobbyView, Color3.fromRGB(50, 130, 230), 2.5)

local lobbyTitle = Instance.new("TextLabel")
lobbyTitle.Size = UDim2.new(1, 0, 0, 45)
lobbyTitle.Position = UDim2.new(0, 0, 0, 16)
lobbyTitle.BackgroundTransparency = 1
lobbyTitle.Text = "⚔️ CARD RIFT: CO-OP DUNGEON"
lobbyTitle.TextColor3 = Color3.fromRGB(120, 190, 255)
lobbyTitle.Font = Enum.Font.GothamBold
lobbyTitle.TextSize = 22
lobbyTitle.Parent = lobbyView

local lobbyDesc = Instance.new("TextLabel")
lobbyDesc.Size = UDim2.new(1, -40, 0, 40)
lobbyDesc.Position = UDim2.new(0, 20, 0, 65)
lobbyDesc.BackgroundTransparency = 1
lobbyDesc.Text = "Gather 1 to 4 heroes and challenge the multi-act Spire.\nDefeat monsters, draft powerful cards, and survive together!"
lobbyDesc.TextColor3 = Color3.fromRGB(190, 195, 210)
lobbyDesc.Font = Enum.Font.GothamMedium
lobbyDesc.TextSize = 13
lobbyDesc.Parent = lobbyView

local lobbyStatus = Instance.new("TextLabel")
lobbyStatus.Name = "LobbyStatus"
lobbyStatus.Size = UDim2.new(1, 0, 0, 30)
lobbyStatus.Position = UDim2.new(0, 0, 0, 130)
lobbyStatus.BackgroundTransparency = 1
lobbyStatus.Text = "Party Size: 1 Hero | Ready to embark"
lobbyStatus.TextColor3 = Color3.fromRGB(255, 215, 60)
lobbyStatus.Font = Enum.Font.GothamBold
lobbyStatus.TextSize = 14
lobbyStatus.Parent = lobbyView

local startRunBtnContainer = Instance.new("Frame")
startRunBtnContainer.Size = UDim2.new(0, 240, 0, 58)
startRunBtnContainer.Position = UDim2.new(0.5, -120, 0, 220)
startRunBtnContainer.BackgroundTransparency = 1
startRunBtnContainer.Parent = lobbyView

UIFactory.createButton(startRunBtnContainer, "START DUNGEON RUN ➔", Color3.fromRGB(45, 175, 80), function()
	if StartRunEvent then
		StartRunEvent:FireServer()
	end
end)

--------------------------------------------------------------------------------
-- VIEW 2: Dungeon Map View (MapSelect)
--------------------------------------------------------------------------------

local mapView = Instance.new("Frame")
mapView.Name = "DungeonMapView"
mapView.Size = UDim2.new(0, 680, 0, 540)
mapView.Position = UDim2.new(0.5, -340, 0.5, -270)
mapView.BackgroundColor3 = Color3.fromRGB(18, 20, 26)
mapView.BackgroundTransparency = 0.08
mapView.BorderSizePixel = 0
mapView.Visible = false
mapView.ZIndex = 15
mapView.Parent = mainFrame
UIFactory.createCorner(mapView, 14)
UIFactory.createStroke(mapView, Color3.fromRGB(45, 120, 220), 2.5)

local mapHeader = Instance.new("Frame")
mapHeader.Size = UDim2.new(1, 0, 0, 50)
mapHeader.BackgroundColor3 = Color3.fromRGB(26, 28, 36)
mapHeader.BorderSizePixel = 0
mapHeader.ZIndex = 16
mapHeader.Parent = mapView
UIFactory.createCorner(mapHeader, 14)

local mapTitle = Instance.new("TextLabel")
mapTitle.Name = "MapTitle"
mapTitle.Size = UDim2.new(1, -40, 1, 0)
mapTitle.Position = UDim2.new(0, 20, 0, 0)
mapTitle.BackgroundTransparency = 1
mapTitle.Text = "🗺️ Act 1: The Spire Threshold (Select Room)"
mapTitle.TextColor3 = Color3.fromRGB(255, 220, 100)
mapTitle.Font = Enum.Font.GothamBold
mapTitle.TextSize = 16
mapTitle.TextXAlignment = Enum.TextXAlignment.Left
mapTitle.ZIndex = 17
mapTitle.Parent = mapHeader

local mapScroll = Instance.new("ScrollingFrame")
mapScroll.Name = "MapScroll"
mapScroll.Size = UDim2.new(1, -20, 1, -65)
mapScroll.Position = UDim2.new(0, 10, 0, 55)
mapScroll.BackgroundTransparency = 1
mapScroll.BorderSizePixel = 0
mapScroll.ScrollBarThickness = 6
mapScroll.CanvasSize = UDim2.new(0, 0, 0, 800)
mapScroll.ZIndex = 16
mapScroll.Parent = mapView

local function buildDungeonMapTree(snapshot: StateTypes.RunSnapshot)
	for _, child in mapScroll:GetChildren() do
		if child:IsA("Frame") or child:IsA("TextLabel") or child:IsA("TextButton") then
			child:Destroy()
		end
	end

	mapTitle.Text = string.format("🗺️ %s (Tier %d/10) - Select Next Room", snapshot.ActName or "Act 1", snapshot.CurrentTier or 0)

	local availableSet: { [string]: boolean } = {}
	for _, id in snapshot.AvailableNodeIds do
		availableSet[id] = true
	end

	local tierHeight = 74
	for tierNum = 10, 1, -1 do
		local yPos = (10 - tierNum) * tierHeight + 12

		local tierLabel = Instance.new("TextLabel")
		tierLabel.Size = UDim2.new(0, 48, 0, 48)
		tierLabel.Position = UDim2.new(0, 8, 0, yPos)
		tierLabel.BackgroundTransparency = 1
		tierLabel.Text = string.format("T%02d", tierNum)
		tierLabel.TextColor3 = Color3.fromRGB(110, 125, 145)
		tierLabel.Font = Enum.Font.GothamBold
		tierLabel.TextSize = 13
		tierLabel.ZIndex = 17
		tierLabel.Parent = mapScroll

		-- Render available or standard nodes for tier
		for lane = 1, 3 do
			local laneX = 100 + (lane - 1) * 160
			local dummyNodeId = string.format("Act%d_T%d_L%d", snapshot.ActIndex, tierNum, lane)
			local isReachable = availableSet[dummyNodeId] or false

			-- Also check exact matches
			for _, avId in snapshot.AvailableNodeIds do
				if avId:find("T" .. tierNum) then
					dummyNodeId = avId
					isReachable = true
					break
				end
			end

			local nodeBtn = Instance.new("TextButton")
			nodeBtn.Name = "Node_" .. dummyNodeId
			nodeBtn.Size = UDim2.new(0, 54, 0, 54)
			nodeBtn.Position = UDim2.new(0, laneX, 0, yPos)
			nodeBtn.BackgroundColor3 = (tierNum == 10) and Color3.fromRGB(220, 50, 50) or (tierNum % 3 == 0 and Color3.fromRGB(220, 130, 40) or Color3.fromRGB(50, 120, 220))
			nodeBtn.BorderSizePixel = 0
			nodeBtn.Text = (tierNum == 10) and "👹" or (tierNum % 3 == 0 and "⚠️" or "⚔️")
			nodeBtn.TextSize = 24
			nodeBtn.ZIndex = 18
			nodeBtn.Parent = mapScroll
			UIFactory.createCorner(nodeBtn, 27)

			local stroke = UIFactory.createStroke(nodeBtn, Color3.fromRGB(255, 240, 100), 3)

			if isReachable then
				nodeBtn.AutoButtonColor = true
				local targetId = dummyNodeId
				nodeBtn.MouseButton1Click:Connect(function()
					if VoteMapNodeEvent then
						VoteMapNodeEvent:FireServer(targetId)
					end
				end)
			else
				stroke.Color = Color3.fromRGB(60, 65, 80)
				stroke.Thickness = 1
				nodeBtn.BackgroundTransparency = 0.5
			end
		end
	end
end

--------------------------------------------------------------------------------
-- VIEW 3: Active Combat HUD (Multi-Enemy & Card Hand)
--------------------------------------------------------------------------------

local combatHudView = Instance.new("Frame")
combatHudView.Name = "CombatHudView"
combatHudView.Size = UDim2.new(1, 0, 1, 0)
combatHudView.BackgroundTransparency = 1
combatHudView.Visible = false
combatHudView.Parent = mainFrame

-- Multi-Enemy Container (Top Center)
local enemiesContainer = Instance.new("Frame")
enemiesContainer.Name = "EnemiesContainer"
enemiesContainer.Size = UDim2.new(0, 800, 0, 100)
enemiesContainer.Position = UDim2.new(0.5, -400, 0, 55)
enemiesContainer.BackgroundTransparency = 1
enemiesContainer.Parent = combatHudView

local enemiesLayout = Instance.new("UIListLayout")
enemiesLayout.FillDirection = Enum.FillDirection.Horizontal
enemiesLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
enemiesLayout.Padding = UDim.new(0, 20)
enemiesLayout.Parent = enemiesContainer

local selectedEnemyId: string? = nil

local function renderEnemyCard(enemy: StateTypes.EnemyView): Frame
	local card = Instance.new("Frame")
	card.Name = "Enemy_" .. enemy.InstanceId
	card.Size = UDim2.new(0, 320, 0, 90)
	card.BackgroundColor3 = Color3.fromRGB(24, 26, 34)
	card.BackgroundTransparency = 0.15
	card.BorderSizePixel = 0
	UIFactory.createCorner(card, 10)

	local isSelected = (selectedEnemyId == enemy.InstanceId)
	local strokeColor = isSelected and Color3.fromRGB(255, 220, 60) or Color3.fromRGB(200, 50, 50)
	local strokeThickness = isSelected and 3 or 2
	local stroke = UIFactory.createStroke(card, strokeColor, strokeThickness)

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.new(1, -20, 0, 24)
	nameLabel.Position = UDim2.new(0, 10, 0, 6)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = "👹 " .. enemy.Name
	nameLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextSize = 14
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.Parent = card

	local hpContainer = Instance.new("Frame")
	hpContainer.Size = UDim2.new(1, -20, 0, 18)
	hpContainer.Position = UDim2.new(0, 10, 0, 32)
	hpContainer.BackgroundTransparency = 1
	hpContainer.Parent = card

	local _, _, updateHp = UIFactory.createProgressBar(hpContainer, Color3.fromRGB(220, 45, 45))
	updateHp(enemy.HP, enemy.MaxHP)

	local statusLabel = Instance.new("TextLabel")
	statusLabel.Size = UDim2.new(1, -20, 0, 24)
	statusLabel.Position = UDim2.new(0, 10, 0, 54)
	statusLabel.BackgroundTransparency = 1
	statusLabel.Text = string.format("🛡️ %d   🧪 %d   |   %s %s", enemy.Shield, enemy.Poison, enemy.IntentIcon, enemy.IntentText)
	statusLabel.TextColor3 = Color3.fromRGB(245, 225, 160)
	statusLabel.Font = Enum.Font.GothamMedium
	statusLabel.TextSize = 12
	statusLabel.TextXAlignment = Enum.TextXAlignment.Left
	statusLabel.Parent = card

	local clickBtn = Instance.new("TextButton")
	clickBtn.Size = UDim2.new(1, 0, 1, 0)
	clickBtn.BackgroundTransparency = 1
	clickBtn.Text = ""
	clickBtn.Parent = card
	clickBtn.MouseButton1Click:Connect(function()
		selectedEnemyId = enemy.InstanceId
		stroke.Color = Color3.fromRGB(255, 220, 60)
		stroke.Thickness = 3
	end)

	return card
end

-- Player HUD (Bottom Left)
local playerHudFrame = Instance.new("Frame")
playerHudFrame.Size = UDim2.new(0, 260, 0, 140)
playerHudFrame.Position = UDim2.new(0, 24, 1, -164)
playerHudFrame.BackgroundColor3 = Color3.fromRGB(22, 24, 30)
playerHudFrame.BackgroundTransparency = 0.15
playerHudFrame.BorderSizePixel = 0
playerHudFrame.Parent = combatHudView
UIFactory.createCorner(playerHudFrame, 12)
UIFactory.createStroke(playerHudFrame, Color3.fromRGB(45, 120, 220), 2)

local playerTitleLabel = Instance.new("TextLabel")
playerTitleLabel.Size = UDim2.new(1, -20, 0, 24)
playerTitleLabel.Position = UDim2.new(0, 12, 0, 8)
playerTitleLabel.BackgroundTransparency = 1
playerTitleLabel.Text = "🛡️ HERO (YOU)"
playerTitleLabel.TextColor3 = Color3.fromRGB(100, 180, 255)
playerTitleLabel.Font = Enum.Font.GothamBold
playerTitleLabel.TextSize = 15
playerTitleLabel.TextXAlignment = Enum.TextXAlignment.Left
playerTitleLabel.Parent = playerHudFrame

local playerHpContainer = Instance.new("Frame")
playerHpContainer.Size = UDim2.new(1, -24, 0, 22)
playerHpContainer.Position = UDim2.new(0, 12, 0, 36)
playerHpContainer.BackgroundTransparency = 1
playerHpContainer.Parent = playerHudFrame

local _, _, updatePlayerHpBar = UIFactory.createProgressBar(playerHpContainer, Color3.fromRGB(45, 195, 75))

local playerShieldLabel = Instance.new("TextLabel")
playerShieldLabel.Size = UDim2.new(0.5, 0, 0, 24)
playerShieldLabel.Position = UDim2.new(0, 12, 0, 64)
playerShieldLabel.BackgroundTransparency = 1
playerShieldLabel.Text = "🛡️ Shield: 0"
playerShieldLabel.TextColor3 = Color3.fromRGB(90, 180, 255)
playerShieldLabel.Font = Enum.Font.GothamBold
playerShieldLabel.TextSize = 14
playerShieldLabel.TextXAlignment = Enum.TextXAlignment.Left
playerShieldLabel.Parent = playerHudFrame

local playerEnergyLabel = Instance.new("TextLabel")
playerEnergyLabel.Size = UDim2.new(0.5, 0, 0, 24)
playerEnergyLabel.Position = UDim2.new(0.5, 0, 0, 64)
playerEnergyLabel.BackgroundTransparency = 1
playerEnergyLabel.Text = "⚡ 3 / 3 Energy"
playerEnergyLabel.TextColor3 = Color3.fromRGB(255, 215, 60)
playerEnergyLabel.Font = Enum.Font.GothamBold
playerEnergyLabel.TextSize = 14
playerEnergyLabel.TextXAlignment = Enum.TextXAlignment.Left
playerEnergyLabel.Parent = playerHudFrame

local deckStatsLabel = Instance.new("TextLabel")
deckStatsLabel.Size = UDim2.new(1, -24, 0, 22)
deckStatsLabel.Position = UDim2.new(0, 12, 0, 96)
deckStatsLabel.BackgroundTransparency = 1
deckStatsLabel.Text = "🃏 Deck: 4   |   🗑️ Discard: 0"
deckStatsLabel.TextColor3 = Color3.fromRGB(180, 185, 200)
deckStatsLabel.Font = Enum.Font.GothamMedium
deckStatsLabel.TextSize = 12
deckStatsLabel.TextXAlignment = Enum.TextXAlignment.Left
deckStatsLabel.Parent = playerHudFrame

-- Co-op Ready Button & Monotonic Timer (Bottom Right)
local controlContainer = Instance.new("Frame")
controlContainer.Size = UDim2.new(0, 200, 0, 100)
controlContainer.Position = UDim2.new(1, -224, 1, -120)
controlContainer.BackgroundTransparency = 1
controlContainer.Parent = combatHudView

local timerBadge = Instance.new("TextLabel")
timerBadge.Size = UDim2.new(1, 0, 0, 24)
timerBadge.BackgroundTransparency = 1
timerBadge.Text = string.format("⏰ Turn Timer: %ds", GameConfig.Combat.TurnDuration)
timerBadge.TextColor3 = Color3.fromRGB(255, 200, 80)
timerBadge.Font = Enum.Font.GothamBold
timerBadge.TextSize = 14
timerBadge.Parent = controlContainer

local readyBtn = Instance.new("TextButton")
readyBtn.Size = UDim2.new(1, 0, 0, 65)
readyBtn.Position = UDim2.new(0, 0, 0, 28)
readyBtn.BackgroundColor3 = Color3.fromRGB(210, 140, 30)
readyBtn.BorderSizePixel = 0
readyBtn.Text = "VOTE READY ➔"
readyBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
readyBtn.Font = Enum.Font.GothamBold
readyBtn.TextSize = 16
readyBtn.AutoButtonColor = true
readyBtn.Parent = controlContainer
UIFactory.createCorner(readyBtn, 12)
UIFactory.createStroke(readyBtn, Color3.fromRGB(255, 190, 60), 2)

readyBtn.MouseButton1Click:Connect(function()
	if PlayerVoteReadyEvent then
		PlayerVoteReadyEvent:FireServer()
	end
end)

-- Active Card Hand Container (Bottom Center)
local handContainer = Instance.new("Frame")
handContainer.Size = UDim2.new(0, 720, 0, 190)
handContainer.Position = UDim2.new(0.5, -360, 1, -205)
handContainer.BackgroundTransparency = 1
handContainer.Parent = combatHudView

local handLayout = Instance.new("UIListLayout")
handLayout.FillDirection = Enum.FillDirection.Horizontal
handLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
handLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
handLayout.Padding = UDim.new(0, 12)
handLayout.Parent = handContainer

-- Card Widget Creator (Uses CardView with CardInstanceId)
local function renderCardWidget(card: StateTypes.CardView): Frame
	local cardFrame = Instance.new("Frame")
	cardFrame.Name = "Card_" .. card.InstanceId
	cardFrame.Size = UDim2.new(0, 135, 0, 175)
	cardFrame.BackgroundColor3 = Color3.fromRGB(26, 28, 34)
	cardFrame.BorderSizePixel = 0
	UIFactory.createCorner(cardFrame, 10)

	local cardColor = card.Color or Color3.fromRGB(80, 120, 200)
	UIFactory.createStroke(cardFrame, cardColor, 2.5)

	local header = Instance.new("Frame")
	header.Size = UDim2.new(1, 0, 0, 30)
	header.BackgroundColor3 = cardColor
	header.BorderSizePixel = 0
	header.Parent = cardFrame
	UIFactory.createCorner(header, 10)

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.new(1, -30, 1, 0)
	nameLabel.Position = UDim2.new(0, 26, 0, 0)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = card.Name
	nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextSize = 12
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.Parent = header

	local costBadge = Instance.new("Frame")
	costBadge.Size = UDim2.new(0, 26, 0, 26)
	costBadge.Position = UDim2.new(0, -5, 0, -5)
	costBadge.BackgroundColor3 = Color3.fromRGB(20, 90, 190)
	costBadge.BorderSizePixel = 0
	costBadge.Parent = cardFrame
	UIFactory.createCorner(costBadge, 13)
	UIFactory.createStroke(costBadge, Color3.fromRGB(255, 220, 50), 2)

	local costText = Instance.new("TextLabel")
	costText.Size = UDim2.new(1, 0, 1, 0)
	costText.BackgroundTransparency = 1
	costText.Text = tostring(card.Cost)
	costText.TextColor3 = Color3.fromRGB(255, 255, 255)
	costText.Font = Enum.Font.GothamBold
	costText.TextSize = 14
	costText.Parent = costBadge

	local iconLabel = Instance.new("TextLabel")
	iconLabel.Size = UDim2.new(1, 0, 0, 45)
	iconLabel.Position = UDim2.new(0, 0, 0, 38)
	iconLabel.BackgroundTransparency = 1
	iconLabel.Text = card.Icon or "⚡"
	iconLabel.TextSize = 32
	iconLabel.Parent = cardFrame

	local descLabel = Instance.new("TextLabel")
	descLabel.Size = UDim2.new(1, -14, 0, 65)
	descLabel.Position = UDim2.new(0, 7, 0, 88)
	descLabel.BackgroundColor3 = Color3.fromRGB(18, 20, 24)
	descLabel.BorderSizePixel = 0
	descLabel.Text = card.Description or ""
	descLabel.TextColor3 = Color3.fromRGB(230, 235, 245)
	descLabel.Font = Enum.Font.GothamMedium
	descLabel.TextSize = 10
	descLabel.TextWrapped = true
	descLabel.Parent = cardFrame
	UIFactory.createCorner(descLabel, 6)

	local clickBtn = Instance.new("TextButton")
	clickBtn.Name = "ClickButton"
	clickBtn.Size = UDim2.new(1, 0, 1, 0)
	clickBtn.BackgroundTransparency = 1
	clickBtn.Text = ""
	clickBtn.Parent = cardFrame

	clickBtn.MouseEnter:Connect(function()
		TweenService:Create(cardFrame, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = UDim2.new(0, 0, 0, -20),
			BackgroundColor3 = Color3.fromRGB(38, 42, 52),
		}):Play()
	end)

	clickBtn.MouseLeave:Connect(function()
		TweenService:Create(cardFrame, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = UDim2.new(0, 0, 0, 0),
			BackgroundColor3 = Color3.fromRGB(26, 28, 34),
		}):Play()
	end)

	clickBtn.MouseButton1Click:Connect(function()
		if PlayCardEvent then
			local targetParam: any = nil
			if card.Target == "Enemy" then
				targetParam = selectedEnemyId
			elseif card.Target == "Ally" then
				targetParam = localPlayer.UserId
			elseif card.Target == "Self" or card.Target == "None" then
				targetParam = nil
			end
			PlayCardEvent:FireServer(card.InstanceId, targetParam)
		end
	end)

	return cardFrame
end

--------------------------------------------------------------------------------
-- VIEW 4: Rewards View (Card Draft & Gold)
--------------------------------------------------------------------------------

local rewardsView = Instance.new("Frame")
rewardsView.Name = "RewardsView"
rewardsView.Size = UDim2.new(0, 580, 0, 360)
rewardsView.Position = UDim2.new(0.5, -290, 0.5, -180)
rewardsView.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
rewardsView.BackgroundTransparency = 0.1
rewardsView.BorderSizePixel = 0
rewardsView.Visible = false
rewardsView.ZIndex = 20
rewardsView.Parent = mainFrame
UIFactory.createCorner(rewardsView, 14)
UIFactory.createStroke(rewardsView, Color3.fromRGB(255, 215, 60), 2.5)

local rewardsTitle = Instance.new("TextLabel")
rewardsTitle.Size = UDim2.new(1, 0, 0, 42)
rewardsTitle.Position = UDim2.new(0, 0, 0, 12)
rewardsTitle.BackgroundTransparency = 1
rewardsTitle.Text = "🎁 ROOM CLEARED: CLAIM REWARDS"
rewardsTitle.TextColor3 = Color3.fromRGB(255, 220, 80)
rewardsTitle.Font = Enum.Font.GothamBold
rewardsTitle.TextSize = 18
rewardsTitle.ZIndex = 21
rewardsTitle.Parent = rewardsView

local rewardsGoldText = Instance.new("TextLabel")
rewardsGoldText.Name = "RewardsGold"
rewardsGoldText.Size = UDim2.new(1, 0, 0, 26)
rewardsGoldText.Position = UDim2.new(0, 0, 0, 52)
rewardsGoldText.BackgroundTransparency = 1
rewardsGoldText.Text = "💰 Gold Earned: +25 Gold"
rewardsGoldText.TextColor3 = Color3.fromRGB(255, 230, 120)
rewardsGoldText.Font = Enum.Font.GothamMedium
rewardsGoldText.TextSize = 14
rewardsGoldText.ZIndex = 21
rewardsGoldText.Parent = rewardsView

local draftCardsContainer = Instance.new("Frame")
draftCardsContainer.Name = "DraftCards"
draftCardsContainer.Size = UDim2.new(1, -20, 0, 180)
draftCardsContainer.Position = UDim2.new(0, 10, 0, 88)
draftCardsContainer.BackgroundTransparency = 1
draftCardsContainer.ZIndex = 21
draftCardsContainer.Parent = rewardsView

local draftLayout = Instance.new("UIListLayout")
draftLayout.FillDirection = Enum.FillDirection.Horizontal
draftLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
draftLayout.Padding = UDim.new(0, 16)
draftLayout.Parent = draftCardsContainer

local continueBtnContainer = Instance.new("Frame")
continueBtnContainer.Size = UDim2.new(0, 180, 0, 45)
continueBtnContainer.Position = UDim2.new(0.5, -90, 1, -60)
continueBtnContainer.BackgroundTransparency = 1
continueBtnContainer.ZIndex = 21
continueBtnContainer.Parent = rewardsView

UIFactory.createButton(continueBtnContainer, "CONTINUE ➔", Color3.fromRGB(45, 175, 80), function()
	if ContinueFromRewardsEvent then
		ContinueFromRewardsEvent:FireServer()
	end
end)

local function buildCardDraftView(offeredCards: { StateTypes.CardView }, hasClaimed: boolean)
	for _, child in draftCardsContainer:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	for _, cardView in offeredCards do
		local cardFrame = renderCardWidget(cardView)
		cardFrame.ZIndex = 22

		local clickBtn = cardFrame:FindFirstChild("ClickButton") :: TextButton?
		if clickBtn then
			if hasClaimed then
				clickBtn.Active = false
				cardFrame.BackgroundTransparency = 0.5
			else
				clickBtn.MouseButton1Click:Connect(function()
					if ClaimRewardCardEvent then
						ClaimRewardCardEvent:FireServer(cardView.DefinitionId)
					end
				end)
			end
		end
		cardFrame.Parent = draftCardsContainer
	end
end

--------------------------------------------------------------------------------
-- Central View Switcher
--------------------------------------------------------------------------------

local function switchView(phase: StateTypes.RunPhase)
	lobbyView.Visible = (phase == "Lobby")
	mapView.Visible = (phase == "MapSelect")
	combatHudView.Visible = (phase == "ActiveRoom")
	rewardsView.Visible = (phase == "Rewards")
end

--------------------------------------------------------------------------------
-- Remote Event Listeners
--------------------------------------------------------------------------------

-- 1. Synchronized Run State Update
if RunStateUpdateEvent then
	RunStateUpdateEvent.OnClientEvent:Connect(function(snapshot: StateTypes.RunSnapshot)
		if not snapshot then return end

		switchView(snapshot.Phase)

		if snapshot.Phase == "Lobby" then
			bannerLabel.Text = "Lobby: Gather heroes and start run."
		elseif snapshot.Phase == "MapSelect" then
			bannerLabel.Text = "Map Selection: Select reachable room to proceed."
			buildDungeonMapTree(snapshot)
		elseif snapshot.Phase == "ActiveRoom" then
			bannerLabel.Text = string.format("Act %d: Tier %d Room", snapshot.ActIndex, snapshot.CurrentTier)
		elseif snapshot.Phase == "Rewards" then
			bannerLabel.Text = "Room Cleared! Draft 1 card reward."
			if snapshot.Rewards then
				rewardsGoldText.Text = string.format("💰 Gold: +%d  |  💎 Aether Shards: +%d", snapshot.Rewards.GoldAmount, snapshot.Rewards.AetherShardsAmount)
				buildCardDraftView(snapshot.Rewards.OfferedCards, snapshot.Rewards.HasClaimed)
			end
		elseif snapshot.Phase == "RunVictory" then
			bannerLabel.Text = "🏆 VICTORY! The Spire has fallen!"
			bannerLabel.TextColor3 = Color3.fromRGB(80, 255, 120)
		elseif snapshot.Phase == "RunDefeat" then
			bannerLabel.Text = "💀 DEFEAT! All party members have fallen."
			bannerLabel.TextColor3 = Color3.fromRGB(255, 60, 60)
		end

		if snapshot.Message and snapshot.Message ~= "" then
			bannerLabel.Text = snapshot.Message
		end
	end)
end

-- 2. Authoritative Combat Snapshot Update
if CombatStateUpdateEvent then
	CombatStateUpdateEvent.OnClientEvent:Connect(function(snapshot: StateTypes.CombatSnapshot)
		if not snapshot then return end

		-- Render Multi-Enemies
		for _, child in enemiesContainer:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end

		local defaultFirstEnemy: string? = nil
		for instId, enemyView in snapshot.Enemies do
			if not defaultFirstEnemy then defaultFirstEnemy = instId end
			local enemyWidget = renderEnemyCard(enemyView)
			enemyWidget.Parent = enemiesContainer
		end

		if not selectedEnemyId or not snapshot.Enemies[selectedEnemyId] then
			selectedEnemyId = defaultFirstEnemy
		end

		-- Monotonic Timer Update
		timerBadge.Text = string.format("⏰ Turn Timer: %ds", snapshot.TimeRemaining)
		if snapshot.TimeRemaining <= 10 then
			timerBadge.TextColor3 = Color3.fromRGB(255, 60, 60)
		else
			timerBadge.TextColor3 = Color3.fromRGB(255, 200, 80)
		end

		-- Local Player Stats
		local localUserId = tostring(localPlayer.UserId)
		local myView = snapshot.Party[localUserId]
		if myView then
			if myView.IsReady then
				readyBtn.Text = "✓ READY"
				readyBtn.BackgroundColor3 = Color3.fromRGB(45, 180, 80)
			else
				readyBtn.Text = "VOTE READY ➔"
				readyBtn.BackgroundColor3 = Color3.fromRGB(210, 140, 30)
			end

			updatePlayerHpBar(myView.HP, myView.MaxHP)
			playerShieldLabel.Text = string.format("🛡️ Shield: %d", myView.Shield)
			playerEnergyLabel.Text = string.format("⚡ %d / %d Energy", myView.Energy, myView.MaxEnergy)
			deckStatsLabel.Text = string.format("🃏 Deck: %d   |   🗑️ Discard: %d", myView.DeckCount, myView.DiscardCount)
		end

		-- Render Local Hand
		for _, child in handContainer:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end

		for _, cardView in snapshot.LocalHand do
			local cardWidget = renderCardWidget(cardView)
			cardWidget.Parent = handContainer
		end

		if snapshot.Message and snapshot.Message ~= "" then
			bannerLabel.Text = snapshot.Message
		end
	end)
end

-- 3. Announcements
if AnnouncementEvent then
	AnnouncementEvent.OnClientEvent:Connect(function(data: any)
		if not data then return end
		bannerLabel.Text = string.format("%s: %s", data.Title or "", data.Message or "")
		bannerLabel.TextColor3 = data.Color or Color3.fromRGB(255, 220, 80)
	end)
end

-- 4. Floating Action Numbers
if CombatEventLoggedEvent then
	CombatEventLoggedEvent.OnClientEvent:Connect(function(event: StateTypes.CombatEvent)
		if not event then return end

		local popup = Instance.new("TextLabel")
		popup.Size = UDim2.new(0, 180, 0, 32)
		popup.BackgroundTransparency = 1
		popup.Font = Enum.Font.GothamBold
		popup.TextSize = 20
		popup.Text = event.ExtraText or (event.Value and tostring(event.Value) or event.Type)
		popup.TextColor3 = (event.Type:find("Damage") or event.Type:find("Defeated")) and Color3.fromRGB(255, 70, 70) or Color3.fromRGB(80, 220, 120)
		popup.Position = UDim2.new(0.5, -90, 0.4, 0)
		popup.Parent = mainFrame

		local tween = TweenService:Create(popup, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = popup.Position + UDim2.new(0, 0, 0, -40),
			TextTransparency = 1,
		})
		tween:Play()
		tween.Completed:Connect(function()
			popup:Destroy()
		end)
	end)
end

-- Request initial state sync on mount
task.delay(0.5, function()
	if RequestStateSyncEvent then
		RequestStateSyncEvent:FireServer()
	end
end)

screenGui.Parent = playerGui
print("[UIController] Card Rift UIController mounted with GameNetwork architecture.")
