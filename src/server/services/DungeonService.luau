--!strict

--[=[
	DungeonService ModuleScript
	Mapped to: ServerScriptService.Server.services.DungeonService
	Encapsulates procedural dungeon tree generation and path traversal logic.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DungeonMap = require(Shared:WaitForChild("DungeonMap") :: ModuleScript)

local DungeonService = {}

function DungeonService.generateRun(): DungeonMap.DungeonRun
	return DungeonMap.generateRun()
end

function DungeonService.getAvailableNodes(run: DungeonMap.DungeonRun): { DungeonMap.DungeonNode }
	return DungeonMap.getAvailableNextNodes(run)
end

function DungeonService.validateNode(run: DungeonMap.DungeonRun, nodeId: string): (boolean, string?, DungeonMap.DungeonNode?)
	return DungeonMap.validateNextNode(run, nodeId)
end

function DungeonService.commitNode(run: DungeonMap.DungeonRun, node: DungeonMap.DungeonNode)
	DungeonMap.commitNextNode(run, node)
end

function DungeonService.selectNode(run: DungeonMap.DungeonRun, nodeId: string): (boolean, string?)
	return DungeonMap.selectNextNode(run, nodeId)
end

function DungeonService.getNode(run: DungeonMap.DungeonRun, nodeId: string): DungeonMap.DungeonNode?
	return DungeonMap.getNode(run, nodeId)
end

function DungeonService.markNodeCleared(run: DungeonMap.DungeonRun, nodeId: string)
	DungeonMap.markNodeCleared(run, nodeId)
end

function DungeonService.init()
	print("[DungeonService] Initialized procedural dungeon pathfinding service.")
end

return DungeonService
