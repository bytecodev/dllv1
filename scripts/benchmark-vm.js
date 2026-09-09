// General VM startup benchmark. It deliberately has no dependency on a user script.
const fs=require('node:fs');
const path=require('node:path');
const {spawnSync}=require('node:child_process');
const {runPrometheus}=require('../src/prometheus');

const root=path.resolve(__dirname,'..');
const results=path.join(root,'test-results','general-benchmark');
const luau=process.env.LUAU_BIN || path.join(root,'test-results','tools','luau','luau.exe');
const iterations=Math.max(1,Number(process.env.VM_BENCH_ITERATIONS)||5000);
const source=`
local function inspect(object)
  local total=0
  for key,value in pairs(object) do
    if type(key)=='string' and type(value)=='number' then total+=value end
  end
  return total
end
local total=0
for i=1,${iterations} do
  total+=inspect({alpha=i,beta=i+1,gamma=i+2,delta=i+3})
end
print('BENCH_OK',total)
`;

function execute(code,name) {
  const file=path.join(results,name+'.luau');
  const wrapped=`local started=os.clock()\nlocal function benchmarkChunk(...)\n${code}\nend\nbenchmarkChunk()\nprint('BENCH_TIME',os.clock()-started)`;
  fs.writeFileSync(file,wrapped);
  const wall=Date.now();
  const run=spawnSync(luau,[file],{encoding:'utf8',timeout:30000,maxBuffer:4*1024*1024});
  if(run.error) throw run.error;
  if(run.status!==0) throw new Error(run.stdout+'\n'+run.stderr);
  const match=run.stdout.match(/BENCH_TIME\s+([\d.e+-]+)/);
  return {name,vmMs:match?Number(match[1])*1000:null,wallMs:Date.now()-wall,stdout:run.stdout.match(/BENCH_OK[^\r\n]*/)?.[0]};
}

(async()=>{
  if(!fs.existsSync(luau)) throw new Error('Luau runner unavailable: '+luau);
  fs.mkdirSync(results,{recursive:true});
  const built=await runPrometheus({source,filename:'general-benchmark.luau',preset:'Medium',luaVersion:'LuaU',seed:42});
  if(!built.ok) throw new Error(built.error);
  const baseline=execute(source,'source');
  const medium=execute(built.output,'medium');
  if(baseline.stdout!==medium.stdout) throw new Error('benchmark output mismatch');
  const report={iterations,sourceBytes:Buffer.byteLength(source),outputBytes:Buffer.byteLength(built.output),baseline,medium};
  fs.writeFileSync(path.join(results,'report.json'),JSON.stringify(report,null,2));
  console.log(JSON.stringify(report));
})().catch(error=>{console.error(error.stack||error.message);process.exitCode=1});
