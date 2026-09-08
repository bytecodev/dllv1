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
    local yieldEvery = tonumber(options.YieldEvery or options.yieldEvery) or 12000
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
            "push(pack(constant(a)))",
            "local v=constant(a); push(pack(v))",
            "do local id=a; local v=constant(id); push(pack(v)) end",
        },
        GLOBAL = {
            "push(pack(env[constant(a)]))",
            "local k=constant(a); push(pack(env[k]))",
            "do local k=constant(a); local v=env[k]; push(pack(v)) end",
        },
        GREF = {
            "push(pack({env,constant(a)}))",
            "local k=constant(a); push(pack({env,k}))",
        },
        GET = {
            "push(pack(cells[a][1]))",
            "local cell=cells[a]; push(pack(cell[1]))",
            "do local slot=a; push(pack(cells[slot][1])) end",
        },
        REF = {
            "push(pack({cells[a],1}))",
            "local cell=cells[a]; push(pack({cell,1}))",
        },
        NEW = {
            "cells[a]={peek()[b]}",
            "local values=peek(); cells[a]={values[b]}",
        },
        INDEX = {
            "local key=pop()[1]; local obj=pop()[1]; push(pack(obj[key]))",
            "local rk=pop(); local ro=pop(); push(pack(ro[1][rk[1]]))",
            "do local key=pop()[1]; local obj=pop()[1]; local v=obj[key]; push(pack(v)) end",
        },
        INDEXREF = {
            "local key=pop()[1]; local obj=pop()[1]; push(pack({obj,key}))",
            "local rk=pop(); local ro=pop(); push(pack({ro[1],rk[1]}))",
        },
        DEREF = {
            "local ref=pop()[1]; push(pack(ref[1][ref[2]]))",
            "local ref=pop()[1]; local obj,key=ref[1],ref[2]; push(pack(obj[key]))",
        },
        ASSIGN = {[=[local values=pop(); local refs={}
            for i=a,1,-1 do refs[i]=pop()[1] end
            for i=1,a do local ref=refs[i]; ref[1][ref[2]]=values[i]; refs[i]=nil end]=]},
        VARARG = {
            "push(varargs)",
            "local v=varargs; push(v)",
        },
        SINGLE = {
            "local v=pop()[1]; push(pack(v))",
            "local values=pop(); push(pack(values[1]))",
        },
        DUP = {
            "push(peek())",
            "local v=peek(); push(v)",
        },
        DROP = {
            "pop()",
            "local _=pop()",
        },
        PACK = {[=[local parts={}; for i=a,1,-1 do parts[i]=pop() end
            local values={n=0}; for i=1,a do
                local part=parts[i]; local count=1; if i==a then count=part.n end
                for j=1,count do values.n=values.n+1; values[values.n]=part[j] end
                parts[i]=nil
            end; push(values)]=]},
        CALL = {
            "local args=pop(); local fn=pop()[1]; push(pack(fn(unpackValues(args,1,args.n))))",
            "local aPack=pop(); local callee=pop()[1]; push(pack(callee(unpackValues(aPack,1,aPack.n))))",
        },
        METHOD = {
            "local obj=pop()[1]; local fn=obj[constant(a)]; push(pack(fn)); push(pack(obj))",
            "local obj=pop()[1]; local key=constant(a); push(pack(obj[key])); push(pack(obj))",
        },
        SELFCALL = {
            "local args=pop(); local obj=pop()[1]; local fn=pop()[1]; push(pack(fn(obj,unpackValues(args,1,args.n))))",
            "local argv=pop(); local selfObj=pop()[1]; local fn=pop()[1]; push(pack(fn(selfObj,unpackValues(argv,1,argv.n))))",
        },
        TAILCALL = {
            "tailArgs=pop(); tailFunction=pop()[1]; status=TAIL",
            "local aPack=pop(); tailFunction=pop()[1]; tailArgs=aPack; status=TAIL",
        },
        TAILSELF = {[=[local args=pop(); local obj=pop()[1]; tailFunction=pop()[1]; tailArgs={n=args.n+1,obj}; for i=1,args.n do tailArgs[i+1]=args[i] end; status=TAIL]=]},
        CLOSURE = {[=[local child=prototypes[a]; local captured={}
            for _,slot in ipairs(child[4]) do captured[slot]=cells[slot] end
            push(pack(function(...) return run(a,captured,pack(...)) end))]=]},
        TABLE = {
            "push(pack({}))",
            "local t={}; push(pack(t))",
        },
        FIELD = {
            "local value=pop()[1]; local key=pop()[1]; peek()[1][key]=value",
            "local valuePack=pop(); local keyPack=pop(); local obj=peek()[1]; obj[keyPack[1]]=valuePack[1]",
        },
        APPEND = {[=[local values=pop(); local obj=peek()[1]; local count=1; if b==1 then count=values.n end; for i=1,count do obj[a+i-1]=values[i] end]=]},
        JUMP = {
            "position=a+drift",
            "local target=a; position=target+drift",
        },
        JTRUE = {
            "if pop()[1] then position=a+drift end",
            "local ok=pop()[1]; if ok then position=a+drift end",
        },
        JFALSE = {
            "if not pop()[1] then position=a+drift end",
            "local ok=pop()[1]; if not ok then position=a+drift end",
        },
        RETURN = {
            "result=pop(); status=DONE",
            "local r=pop(); result=r; status=DONE",
        },
        FORPREP = {[=[local v=pop(); local x,y,z=tonumber(v[1]),tonumber(v[2]),tonumber(v[3])
            if x==nil or y==nil or z==nil then error('invalid numeric for',0) end
            cells[a]={x}; cells[b]={y}; cells[c]={z}]=]},
        FORCHECK = {
            "local x,y,z=cells[a][1],cells[b][1],cells[c][1]; push(pack((z>0 and x<=y) or (z<=0 and x>=y)))",
            "local x=cells[a][1]; local y=cells[b][1]; local z=cells[c][1]; push(pack((z>0 and x<=y) or (z<=0 and x>=y)))",
        },
        FORSTEP = {
            "cells[a][1]=cells[a][1]+cells[b][1]",
            "local cell=cells[a]; cell[1]=cell[1]+cells[b][1]",
        },
        ITERPREP = {[=[local v=pop(); local fn,st,control=v[1],v[2],v[3]
            if type(fn)=='table' then
                local mt=getmetatable(fn)
                if type(mt)=='table' and mt.__iter then fn,st,control=mt.__iter(fn)
                elseif not (type(mt)=='table' and mt.__call) then st=fn; fn=next; control=nil end
            end
            cells[a]={fn}; cells[b]={st}; cells[c]={control}]=]},
        ITERNEXT = {
            "local values=pack(cells[a][1](cells[b][1],cells[c][1])); cells[c][1]=values[1]; push(values)",
            "local fn,st,ctrl=cells[a][1],cells[b][1],cells[c][1]; local values=pack(fn(st,ctrl)); cells[c][1]=values[1]; push(values)",
        },
    }
    -- Lua 5.1 commits assignments right-to-left; Luau commits left-to-right.
    if luaVersion == "Lua51" then
        handlers.ASSIGN={handlers.ASSIGN[1]:gsub("for i=1,a do local ref", "for i=a,1,-1 do local ref")}
    end
    local bin = {ADD="+",SUB="-",MUL="*",DIV="/",MOD="%",POW="^",CONCAT="..",LT="<",GT=">",LE="<=",GE=">=",EQ="==",NE="~="}
    local binNames={}; for op in pairs(bin) do binNames[#binNames+1]=op end
    table.sort(binNames)
    for _, op in ipairs(binNames) do
        local symbol=bin[op]
        handlers[op] = {
            "local right=pop()[1]; local left=pop()[1]; push(pack(left " .. symbol .. " right))",
            "local r=pop()[1]; local l=pop()[1]; local out=l " .. symbol .. " r; push(pack(out))",
            "do local b0=pop()[1]; local a0=pop()[1]; push(pack(a0 " .. symbol .. " b0)) end",
        }
    end
    for op, symbol in pairs({NOT="not ",NEG="-",LEN="#"}) do
        handlers[op] = {
            "local value=pop()[1]; push(pack(" .. symbol .. "value))",
            "local v=pop()[1]; local r=" .. symbol .. "v; push(pack(r))",
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
        traceGuard()
        local previousConstantCache=activeConstantCache
        local frameConstantCacheEnabled=FRAMECONSTANTCACHE
        local localConstantCache=frameConstantCacheEnabled and {} or nil
        activeConstantCache=localConstantCache
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
        local stack={}; local top=STACKADD
        local function push(value) top=top+STACKMUL; stack[top]=value end
        local function pop() local value=stack[top]; stack[top]=nil; top=top-STACKMUL; return value end
        local function peek() return stack[top] end
        local drift=proto[2]%65521
        local position=PCMUL+PCADD+drift
        local status=LIVE; local result; local tailFunction,tailArgs; local noise=proto[2]%65521
        local vmBudget=0
        local guardBudget=0
        local clockFunc=(os and os.clock) or nil
        local lastYieldAt=clockFunc and clockFunc() or 0
        local dispatch={}
        HANDLERS
        while status==LIVE do
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
            local index=(position-drift-PCADD)/PCMUL
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
            drift=(drift+stream[offset+1])%65521
            position=(index+1)*PCMUL+PCADD+drift
            local handler=dispatch[opcode]
            if not handler then error('invalid instruction',0) end
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
