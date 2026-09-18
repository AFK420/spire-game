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
local UserInputService = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)
local DungeonMap = require(Shared:WaitForChild("DungeonMap") :: ModuleScript)
local GameConfig = require(Shared:WaitForChild("GameConfig") :: ModuleScript)
local BuildInfo = require(Shared:WaitForChild("BuildInfo") :: ModuleScript)

print(string.format("[BUILD] Client build=%s", BuildInfo.BUILD_ID))

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
local ReturnToLobbyEvent = getEvent("ReturnToLobby")
local SubmitCombatReactionEvent = getEvent("SubmitCombatReaction")
local InteractEventObjectEvent = getEvent("InteractEventObject")

-- Server -> Client State
local RunStateUpdateEvent = getEvent("RunStateUpdate")
local CombatStateUpdateEvent = getEvent("CombatStateUpdate")
local CombatEventLoggedEvent = getEvent("CombatEventLogged")
local AnnouncementEvent = getEvent("Announcement")
local ActionResultEvent = getEvent("ActionResult")

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

-- Map View State & Focus Tracking
local lastFocusedPhase: string? = nil
local lastFocusedTier: number? = nil
local lastFocusedNodeId: string? = nil
local lastRunStateRevision: number = -1
local isVotePending = false
local isRewardClaimPending = false
local pendingVoteNodeId: string? = nil
local activeNodeButtons: { [string]: TextButton } = {}

local function setMapButtonsEnabled(enabled: boolean)
	for _, btn in activeNodeButtons do
		if btn and btn.Parent then
			btn.Active = enabled
			btn.AutoButtonColor = enabled
			btn.BackgroundTransparency = enabled and 0 or 0.35
		end
	end
end
local mapSyncRequested = false
local lastMapSyncTime = 0

local firstRoomPromptLabel = Instance.new("TextLabel")
firstRoomPromptLabel.Name = "FirstRoomPromptLabel"
firstRoomPromptLabel.Size = UDim2.new(0, 320, 0, 36)
firstRoomPromptLabel.Position = UDim2.new(0.5, -160, 1, -48)
firstRoomPromptLabel.BackgroundColor3 = Color3.fromRGB(24, 28, 38)
firstRoomPromptLabel.BackgroundTransparency = 0.1
firstRoomPromptLabel.Text = "👉 CHOOSE YOUR FIRST ROOM"
firstRoomPromptLabel.TextColor3 = Color3.fromRGB(255, 220, 60)
firstRoomPromptLabel.Font = Enum.Font.GothamBold
firstRoomPromptLabel.TextSize = 15
firstRoomPromptLabel.Visible = false
firstRoomPromptLabel.ZIndex = 25
firstRoomPromptLabel.Parent = mapView
UIFactory.createCorner(firstRoomPromptLabel, 8)
UIFactory.createStroke(firstRoomPromptLabel, Color3.fromRGB(255, 200, 50), 1.5)

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

local function getNodeVisuals(nodeType: StateTypes.ActiveRoomType): (string, Color3)
	if nodeType == "Combat" then
		return "⚔️", Color3.fromRGB(195, 55, 55)
	elseif nodeType == "Elite Monster" then
		return "💀", Color3.fromRGB(220, 110, 30)
	elseif nodeType == "Campfire Rest" then
		return "🔥", Color3.fromRGB(45, 175, 95)
	elseif nodeType == "Merchant Shop" then
		return "💰", Color3.fromRGB(225, 195, 45)
	elseif nodeType == "Act Boss" then
		return "👹", Color3.fromRGB(175, 35, 195)
	elseif nodeType == "Event" then
		return "🔮", Color3.fromRGB(160, 70, 230)
	else
		return "❓", Color3.fromRGB(120, 120, 120)
	end
end

local function buildDungeonMapTree(snapshot: StateTypes.RunSnapshot)
	for _, child in mapScroll:GetChildren() do
		if child:IsA("Frame") or child:IsA("TextLabel") or child:IsA("TextButton") then
			child:Destroy()
		end
	end
	table.clear(activeNodeButtons)

	mapTitle.Text = string.format("🗺️ %s (Tier %d/10) - Select Next Room", snapshot.ActName or "Act 1", snapshot.CurrentTier or 0)

	-- Diagnostic when MapNodes or AvailableNodeIds is empty or unpopulated
	if not snapshot.MapNodes or #snapshot.MapNodes == 0 or not snapshot.AvailableNodeIds or #snapshot.AvailableNodeIds == 0 then
		local loadingLabel = Instance.new("TextLabel")
		loadingLabel.Name = "MapLoadingLabel"
		loadingLabel.Size = UDim2.new(1, 0, 0, 80)
		loadingLabel.Position = UDim2.new(0, 0, 0.4, 0)
		loadingLabel.BackgroundTransparency = 1
		loadingLabel.Font = Enum.Font.GothamBold
		loadingLabel.TextSize = 20
		loadingLabel.ZIndex = 18
		loadingLabel.Parent = mapScroll

		local now = os.clock()
		if not mapSyncRequested or (now - lastMapSyncTime > 5) then
			loadingLabel.Text = "Loading map..." -- MAP DATA LOADING... MAP LOADING...
			loadingLabel.TextColor3 = Color3.fromRGB(180, 190, 210)
			mapSyncRequested = true
			lastMapSyncTime = now
			if RequestStateSyncEvent then
				RequestStateSyncEvent:FireServer()
			end
		else
			loadingLabel.Text = "MAP DATA ERROR: Map nodes unavailable. Please re-sync."
			loadingLabel.TextColor3 = Color3.fromRGB(255, 80, 80)
		end
		firstRoomPromptLabel.Visible = false
		return
	else
		mapSyncRequested = false
	end

	local tierHeight = 74

	-- Render vertical tier indicators
	for tierNum = 10, 1, -1 do
		local yPos = (10 - tierNum) * tierHeight + 12

		local tierLabel = Instance.new("TextLabel")
		tierLabel.Name = "TierLabel_" .. tierNum
		tierLabel.Size = UDim2.new(0, 48, 0, 48)
		tierLabel.Position = UDim2.new(0, 8, 0, yPos)
		tierLabel.BackgroundTransparency = 1
		tierLabel.Text = string.format("T%02d", tierNum)
		tierLabel.TextColor3 = Color3.fromRGB(110, 125, 145)
		tierLabel.Font = Enum.Font.GothamBold
		tierLabel.TextSize = 13
		tierLabel.ZIndex = 17
		tierLabel.Parent = mapScroll
	end

	-- Render authoritative MapNodes graph from server snapshot
	for _, node in snapshot.MapNodes do
		local yPos = (10 - node.Tier) * tierHeight + 12
		local laneX = 70 + (node.Lane - 1) * 110
		local icon, baseColor = getNodeVisuals(node.Type)

		local nodeBtn = Instance.new("TextButton")
		nodeBtn.Name = "Node_" .. node.Id
		nodeBtn.Size = UDim2.new(0, 52, 0, 52)
		nodeBtn.Position = UDim2.new(0, laneX, 0, yPos)
		nodeBtn.BackgroundColor3 = baseColor
		nodeBtn.BorderSizePixel = 0
		nodeBtn.Text = icon
		nodeBtn.TextSize = 22
		nodeBtn.ZIndex = 18
		nodeBtn.Parent = mapScroll
		UIFactory.createCorner(nodeBtn, 26)

		local stroke = UIFactory.createStroke(nodeBtn, Color3.fromRGB(60, 65, 80), 1)

		if node.IsCurrent then
			stroke.Color = Color3.fromRGB(80, 220, 255)
			stroke.Thickness = 3
			nodeBtn.BackgroundTransparency = 0
			nodeBtn.AutoButtonColor = false
		elseif node.IsCleared then
			stroke.Color = Color3.fromRGB(50, 55, 65)
			stroke.Thickness = 1
			nodeBtn.BackgroundTransparency = 0.6
			nodeBtn.Text = "✓"
			nodeBtn.TextColor3 = Color3.fromRGB(180, 180, 180)
			nodeBtn.TextSize = 16
			nodeBtn.AutoButtonColor = false
		elseif node.IsAvailable then
			stroke.Color = Color3.fromRGB(255, 220, 60)
			stroke.Thickness = 3
			nodeBtn.BackgroundTransparency = (isVotePending and 0.35) or 0
			nodeBtn.Active = not isVotePending
			nodeBtn.AutoButtonColor = not isVotePending
			activeNodeButtons[node.Id] = nodeBtn

			local targetId = node.Id
			nodeBtn.MouseButton1Click:Connect(function()
				if isVotePending or pendingVoteNodeId ~= nil then return end
				print(string.format("[MAPFLOW][CLIENT][1] Node button clicked: Node=%s", targetId))
				isVotePending = true
				pendingVoteNodeId = targetId
				setMapButtonsEnabled(false)
				firstRoomPromptLabel.Visible = false
				bannerLabel.Text = "Submitting room vote..."
				bannerLabel.TextColor3 = Color3.fromRGB(255, 220, 80)
				if VoteMapNodeEvent then
					print(string.format("[MAPFLOW][CLIENT][2] Vote fired to server: Node=%s", targetId))
					VoteMapNodeEvent:FireServer(targetId)
				end

				-- 8-second timeout guard: recover cleanly if network packet drops
				task.delay(8.0, function()
					if isVotePending and pendingVoteNodeId == targetId and mapView.Visible then
						warn(string.format("[MAPFLOW][CLIENT] Vote for node %s timed out after 8s; requesting state sync.", targetId))
						isVotePending = false
						pendingVoteNodeId = nil
						setMapButtonsEnabled(true)
						bannerLabel.Text = "⚠️ Room transition timed out. Refreshing state..."
						bannerLabel.TextColor3 = Color3.fromRGB(255, 180, 60)
						if RequestStateSyncEvent then
							RequestStateSyncEvent:FireServer()
						end
					end
				end)
			end)
		else
			stroke.Color = Color3.fromRGB(45, 50, 60)
			stroke.Thickness = 1
			nodeBtn.BackgroundTransparency = 0.5
			nodeBtn.AutoButtonColor = false
		end
	end

	-- Auto-focus / scroll to lowest available/reachable tier on fresh run or room transition
	local lowestAvailableTier: number? = nil
	for _, node in snapshot.MapNodes do
		if node.IsAvailable then
			if lowestAvailableTier == nil or node.Tier < lowestAvailableTier then
				lowestAvailableTier = node.Tier
			end
		end
	end
	local targetTier = lowestAvailableTier or (snapshot.CurrentTier and (snapshot.CurrentTier + 1)) or 1

	local isFreshRun = (snapshot.CurrentNodeId == nil and (snapshot.CurrentTier == nil or snapshot.CurrentTier == 0))
	if isFreshRun and not isVotePending then
		firstRoomPromptLabel.Visible = true
	else
		firstRoomPromptLabel.Visible = false
	end

	local shouldAutoFocus = (lastFocusedPhase ~= "MapSelect")
		or (lastFocusedTier ~= snapshot.CurrentTier)
		or (lastFocusedNodeId ~= snapshot.CurrentNodeId)

	if shouldAutoFocus then
		lastFocusedPhase = "MapSelect"
		lastFocusedTier = snapshot.CurrentTier
		lastFocusedNodeId = snapshot.CurrentNodeId

		local targetYPos = (10 - targetTier) * tierHeight + 12
		local function applyScroll()
			local viewHeight = mapScroll.AbsoluteWindowSize.Y
			if viewHeight <= 0 then
				viewHeight = mapScroll.AbsoluteSize.Y
			end
			if viewHeight <= 0 then
				viewHeight = 400
			end
			local targetCanvasY = math.clamp(targetYPos - (viewHeight / 2) + 26, 0, math.max(0, 800 - viewHeight))
			mapScroll.CanvasPosition = Vector2.new(0, targetCanvasY)
		end
		applyScroll()
		task.defer(applyScroll)
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
local currentCombatPhase: string = "PlayerPhase"
local isPlayCardPending: boolean = false
local isReadyVotePending: boolean = false

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
	if currentCombatPhase ~= "PlayerPhase" then return end
	if isReadyVotePending then return end
	isReadyVotePending = true
	task.delay(2.0, function()
		isReadyVotePending = false
	end)
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

-- Environmental State Badge (Top Right)
local environmentBadge = Instance.new("Frame")
environmentBadge.Name = "EnvironmentBadge"
environmentBadge.Size = UDim2.new(0, 220, 0, 36)
environmentBadge.Position = UDim2.new(1, -240, 0, 14)
environmentBadge.BackgroundColor3 = Color3.fromRGB(24, 26, 36)
environmentBadge.BackgroundTransparency = 0.2
environmentBadge.Visible = false
environmentBadge.Parent = combatHudView
UIFactory.createCorner(environmentBadge, 8)
UIFactory.createStroke(environmentBadge, Color3.fromRGB(100, 130, 200), 1)

local environmentLabel = Instance.new("TextLabel")
environmentLabel.Size = UDim2.new(1, -16, 1, 0)
environmentLabel.Position = UDim2.new(0, 8, 0, 0)
environmentLabel.BackgroundTransparency = 1
environmentLabel.Text = "🌐 Neutral Arena"
environmentLabel.TextColor3 = Color3.fromRGB(220, 230, 255)
environmentLabel.Font = Enum.Font.GothamBold
environmentLabel.TextSize = 13
environmentLabel.TextXAlignment = Enum.TextXAlignment.Center
environmentLabel.Parent = environmentBadge

-- Combat Reaction 3D Attack Presentation & Unobtrusive HUD
local activeReactionWindowId: string? = nil
local currentReactionWindowView: StateTypes.ReactionWindowView? = nil

-- Small, unobtrusive reaction prompt bar positioned above hand
local reactionWidget = Instance.new("Frame")
reactionWidget.Name = "ReactionWidget"
reactionWidget.Size = UDim2.new(0, 310, 0, 78)
reactionWidget.Position = UDim2.new(0.5, -155, 0.72, 0)
reactionWidget.BackgroundColor3 = Color3.fromRGB(18, 20, 28)
reactionWidget.BackgroundTransparency = 0.25
reactionWidget.BorderSizePixel = 0
reactionWidget.Visible = false
reactionWidget.ZIndex = 50
reactionWidget.Parent = combatHudView
UIFactory.createCorner(reactionWidget, 8)
UIFactory.createStroke(reactionWidget, Color3.fromRGB(70, 90, 130), 1.5)
local reactionPromptFrame = reactionWidget -- Backward-compatible reference

-- Attack description label inside prompt bar
local reactionAttackLabel = Instance.new("TextLabel")
reactionAttackLabel.Name = "ReactionAttackLabel"
reactionAttackLabel.Size = UDim2.new(1, -16, 0, 22)
reactionAttackLabel.Position = UDim2.new(0, 8, 0, 6)
reactionAttackLabel.BackgroundTransparency = 1
reactionAttackLabel.Text = "⚔️ Incoming Hostile Strike"
reactionAttackLabel.TextColor3 = Color3.fromRGB(255, 230, 170)
reactionAttackLabel.Font = Enum.Font.GothamBold
reactionAttackLabel.TextSize = 13
reactionAttackLabel.TextXAlignment = Enum.TextXAlignment.Center
reactionAttackLabel.ZIndex = 52
reactionAttackLabel.Parent = reactionWidget
local reactionDetail = reactionAttackLabel -- Backward-compatible reference

-- Keybind badges container
local reactionButtonsContainer = Instance.new("Frame")
reactionButtonsContainer.Name = "ReactionButtonsContainer"
reactionButtonsContainer.Size = UDim2.new(1, -16, 0, 38)
reactionButtonsContainer.Position = UDim2.new(0, 8, 0, 32)
reactionButtonsContainer.BackgroundTransparency = 1
reactionButtonsContainer.ZIndex = 52
reactionButtonsContainer.Parent = reactionWidget

local reactionButtonsLayout = Instance.new("UIListLayout")
reactionButtonsLayout.FillDirection = Enum.FillDirection.Horizontal
reactionButtonsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
reactionButtonsLayout.Padding = UDim.new(0, 12)
reactionButtonsLayout.Parent = reactionButtonsContainer

local dodgeBtnFrame = Instance.new("Frame")
dodgeBtnFrame.Name = "DodgeBtnFrame"
dodgeBtnFrame.Size = UDim2.new(0, 134, 0, 34)
dodgeBtnFrame.BackgroundTransparency = 1
dodgeBtnFrame.ZIndex = 53
dodgeBtnFrame.Parent = reactionButtonsContainer

local dodgeBtn = UIFactory.createButton(dodgeBtnFrame, "💨 [C] DODGE", Color3.fromRGB(35, 150, 75), function()
	submitReactionAttempt("Dodge")
end)
dodgeBtn.ZIndex = 54

local parryBtnFrame = Instance.new("Frame")
parryBtnFrame.Name = "ParryBtnFrame"
parryBtnFrame.Size = UDim2.new(0, 134, 0, 34)
parryBtnFrame.BackgroundTransparency = 1
parryBtnFrame.ZIndex = 53
parryBtnFrame.Parent = reactionButtonsContainer

local parryBtn = UIFactory.createButton(parryBtnFrame, "⚔️ [V] PARRY", Color3.fromRGB(140, 55, 200), function()
	submitReactionAttempt("Parry")
end)
parryBtn.ZIndex = 54

-- Center Floating Judgement feedback banner (Fades out quickly)
local reactionJudgementLabel = Instance.new("TextLabel")
reactionJudgementLabel.Name = "ReactionJudgementLabel"
reactionJudgementLabel.Size = UDim2.new(0, 340, 0, 44)
reactionJudgementLabel.Position = UDim2.new(0.5, -170, 0.44, -22)
reactionJudgementLabel.BackgroundTransparency = 1
reactionJudgementLabel.Text = ""
reactionJudgementLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
reactionJudgementLabel.Font = Enum.Font.GothamBlack
reactionJudgementLabel.TextSize = 24
reactionJudgementLabel.ZIndex = 60
reactionJudgementLabel.Visible = false
reactionJudgementLabel.Parent = combatHudView

local function showJudgementFeedback(text: string, color: Color3)
	reactionJudgementLabel.Text = text
	reactionJudgementLabel.TextColor3 = color
	reactionJudgementLabel.Visible = true
	reactionJudgementLabel.TextTransparency = 0
	reactionJudgementLabel.TextSize = 24

	task.delay(0.85, function()
		if reactionJudgementLabel.Text == text then
			local tween = TweenService:Create(reactionJudgementLabel, TweenInfo.new(0.2), { TextTransparency = 1 })
			tween:Play()
			tween.Completed:Connect(function()
				if reactionJudgementLabel.Text == text then
					reactionJudgementLabel.Visible = false
				end
			end)
		end
	end)
end

function submitReactionAttempt(reactionType: "Dodge" | "Parry")
	if not activeReactionWindowId or not currentReactionWindowView then return end

	if reactionType == "Dodge" and not currentReactionWindowView.CanDodge then return end
	if reactionType == "Parry" and not currentReactionWindowView.CanParry then return end

	local winId = activeReactionWindowId
	local winView = currentReactionWindowView
	activeReactionWindowId = nil -- Prevent multiple local submissions
	reactionWidget.Visible = false -- Dismiss prompt bar immediately on reaction

	-- Synchronized server-time evaluation for client prediction feedback
	local clientServerTimestamp = Workspace:GetServerTimeNow()
	local impactTime = winView.ImpactServerTime or winView.ImpactTime
	local timeDelta = clientServerTimestamp - impactTime
	local absDelta = math.abs(timeDelta)

	if reactionType == "Dodge" then
		if absDelta <= (winView.DodgePerfectTolerance or 0.15) then
			showJudgementFeedback("PERFECT DODGE!", Color3.fromRGB(80, 240, 255))
			bannerLabel.Text = "⚡ PERFECT DODGE!"
			bannerLabel.TextColor3 = Color3.fromRGB(80, 240, 255)
		elseif absDelta <= (winView.DodgeGoodTolerance or 0.35) then
			showJudgementFeedback("GOOD DODGE", Color3.fromRGB(80, 220, 120))
			bannerLabel.Text = "💨 GOOD DODGE!"
			bannerLabel.TextColor3 = Color3.fromRGB(80, 220, 120)
		elseif timeDelta < -(winView.DodgeGoodTolerance or 0.35) then
			showJudgementFeedback("EARLY", Color3.fromRGB(255, 160, 50))
			bannerLabel.Text = "⚠️ Dodged Too Early!"
			bannerLabel.TextColor3 = Color3.fromRGB(255, 160, 50)
		else
			showJudgementFeedback("LATE", Color3.fromRGB(255, 90, 90))
			bannerLabel.Text = "⚠️ Dodged Too Late!"
			bannerLabel.TextColor3 = Color3.fromRGB(255, 90, 90)
		end
	elseif reactionType == "Parry" then
		if absDelta <= (winView.ParryPerfectTolerance or 0.08) then
			showJudgementFeedback("PERFECT PARRY!", Color3.fromRGB(255, 215, 60))
			bannerLabel.Text = "🛡️ PERFECT PARRY!"
			bannerLabel.TextColor3 = Color3.fromRGB(255, 215, 60)
		elseif absDelta <= (winView.ParryGoodTolerance or 0.18) then
			showJudgementFeedback("GOOD PARRY", Color3.fromRGB(190, 100, 255))
			bannerLabel.Text = "⚔️ GOOD PARRY!"
			bannerLabel.TextColor3 = Color3.fromRGB(190, 100, 255)
		elseif timeDelta < -(winView.ParryGoodTolerance or 0.18) then
			showJudgementFeedback("EARLY", Color3.fromRGB(255, 160, 50))
			bannerLabel.Text = "⚠️ Parried Too Early!"
			bannerLabel.TextColor3 = Color3.fromRGB(255, 160, 50)
		else
			showJudgementFeedback("LATE", Color3.fromRGB(255, 90, 90))
			bannerLabel.Text = "⚠️ Parried Too Late!"
			bannerLabel.TextColor3 = Color3.fromRGB(255, 90, 90)
		end
	end

	if SubmitCombatReactionEvent then
		SubmitCombatReactionEvent:FireServer(winId, reactionType, clientServerTimestamp)
	end
end

local function startReactionOpportunity(win: StateTypes.ReactionWindowView)
	-- Reaction prompt and C/V inputs are strictly reserved for targeted recipients
	local isTargeted = false
	if win.TargetUserIds then
		for _, uid in win.TargetUserIds do
			if uid == localPlayer.UserId then
				isTargeted = true
				break
			end
		end
	end

	if not isTargeted then
		reactionWidget.Visible = false
		return
	end

	reactionWidget.Visible = true

	if not win.CanDodge and not win.CanParry then
		reactionAttackLabel.Text = string.format("⚠️ %s: %s (UNREACTABLE)", win.EnemyName, win.AttackName)
		dodgeBtnFrame.Visible = false
		parryBtnFrame.Visible = false
	else
		local permText = if (win.CanDodge and win.CanParry) then ""
			elseif win.CanDodge then " [Unparryable]"
			else " [Undodgeable]"
		reactionAttackLabel.Text = string.format("⚔️ %s: %s (%d %s)%s", win.EnemyName, win.AttackName, win.RawDamage, win.DamageType, permText)
		dodgeBtnFrame.Visible = win.CanDodge
		parryBtnFrame.Visible = win.CanParry
	end

	-- Automatic timeout handler if player does not submit
	local closeTime = win.ReactionCloseServerTime or win.CloseTime
	local now = Workspace:GetServerTimeNow()
	local waitDuration = math.max(0.1, closeTime - now)

	task.delay(waitDuration, function()
		if activeReactionWindowId == win.WindowId then
			activeReactionWindowId = nil
			currentReactionWindowView = nil
			reactionWidget.Visible = false
			showJudgementFeedback("MISS", Color3.fromRGB(255, 60, 60))
			bannerLabel.Text = "💀 Reaction Missed!"
			bannerLabel.TextColor3 = Color3.fromRGB(255, 60, 60)
		end
	end)
end

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then return end
	if not activeReactionWindowId or not reactionWidget.Visible then return end

	-- STRICT PROTOCOL: C = Dodge, V = Parry only. Space and Shift are explicitly NOT bound.
	if input.KeyCode == Enum.KeyCode.C then
		if dodgeBtnFrame.Visible then
			submitReactionAttempt("Dodge")
		end
	elseif input.KeyCode == Enum.KeyCode.V then
		if parryBtnFrame.Visible then
			submitReactionAttempt("Parry")
		end
	end
end)

-- Card Widget Creator (Uses CardView with CardInstanceId)
local function renderCardWidget(card: StateTypes.CardView, customClickHandler: (() -> ())?): Frame
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

	if customClickHandler then
		clickBtn.MouseButton1Click:Connect(customClickHandler)
	else
		clickBtn.MouseButton1Click:Connect(function()
			if currentCombatPhase ~= "PlayerPhase" then
				bannerLabel.Text = "⏳ Please wait: Enemies are taking their turn..."
				bannerLabel.TextColor3 = Color3.fromRGB(255, 200, 80)
				return
			end
			if isPlayCardPending then return end
			isPlayCardPending = true
			task.delay(2.0, function()
				isPlayCardPending = false
			end)
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
	end

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
	print("[REWARDFLOW][CLIENT][2] Continue button clicked")
	bannerLabel.Text = "Submitting continue request..."
	bannerLabel.TextColor3 = Color3.fromRGB(255, 220, 80)
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
		local cardFrame = renderCardWidget(cardView, function()
			if isRewardClaimPending or hasClaimed then return end
			isRewardClaimPending = true
			print(string.format("[REWARDFLOW][CLIENT][1] Card reward clicked: %s (%s)", cardView.Name, cardView.DefinitionId))
			bannerLabel.Text = string.format("Drafting [%s]...", cardView.Name)
			bannerLabel.TextColor3 = Color3.fromRGB(255, 220, 80)
			if ClaimRewardCardEvent then
				ClaimRewardCardEvent:FireServer(cardView.DefinitionId)
			end
		end)
		cardFrame.ZIndex = 22

		local clickBtn = cardFrame:FindFirstChild("ClickButton") :: TextButton?
		if clickBtn then
			if hasClaimed then
				clickBtn.Active = false
				clickBtn.AutoButtonColor = false
				cardFrame.BackgroundTransparency = 0.5
			end
		end
		cardFrame.Parent = draftCardsContainer
	end
end

--------------------------------------------------------------------------------
-- VIEW 5: Victory View (Phase 13)
--------------------------------------------------------------------------------

local victoryView = Instance.new("Frame")
victoryView.Name = "VictoryView"
victoryView.Size = UDim2.new(0, 520, 0, 360)
victoryView.Position = UDim2.new(0.5, -260, 0.5, -180)
victoryView.BackgroundColor3 = Color3.fromRGB(18, 24, 22)
victoryView.BackgroundTransparency = 0.08
victoryView.BorderSizePixel = 0
victoryView.Visible = false
victoryView.ZIndex = 25
victoryView.Parent = mainFrame
UIFactory.createCorner(victoryView, 14)
UIFactory.createStroke(victoryView, Color3.fromRGB(80, 255, 140), 2.5)

local victoryTitle = Instance.new("TextLabel")
victoryTitle.Size = UDim2.new(1, 0, 0, 50)
victoryTitle.Position = UDim2.new(0, 0, 0, 20)
victoryTitle.BackgroundTransparency = 1
victoryTitle.Text = "🏆 VICTORY ACHIEVED!"
victoryTitle.TextColor3 = Color3.fromRGB(100, 255, 150)
victoryTitle.Font = Enum.Font.GothamBold
victoryTitle.TextSize = 24
victoryTitle.ZIndex = 26
victoryTitle.Parent = victoryView

local victoryDesc = Instance.new("TextLabel")
victoryDesc.Size = UDim2.new(1, -40, 0, 80)
victoryDesc.Position = UDim2.new(0, 20, 0, 80)
victoryDesc.BackgroundTransparency = 1
victoryDesc.Text = "The Heart of the Spire has fallen!\nYour expedition was completely triumphant.\nAll earned Aether Shards and rewards have been saved to your account."
victoryDesc.TextColor3 = Color3.fromRGB(200, 240, 210)
victoryDesc.Font = Enum.Font.GothamMedium
victoryDesc.TextSize = 14
victoryDesc.TextWrapped = true
victoryDesc.ZIndex = 26
victoryDesc.Parent = victoryView

local returnLobbyBtnContainer = Instance.new("Frame")
returnLobbyBtnContainer.Size = UDim2.new(0, 240, 0, 52)
returnLobbyBtnContainer.Position = UDim2.new(0.5, -120, 1, -80)
returnLobbyBtnContainer.BackgroundTransparency = 1
returnLobbyBtnContainer.ZIndex = 26
returnLobbyBtnContainer.Parent = victoryView

UIFactory.createButton(returnLobbyBtnContainer, "RETURN TO LOBBY ➔", Color3.fromRGB(45, 180, 90), function()
	if ReturnToLobbyEvent then
		ReturnToLobbyEvent:FireServer()
	elseif RequestStateSyncEvent then
		RequestStateSyncEvent:FireServer()
	end
end)

--------------------------------------------------------------------------------
-- VIEW 6: Defeat View (Phase 13)
--------------------------------------------------------------------------------

local defeatView = Instance.new("Frame")
defeatView.Name = "DefeatView"
defeatView.Size = UDim2.new(0, 520, 0, 360)
defeatView.Position = UDim2.new(0.5, -260, 0.5, -180)
defeatView.BackgroundColor3 = Color3.fromRGB(26, 18, 18)
defeatView.BackgroundTransparency = 0.08
defeatView.BorderSizePixel = 0
defeatView.Visible = false
defeatView.ZIndex = 25
defeatView.Parent = mainFrame
UIFactory.createCorner(defeatView, 14)
UIFactory.createStroke(defeatView, Color3.fromRGB(255, 60, 60), 2.5)

local defeatTitle = Instance.new("TextLabel")
defeatTitle.Size = UDim2.new(1, 0, 0, 50)
defeatTitle.Position = UDim2.new(0, 0, 0, 20)
defeatTitle.BackgroundTransparency = 1
defeatTitle.Text = "💀 EXPEDITION FAILED"
defeatTitle.TextColor3 = Color3.fromRGB(255, 70, 70)
defeatTitle.Font = Enum.Font.GothamBold
defeatTitle.TextSize = 24
defeatTitle.ZIndex = 26
defeatTitle.Parent = defeatView

local defeatDesc = Instance.new("TextLabel")
defeatDesc.Size = UDim2.new(1, -40, 0, 80)
defeatDesc.Position = UDim2.new(0, 20, 0, 80)
defeatDesc.BackgroundTransparency = 1
defeatDesc.Text = "Your party was overwhelmed by the rift creatures.\nReturn to the camp, adjust your party strategy, and embark once more."
defeatDesc.TextColor3 = Color3.fromRGB(240, 200, 200)
defeatDesc.Font = Enum.Font.GothamMedium
defeatDesc.TextSize = 14
defeatDesc.TextWrapped = true
defeatDesc.ZIndex = 26
defeatDesc.Parent = defeatView

local defeatLobbyBtnContainer = Instance.new("Frame")
defeatLobbyBtnContainer.Size = UDim2.new(0, 240, 0, 52)
defeatLobbyBtnContainer.Position = UDim2.new(0.5, -120, 1, -80)
defeatLobbyBtnContainer.BackgroundTransparency = 1
defeatLobbyBtnContainer.ZIndex = 26
defeatLobbyBtnContainer.Parent = defeatView

UIFactory.createButton(defeatLobbyBtnContainer, "RETURN TO LOBBY ➔", Color3.fromRGB(200, 50, 50), function()
	if ReturnToLobbyEvent then
		ReturnToLobbyEvent:FireServer()
	elseif RequestStateSyncEvent then
		RequestStateSyncEvent:FireServer()
	end
end)

--------------------------------------------------------------------------------
-- VIEW 6: 3D Event Chamber HUD (Puzzles & Riddles)
--------------------------------------------------------------------------------

local eventChamberView = Instance.new("Frame")
eventChamberView.Name = "EventChamberView"
eventChamberView.Size = UDim2.new(0, 640, 0, 480)
eventChamberView.Position = UDim2.new(0.5, -320, 0.5, -240)
eventChamberView.BackgroundColor3 = Color3.fromRGB(22, 20, 32)
eventChamberView.BackgroundTransparency = 0.1
eventChamberView.BorderSizePixel = 0
eventChamberView.Visible = false
eventChamberView.ZIndex = 15
eventChamberView.Parent = mainFrame
UIFactory.createCorner(eventChamberView, 14)
UIFactory.createStroke(eventChamberView, Color3.fromRGB(140, 70, 220), 2.5)

local eventHeader = Instance.new("Frame")
eventHeader.Size = UDim2.new(1, 0, 0, 60)
eventHeader.BackgroundColor3 = Color3.fromRGB(30, 26, 46)
eventHeader.BorderSizePixel = 0
eventHeader.ZIndex = 16
eventHeader.Parent = eventChamberView
UIFactory.createCorner(eventHeader, 14)

local eventTitle = Instance.new("TextLabel")
eventTitle.Size = UDim2.new(1, -90, 0, 30)
eventTitle.Position = UDim2.new(0, 20, 0, 6)
eventTitle.BackgroundTransparency = 1
eventTitle.Text = "🔮 ANCIENT EVENT CHAMBER"
eventTitle.TextColor3 = Color3.fromRGB(210, 160, 255)
eventTitle.Font = Enum.Font.GothamBold
eventTitle.TextSize = 18
eventTitle.TextXAlignment = Enum.TextXAlignment.Left
eventTitle.ZIndex = 17
eventTitle.Parent = eventHeader

local eventStatusLabel = Instance.new("TextLabel")
eventStatusLabel.Size = UDim2.new(1, -90, 0, 20)
eventStatusLabel.Position = UDim2.new(0, 20, 0, 34)
eventStatusLabel.BackgroundTransparency = 1
eventStatusLabel.Text = "Attempts Remaining: 3"
eventStatusLabel.TextColor3 = Color3.fromRGB(255, 215, 80)
eventStatusLabel.Font = Enum.Font.GothamMedium
eventStatusLabel.TextSize = 13
eventStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
eventStatusLabel.ZIndex = 17
eventStatusLabel.Parent = eventHeader

local eventCloseBtn = Instance.new("TextButton")
eventCloseBtn.Size = UDim2.new(0, 32, 0, 32)
eventCloseBtn.Position = UDim2.new(1, -44, 0, 14)
eventCloseBtn.BackgroundColor3 = Color3.fromRGB(60, 45, 75)
eventCloseBtn.Text = "✕"
eventCloseBtn.TextColor3 = Color3.fromRGB(230, 210, 255)
eventCloseBtn.Font = Enum.Font.GothamBold
eventCloseBtn.TextSize = 16
eventCloseBtn.ZIndex = 18
eventCloseBtn.Parent = eventHeader
UIFactory.createCorner(eventCloseBtn, 8)
eventCloseBtn.MouseButton1Click:Connect(function()
	eventChamberView.Visible = false
end)

local eventClueBox = Instance.new("Frame")
eventClueBox.Size = UDim2.new(1, -48, 0, 130)
eventClueBox.Position = UDim2.new(0, 24, 0, 68)
eventClueBox.BackgroundColor3 = Color3.fromRGB(16, 14, 24)
eventClueBox.ZIndex = 16
eventClueBox.Parent = eventChamberView
UIFactory.createCorner(eventClueBox, 10)
UIFactory.createStroke(eventClueBox, Color3.fromRGB(70, 60, 100), 1)

local eventCluePadding = Instance.new("UIPadding")
eventCluePadding.PaddingLeft = UDim.new(0, 16)
eventCluePadding.PaddingRight = UDim.new(0, 16)
eventCluePadding.PaddingTop = UDim.new(0, 10)
eventCluePadding.PaddingBottom = UDim.new(0, 10)
eventCluePadding.Parent = eventClueBox

local eventClueText = Instance.new("TextLabel")
eventClueText.Size = UDim2.new(1, 0, 1, 0)
eventClueText.Position = UDim2.new(0, 0, 0, 0)
eventClueText.BackgroundTransparency = 1
eventClueText.Text = "Decipher the chamber's secret..."
eventClueText.TextColor3 = Color3.fromRGB(230, 220, 255)
eventClueText.Font = Enum.Font.GothamMedium
eventClueText.TextSize = 13
eventClueText.TextWrapped = true
eventClueText.TextXAlignment = Enum.TextXAlignment.Left
eventClueText.TextYAlignment = Enum.TextYAlignment.Top
eventClueText.ZIndex = 17
eventClueText.Parent = eventClueBox

local interactablesContainer = Instance.new("Frame")
interactablesContainer.Size = UDim2.new(1, -48, 0, 240)
interactablesContainer.Position = UDim2.new(0, 24, 0, 208)
interactablesContainer.BackgroundTransparency = 1
interactablesContainer.ZIndex = 16
interactablesContainer.Parent = eventChamberView

local interactablesLayout = Instance.new("UIGridLayout")
interactablesLayout.CellSize = UDim2.new(0.48, 0, 0, 58)
interactablesLayout.CellPadding = UDim2.new(0.04, 0, 0, 14)
interactablesLayout.Parent = interactablesContainer

local isEventInteractPending = false

local function renderEventChamber(eventView: StateTypes.EventView)
	eventTitle.Text = string.format("🔮 %s (%s)", eventView.Name, eventView.Category)
	eventStatusLabel.Text = string.format("Attempts Remaining: %d  |  Status: %s",
		eventView.AttemptsRemaining, eventView.Outcome)

	local clue = eventView.ClueText or "Examine your surroundings to solve the chamber's secret."
	if eventView.ObjectiveText then
		clue = clue .. string.format("\n🎯 Objective: %s", eventView.ObjectiveText)
	end
	eventClueText.Text = clue

	if eventView.Category == "Riddle" then
		interactablesLayout.CellSize = UDim2.new(0.98, 0, 0, 48)
		interactablesLayout.CellPadding = UDim2.new(0, 0, 0, 8)
	else
		interactablesLayout.CellSize = UDim2.new(0.48, 0, 0, 58)
		interactablesLayout.CellPadding = UDim2.new(0.04, 0, 0, 14)
	end

	for _, child in interactablesContainer:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	for _, interactable in eventView.Interactables do
		local btnFrame = Instance.new("Frame")
		btnFrame.Size = UDim2.new(1, 0, 1, 0)
		btnFrame.BackgroundTransparency = 1
		btnFrame.ZIndex = 17
		btnFrame.Parent = interactablesContainer

		local btnColor = interactable.IsActive and Color3.fromRGB(75, 55, 125) or Color3.fromRGB(50, 48, 60)
		local btnText = interactable.Label or interactable.Name
		local btn = UIFactory.createButton(btnFrame, btnText, btnColor, function()
			if isEventInteractPending then return end
			if not interactable.IsActive then return end
			isEventInteractPending = true
			bannerLabel.Text = "Submitting choice..."
			bannerLabel.TextColor3 = Color3.fromRGB(255, 220, 100)
			if InteractEventObjectEvent then
				InteractEventObjectEvent:FireServer(interactable.Id)
			end
		end)
		btn.ZIndex = 18
		btn.TextWrapped = true
		btn.TextSize = 13
		btn.Active = interactable.IsActive

		local btnPadding = Instance.new("UIPadding")
		btnPadding.PaddingLeft = UDim.new(0, 12)
		btnPadding.PaddingRight = UDim.new(0, 12)
		btnPadding.PaddingTop = UDim.new(0, 6)
		btnPadding.PaddingBottom = UDim.new(0, 6)
		btnPadding.Parent = btn
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
	victoryView.Visible = (phase == "RunVictory")
	defeatView.Visible = (phase == "RunDefeat")

	if phase ~= "ActiveRoom" then
		eventChamberView.Visible = false
		isEventInteractPending = false
		if reactionWidget then
			reactionWidget.Visible = false
		end
	end
end

--------------------------------------------------------------------------------
-- Remote Event Listeners
--------------------------------------------------------------------------------

-- 1. Synchronized Run State Update
if RunStateUpdateEvent then
	RunStateUpdateEvent.OnClientEvent:Connect(function(snapshot: StateTypes.RunSnapshot)
		if not snapshot then return end

		local rev = snapshot.StateRevision or 0
		print(string.format("[MAPFLOW][CLIENT] 14. RunStateUpdate RECEIVED: Phase=%s, Rev=%d, CurrentNode=%s",
			tostring(snapshot.Phase), rev, tostring(snapshot.CurrentNodeId)))

		print(string.format("[MAPFLOW][CLIENT] 15. StateRevision checked: Rev=%d, LastRev=%d",
			rev, lastRunStateRevision))
		if snapshot.StateRevision and snapshot.StateRevision < lastRunStateRevision then
			print(string.format("[MAPFLOW][CLIENT] Stale RunStateUpdate snapshot discarded (rev %d < last %d)",
				snapshot.StateRevision, lastRunStateRevision))
			return
		end
		if snapshot.StateRevision then
			lastRunStateRevision = snapshot.StateRevision
		end

		print(string.format("[MAPFLOW][CLIENT] 16. Phase processed: Phase=%s", tostring(snapshot.Phase)))
		print(string.format("[MAPFLOW][CLIENT] 17. CurrentNodeId processed: CurrentNode=%s", tostring(snapshot.CurrentNodeId)))

		print(string.format("[MAPFLOW][CLIENT] 18. switchView called: TargetPhase=%s", tostring(snapshot.Phase)))
		switchView(snapshot.Phase)
		print(string.format("[MAPFLOW][CLIENT] 19. MapVisible updated: MapVisible=%s", tostring(mapView.Visible)))
		print(string.format("[MAPFLOW][CLIENT] 20. CombatVisible updated: CombatVisible=%s", tostring(combatHudView.Visible)))

		if snapshot.Phase == "Lobby" then
			bannerLabel.Text = "Lobby: Gather heroes and start run."
		elseif snapshot.Phase == "MapSelect" then
			bannerLabel.Text = "Map Selection: Select reachable room to proceed."
			buildDungeonMapTree(snapshot)
		elseif snapshot.Phase == "ActiveRoom" then
			bannerLabel.Text = "Entered Room: Combat"
			bannerLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
			if snapshot.Event ~= nil and not snapshot.Event.IsCompleted then
				combatHudView.Visible = false
				eventChamberView.Visible = true
				renderEventChamber(snapshot.Event)
				bannerLabel.Text = string.format("Event Chamber: %s", snapshot.Event.Name)
			else
				combatHudView.Visible = (snapshot.Event == nil)
				eventChamberView.Visible = false
			end
		elseif snapshot.Phase == "Rewards" then
			isRewardClaimPending = false
			local isBossRoom = (snapshot.CurrentTier == 10)
			rewardsTitle.Text = if isBossRoom then "👑 ACT BOSS CLEARED: CLAIM REWARDS" else "🎁 ROOM CLEARED: CLAIM REWARDS"
			if snapshot.Rewards and snapshot.Rewards.HasClaimed then
				bannerLabel.Text = "Reward claimed! Click CONTINUE ➔ to proceed."
				bannerLabel.TextColor3 = Color3.fromRGB(80, 220, 120)
			else
				bannerLabel.Text = if isBossRoom then "👑 Boss Defeated! Draft 1 card reward." else "Room Cleared! Draft 1 card reward."
				bannerLabel.TextColor3 = Color3.fromRGB(255, 230, 100)
			end
			if snapshot.Rewards then
				rewardsGoldText.Text = string.format("💰 Gold: +%d  |  💎 Aether Shards: +%d", snapshot.Rewards.GoldAmount, snapshot.Rewards.AetherShardsAmount)
				buildCardDraftView(snapshot.Rewards.OfferedCards, snapshot.Rewards.HasClaimed)
			end
		elseif snapshot.Phase == "RunVictory" then
			isRewardClaimPending = false
			bannerLabel.Text = "🏆 VICTORY! The Spire has fallen!"
			bannerLabel.TextColor3 = Color3.fromRGB(80, 255, 120)
		elseif snapshot.Phase == "RunDefeat" then
			isRewardClaimPending = false
			bannerLabel.Text = "💀 DEFEAT! All party members have fallen."
			bannerLabel.TextColor3 = Color3.fromRGB(255, 60, 60)
		end

		if snapshot.Phase ~= "Rewards" then
			isRewardClaimPending = false
		end

		if snapshot.Phase ~= "MapSelect" or snapshot.CurrentNodeId ~= nil then
			isVotePending = false
			pendingVoteNodeId = nil
			setMapButtonsEnabled(false)
			firstRoomPromptLabel.Visible = false
		end
		if snapshot.Phase == "ActiveRoom" then
			mapView.Visible = false
		end
		if snapshot.Phase ~= "MapSelect" then
			lastFocusedPhase = snapshot.Phase
		end

		if snapshot.Message and snapshot.Message ~= "" and snapshot.Phase ~= "ActiveRoom" then
			bannerLabel.Text = snapshot.Message
		end
	end)
end

-- 2. Authoritative Combat Snapshot Update
if CombatStateUpdateEvent then
	CombatStateUpdateEvent.OnClientEvent:Connect(function(snapshot: StateTypes.CombatSnapshot)
		if not snapshot then return end

		currentCombatPhase = snapshot.Phase or "PlayerPhase"
		isPlayCardPending = false
		isReadyVotePending = false

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
			if snapshot.Phase == "ResolutionPhase" then
				readyBtn.Text = "⏳ RESOLVING..."
				readyBtn.BackgroundColor3 = Color3.fromRGB(70, 75, 90)
				readyBtn.Active = false
			elseif myView.IsReady then
				readyBtn.Active = true
				readyBtn.Text = "✓ READY"
				readyBtn.BackgroundColor3 = Color3.fromRGB(45, 180, 80)
			else
				readyBtn.Active = true
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

		-- Environment Badge Update
		if snapshot.Environment then
			environmentBadge.Visible = true
			local transText = snapshot.Environment.ActiveTransformation
			if transText then
				environmentLabel.Text = string.format("%s %s [%s]", snapshot.Environment.Icon, snapshot.Environment.Name, transText)
			else
				environmentLabel.Text = string.format("%s %s", snapshot.Environment.Icon, snapshot.Environment.Name)
			end
		else
			environmentBadge.Visible = false
		end

		-- Active Reaction Window Update (3D Attack Timing & Reaction Prompt)
		if snapshot.ActiveReactionWindow then
			local win = snapshot.ActiveReactionWindow
			if activeReactionWindowId ~= win.WindowId then
				activeReactionWindowId = win.WindowId
				currentReactionWindowView = win
				startReactionOpportunity(win)
			end
		else
			activeReactionWindowId = nil
			currentReactionWindowView = nil
			reactionWidget.Visible = false
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

-- 5. Action Result Feedback (Phase 14)
if ActionResultEvent then
	ActionResultEvent.OnClientEvent:Connect(function(res: any)
		if not res then return end
		if res.Action == "VoteMapNode" then
			print(string.format("[MAPFLOW][CLIENT] 11. ActionResult RECEIVED: Action=VoteMapNode, Success=%s, Won=%s, Node=%s, Phase=%s, Rev=%s",
				tostring(res.Success), tostring(res.Won), tostring(res.NodeId), tostring(res.Phase), tostring(res.StateRevision)))

			if lastFocusedPhase == "ActiveRoom" or not mapView.Visible then
				isVotePending = false
				pendingVoteNodeId = nil
				setMapButtonsEnabled(false)
				return
			end

			if res.Success == false then
				isVotePending = false
				pendingVoteNodeId = nil
				setMapButtonsEnabled(true)
				local failReason = res.Reason or res.Message or "Rejection"
				bannerLabel.Text = string.format("⚠️ Vote Failed: %s", failReason)
				bannerLabel.TextColor3 = Color3.fromRGB(255, 90, 90)
				if lastFocusedPhase == "MapSelect" and lastFocusedNodeId == nil and (lastFocusedTier == 0 or lastFocusedTier == nil) then
					firstRoomPromptLabel.Visible = true
				end
			else
				if res.Won == true then
					-- Vote accepted and party won consensus! Keep buttons disabled and request immediate state sync
					setMapButtonsEnabled(false)
					bannerLabel.Text = "Room selected. Syncing room..."
					bannerLabel.TextColor3 = Color3.fromRGB(80, 220, 120)
					print(string.format("[MAPFLOW][CLIENT] 12. ActionResult Won: Node=%s, ServerPhase=%s, ServerRev=%s",
						tostring(res.NodeId), tostring(res.Phase), tostring(res.StateRevision)))
					print("[MAPFLOW][CLIENT] 13. RequestStateSync SENT")
					if RequestStateSyncEvent then
						RequestStateSyncEvent:FireServer()
					end
				else
					isVotePending = false
					pendingVoteNodeId = nil
					setMapButtonsEnabled(true)
					bannerLabel.Text = "Vote submitted — waiting for the party..."
					bannerLabel.TextColor3 = Color3.fromRGB(80, 220, 120)
				end
			end
		elseif res.Action == "SubmitCombatReaction" then
			-- Reconcile displayed reaction judgement with authoritative server result
			if res.Success then
				local j = res.ReactionJudgement or res.ReactionResult
				if j == "Perfect" then
					showJudgementFeedback("PERFECT!", Color3.fromRGB(80, 240, 255))
					bannerLabel.Text = string.format("⚡ Server: %s", tostring(res.Message or "PERFECT!"))
					bannerLabel.TextColor3 = Color3.fromRGB(80, 240, 255)
				elseif j == "Good" then
					showJudgementFeedback("GOOD", Color3.fromRGB(80, 220, 120))
					bannerLabel.Text = string.format("💨 Server: %s", tostring(res.Message or "GOOD!"))
					bannerLabel.TextColor3 = Color3.fromRGB(80, 220, 120)
				elseif j == "Early" then
					showJudgementFeedback("EARLY", Color3.fromRGB(255, 160, 50))
					bannerLabel.Text = string.format("⚠️ Server: %s", tostring(res.Message or "Early"))
					bannerLabel.TextColor3 = Color3.fromRGB(255, 160, 50)
				elseif j == "Late" then
					showJudgementFeedback("LATE", Color3.fromRGB(255, 90, 90))
					bannerLabel.Text = string.format("⚠️ Server: %s", tostring(res.Message or "Late"))
					bannerLabel.TextColor3 = Color3.fromRGB(255, 90, 90)
				end
			else
				showJudgementFeedback(res.ReactionJudgement or "MISS", Color3.fromRGB(255, 90, 90))
				bannerLabel.Text = string.format("⚠️ %s", tostring(res.Message or "Reaction missed"))
				bannerLabel.TextColor3 = Color3.fromRGB(255, 90, 90)
			end
		elseif res.Action == "ClaimRewardCard" then
			isRewardClaimPending = false
			if res.Success == true then
				print("[REWARDFLOW][CLIENT][3] ClaimRewardCard confirmed by server")
				bannerLabel.Text = "✅ Card drafted! Click CONTINUE ➔ to proceed."
				bannerLabel.TextColor3 = Color3.fromRGB(80, 220, 120)
			else
				print(string.format("[REWARDFLOW][CLIENT][3] ClaimRewardCard rejected: %s", tostring(res.Message)))
				bannerLabel.Text = string.format("⚠️ Failed to claim card: %s", tostring(res.Message or "Unknown error."))
				bannerLabel.TextColor3 = Color3.fromRGB(255, 90, 90)
			end
		elseif res.Action == "ContinueFromRewards" then
			if res.Success == true then
				print("[REWARDFLOW][CLIENT][4] ContinueFromRewards confirmed by server")
				bannerLabel.Text = "Entering map..."
				bannerLabel.TextColor3 = Color3.fromRGB(80, 220, 120)
			else
				print(string.format("[REWARDFLOW][CLIENT][4] ContinueFromRewards rejected: %s", tostring(res.Message)))
				bannerLabel.Text = string.format("⚠️ Cannot continue: %s", tostring(res.Message or "Unknown error."))
				bannerLabel.TextColor3 = Color3.fromRGB(255, 90, 90)
			end
		elseif res.Action == "PlayCard" then
			isPlayCardPending = false
			if res.Success == false then
				bannerLabel.Text = string.format("⚠️ %s", tostring(res.Message or "Cannot play card."))
				bannerLabel.TextColor3 = Color3.fromRGB(255, 90, 90)
			end
		elseif res.Action == "InteractEventObject" then
			isEventInteractPending = false
			if res.Success == false then
				bannerLabel.Text = string.format("⚠️ %s", tostring(res.Message or "Interaction failed."))
				bannerLabel.TextColor3 = Color3.fromRGB(255, 90, 90)
			else
				bannerLabel.Text = tostring(res.Message or "Interaction recorded.")
				bannerLabel.TextColor3 = Color3.fromRGB(80, 220, 120)
			end
		elseif res.Success == false then
			bannerLabel.Text = string.format("⚠️ %s: %s", res.Action or "Action", res.Message or "Action failed.")
			bannerLabel.TextColor3 = Color3.fromRGB(255, 90, 90)
		elseif res.Action == "ReturnToLobby" and res.Success == true then
			switchView("Lobby")
		end
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
