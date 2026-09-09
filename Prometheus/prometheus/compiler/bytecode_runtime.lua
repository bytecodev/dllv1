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
local function choice(t) return t[math.random(#t)] end

local function digestStream(stream, key, salt, stride, step)
    step = math.max(1, tonumber(step) or 1)
    local hash = (#stream * 131 + key * 17 + salt * 7 + stride) % MOD
    if #stream == 0 then return hash end
    for i = 1, #stream, step do
        hash = (hash * 131 + stream[i] + i * 17) % MOD
    end
    if ((#stream - 1) % step) ~= 0 then
        hash = (hash * 131 + stream[#stream] + #stream * 17) % MOD
    end
    return hash
end

function R.emit(protos, constants, luaVersion, options)
    options = options or {}
    local yieldEvery = tonumber(options.YieldEvery or options.yieldEvery) or 0
    if yieldEvery < 0 then yieldEvery = 0 end
    local noiseRate = tonumber(options.NoiseRate or options.noiseRate) or 96
    if noiseRate < 0 then noiseRate = 0 end
    local frameConstantCache = options.FrameConstantCache ~= false and options.frameConstantCache ~= false
    local integrityStep = tonumber(options.IntegrityStep or options.integrityStep) or 257
    if integrityStep < 0 then integrityStep = 0 end
    integrityStep = math.floor(integrityStep)
    local traceGuardEvery = tonumber(options.TraceGuardEvery or options.traceGuardEvery) or 0
    if traceGuardEvery < 0 then traceGuardEvery = 0 end
    traceGuardEvery = math.floor(traceGuardEvery)
    local instructionCache = options.InstructionCache ~= false and options.instructionCache ~= false
    local verifyOnce = options.VerifyOnce ~= false and options.verifyOnce ~= false
    local yieldInterval = tonumber(options.YieldInterval or options.yieldInterval) or 0.035
    if yieldInterval < 0 then yieldInterval = 0 end
    local handlerWrapperNoise = options.HandlerWrapperNoise == true or options.handlerWrapperNoise == true

    local regMul, regAdd = math.random(3, 97), rand()
    local pcMul, pcAdd = math.random(3, 97), rand()
    local stackMul, stackAdd = math.random(3, 97), rand()
    local stateLive, stateDone = rand(), rand()
    while stateDone == stateLive do stateDone = rand() end
    local stateTail; repeat stateTail=rand() until stateTail~=stateLive and stateTail~=stateDone
    local salt, stride = rand(), math.random(101, 8191)
    local guardSalt = rand()
    local function reg(id) return id * regMul + regAdd end
    local function pc(id) return id * pcMul + pcAdd end

    local handlers = {
        CONST = {
            "pushOne(constant(a))",
            "local v=constant(a); pushOne(v)",
            "do local id=a; local v=constant(id); pushOne(v) end",
        },
        GLOBAL = {
            "pushOne(env[constant(a)])",
            "local k=constant(a); pushOne(env[k])",
            "do local k=constant(a); local v=env[k]; pushOne(v) end",
        },
        GREF = {
            "pushOne({env,constant(a)})",
            "local k=constant(a); pushOne({env,k})",
        },
        GET = {
            "pushOne(cells[a][1])",
            "local cell=cells[a]; pushOne(cell[1])",
            "do local slot=a; pushOne(cells[slot][1]) end",
        },
        REF = {
            "pushOne({cells[a],1})",
            "local cell=cells[a]; pushOne({cell,1})",
        },
        NEW = {
            "cells[a]={peekAt(b)}",
            "local value=peekAt(b); cells[a]={value}",
        },
        INDEX = {
            "local key=popOne(); local obj=popOne(); pushOne(obj[key])",
            "local key=popOne(); local obj=popOne(); local value=obj[key]; pushOne(value)",
            "do local key=popOne(); local obj=popOne(); local v=obj[key]; pushOne(v) end",
        },
        INDEXREF = {
            "local key=popOne(); local obj=popOne(); pushOne({obj,key})",
            "local key=popOne(); local obj=popOne(); local ref={obj,key}; pushOne(ref)",
        },
        DEREF = {
            "local ref=popOne(); pushOne(ref[1][ref[2]])",
            "local ref=popOne(); local obj,key=ref[1],ref[2]; pushOne(obj[key])",
        },
        ASSIGN = {[=[local values=popPacket(); local refs={}
            for i=a,1,-1 do refs[i]=popOne() end
            for i=1,a do local ref=refs[i]; ref[1][ref[2]]=values[i]; refs[i]=nil end]=]},
        VARARG = {
            "pushPacket(varargs)",
            "local v=varargs; pushPacket(v)",
        },
        SINGLE = {
            "local v=popOne(); pushOne(v)",
            "local value=popOne(); pushOne(value)",
        },
        DUP = {
            "duplicate()",
            "do duplicate() end",
        },
        DROP = {
            "drop()",
            "do drop() end",
        },
        PACK = {"packStack(a)"},
        CALL = {
            "local args=popPacket(); local fn=popOne(); pushPacket(pack(fn(unpackValues(args,1,args.n))))",
            "local args=popPacket(); local callee=popOne(); pushPacket(pack(callee(unpackValues(args,1,args.n))))",
        },
        CALL1 = {
            "local args=popPacket(); local fn=popOne(); pushOne(fn(unpackValues(args,1,args.n)))",
            "local args=popPacket(); local callee=popOne(); local value=callee(unpackValues(args,1,args.n)); pushOne(value)",
        },
        CALL0 = {
            "local args=popPacket(); local fn=popOne(); fn(unpackValues(args,1,args.n))",
            "local args=popPacket(); local callee=popOne(); callee(unpackValues(args,1,args.n))",
        },
        FCALL1 = {[=[local x1,x2,x3
            if a>=3 then x3=popOne() end; if a>=2 then x2=popOne() end; if a>=1 then x1=popOne() end
            local fn=popOne()
            if a==0 then pushOne(fn()) elseif a==1 then pushOne(fn(x1)) elseif a==2 then pushOne(fn(x1,x2)) else pushOne(fn(x1,x2,x3)) end]=]},
        FCALL0 = {[=[local x1,x2,x3
            if a>=3 then x3=popOne() end; if a>=2 then x2=popOne() end; if a>=1 then x1=popOne() end
            local fn=popOne()
            if a==0 then fn() elseif a==1 then fn(x1) elseif a==2 then fn(x1,x2) else fn(x1,x2,x3) end]=]},
        GCALL1 = {[=[local x1,x2,x3
            if b>=3 then x3=popOne() end; if b>=2 then x2=popOne() end; if b>=1 then x1=popOne() end
            local fn=env[constant(a)]
            if b==0 then pushOne(fn()) elseif b==1 then pushOne(fn(x1)) elseif b==2 then pushOne(fn(x1,x2)) else pushOne(fn(x1,x2,x3)) end]=]},
        GCALL0 = {[=[local x1,x2,x3
            if b>=3 then x3=popOne() end; if b>=2 then x2=popOne() end; if b>=1 then x1=popOne() end
            local fn=env[constant(a)]
            if b==0 then fn() elseif b==1 then fn(x1) elseif b==2 then fn(x1,x2) else fn(x1,x2,x3) end]=]},
        METHOD = {
            "local obj=popOne(); local fn=obj[constant(a)]; pushOne(fn); pushOne(obj)",
            "local obj=popOne(); local key=constant(a); pushOne(obj[key]); pushOne(obj)",
        },
        SELFCALL = {
            "local args=popPacket(); local obj=popOne(); local fn=popOne(); pushPacket(pack(fn(obj,unpackValues(args,1,args.n))))",
            "local args=popPacket(); local selfObj=popOne(); local fn=popOne(); pushPacket(pack(fn(selfObj,unpackValues(args,1,args.n))))",
        },
        SELF1 = {
            "local args=popPacket(); local obj=popOne(); local fn=popOne(); pushOne(fn(obj,unpackValues(args,1,args.n)))",
            "local args=popPacket(); local selfObj=popOne(); local fn=popOne(); local value=fn(selfObj,unpackValues(args,1,args.n)); pushOne(value)",
        },
        SELF0 = {
            "local args=popPacket(); local obj=popOne(); local fn=popOne(); fn(obj,unpackValues(args,1,args.n))",
            "local args=popPacket(); local selfObj=popOne(); local fn=popOne(); fn(selfObj,unpackValues(args,1,args.n))",
        },
        MCALL1 = {[=[local x1,x2,x3
            if b>=3 then x3=popOne() end; if b>=2 then x2=popOne() end; if b>=1 then x1=popOne() end
            local obj=popOne(); local fn=obj[constant(a)]
            if b==0 then pushOne(fn(obj)) elseif b==1 then pushOne(fn(obj,x1)) elseif b==2 then pushOne(fn(obj,x1,x2)) else pushOne(fn(obj,x1,x2,x3)) end]=]},
        MCALL0 = {[=[local x1,x2,x3
            if b>=3 then x3=popOne() end; if b>=2 then x2=popOne() end; if b>=1 then x1=popOne() end
            local obj=popOne(); local fn=obj[constant(a)]
            if b==0 then fn(obj) elseif b==1 then fn(obj,x1) elseif b==2 then fn(obj,x1,x2) else fn(obj,x1,x2,x3) end]=]},
        TAILCALL = {
            "tailArgs=popPacket(); tailFunction=popOne(); status=TAIL",
            "local args=popPacket(); tailFunction=popOne(); tailArgs=args; status=TAIL",
        },
        TAILSELF = {[=[local args=popPacket(); local obj=popOne(); tailFunction=popOne(); tailArgs={n=args.n+1,obj}; for i=1,args.n do tailArgs[i+1]=args[i] end; status=TAIL]=]},
        CLOSURE = {[=[local child=prototypes[a]; local captured={}
            for _,slot in ipairs(child[4]) do captured[slot]=cells[slot] end
            pushOne(function(...) return run(a,captured,pack(...)) end)]=]},
        TABLE = {
            "pushOne({})",
            "local t={}; pushOne(t)",
        },
        FIELD = {
            "local value=popOne(); local key=popOne(); peekOne()[key]=value",
            "local value=popOne(); local key=popOne(); local obj=peekOne(); obj[key]=value",
        },
        APPEND = {[=[local values=popPacket(); local count=1; if b==1 then count=values.n end
            local obj=peekOne(); if b==1 and count>1 then obj=reserveArray(a+count-1) end
            for i=1,count do obj[a+i-1]=values[i] end]=]},
        JUMP = {
            "position=a+drift",
            "local target=a; position=target+drift",
        },
        JTRUE = {
            "if popOne() then position=a+drift end",
            "local ok=popOne(); if ok then position=a+drift end",
        },
        JFALSE = {
            "if not popOne() then position=a+drift end",
            "local ok=popOne(); if not ok then position=a+drift end",
        },
        RETURN = {
            "result=popPacket(); status=DONE",
            "local values=popPacket(); result=values; status=DONE",
        },
        FORPREP = {[=[local v=popPacket(); local x,y,z=tonumber(v[1]),tonumber(v[2]),tonumber(v[3])
            if x==nil or y==nil or z==nil then error('invalid numeric for',0) end
            cells[a]={x}; cells[b]={y}; cells[c]={z}]=]},
        FORCHECK = {
            "local x,y,z=cells[a][1],cells[b][1],cells[c][1]; pushOne((z>0 and x<=y) or (z<=0 and x>=y))",
            "local x=cells[a][1]; local y=cells[b][1]; local z=cells[c][1]; pushOne((z>0 and x<=y) or (z<=0 and x>=y))",
        },
        FORSTEP = {
            "cells[a][1]=cells[a][1]+cells[b][1]",
            "local cell=cells[a]; cell[1]=cell[1]+cells[b][1]",
        },
        ITERPREP = {[=[local v=popPacket(); local fn,st,control=v[1],v[2],v[3]
            if type(fn)=='table' then
                local mt=getmetatable(fn)
                if type(mt)=='table' and mt.__iter then fn,st,control=mt.__iter(fn)
                elseif not (type(mt)=='table' and mt.__call) then st=fn; fn=next; control=nil end
            end
            cells[a]={fn}; cells[b]={st}; cells[c]={control}]=]},
        ITERNEXT = {
            "local values=pack(cells[a][1](cells[b][1],cells[c][1])); cells[c][1]=values[1]; pushPacket(values)",
            "local fn,st,ctrl=cells[a][1],cells[b][1],cells[c][1]; local values=pack(fn(st,ctrl)); cells[c][1]=values[1]; pushPacket(values)",
        },
    }
    -- Lua 5.1 commits assignments right-to-left; Luau commits left-to-right.
    if luaVersion == "Lua51" then
        -- Parentheses keep gsub's replacement count out of the handler variants.
        handlers.ASSIGN={(handlers.ASSIGN[1]:gsub("for i=1,a do local ref", "for i=a,1,-1 do local ref"))}
    end
    local bin = {ADD="+",SUB="-",MUL="*",DIV="/",MOD="%",POW="^",CONCAT="..",LT="<",GT=">",LE="<=",GE=">=",EQ="==",NE="~="}
    local binNames={}; for op in pairs(bin) do binNames[#binNames+1]=op end
    table.sort(binNames)
    for _, op in ipairs(binNames) do
        local symbol=bin[op]
        handlers[op] = {
            "local right=popOne(); local left=popOne(); pushOne(left " .. symbol .. " right)",
            "local r=popOne(); local l=popOne(); local out=l " .. symbol .. " r; pushOne(out)",
            "do local b0=popOne(); local a0=popOne(); pushOne(a0 " .. symbol .. " b0) end",
        }
    end
    for op, symbol in pairs({NOT="not ",NEG="-",LEN="#"}) do
        handlers[op] = {
            "local value=popOne(); pushOne(" .. symbol .. "value)",
            "local v=popOne(); local r=" .. symbol .. "v; pushOne(r)",
        }
    end
    -- Executable decoys only mutate private noise. Dead handlers have no host effects.
    local noiseCount=math.random(6,12)
    for i=1,noiseCount do
        handlers["NOISE"..i] = {
            "noise=(noise+a*" .. math.random(3,97) .. "+b+c)%65521",
            "noise=(noise~=(noise+1) and (noise+a+b+c) or noise)%65521",
        }
    end
    for i=1,math.random(6,12) do
        handlers["DEAD"..i] = {
            "noise=(noise*" .. math.random(3,97) .. "+a)%65521",
            "noise=(noise+a+b*3+c*7)%65521",
        }
    end
    local names = {}; for name in pairs(handlers) do names[#names+1]=name end
    table.sort(names); shuffle(names)
    local opcodes, layouts, used = {}, {}, {}
    for _, name in ipairs(names) do
        opcodes[name] = {}
        local variantCount = math.random(2, 4)
        for variant=1,variantCount do
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
            local opcodeVariants=opcodes[op]
            local words = {opcodeVariants[math.random(#opcodeVariants)], instruction[2], instruction[3], instruction[4]}
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
        local digest = integrityStep > 0 and digestStream(stream, key, salt, stride, integrityStep) or 0
        serialized[pid]=array({array(stream),key,array(params),array(captures),digest})
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
    local frameFields={"cells","varargs","position","drift","result","status","tailFunction","tailArgs","noise"}
    for _,name in ipairs(names) do
        for _,code in ipairs(opcodes[name]) do
            local body=choice(handlers[name])
            if handlerWrapperNoise then
                local wrapperStyle=math.random(1,4)
                if wrapperStyle==1 then
                    body="do "..body.." end"
                elseif wrapperStyle==2 then
                    body="local gate=(noise+"..rand()..")%65521; if gate>=0 then "..body.." else noise=gate end"
                elseif wrapperStyle==3 then
                    body="if noise~=-1 then "..body.." end"
                end
            else
                body="do "..body.." end"
            end
            for _,helper in ipairs({"constant","pushOne","pushPacket","peekAt","packStack","reserveArray"}) do
                body=body:gsub(helper.."%(",helper.."(f,")
            end
            for _,helper in ipairs({"popOne","popPacket","peekOne","duplicate","drop"}) do
                body=body:gsub(helper.."%(%)",helper.."(f)")
            end
            for _,field in ipairs(frameFields) do
                body=body:gsub("%f[%w_]"..field.."%f[^%w_]","f."..field)
            end
            local args={"a","b","c"}; local layout=layouts[code]
            local params={args[layout[1]],args[layout[2]],args[layout[3]]}
            emittedHandlers[#emittedHandlers+1]="dispatch["..code.."]=function(f,"..table.concat(params,",")..") "..body.." end"
        end
    end
    shuffle(emittedHandlers)
    local runtime = [=[
return (function(env,...)
    local prototypes=PROTOTYPES
    local pool=CONSTANTS
    local unpackValues=unpack or table.unpack
    local function pack(...) return {n=select('#',...),...} end
    local createArray=table and table.create
    local nilSentinel={}
    local decodedProtoCache={}
    local verifiedProtoCache={}
    local guardString=string
    local guardTable=table
    local guardType=type
    local guardSelect=select
    local guardPcall=pcall
    local guardSalt=GUARDSALT
    local function traceGuard()
        if TRACEGUARDEVERY<=0 then return true end
        local ok,good=guardPcall(function()
            return guardType(prototypes)=='table'
                and guardType(pool)=='table'
                and guardSelect('#',1,nil,false)==3
                and guardString.char(66,67)=='BC'
                and guardTable.concat({'v','m'},'')=='vm'
                and ((guardSalt+1)>guardSalt)
        end)
        if not ok or good~=true then error('runtime guard',0) end
        return true
    end
    local function verifyProto(pid,proto)
        if INTEGRITYSTEP<=0 then return true end
        if VERIFYONCE and verifiedProtoCache[pid] then return true end
        local stream=proto[1]
        local key=proto[2]
        local hash=(#stream*131+key*17+SALT*7+STRIDE)%2147483647
        if #stream>0 then
            for i=1,#stream,INTEGRITYSTEP do
                hash=(hash*131+stream[i]+i*17)%2147483647
            end
            if ((#stream-1)%INTEGRITYSTEP)~=0 then
                hash=(hash*131+stream[#stream]+#stream*17)%2147483647
            end
        end
        if hash~=proto[5] then error('invalid bytecode',0) end
        if VERIFYONCE then verifiedProtoCache[pid]=true end
        return true
    end
    local function constant(frame,id)
        local cache=frame.constantCache
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
    local function pushOne(frame,value)
        frame.top=frame.top+STACKMUL
        frame.stack[frame.top]=value
    end
    local function pushPacket(frame,values)
        frame.top=frame.top+STACKMUL
        frame.stack[frame.top]=values[1]
        frame.packets[frame.top]=values
    end
    local function clearTop(frame)
        frame.stack[frame.top]=nil
        frame.packets[frame.top]=nil
        frame.top=frame.top-STACKMUL
    end
    local function popOne(frame)
        local value=frame.stack[frame.top]
        clearTop(frame)
        return value
    end
    local function popPacket(frame)
        local values=frame.packets[frame.top]
        if not values then
            values={n=1,frame.stack[frame.top]}
        end
        clearTop(frame)
        return values
    end
    local function peekOne(frame) return frame.stack[frame.top] end
    local function peekAt(frame,index)
        local values=frame.packets[frame.top]
        if values then return values[index] end
        if index==1 then return frame.stack[frame.top] end
        return nil
    end
    local function duplicate(frame)
        local old=frame.top
        frame.top=old+STACKMUL
        frame.stack[frame.top]=frame.stack[old]
        frame.packets[frame.top]=frame.packets[old]
    end
    local function drop(frame) clearTop(frame) end
    local function reserveArray(frame,size)
        local previous=frame.stack[frame.top]
        if not createArray then return previous end
        local replacement=createArray(size)
        for key,value in pairs(previous) do replacement[key]=value end
        frame.stack[frame.top]=replacement
        return replacement
    end
    local function packStack(frame,count)
        local first=frame.top-(count-1)*STACKMUL
        local values={n=0}
        for i=1,count do
            local position=first+(i-1)*STACKMUL
            local packet=frame.packets[position]
            local arity=i==count and packet and packet.n or 1
            for j=1,arity do
                values.n=values.n+1
                local value
                if packet then value=packet[j]
                elseif j==1 then value=frame.stack[position] end
                values[values.n]=value
            end
            frame.stack[position]=nil
            frame.packets[position]=nil
        end
        frame.top=first-STACKMUL
        pushPacket(frame,values)
    end
    local run
    local dispatch={}
    HANDLERS
    run=function(id,captured,args)
        traceGuard()
        local frameConstantCacheEnabled=FRAMECONSTANTCACHE
        local localConstantCache=frameConstantCacheEnabled and {} or nil
        local proto=prototypes[id]; verifyProto(id,proto)
        local stream=proto[1]
        local decodedCache=nil
        if INSTRUCTIONCACHE then
            decodedCache=decodedProtoCache[id]
            if not decodedCache then decodedCache={}; decodedProtoCache[id]=decodedCache end
        end
        local cells={}; for slot,cell in pairs(captured) do cells[slot]=cell end
        for i,slot in ipairs(proto[3]) do cells[slot]={args[i]} end
        local varargs={n=math.max(0,args.n-#proto[3])}
        for i=1,varargs.n do varargs[i]=args[i+#proto[3]] end
        args=nil
        local frame={
            cells=cells,varargs=varargs,stack={},packets={},top=STACKADD,
            drift=proto[2]%65521,status=LIVE,noise=proto[2]%65521,
            constantCache=localConstantCache,
        }
        frame.position=PCMUL+PCADD+frame.drift
        local vmBudget=0
        local guardBudget=0
        local clockFunc=(os and os.clock) or nil
        local lastYieldAt=clockFunc and clockFunc() or 0
        while frame.status==LIVE do
            vmBudget=vmBudget+1
            guardBudget=guardBudget+1
            if YIELDEVERY>0 and vmBudget>=YIELDEVERY then
                vmBudget=0
                if YIELDINTERVAL<=0 then
                    safeYield()
                elseif clockFunc then
                    local now=clockFunc()
                    if (now-lastYieldAt)>=YIELDINTERVAL then lastYieldAt=now; safeYield() end
                else
                    safeYield()
                end
            end
            if TRACEGUARDEVERY>0 and guardBudget>=TRACEGUARDEVERY then guardBudget=0; traceGuard() end
            local index=(frame.position-frame.drift-PCADD)/PCMUL
            local offset=(index-1)*4
            local cacheBase=index*4
            local opcode,a,b,c
            if decodedCache then
                opcode=decodedCache[cacheBase-3]
                if opcode~=nil then
                    a=decodedCache[cacheBase-2]; b=decodedCache[cacheBase-1]; c=decodedCache[cacheBase]
                end
            end
            if opcode==nil then
                local key=(proto[2]+index*STRIDE+SALT)%2147483647
                key=(key*48271+97)%2147483647
                local cipher=stream[offset+1]
                opcode=(cipher-key)%2147483647
                key=(key+cipher)%2147483647
                key=(key*48271+2*97)%2147483647
                cipher=stream[offset+2]
                a=(cipher-key)%2147483647
                key=(key+cipher)%2147483647
                key=(key*48271+3*97)%2147483647
                cipher=stream[offset+3]
                b=(cipher-key)%2147483647
                key=(key+cipher)%2147483647
                key=(key*48271+4*97)%2147483647
                cipher=stream[offset+4]
                c=(cipher-key)%2147483647
                if decodedCache then
                    decodedCache[cacheBase-3]=opcode; decodedCache[cacheBase-2]=a; decodedCache[cacheBase-1]=b; decodedCache[cacheBase]=c
                end
            end
            frame.drift=(frame.drift+stream[offset+1])%65521
            frame.position=(index+1)*PCMUL+PCADD+frame.drift
            local handler=dispatch[opcode]
            if not handler then error('invalid instruction',0) end
            handler(frame,a,b,c)
        end
        local finalStatus, finalResult, finalTailFunction, finalTailArgs = frame.status, frame.result, frame.tailFunction, frame.tailArgs
        if localConstantCache then for k in pairs(localConstantCache) do localConstantCache[k]=nil end end
        if finalStatus==TAIL then return finalTailFunction(unpackValues(finalTailArgs,1,finalTailArgs.n)) end
        return unpackValues(finalResult,1,finalResult.n)
    end
    return run(1,{},pack(...))
end)(getfenv and getfenv() or _ENV or _G,...)
]=]
    local replacements={PROTOTYPES=array(serialized),CONSTANTS=array(encrypted),STRIDE=stride,SALT=salt,
        PCMUL=pcMul,PCADD=pcAdd,STACKMUL=stackMul,STACKADD=stackAdd,LIVE=stateLive,DONE=stateDone,TAIL=stateTail,
        YIELDEVERY=yieldEvery,YIELDINTERVAL=yieldInterval,FRAMECONSTANTCACHE=tostring(frameConstantCache),
        INTEGRITYSTEP=integrityStep,VERIFYONCE=tostring(verifyOnce),INSTRUCTIONCACHE=tostring(instructionCache),
        TRACEGUARDEVERY=traceGuardEvery,GUARDSALT=guardSalt,HANDLERS=table.concat(emittedHandlers,"\n")}
    -- One substitution pass, including DONE/TAIL in inserted handler source.
    replacements.HANDLERS=replacements.HANDLERS:gsub("DONE",tostring(stateDone))
    replacements.HANDLERS=replacements.HANDLERS:gsub("TAIL",tostring(stateTail))
    runtime=runtime:gsub("%u[%u%d_]+",function(token) return tostring(replacements[token] or token) end)
    return runtime
end
return R
