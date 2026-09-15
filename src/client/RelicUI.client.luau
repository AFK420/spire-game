--!strict

--[=[
	RelicUI LocalScript
	Mapped to: StarterPlayer.StarterPlayerScripts.Client.RelicUI
	Manages the client-side Relic HUD and hover tooltip display for Card Rift: Co-op Dungeon:
	1. Displays a clean, horizontal scrolling UI frame inside the player's active HUD.
	2. Renders compact icon badges for all relics equipped by the player.
	3. Features a dynamic hover-tooltip system displaying Name, Rarity color tier, Trigger, and Description.
	4. Listens to server RemoteEvents for inventory synchronization and visual trigger pulses.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RelicData = require(Shared:WaitForChild("RelicData") :: ModuleScript)

--------------------------------------------------------------------------------
-- Remote Events Resolution
--------------------------------------------------------------------------------

local function findRelicEvent(eventName: string): RemoteEvent?
	local networkFolder = ReplicatedStorage:FindFirstChild("GameNetwork") or ReplicatedStorage:WaitForChild("GameNetwork", 5)
	if networkFolder then
		local ev = networkFolder:FindFirstChild(eventName)
		if ev and ev:IsA("RemoteEvent") then
			return ev
		end
	end
	local folder = ReplicatedStorage:FindFirstChild("RelicEvents")
	if folder then
		local ev = folder:FindFirstChild(eventName)
		if ev and ev:IsA("RemoteEvent") then
			return ev
		end
	end
	return nil
end

local RelicTriggerNotificationEvent = findRelicEvent("RelicNotification")
local RunStateUpdateEvent = findRelicEvent("RunStateUpdate")

--------------------------------------------------------------------------------
-- UI Construction & Styling Helpers
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
-- ScreenGui & Main Relic Bar Setup
--------------------------------------------------------------------------------

-- Ensure a ScreenGui exists for the Relic HUD
local relicScreenGui: ScreenGui
local existingGui = playerGui:FindFirstChild("CardRiftScreenGui")
if existingGui and existingGui:IsA("ScreenGui") then
	relicScreenGui = existingGui
else
	local newGui = Instance.new("ScreenGui")
	newGui.Name = "CardRiftRelicGui"
	newGui.ResetOnSpawn = false
	newGui.DisplayOrder = 15
	newGui.Parent = playerGui
	relicScreenGui = newGui
end

-- Relic Bar Outer Container
local relicBarContainer = Instance.new("Frame")
relicBarContainer.Name = "RelicBarContainer"
relicBarContainer.Size = UDim2.new(0, 360, 0, 48)
relicBarContainer.Position = UDim2.new(0, 16, 0, 68) -- Positioned cleanly under top header
relicBarContainer.BackgroundColor3 = Color3.fromRGB(16, 18, 26)
relicBarContainer.BackgroundTransparency = 0.25
relicBarContainer.BorderSizePixel = 0
relicBarContainer.ClipsDescendants = false
relicBarContainer.Parent = relicScreenGui

createCorner(relicBarContainer, 10)
createStroke(relicBarContainer, Color3.fromRGB(50, 65, 90), 1.5)

-- Left Label / Icon
local titleBadge = Instance.new("TextLabel")
titleBadge.Name = "TitleBadge"
titleBadge.Size = UDim2.new(0, 72, 1, 0)
titleBadge.Position = UDim2.new(0, 8, 0, 0)
titleBadge.BackgroundTransparency = 1
titleBadge.Text = "🏺 RELICS"
titleBadge.TextColor3 = Color3.fromRGB(200, 220, 255)
titleBadge.Font = Enum.Font.GothamBold
titleBadge.TextSize = 12
titleBadge.TextXAlignment = Enum.TextXAlignment.Left
titleBadge.Parent = relicBarContainer

-- Horizontal Scrolling Container for Relic Badges
local scrollFrame = Instance.new("ScrollingFrame")
scrollFrame.Name = "RelicScroller"
scrollFrame.Size = UDim2.new(1, -88, 1, -8)
scrollFrame.Position = UDim2.new(0, 80, 0, 4)
scrollFrame.BackgroundTransparency = 1
scrollFrame.BorderSizePixel = 0
scrollFrame.ScrollBarThickness = 3
scrollFrame.ScrollBarImageColor3 = Color3.fromRGB(70, 140, 220)
scrollFrame.ScrollingDirection = Enum.ScrollingDirection.X
scrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.X
scrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
scrollFrame.Parent = relicBarContainer

local listLayout = Instance.new("UIListLayout")
listLayout.FillDirection = Enum.FillDirection.Horizontal
listLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
listLayout.VerticalAlignment = Enum.VerticalAlignment.Center
listLayout.Padding = UDim.new(0, 6)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = scrollFrame

local padding = Instance.new("UIPadding")
padding.PaddingLeft = UDim.new(0, 2)
padding.PaddingRight = UDim.new(0, 6)
padding.Parent = scrollFrame

--------------------------------------------------------------------------------
-- Hover Tooltip Window
--------------------------------------------------------------------------------

local tooltipFrame = Instance.new("Frame")
tooltipFrame.Name = "RelicTooltip"
tooltipFrame.Size = UDim2.new(0, 240, 0, 110)
tooltipFrame.Position = UDim2.new(0, 16, 0, 122)
tooltipFrame.BackgroundColor3 = Color3.fromRGB(12, 14, 20)
tooltipFrame.BackgroundTransparency = 0.05
tooltipFrame.BorderSizePixel = 0
tooltipFrame.Visible = false
tooltipFrame.ZIndex = 30
tooltipFrame.Parent = relicScreenGui

createCorner(tooltipFrame, 8)
local tooltipStroke = createStroke(tooltipFrame, Color3.fromRGB(80, 160, 240), 1.5)

-- Tooltip Header (Icon + Name)
local ttIcon = Instance.new("TextLabel")
ttIcon.Name = "TooltipIcon"
ttIcon.Size = UDim2.new(0, 26, 0, 26)
ttIcon.Position = UDim2.new(0, 10, 0, 8)
ttIcon.BackgroundTransparency = 1
ttIcon.Text = "✨"
ttIcon.TextSize = 20
ttIcon.ZIndex = 31
ttIcon.Parent = tooltipFrame

local ttTitle = Instance.new("TextLabel")
ttTitle.Name = "TooltipTitle"
ttTitle.Size = UDim2.new(1, -120, 0, 20)
ttTitle.Position = UDim2.new(0, 40, 0, 8)
ttTitle.BackgroundTransparency = 1
ttTitle.Text = "Relic Name"
ttTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
ttTitle.Font = Enum.Font.GothamBold
ttTitle.TextSize = 13
ttTitle.TextXAlignment = Enum.TextXAlignment.Left
ttTitle.ZIndex = 31
ttTitle.Parent = tooltipFrame

-- Rarity Pill Badge
local ttRarityPill = Instance.new("TextLabel")
ttRarityPill.Name = "TooltipRarity"
ttRarityPill.Size = UDim2.new(0, 70, 0, 18)
ttRarityPill.Position = UDim2.new(1, -78, 0, 8)
ttRarityPill.BackgroundColor3 = Color3.fromRGB(30, 35, 48)
ttRarityPill.Text = "COMMON"
ttRarityPill.TextColor3 = Color3.fromRGB(220, 220, 230)
ttRarityPill.Font = Enum.Font.GothamBold
ttRarityPill.TextSize = 9
ttRarityPill.ZIndex = 31
ttRarityPill.Parent = tooltipFrame
createCorner(ttRarityPill, 4)

-- Trigger Subtitle
local ttTrigger = Instance.new("TextLabel")
ttTrigger.Name = "TooltipTrigger"
ttTrigger.Size = UDim2.new(1, -20, 0, 16)
ttTrigger.Position = UDim2.new(0, 10, 0, 32)
ttTrigger.BackgroundTransparency = 1
ttTrigger.Text = "⚡ Trigger: OnCombatStart"
ttTrigger.TextColor3 = Color3.fromRGB(140, 175, 210)
ttTrigger.Font = Enum.Font.GothamMedium
ttTrigger.TextSize = 10
ttTrigger.TextXAlignment = Enum.TextXAlignment.Left
ttTrigger.ZIndex = 31
ttTrigger.Parent = tooltipFrame

-- Separator Line
local ttDivider = Instance.new("Frame")
ttDivider.Name = "Divider"
ttDivider.Size = UDim2.new(1, -20, 0, 1)
ttDivider.Position = UDim2.new(0, 10, 0, 52)
ttDivider.BackgroundColor3 = Color3.fromRGB(40, 48, 65)
ttDivider.BorderSizePixel = 0
ttDivider.ZIndex = 31
ttDivider.Parent = tooltipFrame

-- Description Body
local ttDesc = Instance.new("TextLabel")
ttDesc.Name = "TooltipDescription"
ttDesc.Size = UDim2.new(1, -20, 0, 48)
ttDesc.Position = UDim2.new(0, 10, 0, 58)
ttDesc.BackgroundTransparency = 1
ttDesc.Text = "Relic passive description goes here."
ttDesc.TextColor3 = Color3.fromRGB(215, 225, 240)
ttDesc.Font = Enum.Font.Gotham
ttDesc.TextSize = 11
ttDesc.TextWrapped = true
ttDesc.TextXAlignment = Enum.TextXAlignment.Left
ttDesc.TextYAlignment = Enum.TextYAlignment.Top
ttDesc.ZIndex = 31
ttDesc.Parent = tooltipFrame

--------------------------------------------------------------------------------
-- Tooltip Logic
--------------------------------------------------------------------------------

local function showTooltip(relic: RelicData.Relic, badgeFrame: Frame)
	local rarityColor = RelicData.getRarityColor(relic.Rarity)

	ttIcon.Text = relic.Icon or "✨"
	ttTitle.Text = relic.Name
	ttRarityPill.Text = string.upper(relic.Rarity)
	ttRarityPill.TextColor3 = rarityColor
	ttTrigger.Text = string.format("⚡ Trigger: %s", relic.Trigger)
	ttDesc.Text = relic.Description
	tooltipStroke.Color = rarityColor

	-- Position tooltip directly beneath or adjacent to the hovered badge
	local badgeAbsolutePos = badgeFrame.AbsolutePosition
	local screenWidth = relicScreenGui.AbsoluteSize.X
	local posX = math.clamp(badgeAbsolutePos.X, 16, math.max(16, screenWidth - 260))
	local posY = badgeAbsolutePos.Y + badgeFrame.AbsoluteSize.Y + 8

	tooltipFrame.Position = UDim2.new(0, posX, 0, posY)
	tooltipFrame.Visible = true

	-- Subtle pop-in animation
	tooltipFrame.Size = UDim2.new(0, 240, 0, 105)
	local tween = TweenService:Create(tooltipFrame, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = UDim2.new(0, 240, 0, 110),
	})
	tween:Play()
end

local function hideTooltip()
	tooltipFrame.Visible = false
end

--------------------------------------------------------------------------------
-- Relic Badge Factory
--------------------------------------------------------------------------------

local activeBadgeFrames: { [string]: Frame } = {}

local function createRelicBadge(relic: RelicData.Relic, index: number): Frame
	local rarityColor = RelicData.getRarityColor(relic.Rarity)

	local badge = Instance.new("Frame")
	badge.Name = "Relic_" .. relic.Id
	badge.Size = UDim2.new(0, 32, 0, 32)
	badge.BackgroundColor3 = Color3.fromRGB(24, 27, 36)
	badge.BorderSizePixel = 0
	badge.LayoutOrder = index
	badge.ZIndex = 20
	badge.Parent = scrollFrame

	createCorner(badge, 6)
	local stroke = createStroke(badge, rarityColor, 1.5)

	-- Icon Glyph
	local iconLabel = Instance.new("TextLabel")
	iconLabel.Name = "Icon"
	iconLabel.Size = UDim2.new(1, 0, 1, 0)
	iconLabel.BackgroundTransparency = 1
	iconLabel.Text = relic.Icon or "✨"
	iconLabel.TextSize = 16
	iconLabel.ZIndex = 21
	iconLabel.Parent = badge

	-- Interactive hover detection via invisible overlay button
	local btn = Instance.new("TextButton")
	btn.Name = "HoverTrigger"
	btn.Size = UDim2.new(1, 0, 1, 0)
	btn.BackgroundTransparency = 1
	btn.Text = ""
	btn.ZIndex = 25
	btn.Parent = badge

	btn.MouseEnter:Connect(function()
		showTooltip(relic, badge)
		TweenService:Create(badge, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = UDim2.new(0, 36, 0, 36),
			BackgroundColor3 = Color3.fromRGB(36, 42, 56),
		}):Play()
		stroke.Thickness = 2.5
	end)

	btn.MouseLeave:Connect(function()
		hideTooltip()
		TweenService:Create(badge, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = UDim2.new(0, 32, 0, 32),
			BackgroundColor3 = Color3.fromRGB(24, 27, 36),
		}):Play()
		stroke.Thickness = 1.5
	end)

	activeBadgeFrames[relic.Id] = badge
	return badge
end

-- Re-renders all badges when relic inventory updates
local function renderInventory(relics: { RelicData.Relic })
	-- Clean existing badges
	for _, child in scrollFrame:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	table.clear(activeBadgeFrames)

	for i, relic in relics do
		createRelicBadge(relic, i)
	end

	print(string.format("[RelicUI] Rendered %d equipped relic(s)", #relics))
end

--------------------------------------------------------------------------------
-- Trigger Pulse Animation & Floating Notification
--------------------------------------------------------------------------------

local function pulseRelicBadge(relicId: string, alertText: string, rarity: RelicData.RelicRarity?)
	local badge = activeBadgeFrames[relicId]
	if not badge then return end

	-- Visual scale bounce on the badge
	local originalSize = badge.Size
	local expandTween = TweenService:Create(badge, TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Size = UDim2.new(0, 42, 0, 42),
		BackgroundColor3 = Color3.fromRGB(60, 90, 130),
	})
	local shrinkTween = TweenService:Create(badge, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Size = originalSize,
		BackgroundColor3 = Color3.fromRGB(24, 27, 36),
	})

	expandTween:Play()
	expandTween.Completed:Connect(function()
		shrinkTween:Play()
	end)

	-- Floating text above the relic bar
	local floatLabel = Instance.new("TextLabel")
	floatLabel.Name = "RelicFloatAlert"
	floatLabel.Size = UDim2.new(0, 220, 0, 20)
	floatLabel.Position = UDim2.new(0, badge.AbsolutePosition.X, 0, badge.AbsolutePosition.Y - 24)
	floatLabel.BackgroundTransparency = 1
	floatLabel.Text = alertText
	floatLabel.TextColor3 = rarity and RelicData.getRarityColor(rarity) or Color3.fromRGB(255, 230, 100)
	floatLabel.Font = Enum.Font.GothamBold
	floatLabel.TextSize = 12
	floatLabel.ZIndex = 40
	floatLabel.Parent = relicScreenGui

	local floatTween = TweenService:Create(floatLabel, TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Position = UDim2.new(0, badge.AbsolutePosition.X, 0, badge.AbsolutePosition.Y - 48),
		TextTransparency = 1,
	})
	floatTween:Play()
	floatTween.Completed:Connect(function()
		floatLabel:Destroy()
	end)
end

--------------------------------------------------------------------------------
-- Remote Event Listeners
--------------------------------------------------------------------------------

if RunStateUpdateEvent then
	RunStateUpdateEvent.OnClientEvent:Connect(function(snapshot: any)
		if typeof(snapshot) == "table" and snapshot.Party then
			local myParty = snapshot.Party[tostring(localPlayer.UserId)]
			if myParty and myParty.RelicIds then
				renderInventory(myParty.RelicIds)
			end
		end
	end)
end

if RelicTriggerNotificationEvent then
	RelicTriggerNotificationEvent.OnClientEvent:Connect(function(payload: any)
		if typeof(payload) == "table" and payload.RelicId and payload.Text then
			pulseRelicBadge(payload.RelicId, payload.Text, payload.Rarity)
		end
	end)
end

print("[RelicUI] Initialized successfully with GameNetwork synchronization.")
