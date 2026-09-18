--!strict

--[=[
	Client Bootstrap Script
	Mapped to: StarterPlayer.StarterPlayerScripts.Client
	Initializes the client environment for Card Rift: Co-op Dungeon.
	UI rendering and state synchronization are managed by UIController.client.luau.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local BuildInfo = require(Shared:WaitForChild("BuildInfo") :: ModuleScript)

print(string.format("[BUILD] Client bootstrap build=%s", BuildInfo.BUILD_ID))
print("[Client] Card Rift: Co-op Dungeon client initialized.")
