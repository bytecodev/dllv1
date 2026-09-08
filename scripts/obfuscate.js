const fs=require('node:fs');
const path=require('node:path');
const {runPrometheus}=require('../src/prometheus');

async function main() {
  const [input,output,seed]=process.argv.slice(2);
  if(!input || !output) throw new Error('Usage: node scripts/obfuscate.js input.lua output.lua [seed]');
  if(path.resolve(input)===path.resolve(output)) throw new Error('Output must differ from the input file');
  const result=await runPrometheus({
    source:fs.readFileSync(input,'utf8'), filename:path.basename(input),
    ...(seed===undefined?{}:{seed:Number(seed)}),
  });
  if(!result.ok) throw new Error(result.error);
  fs.writeFileSync(output,result.output,{flag:'wx'});
  console.log(`Medium + LuaU: ${Buffer.byteLength(result.output)} bytes -> ${output}`);
}
main().catch(error=>{console.error(error.message);process.exitCode=1;});
