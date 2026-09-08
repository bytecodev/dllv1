-- This Script is Part of the ByteCode Obfuscator hardening layer
--
-- AntiDump.lua
--
-- Injects a cheap runtime trace-poison prologue before Vmify. The goal is not to
-- break normal Roblox execution, but to waste/distract dynamic dumpers that follow
-- task.spawn/coroutine execution and reconstruct runtime calls/constants.

local Step = require("prometheus.step");
local Parser = require("prometheus.parser");
local enums = require("prometheus.enums");

local LuaVersion = enums.LuaVersion;

local AntiDump = Step:extend();
AntiDump.Description = "Adds Roblox/Luau safe anti-dump trace poison before VM execution";
AntiDump.Name = "Anti Dump";

AntiDump.SettingsDescriptor = {
    Enabled = {
        name = "Enabled",
        description = "Whether to inject the anti-dynamic-dump prologue",
        type = "boolean",
        default = true,
    },
    EnvNoise = {
        name = "EnvNoise",
        description = "Number of harmless random fenv/getgenv decoy keys to create",
        type = "number",
        default = 32,
        min = 0,
        max = 128,
    },
    SpawnPoison = {
        name = "SpawnPoison",
        description = "Spawn low-cost background decoy jobs that confuse dynamic dumpers",
        type = "boolean",
        default = true,
    },
}

function AntiDump:init(_) end

local function randomAscii(len)
    local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    local out = {};
    for i = 1, len do
        local p = math.random(1, #chars);
        out[i] = chars:sub(p, p);
    end
    return table.concat(out);
end

local function luaQuote(str)
    return string.format("%q", str);
end

function AntiDump:apply(ast)
    if not self.Enabled then
        return;
    end

    local envNoise = math.max(0, math.min(tonumber(self.EnvNoise) or 0, 128));
    local seedA = randomAscii(math.random(8, 14));
    local seedB = randomAscii(math.random(8, 14));
    local noiseKeys = {};
    for i = 1, envNoise do
        noiseKeys[i] = luaQuote(randomAscii(math.random(9, 18)));
    end

    -- The first spawned job intentionally looks like a real long-running worker.
    -- Normal Roblox clients simply park it on a very long task.wait. A lot of
    -- dynamic dumpers, however, try to walk spawned closures and will spend their
    -- budget on this decoy before reaching the real VM bootstrap.
    local spawnPoison = self.SpawnPoison and [[
        if type(_bd_spawn) == "function" and type(_bd_wait) == "function" then
            _bd_spawn(function()
                local _bd_acc = 0;
                local _bd_anchor = _bd_clock and _bd_clock() or 0;
                while true do
                    _bd_acc = (_bd_acc + 1) % 104729;
                    if _bd_acc == -1 and _bd_anchor == -2 then
                        error(tostring(_bd_salt[1]));
                    end
                    _bd_wait(100000000 + (_bd_acc % 97));
                end
            end);
            _bd_spawn(function()
                local _bd_bucket = {};
                local _bd_i = 1;
                while _bd_i <= 96 do
                    _bd_bucket[_bd_i] = (_bd_i * 3) - _bd_i;
                    _bd_i = _bd_i + 1;
                    if (_bd_i % 16) == 0 then
                        _bd_wait(0.05);
                    end
                end
            end);
        end
    ]] or "";

    local code = [[
    do
        local _bd_env = nil;
        pcall(function()
            _bd_env = (getfenv and getfenv()) or (getgenv and getgenv()) or _ENV or _G;
        end);
        if type(_bd_env) ~= "table" then
            _bd_env = {};
        end

        local _bd_task = task;
        local _bd_wait = (_bd_task and _bd_task.wait) or wait;
        local _bd_spawn = (_bd_task and _bd_task.spawn) or spawn;
        local _bd_clock = (os and os.clock) or tick;
        local _bd_salt = { ]] .. luaQuote(seedA) .. [[, ]] .. luaQuote(seedB) .. [[, tostring({}), tostring(function() end) };
        local _bd_keys = { ]] .. table.concat(noiseKeys, ", ") .. [[ };

        for _bd_i = 1, #_bd_keys do
            local _bd_k = "_" .. tostring(_bd_i) .. _bd_keys[_bd_i] .. tostring(_bd_salt[((_bd_i - 1) % #_bd_salt) + 1]);
            _bd_env[_bd_k] = _bd_env[_bd_k] or ((_bd_i * 17) % 257);
        end

    ]] .. spawnPoison .. [[
    end
    ]];

    local parser = Parser:new({
        LuaVersion = LuaVersion.Lua51;
    });

    local newAst = parser:parse(code);
    local stat = newAst.body.statements[1];
    stat.body.scope:setParent(ast.body.scope);
    table.insert(ast.body.statements, 1, stat);
end

return AntiDump;
