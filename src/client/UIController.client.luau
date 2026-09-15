--!strict

--[=[
	UIController LocalScript
	Mapped to: StarterPlayer.StarterPlayerScripts.Client.UIController
	Client-side UI controller for Card Rift: Co-op Dungeon:
	1. Remote Listeners: Syncs state changes (Lobby, MapSelect, ActiveRoom, Rewards) from GameCoordinator.
	2. Dungeon Map UI: Dynamically builds the visual node tree during MapSelect for voting and traveling.
	3. Combat HUD UI: Renders active card hand, player energy counters, shield/HP bars, and boss intent icons during ActiveRoom.
	4. Co-op Ready Button: Synchronized ready button that locks in turn choices with 45s timer display.
	5. Modular UI Frame creation functions for easy styling.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CardData = require(Shared:WaitForChild("CardData") :: ModuleScript)
local DungeonMap = require(Shared:WaitForChild("DungeonMap") :: ModuleScript)

--------------------------------------------------------------------------------
-- Remote Events Resolution
--------------------------------------------------------------------------------

local function findEvent(folderName: string, eventName: string): RemoteEvent?
	local folder = ReplicatedStorage:FindFirstChild(folderName)
	if folder then
		local ev = folder:FindFirstChild(eventName)
		if ev and ev:IsA("RemoteEvent") then
			return ev
		end
	end
	return nil
end

-- Game Flow Events
local StartRunEvent = findEvent("GameFlowEvents", "StartRun")
local VoteMapNodeEvent = findEvent("GameFlowEvents", "VoteMapNode")
local ClaimRewardCardEvent = findEvent("GameFlowEvents", "ClaimRewardCard")
local ContinueFromRewardsEvent = findEvent("GameFlowEvents", "ContinueFromRewards")
local CampfireChoiceEvent = findEvent("GameFlowEvents", "CampfireChoice")
local FlowStateUpdateEvent = findEvent("GameFlowEvents", "FlowStateUpdate")
local FlowAnnouncementEvent = findEvent("GameFlowEvents", "FlowAnnouncement")

-- Co-op Session Events
local PlayerVoteReadyEvent = findEvent("CoopEvents", "PlayerVoteReady")
local RescueTeammateEvent = findEvent("CoopEvents", "RescueTeammate")
local CoopStateUpdateEvent = findEvent("CoopEvents", "CoopStateUpdate")
local CoopAnnouncementEvent = findEvent("CoopEvents", "CoopAnnouncement")

-- Combat Core Events
local PlayCardEvent = findEvent("CombatEvents", "PlayCard")
local EndTurnEvent = findEvent("CombatEvents", "EndTurn")
local CombatActionEvent = findEvent("CombatEvents", "CombatAction")
local SelectMapNodeEvent = findEvent("CombatEvents", "SelectMapNode")

--------------------------------------------------------------------------------
-- Modular UI Component Factory (Easily Styled)
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
			Size = UDim2.new(ratio, 0, 1, 0)
		}):Play()
		label.Text = string.format("%d / %d HP", current, max)
	end

	return fill, label, update
end

--------------------------------------------------------------------------------
-- Build Main ScreenGui Root
--------------------------------------------------------------------------------

local existingGui = playerGui:FindFirstChild("CardRiftScreenGui")
if existingGui then
	existingGui:Destroy()
end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "CardRiftScreenGui"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

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

-- Builds the visual node tree during MapSelect
local function buildDungeonMapTree(payload: any)
	for _, child in mapScroll:GetChildren() do
		if child:IsA("Frame") or child:IsA("TextLabel") or child:IsA("TextButton") then
			child:Destroy()
		end
	end

	local runData = payload.Run or {}
	mapTitle.Text = string.format("🗺️ %s (Tier %d/10) - Select Next Room", runData.ActName or "Act 1", runData.CurrentTier or 0)

	local availableSet: { [string]: boolean } = {}
	if payload.AvailableNodes then
		for _, node in payload.AvailableNodes do
			availableSet[node.Id] = true
		end
	end

	-- Render 10 Tiers vertically: Tier 10 (Boss) at top, Tier 1 at bottom
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

		-- Populate nodes for this tier
		local tierNodes: { any } = {}
		if payload.AvailableNodes then
			for _, n in payload.AvailableNodes do
				if n.Tier == tierNum then
					table.insert(tierNodes, n)
				end
			end
		end

		for _, node in tierNodes do
			local meta = DungeonMap.getNodeMetadata(node.Type)
			local laneX = 85 + (node.Lane - 1) * 105

			local isAvailable = availableSet[node.Id] or false

			local nodeBtn = Instance.new("TextButton")
			nodeBtn.Name = "Node_" .. node.Id
			nodeBtn.Size = UDim2.new(0, 54, 0, 54)
			nodeBtn.Position = UDim2.new(0, laneX, 0, yPos)
			nodeBtn.BackgroundColor3 = meta.Color
			nodeBtn.BorderSizePixel = 0
			nodeBtn.Text = meta.Icon
			nodeBtn.TextSize = 24
			nodeBtn.ZIndex = 18
			nodeBtn.Parent = mapScroll
			UIFactory.createCorner(nodeBtn, 27)

			local stroke = UIFactory.createStroke(nodeBtn, Color3.fromRGB(255, 240, 100), 3)

			if isAvailable then
				nodeBtn.AutoButtonColor = true
				-- Highlight pulsing glow
				local pulse = TweenService:Create(stroke, TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
					Thickness = 4.5,
					Color = Color3.fromRGB(255, 255, 180),
				})
				pulse:Play()

				-- Click to vote or travel
				nodeBtn.MouseButton1Click:Connect(function()
					if VoteMapNodeEvent then
						VoteMapNodeEvent:FireServer(node.Id)
					elseif SelectMapNodeEvent then
						SelectMapNodeEvent:FireServer(node.Id)
					end
				end)
			else
				nodeBtn.AutoButtonColor = false
				stroke.Color = Color3.fromRGB(60, 65, 75)
				stroke.Thickness = 1.5
			end
		end
	end
end

--------------------------------------------------------------------------------
-- VIEW 3: Combat HUD View (ActiveRoom)
--------------------------------------------------------------------------------

local combatHudView = Instance.new("Frame")
combatHudView.Name = "CombatHUDView"
combatHudView.Size = UDim2.new(1, 0, 1, 0)
combatHudView.BackgroundTransparency = 1
combatHudView.Visible = false
combatHudView.Parent = mainFrame

-- Boss HUD (Top Center)
local combatBossHud = Instance.new("Frame")
combatBossHud.Size = UDim2.new(0, 440, 0, 88)
combatBossHud.Position = UDim2.new(0.5, -220, 0, 16)
combatBossHud.BackgroundColor3 = Color3.fromRGB(24, 24, 30)
combatBossHud.BackgroundTransparency = 0.15
combatBossHud.BorderSizePixel = 0
combatBossHud.Parent = combatHudView
UIFactory.createCorner(combatBossHud, 12)
UIFactory.createStroke(combatBossHud, Color3.fromRGB(180, 40, 40), 2)

local bossNameLabel = Instance.new("TextLabel")
bossNameLabel.Size = UDim2.new(1, 0, 0, 26)
bossNameLabel.Position = UDim2.new(0, 0, 0, 4)
bossNameLabel.BackgroundTransparency = 1
bossNameLabel.Text = "👹 THE SPIRE GUARDIAN"
bossNameLabel.TextColor3 = Color3.fromRGB(255, 90, 90)
bossNameLabel.Font = Enum.Font.GothamBold
bossNameLabel.TextSize = 16
bossNameLabel.Parent = combatBossHud

local bossHpContainer = Instance.new("Frame")
bossHpContainer.Size = UDim2.new(0.9, 0, 0, 20)
bossHpContainer.Position = UDim2.new(0.05, 0, 0, 32)
bossHpContainer.BackgroundTransparency = 1
bossHpContainer.Parent = combatBossHud

local _, _, updateBossHpBar = UIFactory.createProgressBar(bossHpContainer, Color3.fromRGB(220, 45, 45))

local bossIntentLabel = Instance.new("TextLabel")
bossIntentLabel.Size = UDim2.new(1, 0, 0, 22)
bossIntentLabel.Position = UDim2.new(0, 0, 0, 56)
bossIntentLabel.BackgroundTransparency = 1
bossIntentLabel.Text = "🛡️ Shield: 0   🧪 Poison: 0   |   ⚔️ Intent: Attack (12)"
bossIntentLabel.TextColor3 = Color3.fromRGB(245, 225, 160)
bossIntentLabel.Font = Enum.Font.GothamMedium
bossIntentLabel.TextSize = 13
bossIntentLabel.Parent = combatBossHud

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

-- Co-op Ready Button & 45s Timer Controls (Bottom Right)
local controlContainer = Instance.new("Frame")
controlContainer.Size = UDim2.new(0, 200, 0, 100)
controlContainer.Position = UDim2.new(1, -224, 1, -120)
controlContainer.BackgroundTransparency = 1
controlContainer.Parent = combatHudView

local timerBadge = Instance.new("TextLabel")
timerBadge.Size = UDim2.new(1, 0, 0, 24)
timerBadge.BackgroundTransparency = 1
timerBadge.Text = "⏰ Turn Timer: 45s"
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

local isLocallyReady = false
readyBtn.MouseButton1Click:Connect(function()
	if PlayerVoteReadyEvent then
		PlayerVoteReadyEvent:FireServer()
		isLocallyReady = not isLocallyReady
		if isLocallyReady then
			readyBtn.Text = "✓ READY"
			readyBtn.BackgroundColor3 = Color3.fromRGB(45, 180, 80)
		else
			readyBtn.Text = "VOTE READY ➔"
			readyBtn.BackgroundColor3 = Color3.fromRGB(210, 140, 30)
		end
	elseif EndTurnEvent then
		EndTurnEvent:FireServer()
	end
end)

-- Active Card Hand Container (Bottom Center)
local handContainer = Instance.new("Frame")
handContainer.Size = UDim2.new(0, 680, 0, 190)
handContainer.Position = UDim2.new(0.5, -340, 1, -205)
handContainer.BackgroundTransparency = 1
handContainer.Parent = combatHudView

local handLayout = Instance.new("UIListLayout")
handLayout.FillDirection = Enum.FillDirection.Horizontal
handLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
handLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
handLayout.Padding = UDim.new(0, 14)
handLayout.Parent = handContainer

-- Card Widget Creator
local function renderCardWidget(card: CardData.Card, handIndex: number): Frame
	local cardFrame = Instance.new("Frame")
	cardFrame.Name = "Card_" .. handIndex
	cardFrame.Size = UDim2.new(0, 145, 0, 180)
	cardFrame.BackgroundColor3 = Color3.fromRGB(26, 28, 34)
	cardFrame.BorderSizePixel = 0
	UIFactory.createCorner(cardFrame, 10)

	local cardColor = card.Color or Color3.fromRGB(80, 120, 200)
	UIFactory.createStroke(cardFrame, cardColor, 2.5)

	local header = Instance.new("Frame")
	header.Size = UDim2.new(1, 0, 0, 32)
	header.BackgroundColor3 = cardColor
	header.BorderSizePixel = 0
	header.Parent = cardFrame
	UIFactory.createCorner(header, 10)

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.new(1, -34, 1, 0)
	nameLabel.Position = UDim2.new(0, 30, 0, 0)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = card.Name
	nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextSize = 13
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.Parent = header

	local costBadge = Instance.new("Frame")
	costBadge.Size = UDim2.new(0, 28, 0, 28)
	costBadge.Position = UDim2.new(0, -6, 0, -6)
	costBadge.BackgroundColor3 = Color3.fromRGB(20, 90, 190)
	costBadge.BorderSizePixel = 0
	costBadge.Parent = cardFrame
	UIFactory.createCorner(costBadge, 14)
	UIFactory.createStroke(costBadge, Color3.fromRGB(255, 220, 50), 2)

	local costText = Instance.new("TextLabel")
	costText.Size = UDim2.new(1, 0, 1, 0)
	costText.BackgroundTransparency = 1
	costText.Text = tostring(card.Cost)
	costText.TextColor3 = Color3.fromRGB(255, 255, 255)
	costText.Font = Enum.Font.GothamBold
	costText.TextSize = 15
	costText.Parent = costBadge

	local iconLabel = Instance.new("TextLabel")
	iconLabel.Size = UDim2.new(1, 0, 0, 50)
	iconLabel.Position = UDim2.new(0, 0, 0, 42)
	iconLabel.BackgroundTransparency = 1
	iconLabel.Text = card.Icon or "⚡"
	iconLabel.TextSize = 36
	iconLabel.Parent = cardFrame

	local descLabel = Instance.new("TextLabel")
	descLabel.Size = UDim2.new(1, -16, 0, 70)
	descLabel.Position = UDim2.new(0, 8, 0, 96)
	descLabel.BackgroundColor3 = Color3.fromRGB(18, 20, 24)
	descLabel.BorderSizePixel = 0
	descLabel.Text = card.Description or ""
	descLabel.TextColor3 = Color3.fromRGB(230, 235, 245)
	descLabel.Font = Enum.Font.GothamMedium
	descLabel.TextSize = 11
	descLabel.TextWrapped = true
	descLabel.Parent = cardFrame
	UIFactory.createCorner(descLabel, 6)

	local clickBtn = Instance.new("TextButton")
	clickBtn.Size = UDim2.new(1, 0, 1, 0)
	clickBtn.BackgroundTransparency = 1
	clickBtn.Text = ""
	clickBtn.Parent = cardFrame

	clickBtn.MouseEnter:Connect(function()
		TweenService:Create(cardFrame, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = UDim2.new(0, 0, 0, -22),
			BackgroundColor3 = Color3.fromRGB(38, 42, 52),
		}):Play()
	end)

	clickBtn.MouseLeave:Connect(function()
		TweenService:Create(cardFrame, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = UDim2.new(0, 0, 0, 0),
			BackgroundColor3 = Color3.fromRGB(26, 28, 34),
		}):Play()
	end)

	clickBtn.MouseButton1Click:Connect(function()
		if PlayCardEvent then
			PlayCardEvent:FireServer(handIndex)
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
rewardsGoldText.Text = "💰 Gold Earned: +20 Gold"
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

local function buildCardDraftView(offeredCards: { CardData.Card })
	for _, child in draftCardsContainer:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	for index, card in offeredCards do
		local cardFrame = renderCardWidget(card, index)
		cardFrame.ZIndex = 22

		local clickBtn = cardFrame:FindFirstChild("ClickButton") :: TextButton?
		if clickBtn then
			clickBtn.MouseButton1Click:Connect(function()
				if ClaimRewardCardEvent then
					ClaimRewardCardEvent:FireServer(card.Id)
				end
			end)
		end
		cardFrame.Parent = draftCardsContainer
	end
end

--------------------------------------------------------------------------------
-- View Switcher: Central State Switcher
--------------------------------------------------------------------------------

local function switchView(phase: string)
	lobbyView.Visible = (phase == "Lobby")
	mapView.Visible = (phase == "MapSelect")
	combatHudView.Visible = (phase == "ActiveRoom")
	rewardsView.Visible = (phase == "Rewards")
end

--------------------------------------------------------------------------------
-- Remote Event Listeners
--------------------------------------------------------------------------------

-- 1. Game Flow Updates from GameCoordinator
if FlowStateUpdateEvent then
	FlowStateUpdateEvent.OnClientEvent:Connect(function(payload: any)
		if not payload then return end

		local phase = payload.Phase or "Lobby"
		switchView(phase)

		if phase == "Lobby" then
			bannerLabel.Text = "Lobby: Gather your party and hit Start Run."
		elseif phase == "MapSelect" then
			bannerLabel.Text = "Map Selection: Vote or click an available room."
			buildDungeonMapTree(payload)
		elseif phase == "ActiveRoom" then
			local active = payload.ActiveRoom
			if active then
				bossNameLabel.Text = "👹 " .. (active.EnemyName or "ENEMY")
				if active.EnemyHP and active.EnemyMaxHP then
					updateBossHpBar(active.EnemyHP, active.EnemyMaxHP)
				end
				bossIntentLabel.Text = string.format("⚔️ Intent: Attack (%d)", active.EnemyAttack or 10)
				bannerLabel.Text = string.format("Entered Room: %s (Tier %d)", active.Type, active.Tier)
			end
		elseif phase == "Rewards" then
			bannerLabel.Text = "Victory! Choose a card draft reward or continue."
			if payload.PendingRewards then
				rewardsGoldText.Text = string.format("💰 Gold Earned: +%d Gold", payload.PendingRewards.GoldAmount or 20)
			end

			local localData = payload.Players and payload.Players[tostring(localPlayer.UserId)]
			if localData and localData.OfferedCards then
				buildCardDraftView(localData.OfferedCards)
			end
		end

		if payload.Message and payload.Message ~= "" then
			bannerLabel.Text = payload.Message
		end
	end)
end

-- 2. Co-op Session Updates from SessionManager
if CoopStateUpdateEvent then
	CoopStateUpdateEvent.OnClientEvent:Connect(function(payload: any)
		if not payload then return end

		if payload.TurnTimer then
			timerBadge.Text = string.format("⏰ Turn Timer: %ds", payload.TurnTimer)
			if payload.TurnTimer <= 5 then
				timerBadge.TextColor3 = Color3.fromRGB(255, 60, 60)
			else
				timerBadge.TextColor3 = Color3.fromRGB(255, 200, 80)
			end
		end

		local localState = payload.Players and payload.Players[tostring(localPlayer.UserId)]
		if localState then
			isLocallyReady = localState.IsReady
			if isLocallyReady then
				readyBtn.Text = "✓ READY"
				readyBtn.BackgroundColor3 = Color3.fromRGB(45, 180, 80)
			else
				readyBtn.Text = "VOTE READY ➔"
				readyBtn.BackgroundColor3 = Color3.fromRGB(210, 140, 30)
			end

			updatePlayerHpBar(localState.HP, localState.MaxHP)
			playerShieldLabel.Text = string.format("🛡️ Shield: %d", localState.Shield)
			playerEnergyLabel.Text = string.format("⚡ %d / %d Energy", localState.Energy, localState.MaxEnergy)
			deckStatsLabel.Text = string.format("🃏 Deck: %d   |   🗑️ Discard: %d", localState.DeckCount, localState.DiscardCount)

			-- Re-render card hand
			for _, child in handContainer:GetChildren() do
				if child:IsA("Frame") then
					child:Destroy()
				end
			end

			if localState.Hand then
				for index, card in localState.Hand do
					local cardWidget = renderCardWidget(card, index)
					cardWidget.Parent = handContainer
				end
			end
		end

		local enemy = payload.Enemy
		if enemy then
			bossNameLabel.Text = "👹 " .. (enemy.Name or "BOSS")
			updateBossHpBar(enemy.HP, enemy.MaxHP)
			bossIntentLabel.Text = string.format("🛡️ Shield: %d   🧪 Poison: %d   |   ⚔️ Intent: %s (%d)", enemy.Shield, enemy.Poison, enemy.Intent or "Attack", enemy.AttackPower)
		end
	end)
end

-- 3. Flow Announcements
if FlowAnnouncementEvent then
	FlowAnnouncementEvent.OnClientEvent:Connect(function(announcement: any)
		if not announcement then return end
		bannerLabel.Text = string.format("%s: %s", announcement.Title or "", announcement.Message or "")
		bannerLabel.TextColor3 = announcement.Color or Color3.fromRGB(255, 220, 80)
	end)
end

-- 4. Floating Action Numbers
if CombatActionEvent then
	CombatActionEvent.OnClientEvent:Connect(function(action: any)
		if not action then return end

		local popup = Instance.new("TextLabel")
		popup.Size = UDim2.new(0, 160, 0, 32)
		popup.BackgroundTransparency = 1
		popup.Font = Enum.Font.GothamBold
		popup.TextSize = 22
		popup.Text = action.Text or ""
		popup.TextColor3 = (action.Type == "Damage") and Color3.fromRGB(255, 60, 60) or Color3.fromRGB(80, 220, 120)
		popup.Position = (action.Target == "Boss") and UDim2.new(0.5, -80, 0, 160) or UDim2.new(0, 60, 1, -190)
		popup.Parent = mainFrame

		local tween = TweenService:Create(popup, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = popup.Position + UDim2.new(0, 0, 0, -45),
			TextTransparency = 1,
		})
		tween:Play()
		tween.Completed:Connect(function()
			popup:Destroy()
		end)
	end)
end

screenGui.Parent = playerGui
print("[UIController] Card Rift UIController mounted successfully.")
