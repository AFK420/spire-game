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
	BUILD_ID = "hardened_campfire_merchant_20260919",
	BUILD_NAME = "Hardened Campfire Choices & Merchant Purchase Transactions",
}

return BuildInfo
