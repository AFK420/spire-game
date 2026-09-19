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
local CardData = require(Shared:WaitForChild("CardData") :: ModuleScript)
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
local CampfireChoiceEvent = getEvent("CampfireChoice")
local BuyMerchantItemEvent = getEvent("BuyMerchantItem")
local ExitMerchantEvent = getEvent("ExitMerchant")

-- Phase 4 Deck & Collection Requests
local RequestDecksEvent = getEvent("RequestDecks")
local RequestCardCollectionEvent = getEvent("RequestCardCollection")

-- Server -> Client State
local RunStateUpdateEvent = getEvent("RunStateUpdate")
local CombatStateUpdateEvent = getEvent("CombatStateUpdate")
local CombatEventLoggedEvent = getEvent("CombatEventLogged")
local AnnouncementEvent = getEvent("Announcement")
local ActionResultEvent = getEvent("ActionResult")
local DeckListUpdateEvent = getEvent("DeckListUpdate")
local DeckDetailUpdateEvent = getEvent("DeckDetailUpdate")
local CardCollectionUpdateEvent = getEvent("CardCollectionUpdate")

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
lobbyView.Size = UDim2.new(0, 480, 0, 390)
lobbyView.Position = UDim2.new(0.5, -240, 0.5, -195)
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
startRunBtnContainer.Size = UDim2.new(0, 260, 0, 48)
startRunBtnContainer.Position = UDim2.new(0.5, -130, 0, 210)
startRunBtnContainer.BackgroundTransparency = 1
startRunBtnContainer.Parent = lobbyView

UIFactory.createButton(startRunBtnContainer, "START DUNGEON RUN ➔", Color3.fromRGB(45, 175, 80), function()
	if StartRunEvent then
		StartRunEvent:FireServer()
	end
end)

local deckBuilderBtnContainer = Instance.new("Frame")
deckBuilderBtnContainer.Size = UDim2.new(0, 260, 0, 44)
deckBuilderBtnContainer.Position = UDim2.new(0.5, -130, 0, 272)
deckBuilderBtnContainer.BackgroundTransparency = 1
deckBuilderBtnContainer.Parent = lobbyView

--------------------------------------------------------------------------------
-- VIEW: Deck Builder & Card Collection Frontend
--------------------------------------------------------------------------------

type DeckBuilderController = {
	View: Frame,
	toggle: () -> (),
	show: () -> (),
	hide: () -> (),
	onDeckListUpdate: (decks: { StateTypes.DeckSummaryView }, activeDeckId: string) -> (),
	onDeckDetailUpdate: (detail: StateTypes.DeckDetailView) -> (),
	onCardCollectionUpdate: (collectionView: StateTypes.CardCollectionView) -> (),
	handleActionResult: (res: any) -> boolean,
}

local function createDeckBuilderController(): DeckBuilderController
	local CreateDeckEvent = getEvent("CreateDeck")
	local RenameDeckEvent = getEvent("RenameDeck")
	local DeleteDeckEvent = getEvent("DeleteDeck")
	local SaveDeckEvent = getEvent("SaveDeck")
	local DuplicateDeckEvent = getEvent("DuplicateDeck")
	local SelectActiveDeckEvent = getEvent("SelectActiveDeck")

	local deckBuilderView = Instance.new("Frame")
	deckBuilderView.Name = "DeckBuilderView"
	deckBuilderView.Size = UDim2.new(0, 940, 0, 580)
	deckBuilderView.Position = UDim2.new(0.5, -470, 0.5, -290)
	deckBuilderView.BackgroundColor3 = Color3.fromRGB(18, 20, 26)
	deckBuilderView.BackgroundTransparency = 0.05
	deckBuilderView.BorderSizePixel = 0
	deckBuilderView.Visible = false
	deckBuilderView.ZIndex = 30
	deckBuilderView.Parent = mainFrame
	UIFactory.createCorner(deckBuilderView, 14)
	UIFactory.createStroke(deckBuilderView, Color3.fromRGB(50, 110, 200), 2)

	-- Header
	local deckBuilderHeader = Instance.new("Frame")
	deckBuilderHeader.Size = UDim2.new(1, 0, 0, 48)
	deckBuilderHeader.BackgroundColor3 = Color3.fromRGB(24, 28, 38)
	deckBuilderHeader.BorderSizePixel = 0
	deckBuilderHeader.ZIndex = 31
	deckBuilderHeader.Parent = deckBuilderView
	UIFactory.createCorner(deckBuilderHeader, 14)

	local deckBuilderHeaderTitle = Instance.new("TextLabel")
	deckBuilderHeaderTitle.Size = UDim2.new(0, 320, 1, 0)
	deckBuilderHeaderTitle.Position = UDim2.new(0, 18, 0, 0)
	deckBuilderHeaderTitle.BackgroundTransparency = 1
	deckBuilderHeaderTitle.Text = "🎴 DECK BUILDER & COLLECTION"
	deckBuilderHeaderTitle.TextColor3 = Color3.fromRGB(120, 190, 255)
	deckBuilderHeaderTitle.Font = Enum.Font.GothamBold
	deckBuilderHeaderTitle.TextSize = 16
	deckBuilderHeaderTitle.TextXAlignment = Enum.TextXAlignment.Left
	deckBuilderHeaderTitle.ZIndex = 32
	deckBuilderHeaderTitle.Parent = deckBuilderHeader

	local deckBuilderStatusLabel = Instance.new("TextLabel")
	deckBuilderStatusLabel.Name = "DeckBuilderStatus"
	deckBuilderStatusLabel.Size = UDim2.new(1, -430, 1, 0)
	deckBuilderStatusLabel.Position = UDim2.new(0, 350, 0, 0)
	deckBuilderStatusLabel.BackgroundTransparency = 1
	deckBuilderStatusLabel.Text = "Select or create a deck to begin editing."
	deckBuilderStatusLabel.TextColor3 = Color3.fromRGB(180, 190, 210)
	deckBuilderStatusLabel.Font = Enum.Font.GothamMedium
	deckBuilderStatusLabel.TextSize = 12
	deckBuilderStatusLabel.TextXAlignment = Enum.TextXAlignment.Right
	deckBuilderStatusLabel.TextTruncate = Enum.TextTruncate.AtEnd
	deckBuilderStatusLabel.ZIndex = 32
	deckBuilderStatusLabel.Parent = deckBuilderHeader

	local closeDeckBuilderBtn = Instance.new("TextButton")
	closeDeckBuilderBtn.Size = UDim2.new(0, 34, 0, 34)
	closeDeckBuilderBtn.Position = UDim2.new(1, -42, 0, 7)
	closeDeckBuilderBtn.BackgroundColor3 = Color3.fromRGB(45, 50, 65)
	closeDeckBuilderBtn.BorderSizePixel = 0
	closeDeckBuilderBtn.Text = "✕"
	closeDeckBuilderBtn.TextColor3 = Color3.fromRGB(240, 240, 240)
	closeDeckBuilderBtn.Font = Enum.Font.GothamBold
	closeDeckBuilderBtn.TextSize = 16
	closeDeckBuilderBtn.ZIndex = 33
	closeDeckBuilderBtn.Parent = deckBuilderHeader
	UIFactory.createCorner(closeDeckBuilderBtn, 8)
	closeDeckBuilderBtn.MouseButton1Click:Connect(function()
		deckBuilderView.Visible = false
	end)

	-- Main 3-column body
	local deckBuilderBody = Instance.new("Frame")
	deckBuilderBody.Size = UDim2.new(1, -24, 1, -62)
	deckBuilderBody.Position = UDim2.new(0, 12, 0, 54)
	deckBuilderBody.BackgroundTransparency = 1
	deckBuilderBody.ZIndex = 31
	deckBuilderBody.Parent = deckBuilderView

	--------------------------------------------------------------------------------
	-- Column 1: Decks Sidebar (Left)
	--------------------------------------------------------------------------------

	local decksSidebarFrame = Instance.new("Frame")
	decksSidebarFrame.Size = UDim2.new(0, 250, 1, 0)
	decksSidebarFrame.Position = UDim2.new(0, 0, 0, 0)
	decksSidebarFrame.BackgroundColor3 = Color3.fromRGB(22, 25, 34)
	decksSidebarFrame.BorderSizePixel = 0
	decksSidebarFrame.ZIndex = 32
	decksSidebarFrame.Parent = deckBuilderBody
	UIFactory.createCorner(decksSidebarFrame, 10)
	UIFactory.createStroke(decksSidebarFrame, Color3.fromRGB(45, 55, 75), 1)

	local decksSidebarHeader = Instance.new("Frame")
	decksSidebarHeader.Size = UDim2.new(1, -16, 0, 36)
	decksSidebarHeader.Position = UDim2.new(0, 8, 0, 8)
	decksSidebarHeader.BackgroundTransparency = 1
	decksSidebarHeader.ZIndex = 33
	decksSidebarHeader.Parent = decksSidebarFrame

	local decksSidebarTitle = Instance.new("TextLabel")
	decksSidebarTitle.Size = UDim2.new(0, 110, 1, 0)
	decksSidebarTitle.BackgroundTransparency = 1
	decksSidebarTitle.Text = "MY DECKS"
	decksSidebarTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
	decksSidebarTitle.Font = Enum.Font.GothamBold
	decksSidebarTitle.TextSize = 14
	decksSidebarTitle.TextXAlignment = Enum.TextXAlignment.Left
	decksSidebarTitle.ZIndex = 34
	decksSidebarTitle.Parent = decksSidebarHeader

	local createDeckBtnContainer = Instance.new("Frame")
	createDeckBtnContainer.Size = UDim2.new(0, 115, 0, 30)
	createDeckBtnContainer.Position = UDim2.new(1, -115, 0, 3)
	createDeckBtnContainer.BackgroundTransparency = 1
	createDeckBtnContainer.ZIndex = 34
	createDeckBtnContainer.Parent = decksSidebarHeader

	local decksListScroll = Instance.new("ScrollingFrame")
	decksListScroll.Size = UDim2.new(1, -16, 1, -56)
	decksListScroll.Position = UDim2.new(0, 8, 0, 48)
	decksListScroll.BackgroundTransparency = 1
	decksListScroll.BorderSizePixel = 0
	decksListScroll.ScrollBarThickness = 5
	decksListScroll.ScrollBarImageColor3 = Color3.fromRGB(80, 95, 125)
	decksListScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	decksListScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	decksListScroll.ZIndex = 33
	decksListScroll.Parent = decksSidebarFrame

	local decksListLayout = Instance.new("UIListLayout")
	decksListLayout.SortOrder = Enum.SortOrder.LayoutOrder
	decksListLayout.Padding = UDim.new(0, 8)
	decksListLayout.Parent = decksListScroll

	--------------------------------------------------------------------------------
	-- Column 2: Draft Editor (Center)
	--------------------------------------------------------------------------------

	local draftEditorFrame = Instance.new("Frame")
	draftEditorFrame.Size = UDim2.new(0, 365, 1, 0)
	draftEditorFrame.Position = UDim2.new(0, 260, 0, 0)
	draftEditorFrame.BackgroundColor3 = Color3.fromRGB(22, 25, 34)
	draftEditorFrame.BorderSizePixel = 0
	draftEditorFrame.ZIndex = 32
	draftEditorFrame.Parent = deckBuilderBody
	UIFactory.createCorner(draftEditorFrame, 10)
	UIFactory.createStroke(draftEditorFrame, Color3.fromRGB(45, 55, 75), 1)

	local draftHeaderFrame = Instance.new("Frame")
	draftHeaderFrame.Size = UDim2.new(1, -16, 0, 78)
	draftHeaderFrame.Position = UDim2.new(0, 8, 0, 8)
	draftHeaderFrame.BackgroundTransparency = 1
	draftHeaderFrame.ZIndex = 33
	draftHeaderFrame.Parent = draftEditorFrame

	local draftDeckTitleLabel = Instance.new("TextLabel")
	draftDeckTitleLabel.Size = UDim2.new(1, 0, 0, 22)
	draftDeckTitleLabel.Position = UDim2.new(0, 0, 0, 0)
	draftDeckTitleLabel.BackgroundTransparency = 1
	draftDeckTitleLabel.Text = "Editing: (Select a Deck)"
	draftDeckTitleLabel.TextColor3 = Color3.fromRGB(120, 190, 255)
	draftDeckTitleLabel.Font = Enum.Font.GothamBold
	draftDeckTitleLabel.TextSize = 14
	draftDeckTitleLabel.TextXAlignment = Enum.TextXAlignment.Left
	draftDeckTitleLabel.TextTruncate = Enum.TextTruncate.AtEnd
	draftDeckTitleLabel.ZIndex = 34
	draftDeckTitleLabel.Parent = draftHeaderFrame

	local draftCountLabel = Instance.new("TextLabel")
	draftCountLabel.Size = UDim2.new(1, 0, 0, 18)
	draftCountLabel.Position = UDim2.new(0, 0, 0, 24)
	draftCountLabel.BackgroundTransparency = 1
	draftCountLabel.Text = "Cards: 0 / 30 (Min: 8, Max: 30, Max Copies: 3)"
	draftCountLabel.TextColor3 = Color3.fromRGB(180, 190, 210)
	draftCountLabel.Font = Enum.Font.GothamMedium
	draftCountLabel.TextSize = 12
	draftCountLabel.TextXAlignment = Enum.TextXAlignment.Left
	draftCountLabel.ZIndex = 34
	draftCountLabel.Parent = draftHeaderFrame

	local draftActionButtons = Instance.new("Frame")
	draftActionButtons.Size = UDim2.new(1, 0, 0, 30)
	draftActionButtons.Position = UDim2.new(0, 0, 0, 46)
	draftActionButtons.BackgroundTransparency = 1
	draftActionButtons.ZIndex = 34
	draftActionButtons.Parent = draftHeaderFrame

	local saveDraftBtnContainer = Instance.new("Frame")
	saveDraftBtnContainer.Size = UDim2.new(0, 125, 1, 0)
	saveDraftBtnContainer.Position = UDim2.new(0, 0, 0, 0)
	saveDraftBtnContainer.BackgroundTransparency = 1
	saveDraftBtnContainer.ZIndex = 35
	saveDraftBtnContainer.Parent = draftActionButtons

	local revertDraftBtnContainer = Instance.new("Frame")
	revertDraftBtnContainer.Size = UDim2.new(0, 105, 1, 0)
	revertDraftBtnContainer.Position = UDim2.new(0, 133, 0, 0)
	revertDraftBtnContainer.BackgroundTransparency = 1
	revertDraftBtnContainer.ZIndex = 35
	revertDraftBtnContainer.Parent = draftActionButtons

	local clearDraftBtnContainer = Instance.new("Frame")
	clearDraftBtnContainer.Size = UDim2.new(0, 95, 1, 0)
	clearDraftBtnContainer.Position = UDim2.new(1, -95, 0, 0)
	clearDraftBtnContainer.BackgroundTransparency = 1
	clearDraftBtnContainer.ZIndex = 35
	clearDraftBtnContainer.Parent = draftActionButtons

	local draftCardsScroll = Instance.new("ScrollingFrame")
	draftCardsScroll.Size = UDim2.new(1, -16, 1, -100)
	draftCardsScroll.Position = UDim2.new(0, 8, 0, 92)
	draftCardsScroll.BackgroundTransparency = 1
	draftCardsScroll.BorderSizePixel = 0
	draftCardsScroll.ScrollBarThickness = 5
	draftCardsScroll.ScrollBarImageColor3 = Color3.fromRGB(80, 95, 125)
	draftCardsScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	draftCardsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	draftCardsScroll.ZIndex = 33
	draftCardsScroll.Parent = draftEditorFrame

	local draftCardsLayout = Instance.new("UIListLayout")
	draftCardsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	draftCardsLayout.Padding = UDim.new(0, 6)
	draftCardsLayout.Parent = draftCardsScroll

	--------------------------------------------------------------------------------
	-- Column 3: Card Collection Browser (Right)
	--------------------------------------------------------------------------------

	local collectionBrowserFrame = Instance.new("Frame")
	collectionBrowserFrame.Size = UDim2.new(1, -635, 1, 0)
	collectionBrowserFrame.Position = UDim2.new(0, 635, 0, 0)
	collectionBrowserFrame.BackgroundColor3 = Color3.fromRGB(22, 25, 34)
	collectionBrowserFrame.BorderSizePixel = 0
	collectionBrowserFrame.ZIndex = 32
	collectionBrowserFrame.Parent = deckBuilderBody
	UIFactory.createCorner(collectionBrowserFrame, 10)
	UIFactory.createStroke(collectionBrowserFrame, Color3.fromRGB(45, 55, 75), 1)

	local collectionHeaderFrame = Instance.new("Frame")
	collectionHeaderFrame.Size = UDim2.new(1, -16, 0, 78)
	collectionHeaderFrame.Position = UDim2.new(0, 8, 0, 8)
	collectionHeaderFrame.BackgroundTransparency = 1
	collectionHeaderFrame.ZIndex = 33
	collectionHeaderFrame.Parent = collectionBrowserFrame

	local collectionTitleLabel = Instance.new("TextLabel")
	collectionTitleLabel.Size = UDim2.new(1, 0, 0, 22)
	collectionTitleLabel.Position = UDim2.new(0, 0, 0, 0)
	collectionTitleLabel.BackgroundTransparency = 1
	collectionTitleLabel.Text = "CARD COLLECTION"
	collectionTitleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	collectionTitleLabel.Font = Enum.Font.GothamBold
	collectionTitleLabel.TextSize = 14
	collectionTitleLabel.TextXAlignment = Enum.TextXAlignment.Left
	collectionTitleLabel.ZIndex = 34
	collectionTitleLabel.Parent = collectionHeaderFrame

	local collectionSearchBox = Instance.new("TextBox")
	collectionSearchBox.Size = UDim2.new(1, 0, 0, 32)
	collectionSearchBox.Position = UDim2.new(0, 0, 0, 36)
	collectionSearchBox.BackgroundColor3 = Color3.fromRGB(30, 34, 46)
	collectionSearchBox.BorderSizePixel = 0
	collectionSearchBox.PlaceholderText = "🔍 Search cards..."
	collectionSearchBox.PlaceholderColor3 = Color3.fromRGB(120, 130, 150)
	collectionSearchBox.Text = ""
	collectionSearchBox.TextColor3 = Color3.fromRGB(240, 240, 240)
	collectionSearchBox.Font = Enum.Font.GothamMedium
	collectionSearchBox.TextSize = 13
	collectionSearchBox.TextXAlignment = Enum.TextXAlignment.Left
	collectionSearchBox.ClearTextOnFocus = false
	collectionSearchBox.ZIndex = 34
	collectionSearchBox.Parent = collectionHeaderFrame
	UIFactory.createCorner(collectionSearchBox, 6)
	UIFactory.createStroke(collectionSearchBox, Color3.fromRGB(60, 70, 95), 1)

	local collectionScroll = Instance.new("ScrollingFrame")
	collectionScroll.Size = UDim2.new(1, -16, 1, -100)
	collectionScroll.Position = UDim2.new(0, 8, 0, 92)
	collectionScroll.BackgroundTransparency = 1
	collectionScroll.BorderSizePixel = 0
	collectionScroll.ScrollBarThickness = 5
	collectionScroll.ScrollBarImageColor3 = Color3.fromRGB(80, 95, 125)
	collectionScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	collectionScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	collectionScroll.ZIndex = 33
	collectionScroll.Parent = collectionBrowserFrame

	local collectionLayout = Instance.new("UIListLayout")
	collectionLayout.SortOrder = Enum.SortOrder.LayoutOrder
	collectionLayout.Padding = UDim.new(0, 6)
	collectionLayout.Parent = collectionScroll

	--------------------------------------------------------------------------------
	-- Inline Rename Modal
	--------------------------------------------------------------------------------

	local renameModalFrame = Instance.new("Frame")
	renameModalFrame.Size = UDim2.new(0, 360, 0, 160)
	renameModalFrame.Position = UDim2.new(0.5, -180, 0.5, -80)
	renameModalFrame.BackgroundColor3 = Color3.fromRGB(24, 28, 38)
	renameModalFrame.BorderSizePixel = 0
	renameModalFrame.Visible = false
	renameModalFrame.ZIndex = 50
	renameModalFrame.Parent = deckBuilderView
	UIFactory.createCorner(renameModalFrame, 12)
	UIFactory.createStroke(renameModalFrame, Color3.fromRGB(60, 130, 240), 2)

	local renameModalTitle = Instance.new("TextLabel")
	renameModalTitle.Size = UDim2.new(1, -24, 0, 30)
	renameModalTitle.Position = UDim2.new(0, 12, 0, 14)
	renameModalTitle.BackgroundTransparency = 1
	renameModalTitle.Text = "Rename Deck"
	renameModalTitle.TextColor3 = Color3.fromRGB(240, 240, 240)
	renameModalTitle.Font = Enum.Font.GothamBold
	renameModalTitle.TextSize = 16
	renameModalTitle.TextXAlignment = Enum.TextXAlignment.Left
	renameModalTitle.ZIndex = 51
	renameModalTitle.Parent = renameModalFrame

	local renameInputBox = Instance.new("TextBox")
	renameInputBox.Size = UDim2.new(1, -24, 0, 38)
	renameInputBox.Position = UDim2.new(0, 12, 0, 52)
	renameInputBox.BackgroundColor3 = Color3.fromRGB(32, 36, 50)
	renameInputBox.BorderSizePixel = 0
	renameInputBox.PlaceholderText = "Enter new deck name..."
	renameInputBox.PlaceholderColor3 = Color3.fromRGB(120, 130, 150)
	renameInputBox.Text = ""
	renameInputBox.TextColor3 = Color3.fromRGB(255, 255, 255)
	renameInputBox.Font = Enum.Font.GothamMedium
	renameInputBox.TextSize = 14
	renameInputBox.ClearTextOnFocus = false
	renameInputBox.ZIndex = 51
	renameInputBox.Parent = renameModalFrame
	UIFactory.createCorner(renameInputBox, 8)
	UIFactory.createStroke(renameInputBox, Color3.fromRGB(70, 85, 115), 1)

	local renameConfirmBtnContainer = Instance.new("Frame")
	renameConfirmBtnContainer.Size = UDim2.new(0, 150, 0, 36)
	renameConfirmBtnContainer.Position = UDim2.new(0, 12, 1, -48)
	renameConfirmBtnContainer.BackgroundTransparency = 1
	renameConfirmBtnContainer.ZIndex = 51
	renameConfirmBtnContainer.Parent = renameModalFrame

	local renameCancelBtnContainer = Instance.new("Frame")
	renameCancelBtnContainer.Size = UDim2.new(0, 150, 0, 36)
	renameCancelBtnContainer.Position = UDim2.new(1, -162, 1, -48)
	renameCancelBtnContainer.BackgroundTransparency = 1
	renameCancelBtnContainer.ZIndex = 51
	renameCancelBtnContainer.Parent = renameModalFrame

	--------------------------------------------------------------------------------
	-- Deck Builder Client State & Functions
	--------------------------------------------------------------------------------

	local cachedDecks: { [string]: StateTypes.DeckSummaryView } = {}
	local deckDetailCache: { [string]: { [string]: number } } = {}
	local cachedActiveDeckId: string = ""
	local cachedCollection: { [string]: number } = {}
	local currentEditedDeckId: string? = nil
	local currentDraftCards: { [string]: number } = {}
	local originalDeckCards: { [string]: number } = {}
	local isDeckActionPending: boolean = false
	local collectionFilterText: string = ""
	local pendingRenameDeckId: string? = nil

	local function countCards(cards: { [string]: number }?): number
		if not cards then return 0 end
		local total = 0
		for _, count in cards do
			total += (count or 0)
		end
		return total
	end

	local function deepCopyCards(cards: { [string]: number }?): { [string]: number }
		local copy: { [string]: number } = {}
		if cards then
			for k, v in cards do
				copy[k] = v
			end
		end
		return copy
	end

	local function setDeckStatus(msg: string, color: Color3)
		deckBuilderStatusLabel.Text = msg
		deckBuilderStatusLabel.TextColor3 = color
	end

	local renderDecksList: () -> ()
	local renderDraftEditor: () -> ()
	local renderCollectionBrowser: () -> ()

	renderDecksList = function()
		for _, child in decksListScroll:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end

		local sortedDecks: { StateTypes.DeckSummaryView } = {}
		for _, d in cachedDecks do
			table.insert(sortedDecks, d)
		end
		table.sort(sortedDecks, function(a, b)
			if a.DeckId == cachedActiveDeckId then return true end
			if b.DeckId == cachedActiveDeckId then return false end
			return (a.Name or "") < (b.Name or "")
		end)

		for _, deck in sortedDecks do
			local isSelected = (deck.DeckId == currentEditedDeckId)
			local isActive = (deck.DeckId == cachedActiveDeckId)
			local deckItem = Instance.new("Frame")
			deckItem.Size = UDim2.new(1, -4, 0, 74)
			deckItem.BackgroundColor3 = if isSelected then Color3.fromRGB(32, 42, 60) else Color3.fromRGB(26, 30, 42)
			deckItem.BorderSizePixel = 0
			deckItem.ZIndex = 34
			deckItem.Parent = decksListScroll
			UIFactory.createCorner(deckItem, 8)
			local strokeColor = if isSelected
				then Color3.fromRGB(80, 180, 255)
				elseif isActive then Color3.fromRGB(50, 180, 100)
				else Color3.fromRGB(50, 60, 80)
			UIFactory.createStroke(deckItem, strokeColor, if isSelected or isActive then 1.5 else 1)

			local nameBtn = Instance.new("TextButton")
			nameBtn.Size = UDim2.new(1, -10, 0, 22)
			nameBtn.Position = UDim2.new(0, 8, 0, 6)
			nameBtn.BackgroundTransparency = 1
			nameBtn.Text = deck.Name
			nameBtn.TextColor3 = if isSelected then Color3.fromRGB(120, 210, 255) else Color3.fromRGB(240, 240, 240)
			nameBtn.Font = Enum.Font.GothamBold
			nameBtn.TextSize = 13
			nameBtn.TextXAlignment = Enum.TextXAlignment.Left
			nameBtn.TextTruncate = Enum.TextTruncate.AtEnd
			nameBtn.ZIndex = 35
			nameBtn.Parent = deckItem

			local countText = string.format("%d cards", deck.CardCount or countCards(deck.Cards))
			local infoLabel = Instance.new("TextLabel")
			infoLabel.Size = UDim2.new(0, 80, 0, 18)
			infoLabel.Position = UDim2.new(0, 8, 0, 28)
			infoLabel.BackgroundTransparency = 1
			infoLabel.Text = countText
			infoLabel.TextColor3 = Color3.fromRGB(160, 175, 195)
			infoLabel.Font = Enum.Font.GothamMedium
			infoLabel.TextSize = 11
			infoLabel.TextXAlignment = Enum.TextXAlignment.Left
			infoLabel.ZIndex = 35
			infoLabel.Parent = deckItem

			if isActive then
				local activeBadge = Instance.new("TextLabel")
				activeBadge.Size = UDim2.new(0, 72, 0, 18)
				activeBadge.Position = UDim2.new(0, 92, 0, 28)
				activeBadge.BackgroundColor3 = Color3.fromRGB(25, 90, 45)
				activeBadge.BorderSizePixel = 0
				activeBadge.Text = "★ ACTIVE"
				activeBadge.TextColor3 = Color3.fromRGB(120, 255, 160)
				activeBadge.Font = Enum.Font.GothamBold
				activeBadge.TextSize = 10
				activeBadge.ZIndex = 35
				activeBadge.Parent = deckItem
				UIFactory.createCorner(activeBadge, 4)
			else
				local setActiveBtn = Instance.new("TextButton")
				setActiveBtn.Size = UDim2.new(0, 76, 0, 18)
				setActiveBtn.Position = UDim2.new(0, 92, 0, 28)
				setActiveBtn.BackgroundColor3 = Color3.fromRGB(40, 50, 70)
				setActiveBtn.BorderSizePixel = 0
				setActiveBtn.Text = "Set Active"
				setActiveBtn.TextColor3 = Color3.fromRGB(180, 210, 255)
				setActiveBtn.Font = Enum.Font.GothamMedium
				setActiveBtn.TextSize = 10
				setActiveBtn.ZIndex = 35
				setActiveBtn.Parent = deckItem
				UIFactory.createCorner(setActiveBtn, 4)
				setActiveBtn.MouseButton1Click:Connect(function()
					if isDeckActionPending then return end
					isDeckActionPending = true
					setDeckStatus("Selecting active deck...", Color3.fromRGB(200, 200, 200))
					SelectActiveDeckEvent:FireServer(deck.DeckId)
				end)
			end

			local btnRow = Instance.new("Frame")
			btnRow.Size = UDim2.new(1, -16, 0, 20)
			btnRow.Position = UDim2.new(0, 8, 0, 48)
			btnRow.BackgroundTransparency = 1
			btnRow.ZIndex = 35
			btnRow.Parent = deckItem

			local renameBtn = Instance.new("TextButton")
			renameBtn.Size = UDim2.new(0, 62, 1, 0)
			renameBtn.Position = UDim2.new(0, 0, 0, 0)
			renameBtn.BackgroundColor3 = Color3.fromRGB(40, 48, 64)
			renameBtn.BorderSizePixel = 0
			renameBtn.Text = "✏️ Rename"
			renameBtn.TextColor3 = Color3.fromRGB(200, 210, 230)
			renameBtn.Font = Enum.Font.Gotham
			renameBtn.TextSize = 10
			renameBtn.ZIndex = 36
			renameBtn.Parent = btnRow
			UIFactory.createCorner(renameBtn, 4)
			renameBtn.MouseButton1Click:Connect(function()
				pendingRenameDeckId = deck.DeckId
				renameInputBox.Text = deck.Name
				renameModalFrame.Visible = true
				renameInputBox:CaptureFocus()
			end)

			local cloneBtn = Instance.new("TextButton")
			cloneBtn.Size = UDim2.new(0, 56, 1, 0)
			cloneBtn.Position = UDim2.new(0, 68, 0, 0)
			cloneBtn.BackgroundColor3 = Color3.fromRGB(40, 48, 64)
			cloneBtn.BorderSizePixel = 0
			cloneBtn.Text = "📋 Copy"
			cloneBtn.TextColor3 = Color3.fromRGB(200, 210, 230)
			cloneBtn.Font = Enum.Font.Gotham
			cloneBtn.TextSize = 10
			cloneBtn.ZIndex = 36
			cloneBtn.Parent = btnRow
			UIFactory.createCorner(cloneBtn, 4)
			cloneBtn.MouseButton1Click:Connect(function()
				if isDeckActionPending then return end
				local totalDecks = 0
				for _ in cachedDecks do totalDecks += 1 end
				if totalDecks >= GameConfig.Deck.MaxDeckSlots then
					setDeckStatus("⚠️ Maximum deck slots reached.", Color3.fromRGB(255, 90, 90))
					return
				end
				isDeckActionPending = true
				setDeckStatus("Duplicating deck...", Color3.fromRGB(200, 200, 200))
				DuplicateDeckEvent:FireServer(deck.DeckId, nil)
			end)

			local deleteBtn = Instance.new("TextButton")
			deleteBtn.Size = UDim2.new(0, 52, 1, 0)
			deleteBtn.Position = UDim2.new(0, 130, 0, 0)
			deleteBtn.BackgroundColor3 = if isActive then Color3.fromRGB(45, 45, 50) else Color3.fromRGB(65, 35, 40)
			deleteBtn.BorderSizePixel = 0
			deleteBtn.Text = "🗑️ Del"
			deleteBtn.TextColor3 = if isActive then Color3.fromRGB(100, 100, 110) else Color3.fromRGB(255, 120, 120)
			deleteBtn.Font = Enum.Font.Gotham
			deleteBtn.TextSize = 10
			deleteBtn.ZIndex = 36
			deleteBtn.Parent = btnRow
			UIFactory.createCorner(deleteBtn, 4)
			deleteBtn.MouseButton1Click:Connect(function()
				if isDeckActionPending then return end
				if isActive then
					setDeckStatus("⚠️ Cannot delete active deck. Switch active deck first.", Color3.fromRGB(255, 90, 90))
					return
				end
				local totalDecks = 0
				for _ in cachedDecks do totalDecks += 1 end
				if totalDecks <= 1 then
					setDeckStatus("⚠️ Cannot delete your only deck.", Color3.fromRGB(255, 90, 90))
					return
				end
				isDeckActionPending = true
				setDeckStatus("Deleting deck...", Color3.fromRGB(200, 200, 200))
				DeleteDeckEvent:FireServer(deck.DeckId)
			end)

			local function selectThisDeck()
				if currentEditedDeckId ~= deck.DeckId then
					currentEditedDeckId = deck.DeckId
					local cards = deckDetailCache[deck.DeckId] or deck.Cards or {}
					originalDeckCards = deepCopyCards(cards)
					currentDraftCards = deepCopyCards(originalDeckCards)
					setDeckStatus(string.format("Loaded deck '%s'.", deck.Name), Color3.fromRGB(180, 220, 255))
					renderDecksList()
					renderDraftEditor()
					renderCollectionBrowser()
				end
			end
			nameBtn.MouseButton1Click:Connect(selectThisDeck)
		end
	end

	renderDraftEditor = function()
		for _, child in draftCardsScroll:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end

		local editedDeck = if currentEditedDeckId then cachedDecks[currentEditedDeckId] else nil
		draftDeckTitleLabel.Text = if editedDeck then string.format("Editing: %s", editedDeck.Name) else "Editing: (No Deck Selected)"

		local totalCount = countCards(currentDraftCards)
		local minSize = GameConfig.Deck.MinDeckSize
		local maxSize = GameConfig.Deck.MaxDeckSize
		local maxCopies = GameConfig.Deck.MaxCopiesPerCard

		if totalCount < minSize then
			draftCountLabel.Text = string.format("Cards: %d / %d  (⚠️ Need %d+ cards)", totalCount, maxSize, minSize)
			draftCountLabel.TextColor3 = Color3.fromRGB(255, 170, 70)
		elseif totalCount > maxSize then
			draftCountLabel.Text = string.format("Cards: %d / %d  (⚠️ Exceeds %d cards)", totalCount, maxSize, maxSize)
			draftCountLabel.TextColor3 = Color3.fromRGB(255, 90, 90)
		else
			draftCountLabel.Text = string.format("Cards: %d / %d  (Valid Deck)", totalCount, maxSize)
			draftCountLabel.TextColor3 = Color3.fromRGB(80, 220, 120)
		end

		local sortedCards: { { Id: string, Count: number } } = {}
		for cardId, count in currentDraftCards do
			if count > 0 then
				table.insert(sortedCards, { Id = cardId, Count = count })
			end
		end
		table.sort(sortedCards, function(a, b)
			return a.Id < b.Id
		end)

		for _, item in sortedCards do
			local cardDef = CardData.getCard(item.Id)
			local cardName = cardDef and cardDef.Name or item.Id
			local cost = cardDef and cardDef.Cost or 0
			local owned = cachedCollection[item.Id] or 0

			local row = Instance.new("Frame")
			row.Size = UDim2.new(1, -4, 0, 42)
			row.BackgroundColor3 = Color3.fromRGB(28, 32, 44)
			row.BorderSizePixel = 0
			row.ZIndex = 34
			row.Parent = draftCardsScroll
			UIFactory.createCorner(row, 6)
			UIFactory.createStroke(row, Color3.fromRGB(48, 56, 76), 1)

			local costBadge = Instance.new("TextLabel")
			costBadge.Size = UDim2.new(0, 24, 0, 24)
			costBadge.Position = UDim2.new(0, 8, 0.5, -12)
			costBadge.BackgroundColor3 = Color3.fromRGB(45, 105, 190)
			costBadge.BorderSizePixel = 0
			costBadge.Text = tostring(cost)
			costBadge.TextColor3 = Color3.fromRGB(255, 255, 255)
			costBadge.Font = Enum.Font.GothamBold
			costBadge.TextSize = 12
			costBadge.ZIndex = 35
			costBadge.Parent = row
			UIFactory.createCorner(costBadge, 12)

			local nameLabel = Instance.new("TextLabel")
			nameLabel.Size = UDim2.new(1, -160, 1, 0)
			nameLabel.Position = UDim2.new(0, 38, 0, 0)
			nameLabel.BackgroundTransparency = 1
			nameLabel.Text = cardName
			nameLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
			nameLabel.Font = Enum.Font.GothamBold
			nameLabel.TextSize = 13
			nameLabel.TextXAlignment = Enum.TextXAlignment.Left
			nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
			nameLabel.ZIndex = 35
			nameLabel.Parent = row

			local qtyLabel = Instance.new("TextLabel")
			qtyLabel.Size = UDim2.new(0, 30, 1, 0)
			qtyLabel.Position = UDim2.new(1, -116, 0, 0)
			qtyLabel.BackgroundTransparency = 1
			qtyLabel.Text = string.format("x%d", item.Count)
			qtyLabel.TextColor3 = Color3.fromRGB(255, 215, 80)
			qtyLabel.Font = Enum.Font.GothamBold
			qtyLabel.TextSize = 13
			qtyLabel.ZIndex = 35
			qtyLabel.Parent = row

			local plusBtn = Instance.new("TextButton")
			plusBtn.Size = UDim2.new(0, 24, 0, 24)
			plusBtn.Position = UDim2.new(1, -84, 0.5, -12)
			local canAdd = (totalCount < maxSize) and (item.Count < maxCopies) and (item.Count < owned)
			plusBtn.BackgroundColor3 = if canAdd then Color3.fromRGB(45, 125, 65) else Color3.fromRGB(45, 50, 60)
			plusBtn.BorderSizePixel = 0
			plusBtn.Text = "+"
			plusBtn.TextColor3 = if canAdd then Color3.fromRGB(255, 255, 255) else Color3.fromRGB(120, 125, 135)
			plusBtn.Font = Enum.Font.GothamBold
			plusBtn.TextSize = 14
			plusBtn.ZIndex = 35
			plusBtn.Parent = row
			UIFactory.createCorner(plusBtn, 4)
			if canAdd then
				plusBtn.MouseButton1Click:Connect(function()
					currentDraftCards[item.Id] = item.Count + 1
					renderDraftEditor()
					renderCollectionBrowser()
				end)
			end

			local minusBtn = Instance.new("TextButton")
			minusBtn.Size = UDim2.new(0, 24, 0, 24)
			minusBtn.Position = UDim2.new(1, -56, 0.5, -12)
			minusBtn.BackgroundColor3 = Color3.fromRGB(125, 75, 45)
			minusBtn.BorderSizePixel = 0
			minusBtn.Text = "-"
			minusBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
			minusBtn.Font = Enum.Font.GothamBold
			minusBtn.TextSize = 14
			minusBtn.ZIndex = 35
			minusBtn.Parent = row
			UIFactory.createCorner(minusBtn, 4)
			minusBtn.MouseButton1Click:Connect(function()
				if item.Count > 1 then
					currentDraftCards[item.Id] = item.Count - 1
				else
					currentDraftCards[item.Id] = nil
				end
				renderDraftEditor()
				renderCollectionBrowser()
			end)

			local delBtn = Instance.new("TextButton")
			delBtn.Size = UDim2.new(0, 24, 0, 24)
			delBtn.Position = UDim2.new(1, -28, 0.5, -12)
			delBtn.BackgroundColor3 = Color3.fromRGB(60, 35, 40)
			delBtn.BorderSizePixel = 0
			delBtn.Text = "✕"
			delBtn.TextColor3 = Color3.fromRGB(255, 120, 120)
			delBtn.Font = Enum.Font.GothamBold
			delBtn.TextSize = 12
			delBtn.ZIndex = 35
			delBtn.Parent = row
			UIFactory.createCorner(delBtn, 4)
			delBtn.MouseButton1Click:Connect(function()
				currentDraftCards[item.Id] = nil
				renderDraftEditor()
				renderCollectionBrowser()
			end)
		end
	end

	renderCollectionBrowser = function()
		for _, child in collectionScroll:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end

		local filter = string.lower(string.gsub(collectionFilterText, "^%s*(.-)%s*$", "%1"))
		local sortedIds: { string } = {}
		for cardId, count in cachedCollection do
			if count > 0 then
				local cardDef = CardData.getCard(cardId)
				local name = cardDef and cardDef.Name or cardId
				if filter == "" or string.find(string.lower(name), filter, 1, true) or string.find(string.lower(cardId), filter, 1, true) then
					table.insert(sortedIds, cardId)
				end
			end
		end
		table.sort(sortedIds, function(a, b)
			local defA = CardData.getCard(a)
			local defB = CardData.getCard(b)
			local costA = defA and defA.Cost or 0
			local costB = defB and defB.Cost or 0
			if costA ~= costB then return costA < costB end
			local nameA = defA and defA.Name or a
			local nameB = defB and defB.Name or b
			return nameA < nameB
		end)

		local totalDraft = countCards(currentDraftCards)
		local maxSize = GameConfig.Deck.MaxDeckSize
		local maxCopies = GameConfig.Deck.MaxCopiesPerCard

		for _, cardId in sortedIds do
			local owned = cachedCollection[cardId] or 0
			local inDraft = currentDraftCards[cardId] or 0
			local cardDef = CardData.getCard(cardId)
			local cardName = cardDef and cardDef.Name or cardId
			local cost = cardDef and cardDef.Cost or 0

			local item = Instance.new("Frame")
			item.Size = UDim2.new(1, -4, 0, 52)
			item.BackgroundColor3 = Color3.fromRGB(28, 32, 44)
			item.BorderSizePixel = 0
			item.ZIndex = 34
			item.Parent = collectionScroll
			UIFactory.createCorner(item, 6)
			UIFactory.createStroke(item, Color3.fromRGB(48, 56, 76), 1)

			local costBadge = Instance.new("TextLabel")
			costBadge.Size = UDim2.new(0, 22, 0, 22)
			costBadge.Position = UDim2.new(0, 6, 0, 6)
			costBadge.BackgroundColor3 = Color3.fromRGB(45, 105, 190)
			costBadge.BorderSizePixel = 0
			costBadge.Text = tostring(cost)
			costBadge.TextColor3 = Color3.fromRGB(255, 255, 255)
			costBadge.Font = Enum.Font.GothamBold
			costBadge.TextSize = 11
			costBadge.ZIndex = 35
			costBadge.Parent = item
			UIFactory.createCorner(costBadge, 11)

			local nameLabel = Instance.new("TextLabel")
			nameLabel.Size = UDim2.new(1, -110, 0, 20)
			nameLabel.Position = UDim2.new(0, 34, 0, 6)
			nameLabel.BackgroundTransparency = 1
			nameLabel.Text = cardName
			nameLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
			nameLabel.Font = Enum.Font.GothamBold
			nameLabel.TextSize = 12
			nameLabel.TextXAlignment = Enum.TextXAlignment.Left
			nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
			nameLabel.ZIndex = 35
			nameLabel.Parent = item

			local descLabel = Instance.new("TextLabel")
			descLabel.Size = UDim2.new(1, -110, 0, 16)
			descLabel.Position = UDim2.new(0, 34, 0, 28)
			descLabel.BackgroundTransparency = 1
			descLabel.Text = string.format("Owned: %d | In Deck: %d", owned, inDraft)
			descLabel.TextColor3 = Color3.fromRGB(160, 175, 195)
			descLabel.Font = Enum.Font.Gotham
			descLabel.TextSize = 10
			descLabel.TextXAlignment = Enum.TextXAlignment.Left
			descLabel.ZIndex = 35
			descLabel.Parent = item

			local canAdd = (currentEditedDeckId ~= nil)
				and (totalDraft < maxSize)
				and (inDraft < maxCopies)
				and (inDraft < owned)

			local addBtn = Instance.new("TextButton")
			addBtn.Size = UDim2.new(0, 64, 0, 32)
			addBtn.Position = UDim2.new(1, -70, 0.5, -16)
			addBtn.BackgroundColor3 = if canAdd then Color3.fromRGB(45, 140, 80) else Color3.fromRGB(40, 45, 55)
			addBtn.BorderSizePixel = 0
			addBtn.Text = if not currentEditedDeckId then "No Deck"
				elseif totalDraft >= maxSize then "Full"
				elseif inDraft >= maxCopies then "Max 3"
				elseif inDraft >= owned then "Limit"
				else "+ Add"
			addBtn.TextColor3 = if canAdd then Color3.fromRGB(255, 255, 255) else Color3.fromRGB(110, 120, 135)
			addBtn.Font = Enum.Font.GothamBold
			addBtn.TextSize = 11
			addBtn.ZIndex = 35
			addBtn.Parent = item
			UIFactory.createCorner(addBtn, 6)

			if canAdd then
				addBtn.MouseButton1Click:Connect(function()
					currentDraftCards[cardId] = inDraft + 1
					renderDraftEditor()
					renderCollectionBrowser()
				end)
			end
		end
	end

	-- Wire UI Actions
	UIFactory.createButton(createDeckBtnContainer, "+ NEW DECK", Color3.fromRGB(45, 140, 80), function()
		if isDeckActionPending then return end
		local totalDecks = 0
		for _ in cachedDecks do totalDecks += 1 end
		if totalDecks >= GameConfig.Deck.MaxDeckSlots then
			setDeckStatus("⚠️ Maximum deck slots reached.", Color3.fromRGB(255, 90, 90))
			return
		end
		isDeckActionPending = true
		setDeckStatus("Creating new deck...", Color3.fromRGB(200, 200, 200))
		if CreateDeckEvent then
			CreateDeckEvent:FireServer(string.format("Deck %d", totalDecks + 1), {}, "Warlord")
		end
	end)

	UIFactory.createButton(saveDraftBtnContainer, "💾 SAVE DECK", Color3.fromRGB(45, 140, 80), function()
		if isDeckActionPending then return end
		if not currentEditedDeckId then
			setDeckStatus("⚠️ No deck selected to save.", Color3.fromRGB(255, 90, 90))
			return
		end
		local total = countCards(currentDraftCards)
		if total < GameConfig.Deck.MinDeckSize then
			setDeckStatus(string.format("⚠️ Deck too small: %d/%d cards minimum.", total, GameConfig.Deck.MinDeckSize), Color3.fromRGB(255, 90, 90))
			return
		end
		if total > GameConfig.Deck.MaxDeckSize then
			setDeckStatus(string.format("⚠️ Deck too large: %d/%d cards maximum.", total, GameConfig.Deck.MaxDeckSize), Color3.fromRGB(255, 90, 90))
			return
		end
		for cardId, count in currentDraftCards do
			if count > GameConfig.Deck.MaxCopiesPerCard then
				setDeckStatus(string.format("⚠️ Max %d copies of %s.", GameConfig.Deck.MaxCopiesPerCard, cardId), Color3.fromRGB(255, 90, 90))
				return
			end
			local owned = cachedCollection[cardId] or 0
			if count > owned then
				setDeckStatus(string.format("⚠️ You only own %d of %s.", owned, cardId), Color3.fromRGB(255, 90, 90))
				return
			end
		end
		isDeckActionPending = true
		setDeckStatus("Saving deck to server...", Color3.fromRGB(200, 200, 200))
		if SaveDeckEvent then
			SaveDeckEvent:FireServer(currentEditedDeckId, currentDraftCards)
		end
	end)

	UIFactory.createButton(revertDraftBtnContainer, "↺ REVERT", Color3.fromRGB(50, 70, 100), function()
		currentDraftCards = deepCopyCards(originalDeckCards)
		setDeckStatus("Draft reverted to saved version.", Color3.fromRGB(180, 220, 255))
		renderDraftEditor()
		renderCollectionBrowser()
	end)

	UIFactory.createButton(clearDraftBtnContainer, "🗑 CLEAR", Color3.fromRGB(80, 45, 50), function()
		table.clear(currentDraftCards)
		setDeckStatus("Draft cleared.", Color3.fromRGB(255, 200, 100))
		renderDraftEditor()
		renderCollectionBrowser()
	end)

	collectionSearchBox:GetPropertyChangedSignal("Text"):Connect(function()
		collectionFilterText = collectionSearchBox.Text
		renderCollectionBrowser()
	end)

	UIFactory.createButton(renameConfirmBtnContainer, "CONFIRM", Color3.fromRGB(45, 140, 80), function()
		if isDeckActionPending or not pendingRenameDeckId then return end
		local name = string.gsub(renameInputBox.Text, "^%s*(.-)%s*$", "%1")
		if #name == 0 then
			setDeckStatus("⚠️ Deck name cannot be empty.", Color3.fromRGB(255, 90, 90))
			return
		end
		if #name > GameConfig.Deck.MaxDeckNameLength then
			setDeckStatus(string.format("⚠️ Name too long (max %d).", GameConfig.Deck.MaxDeckNameLength), Color3.fromRGB(255, 90, 90))
			return
		end
		isDeckActionPending = true
		setDeckStatus("Renaming deck...", Color3.fromRGB(200, 200, 200))
		if RenameDeckEvent then
			RenameDeckEvent:FireServer(pendingRenameDeckId, name)
		end
		renameModalFrame.Visible = false
		pendingRenameDeckId = nil
	end)

	UIFactory.createButton(renameCancelBtnContainer, "CANCEL", Color3.fromRGB(60, 65, 80), function()
		renameModalFrame.Visible = false
		pendingRenameDeckId = nil
	end)

	local function toggleDeckBuilder()
		deckBuilderView.Visible = not deckBuilderView.Visible
		if deckBuilderView.Visible then
			if RequestDecksEvent then
				RequestDecksEvent:FireServer()
			end
			if RequestCardCollectionEvent then
				RequestCardCollectionEvent:FireServer()
			end
			renderDecksList()
			renderDraftEditor()
			renderCollectionBrowser()
		end
	end

	return {
		View = deckBuilderView,
		toggle = toggleDeckBuilder,
		show = function()
			deckBuilderView.Visible = true
			if RequestDecksEvent then
				RequestDecksEvent:FireServer()
			end
			if RequestCardCollectionEvent then
				RequestCardCollectionEvent:FireServer()
			end
			renderDecksList()
			renderDraftEditor()
			renderCollectionBrowser()
		end,
		hide = function()
			deckBuilderView.Visible = false
		end,
		onDeckListUpdate = function(decks: { StateTypes.DeckSummaryView }, activeDeckId: string)
			cachedActiveDeckId = activeDeckId or ""
			table.clear(cachedDecks)
			for _, d in decks do
				cachedDecks[d.DeckId] = d
				if d.Cards and not deckDetailCache[d.DeckId] then
					deckDetailCache[d.DeckId] = d.Cards
				end
			end

			if not currentEditedDeckId or not cachedDecks[currentEditedDeckId] then
				local targetId = if (activeDeckId and cachedDecks[activeDeckId])
					then activeDeckId
					else (decks[1] and decks[1].DeckId or nil)
				if targetId then
					currentEditedDeckId = targetId
					local cards = deckDetailCache[targetId] or (cachedDecks[targetId] and cachedDecks[targetId].Cards) or {}
					originalDeckCards = deepCopyCards(cards)
					currentDraftCards = deepCopyCards(originalDeckCards)
				end
			end

			renderDecksList()
			renderDraftEditor()
			renderCollectionBrowser()
		end,
		onDeckDetailUpdate = function(detail: StateTypes.DeckDetailView)
			if not detail or not detail.DeckId then return end
			deckDetailCache[detail.DeckId] = detail.Cards
			if cachedDecks[detail.DeckId] then
				cachedDecks[detail.DeckId].Cards = detail.Cards
				cachedDecks[detail.DeckId].CardCount = detail.CardCount
			end

			if detail.DeckId == currentEditedDeckId then
				local hasEdits = false
				for k, v in currentDraftCards do
					if originalDeckCards[k] ~= v then hasEdits = true break end
				end
				for k in originalDeckCards do
					if not currentDraftCards[k] then hasEdits = true break end
				end

				originalDeckCards = deepCopyCards(detail.Cards)
				if not hasEdits then
					currentDraftCards = deepCopyCards(detail.Cards)
				end
				renderDraftEditor()
				renderCollectionBrowser()
			end
			renderDecksList()
		end,
		onCardCollectionUpdate = function(collectionView: StateTypes.CardCollectionView)
			if not collectionView or not collectionView.Cards then return end
			table.clear(cachedCollection)
			for k, v in collectionView.Cards do
				cachedCollection[k] = v
			end
			renderCollectionBrowser()
			renderDraftEditor()
		end,
		handleActionResult = function(res: any): boolean
			if res.Action == "CreateDeck" then
				isDeckActionPending = false
				if res.Success then
					setDeckStatus("✅ Deck created successfully!", Color3.fromRGB(80, 220, 120))
				else
					setDeckStatus(string.format("⚠️ Create failed: %s", tostring(res.Message or "Unknown error")), Color3.fromRGB(255, 90, 90))
				end
				return true
			elseif res.Action == "RenameDeck" then
				isDeckActionPending = false
				if res.Success then
					setDeckStatus("✅ Deck renamed successfully!", Color3.fromRGB(80, 220, 120))
				else
					setDeckStatus(string.format("⚠️ Rename failed: %s", tostring(res.Message or "Unknown error")), Color3.fromRGB(255, 90, 90))
				end
				return true
			elseif res.Action == "DeleteDeck" then
				isDeckActionPending = false
				if res.Success then
					setDeckStatus("✅ Deck deleted successfully.", Color3.fromRGB(80, 220, 120))
					if currentEditedDeckId and not cachedDecks[currentEditedDeckId] then
						currentEditedDeckId = cachedActiveDeckId
						if currentEditedDeckId and cachedDecks[currentEditedDeckId] then
							local cards = deckDetailCache[currentEditedDeckId] or cachedDecks[currentEditedDeckId].Cards or {}
							originalDeckCards = deepCopyCards(cards)
							currentDraftCards = deepCopyCards(originalDeckCards)
						end
					end
					renderDecksList()
					renderDraftEditor()
					renderCollectionBrowser()
				else
					setDeckStatus(string.format("⚠️ Delete failed: %s", tostring(res.Message or "Unknown error")), Color3.fromRGB(255, 90, 90))
				end
				return true
			elseif res.Action == "SaveDeck" then
				isDeckActionPending = false
				if res.Success then
					originalDeckCards = deepCopyCards(currentDraftCards)
					setDeckStatus("✅ Deck saved successfully!", Color3.fromRGB(80, 220, 120))
				else
					setDeckStatus(string.format("⚠️ Save failed: %s", tostring(res.Message or "Unknown error")), Color3.fromRGB(255, 90, 90))
				end
				renderDraftEditor()
				renderCollectionBrowser()
				return true
			elseif res.Action == "DuplicateDeck" then
				isDeckActionPending = false
				if res.Success then
					setDeckStatus("✅ Deck duplicated successfully!", Color3.fromRGB(80, 220, 120))
				else
					setDeckStatus(string.format("⚠️ Duplicate failed: %s", tostring(res.Message or "Unknown error")), Color3.fromRGB(255, 90, 90))
				end
				return true
			elseif res.Action == "SelectActiveDeck" then
				isDeckActionPending = false
				if res.Success then
					setDeckStatus("✅ Active deck updated!", Color3.fromRGB(80, 220, 120))
				else
					setDeckStatus(string.format("⚠️ Select active failed: %s", tostring(res.Message or "Unknown error")), Color3.fromRGB(255, 90, 90))
				end
				return true
			end
			return false
		end,
	}
end

local DeckBuilder = createDeckBuilderController()

UIFactory.createButton(deckBuilderBtnContainer, "🎴 DECK BUILDER", Color3.fromRGB(50, 110, 200), function()
	DeckBuilder.toggle()
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
local submittedReactionWindowId: string? = nil
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
	submittedReactionWindowId = winId
	activeReactionWindowId = nil -- Prevent multiple local submissions
	currentReactionWindowView = nil
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
-- VIEW 7: Campfire Rest View
--------------------------------------------------------------------------------

local campfireView = Instance.new("Frame")
campfireView.Name = "CampfireView"
campfireView.Size = UDim2.new(0, 560, 0, 360)
campfireView.Position = UDim2.new(0.5, -280, 0.5, -180)
campfireView.BackgroundColor3 = Color3.fromRGB(24, 18, 16)
campfireView.BackgroundTransparency = 0.1
campfireView.BorderSizePixel = 0
campfireView.Visible = false
campfireView.ZIndex = 15
campfireView.Parent = mainFrame
UIFactory.createCorner(campfireView, 14)
UIFactory.createStroke(campfireView, Color3.fromRGB(230, 110, 40), 2.5)

local campfireHeader = Instance.new("Frame")
campfireHeader.Size = UDim2.new(1, 0, 0, 55)
campfireHeader.BackgroundColor3 = Color3.fromRGB(36, 22, 18)
campfireHeader.BorderSizePixel = 0
campfireHeader.ZIndex = 16
campfireHeader.Parent = campfireView
UIFactory.createCorner(campfireHeader, 14)

local campfireTitle = Instance.new("TextLabel")
campfireTitle.Size = UDim2.new(1, -40, 0, 30)
campfireTitle.Position = UDim2.new(0, 20, 0, 12)
campfireTitle.BackgroundTransparency = 1
campfireTitle.Text = "🔥 CAMPFIRE GROVE"
campfireTitle.TextColor3 = Color3.fromRGB(255, 170, 70)
campfireTitle.Font = Enum.Font.GothamBold
campfireTitle.TextSize = 20
campfireTitle.TextXAlignment = Enum.TextXAlignment.Left
campfireTitle.ZIndex = 17
campfireTitle.Parent = campfireHeader

local campfireDesc = Instance.new("TextLabel")
campfireDesc.Size = UDim2.new(1, -40, 0, 70)
campfireDesc.Position = UDim2.new(0, 20, 0, 75)
campfireDesc.BackgroundTransparency = 1
campfireDesc.Text = "The warm embers of the grove offer solace amidst the rift.\nResting here will restore 30% of each hero's Max HP."
campfireDesc.TextColor3 = Color3.fromRGB(220, 200, 180)
campfireDesc.Font = Enum.Font.Gotham
campfireDesc.TextSize = 15
campfireDesc.TextWrapped = true
campfireDesc.TextXAlignment = Enum.TextXAlignment.Center
campfireDesc.ZIndex = 17
campfireDesc.Parent = campfireView

local campfireRestBtn = UIFactory.createButton(campfireView, "🔥 Rest by the Fire (+30% HP)", Color3.fromRGB(200, 75, 25), function()
	if CampfireChoiceEvent then
		CampfireChoiceEvent:FireServer("Rest")
	end
end)
campfireRestBtn.Size = UDim2.new(0, 300, 0, 48)
campfireRestBtn.Position = UDim2.new(0.5, -150, 0, 165)
campfireRestBtn.ZIndex = 17

local campfireLeaveBtn = UIFactory.createButton(campfireView, "Continue Expedition ➔", Color3.fromRGB(70, 70, 85), function()
	if CampfireChoiceEvent then
		CampfireChoiceEvent:FireServer("Leave")
	end
end)
campfireLeaveBtn.Size = UDim2.new(0, 260, 0, 40)
campfireLeaveBtn.Position = UDim2.new(0.5, -130, 0, 230)
campfireLeaveBtn.ZIndex = 17

--------------------------------------------------------------------------------
-- VIEW 8: Merchant Bazaar View
--------------------------------------------------------------------------------

local merchantView = Instance.new("Frame")
merchantView.Name = "MerchantView"
merchantView.Size = UDim2.new(0, 680, 0, 460)
merchantView.Position = UDim2.new(0.5, -340, 0.5, -230)
merchantView.BackgroundColor3 = Color3.fromRGB(18, 22, 28)
merchantView.BackgroundTransparency = 0.1
merchantView.BorderSizePixel = 0
merchantView.Visible = false
merchantView.ZIndex = 15
merchantView.Parent = mainFrame
UIFactory.createCorner(merchantView, 14)
UIFactory.createStroke(merchantView, Color3.fromRGB(215, 175, 45), 2.5)

local merchantHeader = Instance.new("Frame")
merchantHeader.Size = UDim2.new(1, 0, 0, 55)
merchantHeader.BackgroundColor3 = Color3.fromRGB(26, 32, 42)
merchantHeader.BorderSizePixel = 0
merchantHeader.ZIndex = 16
merchantHeader.Parent = merchantView
UIFactory.createCorner(merchantHeader, 14)

local merchantTitle = Instance.new("TextLabel")
merchantTitle.Size = UDim2.new(0, 300, 0, 30)
merchantTitle.Position = UDim2.new(0, 20, 0, 12)
merchantTitle.BackgroundTransparency = 1
merchantTitle.Text = "💰 RIFT MERCHANT BAZAAR"
merchantTitle.TextColor3 = Color3.fromRGB(255, 215, 80)
merchantTitle.Font = Enum.Font.GothamBold
merchantTitle.TextSize = 20
merchantTitle.TextXAlignment = Enum.TextXAlignment.Left
merchantTitle.ZIndex = 17
merchantTitle.Parent = merchantHeader

local merchantGoldLabel = Instance.new("TextLabel")
merchantGoldLabel.Size = UDim2.new(0, 200, 0, 30)
merchantGoldLabel.Position = UDim2.new(1, -220, 0, 12)
merchantGoldLabel.BackgroundTransparency = 1
merchantGoldLabel.Text = "Gold: 0 🪙"
merchantGoldLabel.TextColor3 = Color3.fromRGB(255, 230, 100)
merchantGoldLabel.Font = Enum.Font.GothamBold
merchantGoldLabel.TextSize = 16
merchantGoldLabel.TextXAlignment = Enum.TextXAlignment.Right
merchantGoldLabel.ZIndex = 17
merchantGoldLabel.Parent = merchantHeader

local waresContainer = Instance.new("Frame")
waresContainer.Size = UDim2.new(1, -40, 0, 300)
waresContainer.Position = UDim2.new(0, 20, 0, 70)
waresContainer.BackgroundTransparency = 1
waresContainer.ZIndex = 16
waresContainer.Parent = merchantView

local waresLayout = Instance.new("UIGridLayout")
waresLayout.CellSize = UDim2.new(0.48, 0, 0, 135)
waresLayout.CellPadding = UDim2.new(0.04, 0, 0, 12)
waresLayout.SortOrder = Enum.SortOrder.LayoutOrder
waresLayout.Parent = waresContainer

local merchantLeaveBtn = UIFactory.createButton(merchantView, "Leave Shop ➔", Color3.fromRGB(60, 65, 80), function()
	if ExitMerchantEvent then
		ExitMerchantEvent:FireServer()
	end
end)
merchantLeaveBtn.Size = UDim2.new(0, 220, 0, 40)
merchantLeaveBtn.Position = UDim2.new(0.5, -110, 1, -50)
merchantLeaveBtn.ZIndex = 17

local function renderMerchantWares(wares: { StateTypes.MerchantItemView }?, playerGold: number)
	merchantGoldLabel.Text = string.format("Gold: %d 🪙", playerGold)
	for _, child in waresContainer:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	if not wares then return end

	for _, item in wares do
		local cardFrame = Instance.new("Frame")
		cardFrame.BackgroundColor3 = if item.IsPurchased then Color3.fromRGB(25, 28, 32) else Color3.fromRGB(30, 36, 46)
		cardFrame.BorderSizePixel = 0
		cardFrame.ZIndex = 17
		cardFrame.Parent = waresContainer
		UIFactory.createCorner(cardFrame, 10)
		UIFactory.createStroke(cardFrame, if item.IsPurchased then Color3.fromRGB(60, 60, 60) else Color3.fromRGB(90, 110, 140), 1.5)

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Size = UDim2.new(1, -16, 0, 22)
		nameLabel.Position = UDim2.new(0, 8, 0, 6)
		nameLabel.BackgroundTransparency = 1
		nameLabel.Text = item.Name
		nameLabel.TextColor3 = if item.IsPurchased then Color3.fromRGB(130, 130, 130) else Color3.fromRGB(240, 240, 240)
		nameLabel.Font = Enum.Font.GothamBold
		nameLabel.TextSize = 13
		nameLabel.TextXAlignment = Enum.TextXAlignment.Left
		nameLabel.ZIndex = 18
		nameLabel.Parent = cardFrame

		local descLabel = Instance.new("TextLabel")
		descLabel.Size = UDim2.new(1, -16, 0, 48)
		descLabel.Position = UDim2.new(0, 8, 0, 28)
		descLabel.BackgroundTransparency = 1
		descLabel.Text = item.Description
		descLabel.TextColor3 = if item.IsPurchased then Color3.fromRGB(110, 110, 110) else Color3.fromRGB(180, 190, 200)
		descLabel.Font = Enum.Font.Gotham
		descLabel.TextSize = 11
		descLabel.TextWrapped = true
		descLabel.TextXAlignment = Enum.TextXAlignment.Left
		descLabel.ZIndex = 18
		descLabel.Parent = cardFrame

		local btnText = if item.IsPurchased then "PURCHASED" else string.format("Buy (%d Gold)", item.Cost)
		local canAfford = playerGold >= item.Cost and not item.IsPurchased
		local btnColor = if item.IsPurchased then Color3.fromRGB(50, 50, 50) elseif canAfford then Color3.fromRGB(45, 135, 75) else Color3.fromRGB(80, 60, 60)
		local buyBtn = UIFactory.createButton(cardFrame, btnText, btnColor, function()
			if not item.IsPurchased and canAfford and BuyMerchantItemEvent then
				BuyMerchantItemEvent:FireServer(item.ItemId)
			end
		end)
		buyBtn.Size = UDim2.new(1, -16, 0, 28)
		buyBtn.Position = UDim2.new(0, 8, 1, -34)
		buyBtn.Active = canAfford
		buyBtn.ZIndex = 18
	end
end

--------------------------------------------------------------------------------
-- Central View Switcher
--------------------------------------------------------------------------------

local function switchView(phase: StateTypes.RunPhase, roomType: StateTypes.ActiveRoomType?)
	lobbyView.Visible = (phase == "Lobby")
	mapView.Visible = (phase == "MapSelect")
	rewardsView.Visible = (phase == "Rewards")
	victoryView.Visible = (phase == "RunVictory")
	defeatView.Visible = (phase == "RunDefeat")

	if phase ~= "Lobby" and DeckBuilder then
		DeckBuilder.hide()
	end

	local isCombat = (roomType == "Combat" or roomType == "Elite Monster" or roomType == "Act Boss")
	local isCampfire = (roomType == "Campfire Rest")
	local isMerchant = (roomType == "Merchant Shop")
	local isEvent = (roomType == "Event")

	if phase == "ActiveRoom" then
		combatHudView.Visible = isCombat and not isCampfire and not isMerchant and not isEvent
		eventChamberView.Visible = isEvent
		campfireView.Visible = isCampfire
		merchantView.Visible = isMerchant

		if not isCombat and not isCampfire and not isMerchant and not isEvent then
			bannerLabel.Text = "Synchronizing room state..."
			bannerLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
			if RequestStateSyncEvent then
				RequestStateSyncEvent:FireServer()
			end
		end
	else
		combatHudView.Visible = false
		eventChamberView.Visible = false
		campfireView.Visible = false
		merchantView.Visible = false
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

		local activeRoomType = snapshot.ActiveRoom and snapshot.ActiveRoom.Type or nil
		print(string.format("[MAPFLOW][CLIENT] 18. switchView called: TargetPhase=%s, RoomType=%s", tostring(snapshot.Phase), tostring(activeRoomType)))
		switchView(snapshot.Phase, activeRoomType)
		print(string.format("[MAPFLOW][CLIENT] 19. MapVisible updated: MapVisible=%s", tostring(mapView.Visible)))
		print(string.format("[MAPFLOW][CLIENT] 20. CombatVisible updated: CombatVisible=%s", tostring(combatHudView.Visible)))

		if snapshot.Phase == "Lobby" then
			bannerLabel.Text = "Lobby: Gather heroes and start run."
		elseif snapshot.Phase == "MapSelect" then
			bannerLabel.Text = "Map Selection: Select reachable room to proceed."
			buildDungeonMapTree(snapshot)
		elseif snapshot.Phase == "ActiveRoom" then
			local roomType = snapshot.ActiveRoom and snapshot.ActiveRoom.Type or nil
			if roomType == "Campfire Rest" then
				combatHudView.Visible = false
				eventChamberView.Visible = false
				merchantView.Visible = false
				campfireView.Visible = true
				bannerLabel.Text = "Campfire Grove: Rest and recover."
				bannerLabel.TextColor3 = Color3.fromRGB(255, 170, 70)
			elseif roomType == "Merchant Shop" then
				combatHudView.Visible = false
				eventChamberView.Visible = false
				campfireView.Visible = false
				merchantView.Visible = true
				bannerLabel.Text = "Merchant Bazaar: Browse wares and gear."
				bannerLabel.TextColor3 = Color3.fromRGB(255, 215, 80)
				local localPView = snapshot.Party[tostring(localPlayer.UserId)]
				local playerGold = localPView and localPView.Gold or 0
				renderMerchantWares(snapshot.ActiveRoom and snapshot.ActiveRoom.MerchantWares, playerGold)
			elseif roomType == "Event" or (snapshot.Event ~= nil and not snapshot.Event.IsCompleted) then
				combatHudView.Visible = false
				campfireView.Visible = false
				merchantView.Visible = false
				eventChamberView.Visible = true
				if snapshot.Event then
					renderEventChamber(snapshot.Event)
					bannerLabel.Text = string.format("Event Chamber: %s", snapshot.Event.Name)
				end
			elseif roomType == "Combat" or roomType == "Elite Monster" or roomType == "Act Boss" then
				combatHudView.Visible = true
				eventChamberView.Visible = false
				campfireView.Visible = false
				merchantView.Visible = false
				bannerLabel.Text = if roomType == "Combat" then "Entered Room: Combat" else string.format("Entered Room: %s", roomType)
				bannerLabel.TextColor3 = Color3.fromRGB(240, 240, 240)
			else
				combatHudView.Visible = false
				eventChamberView.Visible = false
				campfireView.Visible = false
				merchantView.Visible = false
				bannerLabel.Text = "Synchronizing room state..."
				bannerLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
				if RequestStateSyncEvent then
					RequestStateSyncEvent:FireServer()
				end
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
			if win.WindowId == submittedReactionWindowId then
				-- Player has already submitted a reaction for this window; suppress reopening prompt
				reactionWidget.Visible = false
			elseif activeReactionWindowId ~= win.WindowId then
				submittedReactionWindowId = nil
				activeReactionWindowId = win.WindowId
				currentReactionWindowView = win
				startReactionOpportunity(win)
			end
		else
			activeReactionWindowId = nil
			currentReactionWindowView = nil
			submittedReactionWindowId = nil
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
		elseif DeckBuilder and DeckBuilder.handleActionResult(res) then
			-- Handled by DeckBuilder
		elseif res.Success == false then
			bannerLabel.Text = string.format("⚠️ %s: %s", res.Action or "Action", res.Message or "Action failed.")
			bannerLabel.TextColor3 = Color3.fromRGB(255, 90, 90)
		elseif res.Action == "ReturnToLobby" and res.Success == true then
			switchView("Lobby")
		end
	end)
end

-- 6. Deck & Collection Event Listeners (Phase 4)
if DeckListUpdateEvent then
	DeckListUpdateEvent.OnClientEvent:Connect(function(decks: { StateTypes.DeckSummaryView }, activeDeckId: string)
		if DeckBuilder then
			DeckBuilder.onDeckListUpdate(decks, activeDeckId)
		end
	end)
end

if DeckDetailUpdateEvent then
	DeckDetailUpdateEvent.OnClientEvent:Connect(function(detail: StateTypes.DeckDetailView)
		if DeckBuilder then
			DeckBuilder.onDeckDetailUpdate(detail)
		end
	end)
end

if CardCollectionUpdateEvent then
	CardCollectionUpdateEvent.OnClientEvent:Connect(function(collectionView: StateTypes.CardCollectionView)
		if DeckBuilder then
			DeckBuilder.onCardCollectionUpdate(collectionView)
		end
	end)
end

-- Request initial state sync, deck list, and card collection on mount
task.delay(0.5, function()
	if RequestStateSyncEvent then
		RequestStateSyncEvent:FireServer()
	end
	if RequestDecksEvent then
		RequestDecksEvent:FireServer()
	end
	if RequestCardCollectionEvent then
		RequestCardCollectionEvent:FireServer()
	end
end)

screenGui.Parent = playerGui
print("[UIController] Card Rift UIController mounted with GameNetwork architecture.")
