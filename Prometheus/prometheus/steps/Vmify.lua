-- This Script is Part of the Prometheus Obfuscator by levno-710
--
-- Vmify.lua
--
-- Compile source AST into encrypted numeric instructions and a generated VM.

local Step = require("prometheus.step");
local Compiler = require("prometheus.compiler.bytecode");

local Vmify = Step:extend();
Vmify.Description = "Compile source into encrypted numeric bytecode with randomized opcodes and a generated interpreter.";
Vmify.Name = "Vmify";

Vmify.SettingsDescriptor = {
    YieldEvery = {
        type = "number",
        default = 12000,
        min = 0,
        description = "Cooperative Roblox scheduler budget. 0 disables runtime yielding."
    },
    NoiseRate = {
        type = "number",
        default = 16,
        min = 0,
        description = "Insert one safe noise instruction every N instructions on average. 0 disables executable noise."
    },
    FrameConstantCache = {
        type = "boolean",
        default = true,
        description = "Cache decrypted constants only for the active VM frame, then wipe on return."
    },
}

function Vmify:init(_) end

function Vmify:apply(ast, pipeline)
    -- Create Compiler
	local compiler = Compiler:new(pipeline and pipeline.LuaVersion, {
        YieldEvery = self.YieldEvery,
        NoiseRate = self.NoiseRate,
        FrameConstantCache = self.FrameConstantCache,
    });

    -- Compile the Script into a bytecode vm
    return compiler:compile(ast);
end

return Vmify;
