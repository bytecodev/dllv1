local function fib(n)
    if n < 2 then return n end
    return fib(n - 1) + fib(n - 2)
end

local function makeCounter()
    local count = 0
    return function()
        count = count + 1
        return count
    end
end

local counter = makeCounter()
local sum = 0
for i = 1, 10 do
    sum = sum + counter()
end

local t = {1, 2, 3, "four", key = "value"}
local concatResult = ""
for i, v in ipairs(t) do
    concatResult = concatResult .. tostring(v)
end

print(fib(10))
print(sum)
print(concatResult)
print(t.key)
print(#t)
