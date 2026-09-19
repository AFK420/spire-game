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
	BUILD_ID = "campfire_merchant_lifecycle_20260919",
	BUILD_NAME = "Campfire & Merchant Room Lifecycle Hardening",
}

return BuildInfo
