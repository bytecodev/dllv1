const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {spawnSync}=require('node:child_process');
const {runPrometheus}=require('../src/prometheus');

const root=path.resolve(__dirname,'..');
const results=path.join(root,'test-results','corpus');
const luau=process.env.LUAU_BIN || path.join(root,'test-results','tools','luau','luau.exe');
const forbidden=['game:GetService','ReplicatedStorage','HttpGet','RemoteEvent','RemoteFunction','AskWearStill','CodexUI'];
fs.mkdirSync(results,{recursive:true});

function execute(source,name) {
  const file=path.join(results,name+'.luau');
  fs.writeFileSync(file,"debug=nil\nsetfenv=function() error('setfenv forbidden',0) end\n"+source);
  const run=spawnSync(luau,[file],{encoding:'utf8',timeout:30000,maxBuffer:4*1024*1024});
  assert.ifError(run.error);
  assert.equal(run.status,0,run.stdout+'\n'+run.stderr);
  return run.stdout;
}

const corpus=[
  ['control',`
    local sum=0
    for i=1,20 do if i%4==0 then continue end sum+=i end
    local n=0; while n<4 do n+=1; sum-=n end
    repeat sum+=2; n-=1 until n==0
    print('CORPUS_control',sum,if sum>0 then 'positive' else 'negative')
  `],
  ['multivalue',`
    local function values() return 7,nil,11 end
    local a,b,c=values(); local one=(values()); local packed={values()}
    local function count(...) return select('#',...),... end
    print('CORPUS_multivalue',a,b==nil,c,one,#packed,count(values()))
  `],
  ['closures',`
    local function factory(start)
      local value=start
      local function add(step) value+=step; return value end
      return add
    end
    local a,b=factory(3),factory(20)
    local function tail(n,total) if n==0 then return total end return tail(n-1,total+n) end
    print('CORPUS_closures',a(2),a(4),b(-3),tail(350,0))
  `],
  ['coroutines',`
    local thread=coroutine.create(function(value)
      local resumed=coroutine.yield(value+1,nil)
      return resumed*2,nil
    end)
    local a,b,c=coroutine.resume(thread,9)
    local d,e,f=coroutine.resume(thread,12)
    print('CORPUS_coroutines',a,b,c==nil,d,e,f==nil,coroutine.status(thread))
  `],
  ['metatables',`
    local writes={}
    local object=setmetatable({base=4},{
      __index=function(_,key) return #key end,
      __newindex=function(_,key,value) writes[key]=value end,
      __call=function(self,value) return self.base+value end,
      __len=function() return 27 end,
      __iter=function(self) return next,{a=self.base,b=6},nil end,
    })
    object.extra=8
    local total=0; for _,value in object do total+=value end
    print('CORPUS_metatables',object.missing,writes.extra,object(5),#object,total)
  `],
  ['errors',`
    local function guarded(value)
      local ok,result=pcall(function() if value<0 then error('expected failure') end return value*3 end)
      return ok,ok and result or string.find(result,'expected failure',1,true)~=nil
    end
    print('CORPUS_errors',guarded(4)); print('CORPUS_errors_negative',guarded(-1))
  `],
  ['roblox_shape',`
    local calls={}; local methods={}
    function methods:WaitForChild(name) calls[#calls+1]='wait:'..name; return self.children[name] end
    function methods:FireServer(value) calls[#calls+1]='fire:'..value end
    local remote=setmetatable({children={}}, {__index=methods})
    local storage=setmetatable({children={RemoteEvent=remote}}, {__index=methods})
    game={GetService=function(self,name) assert(self==game); calls[#calls+1]='service:'..name; return storage end}
    typeof=function(value) return type(value)=='table' and 'Instance' or type(value) end
    local selected=game:GetService('ReplicatedStorage'):WaitForChild('RemoteEvent')
    selected:FireServer('payload')
    print('CORPUS_roblox_shape',typeof(selected),table.concat(calls,','))
  `],
  ['hot_callbacks',`
    local function score(object)
      local total=0
      for _,value in pairs(object) do if type(value)=='number' then total+=value end end
      return total
    end
    local total=0
    for i=1,2000 do total+=score({i,i+1,i+2,i+3}) end
    print('CORPUS_hot_callbacks',total)
  `],
];

test('general Luau corpus preserves behavior across randomized Medium builds',{
  skip:!fs.existsSync(luau)?'Luau runner unavailable':false,
},async()=>{
  const manifest=[];
  for(const [name,source] of corpus) {
    const baseline=execute(source,name+'.source');
    for(const seed of [13,907]) {
      const result=await runPrometheus({source,filename:name+'.luau',preset:'Medium',luaVersion:'LuaU',seed});
      assert(result.ok,result.error);
      assert.equal(execute(result.output,`${name}.medium.${seed}`),baseline,`${name}, seed ${seed}`);
      assert(!result.output.includes('CORPUS_'+name),name+' plaintext marker');
      assert(!/base(?:64|85)/i.test(result.output),name+' outer text encoding');
      if(name==='roblox_shape') for(const word of forbidden) assert(!result.output.includes(word),word);
      manifest.push({name,seed,sourceBytes:Buffer.byteLength(source),outputBytes:Buffer.byteLength(result.output)});
    }
  }
  fs.writeFileSync(path.join(results,'manifest.json'),JSON.stringify(manifest,null,2));
});

test('deterministic generated-program matrix preserves arithmetic and branch behavior',{
  skip:!fs.existsSync(luau)?'Luau runner unavailable':false,
},async()=>{
  for(let caseId=1;caseId<=8;caseId++) {
    let state=caseId*7919;
    const lines=[`local x=${caseId}`,`local function step(v,n)`];
    for(let i=1;i<=24;i++) {
      state=(state*48271)%2147483647;
      const value=state%31+1;
      if(i%3===0) lines.push(`if n%${(value%7)+2}==0 then v+=${value} else v-=${value%11} end`);
      else lines.push(`v=(v*${(value%5)+1}+${value})%1000003`);
    }
    lines.push('return v end','for i=1,80 do x=step(x,i) end',`print('GENERATED_${caseId}',x)`);
    const source=lines.join('\n');
    const result=await runPrometheus({source,filename:`generated-${caseId}.luau`,preset:'Medium',luaVersion:'LuaU',seed:caseId*101});
    assert(result.ok,result.error);
    assert.equal(execute(result.output,`generated.${caseId}.medium`),execute(source,`generated.${caseId}.source`));
    assert(!result.output.includes('GENERATED_'+caseId));
  }
});
