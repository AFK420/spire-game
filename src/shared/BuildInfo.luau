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
	BUILD_ID = "hardened_server_deck_contracts_20260919",
	BUILD_NAME = "Hardened Server Deck Invariants & Contracts",
}

return BuildInfo
