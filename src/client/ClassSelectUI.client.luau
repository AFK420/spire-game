--!strict

--[=[
	ClassSelectUI LocalScript
	Mapped to: StarterPlayer.StarterPlayerScripts.Client.ClassSelectUI
	Lobby class selection screen for Card Rift: Co-op Dungeon:
	1. Displays an interactive lobby showcase for all 10 core classes.
	2. Shows class stats (Max HP, Starting Energy), descriptions, and combat gimmicks.
	3. Provides toggle buttons for selecting between the 2 specialized subclasses.
	4. Fires secure RemoteEvents to ClassService via GameNetwork when locking in selections.
	5. Automatically hides during active dungeon runs and reappears in the Lobby.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ClassData = require(Shared:WaitForChild("ClassData") :: ModuleScript)

--------------------------------------------------------------------------------
-- Remote Events Resolution via GameNetwork
--------------------------------------------------------------------------------

local function findEvent(eventName: string): RemoteEvent?
	local networkFolder = ReplicatedStorage:WaitForChild("GameNetwork", 15) :: Folder?
	if networkFolder then
		local ev = networkFolder:WaitForChild(eventName, 10)
		if ev and ev:IsA("RemoteEvent") then
			return ev
		end
	end
	return nil
end

local SelectClassEvent = findEvent("SelectClass")
local RunStateUpdateEvent = findEvent("RunStateUpdate")
local RequestStateSyncEvent = findEvent("RequestStateSync")

--------------------------------------------------------------------------------
-- UI Creation Helpers
--------------------------------------------------------------------------------

local function createCorner(parent: Instance, radius: number): UICorner
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
	return corner
end

local function createStroke(parent: Instance, color: Color3, thickness: number): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = parent
	return stroke
end

--------------------------------------------------------------------------------
-- ScreenGui Setup (Dedicated CardRiftClassSelectGui)
--------------------------------------------------------------------------------

local mainGui: ScreenGui
local existing = playerGui:FindFirstChild("CardRiftClassSelectGui")
if existing and existing:IsA("ScreenGui") then
	mainGui = existing
	mainGui:ClearAllChildren()
else
	local newGui = Instance.new("ScreenGui")
	newGui.Name = "CardRiftClassSelectGui"
	newGui.ResetOnSpawn = false
	newGui.DisplayOrder = 20
	newGui.Parent = playerGui
	mainGui = newGui
end

--------------------------------------------------------------------------------
-- Class Select Main Modal Frame
--------------------------------------------------------------------------------

local modal = Instance.new("Frame")
modal.Name = "ClassSelectModal"
modal.Size = UDim2.new(0.92, 0, 0.88, 0)
modal.Position = UDim2.new(0.5, 0, 0.5, 0)
modal.AnchorPoint = Vector2.new(0.5, 0.5)
modal.BackgroundColor3 = Color3.fromRGB(14, 16, 24)
modal.BackgroundTransparency = 0.05
modal.BorderSizePixel = 0
modal.Visible = true -- Default visible in Lobby
modal.Parent = mainGui

createCorner(modal, 12)
createStroke(modal, Color3.fromRGB(60, 80, 115), 2)

-- Header Bar
local header = Instance.new("Frame")
header.Name = "Header"
header.Size = UDim2.new(1, 0, 0, 56)
header.BackgroundColor3 = Color3.fromRGB(20, 24, 36)
header.BorderSizePixel = 0
header.Parent = modal
createCorner(header, 12)

local titleLabel = Instance.new("TextLabel")
titleLabel.Name = "Title"
titleLabel.Size = UDim2.new(1, -32, 0, 28)
titleLabel.Position = UDim2.new(0, 16, 0, 6)
titleLabel.BackgroundTransparency = 1
titleLabel.Text = "CHOOSE YOUR HERO CLASS"
titleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
titleLabel.Font = Enum.Font.GothamBlack
titleLabel.TextSize = 18
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Parent = header

local subtitleLabel = Instance.new("TextLabel")
subtitleLabel.Name = "Subtitle"
subtitleLabel.Size = UDim2.new(1, -32, 0, 18)
subtitleLabel.Position = UDim2.new(0, 16, 0, 32)
subtitleLabel.BackgroundTransparency = 1
subtitleLabel.Text = "Select 1 of 10 core classes and customize your subclass before descending into the Spire."
subtitleLabel.TextColor3 = Color3.fromRGB(160, 180, 210)
subtitleLabel.Font = Enum.Font.Gotham
subtitleLabel.TextSize = 11
subtitleLabel.TextXAlignment = Enum.TextXAlignment.Left
subtitleLabel.Parent = header

-- Main Body Split: Left (Class List Carousel) & Right (Class Inspector)
local body = Instance.new("Frame")
body.Name = "Body"
body.Size = UDim2.new(1, -24, 1, -80)
body.Position = UDim2.new(0, 12, 0, 68)
body.BackgroundTransparency = 1
body.Parent = modal

--------------------------------------------------------------------------------
-- Left: Class Cards Scroller
--------------------------------------------------------------------------------

local leftScroller = Instance.new("ScrollingFrame")
leftScroller.Name = "ClassScroller"
leftScroller.Size = UDim2.new(0.42, 0, 1, 0)
leftScroller.Position = UDim2.new(0, 0, 0, 0)
leftScroller.BackgroundColor3 = Color3.fromRGB(18, 20, 30)
leftScroller.BackgroundTransparency = 0.5
leftScroller.BorderSizePixel = 0
leftScroller.ScrollBarThickness = 4
leftScroller.ScrollBarImageColor3 = Color3.fromRGB(80, 140, 220)
leftScroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
leftScroller.CanvasSize = UDim2.new(0, 0, 0, 0)
leftScroller.Parent = body

createCorner(leftScroller, 8)
createStroke(leftScroller, Color3.fromRGB(40, 50, 70), 1)

local classListLayout = Instance.new("UIListLayout")
classListLayout.FillDirection = Enum.FillDirection.Vertical
classListLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
classListLayout.Padding = UDim.new(0, 6)
classListLayout.SortOrder = Enum.SortOrder.LayoutOrder
classListLayout.Parent = leftScroller

local classListPadding = Instance.new("UIPadding")
classListPadding.PaddingTop = UDim.new(0, 8)
classListPadding.PaddingBottom = UDim.new(0, 8)
classListPadding.PaddingLeft = UDim.new(0, 8)
classListPadding.PaddingRight = UDim.new(0, 8)
classListPadding.Parent = leftScroller

--------------------------------------------------------------------------------
-- Right: Class Inspector & Subclass Selector
--------------------------------------------------------------------------------

local rightInspector = Instance.new("Frame")
rightInspector.Name = "ClassInspector"
rightInspector.Size = UDim2.new(0.56, 0, 1, 0)
rightInspector.Position = UDim2.new(0.44, 0, 0, 0)
rightInspector.BackgroundColor3 = Color3.fromRGB(20, 23, 34)
rightInspector.BackgroundTransparency = 0.2
rightInspector.BorderSizePixel = 0
rightInspector.Parent = body

createCorner(rightInspector, 8)
local inspectorStroke = createStroke(rightInspector, Color3.fromRGB(55, 75, 110), 1.5)

-- Inspector Header (Large Icon, Name, Stats)
local inspIcon = Instance.new("TextLabel")
inspIcon.Name = "HeroIcon"
inspIcon.Size = UDim2.new(0, 48, 0, 48)
inspIcon.Position = UDim2.new(0, 16, 0, 14)
inspIcon.BackgroundTransparency = 1
inspIcon.Text = "⚔️"
inspIcon.TextSize = 34
inspIcon.Parent = rightInspector

local inspTitle = Instance.new("TextLabel")
inspTitle.Name = "HeroTitle"
inspTitle.Size = UDim2.new(1, -160, 0, 26)
inspTitle.Position = UDim2.new(0, 70, 0, 14)
inspTitle.BackgroundTransparency = 1
inspTitle.Text = "Warlord"
inspTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
inspTitle.Font = Enum.Font.GothamBold
inspTitle.TextSize = 18
inspTitle.TextXAlignment = Enum.TextXAlignment.Left
inspTitle.Parent = rightInspector

local inspStats = Instance.new("TextLabel")
inspStats.Name = "HeroStats"
inspStats.Size = UDim2.new(1, -160, 0, 18)
inspStats.Position = UDim2.new(0, 70, 0, 40)
inspStats.BackgroundTransparency = 1
inspStats.Text = "❤️ 110 Max HP   |   ⚡ 3 Starting Energy"
inspStats.TextColor3 = Color3.fromRGB(180, 210, 255)
inspStats.Font = Enum.Font.GothamMedium
inspStats.TextSize = 11
inspStats.TextXAlignment = Enum.TextXAlignment.Left
inspStats.Parent = rightInspector

-- Class Description
local inspDesc = Instance.new("TextLabel")
inspDesc.Name = "HeroDesc"
inspDesc.Size = UDim2.new(1, -32, 0, 36)
inspDesc.Position = UDim2.new(0, 16, 0, 68)
inspDesc.BackgroundTransparency = 1
inspDesc.Text = "Class description goes here."
inspDesc.TextColor3 = Color3.fromRGB(200, 215, 235)
inspDesc.Font = Enum.Font.Gotham
inspDesc.TextSize = 11
inspDesc.TextWrapped = true
inspDesc.TextXAlignment = Enum.TextXAlignment.Left
inspDesc.TextYAlignment = Enum.TextYAlignment.Top
inspDesc.Parent = rightInspector

-- Gimmick Card Container
local gimmickBox = Instance.new("Frame")
gimmickBox.Name = "GimmickBox"
gimmickBox.Size = UDim2.new(1, -32, 0, 64)
gimmickBox.Position = UDim2.new(0, 16, 0, 108)
gimmickBox.BackgroundColor3 = Color3.fromRGB(28, 32, 48)
gimmickBox.BorderSizePixel = 0
gimmickBox.Parent = rightInspector

createCorner(gimmickBox, 8)
createStroke(gimmickBox, Color3.fromRGB(75, 95, 140), 1)

local gimmickTitle = Instance.new("TextLabel")
gimmickTitle.Name = "GimmickTitle"
gimmickTitle.Size = UDim2.new(1, -16, 0, 18)
gimmickTitle.Position = UDim2.new(0, 8, 0, 6)
gimmickTitle.BackgroundTransparency = 1
gimmickTitle.Text = "⚡ COMBAT GIMMICK: Rage"
gimmickTitle.TextColor3 = Color3.fromRGB(255, 215, 60)
gimmickTitle.Font = Enum.Font.GothamBold
gimmickTitle.TextSize = 12
gimmickTitle.TextXAlignment = Enum.TextXAlignment.Left
gimmickTitle.Parent = gimmickBox

local gimmickDesc = Instance.new("TextLabel")
gimmickDesc.Name = "GimmickDesc"
gimmickDesc.Size = UDim2.new(1, -16, 0, 34)
gimmickDesc.Position = UDim2.new(0, 8, 0, 24)
gimmickDesc.BackgroundTransparency = 1
gimmickDesc.Text = "Gimmick effect explanation."
gimmickDesc.TextColor3 = Color3.fromRGB(215, 230, 250)
gimmickDesc.Font = Enum.Font.Gotham
gimmickDesc.TextSize = 10
gimmickDesc.TextWrapped = true
gimmickDesc.TextXAlignment = Enum.TextXAlignment.Left
gimmickDesc.TextYAlignment = Enum.TextYAlignment.Top
gimmickDesc.Parent = gimmickBox

-- Subclasses Header
local subHeader = Instance.new("TextLabel")
subHeader.Name = "SubclassHeader"
subHeader.Size = UDim2.new(1, -32, 0, 18)
subHeader.Position = UDim2.new(0, 16, 0, 180)
subHeader.BackgroundTransparency = 1
subHeader.Text = "SELECT YOUR SUBCLASS:"
subHeader.TextColor3 = Color3.fromRGB(160, 185, 220)
subHeader.Font = Enum.Font.GothamBold
subHeader.TextSize = 11
subHeader.TextXAlignment = Enum.TextXAlignment.Left
subHeader.Parent = rightInspector

-- Subclass Toggle Container
local subContainer = Instance.new("Frame")
subContainer.Name = "SubclassContainer"
subContainer.Size = UDim2.new(1, -32, 0, 80)
subContainer.Position = UDim2.new(0, 16, 0, 202)
subContainer.BackgroundTransparency = 1
subContainer.Parent = rightInspector

local subLayout = Instance.new("UIListLayout")
subLayout.FillDirection = Enum.FillDirection.Horizontal
subLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
subLayout.Padding = UDim.new(0, 10)
subLayout.Parent = subContainer

-- Lock In Button
local lockInButton = Instance.new("TextButton")
lockInButton.Name = "LockInButton"
lockInButton.Size = UDim2.new(1, -32, 0, 42)
lockInButton.Position = UDim2.new(0, 16, 1, -54)
lockInButton.BackgroundColor3 = Color3.fromRGB(45, 130, 240)
lockInButton.BorderSizePixel = 0
lockInButton.Text = "LOCK IN CLASS ➔"
lockInButton.TextColor3 = Color3.fromRGB(255, 255, 255)
lockInButton.Font = Enum.Font.GothamBold
lockInButton.TextSize = 14
lockInButton.AutoButtonColor = true
lockInButton.ZIndex = 15
lockInButton.Parent = rightInspector

createCorner(lockInButton, 8)
local lockInStroke = createStroke(lockInButton, Color3.fromRGB(90, 180, 255), 1.5)

--------------------------------------------------------------------------------
-- Active Client Selection State
--------------------------------------------------------------------------------

local currentClassId = "Warlord"
local currentSubclassId = "Berserker"
local classCardsList: { [string]: Frame } = {}
local subclassButtonsList: { [string]: TextButton } = {}

--------------------------------------------------------------------------------
-- Inspector Population & Subclass Switcher
--------------------------------------------------------------------------------

local function updateInspector(heroClass: ClassData.HeroClass)
	inspIcon.Text = heroClass.Icon
	inspTitle.Text = heroClass.Name
	inspTitle.TextColor3 = heroClass.Color
	inspStats.Text = string.format("❤️ %d Max HP   |   ⚡ %d Starting Energy", heroClass.MaxHp, heroClass.StartingEnergy)
	inspDesc.Text = heroClass.Description
	inspectorStroke.Color = heroClass.Color

	gimmickTitle.Text = string.format("⚡ COMBAT GIMMICK: %s", heroClass.GimmickName)
	gimmickDesc.Text = heroClass.GimmickDescription

	-- Clear old subclass toggle buttons
	for _, child in subContainer:GetChildren() do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
	table.clear(subclassButtonsList)

	-- Generate the 2 Subclass option buttons
	for _, sub in heroClass.Subclasses do
		local subBtn = Instance.new("TextButton")
		subBtn.Name = "Sub_" .. sub.Id
		subBtn.Size = UDim2.new(0.48, -5, 1, 0)
		subBtn.BackgroundColor3 = (sub.Id == currentSubclassId) and Color3.fromRGB(40, 60, 95) or Color3.fromRGB(24, 28, 42)
		subBtn.BorderSizePixel = 0
		subBtn.AutoButtonColor = true
		subBtn.Text = ""
		subBtn.Parent = subContainer

		createCorner(subBtn, 6)
		local sStroke = createStroke(
			subBtn,
			(sub.Id == currentSubclassId) and heroClass.Color or Color3.fromRGB(50, 65, 90),
			(sub.Id == currentSubclassId) and 2 or 1
		)

		local sTitle = Instance.new("TextLabel")
		sTitle.Name = "Title"
		sTitle.Size = UDim2.new(1, -12, 0, 18)
		sTitle.Position = UDim2.new(0, 6, 0, 6)
		sTitle.BackgroundTransparency = 1
		sTitle.Text = sub.Name
		sTitle.TextColor3 = (sub.Id == currentSubclassId) and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(200, 215, 240)
		sTitle.Font = Enum.Font.GothamBold
		sTitle.TextSize = 12
		sTitle.TextXAlignment = Enum.TextXAlignment.Left
		sTitle.Parent = subBtn

		local sDesc = Instance.new("TextLabel")
		sDesc.Name = "Desc"
		sDesc.Size = UDim2.new(1, -12, 1, -26)
		sDesc.Position = UDim2.new(0, 6, 0, 24)
		sDesc.BackgroundTransparency = 1
		sDesc.Text = sub.Description
		sDesc.TextColor3 = Color3.fromRGB(160, 180, 210)
		sDesc.Font = Enum.Font.Gotham
		sDesc.TextSize = 10
		sDesc.TextWrapped = true
		sDesc.TextXAlignment = Enum.TextXAlignment.Left
		sDesc.TextYAlignment = Enum.TextYAlignment.Top
		sDesc.Parent = subBtn

		subBtn.MouseButton1Click:Connect(function()
			currentSubclassId = sub.Id
			updateInspector(heroClass)
		end)

		subclassButtonsList[sub.Id] = subBtn
	end
end

--------------------------------------------------------------------------------
-- Class Cards Factory
--------------------------------------------------------------------------------

local function buildClassCards()
	local all = ClassData.getClassList()

	for i, hero in all do
		local card = Instance.new("Frame")
		card.Name = "Card_" .. hero.Id
		card.Size = UDim2.new(1, 0, 0, 48)
		card.BackgroundColor3 = (hero.Id == currentClassId) and Color3.fromRGB(36, 45, 68) or Color3.fromRGB(22, 26, 38)
		card.BorderSizePixel = 0
		card.LayoutOrder = i
		card.Parent = leftScroller

		createCorner(card, 8)
		local cStroke = createStroke(
			card,
			(hero.Id == currentClassId) and hero.Color or Color3.fromRGB(45, 55, 75),
			(hero.Id == currentClassId) and 2 or 1
		)

		local cIcon = Instance.new("TextLabel")
		cIcon.Name = "Icon"
		cIcon.Size = UDim2.new(0, 32, 1, 0)
		cIcon.Position = UDim2.new(0, 8, 0, 0)
		cIcon.BackgroundTransparency = 1
		cIcon.Text = hero.Icon
		cIcon.TextSize = 20
		cIcon.Parent = card

		local cName = Instance.new("TextLabel")
		cName.Name = "Name"
		cName.Size = UDim2.new(1, -100, 0, 20)
		cName.Position = UDim2.new(0, 44, 0, 6)
		cName.BackgroundTransparency = 1
		cName.Text = hero.Name
		cName.TextColor3 = Color3.fromRGB(255, 255, 255)
		cName.Font = Enum.Font.GothamBold
		cName.TextSize = 13
		cName.TextXAlignment = Enum.TextXAlignment.Left
		cName.Parent = card

		local cGimmick = Instance.new("TextLabel")
		cGimmick.Name = "Gimmick"
		cGimmick.Size = UDim2.new(1, -100, 0, 16)
		cGimmick.Position = UDim2.new(0, 44, 0, 24)
		cGimmick.BackgroundTransparency = 1
		cGimmick.Text = hero.GimmickName
		cGimmick.TextColor3 = hero.Color
		cGimmick.Font = Enum.Font.GothamMedium
		cGimmick.TextSize = 10
		cGimmick.TextXAlignment = Enum.TextXAlignment.Left
		cGimmick.Parent = card

		local btn = Instance.new("TextButton")
		btn.Name = "SelectBtn"
		btn.Size = UDim2.new(1, 0, 1, 0)
		btn.BackgroundTransparency = 1
		btn.Text = ""
		btn.Parent = card

		btn.MouseButton1Click:Connect(function()
			currentClassId = hero.Id
			currentSubclassId = hero.Subclasses[1].Id
			for id, cFrame in classCardsList do
				local isSelected = (id == hero.Id)
				cFrame.BackgroundColor3 = isSelected and Color3.fromRGB(36, 45, 68) or Color3.fromRGB(22, 26, 38)
				local strk = cFrame:FindFirstChildOfClass("UIStroke")
				if strk then
					strk.Color = isSelected and hero.Color or Color3.fromRGB(45, 55, 75)
					strk.Thickness = isSelected and 2 or 1
				end
			end
			updateInspector(hero)
		end)

		classCardsList[hero.Id] = card
	end
end

--------------------------------------------------------------------------------
-- Lock In Action & Game Flow Synchronization
--------------------------------------------------------------------------------

local isLockingIn = false

local function restoreLockInButton()
	lockInButton.Text = "LOCK IN CLASS ➔"
	lockInButton.BackgroundColor3 = Color3.fromRGB(45, 130, 240)
	lockInStroke.Color = Color3.fromRGB(90, 180, 255)
	lockInButton.AutoButtonColor = true
end

lockInButton.MouseButton1Click:Connect(function()
	if isLockingIn then
		return
	end
	isLockingIn = true

	print(string.format("[ClassSelectUI] Locking in: Class=%s, Subclass=%s", tostring(currentClassId), tostring(currentSubclassId)))
	lockInButton.Text = "LOCKING IN..."
	lockInButton.BackgroundColor3 = Color3.fromRGB(60, 75, 105)
	lockInStroke.Color = Color3.fromRGB(90, 110, 145)
	lockInButton.AutoButtonColor = false

	if not SelectClassEvent then
		SelectClassEvent = findEvent("SelectClass")
	end

	if SelectClassEvent then
		SelectClassEvent:FireServer({
			ClassId = currentClassId,
			SubclassId = currentSubclassId,
		})
	else
		warn("[ClassSelectUI] SelectClass RemoteEvent missing from GameNetwork!")
		isLockingIn = false
		restoreLockInButton()
	end

	-- Fallback timeout in case server doesn't respond or packet drop
	task.delay(5, function()
		if isLockingIn then
			warn("[ClassSelectUI] Lock in request timed out waiting for server confirmation.")
			isLockingIn = false
			restoreLockInButton()
		end
	end)
end)

--------------------------------------------------------------------------------
-- Game Flow Visibility Sync
--------------------------------------------------------------------------------

if RunStateUpdateEvent then
	RunStateUpdateEvent.OnClientEvent:Connect(function(state: any)
		if typeof(state) ~= "table" or not state.Phase then
			return
		end

		if state.Phase ~= "Lobby" then
			modal.Visible = false
			isLockingIn = false
			restoreLockInButton()
			return
		end

		local myView: any = nil
		if state.Party and localPlayer then
			myView = state.Party[tostring(localPlayer.UserId)]
		end

		if myView then
			local isClassLocked = (myView.ClassLocked == true)
			if isClassLocked then
				if isLockingIn then
					isLockingIn = false
					lockInButton.Text = "✓ CLASS LOCKED IN!"
					lockInButton.BackgroundColor3 = Color3.fromRGB(50, 180, 100)
					lockInStroke.Color = Color3.fromRGB(80, 240, 140)

					-- Button bounce tween
					local tween = TweenService:Create(lockInButton, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
						Size = UDim2.new(1, -28, 0, 44),
					})
					tween:Play()
					tween.Completed:Connect(function()
						TweenService:Create(lockInButton, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
							Size = UDim2.new(1, -32, 0, 42),
						}):Play()
					end)

					task.delay(0.4, function()
						modal.Visible = false
					end)
				else
					isLockingIn = false
					modal.Visible = false
				end
			else
				modal.Visible = true
				if isLockingIn then
					isLockingIn = false
					restoreLockInButton()
				elseif not modal.Visible then
					restoreLockInButton()
				end
			end
		else
			modal.Visible = true
			if isLockingIn then
				isLockingIn = false
				restoreLockInButton()
			end
		end

		if state.Message and string.find(string.lower(state.Message), "rejected") then
			warn(string.format("[ClassSelectUI] Server message: %s", tostring(state.Message)))
			isLockingIn = false
			restoreLockInButton()
			modal.Visible = true
			subtitleLabel.Text = state.Message
			subtitleLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
			task.delay(4, function()
				subtitleLabel.Text = "Select 1 of 10 core classes and customize your subclass before descending into the Spire."
				subtitleLabel.TextColor3 = Color3.fromRGB(160, 180, 210)
			end)
		end
	end)
end

--------------------------------------------------------------------------------
-- Startup Initialization
--------------------------------------------------------------------------------

buildClassCards()
local defaultHero = ClassData.getClass("Warlord")
if defaultHero then
	updateInspector(defaultHero)
end

if RequestStateSyncEvent then
	RequestStateSyncEvent:FireServer()
end

print("[ClassSelectUI] Initialized lobby hero selector.")
