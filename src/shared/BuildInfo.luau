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
	BUILD_ID = "18918ad5-mapflow-handshake-v2",
	BUILD_NAME = "MapFlow Handshake & StateSync Recovery",
}

return BuildInfo
