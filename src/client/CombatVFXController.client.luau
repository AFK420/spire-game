--!strict

--[=[
	CombatVFXController Client Script
	Mapped to: StarterPlayer.StarterPlayerScripts.Client.CombatVFXController

	Cosmetic 3D Attack Presentation & Combat Visual Effects:
	1. Exclusively owns cosmetic 3D attack visuals (no server tweens or duplicate projectiles).
	2. Synchronizes all attack movements and projectile flight to authoritative server timestamps
	   (Workspace:GetServerTimeNow(), AttackStartServerTime, ImpactServerTime).
	3. Renders attacks for all clients in co-op (spectators and targets alike).
	4. Moves enemy visual models as coherent assemblies using Model:PivotTo().
	5. Supports Melee lunges, Jump arcs, Projectiles, and AoE charge/detonations.
	6. Handles client replication races with bounded Heartbeat retry and deterministic catch-up.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)
local GameConfig = require(Shared:WaitForChild("GameConfig") :: ModuleScript)
local CombatFeedbackData = require(Shared:WaitForChild("CombatFeedbackData") :: ModuleScript)

local GameNetwork = ReplicatedStorage:WaitForChild("GameNetwork")
local CombatStateUpdateEvent = GameNetwork:WaitForChild("CombatStateUpdate") :: RemoteEvent
local CombatEventLoggedEvent = GameNetwork:WaitForChild("CombatEventLogged") :: RemoteEvent

local localPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Active Attack State Tracking
--------------------------------------------------------------------------------

local currentActiveWindowId: string? = nil
local playbackStarted: { [string]: boolean } = {}
local pendingRetryConnection: RBXScriptConnection? = nil
local pendingRetryWindow: StateTypes.ReactionWindowView? = nil
local activeAnimations: { [string]: RBXScriptConnection } = {}
local activeConnections: { [string]: { RBXScriptConnection } } = {}
local activeVfxInstances: { Instance } = {}
local enemyOriginalPivots: { [Model]: CFrame } = {}
local latestEnemyViews: { [string]: StateTypes.EnemyView } = {}
local activeFeedbackPopups: { BillboardGui } = {}
local feedbackSerial = 0
local activeShakeConnection: RBXScriptConnection? = nil
local activeShakeHumanoid: Humanoid? = nil
local activeShakeBaseOffset = Vector3.zero

local function trackConnection(windowId: string, conn: RBXScriptConnection)
	local list = activeConnections[windowId]
	if not list then
		list = {}
		activeConnections[windowId] = list
	end
	table.insert(list, conn)
end

local function getActiveRoom(): Instance?
	local cardRiftWorld = Workspace:FindFirstChild("CardRiftWorld")
	if not cardRiftWorld then return nil end
	return cardRiftWorld:FindFirstChild("ActiveRoom")
end

local function getVfxContainer(): Instance
	local activeRoom = getActiveRoom()
	if activeRoom then
		local effects = activeRoom:FindFirstChild("Effects")
		if effects then return effects end
		return activeRoom
	end
	local combatArena = Workspace:FindFirstChild("CombatArena")
	if combatArena then return combatArena end
	return Workspace
end

local function findEnemyModel(enemyInstanceId: string?): Model?
	if not enemyInstanceId or enemyInstanceId == "" then return nil end
	local expectedName = "Enemy_" .. enemyInstanceId

	-- 1. Search recursively under ActiveRoom
	local activeRoom = getActiveRoom()
	if activeRoom then
		local found = activeRoom:FindFirstChild(expectedName, true)
		if found and found:IsA("Model") then
			return found
		end
	end

	-- 2. Search recursively under CardRiftWorld
	local cardRiftWorld = Workspace:FindFirstChild("CardRiftWorld")
	if cardRiftWorld then
		local found = cardRiftWorld:FindFirstChild(expectedName, true)
		if found and found:IsA("Model") then
			return found
		end
	end

	-- 3. Search recursively under Workspace
	local foundWs = Workspace:FindFirstChild(expectedName, true)
	if foundWs and foundWs:IsA("Model") then
		return foundWs
	end

	return nil
end

--------------------------------------------------------------------------------
-- Authoritative Combat Event Feedback
--------------------------------------------------------------------------------

local function findPlayerByTargetId(targetId: string): Player?
	local numericId = tonumber(targetId)
	for _, player in Players:GetPlayers() do
		if (numericId and player.UserId == numericId)
			or player.Name == targetId
			or player.DisplayName == targetId then
			return player
		end
	end
	return nil
end

local function resolveFeedbackTarget(targetId: string): (BasePart?, Model?, Player?)
	local enemyModel = findEnemyModel(targetId)
	if not enemyModel then
		-- Compatibility fallback for combat events emitted before stable target IDs.
		for enemyId, enemyView in latestEnemyViews do
			if enemyView.Name == targetId then
				enemyModel = findEnemyModel(enemyId)
				break
			end
		end
	end
	if enemyModel then
		local head = enemyModel:FindFirstChild("Head")
		local adornee = if head and head:IsA("BasePart") then head else enemyModel.PrimaryPart
		return adornee, enemyModel, nil
	end

	local player = findPlayerByTargetId(targetId)
	local character = if player then player.Character else nil
	if character then
		local head = character:FindFirstChild("Head")
		local root = character:FindFirstChild("HumanoidRootPart")
		local adornee = if head and head:IsA("BasePart")
			then head
			elseif root and root:IsA("BasePart") then root else nil
		return adornee, character, player
	end
	return nil, nil, player
end

local function removeFeedbackPopup(popup: BillboardGui)
	for index, current in activeFeedbackPopups do
		if current == popup then
			table.remove(activeFeedbackPopups, index)
			break
		end
	end
	if popup.Parent then
		popup:Destroy()
	end
end

local function showWorldPopup(adornee: BasePart, event: StateTypes.CombatEvent)
	local feedbackConfig = GameConfig.CombatFeedback
	while #activeFeedbackPopups >= feedbackConfig.MaxConcurrentPopups do
		removeFeedbackPopup(activeFeedbackPopups[1])
	end

	feedbackSerial += 1
	local style = CombatFeedbackData.getStyle(event.Type)
	local laneOffset = ((feedbackSerial - 1) % 3 - 1) * 0.65
	local startOffset = Vector3.new(laneOffset, 2.6, 0)

	local popup = Instance.new("BillboardGui")
	popup.Name = "CombatFeedbackPopup"
	popup.Adornee = adornee
	popup.AlwaysOnTop = true
	popup.LightInfluence = 0
	popup.MaxDistance = 120
	popup.Size = UDim2.fromOffset(math.round(190 * style.Scale), math.round(54 * style.Scale))
	popup.StudsOffsetWorldSpace = startOffset
	popup.Parent = adornee
	table.insert(activeFeedbackPopups, popup)

	local label = Instance.new("TextLabel")
	label.Name = "Value"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.Text = CombatFeedbackData.getDisplayText(event)
	label.TextColor3 = style.Color
	label.TextScaled = true
	label.Parent = popup

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(20, 20, 28)
	stroke.Thickness = 2.5
	stroke.Transparency = 0.1
	stroke.Parent = label

	local tweenInfo = TweenInfo.new(feedbackConfig.PopupLifetime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(popup, tweenInfo, {
		StudsOffsetWorldSpace = startOffset + Vector3.new(0, feedbackConfig.PopupRiseStuds, 0),
	}):Play()
	TweenService:Create(label, tweenInfo, { TextTransparency = 1 }):Play()
	local strokeTween = TweenService:Create(stroke, tweenInfo, { Transparency = 1 })
	strokeTween:Play()
	strokeTween.Completed:Connect(function()
		removeFeedbackPopup(popup)
	end)
end

local function flashTarget(model: Model, color: Color3)
	local highlight = Instance.new("Highlight")
	highlight.Name = "CombatImpactFlash"
	highlight.Adornee = model
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.FillColor = color
	highlight.FillTransparency = 0.25
	highlight.OutlineColor = Color3.new(1, 1, 1)
	highlight.OutlineTransparency = 0.15
	highlight.Parent = model

	local tween = TweenService:Create(highlight, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		FillTransparency = 1,
		OutlineTransparency = 1,
	})
	tween:Play()
	tween.Completed:Connect(function()
		if highlight.Parent then
			highlight:Destroy()
		end
	end)
end

local function stopCameraShake()
	if activeShakeConnection then
		activeShakeConnection:Disconnect()
		activeShakeConnection = nil
	end
	if activeShakeHumanoid and activeShakeHumanoid.Parent then
		activeShakeHumanoid.CameraOffset = activeShakeBaseOffset
	end
	activeShakeHumanoid = nil
end

local function playCameraShake(requestedStrength: number)
	local feedbackConfig = GameConfig.CombatFeedback
	if localPlayer:GetAttribute(feedbackConfig.ReducedMotionAttribute) == true then
		return
	end
	local character = localPlayer.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if not humanoid then
		return
	end

	stopCameraShake()
	local strength = math.clamp(requestedStrength, 0, feedbackConfig.MaximumShakeStrength)
	local duration = feedbackConfig.ShakeDuration
	local startTime = os.clock()
	activeShakeHumanoid = humanoid
	activeShakeBaseOffset = humanoid.CameraOffset
	activeShakeConnection = RunService.RenderStepped:Connect(function()
		local elapsed = os.clock() - startTime
		local alpha = math.clamp(elapsed / duration, 0, 1)
		if alpha >= 1 or not humanoid.Parent then
			stopCameraShake()
			return
		end
		local falloff = 1 - alpha
		humanoid.CameraOffset = activeShakeBaseOffset + Vector3.new(
			math.sin(elapsed * 78) * strength * falloff,
			math.cos(elapsed * 91) * strength * 0.65 * falloff,
			0
		)
	end)
end

local function sourceBelongsToLocalPlayer(sourceId: string): boolean
	return sourceId == tostring(localPlayer.UserId)
		or sourceId == localPlayer.Name
		or sourceId == localPlayer.DisplayName
end

local function handleCombatFeedback(event: StateTypes.CombatEvent)
	local style = CombatFeedbackData.getStyle(event.Type)
	if not style.WorldPopup then
		return
	end
	local adornee, targetModel, targetPlayer = resolveFeedbackTarget(event.TargetId)
	if adornee then
		showWorldPopup(adornee, event)
	end
	if style.FlashTarget and targetModel then
		flashTarget(targetModel, style.Color)
	end

	if targetPlayer == localPlayer and style.LocalHitShake > 0 then
		playCameraShake(style.LocalHitShake)
	elseif sourceBelongsToLocalPlayer(event.SourceId) and style.LocalAttackShake > 0 then
		playCameraShake(style.LocalAttackShake)
	end
end

local function getRarityScale(rarity: string?): number
	if rarity == "UltraRare" then return 1.55 end
	if rarity == "SuperRare" then return 1.35 end
	if rarity == "Rare" then return 1.18 end
	if rarity == "Uncommon" then return 1.08 end
	return 1
end

local function configureProjectileShape(part: Part, shapeId: string?)
	if shapeId == "Coin" then
		part.Shape = Enum.PartType.Cylinder
		part.Size = Vector3.new(0.35, 1.6, 1.6)
	elseif shapeId == "Dice" then
		part.Shape = Enum.PartType.Block
		part.Size = Vector3.new(1.5, 1.5, 1.5)
	elseif shapeId == "Dart" or shapeId == "Wrench" then
		part.Shape = Enum.PartType.Block
		part.Size = Vector3.new(0.35, 0.35, 2.2)
	elseif shapeId == "Flask" then
		part.Shape = Enum.PartType.Ball
		part.Size = Vector3.new(1.2, 1.6, 1.2)
	else
		part.Shape = Enum.PartType.Ball
		part.Size = Vector3.new(1.35, 1.35, 1.35)
	end
end

local function playCardPresentation(event: StateTypes.CombatEvent)
	local sourcePlayer = findPlayerByTargetId(event.SourceId)
	local sourceCharacter = if sourcePlayer then sourcePlayer.Character else nil
	local sourceRoot = if sourceCharacter then sourceCharacter:FindFirstChild("HumanoidRootPart") else nil
	local targetPart = select(1, resolveFeedbackTarget(event.TargetId))
	if not sourceRoot or not sourceRoot:IsA("BasePart") then
		return
	end

	local color = event.EffectColor or Color3.fromRGB(120, 190, 255)
	local rarityScale = getRarityScale(event.CardRarity)
	local animationType = event.AnimationType or "Aura"
	local container = getVfxContainer()

	if animationType == "Projectile" and targetPart then
		local projectile = Instance.new("Part")
		projectile.Name = "CardProjectile_" .. (event.AnimationId or event.CardDefinitionId or "Card")
		configureProjectileShape(projectile, event.ProjectileShape)
		projectile.Size *= rarityScale
		projectile.Material = Enum.Material.Neon
		projectile.Color = color
		projectile.Anchored = true
		projectile.CanCollide = false
		projectile.CanQuery = false
		projectile.CFrame = CFrame.lookAt(sourceRoot.Position + Vector3.new(0, 1.5, 0), targetPart.Position)
		projectile.Parent = container

		local destination = targetPart.Position + if event.DidHit == false then Vector3.new(3.5, 1.8, 0) else Vector3.zero
		local travelTween = TweenService:Create(projectile, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			CFrame = CFrame.new(destination),
			Transparency = if event.DidHit == false then 0.65 else 0.1,
		})
		travelTween:Play()
		travelTween.Completed:Connect(function()
			if not projectile.Parent then return end
			local burst = TweenService:Create(projectile, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Size = projectile.Size * 1.8,
				Transparency = 1,
			})
			burst:Play()
			burst.Completed:Connect(function()
				if projectile.Parent then projectile:Destroy() end
			end)
		end)
	elseif animationType == "Melee" and targetPart then
		local slash = Instance.new("Part")
		slash.Name = "CardMeleeArc_" .. (event.AnimationId or event.CardDefinitionId or "Card")
		slash.Size = Vector3.new(0.18, 4.2 * rarityScale, 0.65 * rarityScale)
		slash.Material = Enum.Material.Neon
		slash.Color = color
		slash.Anchored = true
		slash.CanCollide = false
		slash.CanQuery = false
		slash.CFrame = CFrame.new(targetPart.Position) * CFrame.Angles(0, 0, math.rad(-48))
		slash.Parent = container
		local slashTween = TweenService:Create(slash, TweenInfo.new(0.20, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {
			CFrame = slash.CFrame * CFrame.Angles(0, math.rad(95), math.rad(100)),
			Transparency = 1,
			Size = Vector3.new(0.08, 6 * rarityScale, 0.25),
		})
		slashTween:Play()
		slashTween.Completed:Connect(function()
			if slash.Parent then slash:Destroy() end
		end)
	else
		local pulse = Instance.new("Part")
		pulse.Name = "CardAura_" .. (event.AnimationId or event.CardDefinitionId or "Card")
		pulse.Shape = Enum.PartType.Ball
		pulse.Size = Vector3.new(1.2, 1.2, 1.2) * rarityScale
		pulse.Material = Enum.Material.Neon
		pulse.Color = color
		pulse.Transparency = 0.35
		pulse.Anchored = true
		pulse.CanCollide = false
		pulse.CanQuery = false
		pulse.CFrame = CFrame.new((targetPart or sourceRoot).Position)
		pulse.Parent = container
		local pulseTween = TweenService:Create(pulse, TweenInfo.new(0.34, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = Vector3.new(7, 7, 7) * rarityScale,
			Transparency = 1,
		})
		pulseTween:Play()
		pulseTween.Completed:Connect(function()
			if pulse.Parent then pulse:Destroy() end
		end)
	end
end

local function stopModelRetry()
	if pendingRetryConnection then
		pendingRetryConnection:Disconnect()
		pendingRetryConnection = nil
	end
	pendingRetryWindow = nil
end

local function cleanupActiveAttack(windowId: string)
	stopModelRetry()

	local conns = activeConnections[windowId]
	if conns then
		for _, conn in conns do
			conn:Disconnect()
		end
		activeConnections[windowId] = nil
	end

	for key, conn in activeAnimations do
		if string.find(key, windowId, 1, true) ~= nil then
			conn:Disconnect()
			activeAnimations[key] = nil
		end
	end

	for i = #activeVfxInstances, 1, -1 do
		local inst = activeVfxInstances[i]
		if inst and inst.Parent then
			inst:Destroy()
		end
		table.remove(activeVfxInstances, i)
	end

	for model, origPivot in enemyOriginalPivots do
		if model and model.Parent then
			pcall(function()
				model:PivotTo(origPivot)
			end)
		end
	end
	table.clear(enemyOriginalPivots)
	playbackStarted[windowId] = nil
end

--------------------------------------------------------------------------------
-- 3D Attack Animations Driven by Synchronized Server Timestamps
--------------------------------------------------------------------------------

-- A) MELEE ATTACK: Windup -> Lunge to Target at ImpactServerTime -> Recover
local function playMeleeAttack(win: StateTypes.ReactionWindowView, enemyModel: Model)
	if not enemyModel or not enemyModel.PrimaryPart then return end

	local originPivot = enemyModel:GetPivot()
	enemyOriginalPivots[enemyModel] = originPivot

	local targetPos = win.TargetWorldPosition or win.TargetWorldPos
	if not targetPos then
		if localPlayer and localPlayer.Character and localPlayer.Character.PrimaryPart then
			targetPos = localPlayer.Character.PrimaryPart.Position
		else
			targetPos = Vector3.new(0, 1.2, 16)
		end
	end
	local dir = (targetPos - originPivot.Position)
	local dist = dir.Magnitude
	local unitDir = if dist > 0.1 then dir.Unit else Vector3.new(0, 0, 1)

	-- Lunge stops ~3.5 studs in front of target, facing target
	local lungePos = targetPos - (unitDir * 3.5) + Vector3.new(0, 0.4, 0)
	local lungeCFrame = CFrame.lookAt(lungePos, targetPos)
	local windupCFrame = originPivot * CFrame.new(0, 0.5, -1.6) * CFrame.Angles(math.rad(-14), 0, 0)

	local startTime = win.AttackStartServerTime
	local impactTime = win.ImpactServerTime
	local totalDuration = math.max(0.1, impactTime - startTime)
	local totalWindupTime = math.clamp(win.TelegraphDuration or (totalDuration * 0.40), 0.05, totalDuration - 0.05)
	local lungeStartTime = startTime + totalWindupTime
	local recoveryDuration = win.RecoveryDuration or 0.35
	local endTime = impactTime + recoveryDuration

	local windowId = win.WindowId
	local connection: RBXScriptConnection? = nil

	connection = RunService.Heartbeat:Connect(function()
		if not enemyModel or not enemyModel.Parent then
			if connection then connection:Disconnect() end
			return
		end

		local now = Workspace:GetServerTimeNow()

		if now < lungeStartTime then
			-- Phase 1: Anticipation Wind-up
			local alpha = math.clamp((now - startTime) / math.max(0.01, totalWindupTime), 0, 1)
			local smoothAlpha = math.sin(alpha * math.pi * 0.5)
			enemyModel:PivotTo(originPivot:Lerp(windupCFrame, smoothAlpha))
		elseif now <= impactTime then
			-- Phase 2: Rapid Strike Lunge reaching target at exact ImpactServerTime
			local lungeDur = math.max(0.01, impactTime - lungeStartTime)
			local alpha = math.clamp((now - lungeStartTime) / lungeDur, 0, 1)
			local strikeAlpha = alpha * alpha * alpha -- Exponential snap
			enemyModel:PivotTo(windupCFrame:Lerp(lungeCFrame, strikeAlpha))
		elseif now <= endTime then
			-- Phase 3: Recovery back to idle origin
			local alpha = math.clamp((now - impactTime) / math.max(0.01, recoveryDuration), 0, 1)
			local recoverAlpha = 1 - math.cos(alpha * math.pi * 0.5)
			enemyModel:PivotTo(lungeCFrame:Lerp(originPivot, recoverAlpha))
		else
			-- Finished: return cleanly to origin
			enemyModel:PivotTo(originPivot)
			if connection then
				connection:Disconnect()
				activeAnimations[windowId] = nil
			end
		end
	end)

	if connection then
		trackConnection(windowId, connection)
		activeAnimations[windowId] = connection
	end
end

-- B) JUMP ATTACK: Crouch -> High Leap Arc -> Slam onto Target at ImpactServerTime -> Recover
local function playJumpAttack(win: StateTypes.ReactionWindowView, enemyModel: Model)
	if not enemyModel or not enemyModel.PrimaryPart then return end

	local originPivot = enemyModel:GetPivot()
	enemyOriginalPivots[enemyModel] = originPivot

	local targetPos = win.TargetWorldPosition or win.TargetWorldPos
	if not targetPos then
		if localPlayer and localPlayer.Character and localPlayer.Character.PrimaryPart then
			targetPos = localPlayer.Character.PrimaryPart.Position
		else
			targetPos = Vector3.new(0, 1.2, 16)
		end
	end
	local crouchPivot = originPivot * CFrame.new(0, -1.2, 0.4) * CFrame.Angles(math.rad(18), 0, 0)
	local slamPivot = CFrame.new(targetPos + Vector3.new(0, 1.0, 0)) * CFrame.Angles(math.rad(25), 0, 0)

	local startTime = win.AttackStartServerTime
	local impactTime = win.ImpactServerTime
	local totalDuration = math.max(0.1, impactTime - startTime)
	local crouchTime = math.clamp(win.TelegraphDuration or (totalDuration * 0.30), 0.05, totalDuration - 0.05)
	local leapStartTime = startTime + crouchTime
	local recoveryDuration = win.RecoveryDuration or 0.45
	local endTime = impactTime + recoveryDuration

	local windowId = win.WindowId
	local connection: RBXScriptConnection? = nil
	local hasCreatedImpactVFX = false

	connection = RunService.Heartbeat:Connect(function()
		if not enemyModel or not enemyModel.Parent then
			if connection then connection:Disconnect() end
			return
		end

		local now = Workspace:GetServerTimeNow()

		if now < leapStartTime then
			-- Phase 1: Crouch down anticipation
			local alpha = math.clamp((now - startTime) / math.max(0.01, crouchTime), 0, 1)
			enemyModel:PivotTo(originPivot:Lerp(crouchPivot, alpha))
		elseif now <= impactTime then
			-- Phase 2: High parabolic leap through 3D world arriving at impact
			local flightDur = math.max(0.01, impactTime - leapStartTime)
			local alpha = math.clamp((now - leapStartTime) / flightDur, 0, 1)

			local arcHeight = 14 * 4 * alpha * (1 - alpha) -- 14 studs parabolic arc height
			local currentPos = crouchPivot.Position:Lerp(targetPos, alpha) + Vector3.new(0, arcHeight, 0)
			local pitchAngle = math.rad(15 - 35 * alpha)
			local flightCFrame = CFrame.lookAt(currentPos, targetPos + Vector3.new(0, 1, 0)) * CFrame.Angles(pitchAngle, 0, 0)
			enemyModel:PivotTo(flightCFrame)
		elseif now <= endTime then
			-- Phase 3: Slam landing and recovery back to origin
			if not hasCreatedImpactVFX then
				hasCreatedImpactVFX = true
				-- Brief landing shockwave ring on ground
				local container = getVfxContainer()
				local ring = Instance.new("Part")
				ring.Name = "JumpImpactRing"
				ring.Shape = Enum.PartType.Cylinder
				ring.Size = Vector3.new(0.3, 10, 10)
				ring.CFrame = CFrame.new(targetPos + Vector3.new(0, 0.2, 0)) * CFrame.Angles(0, 0, math.rad(90))
				ring.Material = Enum.Material.Neon
				ring.Color = Color3.fromRGB(255, 140, 40)
				ring.Anchored = true
				ring.CanCollide = false
				ring.Parent = container
				table.insert(activeVfxInstances, ring)

				local tRing = TweenService:Create(ring, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					Size = Vector3.new(0.1, 18, 18),
					Transparency = 1,
				})
				tRing:Play()
				task.delay(0.35, function()
					if ring and ring.Parent then ring:Destroy() end
				end)
			end

			local alpha = math.clamp((now - impactTime) / math.max(0.01, recoveryDuration), 0, 1)
			local recoverAlpha = 1 - math.cos(alpha * math.pi * 0.5)
			enemyModel:PivotTo(slamPivot:Lerp(originPivot, recoverAlpha))
		else
			enemyModel:PivotTo(originPivot)
			if connection then
				connection:Disconnect()
				activeAnimations[windowId] = nil
			end
		end
	end)

	if connection then
		trackConnection(windowId, connection)
		activeAnimations[windowId] = connection
	end
end

-- C) PROJECTILE ATTACK: Cast Windup -> Single 3D Projectile Flight to Target -> Impact at ImpactServerTime
local function playProjectileAttack(win: StateTypes.ReactionWindowView, enemyModel: Model?)
	local originPivot = (enemyModel and enemyModel:GetPivot()) or CFrame.new(0, 4, -16)
	if enemyModel then
		enemyOriginalPivots[enemyModel] = originPivot
	end

	local spawnPos = win.AttackerWorldPos or originPivot.Position + Vector3.new(0, 2.5, 2)
	local targetPos = (win.TargetWorldPosition or win.TargetWorldPos or Vector3.new(0, 1.2, 16)) + Vector3.new(0, 2.8, 0)

	local startTime = win.AttackStartServerTime
	local impactTime = win.ImpactServerTime
	local totalDuration = math.max(0.1, impactTime - startTime)
	local castWindup = math.clamp(win.TelegraphDuration or (totalDuration * 0.25), 0.05, totalDuration - 0.05)
	local flightStartTime = startTime + castWindup
	local flightDuration = math.max(0.05, impactTime - flightStartTime)
	local recoveryDuration = win.RecoveryDuration or 0.30

	local container = getVfxContainer()
	local windowId = win.WindowId

	-- Caster wind-up pose
	if enemyModel and enemyModel.PrimaryPart then
		local castCFrame = originPivot * CFrame.new(0, 0.6, -0.8) * CFrame.Angles(math.rad(-12), 0, 0)
		local now = Workspace:GetServerTimeNow()
		local remainingWindup = math.max(0.05, flightStartTime - now)
		local tCast = TweenService:Create(enemyModel.PrimaryPart :: BasePart, TweenInfo.new(remainingWindup, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), { CFrame = castCFrame })
		tCast:Play()
	end

	local function launchProjectile()
		if currentActiveWindowId ~= windowId then return end

		local proj = Instance.new("Part")
		proj.Name = "AttackProjectile_" .. windowId
		proj.Shape = Enum.PartType.Ball
		proj.Size = Vector3.new(2.2, 2.2, 2.2)
		proj.Material = Enum.Material.Neon
		proj.Color = Color3.fromRGB(130, 210, 255)
		proj.Anchored = true
		proj.CanCollide = false
		proj.CFrame = CFrame.new(spawnPos)
		proj.Parent = container
		table.insert(activeVfxInstances, proj)

		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(140, 220, 255)
		light.Brightness = 3.5
		light.Range = 16
		light.Parent = proj

		-- Heartbeat flight loop for exact impact arrival synchronized to server time
		local flightConnection: RBXScriptConnection? = nil
		flightConnection = RunService.Heartbeat:Connect(function()
			if not proj or not proj.Parent then
				if flightConnection then flightConnection:Disconnect() end
				return
			end

			local now = Workspace:GetServerTimeNow()
			local progress = math.clamp((now - flightStartTime) / flightDuration, 0, 1)
			local smoothProgress = progress * progress -- Accelerating into impact
			local currentPos = spawnPos:Lerp(targetPos, smoothProgress)
			proj.CFrame = CFrame.new(currentPos)

			if progress >= 1 or now >= impactTime then
				if flightConnection then flightConnection:Disconnect() end
				-- Impact burst
				local burstTween = TweenService:Create(proj, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
					Size = Vector3.new(4.5, 4.5, 4.5),
					Transparency = 1,
				})
				burstTween:Play()
				task.delay(0.18, function()
					if proj and proj.Parent then proj:Destroy() end
				end)

				-- Enemy recovery
				if enemyModel and enemyModel.PrimaryPart then
					local tRecover = TweenService:Create(enemyModel.PrimaryPart, TweenInfo.new(recoveryDuration, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), { CFrame = originPivot })
					tRecover:Play()
				end
			end
		end)

		if flightConnection then
			trackConnection(windowId, flightConnection)
			activeAnimations[windowId .. "_proj"] = flightConnection
		end
	end

	local now = Workspace:GetServerTimeNow()
	if now >= flightStartTime then
		launchProjectile()
	else
		task.delay(flightStartTime - now, launchProjectile)
	end
end

-- D) AOE ATTACK: Ground Charge Expansion -> Detonation at ImpactServerTime -> Fade
local function playAoEAttack(win: StateTypes.ReactionWindowView, enemyModel: Model?)
	local originPivot = (enemyModel and enemyModel:GetPivot()) or CFrame.new(0, 4, -16)
	if enemyModel then
		enemyOriginalPivots[enemyModel] = originPivot
	end

	local startTime = win.AttackStartServerTime
	local impactTime = win.ImpactServerTime
	local totalChargeTime = math.max(0.1, impactTime - startTime)

	local container = getVfxContainer()

	local isMovementHazard = win.AvoidanceMode == "Movement"
	-- Movement hazards are centered on the snapshotted target position; ordinary
	-- AoE explosions continue to originate from the attacker.
	local centerPos = if isMovementHazard
		then (win.TargetWorldPosition or win.TargetWorldPos or originPivot.Position)
		else (win.AttackerWorldPos or originPivot.Position)
	local aoeCenter = Vector3.new(centerPos.X, 0.4, centerPos.Z)
	local hazardDiameter = math.max(2, (win.HazardRadius or 7) * 2)

	local aoeZone = Instance.new("Part")
	aoeZone.Name = "CombatVFX_AoETelegraph"
	aoeZone.Shape = Enum.PartType.Cylinder
	aoeZone.Size = if isMovementHazard then Vector3.new(0.2, hazardDiameter, hazardDiameter) else Vector3.new(0.2, 4, 4)
	aoeZone.CFrame = CFrame.new(aoeCenter) * CFrame.Angles(0, 0, math.rad(90))
	aoeZone.Material = Enum.Material.Neon
	aoeZone.Color = if isMovementHazard then Color3.fromRGB(225, 45, 255) else Color3.fromRGB(240, 50, 50)
	aoeZone.Transparency = 0.65
	aoeZone.Anchored = true
	aoeZone.CanCollide = false
	aoeZone.Parent = container
	table.insert(activeVfxInstances, aoeZone)

	local windowId = win.WindowId
	local aoeConn: RBXScriptConnection? = nil
	local detonated = false

	aoeConn = RunService.Heartbeat:Connect(function()
		if not aoeZone or not aoeZone.Parent then
			if aoeConn then aoeConn:Disconnect() end
			return
		end

		local now = Workspace:GetServerTimeNow()
		local alpha = math.clamp((now - startTime) / totalChargeTime, 0, 1)
		local quadAlpha = alpha * alpha
		local diam = if isMovementHazard then hazardDiameter else 4 + (41 * quadAlpha)
		aoeZone.Size = Vector3.new(0.2, diam, diam)
		if isMovementHazard then
			aoeZone.Transparency = 0.45 + (math.sin(alpha * math.pi * 8) * 0.08)
		else
			aoeZone.Transparency = 0.65 - (0.30 * quadAlpha)
		end

		if now >= impactTime and not detonated then
			detonated = true
			if aoeConn then
				aoeConn:Disconnect()
				activeAnimations[windowId .. "_aoe"] = nil
			end

			-- Flash explosion
			local tDetonate = TweenService:Create(aoeZone, TweenInfo.new(0.25, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {
				Size = if isMovementHazard then Vector3.new(0.8, hazardDiameter + 4, hazardDiameter + 4) else Vector3.new(0.8, 55, 55),
				Color = Color3.fromRGB(255, 220, 100),
				Transparency = 1,
			})
			tDetonate:Play()
			task.delay(0.25, function()
				if aoeZone and aoeZone.Parent then aoeZone:Destroy() end
			end)
		end
	end)

	if aoeConn then
		trackConnection(windowId, aoeConn)
		activeAnimations[windowId .. "_aoe"] = aoeConn
	end
end

--------------------------------------------------------------------------------
-- Reaction Window Synchronization & Model Discovery Retry
--------------------------------------------------------------------------------

local function startAttackVisual(win: StateTypes.ReactionWindowView): boolean
	local enemyInstanceId = win.EnemyInstanceId
	local enemyModel = findEnemyModel(enemyInstanceId)

	local aType = win.AttackType
	if aType == "Melee" or aType == "Jump" then
		-- Melee and Jump attacks strictly require the enemy model and its PrimaryPart
		if not enemyModel or not enemyModel.PrimaryPart then
			return false
		end
	elseif aType == "Projectile" or aType == "AoE" then
		-- Projectile and AoE prefer having the enemy model, but can proceed if model is missing at/after flight/charge time
		local now = Workspace:GetServerTimeNow()
		local startTime = win.AttackStartServerTime
		local impactTime = win.ImpactServerTime
		local triggerTime = if aType == "Projectile"
			then (startTime + math.max(0.15, (impactTime - startTime) * 0.25))
			else impactTime

		if (not enemyModel or not enemyModel.PrimaryPart) and now < triggerTime then
			return false
		end
	end

	playbackStarted[win.WindowId] = true

	if aType == "Melee" then
		playMeleeAttack(win, enemyModel :: Model)
	elseif aType == "Jump" then
		playJumpAttack(win, enemyModel :: Model)
	elseif aType == "Projectile" then
		playProjectileAttack(win, enemyModel)
	elseif aType == "AoE" then
		playAoEAttack(win, enemyModel)
	else
		warn(string.format("[CombatVFXController] Unknown attack type '%s' for attack '%s'; defaulting to Melee presentation.", tostring(aType), tostring(win.AttackName)))
		if enemyModel and enemyModel.PrimaryPart then
			playMeleeAttack(win, enemyModel)
		else
			return false
		end
	end

	return true
end

local function startModelRetry(win: StateTypes.ReactionWindowView)
	if pendingRetryWindow and pendingRetryWindow.WindowId == win.WindowId and pendingRetryConnection then
		return
	end

	stopModelRetry()
	pendingRetryWindow = win

	local closeDeadline = win.ReactionCloseServerTime or (win.ImpactServerTime + (win.RecoveryDuration or 0.35) + 0.1)

	pendingRetryConnection = RunService.Heartbeat:Connect(function()
		if currentActiveWindowId ~= win.WindowId then
			stopModelRetry()
			return
		end

		local now = Workspace:GetServerTimeNow()
		if now > closeDeadline then
			stopModelRetry()
			return
		end

		if startAttackVisual(win) then
			stopModelRetry()
			return
		end
	end)
end

local function onReactionWindowChanged(win: StateTypes.ReactionWindowView?)
	if not win then
		if currentActiveWindowId then
			cleanupActiveAttack(currentActiveWindowId)
			currentActiveWindowId = nil
		end
		return
	end

	-- If this exact window already successfully started playback, ignore duplicate snapshot
	if currentActiveWindowId == win.WindowId and playbackStarted[win.WindowId] then
		return
	end

	-- If a different window was active, clean it up
	if currentActiveWindowId and currentActiveWindowId ~= win.WindowId then
		cleanupActiveAttack(currentActiveWindowId)
	end

	currentActiveWindowId = win.WindowId

	-- Attempt to start visual immediately
	if startAttackVisual(win) then
		return
	end

	-- Enemy model not found yet. Begin bounded retry via Heartbeat.
	startModelRetry(win)
end

--------------------------------------------------------------------------------
-- Event Listener
--------------------------------------------------------------------------------

if CombatStateUpdateEvent then
	CombatStateUpdateEvent.OnClientEvent:Connect(function(snapshot: StateTypes.CombatSnapshot)
		if not snapshot then return end
		latestEnemyViews = snapshot.Enemies or {}
		onReactionWindowChanged(snapshot.ActiveReactionWindow)
	end)
end

if CombatEventLoggedEvent then
	CombatEventLoggedEvent.OnClientEvent:Connect(function(event: StateTypes.CombatEvent)
		if not event then return end
		if event.Type == "CardPresented" then
			playCardPresentation(event)
		end
		handleCombatFeedback(event)
	end)
end

print("[CombatVFXController] Initialized synchronized attacks, world combat numbers, hit flashes, and restrained camera feedback.")
