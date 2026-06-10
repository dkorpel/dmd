import { readFileSync } from 'fs';
const bytes = readFileSync('web/dmd.wasm');
let memory, stdoutText = "", stderrText = "";
const td = new TextDecoder(), te = new TextEncoder();
const dv = () => new DataView(memory.buffer);
const wasi = new Proxy({
  fd_write: (fd, iovs, n, nw) => { const v=dv(); let w=0,s="";
    for(let i=0;i<n;i++){const p=v.getUint32(iovs+i*8,true),l=v.getUint32(iovs+i*8+4,true);
      s+=td.decode(new Uint8Array(memory.buffer,p,l));w+=l;}
    if (fd===1) stdoutText+=s; else stderrText+=s; v.setUint32(nw,w,true); return 0; },
  environ_sizes_get: (c,s)=>{dv().setUint32(c,0,true);dv().setUint32(s,0,true);return 0;},
  environ_get: ()=>0, clock_time_get:(a,b,p)=>{dv().setBigUint64(p,0n,true);return 0;}, proc_exit:(c)=>{throw new Error("exit "+c);}
}, { get:(t,k)=> k in t ? t[k] : (()=>8) });
const { instance } = await WebAssembly.instantiate(bytes, { wasi_snapshot_preview1: wasi, env:{} });
const ex = instance.exports; memory = ex.memory;
ex.__wasm_call_ctors();
function compile(src){ stdoutText=""; stderrText="";
  const b=te.encode(src); const ptr=ex.dmdwasm_input_buffer(b.length+1);
  new Uint8Array(memory.buffer,ptr,b.length).set(b);
  ex.dmdwasm_run(ptr,b.length);
  const ast=td.decode(new Uint8Array(memory.buffer,ex.dmdwasm_ast_ptr(),ex.dmdwasm_ast_len()));
  return {ast, asm:stdoutText, errors:ex.dmdwasm_errors(), diag:stderrText}; }
const r = compile("module web;\nstruct Point { int x, y; }\nint dot(Point a, Point b) => a.x*b.x + a.y*b.y;\n");
console.log("errors:", r.errors, "diag:", r.diag||"(none)");
console.log("=== AST ===\n" + r.ast);
console.log("=== ASM (-vasm) ===\n" + r.asm);
