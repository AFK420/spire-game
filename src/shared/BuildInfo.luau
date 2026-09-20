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
	BUILD_ID = "phase5_flexible_builds_20260920",
	BUILD_NAME = "Phase 5 Flexible Builds",
}

return BuildInfo
