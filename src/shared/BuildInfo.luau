--!strict

--[=[
	BuildInfo Module
	Provides authoritative build fingerprinting to ensure Roblox Studio and client runtimes
	are synchronized with the repository codebase.
]=]

export type BuildInfoType = {
	BUILD_ID: string,
	BUILD_NAME: string,
}

local BuildInfo = {
	BUILD_ID = "reaction_v2_playability_20260919",
	BUILD_NAME = "Reaction V2 End-to-End Playability & Visual Synchronization",
}

return BuildInfo
