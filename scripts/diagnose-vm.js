// Reproduce the supplied script's startup cost using deterministic getgc fixtures.
// This measures Luau CLI work, not executor behavior or an actual client crash.
const fs=require('node:fs');
const path=require('node:path');
const {spawnSync}=require('node:child_process');
const {createHash}=require('node:crypto');
const assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..');
const results=path.join(root,'test-results');
const before=path.join(results,'performance-before');
const baselineOutput=fs.readFileSync(path.join(before,'04_stealanegg.medium.lua'),'utf8');
const output=fs.readFileSync(path.join(results,'04_stealanegg.medium.optimized.lua'),'utf8');
const metadata=JSON.parse(fs.readFileSync(path.join(before,'04_stealanegg.build.json'),'utf8'));
const optimizedMetadata=JSON.parse(fs.readFileSync(path.join(results,'04_stealanegg.optimized.build.json'),'utf8'));
const hash=value=>createHash('sha256').update(value).digest('hex');
assert.equal(hash(baselineOutput),metadata.outputSha256,'baseline output must match its build metadata');
assert.equal(hash(output),optimizedMetadata.outputSha256,'optimized output must match its build metadata');
let source;
const sourcePath=path.join(root,'04_stealanegg.lua');
if(fs.existsSync(sourcePath)) source=fs.readFileSync(sourcePath,'utf8');
else {
  // The user's original can be moved after delivery. Read the exact saved source
  // from the earlier test artifact without restoring/modifying their input file.
  const saved=fs.readFileSync(path.join(results,'04.source.startup.false.luau'),'utf8');
  const marker='local function main(...)\n';
  const start=saved.indexOf(marker),end=saved.lastIndexOf('\nend\nmain()\n__auditFinish()');
  assert(start>=0 && end>start,'source artifact boundaries missing');
  source=saved.slice(start+marker.length,end);
}
assert.equal(hash(source),metadata.sourceSha256,'source must match the output build');
const host=fs.readFileSync(path.join(root,'test/fixtures/stealanegg-startup-host.lua'),'utf8');
const runner=process.env.LUAU_BIN || path.join(results,'tools/luau/luau.exe');
const measurements=[];
for(const count of [0,1000,5000]) {
  for(const [variant,code] of [['source',source],['baseline',baselineOutput],['optimized',output]]) {
    const fixture=`
local objects={}
for i=1,${count} do
 local item={value=1}
 for j=1,12 do item['field'..j]=j+10 end
 if i%10==0 then item.self=item end
 objects[i]=item
end
getgc=function() return objects end
getrawmetatable=getmetatable
local startMemory=collectgarbage('count')
local startTime=os.clock()
local function main(...)
${code}
end
main()
local elapsed=os.clock()-startTime
local memoryDelta=collectgarbage('count')-startMemory
__auditFinish()
print('VM_DIAGNOSTIC '..elapsed..' '..memoryDelta)
`;
    const file=path.join(results,`diagnostic.${variant}.${count}.luau`);
    fs.writeFileSync(file,'__MOCK_HTTP=false\n'+host+'\n'+fixture);
    const started=Date.now();
    const run=spawnSync(runner,[file],{encoding:'utf8',timeout:30000,maxBuffer:1024*1024});
    fs.writeFileSync(file+'.log',(run.stdout||'')+'\n'+(run.stderr||''));
    const row={variant,tables:count,wallMs:Date.now()-started,exit:run.status,error:run.error?.message||null};
    const metrics=run.stdout?.match(/VM_DIAGNOSTIC ([\d.e+-]+) ([\d.e+-]+)/);
    if(metrics) {row.startupMs=Number(metrics[1])*1000;row.heapDeltaKB=Number(metrics[2]);}
    measurements.push(row);console.log(JSON.stringify(row));
    fs.writeFileSync(path.join(results,'vm-diagnostic.json'),JSON.stringify({
      sourceSha256:metadata.sourceSha256,baselineOutputSha256:metadata.outputSha256,optimizedOutputSha256:optimizedMetadata.outputSha256,
      note:'Synthetic getgc workload; heap is an end-of-startup delta, not peak memory; CLI wall time includes parsing/compilation.',
      measurements,
    },null,2));
    if(run.error || run.status!==0) {process.exitCode=1; console.error(run.stderr);break;}
  }
}
