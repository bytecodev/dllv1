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
local function randomIdent(len)
    local first="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    local rest=first.."0123456789_"
    local out={}
    local p=math.random(#first); out[1]=first:sub(p,p)
    for i=2,len do local n=math.random(#rest); out[i]=rest:sub(n,n) end
    return table.concat(out)
end

local function digestStream(stream, key, salt, stride, step, mod, mul, lenMix, keyMix, saltMix, indexMix)
    step = math.max(1, tonumber(step) or 1)
    local hash = (#stream * lenMix + key * keyMix + salt * saltMix + stride) % mod
    if #stream == 0 then return hash end
    local offset = ((key + salt) % step) + 1
    for i = offset, #stream, step do
        hash = (hash * mul + stream[i] + i * indexMix) % mod
    end
    if ((#stream - offset) % step) ~= 0 then
        hash = (hash * mul + stream[#stream] + #stream * indexMix) % mod
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
    local constantCacheSlots = math.floor(tonumber(options.ConstantCacheSlots or options.constantCacheSlots) or 32)
    if constantCacheSlots < 1 then frameConstantCache=false; constantCacheSlots=1 end
    local integrityStep = tonumber(options.IntegrityStep or options.integrityStep) or 1
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

    -- Every build receives independent arithmetic fingerprints. Multipliers
    -- stay small enough that all intermediate integers remain exact doubles.
    local cipherMod = MOD - math.random(0, 997) * 2
    local constMod = MOD - math.random(998, 1997) * 2
    local digestMod = MOD - math.random(1998, 2997) * 2
    local cipherMuls={math.random(1009,99991),math.random(1009,99991),math.random(1009,99991)}
    local constMuls={math.random(1009,99991),math.random(1009,99991),math.random(1009,99991)}
    local roundAdds={}
    local constAdds={}
    for lane=1,3 do
        roundAdds[lane]={rand(),rand(),rand(),rand()}
        constAdds[lane]=rand()
    end
    local digestMul=math.random(1009,99991)
    local digestLenMix,digestKeyMix,digestSaltMix,digestIndexMix=math.random(11,997),math.random(11,997),math.random(11,997),math.random(11,997)
    local constDigestMul,constDigestIndexMix=math.random(1009,99991),math.random(11,997)
    local digestMaskMul,constDigestMaskMul=math.random(11,997),math.random(11,997)
    local dispatchSealMix,dispatchSealRemainderMix=math.random(1009,99991),math.random(11,997)
    local regMul, regAdd = math.random(3, 97), rand()
    local pcMul, pcAdd = math.random(3, 97), rand()
    local stackMul, stackAdd = math.random(3, 97), rand()
    local stateLive, stateDone = rand(), rand()
    while stateDone == stateLive do stateDone = rand() end
    local stateTail; repeat stateTail=rand() until stateTail~=stateLive and stateTail~=stateDone
    local salt, stride = rand(), math.random(101, 8191)
    local constSalt, constStride = rand(), math.random(101,8191)
    local driftMod,noiseMod=math.random(50021,120011),math.random(50021,120011)
    local constantCacheMul=math.random(101,1009)
    local cacheMaskA,cacheMaskB,cacheMaskC=rand(),rand(),rand()
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
            for _,slot in ipairs(child[PCAPTURES]) do captured[slot]=cells[slot] end
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
            "noise=(noise+a*" .. math.random(3,97) .. "+b+c)%"..noiseMod,
            "noise=(noise~=(noise+1) and (noise+a+b+c) or noise)%"..noiseMod,
        }
    end
    for i=1,math.random(6,12) do
        handlers["DEAD"..i] = {
            "noise=(noise*" .. math.random(3,97) .. "+a)%"..noiseMod,
            "noise=(noise+a+b*3+c*7)%"..noiseMod,
        }
    end
    local names = {}; for name in pairs(handlers) do names[#names+1]=name end
    table.sort(names); shuffle(names)
    local operandUses={
        CONST={true},GLOBAL={true},GREF={true},GET={true},REF={true},NEW={true,true},ASSIGN={true},PACK={true},
        FCALL1={true},FCALL0={true},GCALL1={true,true},GCALL0={true,true},METHOD={true},MCALL1={true,true},MCALL0={true,true},
        CLOSURE={true},APPEND={true,true},JUMP={true},JTRUE={true},JFALSE={true},
        FORPREP={true,true,true},FORCHECK={true,true,true},FORSTEP={true,true},ITERPREP={true,true,true},ITERNEXT={true,true,true},
    }
    local opcodes, layouts, operandMasks, used = {}, {}, {}, {}
    for _, name in ipairs(names) do
        opcodes[name] = {}
        local variantCount = math.random(2, 4)
        for variant=1,variantCount do
            local code; repeat code=math.random(100,1000000) until not used[code]
            used[code]=true; opcodes[name][variant]=code
            layouts[code]=shuffle({1,2,3})
            local use=operandUses[name] or (name:match('^NOISE') or name:match('^DEAD')) and {true,true,true} or {}
            operandMasks[code]={use[1] and math.random(1000,50000) or 0,use[2] and math.random(1000,50000) or 0,use[3] and math.random(1000,50000) or 0}
        end
    end
    local slotArgs = {
        GET={1},REF={1},NEW={1},FORPREP={1,2,3},FORCHECK={1,2,3},FORSTEP={1,2},
        ITERPREP={1,2,3},ITERNEXT={1,2,3},
    }
    -- Prototype and constant records do not keep stable field positions across
    -- builds. A raw table dump therefore needs the generated layout as well.
    local protoLayout=shuffle({1,2,3,4,5,6,7})
    local pStream,pKey,pParams,pCaptures,pDigest,pMode,pCacheKey=protoLayout[1],protoLayout[2],protoLayout[3],protoLayout[4],protoLayout[5],protoLayout[6],protoLayout[7]
    local constLayout=shuffle({1,2,3,4})
    local cMode,cKey,cBytes,cDigest=constLayout[1],constLayout[2],constLayout[3],constLayout[4]
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
        local key = rand(); local stream = {}; local mode=math.random(1,3)
        for i, instruction in ipairs(code) do
            local op = instruction[1]
            local opcodeVariants=opcodes[op]
            local words = {opcodeVariants[math.random(#opcodeVariants)], instruction[2], instruction[3], instruction[4]}
            for _, arg in ipairs(slotArgs[op] or {}) do words[arg+1]=reg(words[arg+1]) end
            if op=="JUMP" or op=="JTRUE" or op=="JFALSE" then words[2]=pc(locations[words[2]]) end
            local masks=operandMasks[words[1]]
            words[2]=words[2]+masks[1]; words[3]=words[3]+masks[2]; words[4]=words[4]+masks[3]
            local layout=layouts[words[1]]
            words={words[1],words[layout[1]+1],words[layout[2]+1],words[layout[3]+1]}
            local state
            if mode==1 then state=(key+i*stride+salt)%cipherMod
            elseif mode==2 then state=(key*3+i*stride+salt)%cipherMod
            else state=(key+i*stride*3+salt)%cipherMod end
            for j=1,4 do
                if mode==1 then
                    state=(state*cipherMuls[1]+roundAdds[1][j])%cipherMod
                elseif mode==2 then
                    state=(state*cipherMuls[2]+roundAdds[2][j]+i)%cipherMod
                else
                    state=(state*cipherMuls[3]+roundAdds[3][j]+key)%cipherMod
                end
                local extra=mode==2 and j*key or mode==3 and i*j or 0
                local cipher=(words[j]+state+extra)%cipherMod
                stream[#stream+1]=cipher
                if mode==1 then state=(state+cipher)%cipherMod
                elseif mode==2 then state=(state+cipher*3+j)%cipherMod
                else state=(state+cipher+j*7)%cipherMod end
            end
        end
        local params, captures = {}, {}
        for _, id in ipairs(p.params) do params[#params+1]=reg(id) end
        for _, id in ipairs(p.captures) do captures[#captures+1]=reg(id) end
        local cacheKey=rand()
        local digest = integrityStep > 0 and digestStream(stream,key,salt,stride,integrityStep,digestMod,digestMul,digestLenMix,digestKeyMix,digestSaltMix,digestIndexMix) or 0
        if integrityStep>0 then
            digest=(digest*digestMul+mode*digestSaltMix+cacheKey*digestKeyMix+pid)%digestMod
            digest=(digest*digestMul+#params*digestLenMix+#captures*digestSaltMix)%digestMod
            for i,value in ipairs(params) do digest=(digest*digestMul+value+i*digestIndexMix)%digestMod end
            for i,value in ipairs(captures) do digest=(digest*digestMul+value+i*digestKeyMix)%digestMod end
        end
        local record={}; record[pStream]=array(stream); record[pKey]=key; record[pParams]=array(params); record[pCaptures]=array(captures)
        record[pDigest]=(digest+key*digestMaskMul+mode*digestSaltMix)%digestMod; record[pMode]=mode; record[pCacheKey]=cacheKey
        serialized[pid]=array(record)
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
        local key = rand(); local mode=math.random(1,3); local state
        if mode==1 then state=(key+id*constStride+constSalt)%constMod
        elseif mode==2 then state=(key*3+id*constStride+constSalt)%constMod
        else state=(key+id*constStride*3+constSalt)%constMod end
        local bytes={}
        -- Type tags are encrypted along with the constant payload.
        for i=0,#plain do
            local byte = i==0 and tag or string.byte(plain,i)
            local n=i+1
            if mode==1 then state=(state*constMuls[1]+n*constAdds[1])%constMod
            elseif mode==2 then state=(state*constMuls[2]+n*constAdds[2]+id)%constMod
            else state=(state*constMuls[3]+n*constAdds[3]+key)%constMod end
            local extra=mode==2 and n or mode==3 and key or 0
            local cipher=(byte+(state+extra)%256)%256
            bytes[#bytes+1]=cipher
            if mode==1 then state=(state+cipher)%constMod
            elseif mode==2 then state=(state+cipher*3+n)%constMod
            else state=(state+cipher+n*7)%constMod end
        end
        local digest=(key+id*digestKeyMix+mode*digestSaltMix+#bytes*digestLenMix)%digestMod
        for i,cipher in ipairs(bytes) do digest=(digest*constDigestMul+cipher+i*constDigestIndexMix)%digestMod end
        local record={}; record[cMode]=mode; record[cKey]=key; record[cBytes]=array(bytes)
        record[cDigest]=(digest+key*constDigestMaskMul+mode*digestKeyMix)%digestMod
        encrypted[id]=array(record)
    end
    local emittedHandlers={}
    local frameFields={"cells","varargs","position","drift","result","status","tailFunction","tailArgs","noise","stack","packets","top","constantCache"}
    local frameAliases,usedAliases={},{}
    for _,field in ipairs(frameFields) do
        local alias; repeat alias=randomIdent(math.random(6,11)) until not usedAliases[alias]
        usedAliases[alias]=true; frameAliases[field]=alias
    end
    for _,name in ipairs(names) do
        for _,code in ipairs(opcodes[name]) do
            local body=choice(handlers[name])
            local masks=operandMasks[code]
            local decoded={}
            for index,name0 in ipairs({"a","b","c"}) do
                if masks[index]~=0 then
                    local style=math.random(1,3)
                    if style==1 then decoded[#decoded+1]=name0.."="..name0.."-"..masks[index]
                    elseif style==2 then decoded[#decoded+1]=name0.."=("..name0.."-"..masks[index]..")"
                    else decoded[#decoded+1]="local "..name0.."0="..name0.."-"..masks[index]..";"..name0.."="..name0.."0" end
                end
            end
            if #decoded>0 then body=table.concat(decoded,";")..";"..body end
            if handlerWrapperNoise then
                local wrapperStyle=math.random(1,4)
                if wrapperStyle==1 then
                    body="do "..body.." end"
                elseif wrapperStyle==2 then
                    body="local gate=(noise+"..rand()..")%"..noiseMod.."; if gate>=0 then "..body.." else noise=gate end"
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
                body=body:gsub("%f[%w_]"..field.."%f[^%w_]","f."..frameAliases[field])
            end
            local args={"a","b","c"}; local layout=layouts[code]
            local params={args[layout[1]],args[layout[2]],args[layout[3]]}
            emittedHandlers[#emittedHandlers+1]="dispatch["..code.."]=function(f,"..table.concat(params,",")..") "..body.." end"
        end
    end
    shuffle(emittedHandlers)
    local dispatchSeal=0
    for _,name in ipairs(names) do
        for _,code in ipairs(opcodes[name]) do
            dispatchSeal=(dispatchSeal+code*dispatchSealMix+(code%997)*dispatchSealRemainderMix)%digestMod
        end
    end
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
    TRACEHELPERS
    local function verifyProto(pid,proto)
        if INTEGRITYSTEP<=0 then return true end
        if VERIFYONCE and verifiedProtoCache[pid] then return true end
        local stream=proto[PSTREAM]
        local key=proto[PKEY]
        local hash=(#stream*DIGESTLENMIX+key*DIGESTKEYMIX+SALT*DIGESTSALTMIX+STRIDE)%DIGESTMOD
        if #stream>0 then
            local offset=((key+SALT)%INTEGRITYSTEP)+1
            for i=offset,#stream,INTEGRITYSTEP do
                hash=(hash*DIGESTMUL+stream[i]+i*DIGESTINDEXMIX)%DIGESTMOD
            end
            if ((#stream-offset)%INTEGRITYSTEP)~=0 then
                hash=(hash*DIGESTMUL+stream[#stream]+#stream*DIGESTINDEXMIX)%DIGESTMOD
            end
        end
        local mode=proto[PMODE]
        local cacheKey=proto[PCACHEKEY]
        local params=proto[PPARAMS]
        local captures=proto[PCAPTURES]
        hash=(hash*DIGESTMUL+mode*DIGESTSALTMIX+cacheKey*DIGESTKEYMIX+pid)%DIGESTMOD
        hash=(hash*DIGESTMUL+#params*DIGESTLENMIX+#captures*DIGESTSALTMIX)%DIGESTMOD
        for i,value in ipairs(params) do hash=(hash*DIGESTMUL+value+i*DIGESTINDEXMIX)%DIGESTMOD end
        for i,value in ipairs(captures) do hash=(hash*DIGESTMUL+value+i*DIGESTKEYMIX)%DIGESTMOD end
        local sealed=(hash+key*DIGESTMASKMUL+mode*DIGESTSALTMIX)%DIGESTMOD
        if sealed~=proto[PDIGEST] then error(ERRORBYTECODE,0) end
        if VERIFYONCE then verifiedProtoCache[pid]=true end
        return true
    end
    local function constant(frame,id)
        local cache=frame.constantCache
        if cache then
            local slot=(id*CONSTCACHEMUL)%CONSTCACHESLOTS+1
            if cache[1][slot]==id then
                local cached=cache[2][slot]
                if cached==nilSentinel then return nil end
                return cached
            end
        end
        local entry=pool[id]; local mode=entry[CMODE]; local key=entry[CKEY]; local bytes=entry[CBYTES]
        local chars={}; local tag; local state
        local hash=(key+id*DIGESTKEYMIX+mode*DIGESTSALTMIX+#bytes*DIGESTLENMIX)%DIGESTMOD
        if mode==1 then
            state=(key+id*CONSTSTRIDE+CONSTSALT)%CONSTMOD
            for i=1,#bytes do
                state=(state*CONSTMUL1+i*CONSTADD1)%CONSTMOD
                local cipher=bytes[i]; local value=(cipher-state%256)%256
                state=(state+cipher)%CONSTMOD
                hash=(hash*CONSTDIGESTMUL+cipher+i*CONSTDIGESTINDEXMIX)%DIGESTMOD
                if i==1 then tag=value else chars[i-1]=string.char(value) end
            end
        elseif mode==2 then
            state=(key*3+id*CONSTSTRIDE+CONSTSALT)%CONSTMOD
            for i=1,#bytes do
                state=(state*CONSTMUL2+i*CONSTADD2+id)%CONSTMOD
                local cipher=bytes[i]; local value=(cipher-(state+i)%256)%256
                state=(state+cipher*3+i)%CONSTMOD
                hash=(hash*CONSTDIGESTMUL+cipher+i*CONSTDIGESTINDEXMIX)%DIGESTMOD
                if i==1 then tag=value else chars[i-1]=string.char(value) end
            end
        else
            state=(key+id*CONSTSTRIDE*3+CONSTSALT)%CONSTMOD
            for i=1,#bytes do
                state=(state*CONSTMUL3+i*CONSTADD3+key)%CONSTMOD
                local cipher=bytes[i]; local value=(cipher-(state+key)%256)%256
                state=(state+cipher+i*7)%CONSTMOD
                hash=(hash*CONSTDIGESTMUL+cipher+i*CONSTDIGESTINDEXMIX)%DIGESTMOD
                if i==1 then tag=value else chars[i-1]=string.char(value) end
            end
        end
        local sealed=(hash+key*CONSTDIGESTMASKMUL+mode*DIGESTKEYMIX)%DIGESTMOD
        if sealed~=entry[CDIGEST] then error(ERRORCONSTANT,0) end
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
        if cache then
            local slot=(id*CONSTCACHEMUL)%CONSTCACHESLOTS+1
            cache[1][slot]=id; cache[2][slot]=value==nil and nilSentinel or value
        end
        return value
    end
    YIELDHELPERS
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
    local handlerCount=0
    local handlerSeal=0
    for code,handler in pairs(dispatch) do
        if type(code)~='number' or type(handler)~='function' then error(ERRORDISPATCH,0) end
        handlerCount=handlerCount+1
        handlerSeal=(handlerSeal+code*DISPATCHSEALMIX+(code%997)*DISPATCHSEALREMAINDERMIX)%DIGESTMOD
    end
    if handlerCount~=HANDLERCOUNT or handlerSeal~=DISPATCHSEAL then error(ERRORDISPATCH,0) end
    run=function(id,captured,args)
        STARTGUARD
        local frameConstantCacheEnabled=FRAMECONSTANTCACHE
        local localConstantCache=frameConstantCacheEnabled and {{},{}} or nil
        local proto=prototypes[id]; verifyProto(id,proto)
        local stream=proto[PSTREAM]
        local protoKey=proto[PKEY]
        local decodeMode=proto[PMODE]
        local cacheKey=proto[PCACHEKEY]
        local decodedCache=nil
        -- The entry prototype normally runs once; retaining its decoded form
        -- only helps dumpers and consumes memory. Repeated child callbacks keep
        -- the masked memoization path for performance.
        if INSTRUCTIONCACHE and id~=1 then
            decodedCache=decodedProtoCache[id]
            if not decodedCache then decodedCache={}; decodedProtoCache[id]=decodedCache end
        end
        local cells={}; for slot,cell in pairs(captured) do cells[slot]=cell end
        for i,slot in ipairs(proto[PPARAMS]) do cells[slot]={args[i]} end
        local varargs={n=math.max(0,args.n-#proto[PPARAMS])}
        for i=1,varargs.n do varargs[i]=args[i+#proto[PPARAMS]] end
        args=nil
        local frame={
            FCELLS=cells,FVARARGS=varargs,FSTACK={},FPACKETS={},FTOP=STACKADD,
            FDRIFT=protoKey%DRIFTMOD,FSTATUS=LIVE,FNOISE=protoKey%NOISEMOD,
            FCONSTANTCACHE=localConstantCache,
        }
        frame.position=PCMUL+PCADD+frame.drift
        BUDGETDECL
        while frame.status==LIVE do
            BUDGETSTEP
            local index=(frame.position-frame.drift-PCADD)/PCMUL
            local offset=(index-1)*4
            local cacheBase=index*4
            local opcode,a,b,c
            if decodedCache then
                opcode=decodedCache[cacheBase-3]
                if opcode~=nil then
                    opcode=opcode-cacheKey
                    a=decodedCache[cacheBase-2]-CACHEMASKA
                    b=decodedCache[cacheBase-1]-CACHEMASKB
                    c=decodedCache[cacheBase]-CACHEMASKC
                end
            end
            if opcode==nil then
                local key,cipher
                if decodeMode==1 then
                    key=(protoKey+index*STRIDE+SALT)%CIPHERMOD
                    key=(key*CIPHERMUL1+IADD11)%CIPHERMOD; cipher=stream[offset+1]; opcode=(cipher-key)%CIPHERMOD; key=(key+cipher)%CIPHERMOD
                    key=(key*CIPHERMUL1+IADD12)%CIPHERMOD; cipher=stream[offset+2]; a=(cipher-key)%CIPHERMOD; key=(key+cipher)%CIPHERMOD
                    key=(key*CIPHERMUL1+IADD13)%CIPHERMOD; cipher=stream[offset+3]; b=(cipher-key)%CIPHERMOD; key=(key+cipher)%CIPHERMOD
                    key=(key*CIPHERMUL1+IADD14)%CIPHERMOD; cipher=stream[offset+4]; c=(cipher-key)%CIPHERMOD
                elseif decodeMode==2 then
                    key=(protoKey*3+index*STRIDE+SALT)%CIPHERMOD
                    key=(key*CIPHERMUL2+IADD21+index)%CIPHERMOD; cipher=stream[offset+1]; opcode=(cipher-key-protoKey)%CIPHERMOD; key=(key+cipher*3+1)%CIPHERMOD
                    key=(key*CIPHERMUL2+IADD22+index)%CIPHERMOD; cipher=stream[offset+2]; a=(cipher-key-2*protoKey)%CIPHERMOD; key=(key+cipher*3+2)%CIPHERMOD
                    key=(key*CIPHERMUL2+IADD23+index)%CIPHERMOD; cipher=stream[offset+3]; b=(cipher-key-3*protoKey)%CIPHERMOD; key=(key+cipher*3+3)%CIPHERMOD
                    key=(key*CIPHERMUL2+IADD24+index)%CIPHERMOD; cipher=stream[offset+4]; c=(cipher-key-4*protoKey)%CIPHERMOD
                else
                    key=(protoKey+index*STRIDE*3+SALT)%CIPHERMOD
                    key=(key*CIPHERMUL3+IADD31+protoKey)%CIPHERMOD; cipher=stream[offset+1]; opcode=(cipher-key-index)%CIPHERMOD; key=(key+cipher+7)%CIPHERMOD
                    key=(key*CIPHERMUL3+IADD32+protoKey)%CIPHERMOD; cipher=stream[offset+2]; a=(cipher-key-index*2)%CIPHERMOD; key=(key+cipher+14)%CIPHERMOD
                    key=(key*CIPHERMUL3+IADD33+protoKey)%CIPHERMOD; cipher=stream[offset+3]; b=(cipher-key-index*3)%CIPHERMOD; key=(key+cipher+21)%CIPHERMOD
                    key=(key*CIPHERMUL3+IADD34+protoKey)%CIPHERMOD; cipher=stream[offset+4]; c=(cipher-key-index*4)%CIPHERMOD
                end
                if decodedCache then
                    decodedCache[cacheBase-3]=opcode+cacheKey
                    decodedCache[cacheBase-2]=a+CACHEMASKA
                    decodedCache[cacheBase-1]=b+CACHEMASKB
                    decodedCache[cacheBase]=c+CACHEMASKC
                end
            end
            frame.drift=(frame.drift+stream[offset+1])%DRIFTMOD
            frame.position=(index+1)*PCMUL+PCADD+frame.drift
            local handler=dispatch[opcode]
            if not handler then error(ERRORINSTRUCTION,0) end
            handler(frame,a,b,c)
        end
        local finalStatus, finalResult, finalTailFunction, finalTailArgs = frame.status, frame.result, frame.tailFunction, frame.tailArgs
        if localConstantCache then
            for _,bucket in pairs(localConstantCache) do for k in pairs(bucket) do bucket[k]=nil end end
            for k in pairs(localConstantCache) do localConstantCache[k]=nil end
        end
        if finalStatus==TAIL then return finalTailFunction(unpackValues(finalTailArgs,1,finalTailArgs.n)) end
        return unpackValues(finalResult,1,finalResult.n)
    end
    return run(1,{},pack(...))
end)(getfenv and getfenv() or _ENV or _G,...)
]=]
    local guardChar1,guardChar2=math.random(65,90),math.random(65,90)
    local guardPart1,guardPart2=string.char(math.random(97,122)),string.char(math.random(97,122))
    local traceHelpers,startGuard,traceDecl,traceStep="","","",""
    if traceGuardEvery>0 then
        local guardText=string.format("%q",string.char(guardChar1,guardChar2))
        local part1,part2=string.format("%q",guardPart1),string.format("%q",guardPart2)
        local joined=string.format("%q",guardPart1..guardPart2)
        local traceError=string.format("%q",tostring(rand())..tostring(rand()))
        traceHelpers="local guardString,guardTable,guardType,guardSelect,guardPcall=string,table,type,select,pcall;"..
            "local function traceGuard() local ok,good=guardPcall(function() return guardType(prototypes)=='table' and guardType(pool)=='table' "..
            "and guardSelect('#',1,nil,false)==3 and guardString.char("..guardChar1..","..guardChar2..") == "..guardText..
            " and guardTable.concat({"..part1..","..part2.."},'') == "..joined.." and "..guardSalt.."+1>"..guardSalt.." end);"..
            "if not ok or good~=true then error("..traceError..",0) end return true end;"
        startGuard="traceGuard()"
        traceDecl="local guardBudget=0;"
        traceStep="guardBudget=guardBudget+1;if guardBudget>="..traceGuardEvery.." then guardBudget=0;traceGuard() end;"
    end
    local yieldHelpers,yieldDecl,yieldStep="","",""
    if yieldEvery>0 then
        yieldHelpers=[[local taskApi=(env and rawget(env,'task')) or task
            local waitFunc=type(taskApi)=='table' and taskApi.wait or nil
            local coApi=(env and rawget(env,'coroutine')) or coroutine
            local isYieldable=type(coApi)=='table' and coApi.isyieldable or nil
            local yieldDisabled=false
            local function safeYield()
                if not waitFunc or yieldDisabled then return end
                if isYieldable and not isYieldable() then return end
                local ok=pcall(waitFunc); if not ok then yieldDisabled=true end
            end]]
        yieldDecl="local vmBudget=0;local clockFunc=(os and os.clock) or nil;local lastYieldAt=clockFunc and clockFunc() or 0;"
        yieldStep="vmBudget=vmBudget+1;if vmBudget>="..yieldEvery.." then vmBudget=0;"..
            (yieldInterval<=0 and "safeYield();" or "if clockFunc then local now=clockFunc();if now-lastYieldAt>="..yieldInterval.." then lastYieldAt=now;safeYield() end else safeYield() end;").."end;"
    end
    local replacements={PROTOTYPES=array(serialized),CONSTANTS=array(encrypted),STRIDE=stride,SALT=salt,
        PCMUL=pcMul,PCADD=pcAdd,STACKMUL=stackMul,STACKADD=stackAdd,LIVE=stateLive,DONE=stateDone,TAIL=stateTail,
        YIELDEVERY=yieldEvery,YIELDINTERVAL=yieldInterval,FRAMECONSTANTCACHE=tostring(frameConstantCache),
        INTEGRITYSTEP=integrityStep,VERIFYONCE=tostring(verifyOnce),INSTRUCTIONCACHE=tostring(instructionCache),
        TRACEGUARDEVERY=traceGuardEvery,GUARDSALT=guardSalt,HANDLERS=table.concat(emittedHandlers,"\n"),
        CIPHERMOD=cipherMod,CIPHERMUL1=cipherMuls[1],CIPHERMUL2=cipherMuls[2],CIPHERMUL3=cipherMuls[3],
        IADD11=roundAdds[1][1],IADD12=roundAdds[1][2],IADD13=roundAdds[1][3],IADD14=roundAdds[1][4],
        IADD21=roundAdds[2][1],IADD22=roundAdds[2][2],IADD23=roundAdds[2][3],IADD24=roundAdds[2][4],
        IADD31=roundAdds[3][1],IADD32=roundAdds[3][2],IADD33=roundAdds[3][3],IADD34=roundAdds[3][4],
        CONSTMOD=constMod,CONSTMUL1=constMuls[1],CONSTMUL2=constMuls[2],CONSTMUL3=constMuls[3],
        CONSTADD1=constAdds[1],CONSTADD2=constAdds[2],CONSTADD3=constAdds[3],CONSTSTRIDE=constStride,CONSTSALT=constSalt,
        DIGESTMOD=digestMod,DIGESTMUL=digestMul,DIGESTLENMIX=digestLenMix,DIGESTKEYMIX=digestKeyMix,
        DIGESTSALTMIX=digestSaltMix,DIGESTINDEXMIX=digestIndexMix,CONSTDIGESTMUL=constDigestMul,CONSTDIGESTINDEXMIX=constDigestIndexMix,
        DIGESTMASKMUL=digestMaskMul,CONSTDIGESTMASKMUL=constDigestMaskMul,
        DISPATCHSEALMIX=dispatchSealMix,DISPATCHSEALREMAINDERMIX=dispatchSealRemainderMix,DISPATCHSEAL=dispatchSeal,
        PSTREAM=pStream,PKEY=pKey,PPARAMS=pParams,PCAPTURES=pCaptures,PDIGEST=pDigest,PMODE=pMode,PCACHEKEY=pCacheKey,
        CMODE=cMode,CKEY=cKey,CBYTES=cBytes,CDIGEST=cDigest,DRIFTMOD=driftMod,NOISEMOD=noiseMod,
        HANDLERCOUNT=#emittedHandlers,
         CONSTCACHESLOTS=constantCacheSlots,CONSTCACHEMUL=constantCacheMul,
         CACHEMASKA=cacheMaskA,CACHEMASKB=cacheMaskB,CACHEMASKC=cacheMaskC,
        TRACEHELPERS=traceHelpers,YIELDHELPERS=yieldHelpers,STARTGUARD=startGuard,BUDGETDECL=yieldDecl..traceDecl,BUDGETSTEP=yieldStep..traceStep,
        ERRORBYTECODE=string.format("%q",tostring(rand())..tostring(rand())),
        ERRORCONSTANT=string.format("%q",tostring(rand())..tostring(rand())),
        ERRORDISPATCH=string.format("%q",tostring(rand())..tostring(rand())),
        ERRORINSTRUCTION=string.format("%q",tostring(rand())..tostring(rand())),
        FCELLS=frameAliases.cells,FVARARGS=frameAliases.varargs,FSTACK=frameAliases.stack,
        FPACKETS=frameAliases.packets,FTOP=frameAliases.top,FDRIFT=frameAliases.drift,
        FSTATUS=frameAliases.status,FNOISE=frameAliases.noise,FCONSTANTCACHE=frameAliases.constantCache}
    -- One substitution pass, including DONE/TAIL in inserted handler source.
    replacements.HANDLERS=replacements.HANDLERS:gsub("DONE",tostring(stateDone))
    replacements.HANDLERS=replacements.HANDLERS:gsub("TAIL",tostring(stateTail))
    replacements.HANDLERS=replacements.HANDLERS:gsub("PCAPTURES",tostring(pCaptures))
    runtime=runtime:gsub("%u[%u%d_]+",function(token) return tostring(replacements[token] or token) end)
    for _,field in ipairs(frameFields) do
        local alias=frameAliases[field]
        runtime=runtime:gsub("%."..field.."%f[^%w_]","."..alias)
    end
    return runtime
end
return R
