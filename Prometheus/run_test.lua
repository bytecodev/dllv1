-- Test harness: obfuscate sample.lua with the "Vmify" preset (isolated) and with
-- a fuller preset, then execute the output and print results so we can diff
-- against the expected output of running sample.lua directly.

local Prometheus = require("prometheus")
local Pipeline = Prometheus.Pipeline

local presetName = arg[1] or "Medium"
local samplePath = arg[2] or "sample.lua"

local f = io.open(samplePath, "r")
local code = f:read("*a")
f:close()

local presets = require("presets")
local preset = presets[presetName]
assert(preset, "Unknown preset " .. tostring(presetName))

local pipeline = Pipeline:fromConfig(preset)
local ok, result = pcall(function()
    return pipeline:apply(code, samplePath)
end)

if not ok then
    print("OBFUSCATION FAILED: " .. tostring(result))
    os.exit(1)
end

local outPath = "out_" .. presetName .. ".lua"
local out = io.open(outPath, "w")
out:write(result)
out:close()

print("Wrote " .. outPath)
