local function multi(...)
    local n = select("#", ...)
    return n, ...
end

local function adder(base)
    return function(...)
        local total = base
        for _, v in ipairs({...}) do
            total = total + v
        end
        return total
    end
end

local add5 = adder(5)
print(add5(1, 2, 3))

local mt = {}
mt.__index = function(t, k) return "default_" .. tostring(k) end
local obj = setmetatable({}, mt)
print(obj.foo)

local n, a, b, c = multi(10, 20, 30)
print(n, a, b, c)

local function factorial(x)
    if x <= 1 then return 1 end
    return x * factorial(x - 1)
end
print(factorial(6))

local nested = {a = {b = {c = 42}}}
print(nested.a.b.c)

local ok, err = pcall(function() error("boom") end)
print(ok, err ~= nil)
