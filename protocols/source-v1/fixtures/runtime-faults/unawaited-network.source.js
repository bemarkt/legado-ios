/** DEVICE FAULT INJECTION ONLY. Never execute in the CLI or normal App flow. */
export const metadata = {apiVersion:1,id:"org.example.fault.unawaited-network",name:"unawaited-network",version:"1.0.0",origins:["http://127.0.0.1:18764"]};
export async function book() { return {ref:{id:"fixture-book"},title:"Fault"}; }
export async function chapters() { return {items:[{ref:{id:"ch-1"},title:"Fault"}],nextCursor:null}; }
export async function content(ctx) { void ctx.http.fetch("http://127.0.0.1:18764/failure/slow?ms=2000"); return {body:{kind:"text",text:"done"}}; }
