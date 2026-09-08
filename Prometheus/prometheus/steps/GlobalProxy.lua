-- This Script is Part of the ByteCode Obfuscator hardening layer
--
-- GlobalProxy.lua
--
-- Adds a Luau/Lua51-safe global environment proxy near the very end of the
-- pipeline. Unlike the internal string-cache proxy, this one is intentionally
-- emitted after VM/string passes so the final output has a real setmetatable
-- prologue and subsequent global reads can be routed through it via setfenv.

local Step = require("prometheus.step");
local Parser = require("prometheus.parser");
local enums = require("prometheus.enums");

local LuaVersion = enums.LuaVersion;

local GlobalProxy = Step:extend();
GlobalProxy.Description = "Adds a setmetatable-backed global/env proxy prologue";
GlobalProxy.Name = "Global Proxy";

GlobalProxy.SettingsDescriptor = {
    Enabled = {
        name = "Enabled",
        description = "Whether to inject the global proxy prologue",
        type = "boolean",
        default = true,
    },
    SetCurrentEnv = {
        name = "SetCurrentEnv",
        description = "Use setfenv(1, proxy) when available so later globals go through the proxy",
        type = "boolean",
        default = true,
    },
    DecoyCount = {
        name = "DecoyCount",
        description = "Number of harmless encrypted proxy-decoy environment keys",
        type = "number",
        default = 10,
        min = 0,
        max = 64,
    },
}

function GlobalProxy:init(_) end

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

local function bxor(a, b)
    local out, bit = 0, 1;
    while a > 0 or b > 0 do
        local aa = a % 2;
        local bb = b % 2;
        if aa ~= bb then
            out = out + bit;
        end
        a = (a - aa) / 2;
        b = (b - bb) / 2;
        bit = bit * 2;
    end
    return out;
end

local function xorEncode(str, key)
    local out = {};
    local prev = key;
    for i = 1, #str do
        local b = string.byte(str, i);
        local k = (prev + i * 17) % 256;
        out[i] = string.char(bxor(b, k));
        prev = (b + prev + i) % 256;
    end
    return table.concat(out);
end

local function numExpr(n)
    if n == 0 then
        local k = math.random(64, 8191);
        return "(" .. tostring(k) .. "-" .. tostring(k) .. ")";
    end
    local style = math.random(1, 4);
    if style == 1 then
        local k = math.random(32, 4096);
        return "(" .. tostring(n + k) .. "-" .. tostring(k) .. ")";
    elseif style == 2 then
        local k = math.random(32, 4096);
        return "(" .. tostring(n - k) .. "+" .. tostring(k) .. ")";
    elseif style == 3 then
        local m = math.random(3, 31);
        local q = math.floor(n / m);
        local r = n - q * m;
        return "((" .. tostring(q) .. "*" .. tostring(m) .. ")+" .. tostring(r) .. ")";
    else
        local a = math.random(11, 99);
        local b = math.random(101, 999);
        return "((" .. tostring(n + a + b) .. "-" .. tostring(a) .. ")-" .. tostring(b) .. ")";
    end
end

function GlobalProxy:apply(ast)
    if not self.Enabled then
        return ast;
    end

    local key = math.random(21, 239);
    local decoys = {};
    local count = math.max(0, math.min(tonumber(self.DecoyCount) or 0, 64));
    for i = 1, count do
        local text = "__" .. randomAscii(math.random(10, 18));
        decoys[i] = luaQuote(xorEncode(text, key));
    end

    local setEnvCode = self.SetCurrentEnv and [[
        if _bc_type(_bc_setfenv) == "function" then
            _bc_pcall(_bc_setfenv, 1, _bc_proxy);
        end
    ]] or "";

    local code = [[
do
    local _bc_rawget = rawget;
    local _bc_rawset = rawset;
    local _bc_getfenv = getfenv;
    local _bc_getgenv = getgenv;
    local _bc_setfenv = setfenv;
    local _bc_pcall = pcall;
    local _bc_type = type;
    local _bc_tostring = tostring;
    local _bc_G = _G;
    local _bc_ENV = _ENV;
    local _bc_env = nil;

    _bc_pcall(function()
        if _bc_type(_bc_getfenv) == "function" then
            _bc_env = _bc_getfenv();
        end
    end);

    if _bc_type(_bc_env) ~= "table" then
        _bc_pcall(function()
            if _bc_type(_bc_getgenv) == "function" then
                _bc_env = _bc_getgenv();
            end
        end);
    end

    if _bc_type(_bc_env) ~= "table" then
        if _bc_type(_bc_G) == "table" then
            _bc_env = _bc_G;
        elseif _bc_type(_bc_ENV) == "table" then
            _bc_env = _bc_ENV;
        else
            _bc_env = {};
        end
    end

    local _bc_proxy = setmetatable({}, {
        __index = function(_, _bc_key)
            local _bc_value;
            if _bc_type(_bc_G) == "table" then
                _bc_value = _bc_rawget(_bc_G, _bc_key);
                if _bc_value ~= nil then
                    return _bc_value;
                end
            end
            if _bc_type(_bc_env) == "table" then
                _bc_value = _bc_rawget(_bc_env, _bc_key);
                if _bc_value ~= nil then
                    return _bc_value;
                end
            end
            if _bc_type(_bc_ENV) == "table" then
                _bc_value = _bc_rawget(_bc_ENV, _bc_key);
                if _bc_value ~= nil then
                    return _bc_value;
                end
            end
            return nil;
        end,
        __newindex = function(_, _bc_key, _bc_value)
            if _bc_type(_bc_env) == "table" then
                _bc_rawset(_bc_env, _bc_key, _bc_value);
            elseif _bc_type(_bc_G) == "table" then
                _bc_rawset(_bc_G, _bc_key, _bc_value);
            end
        end,
        __metatable = false,
    });

    local _bc_string = _bc_proxy.string;
    local _bc_byte = _bc_string and _bc_string.byte;
    local _bc_char = _bc_string and _bc_string.char;
    local _bc_gmatch = _bc_string and _bc_string.gmatch;
    local _bc_unpack = (_bc_proxy.table and (_bc_proxy.table.unpack or _bc_proxy.unpack)) or _bc_proxy.unpack;

    local function _bc_xor(_bc_a, _bc_b)
        local _bc_c = 0;
        local _bc_d = 1;
        while _bc_a > 0 or _bc_b > 0 do
            local _bc_e = _bc_a % 2;
            local _bc_f = _bc_b % 2;
            if _bc_e ~= _bc_f then
                _bc_c = _bc_c + _bc_d;
            end
            _bc_a = (_bc_a - _bc_e) / 2;
            _bc_b = (_bc_b - _bc_f) / 2;
            _bc_d = _bc_d * 2;
        end
        return _bc_c;
    end

    local function _bc_floor(_bc_n)
        local _bc_i = _bc_n - _bc_n % 1;
        if _bc_n < 0 and _bc_n % 1 ~= 0 then
            _bc_i = _bc_i - 1;
        end
        return _bc_i;
    end

    local function _bc_dec(_bc_data, _bc_key)
        if not _bc_data or not _bc_key or not _bc_byte or not _bc_char or not _bc_gmatch then
            return _bc_data;
        end
        local _bc_out = "";
        local _bc_prev = _bc_key;
        local _bc_i = 1;
        for _bc_ch in _bc_gmatch(_bc_data, ".") do
            local _bc_v = _bc_byte(_bc_ch);
            local _bc_k = (_bc_prev + _bc_i * 17) % 256;
            local _bc_plain = _bc_xor(_bc_v, _bc_k);
            _bc_out = _bc_out .. _bc_char(_bc_floor(_bc_plain));
            _bc_prev = (_bc_plain + _bc_prev + _bc_i) % 256;
            _bc_i = _bc_i + 1;
        end
        return _bc_out;
    end

    local _bc_keys = { ]] .. table.concat(decoys, ", ") .. [[ };
    for _bc_i = 1, #_bc_keys do
        local _bc_k = _bc_dec(_bc_keys[_bc_i], ]] .. numExpr(key) .. [[);
        if _bc_k and _bc_rawget(_bc_env, _bc_k) == nil then
            _bc_rawset(_bc_env, _bc_k, (_bc_i * 13) % 251);
        end
    end

    if _bc_unpack and false then
        _bc_unpack(_bc_keys);
    end
]] .. setEnvCode .. [[
end
]];

    local parser = Parser:new({
        LuaVersion = LuaVersion.Lua51;
    });

    local newAst = parser:parse(code);
    local stat = newAst.body.statements[1];
    stat.body.scope:setParent(ast.body.scope);
    table.insert(ast.body.statements, 1, stat);
    return ast;
end

return GlobalProxy;
