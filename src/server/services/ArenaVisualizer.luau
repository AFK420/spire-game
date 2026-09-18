--!strict

--[=[
	ArenaVisualizer ModuleScript
	Mapped to: ServerScriptService.Server.services.ArenaVisualizer
	Reactive 3D View Layer in Workspace for Card Rift: Co-op Dungeon:
	1. Constructs the 3D Battle Arena platform, perimeter pillars, and pedestals.
	2. Spawns visual 3D representations of active enemies with overhead BillboardGuis.
	3. Reactively updates health bars, shield counters, and intent icons.
	4. Performs attack animations and damage hit reactions.
	5. Cleans up visual models on room exit.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)

local ArenaVisualizer = {}

--------------------------------------------------------------------------------
-- Arena Coordinates & Configuration
--------------------------------------------------------------------------------

local ARENA_ORIGIN = Vector3.new(0, 0, 0)
local PLAYER_STAND_POS = Vector3.new(0, 1.2, 16)
local ENEMY_STAND_POS = Vector3.new(0, 1.2, -16)

local spawnedEnemyModels: { [string]: Model } = {}

--------------------------------------------------------------------------------
-- 3D Arena Construction
--------------------------------------------------------------------------------

function ArenaVisualizer.buildArena(): Model
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
	floor.Position = ARENA_ORIGIN
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

	-- Player Pedestal
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

	-- Enemy Pedestal
	local enemyPad = Instance.new("Part")
	enemyPad.Name = "EnemyPedestal"
	enemyPad.Shape = Enum.PartType.Cylinder
	enemyPad.Size = Vector3.new(0.6, 12, 12)
	enemyPad.CFrame = CFrame.new(ENEMY_STAND_POS) * CFrame.Angles(0, 0, math.rad(90))
	enemyPad.Anchored = true
	enemyPad.Material = Enum.Material.Neon
	enemyPad.Color = Color3.fromRGB(200, 45, 45)
	enemyPad.Parent = arenaModel

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

--------------------------------------------------------------------------------
-- 3D Enemy Spawner & Billboard
--------------------------------------------------------------------------------

local function buildEnemyModel(enemy: StateTypes.EnemyState, worldPos: Vector3): Model
	local model = Instance.new("Model")
	model.Name = "Enemy_" .. enemy.InstanceId

	-- Torso
	local torso = Instance.new("Part")
	torso.Name = "HumanoidRootPart"
	torso.Size = Vector3.new(3.5, 4.5, 2.5)
	torso.CFrame = CFrame.new(worldPos + Vector3.new(0, 4, 0))
	torso.Anchored = true
	torso.Material = Enum.Material.Granite
	torso.Color = Color3.fromRGB(35, 35, 45)
	torso.Parent = model
	model.PrimaryPart = torso

	-- Glowing Core Chest
	local chestCore = Instance.new("Part")
	chestCore.Name = "ChestCore"
	chestCore.Size = Vector3.new(1.8, 2, 0.5)
	chestCore.CFrame = torso.CFrame * CFrame.new(0, 0.3, -1.1)
	chestCore.Anchored = true
	chestCore.Material = Enum.Material.Neon
	chestCore.Color = Color3.fromRGB(220, 40, 40)
	chestCore.Parent = model

	-- Head
	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(2, 2, 2)
	head.CFrame = torso.CFrame * CFrame.new(0, 3.2, 0)
	head.Anchored = true
	head.Material = Enum.Material.Basalt
	head.Color = Color3.fromRGB(20, 20, 25)
	head.Parent = model

	-- Visor
	local visor = Instance.new("Part")
	visor.Name = "Visor"
	visor.Size = Vector3.new(1.5, 0.4, 0.3)
	visor.CFrame = head.CFrame * CFrame.new(0, 0.1, -0.9)
	visor.Anchored = true
	visor.CanCollide = false
	visor.Material = Enum.Material.Neon
	visor.Color = Color3.fromRGB(255, 60, 60)
	visor.Parent = model

	-- Weld subparts to torso root so Model:PivotTo() moves the entire coherent assembly
	local function weldToTorso(subPart: BasePart)
		local weld = Instance.new("WeldConstraint")
		weld.Name = subPart.Name .. "_Weld"
		weld.Part0 = torso
		weld.Part1 = subPart
		weld.Parent = torso
	end
	weldToTorso(chestCore)
	weldToTorso(head)
	weldToTorso(visor)

	-- Overhead BillboardGui
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "OverheadDisplay"
	billboard.Size = UDim2.new(7, 0, 3, 0)
	billboard.StudsOffset = Vector3.new(0, 5, 0)
	billboard.AlwaysOnTop = true
	billboard.Adornee = head

	local container = Instance.new("Frame")
	container.Name = "Container"
	container.Size = UDim2.new(1, 0, 1, 0)
	container.BackgroundTransparency = 1
	container.Parent = billboard

	local title = Instance.new("TextLabel")
	title.Name = "EnemyTitle"
	title.Size = UDim2.new(1, 0, 0.3, 0)
	title.BackgroundTransparency = 1
	title.Text = "👹 " .. enemy.Name
	title.TextColor3 = Color3.fromRGB(255, 80, 80)
	title.TextScaled = true
	title.Font = Enum.Font.GothamBold
	title.Parent = container

	local hpBg = Instance.new("Frame")
	hpBg.Name = "HPBackground"
	hpBg.Size = UDim2.new(0.9, 0, 0.22, 0)
	hpBg.Position = UDim2.new(0.05, 0, 0.35, 0)
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
	hpText.Text = string.format("%d / %d HP", enemy.HP, enemy.MaxHP)
	hpText.TextColor3 = Color3.fromRGB(255, 255, 255)
	hpText.TextScaled = true
	hpText.Font = Enum.Font.GothamBold
	hpText.Parent = hpBg

	local statusBar = Instance.new("TextLabel")
	statusBar.Name = "StatusBar"
	statusBar.Size = UDim2.new(1, 0, 0.3, 0)
	statusBar.Position = UDim2.new(0, 0, 0.65, 0)
	statusBar.BackgroundTransparency = 1
	statusBar.Text = string.format("🛡️ %d   🧪 %d   |   %s (%d)", enemy.Shield, enemy.Poison, enemy.Intent.Type, enemy.Intent.Value)
	statusBar.TextColor3 = Color3.fromRGB(240, 230, 180)
	statusBar.TextScaled = true
	statusBar.Font = Enum.Font.GothamMedium
	statusBar.Parent = container

	billboard.Parent = model

	local cardRiftWorld = Workspace:FindFirstChild("CardRiftWorld")
	local activeRoom = cardRiftWorld and cardRiftWorld:FindFirstChild("ActiveRoom")
	model.Parent = activeRoom or Workspace
	return model
end

--------------------------------------------------------------------------------
-- Public Methods: Sync, Animations, Position Players
--------------------------------------------------------------------------------

function ArenaVisualizer.syncEnemies(enemies: { [string]: StateTypes.EnemyState })
	-- Destroy removed enemies
	for instId, model in spawnedEnemyModels do
		if not enemies[instId] or enemies[instId].HP <= 0 then
			model:Destroy()
			spawnedEnemyModels[instId] = nil
		end
	end

	-- Count alive enemies
	local aliveList = {}
	for _, e in enemies do
		if e.HP > 0 then
			table.insert(aliveList, e)
		end
	end

	-- Position offsets for 1 to N enemies
	local count = #aliveList
	for i, enemy in aliveList do
		local offset = Vector3.zero
		if count == 2 then
			offset = Vector3.new((i == 1 and -4 or 4), 0, 0)
		elseif count >= 3 then
			offset = Vector3.new((i - 2) * 5, 0, 0)
		end

		local targetPos = ENEMY_STAND_POS + offset
		local ok, err = pcall(function()
			local model = spawnedEnemyModels[enemy.InstanceId]
			if not model or not model.Parent then
				model = buildEnemyModel(enemy, targetPos)
				spawnedEnemyModels[enemy.InstanceId] = model
			end

			-- Update billboard
			local head = model:FindFirstChild("Head")
			if head then
				local billboard = head:FindFirstChild("OverheadDisplay") :: BillboardGui?
				if billboard then
					local container = billboard:FindFirstChild("Container") :: Frame?
					if container then
						local hpBg = container:FindFirstChild("HPBackground") :: Frame?
						if hpBg then
							local hpFill = hpBg:FindFirstChild("HPFill") :: Frame?
							local hpText = hpBg:FindFirstChild("HPText") :: TextLabel?
							if hpFill and hpText then
								local ratio = math.clamp(enemy.HP / math.max(1, enemy.MaxHP), 0, 1)
								hpFill.Size = UDim2.new(ratio, 0, 1, 0)
								hpText.Text = string.format("%d / %d HP", enemy.HP, enemy.MaxHP)
							end
						end

						local statusBar = container:FindFirstChild("StatusBar") :: TextLabel?
						if statusBar then
							statusBar.Text = string.format("🛡️ %d   🧪 %d   |   %s (%d)", enemy.Shield, enemy.Poison, enemy.Intent.Type, enemy.Intent.Value)
						end
					end
				end
			end
		end)
		if not ok then
			warn(string.format("[ArenaVisualizer] syncEnemies error for %s: %s", enemy.InstanceId, tostring(err)))
		end
	end
end

function ArenaVisualizer.getEnemyModel(enemyInstanceId: string): Model?
	return spawnedEnemyModels[enemyInstanceId]
end

function ArenaVisualizer.playEnemyAttackAnimation(
	enemyInstanceId: string,
	telegraphDuration: number?,
	impactDelay: number?,
	recoveryDuration: number?,
	attackType: StateTypes.AttackType?,
	targetWorldPos: Vector3?
)
	-- Single Source of Truth for 3D Visuals:
	-- The server does NOT run competing cosmetic attack tweens or spawn duplicate projectiles.
	-- All cosmetic attack motions (melee lunges, jump arcs, projectile flight, AoE telegraphs)
	-- are exclusively rendered by CombatVFXController on the client driven by synchronized server timestamps.
	local model = spawnedEnemyModels[enemyInstanceId]
	if not model or not model.PrimaryPart then return end
end

function ArenaVisualizer.teleportPlayersToPedestal()
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			local char = player.Character
			if not char then
				local start = os.clock()
				while not player.Character and (os.clock() - start < 3.0) do
					task.wait(0.1)
				end
				char = player.Character
			end
			if char then
				local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
				if root then
					root.CFrame = CFrame.lookAt(PLAYER_STAND_POS + Vector3.new(0, 3, 0), ENEMY_STAND_POS)
				end
			end
		end)
	end
end

function ArenaVisualizer.cleanup()
	for _, model in spawnedEnemyModels do
		pcall(function()
			model:Destroy()
		end)
	end
	table.clear(spawnedEnemyModels)
end

function ArenaVisualizer.init()
	-- WorldRoomService is the canonical room geometry and player positioning system.
	-- Redundant CombatArena construction and independent player teleportation at startup are eliminated.
	print("[ArenaVisualizer] Initialized reactive 3D arena visualizer.")
end

return ArenaVisualizer
