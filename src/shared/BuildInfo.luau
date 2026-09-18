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
	BUILD_ID = "reaction_v2_20260918",
	BUILD_NAME = "Reaction V2 3D Attack & Timing Hardening",
}

return BuildInfo
