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
        default = 0,
        min = 0,
        description = "Optional cooperative scheduler budget. Disabled by default because yielding is illegal in some executor entry threads."
    },
    NoiseRate = {
        type = "number",
        default = 96,
        min = 0,
        description = "Insert one safe noise instruction every N instructions on average. 0 disables executable noise."
    },
    FrameConstantCache = {
        type = "boolean",
        default = true,
        description = "Cache decrypted constants only for the active VM frame, then wipe on return."
    },
    IntegrityStep = {
        type = "number",
        default = 257,
        min = 0,
        description = "Sampled bytecode integrity verification step. 1 is full but expensive; 0 disables."
    },
    TraceGuardEvery = {
        type = "number",
        default = 0,
        min = 0,
        description = "Lightweight executor-safe runtime sanity guard interval. 0 disables."
    },
    InstructionCache = {
        type = "boolean",
        default = true,
        description = "Cache decoded numeric instructions per prototype to avoid re-decoding hot loops. Keeps source constants encrypted."
    },
    VerifyOnce = {
        type = "boolean",
        default = true,
        description = "Verify each prototype integrity once, then remember it. Safer than disabling integrity and much faster for repeated calls."
    },
    YieldInterval = {
        type = "number",
        default = 0.035,
        min = 0,
        description = "Minimum seconds between cooperative yields. Prevents excessive task.wait calls while still avoiding client freeze."
    },
    HandlerWrapperNoise = {
        type = "boolean",
        default = false,
        description = "Adds extra per-handler opaque wrapper branches. Stronger but slower; off in Medium Balanced."
    },
}

function Vmify:init(_) end

function Vmify:apply(ast, pipeline)
    -- Create Compiler
	local compiler = Compiler:new(pipeline and pipeline.LuaVersion, {
        YieldEvery = self.YieldEvery,
        NoiseRate = self.NoiseRate,
        FrameConstantCache = self.FrameConstantCache,
        IntegrityStep = self.IntegrityStep,
        TraceGuardEvery = self.TraceGuardEvery,
        InstructionCache = self.InstructionCache,
        VerifyOnce = self.VerifyOnce,
        YieldInterval = self.YieldInterval,
        HandlerWrapperNoise = self.HandlerWrapperNoise,
    });

    -- Compile the Script into a bytecode vm
    return compiler:compile(ast);
end

return Vmify;
