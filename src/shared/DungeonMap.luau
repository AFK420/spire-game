--!strict

--[=[
	DungeonMap ModuleScript
	Generates a procedural multi-act dungeon tree inspired by deckbuilders (e.g. Slay the Spire).
	- 4 Acts per run
	- 10 vertical tiers per Act
	- Randomized nodes: Combat, Elite Monster, Campfire Rest, Merchant Shop, and Act Boss
	- Path connectivity verification
	- Navigation API to fetch reachable nodes and travel between rooms
]=]

local DungeonMap = {}

--------------------------------------------------------------------------------
-- Type Definitions
--------------------------------------------------------------------------------

export type NodeType =
	| "Combat"
	| "Elite Monster"
	| "Campfire Rest"
	| "Merchant Shop"
	| "Act Boss"

export type NodeMetadata = {
	DisplayName: string,
	Icon: string,
	Color: Color3,
	Description: string,
}

export type DungeonNode = {
	Id: string,                  -- Unique ID, e.g. "Act1_T3_L2"
	Act: number,                -- 1..4
	Tier: number,               -- 1..10 (Vertical progression)
	Lane: number,               -- 1..5 (Horizontal layout position)
	Type: NodeType,             -- Room type
	IncomingNodeIds: { string },-- Connected nodes from Tier - 1
	OutgoingNodeIds: { string },-- Connected nodes to Tier + 1
}

export type Act = {
	ActNumber: number,
	Name: string,
	Tiers: { { DungeonNode } }, -- Tiers[tierIndex] = array of nodes in that tier (1..10)
	NodesById: { [string]: DungeonNode },
	BossNodeId: string,
}

export type DungeonRun = {
	Seed: number,
	Acts: { Act },               -- Array of 4 Acts
	CurrentActIndex: number,     -- 1..4
	CurrentTier: number,         -- 0 (not started) or 1..10
	CurrentNodeId: string?,      -- Currently occupied node ID
	ClearedNodeIds: { string },  -- History of visited node IDs
	IsCompleted: boolean,        -- True when Act 4 Boss is cleared
}

--------------------------------------------------------------------------------
-- Constants & Metadata
--------------------------------------------------------------------------------

local TOTAL_ACTS = 4
local TIERS_PER_ACT = 10
local LANES_COUNT = 5

local ACT_NAMES: { [number]: string } = {
	[1] = "Act 1: The Spire Threshold",
	[2] = "Act 2: The Sunken City",
	[3] = "Act 3: The Astral Beyond",
	[4] = "Act 4: The Heart Summit",
}

local NODE_METADATA: { [NodeType]: NodeMetadata } = {
	["Combat"] = {
		DisplayName = "Combat Encounter",
		Icon = "⚔️",
		Color = Color3.fromRGB(195, 55, 55),
		Description = "Battle standard spire creatures for cards and gold.",
	},
	["Elite Monster"] = {
		DisplayName = "Elite Monster",
		Icon = "💀",
		Color = Color3.fromRGB(220, 110, 30),
		Description = "Defeat a deadly elite enemy for rare relics and high rewards.",
	},
	["Campfire Rest"] = {
		DisplayName = "Campfire Rest",
		Icon = "🔥",
		Color = Color3.fromRGB(45, 175, 95),
		Description = "Rest to restore 30% Max HP or upgrade a card in your deck.",
	},
	["Merchant Shop"] = {
		DisplayName = "Merchant Shop",
		Icon = "💰",
		Color = Color3.fromRGB(225, 195, 45),
		Description = "Purchase cards, relics, and remove unwanted cards with gold.",
	},
	["Act Boss"] = {
		DisplayName = "Act Boss",
		Icon = "👹",
		Color = Color3.fromRGB(175, 35, 195),
		Description = "The guardian of this Act. Defeat to advance to the next Act.",
	},
}

--------------------------------------------------------------------------------
-- Helper Functions
--------------------------------------------------------------------------------

function DungeonMap.getNodeMetadata(nodeType: NodeType): NodeMetadata
	local meta = NODE_METADATA[nodeType]
	if meta then
		return meta
	end
	return {
		DisplayName = "Unknown Node",
		Icon = "❓",
		Color = Color3.fromRGB(150, 150, 150),
		Description = "Mysterious room.",
	}
end

-- Generates a deterministic node ID
local function makeNodeId(act: number, tier: number, lane: number): string
	return string.format("Act%d_T%d_L%d", act, tier, lane)
end

-- Determines node type according to progression rules
local function pickNodeType(tier: number, rng: Random): NodeType
	if tier == 1 then
		-- Tier 1 is always introductory combat
		return "Combat"
	elseif tier == TIERS_PER_ACT then
		-- Tier 10 is always the Act Boss
		return "Act Boss"
	elseif tier == TIERS_PER_ACT - 1 then
		-- Tier 9 (pre-boss) is guaranteed Campfire Rest to prepare for the boss
		return "Campfire Rest"
	elseif tier >= 2 and tier <= 4 then
		-- Early tiers: Mostly Combat, with occasional Shop or Campfire
		local roll = rng:NextNumber()
		if roll < 0.65 then
			return "Combat"
		elseif roll < 0.85 then
			return "Merchant Shop"
		else
			return "Campfire Rest"
		end
	else
		-- Mid/Late tiers (5..8): Introduces Elite Monsters
		local roll = rng:NextNumber()
		if roll < 0.40 then
			return "Combat"
		elseif roll < 0.70 then
			return "Elite Monster"
		elseif roll < 0.85 then
			return "Campfire Rest"
		else
			return "Merchant Shop"
		end
	end
end

--------------------------------------------------------------------------------
-- Act Tree Generator
--------------------------------------------------------------------------------

function DungeonMap.generateAct(actNumber: number, rng: Random): Act
	local tiers: { { DungeonNode } } = {}
	local nodesById: { [string]: DungeonNode } = {}

	-- Step 1: Generate Nodes for each Tier
	for tier = 1, TIERS_PER_ACT do
		tiers[tier] = {}

		if tier == TIERS_PER_ACT then
			-- Final Tier: Single Boss Node at center lane (Lane 3)
			local bossId = makeNodeId(actNumber, tier, 3)
			local bossNode: DungeonNode = {
				Id = bossId,
				Act = actNumber,
				Tier = tier,
				Lane = 3,
				Type = "Act Boss",
				IncomingNodeIds = {},
				OutgoingNodeIds = {},
			}
			table.insert(tiers[tier], bossNode)
			nodesById[bossId] = bossNode
		elseif tier == 1 then
			-- Starter Tier: 3 starting lanes (e.g. Lanes 1, 3, 5 or 2, 3, 4)
			local startLanes = { 1, 3, 5 }
			for _, lane in startLanes do
				local nodeId = makeNodeId(actNumber, tier, lane)
				local node: DungeonNode = {
					Id = nodeId,
					Act = actNumber,
					Tier = tier,
					Lane = lane,
					Type = "Combat",
					IncomingNodeIds = {},
					OutgoingNodeIds = {},
				}
				table.insert(tiers[tier], node)
				nodesById[nodeId] = node
			end
		elseif tier == TIERS_PER_ACT - 1 then
			-- Tier 9 (Pre-boss rest): 2 to 3 Campfire nodes that converge to Boss
			local preBossLanes = { 2, 3, 4 }
			for _, lane in preBossLanes do
				local nodeId = makeNodeId(actNumber, tier, lane)
				local node: DungeonNode = {
					Id = nodeId,
					Act = actNumber,
					Tier = tier,
					Lane = lane,
					Type = "Campfire Rest",
					IncomingNodeIds = {},
					OutgoingNodeIds = {},
				}
				table.insert(tiers[tier], node)
				nodesById[nodeId] = node
			end
		else
			-- Intermediate Tiers (2..8): Choose 2 to 4 lanes
			local possibleLanes = { 1, 2, 3, 4, 5 }
			-- Shuffle lanes
			for i = #possibleLanes, 2, -1 do
				local j = rng:NextInteger(1, i)
				possibleLanes[i], possibleLanes[j] = possibleLanes[j], possibleLanes[i]
			end

			local laneCount = rng:NextInteger(2, 4)
			local chosenLanes = {}
			for k = 1, laneCount do
				table.insert(chosenLanes, possibleLanes[k])
			end
			table.sort(chosenLanes)

			for _, lane in chosenLanes do
				local nodeId = makeNodeId(actNumber, tier, lane)
				local node: DungeonNode = {
					Id = nodeId,
					Act = actNumber,
					Tier = tier,
					Lane = lane,
					Type = pickNodeType(tier, rng),
					IncomingNodeIds = {},
					OutgoingNodeIds = {},
				}
				table.insert(tiers[tier], node)
				nodesById[nodeId] = node
			end
		end
	end

	-- Step 2: Establish Forward & Backward Path Connections
	for tier = 1, TIERS_PER_ACT - 1 do
		local currentTierNodes = tiers[tier]
		local nextTierNodes = tiers[tier + 1]

		-- Ensure every node in current tier has at least one forward connection
		for _, currentNode in currentTierNodes do
			if tier == TIERS_PER_ACT - 1 then
				-- All Tier 9 nodes connect directly to the Tier 10 Boss
				local bossNode = nextTierNodes[1]
				table.insert(currentNode.OutgoingNodeIds, bossNode.Id)
				table.insert(bossNode.IncomingNodeIds, currentNode.Id)
			else
				-- Find adjacent / reachable next-tier nodes (|Lane Difference| <= 1)
				local candidates: { DungeonNode } = {}
				for _, nextNode in nextTierNodes do
					if math.abs(nextNode.Lane - currentNode.Lane) <= 1 then
						table.insert(candidates, nextNode)
					end
				end

				-- If no adjacent node found, connect to the closest available lane
				if #candidates == 0 then
					local closestNode = nextTierNodes[1]
					local closestDist = math.abs(closestNode.Lane - currentNode.Lane)
					for _, nextNode in nextTierNodes do
						local dist = math.abs(nextNode.Lane - currentNode.Lane)
						if dist < closestDist then
							closestDist = dist
							closestNode = nextNode
						end
					end
					table.insert(candidates, closestNode)
				end

				-- Connect to 1 or 2 candidates
				local connectCount = math.min(#candidates, rng:NextInteger(1, 2))
				for i = 1, connectCount do
					local target = candidates[i]
					if not table.find(currentNode.OutgoingNodeIds, target.Id) then
						table.insert(currentNode.OutgoingNodeIds, target.Id)
					end
					if not table.find(target.IncomingNodeIds, currentNode.Id) then
						table.insert(target.IncomingNodeIds, currentNode.Id)
					end
				end
			end
		end

		-- Verify no orphan nodes in next tier (every next tier node must have >= 1 incoming connection)
		for _, nextNode in nextTierNodes do
			if #nextNode.IncomingNodeIds == 0 then
				-- Find closest node in current tier to connect from
				local closestPrev = currentTierNodes[1]
				local closestDist = math.abs(closestPrev.Lane - nextNode.Lane)
				for _, prevNode in currentTierNodes do
					local dist = math.abs(prevNode.Lane - nextNode.Lane)
					if dist < closestDist then
						closestDist = dist
						closestPrev = prevNode
					end
				end

				if not table.find(closestPrev.OutgoingNodeIds, nextNode.Id) then
					table.insert(closestPrev.OutgoingNodeIds, nextNode.Id)
				end
				table.insert(nextNode.IncomingNodeIds, closestPrev.Id)
			end
		end
	end

	local bossId = makeNodeId(actNumber, TIERS_PER_ACT, 3)

	return {
		ActNumber = actNumber,
		Name = ACT_NAMES[actNumber] or ("Act " .. tostring(actNumber)),
		Tiers = tiers,
		NodesById = nodesById,
		BossNodeId = bossId,
	}
end

--------------------------------------------------------------------------------
-- Run Generator
--------------------------------------------------------------------------------

function DungeonMap.generateRun(seed: number?): DungeonRun
	local runSeed = seed or math.floor(os.time() + math.random(1, 1000000))
	local rng = Random.new(runSeed)

	local acts: { Act } = {}
	for actNum = 1, TOTAL_ACTS do
		table.insert(acts, DungeonMap.generateAct(actNum, rng))
	end

	return {
		Seed = runSeed,
		Acts = acts,
		CurrentActIndex = 1,
		CurrentTier = 0,
		CurrentNodeId = nil,
		ClearedNodeIds = {},
		IsCompleted = false,
	}
end

--------------------------------------------------------------------------------
-- Path Navigation API
--------------------------------------------------------------------------------

-- Fetches all available nodes the player can travel to next
function DungeonMap.getAvailableNextNodes(run: DungeonRun): { DungeonNode }
	if run.IsCompleted then
		return {}
	end

	local currentAct = run.Acts[run.CurrentActIndex]
	if not currentAct then
		return {}
	end

	-- Case 1: Start of an Act (no room visited yet in this act)
	if run.CurrentNodeId == nil or run.CurrentTier == 0 then
		local startTierNodes = currentAct.Tiers[1]
		if not startTierNodes then
			return {}
		end
		-- Return all Tier 1 starter options
		local available: { DungeonNode } = {}
		for _, node in startTierNodes do
			table.insert(available, node)
		end
		return available
	end

	-- Case 2: Currently on a node within the Act
	local currentNode = currentAct.NodesById[run.CurrentNodeId]
	if not currentNode then
		return {}
	end

	-- Verify current node has actually been cleared before generating next reachable nodes
	local isCurrentCleared = false
	for _, id in run.ClearedNodeIds do
		if id == run.CurrentNodeId then
			isCurrentCleared = true
			break
		end
	end
	if not isCurrentCleared then
		return {}
	end

	-- If current node is Tier 10 (Boss cleared)
	if currentNode.Tier == TIERS_PER_ACT then
		if run.CurrentActIndex < TOTAL_ACTS then
			-- Available to enter Tier 1 of the NEXT Act
			local nextAct = run.Acts[run.CurrentActIndex + 1]
			if nextAct and nextAct.Tiers[1] then
				local nextActStarts: { DungeonNode } = {}
				for _, node in nextAct.Tiers[1] do
					table.insert(nextActStarts, node)
				end
				return nextActStarts
			end
		end
		-- Run completed
		return {}
	end

	-- Standard progression: Return nodes connected via OutgoingNodeIds
	local reachable: { DungeonNode } = {}
	for _, nextId in currentNode.OutgoingNodeIds do
		local nextNode = currentAct.NodesById[nextId]
		if nextNode then
			table.insert(reachable, nextNode)
		end
	end

	return reachable
end

-- Validates if a target node is reachable from the current dungeon state without mutating state
function DungeonMap.validateNextNode(run: DungeonRun, targetNodeId: string): (boolean, string?, DungeonNode?)
	if run.IsCompleted then
		return false, "Dungeon run is already completed.", nil
	end

	local available = DungeonMap.getAvailableNextNodes(run)
	local targetNode: DungeonNode? = nil

	for _, node in available do
		if node.Id == targetNodeId then
			targetNode = node
			break
		end
	end

	if not targetNode then
		return false, string.format("Node '%s' is not an available path from the current room.", targetNodeId), nil
	end

	return true, nil, targetNode
end

-- Commits travel to an already-validated node
function DungeonMap.commitNextNode(run: DungeonRun, targetNode: DungeonNode)
	run.CurrentActIndex = targetNode.Act
	run.CurrentTier = targetNode.Tier
	run.CurrentNodeId = targetNode.Id
end

-- Selects a node to travel to after clearing a room (atomic validate + commit)
function DungeonMap.selectNextNode(run: DungeonRun, targetNodeId: string): (boolean, string?)
	local valid, err, targetNode = DungeonMap.validateNextNode(run, targetNodeId)
	if not valid or not targetNode then
		return false, err
	end
	DungeonMap.commitNextNode(run, targetNode)
	return true, nil
end

-- Authoritatively marks a node as cleared upon victory or completion of room action
function DungeonMap.markNodeCleared(run: DungeonRun, nodeId: string)
	local alreadyCleared = false
	for _, id in run.ClearedNodeIds do
		if id == nodeId then
			alreadyCleared = true
			break
		end
	end
	if not alreadyCleared then
		table.insert(run.ClearedNodeIds, nodeId)
	end

	local node = DungeonMap.getNode(run, nodeId)
	if node and node.Type == "Act Boss" and node.Act == TOTAL_ACTS then
		run.IsCompleted = true
	end
end

-- Look up a node by its ID across the entire run
function DungeonMap.getNode(run: DungeonRun, nodeId: string): DungeonNode?
	for _, act in run.Acts do
		local node = act.NodesById[nodeId]
		if node then
			return node
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- ASCII Visualizer (For Console Logs & Debugging)
--------------------------------------------------------------------------------

function DungeonMap.printAsciiMap(act: Act, currentNodeId: string?)
	print("============================================================")
	print(string.format("               MAP: %s              ", act.Name))
	print("============================================================")
	print(" TIER | L1   L2   L3   L4   L5")
	print("------+------------------------")

	for tier = TIERS_PER_ACT, 1, -1 do
		local line = string.format("  %02d  |", tier)
		local laneMap: { [number]: DungeonNode } = {}

		for _, node in act.Tiers[tier] do
			laneMap[node.Lane] = node
		end

		for lane = 1, LANES_COUNT do
			local node = laneMap[lane]
			if node then
				local meta = DungeonMap.getNodeMetadata(node.Type)
				local marker = meta.Icon
				if currentNodeId == node.Id then
					marker = "▶" .. marker
				end
				line ..= string.format(" %-4s", marker)
			else
				line ..= "  .  "
			end
		end

		print(line)
	end
	print("============================================================")
end

return DungeonMap
