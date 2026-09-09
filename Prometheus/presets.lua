-- This Script is Part of the Prometheus Obfuscator by levno-710
--
-- presets.lua
--
-- This Script provides the predefined obfuscation presets for Prometheus

return {
	-- Minifies your code. Does not obfuscate it. No performance loss.
	["Minify"] = {
		LuaVersion = "Lua51",
		VarNamePrefix = "",
		NameGenerator = "MangledShuffled",
		PrettyPrint = false,
		Seed = 0,
		Steps = {},
	},

	-- Weak obfuscation. Very readable, low performance loss.
	["Weak"] = {
		LuaVersion = "Lua51",
		VarNamePrefix = "",
		NameGenerator = "MangledShuffled",
		PrettyPrint = false,
		Seed = 0,
		Steps = {
			{ Name = "SplitStrings", Settings = {} },
			{ Name = "Vmify", Settings = {} },
			{
				Name = "ConstantArray",
				Settings = {
					Threshold = 1,
					StringsOnly = true
				},
			},
			{ Name = "WrapInFunction", Settings = {} },
		},
	},

	-- This is here for the tests.lua file.
	-- It helps isolate any problems with the Vmify step.
	-- It is not recommended to use this preset for obfuscation.
	-- Use the Weak, Medium, or Strong for obfuscation instead.
	["Vmify"] = {
		LuaVersion = "Lua51",
		VarNamePrefix = "",
		NameGenerator = "MangledShuffled",
		PrettyPrint = false,
		Seed = 0,
		Steps = {
			{ Name = "Vmify", Settings = {} },
		},
	},

	-- Medium: numeric bytecode VM with lazy constants and executor-safe intrinsics.
	["Medium"] = {
		LuaVersion = "LuaU",
		VarNamePrefix = "",
		NameGenerator = "MangledShuffled",
		PrettyPrint = false,
		Seed = 0,
		Steps = {
			{ Name = "Vmify", Settings = { YieldEvery = 0, YieldInterval = 0.035, NoiseRate = 96, FrameConstantCache = true, InstructionCache = true, IntegrityStep = 257, VerifyOnce = true, TraceGuardEvery = 0, HandlerWrapperNoise = false } },
		},
	},
	-- Strong obfuscation, high performance loss.
	["Strong"] = {
		LuaVersion = "Lua51",
		VarNamePrefix = "",
		NameGenerator = "MangledShuffled",
		PrettyPrint = false,
		Seed = 0,
		Steps = {
			{ Name = "Vmify", Settings = {} },
			{ Name = "EncryptStrings", Settings = {} },
			{
				Name = "AntiTamper",
				Settings = {
					UseDebug = true,
				},
			},
			{ Name = "Vmify", Settings = {} },
			{
				Name = "ConstantArray",
				Settings = {
					Threshold = 1,
					StringsOnly = true,
					Shuffle = true,
					Rotate = true,
					LocalWrapperThreshold = 0
				},
			},
			{
				Name = "NumbersToExpressions",
				Settings = {
					NumberRepresentationMutation = true
				},
			},
			{ Name = "SplitStrings", Settings = {} },
			{ Name = "WrapInFunction", Settings = {} },
		},
	},

	-- Extreme obfuscation. Maximum security, heavy performance loss.
	["Extreme"] = {
		LuaVersion = "Lua51",
		VarNamePrefix = "",
		NameGenerator = "Confuse",
		PrettyPrint = false,
		Seed = 0,
		Steps = {
			{ Name = "AddVararg", Settings = {} },
			{ Name = "ProxifyLocals", Settings = { LiteralType = "any" } },
			{ Name = "Vmify", Settings = {} },
			{ Name = "EncryptStrings", Settings = {} },
			{ Name = "SplitStrings", Settings = {} },
			{
				Name = "AntiTamper",
				Settings = {
					UseDebug = true,
				},
			},
			{ Name = "Vmify", Settings = {} },
			{
				Name = "ConstantArray",
				Settings = {
					Threshold = 1,
					StringsOnly = false,
					Shuffle = true,
					Rotate = true,
					LocalWrapperThreshold = 1,
					LocalWrapperCount = 3
				},
			},
			{
				Name = "NumbersToExpressions",
				Settings = {
					NumberRepresentationMutation = true
				},
			},
			{ Name = "ProxifyLocals", Settings = { LiteralType = "dictionary" } },
			{ Name = "WrapInFunction", Settings = {} },
		},
	},

}
