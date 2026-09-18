--!strict

--[=[
	WorldRoomService ModuleScript
	Mapped to: ServerScriptService.Server.services.WorldRoomService
	Authoritative 3D room and world lifecycle manager for Card Rift: Co-op Dungeon.
	1. Constructs and manages physical 3D spaces in Workspace.CardRiftWorld.ActiveRoom.
	2. Manages room templates, geometry, spawn locations, interactables, hazards, and environmental effects.
	3. Guarantees deterministic generation and zero-leakage cleanup between encounters.
	4. Teleports party members safely into player spawn points.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local StateTypes = require(Shared:WaitForChild("StateTypes") :: ModuleScript)

local WorldRoomService = {}

local WORLD_CONTAINER_NAME = "CardRiftWorld"
local ACTIVE_ROOM_NAME = "ActiveRoom"

local ARENA_ORIGIN = Vector3.new(0, 0, 0)
local DEFAULT_PLAYER_SPAWN = Vector3.new(0, 3, 16)
local DEFAULT_ENEMY_SPAWN = Vector3.new(0, 3, -16)

local currentActiveRoom: Model? = nil
local currentEnvironmentId: StateTypes.EnvironmentId? = "None"
local currentRoomTemplateId: string = "tpl_default"

--------------------------------------------------------------------------------
-- Container Lifecycle
--------------------------------------------------------------------------------

local function getOrCreateWorldContainer(): Folder
	local existing = Workspace:FindFirstChild(WORLD_CONTAINER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = WORLD_CONTAINER_NAME
	folder.Parent = Workspace
	return folder
end

function WorldRoomService.cleanupRoom()
	if currentActiveRoom then
		pcall(function()
			currentActiveRoom:Destroy()
		end)
		currentActiveRoom = nil
	end

	local worldContainer = Workspace:FindFirstChild(WORLD_CONTAINER_NAME)
	if worldContainer then
		local leftover = worldContainer:FindFirstChild(ACTIVE_ROOM_NAME)
		if leftover then
			pcall(function()
				leftover:Destroy()
			end)
		end
	end

	currentEnvironmentId = "None"
	currentRoomTemplateId = "tpl_default"
end

function WorldRoomService.getActiveRoomModel(): Model?
	return currentActiveRoom
end

function WorldRoomService.getActiveEnvironmentId(): StateTypes.EnvironmentId?
	return currentEnvironmentId
end

--------------------------------------------------------------------------------
-- Room Construction Engine
--------------------------------------------------------------------------------

local function buildActiveRoomContainer(templateId: string): (Model, Folder, Folder, Folder, Folder, Folder)
	local world = getOrCreateWorldContainer()

	local roomModel = Instance.new("Model")
	roomModel.Name = ACTIVE_ROOM_NAME
	roomModel:SetAttribute("TemplateId", templateId)
	roomModel.Parent = world

	local geometryFolder = Instance.new("Folder")
	geometryFolder.Name = "Geometry"
	geometryFolder.Parent = roomModel

	local spawnPointsFolder = Instance.new("Folder")
	spawnPointsFolder.Name = "SpawnPoints"
	spawnPointsFolder.Parent = roomModel

	local interactablesFolder = Instance.new("Folder")
	interactablesFolder.Name = "Interactables"
	interactablesFolder.Parent = roomModel

	local hazardsFolder = Instance.new("Folder")
	hazardsFolder.Name = "Hazards"
	hazardsFolder.Parent = roomModel

	local effectsFolder = Instance.new("Folder")
	effectsFolder.Name = "Effects"
	effectsFolder.Parent = roomModel

	return roomModel, geometryFolder, spawnPointsFolder, interactablesFolder, hazardsFolder, effectsFolder
end

local function spawnPlayerSpawnLocation(parent: Folder, position: Vector3): SpawnLocation
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "PlayerSpawn"
	spawn.Size = Vector3.new(8, 0.5, 8)
	spawn.Position = position
	spawn.Anchored = true
	spawn.Material = Enum.Material.Neon
	spawn.Color = Color3.fromRGB(50, 150, 255)
	spawn.Transparency = 0.8
	spawn.CanCollide = true
	spawn.Duration = 0
	spawn.Parent = parent
	return spawn
end

--------------------------------------------------------------------------------
-- Room Generators
--------------------------------------------------------------------------------

local function buildCombatArena(
	geometry: Folder,
	spawnPoints: Folder,
	environmentId: StateTypes.EnvironmentId
)
	-- Main Floor
	local floor = Instance.new("Part")
	floor.Name = "ArenaFloor"
	floor.Size = Vector3.new(54, 2, 54)
	floor.Position = ARENA_ORIGIN
	floor.Anchored = true
	floor.Material = Enum.Material.Cobblestone
	floor.Color = Color3.fromRGB(35, 38, 44)
	floor.TopSurface = Enum.SurfaceType.Smooth
	floor.Parent = geometry

	-- Glowing Perimeter Border
	local border = Instance.new("Part")
	border.Name = "ArenaBorder"
	border.Size = Vector3.new(56, 0.4, 56)
	border.Position = ARENA_ORIGIN + Vector3.new(0, 1.05, 0)
	border.Anchored = true
	border.Material = Enum.Material.Neon
	border.Color = Color3.fromRGB(60, 140, 220)
	border.CanCollide = false
	border.Transparency = 0.5
	border.Parent = geometry

	-- Player Pedestal
	local playerPad = Instance.new("Part")
	playerPad.Name = "PlayerPedestal"
	playerPad.Shape = Enum.PartType.Cylinder
	playerPad.Size = Vector3.new(0.6, 10, 10)
	playerPad.CFrame = CFrame.new(DEFAULT_PLAYER_SPAWN - Vector3.new(0, 1.8, 0)) * CFrame.Angles(0, 0, math.rad(90))
	playerPad.Anchored = true
	playerPad.Material = Enum.Material.Neon
	playerPad.Color = Color3.fromRGB(45, 120, 240)
	playerPad.Parent = geometry

	-- Enemy Pedestal
	local enemyPad = Instance.new("Part")
	enemyPad.Name = "EnemyPedestal"
	enemyPad.Shape = Enum.PartType.Cylinder
	enemyPad.Size = Vector3.new(0.6, 14, 14)
	enemyPad.CFrame = CFrame.new(DEFAULT_ENEMY_SPAWN - Vector3.new(0, 1.8, 0)) * CFrame.Angles(0, 0, math.rad(90))
	enemyPad.Anchored = true
	enemyPad.Material = Enum.Material.Neon
	enemyPad.Color = Color3.fromRGB(200, 45, 45)
	enemyPad.Parent = geometry

	-- Perimeter Pillars
	local pillarPositions = {
		Vector3.new(-24, 6, -24),
		Vector3.new(24, 6, -24),
		Vector3.new(-24, 6, 24),
		Vector3.new(24, 6, 24),
	}
	for i, pos in pillarPositions do
		local pillar = Instance.new("Part")
		pillar.Name = "Pillar_" .. i
		pillar.Size = Vector3.new(3.5, 14, 3.5)
		pillar.Position = pos
		pillar.Anchored = true
		pillar.Material = Enum.Material.SmoothPlastic
		pillar.Color = Color3.fromRGB(25, 27, 32)
		pillar.Parent = geometry
	end

	-- Spawn Location
	spawnPlayerSpawnLocation(spawnPoints, DEFAULT_PLAYER_SPAWN)
end

local function buildEventChamber(
	geometry: Folder,
	spawnPoints: Folder,
	eventId: string?
)
	-- Chamber Floor
	local floor = Instance.new("Part")
	floor.Name = "ChamberFloor"
	floor.Size = Vector3.new(60, 2, 60)
	floor.Position = ARENA_ORIGIN
	floor.Anchored = true
	floor.Material = Enum.Material.Marble
	floor.Color = Color3.fromRGB(40, 36, 52)
	floor.TopSurface = Enum.SurfaceType.Smooth
	floor.Parent = geometry

	-- Chamber Walls
	local wallConfigs = {
		{ Size = Vector3.new(62, 14, 2), Pos = Vector3.new(0, 7, -30) },
		{ Size = Vector3.new(62, 14, 2), Pos = Vector3.new(0, 7, 30) },
		{ Size = Vector3.new(2, 14, 62), Pos = Vector3.new(-30, 7, 0) },
		{ Size = Vector3.new(2, 14, 62), Pos = Vector3.new(30, 7, 0) },
	}
	for i, wc in wallConfigs do
		local wall = Instance.new("Part")
		wall.Name = "ChamberWall_" .. i
		wall.Size = wc.Size
		wall.Position = wc.Pos
		wall.Anchored = true
		wall.Material = Enum.Material.Slate
		wall.Color = Color3.fromRGB(26, 24, 36)
		wall.Parent = geometry
	end

	-- Central Dais / Altar
	local dais = Instance.new("Part")
	dais.Name = "CentralDais"
	dais.Size = Vector3.new(12, 1.2, 12)
	dais.Position = Vector3.new(0, 0.6, 0)
	dais.Anchored = true
	dais.Material = Enum.Material.Granite
	dais.Color = Color3.fromRGB(80, 50, 130)
	dais.Parent = geometry

	-- Player Spawn
	spawnPlayerSpawnLocation(spawnPoints, Vector3.new(0, 2.5, 20))
end

local function buildCampfireGrove(geometry: Folder, spawnPoints: Folder)
	local floor = Instance.new("Part")
	floor.Name = "GroveFloor"
	floor.Size = Vector3.new(50, 2, 50)
	floor.Position = ARENA_ORIGIN
	floor.Anchored = true
	floor.Material = Enum.Material.Grass
	floor.Color = Color3.fromRGB(45, 80, 45)
	floor.Parent = geometry

	-- Fire Pit
	local pit = Instance.new("Part")
	pit.Name = "CampfirePit"
	pit.Size = Vector3.new(6, 1, 6)
	pit.Position = Vector3.new(0, 0.5, 0)
	pit.Anchored = true
	pit.Material = Enum.Material.Cobblestone
	pit.Color = Color3.fromRGB(60, 60, 60)
	pit.Parent = geometry

	local flame = Instance.new("Part")
	flame.Name = "FlameCore"
	flame.Size = Vector3.new(2, 3, 2)
	flame.Position = Vector3.new(0, 2, 0)
	flame.Anchored = true
	flame.CanCollide = false
	flame.Material = Enum.Material.Neon
	flame.Color = Color3.fromRGB(255, 120, 30)
	flame.Parent = geometry

	local fireLight = Instance.new("PointLight")
	fireLight.Range = 25
	fireLight.Brightness = 2.5
	fireLight.Color = Color3.fromRGB(255, 150, 50)
	fireLight.Parent = flame

	spawnPlayerSpawnLocation(spawnPoints, Vector3.new(0, 2.5, 12))
end

local function buildMerchantBazaar(geometry: Folder, spawnPoints: Folder)
	local floor = Instance.new("Part")
	floor.Name = "BazaarFloor"
	floor.Size = Vector3.new(50, 2, 50)
	floor.Position = ARENA_ORIGIN
	floor.Anchored = true
	floor.Material = Enum.Material.WoodPlanks
	floor.Color = Color3.fromRGB(90, 65, 45)
	floor.Parent = geometry

	-- Merchant Stall Counter
	local stall = Instance.new("Part")
	stall.Name = "MerchantCounter"
	stall.Size = Vector3.new(16, 3.5, 4)
	stall.Position = Vector3.new(0, 1.75, -8)
	stall.Anchored = true
	stall.Material = Enum.Material.Wood
	stall.Color = Color3.fromRGB(120, 85, 55)
	stall.Parent = geometry

	spawnPlayerSpawnLocation(spawnPoints, Vector3.new(0, 2.5, 12))
end

--------------------------------------------------------------------------------
-- Environmental Presentation
--------------------------------------------------------------------------------

function WorldRoomService.applyEnvironmentVisuals(environmentId: StateTypes.EnvironmentId)
	if not currentActiveRoom then return end
	local effectsFolder = currentActiveRoom:FindFirstChild("Effects") :: Folder?
	if not effectsFolder then return end

	-- Clean up previous effects
	effectsFolder:ClearAllChildren()

	local geometryFolder = currentActiveRoom:FindFirstChild("Geometry") :: Folder?
	local floorPart = geometryFolder and geometryFolder:FindFirstChildWhichIsA("BasePart")

	if environmentId == "RainSoaked" then
		if floorPart then
			floorPart.Color = Color3.fromRGB(28, 38, 48)
			floorPart.Material = Enum.Material.Cobblestone
		end

		local rainEmitterPart = Instance.new("Part")
		rainEmitterPart.Name = "RainEmitter"
		rainEmitterPart.Size = Vector3.new(50, 1, 50)
		rainEmitterPart.Position = Vector3.new(0, 25, 0)
		rainEmitterPart.Anchored = true
		rainEmitterPart.Transparency = 1
		rainEmitterPart.CanCollide = false
		rainEmitterPart.Parent = effectsFolder

		local rainLight = Instance.new("PointLight")
		rainLight.Name = "RainAtmosphere"
		rainLight.Color = Color3.fromRGB(80, 140, 200)
		rainLight.Brightness = 1.0
		rainLight.Range = 40
		rainLight.Parent = rainEmitterPart

	elseif environmentId == "LavaCavern" then
		if floorPart then
			floorPart.Color = Color3.fromRGB(45, 20, 15)
			floorPart.Material = Enum.Material.Basalt
		end

		local lavaLight = Instance.new("PointLight")
		lavaLight.Name = "LavaGlow"
		lavaLight.Color = Color3.fromRGB(255, 80, 20)
		lavaLight.Brightness = 2.0
		lavaLight.Range = 45
		lavaLight.Position = Vector3.new(0, 4, 0)
		local glowAnchor = Instance.new("Part")
		glowAnchor.Name = "LavaAnchor"
		glowAnchor.Size = Vector3.new(1, 1, 1)
		glowAnchor.Position = Vector3.new(0, 3, 0)
		glowAnchor.Anchored = true
		glowAnchor.Transparency = 1
		glowAnchor.CanCollide = false
		lavaLight.Parent = glowAnchor
		glowAnchor.Parent = effectsFolder

	elseif environmentId == "FrozenWastes" then
		if floorPart then
			floorPart.Color = Color3.fromRGB(180, 210, 240)
			floorPart.Material = Enum.Material.Ice
		end

		local frostAnchor = Instance.new("Part")
		frostAnchor.Name = "FrostAnchor"
		frostAnchor.Size = Vector3.new(1, 1, 1)
		frostAnchor.Position = Vector3.new(0, 5, 0)
		frostAnchor.Anchored = true
		frostAnchor.Transparency = 1
		frostAnchor.CanCollide = false
		frostAnchor.Parent = effectsFolder

		local frostLight = Instance.new("PointLight")
		frostLight.Name = "FrostGlow"
		frostLight.Color = Color3.fromRGB(150, 220, 255)
		frostLight.Brightness = 1.5
		frostLight.Range = 40
		frostLight.Parent = frostAnchor

	elseif environmentId == "ToxicSwamp" then
		if floorPart then
			floorPart.Color = Color3.fromRGB(25, 45, 20)
			floorPart.Material = Enum.Material.Mud
		end

		local toxicAnchor = Instance.new("Part")
		toxicAnchor.Name = "ToxicAnchor"
		toxicAnchor.Size = Vector3.new(1, 1, 1)
		toxicAnchor.Position = Vector3.new(0, 4, 0)
		toxicAnchor.Anchored = true
		toxicAnchor.Transparency = 1
		toxicAnchor.CanCollide = false
		toxicAnchor.Parent = effectsFolder

		local toxicLight = Instance.new("PointLight")
		toxicLight.Name = "ToxicGlow"
		toxicLight.Color = Color3.fromRGB(80, 240, 70)
		toxicLight.Brightness = 1.6
		toxicLight.Range = 40
		toxicLight.Parent = toxicAnchor

	elseif environmentId == "ArcaneStorm" then
		if floorPart then
			floorPart.Color = Color3.fromRGB(35, 25, 55)
			floorPart.Material = Enum.Material.Glass
		end

		local arcaneAnchor = Instance.new("Part")
		arcaneAnchor.Name = "ArcaneAnchor"
		arcaneAnchor.Size = Vector3.new(1, 1, 1)
		arcaneAnchor.Position = Vector3.new(0, 6, 0)
		arcaneAnchor.Anchored = true
		arcaneAnchor.Transparency = 1
		arcaneAnchor.CanCollide = false
		arcaneAnchor.Parent = effectsFolder

		local arcaneLight = Instance.new("PointLight")
		arcaneLight.Name = "ArcaneGlow"
		arcaneLight.Color = Color3.fromRGB(190, 80, 255)
		arcaneLight.Brightness = 2.2
		arcaneLight.Range = 50
		arcaneLight.Parent = arcaneAnchor
	end
end

--------------------------------------------------------------------------------
-- Interactable Spawner for 3D Puzzles
--------------------------------------------------------------------------------

function WorldRoomService.createInteractable(
	id: string,
	name: string,
	modelType: string,
	position: Vector3,
	label: string?
): Instance
	if not currentActiveRoom then
		error("[WorldRoomService] Cannot spawn interactable without active room.")
	end

	local interactablesFolder = currentActiveRoom:FindFirstChild("Interactables") :: Folder
	assert(interactablesFolder, "Interactables folder exists")

	local part = Instance.new("Part")
	part.Name = id
	part.Position = position
	part.Anchored = true
	part.CanCollide = true
	part:SetAttribute("InteractableId", id)
	part:SetAttribute("InteractableName", name)
	part:SetAttribute("InteractableType", modelType)

	if modelType == "Rune" then
		part.Size = Vector3.new(3, 4, 3)
		part.Material = Enum.Material.Neon
		part.Color = Color3.fromRGB(100, 180, 255)

		-- Overhead billboard
		local bb = Instance.new("BillboardGui")
		bb.Name = "RuneBillboard"
		bb.Size = UDim2.new(0, 140, 0, 40)
		bb.StudsOffset = Vector3.new(0, 3.5, 0)
		bb.AlwaysOnTop = true
		bb.Parent = part

		local txt = Instance.new("TextLabel")
		txt.Size = UDim2.new(1, 0, 1, 0)
		txt.BackgroundTransparency = 1
		txt.Text = label or name
		txt.TextColor3 = Color3.fromRGB(255, 255, 255)
		txt.TextStrokeTransparency = 0.2
		txt.TextSize = 14
		txt.Font = Enum.Font.GothamBold
		txt.Parent = bb

	elseif modelType == "Statue" then
		part.Size = Vector3.new(4, 9, 4)
		part.Material = Enum.Material.Marble
		part.Color = Color3.fromRGB(220, 220, 230)

		local bb = Instance.new("BillboardGui")
		bb.Name = "StatueBillboard"
		bb.Size = UDim2.new(0, 160, 0, 45)
		bb.StudsOffset = Vector3.new(0, 6, 0)
		bb.AlwaysOnTop = true
		bb.Parent = part

		local txt = Instance.new("TextLabel")
		txt.Size = UDim2.new(1, 0, 1, 0)
		txt.BackgroundTransparency = 1
		txt.Text = label or name
		txt.TextColor3 = Color3.fromRGB(255, 230, 120)
		txt.TextStrokeTransparency = 0.2
		txt.TextSize = 13
		txt.Font = Enum.Font.GothamBold
		txt.Parent = bb
	else
		part.Size = Vector3.new(3, 3, 3)
		part.Material = Enum.Material.SmoothPlastic
		part.Color = Color3.fromRGB(180, 180, 180)
	end

	-- Add ClickDetector for physical in-game interaction
	local clickDetector = Instance.new("ClickDetector")
	clickDetector.MaxActivationDistance = 32
	clickDetector.Parent = part

	part.Parent = interactablesFolder
	return part
end

function WorldRoomService.getInteractable(interactableId: string): Instance?
	if not currentActiveRoom then return nil end
	local folder = currentActiveRoom:FindFirstChild("Interactables")
	return folder and folder:FindFirstChild(interactableId)
end

--------------------------------------------------------------------------------
-- Room Loading & Teleportation
--------------------------------------------------------------------------------

function WorldRoomService.loadRoom(
	roomType: StateTypes.ActiveRoomType,
	tier: number,
	actIndex: number,
	encounterId: string?,
	environmentId: StateTypes.EnvironmentId?,
	seed: number?
): Model
	-- 1. Clean up prior room completely
	WorldRoomService.cleanupRoom()

	-- 2. Deterministic template identification
	local env = environmentId or "None"
	currentEnvironmentId = env
	currentRoomTemplateId = string.format("tpl_%s_%d", string.gsub(roomType, "%s+", "_"), tier)

	-- 3. Build container tree
	local roomModel, geometry, spawnPoints, interactables, hazards, effects = buildActiveRoomContainer(currentRoomTemplateId)
	currentActiveRoom = roomModel

	-- 4. Construct geometry based on RoomType
	if roomType == "Combat" or roomType == "Elite Monster" or roomType == "Act Boss" then
		buildCombatArena(geometry, spawnPoints, env)
	elseif roomType == "Event" then
		buildEventChamber(geometry, spawnPoints, encounterId)
	elseif roomType == "Campfire Rest" then
		buildCampfireGrove(geometry, spawnPoints)
	elseif roomType == "Merchant Shop" then
		buildMerchantBazaar(geometry, spawnPoints)
	else
		buildCombatArena(geometry, spawnPoints, env)
	end

	-- 5. Apply environment visual preset if applicable
	if env ~= "None" then
		WorldRoomService.applyEnvironmentVisuals(env)
	end

	return roomModel
end

function WorldRoomService.teleportPlayers(partyMembers: { any }, customSpawnPosition: Vector3?)
	local targetPos = customSpawnPosition or DEFAULT_PLAYER_SPAWN

	if currentActiveRoom then
		local spFolder = currentActiveRoom:FindFirstChild("SpawnPoints")
		local spawnLoc = spFolder and spFolder:FindFirstChildWhichIsA("SpawnLocation")
		if spawnLoc then
			targetPos = spawnLoc.Position + Vector3.new(0, 3.5, 0)
		end
	end

	local offsetIndex = 0
	for _, member in partyMembers do
		local playerInstance: Player? = nil
		if typeof(member) == "Instance" and member:IsA("Player") then
			playerInstance = member
		elseif typeof(member) == "table" and member.PlayerInstance and member.PlayerInstance:IsA("Player") then
			playerInstance = member.PlayerInstance
		end

		if playerInstance and playerInstance.Character then
			local root = playerInstance.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root then
				local offsetX = (offsetIndex - 1.5) * 4
				root.CFrame = CFrame.new(targetPos + Vector3.new(offsetX, 0, 0))
				offsetIndex += 1
			end
		end
	end
end

function WorldRoomService.init()
	getOrCreateWorldContainer()
	print("[WorldRoomService] Initialized authoritative 3D room and world lifecycle manager.")
end

return WorldRoomService
