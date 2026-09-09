// Rebuild the exact previously audited target without overwriting user input or
// the baseline artifact. The source artifact hash must match build metadata.
const fs=require('node:fs');
const path=require('node:path');
const {createHash}=require('node:crypto');
const {runPrometheus}=require('../src/prometheus');
const root=path.resolve(__dirname,'..');
const results=path.join(root,'test-results');
const metadata=JSON.parse(fs.readFileSync(path.join(results,'04_stealanegg.build.json'),'utf8'));
const hash=value=>createHash('sha256').update(value).digest('hex');
function source() {
  const direct=path.join(root,'04_stealanegg.lua');
  if(fs.existsSync(direct)) return fs.readFileSync(direct,'utf8');
  const saved=fs.readFileSync(path.join(results,'04.source.startup.false.luau'),'utf8');
  const marker='local function main(...)\n';
  const start=saved.indexOf(marker),end=saved.lastIndexOf('\nend\nmain()\n__auditFinish()');
  if(start<0 || end<=start) throw new Error('source artifact boundaries missing');
  return saved.slice(start+marker.length,end);
}
(async()=>{
  const input=source();
  if(hash(input)!==metadata.sourceSha256) throw new Error('source hash differs from audited target');
  const started=Date.now();
  const result=await runPrometheus({source:input,filename:'04_stealanegg.lua',preset:'Medium',luaVersion:'LuaU',seed:42});
  if(!result.ok) throw new Error(result.error);
  const outputPath=path.join(results,'04_stealanegg.medium.optimized.lua');
  fs.writeFileSync(outputPath,result.output);
  const next={sourceBytes:Buffer.byteLength(input),sourceSha256:hash(input),outputBytes:Buffer.byteLength(result.output),
    outputSha256:hash(result.output),preset:'Medium',luaVersion:'LuaU',seed:42,buildMs:Date.now()-started};
  fs.writeFileSync(path.join(results,'04_stealanegg.optimized.build.json'),JSON.stringify(next,null,2));
  console.log(JSON.stringify(next));
})().catch(error=>{console.error(error.stack||error.message);process.exitCode=1});
