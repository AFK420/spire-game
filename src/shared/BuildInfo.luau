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
	BUILD_ID = "deck_builder_collection_ui_20260919",
	BUILD_NAME = "Deck Builder UI & Collection Frontend",
}

return BuildInfo
