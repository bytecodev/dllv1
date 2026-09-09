const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {spawnSync}=require('node:child_process');
const {runPrometheus}=require('../src/prometheus');

const root=path.resolve(__dirname,'..');
const fixture=path.join(__dirname,'fixtures','typed.luau');
const results=path.join(root,'test-results','typed');
const luau=process.env.LUAU_BIN || path.join(root,'test-results','tools','luau','luau.exe');
fs.mkdirSync(results,{recursive:true});

function execute(code,name) {
  const file=path.join(results,name+'.luau');
  fs.writeFileSync(file,code);
  const run=spawnSync(luau,[file],{encoding:'utf8',timeout:30000,maxBuffer:4*1024*1024});
  assert.ifError(run.error);
  assert.equal(run.status,0,run.stdout+'\n'+run.stderr);
  return run.stdout;
}

test('typed Luau aliases/functions, annotations, casts, generics, and packs are erased safely',{
  skip:!fs.existsSync(luau)?'Luau runner unavailable':false,
},async()=>{
  const source=fs.readFileSync(fixture,'utf8');
  const baseline=execute(source,'source');
  assert.match(baseline,/TYPED_CORPUS_OK/);
  for(const seed of [5,42,991]) {
    const result=await runPrometheus({source,filename:'typed.luau',preset:'Medium',luaVersion:'LuaU',seed});
    assert(result.ok,result.error);
    assert.match(result.output,/0x[0-9A-F]+/,'Medium should mix hexadecimal integer literals into its VM output');
    assert.equal(execute(result.output,'medium.'+seed),baseline,'seed '+seed);
    for(const marker of ['ErasedTypeFunction_219','ErasedResult_481','ErasedCallback_927','ErasedOverload_315','ErasedOrigin_746','ErasedAccess_394']) {
      assert(!result.output.includes(marker),'type-only identifier leaked: '+marker);
    }
  }
});

test('type aliases remain contextual and ordinary variables named type/export still work',{
  skip:!fs.existsSync(luau)?'Luau runner unavailable':false,
},async()=>{
  const source=`
    local type=3
    type=type+2
    local export=function(value) return value*2 end
    local typeof=function(value) return value+1 end
    type ErasedContextual_556 = number
    export type ErasedExported_557 = {value:number}
    print('CONTEXTUAL_OK',type,export(typeof(type)))
  `;
  const result=await runPrometheus({source,filename:'contextual.luau',preset:'Medium',luaVersion:'LuaU',seed:77});
  assert(result.ok,result.error);
  assert.equal(execute(result.output,'contextual.medium'),execute(source,'contextual.source'));
  assert(!result.output.includes('ErasedContextual_556'));
  assert(!result.output.includes('ErasedExported_557'));
});
