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

Vmify.SettingsDescriptor = {}

function Vmify:init(_) end

function Vmify:apply(ast, pipeline)
    -- Create Compiler
	local compiler = Compiler:new(pipeline and pipeline.LuaVersion);

    -- Compile the Script into a bytecode vm
    return compiler:compile(ast);
end

return Vmify;
