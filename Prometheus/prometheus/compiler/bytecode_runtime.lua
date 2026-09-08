-- Build-time serializer and polymorphic interpreter generator.
-- Arithmetic stays below 2^53, so the wire format works on Lua 5.1 and Luau.
local R = {}
local MOD = 2147483647
local function rand() return math.random(10000, 1000000) end
local function shuffle(t)
    for i = #t, 2, -1 do local j = math.random(i); t[i], t[j] = t[j], t[i] end
    return t
end
local function array(t) return "{" .. table.concat(t, ",") .. "}" end

function R.emit(protos, constants, luaVersion, options)
    options = options or {}
    local yieldEvery = tonumber(options.YieldEvery or options.yieldEvery) or 12000
    if yieldEvery < 0 then yieldEvery = 0 end
    local noiseRate = tonumber(options.NoiseRate or options.noiseRate) or 16
    if noiseRate < 0 then noiseRate = 0 end
    local frameConstantCache = options.FrameConstantCache ~= false and options.frameConstantCache ~= false
    local regMul, regAdd = math.random(3, 97), rand()
    local pcMul, pcAdd = math.random(3, 97), rand()
    local stackMul, stackAdd = math.random(3, 97), rand()
    local stateLive, stateDone = rand(), rand()
    while stateDone == stateLive do stateDone = rand() end
    local stateTail; repeat stateTail=rand() until stateTail~=stateLive and stateTail~=stateDone
    local salt, stride = rand(), math.random(101, 8191)
    local function reg(id) return id * regMul + regAdd end
    local function pc(id) return id * pcMul + pcAdd end
    local handlers = {
        CONST = "push(pack(constant(a)))",
        GLOBAL = "push(pack(env[constant(a)]))",
        GREF = "push(pack({env,constant(a)}))",
        GET = "push(pack(cells[a][1]))",
        REF = "push(pack({cells[a],1}))",
        NEW = "cells[a]={peek()[b]}",
        INDEX = "local key=pop()[1]; local obj=pop()[1]; push(pack(obj[key]))",
        INDEXREF = "local key=pop()[1]; local obj=pop()[1]; push(pack({obj,key}))",
        DEREF = "local ref=pop()[1]; push(pack(ref[1][ref[2]]))",
        ASSIGN = [=[local values=pop(); local refs={}
            for i=a,1,-1 do refs[i]=pop()[1] end
            for i=1,a do local ref=refs[i]; ref[1][ref[2]]=values[i]; refs[i]=nil end]=],
        VARARG = "push(varargs)",
        SINGLE = "local v=pop()[1]; push(pack(v))",
        DUP = "push(peek())",
        DROP = "pop()",
        PACK = [=[local parts={}; for i=a,1,-1 do parts[i]=pop() end
            local values={n=0}; for i=1,a do
                local part=parts[i]; local count=1; if i==a then count=part.n end
                for j=1,count do values.n=values.n+1; values[values.n]=part[j] end
                parts[i]=nil
            end; push(values)]=],
        CALL = "local args=pop(); local fn=pop()[1]; push(pack(fn(unpackValues(args,1,args.n))))",
        METHOD = "local obj=pop()[1]; local fn=obj[constant(a)]; push(pack(fn)); push(pack(obj))",
        SELFCALL = "local args=pop(); local obj=pop()[1]; local fn=pop()[1]; push(pack(fn(obj,unpackValues(args,1,args.n))))",
        TAILCALL = "tailArgs=pop(); tailFunction=pop()[1]; status=TAIL",
        TAILSELF = "local args=pop(); local obj=pop()[1]; tailFunction=pop()[1]; tailArgs={n=args.n+1,obj}; for i=1,args.n do tailArgs[i+1]=args[i] end; status=TAIL",
        CLOSURE = [=[local child=prototypes[a]; local captured={}
            for _,slot in ipairs(child[4]) do captured[slot]=cells[slot] end
            push(pack(function(...) return run(a,captured,pack(...)) end))]=],
        TABLE = "push(pack({}))",
        FIELD = "local value=pop()[1]; local key=pop()[1]; peek()[1][key]=value",
        APPEND = "local values=pop(); local obj=peek()[1]; local count=1; if b==1 then count=values.n end; for i=1,count do obj[a+i-1]=values[i] end",
        JUMP = "position=a+drift",
        JTRUE = "if pop()[1] then position=a+drift end",
        JFALSE = "if not pop()[1] then position=a+drift end",
        RETURN = "result=pop(); status=DONE",
        FORPREP = [=[local v=pop(); local x,y,z=tonumber(v[1]),tonumber(v[2]),tonumber(v[3])
            if x==nil or y==nil or z==nil then error('invalid numeric for',0) end
            cells[a]={x}; cells[b]={y}; cells[c]={z}]=],
        FORCHECK = "local x,y,z=cells[a][1],cells[b][1],cells[c][1]; push(pack((z>0 and x<=y) or (z<=0 and x>=y)))",
        FORSTEP = "cells[a][1]=cells[a][1]+cells[b][1]",
        ITERPREP = [=[local v=pop(); local fn,st,control=v[1],v[2],v[3]
            if type(fn)=='table' then
                local mt=getmetatable(fn)
                if type(mt)=='table' and mt.__iter then fn,st,control=mt.__iter(fn)
                elseif not (type(mt)=='table' and mt.__call) then st=fn; fn=next; control=nil end
            end
            cells[a]={fn}; cells[b]={st}; cells[c]={control}]=],
        ITERNEXT = "local values=pack(cells[a][1](cells[b][1],cells[c][1])); cells[c][1]=values[1]; push(values)",
    }
    -- Lua 5.1 commits assignments right-to-left; Luau commits left-to-right.
    if luaVersion == "Lua51" then
        handlers.ASSIGN=handlers.ASSIGN:gsub("for i=1,a do local ref", "for i=a,1,-1 do local ref")
    end
    local bin = {ADD="+",SUB="-",MUL="*",DIV="/",MOD="%",POW="^",CONCAT="..",LT="<",GT=">",LE="<=",GE=">=",EQ="==",NE="~="}
    local binNames={}; for op in pairs(bin) do binNames[#binNames+1]=op end
    table.sort(binNames)
    for _, op in ipairs(binNames) do
        local symbol=bin[op]
        if math.random(2) == 1 then
            handlers[op] = "local right=pop()[1]; local left=pop()[1]; push(pack(left " .. symbol .. " right))"
        else
            handlers[op] = "local operands={}; operands[2]=pop()[1]; operands[1]=pop()[1]; push(pack(operands[1] " .. symbol .. " operands[2]))"
        end
    end
    for op, symbol in pairs({NOT="not ",NEG="-",LEN="#"}) do
        handlers[op] = "local value=pop()[1]; push(pack(" .. symbol .. "value))"
    end
    -- Executable decoys only mutate private noise. Dead handlers have no host effects.
    local noiseCount=math.random(6,12)
    for i=1,noiseCount do
        handlers["NOISE"..i] = "noise=(noise+a*" .. math.random(3,97) .. "+b+c)%65521"
    end
    for i=1,math.random(6,12) do
        handlers["DEAD"..i] = "noise=(noise*" .. math.random(3,97) .. "+a)%65521"
    end
    local names = {}; for name in pairs(handlers) do names[#names+1]=name end
    table.sort(names); shuffle(names)
    local opcodes, layouts, used = {}, {}, {}
    for _, name in ipairs(names) do
        opcodes[name] = {}
        for variant=1,2 do
            local code; repeat code=math.random(100,1000000) until not used[code]
            used[code]=true; opcodes[name][variant]=code
            layouts[code]=shuffle({1,2,3})
        end
    end
    local slotArgs = {
        GET={1},REF={1},NEW={1},FORPREP={1,2,3},FORCHECK={1,2,3},FORSTEP={1,2},
        ITERPREP={1,2,3},ITERNEXT={1,2,3},
    }
    local serialized = {}
    for pid,p in ipairs(protos) do
        -- Relocate branch targets after inserting safe decoy instructions.
        local code, locations = {}, {}
        for i, instruction in ipairs(p.code) do
            locations[i] = #code+1
            if noiseRate > 0 and math.random(noiseRate)==1 then
                code[#code+1] = {"NOISE"..math.random(noiseCount),rand(),rand(),rand()}
            end
            code[#code+1] = instruction
        end
        locations[#p.code+1] = #code+1
        local key = rand(); local stream = {}
        for i, instruction in ipairs(code) do
            local op = instruction[1]
            local words = {opcodes[op][math.random(2)], instruction[2], instruction[3], instruction[4]}
            for _, arg in ipairs(slotArgs[op] or {}) do words[arg+1]=reg(words[arg+1]) end
            if op=="JUMP" or op=="JTRUE" or op=="JFALSE" then words[2]=pc(locations[words[2]]) end
            local layout=layouts[words[1]]
            words={words[1],words[layout[1]+1],words[layout[2]+1],words[layout[3]+1]}
            local state = (key+i*stride+salt)%MOD
            for j=1,4 do
                state=(state*48271+j*97)%MOD
                local cipher=(words[j]+state)%MOD
                stream[#stream+1]=cipher
                state=(state+cipher)%MOD
            end
        end
        local params, captures = {}, {}
        for _, id in ipairs(p.params) do params[#params+1]=reg(id) end
        for _, id in ipairs(p.captures) do captures[#captures+1]=reg(id) end
        serialized[pid]=array({array(stream),key,array(params),array(captures)})
    end
    local encrypted = {}
    for id,entry in ipairs(constants) do
        local value = entry.value
        local tag, plain
        if type(value)=="string" then tag=1; plain=value
        elseif type(value)=="number" then tag=2; plain=string.format("%.17g",value)
        elseif value==true then tag=3; plain=""
        elseif value==false then tag=4; plain=""
        else tag=5; plain="" end
        local key = rand(); local state=(key+id*stride+salt)%MOD
        local bytes={}
        -- Type tags are encrypted along with the constant payload.
        for i=0,#plain do
            local byte = i==0 and tag or string.byte(plain,i)
            state=(state*48271+(i+1)*97)%MOD
            local cipher=(byte+state%256)%256
            bytes[#bytes+1]=cipher; state=(state+cipher)%MOD
        end
        encrypted[id]=array({key,array(bytes)})
    end
    local emittedHandlers={}
    for _,name in ipairs(names) do
        for variant,code in ipairs(opcodes[name]) do
            local body=handlers[name]
            if variant==2 then
                body="local gate=(noise+"..rand()..")%65521; if gate>=0 then "..body.." else noise=gate end"
            elseif math.random(2)==1 then body="do "..body.." end" end
            local args={"a","b","c"}; local layout=layouts[code]
            local params={args[layout[1]],args[layout[2]],args[layout[3]]}
            emittedHandlers[#emittedHandlers+1]="dispatch["..code.."]=function("..table.concat(params,",")..") "..body.." end"
        end
    end
    shuffle(emittedHandlers)
    local runtime = [=[
return (function(env,...)
    local prototypes=PROTOTYPES
    local pool=CONSTANTS
    local unpackValues=unpack or table.unpack
    local function pack(...) return {n=select('#',...),...} end
    local nilSentinel={}
    local activeConstantCache=nil
    local function constant(id)
        local cache=activeConstantCache
        if cache then
            local cached=cache[id]
            if cached~=nil then
                if cached==nilSentinel then return nil end
                return cached
            end
        end
        local entry=pool[id]; local bytes=entry[2]
        local state=(entry[1]+id*STRIDE+SALT)%2147483647
        local chars={}; local tag
        for i=1,#bytes do
            state=(state*48271+i*97)%2147483647
            local value=(bytes[i]-state%256)%256
            state=(state+bytes[i])%2147483647
            if i==1 then tag=value else chars[i-1]=string.char(value) end
        end
        local raw=table.concat(chars)
        for i=1,#chars do chars[i]=nil end
        local value
        if tag==1 then value=raw
        elseif tag==2 then
            if raw=='inf' then value=1/0
            elseif raw=='-inf' then value=-1/0
            elseif raw=='nan' or raw=='-nan' then value=0/0
            else value=tonumber(raw) end
        elseif tag==3 then value=true
        elseif tag==4 then value=false
        else value=nil end
        if cache then cache[id]=value==nil and nilSentinel or value end
        return value
    end
    local taskApi=(env and rawget(env,'task')) or task
    local waitFunc=type(taskApi)=='table' and taskApi.wait or nil
    local coApi=(env and rawget(env,'coroutine')) or coroutine
    local isYieldable=type(coApi)=='table' and coApi.isyieldable or nil
    local yieldDisabled=false
    local function safeYield()
        if not waitFunc or yieldDisabled then return end
        if isYieldable and not isYieldable() then return end
        local ok=pcall(waitFunc)
        if not ok then yieldDisabled=true end
    end
    local run
    run=function(id,captured,args)
        local previousConstantCache=activeConstantCache
        local frameConstantCacheEnabled=FRAMECONSTANTCACHE
        local localConstantCache=frameConstantCacheEnabled and {} or nil
        activeConstantCache=localConstantCache
        local proto=prototypes[id]; local stream=proto[1]
        local cells={}; for slot,cell in pairs(captured) do cells[slot]=cell end
        for i,slot in ipairs(proto[3]) do cells[slot]={args[i]} end
        local varargs={n=math.max(0,args.n-#proto[3])}
        for i=1,varargs.n do varargs[i]=args[i+#proto[3]] end
        args=nil
        local stack={}; local top=STACKADD
        local function push(value) top=top+STACKMUL; stack[top]=value end
        local function pop() local value=stack[top]; stack[top]=nil; top=top-STACKMUL; return value end
        local function peek() return stack[top] end
        local drift=proto[2]%65521
        local position=PCMUL+PCADD+drift
        local status=LIVE; local result; local tailFunction,tailArgs; local noise=proto[2]%65521
        local vmBudget=0
        local dispatch={}
        HANDLERS
        while status==LIVE do
            if YIELDEVERY>0 then
                vmBudget=vmBudget+1
                if vmBudget>=YIELDEVERY then vmBudget=0; safeYield() end
            end
            local index=(position-drift-PCADD)/PCMUL
            local offset=(index-1)*4
            local key=(proto[2]+index*STRIDE+SALT)%2147483647
            local words={}
            for j=1,4 do
                key=(key*48271+j*97)%2147483647
                local cipher=stream[offset+j]
                words[j]=(cipher-key)%2147483647
                key=(key+cipher)%2147483647
            end
            drift=(drift+stream[offset+1])%65521
            position=(index+1)*PCMUL+PCADD+drift
            local handler=dispatch[words[1]]
            if not handler then error('invalid instruction',0) end
            local a,b,c=words[2],words[3],words[4]
            for j=1,4 do words[j]=nil end
            handler(a,b,c)
        end
        local finalStatus, finalResult, finalTailFunction, finalTailArgs = status, result, tailFunction, tailArgs
        if localConstantCache then for k in pairs(localConstantCache) do localConstantCache[k]=nil end end
        activeConstantCache=previousConstantCache
        if finalStatus==TAIL then return finalTailFunction(unpackValues(finalTailArgs,1,finalTailArgs.n)) end
        return unpackValues(finalResult,1,finalResult.n)
    end
    return run(1,{},pack(...))
end)(getfenv and getfenv() or _ENV or _G,...)
]=]
    local replacements={PROTOTYPES=array(serialized),CONSTANTS=array(encrypted),STRIDE=stride,SALT=salt,
        PCMUL=pcMul,PCADD=pcAdd,STACKMUL=stackMul,STACKADD=stackAdd,LIVE=stateLive,DONE=stateDone,TAIL=stateTail,
        YIELDEVERY=yieldEvery,FRAMECONSTANTCACHE=tostring(frameConstantCache),
        HANDLERS=table.concat(emittedHandlers,"\n")}
    -- One substitution pass, including DONE in inserted handler source.
    replacements.HANDLERS=replacements.HANDLERS:gsub("DONE",tostring(stateDone))
    replacements.HANDLERS=replacements.HANDLERS:gsub("TAIL",tostring(stateTail))
    runtime=runtime:gsub("%u[%u%d_]+",function(token) return tostring(replacements[token] or token) end)
    return runtime
end
return R
