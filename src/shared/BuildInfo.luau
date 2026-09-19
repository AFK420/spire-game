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
	BUILD_ID = "first_aid_transactions_20260919",
	BUILD_NAME = "First Aid Transaction Semantics & Effect Fail-Closed",
}

return BuildInfo
