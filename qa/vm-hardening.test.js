const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {spawnSync}=require('node:child_process');
const {runPrometheus}=require('../src/prometheus');
const compilerEngine=require('../test/helpers/compiler-engine');

const root=path.resolve(__dirname,'..');
const results=path.join(root,'test-results','hardening');
const luau=process.env.LUAU_BIN || path.join(root,'test-results','tools','luau','luau.exe');
fs.mkdirSync(results,{recursive:true});

function run(code,name) {
  const file=path.join(results,name+'.luau');
  fs.writeFileSync(file,code);
  return spawnSync(luau,[file],{encoding:'utf8',timeout:30000,maxBuffer:4*1024*1024});
}

function mutateLargestNumericArray(code) {
  const number='(?:0x[0-9A-F]+|\\d+)';
  const arrays=[...code.matchAll(new RegExp('\\{'+number+'(?:[;,]'+number+'){7,}\\}','g'))];
  assert(arrays.length>0,'encrypted numeric array not found');
  arrays.sort((a,b)=>b[0].length-a[0].length);
  const selected=arrays[0];
  const tokens=[...selected[0].matchAll(new RegExp(number,'g'))];
  const token=tokens[tokens.length-1];
  const value=token[0].startsWith('0x')?parseInt(token[0].slice(2),16):Number(token[0]);
  const replacement=String(value+1);
  const absolute=selected.index+token.index;
  return code.slice(0,absolute)+replacement+code.slice(absolute+token[0].length);
}

function mutateDispatchKey(code) {
  const match=code.match(/\[(0x[0-9A-F]+|\d+)\]=function\(/);
  assert(match,'numeric dispatch handler not found');
  const value=match[1].startsWith('0x')?parseInt(match[1].slice(2),16):Number(match[1]);
  return code.slice(0,match.index+1)+String(value+1)+code.slice(match.index+1+match[1].length);
}

test('Medium randomizes cipher fingerprints and remains reproducible per seed',{
  skip:!fs.existsSync(luau)?'Luau runner unavailable':false,
},async()=>{
  const source="local x=7; for i=1,40 do x=(x*3+i)%1009 end; print('HARDENED_OK',x)";
  const a=await runPrometheus({source,preset:'Medium',luaVersion:'LuaU',seed:301});
  const repeat=await runPrometheus({source,preset:'Medium',luaVersion:'LuaU',seed:301});
  const b=await runPrometheus({source,preset:'Medium',luaVersion:'LuaU',seed:302});
  assert(a.ok,a.error); assert(repeat.ok,repeat.error); assert(b.ok,b.error);
  assert.equal(a.output,repeat.output);
  assert.notEqual(a.output,b.output);
  for(const output of [a.output,b.output]) {
    assert(!/(^|[^\d])48271([^\d]|$)/.test(output),'fixed legacy instruction multiplier leaked');
    assert(!/(^|[^\d])2147483647([^\d]|$)/.test(output),'fixed legacy modulus leaked');
    assert(!/(^|[^\d])65521([^\d]|$)/.test(output),'fixed legacy VM state modulus leaked');
    for(const field of ['cells','varargs','position','drift','result','status','tailFunction','tailArgs','noise','stack','packets','top','constantCache']) {
      assert(!new RegExp(`\\.${field}\\b`).test(output),`stable VM frame field leaked: ${field}`);
    }
    const execution=run(output,'randomized-'+output.length);
    assert.ifError(execution.error); assert.equal(execution.status,0,execution.stderr);
    assert.match(execution.stdout,/HARDENED_OK/);
  }
});

test('instruction-stream integrity rejects a modified encrypted word',{
  skip:!fs.existsSync(luau)?'Luau runner unavailable':false,
},async()=>{
  const lines=['local x=1'];
  for(let i=1;i<=120;i++) lines.push(`x=(x*3+${i})%1000003`);
  lines.push("print('STREAM_OK',x)");
  const built=await runPrometheus({source:lines.join('\n'),preset:'Medium',luaVersion:'LuaU',seed:410});
  assert(built.ok,built.error);
  const execution=run(mutateLargestNumericArray(built.output),'tampered-stream');
  assert.ifError(execution.error);
  assert.notEqual(execution.status,0,'tampered instruction stream executed successfully');
});

test('lazy constant integrity rejects a modified encrypted byte',{
  skip:!fs.existsSync(luau)?'Luau runner unavailable':false,
},async()=>{
  const secret='K'.repeat(700);
  const built=await runPrometheus({source:`print('${secret}')`,preset:'Medium',luaVersion:'LuaU',seed:511});
  assert(built.ok,built.error);
  const execution=run(mutateLargestNumericArray(built.output),'tampered-constant');
  assert.ifError(execution.error);
  assert.notEqual(execution.status,0,'tampered constant pool executed successfully');
});

test('dispatch seal rejects a modified opcode key',{
  skip:!fs.existsSync(luau)?'Luau runner unavailable':false,
},async()=>{
  const built=await runPrometheus({source:"print('DISPATCH_OK')",preset:'Medium',luaVersion:'LuaU',seed:577});
  assert(built.ok,built.error);
  const execution=run(mutateDispatchKey(built.output),'tampered-dispatch');
  assert.ifError(execution.error);
  assert.notEqual(execution.status,0,'tampered dispatch executed successfully');
});

test('optional scheduler and periodic guard paths remain valid Luau',{
  skip:!fs.existsSync(luau)?'Luau runner unavailable':false,
},async()=>{
  const engine=await compilerEngine();
  let output;
  try {
    output=await engine.doString(`
      local Pipeline=require('prometheus.pipeline')
      local config={LuaVersion='LuaU',Seed=612,PrettyPrint=false,NameGenerator='MangledShuffled',Steps={{
        Name='Vmify',Settings={YieldEvery=3,YieldInterval=0,TraceGuardEvery=2,IntegrityStep=17,ConstantCacheSlots=8}
      }}}
      return Pipeline:fromConfig(config):apply("print('OPTIONAL_GUARD_OK')",'optional.luau')
    `);
  } finally {
    engine.global.close();
  }
  const execution=run(output,'optional-guards');
  assert.ifError(execution.error); assert.equal(execution.status,0,execution.stderr);
  assert.match(execution.stdout,/OPTIONAL_GUARD_OK/);
});
