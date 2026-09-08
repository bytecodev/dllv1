-- This Script is Part of the Prometheus Obfuscator by levno-710
--
-- EncryptStrings.lua
--
-- This Script provides a Simple Obfuscation Step that encrypts strings

local Step = require("prometheus.step")
local Ast = require("prometheus.ast")
local Parser = require("prometheus.parser")
local Enums = require("prometheus.enums")
local visitast = require("prometheus.visitast");
local util = require("prometheus.util")
local AstKind = Ast.AstKind;

local EncryptStrings = Step:extend()
EncryptStrings.Description = "This Step will encrypt strings within your Program."
EncryptStrings.Name = "Encrypt Strings"

EncryptStrings.SettingsDescriptor = {}

function EncryptStrings:init(_) end


function EncryptStrings:CreateEncryptionService()
	local usedSeeds = {};

	local secret_key_6 = math.random(0, 7) -- reduced from 6-bit to 3-bit range: keeps
		-- param_mul_45 (below) small enough that state_45 * param_mul_45 stays well
		-- under 2^53 (the largest exact integer representable in a double). Lua 5.3's
		-- integer subtype masked this overflow during testing on stock Lua, but Luau
		-- (like Lua 5.1) has no integer subtype and silently loses precision above
		-- 2^53, corrupting the whole decryption stream. state_45 alone can be up to
		-- 2^45-1; capping this factor at <= 29 keeps the product under ~2^50, a safe
		-- 3-bit margin under 2^53 in every Lua dialect.
	local secret_key_7 = math.random(0, 127) -- 7-bit  arbitrary integer (0..127)
	local secret_key_44 = math.random(0, 17592186044415) -- 44-bit arbitrary integer (0..17592186044415)
	local secret_key_8 = math.random(0, 255); -- 8-bit  arbitrary integer (0..255)

	local floor = math.floor

	local function primitive_root_257(idx)
		local g, m, d = 1, 128, 2 * idx + 1
		repeat
			g, m, d = g * g * (d >= m and 3 or 1) % 257, m / 2, d % m
		until m < 1
		return g
	end

	local param_mul_8 = primitive_root_257(secret_key_7)
	local param_mul_45 = secret_key_6 * 4 + 1
	local param_add_45 = secret_key_44 * 2 + 1

	local state_45 = 0
	local state_8 = 2

	local prev_values = {}
	local function set_seed(seed_53)
		state_45 = seed_53 % 35184372088832
		state_8 = seed_53 % 255 + 2
		prev_values = {}
	end

	local function gen_seed()
		local seed;
		repeat
			seed = math.random(0, 35184372088832);
		until not usedSeeds[seed];
		usedSeeds[seed] = true;
		return seed;
	end

	local function get_random_32()
		state_45 = (state_45 * param_mul_45 + param_add_45) % 35184372088832
		repeat
			state_8 = state_8 * param_mul_8 % 257
		until state_8 ~= 1
		local r = state_8 % 32
		local n = floor(state_45 / 2 ^ (13 - (state_8 - r) / 32)) % 2 ^ 32 / 2 ^ r
		return floor(n % 1 * 2 ^ 32) + floor(n)
	end

	local function get_next_pseudo_random_byte()
		if #prev_values == 0 then
			local rnd = get_random_32() -- value 0..4294967295
			local low_16 = rnd % 65536
			local high_16 = (rnd - low_16) / 65536
			local b1 = low_16 % 256
			local b2 = (low_16 - b1) / 256
			local b3 = high_16 % 256
			local b4 = (high_16 - b3) / 256
			prev_values = { b1, b2, b3, b4 }
		end
		--print(unpack(prev_values))
		return table.remove(prev_values)
	end

	local function encrypt(str)
		local seed = gen_seed();
		set_seed(seed)
		local len = string.len(str)
		local out = {}
		local prevVal = secret_key_8;
		for i = 1, len do
			local byte = string.byte(str, i);
			out[i] = string.char((byte - (get_next_pseudo_random_byte() + prevVal)) % 256);
			prevVal = byte;
		end
		return table.concat(out), seed;
	end

	-- Emit constants as arithmetic expressions instead of plain numeric literals.
	-- This does not pretend to be cryptographic security; it removes the stable
	-- regex shape used by simple UndoEncryptStrings-style static decoders.
	local function numExpr(n)
		if n == 0 then
			local k = math.random(32, 8191);
			return "(" .. tostring(k) .. "-" .. tostring(k) .. ")";
		end

		local style = math.random(1, 5);
		if style == 1 then
			local k = math.random(32, 65535);
			return "(" .. tostring(n - k) .. "+" .. tostring(k) .. ")";
		elseif style == 2 then
			local k = math.random(32, 65535);
			return "(" .. tostring(n + k) .. "-" .. tostring(k) .. ")";
		elseif style == 3 and (n > 128 or n < -128) then
			local m = math.random(3, 97);
			local q = math.floor(n / m);
			local r = n - q * m;
			return "((" .. tostring(q) .. "*" .. tostring(m) .. ")+" .. tostring(r) .. ")";
		elseif style == 4 then
			local a = math.random(11, 255);
			local b = math.random(257, 8191);
			return "((" .. tostring(n + a + b) .. "-" .. tostring(a) .. ")-" .. tostring(b) .. ")";
		else
			local a = math.random(11, 255);
			local b = math.random(257, 8191);
			return "((" .. tostring(n + a + b) .. ")-(" .. tostring(a) .. "+" .. tostring(b) .. "))";
		end
	end

    local function genCode()
        local code = [[
do
	]] .. table.concat(util.shuffle{
		"local floor = math.floor",
		"local random = math.random",
		"local remove = table.remove",
		"local char = string.char",
		"local byte = string.byte",
		"local state_45 = 0",
		"local state_8 = 2",
		"local charmap = {}",
		"local nums = {}"
	}, "\n") .. [[
	for i = 1, 256 do
		nums[i] = i;
	end

	repeat
		local idx = random(1, #nums);
		local n = remove(nums, idx);
		charmap[n] = char(n - 1);
	until #nums == 0;

	local prev_values = {}
	local function get_next_pseudo_random_byte()
		if #prev_values == 0 then
			state_45 = (state_45 * ]] .. numExpr(param_mul_45) .. [[ + ]] .. numExpr(param_add_45) .. [[) % ]] .. numExpr(35184372088832) .. [[
			repeat
				state_8 = state_8 * ]] .. numExpr(param_mul_8) .. [[ % ]] .. numExpr(257) .. [[
			until state_8 ~= 1
			local r = state_8 % 32
			local shift = 13 - (state_8 - r) / 32
			local n = floor(state_45 / 2 ^ shift) % ]] .. numExpr(4294967296) .. [[ / 2 ^ r
			local rnd = floor(n % 1 * 4294967296) + floor(n)
			local low_16 = rnd % 65536
			local high_16 = (rnd - low_16) / 65536
			prev_values = { low_16 % 256, (low_16 - low_16 % 256) / 256, high_16 % 256, (high_16 - high_16 % 256) / 256 }
		end


		local prevValuesLen = #prev_values;
		local removed = prev_values[prevValuesLen];
		prev_values[prevValuesLen] = nil;
		return removed;
	end

	local realStrings = {};
	local reveal = function(t, k)
		return t[k];
	end
	local function makeIndex(inner)
		return function(_, k)
			return reveal(inner, k);
		end
	end
	local proxyLayer = setmetatable({}, {
		__index = makeIndex(realStrings);
		__newindex = function() return nil; end;
		__metatable = false;
	});
	STRINGS = setmetatable({}, {
		__index = makeIndex(proxyLayer);
		__newindex = function() return nil; end;
		__metatable = false;
	});
	local cacheSalt = ((#charmap * ]] .. numExpr(math.random(3, 23)) .. [[) + ]] .. numExpr(math.random(17, 4095)) .. [[) % ]] .. numExpr(65536) .. [[;
  	function DECRYPT(str, seed)
		local realStringsLocal = realStrings;
		local cacheKey = seed + cacheSalt;
		if(realStringsLocal[cacheKey]) then return cacheKey; else
			prev_values = {};
			local chars = charmap;
			state_45 = seed % ]] .. numExpr(35184372088832) .. [[
			state_8 = seed % ]] .. numExpr(255) .. [[ + ]] .. numExpr(2) .. [[
			local len = #str;
			realStringsLocal[cacheKey] = "";
			local prevVal = (]] .. numExpr(secret_key_8) .. [[ + cacheSalt - cacheSalt);
			local s = "";
			for i=1, len, 1 do
				prevVal = (byte(str, i) + get_next_pseudo_random_byte() + prevVal) % ]] .. numExpr(256) .. [[
				s = s .. chars[prevVal + ]] .. numExpr(1) .. [[];
			end
			realStringsLocal[cacheKey] = s;
		end
		return cacheKey;
	end
end]]

		return code;
    end

    return {
        encrypt = encrypt,
        param_mul_45 = param_mul_45,
        param_mul_8 = param_mul_8,
        param_add_45 = param_add_45,
		secret_key_8 = secret_key_8,
        genCode = genCode,
    }
end

function EncryptStrings:apply(ast, _)
    local Encryptor = self:CreateEncryptionService();

	local code = Encryptor.genCode();
	local newAst = Parser:new({ LuaVersion = Enums.LuaVersion.Lua51 }):parse(code);
	local doStat = newAst.body.statements[1];

	local scope = ast.body.scope;
	local decryptVar = scope:addVariable();
	local stringsVar = scope:addVariable();

	doStat.body.scope:setParent(ast.body.scope);

	visitast(newAst, nil, function(node, data)
		if(node.kind == AstKind.FunctionDeclaration) then
			if(node.scope:getVariableName(node.id) == "DECRYPT") then
				data.scope:removeReferenceToHigherScope(node.scope, node.id);
				data.scope:addReferenceToHigherScope(scope, decryptVar);
				node.scope = scope;
				node.id = decryptVar;
			end
		end
		if(node.kind == AstKind.AssignmentVariable or node.kind == AstKind.VariableExpression) then
			if(node.scope:getVariableName(node.id) == "STRINGS") then
				data.scope:removeReferenceToHigherScope(node.scope, node.id);
				data.scope:addReferenceToHigherScope(scope, stringsVar);
				node.scope = scope;
				node.id = stringsVar;
			end
		end
	end)

	visitast(ast, nil, function(node, data)
		if(node.kind == AstKind.StringExpression) then
			data.scope:addReferenceToHigherScope(scope, stringsVar);
			data.scope:addReferenceToHigherScope(scope, decryptVar);
			local encrypted, seed = Encryptor.encrypt(node.value);
			return Ast.IndexExpression(Ast.VariableExpression(scope, stringsVar), Ast.FunctionCallExpression(Ast.VariableExpression(scope, decryptVar), {
				Ast.StringExpression(encrypted), Ast.NumberExpression(seed),
			}));
		end
	end)


	-- Insert to Main Ast
	table.insert(ast.body.statements, 1, doStat);
	table.insert(ast.body.statements, 1, Ast.LocalVariableDeclaration(scope, util.shuffle{ decryptVar, stringsVar }, {}));
	return ast
end

return EncryptStrings
