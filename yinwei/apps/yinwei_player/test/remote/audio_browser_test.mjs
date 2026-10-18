import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';

const clientSource = await readFile('assets/remote/audio-client.js','utf8');
const {decodeAudioPacket, BrowserAudio} = await import(`data:text/javascript;base64,${Buffer.from(clientSource).toString('base64')}`);
function packet() {
  const buffer = new ArrayBuffer(56 + 512 * 8), view = new DataView(buffer);
  view.setUint32(0,0x31574e59,true); view.setUint32(4,1,true);
  view.setBigUint64(8,1n,true); view.setBigUint64(16,1n,true);
  view.setUint32(32,48000,true); view.setUint32(36,512,true);
  return buffer;
}
assert.equal(decodeAudioPacket(packet()).frames,512);
for (const [offset,value] of [[0,0],[4,2],[32,0],[36,513],[40,3]]) {
  const buffer=packet(); new DataView(buffer).setUint32(offset,value,true);
  assert.throws(()=>decodeAudioPacket(buffer));
}
const badPose=packet(); new DataView(badPose).setFloat32(48,NaN,true);
assert.throws(()=>decodeAudioPacket(badPose));
const badCounter=packet(); new DataView(badCounter).setBigUint64(24,BigInt(Number.MAX_SAFE_INTEGER),true);
assert.throws(()=>decodeAudioPacket(badCounter));
assert.throws(()=>decodeAudioPacket(packet().slice(0,60)));

let Sink;
const messages=[];
const context=vm.createContext({sampleRate:48000,Float32Array,Number,Math,
  AudioWorkletProcessor:class {constructor(){this.port={postMessage:data=>messages.push(data)};}},
  registerProcessor:(name,processor)=>{assert.equal(name,'yinwei-pcm-sink'); Sink=processor;}});
vm.runInContext(await readFile('assets/remote/audio-worklet.js','utf8'),context);
const sink=new Sink();
let sequence=0, firstFrame=0;
function send(rate=48000, value=.25) {
  const pcm=new Float32Array(1024);
  for(let i=0;i<512;i++){pcm[i*2]=value;pcm[i*2+1]=-value;}
  sink.port.onmessage({data:{type:'pcm',buffer:pcm.buffer,sampleRate:rate,
    sequence:++sequence,firstFrame,epoch:1,mode:1,azimuth:30,elevation:15}});
  firstFrame+=512;
}
const render=()=>{const out=[new Float32Array(128),new Float32Array(128)]; sink.process([], [out]); return out;};
send(); assert.equal(render()[0].every(x=>x===0),true,'prefill is silent');
// 160 ms prefill: 15 packets (7680 frames) at 48 kHz.
for(let i=0;i<13;i++)send();
assert.equal(render()[0].every(x=>x===0),true,'still prefilling below 160 ms');
send();
const out=render(); assert.equal(out[0][0],.25); assert.equal(out[1][0],-.25);
for(let i=0;i<12;i++)render();
assert.ok(messages.some(x=>x.type==='presentation'&&x.azimuth===30));
assert.ok(messages.some(x=>x.type==='presentation'&&x.epoch===1&&x.mode===1));
assert.equal(messages.filter(x=>x.type==='presentation').at(-1).signalPresent,true);
// Continuous silent PCM must not be described as music merely because the
// worklet is rendering. Feed at real-time cadence without triggering overflow.
sink.port.onmessage({data:{type:'flush'}});
for(let i=0;i<8;i++)send(48000,0);
for(let i=0;i<120;i++){send(48000,0);for(let j=0;j<4;j++)render();}
assert.equal(messages.filter(x=>x.type==='presentation').at(-1).signalPresent,false);
for(let i=0;i<20;i++){send(48000,.1);for(let j=0;j<4;j++)render();}
assert.equal(messages.filter(x=>x.type==='presentation').at(-1).signalPresent,true);
sink.port.onmessage({data:{type:'flush'}});
assert.equal(render()[0].every(x=>x===0),true,'seek flush removes queued audio');
for(let i=0;i<14;i++)send(44100);
const before=sink.count; render();
assert.equal(before-sink.count,117,'continuous resampling advances source frames');
for(let i=0;i<100;i++)send(44100);
assert.ok(sink.count<=44100,'buffer remains bounded');
assert.ok(messages.some(x=>x.type==='resync'));
assert.ok(sink.ready&&sink.count>0,'overflow skips ahead instead of emptying the queue');
for(let i=0;i<500;i++)render();
assert.ok(messages.some(x=>x.type==='underrun'));
assert.equal(render()[0].every(x=>x===0),true,'underrun produces silence');
assert.ok(Math.abs(sink.targetSeconds-0.21)<1e-9,'underrun grows the prefill by 50 ms');
// Ten stable seconds give 25 ms back, never below 160 ms.
sink.port.onmessage({data:{type:'flush'}});
for(let i=0;i<20;i++)send();
for(let i=0;i<940;i++){send();for(let j=0;j<4;j++)render();}
assert.ok(Math.abs(sink.targetSeconds-0.185)<1e-9,'stable playback shrinks the prefill');
console.log('PASS: PCM validation, stereo, adaptive jitter prefill, presentation pose, resampling, flush, bounded skip-ahead backlog, underrun');

// Exercise client lifecycle and packet delivery independently of a device.
const clientMessages=[], statuses=[];
let socket, contextClosed=false, resumeFails=false;
globalThis.location={protocol:'http:',host:'127.0.0.1'};
globalThis.AudioContext=class {
  constructor(){this.state='running';this.audioWorklet={addModule:async()=>{}};}
  async resume(){if(resumeFails)throw Error('device denied');}
  createGain(){return {gain:{value:1},connect(){},disconnect(){}};}
  async close(){contextClosed=true;this.state='closed';}
};
globalThis.AudioWorkletNode=class {
  constructor(){this.port={postMessage:data=>clientMessages.push(data)};}
  connect(){return {connect(){}};} disconnect(){}
};
globalThis.WebSocket=class {
  static OPEN=1;
  constructor(){socket=this;this.readyState=1;this.sent=[];}
  send(data){this.sent.push(JSON.parse(data));} close(){this.readyState=3;}
};
const client=new BrowserAudio({request:async()=>({ticket:'test-ticket'}),status:text=>statuses.push(text),pose:()=>{}});
client.updateTransport({playing:true,positionMs:0},60000);
await client.start(); socket.onopen();
assert.deepEqual(socket.sent[0],{ticket:'test-ticket'});
socket.onmessage({data:packet()});
assert.equal(client.pending.size,1);
assert.equal(clientMessages.at(-1).type,'pcm');
assert.match(statuses.at(-1),/Buffering/,'packet arrival is not output confirmation');
client.node.port.onmessage({data:{type:'presentation',epoch:1,mode:1}});
assert.match(statuses.at(-1),/Playing laptop stereo/);
client.node.port.onmessage({data:{type:'presentation',epoch:1,mode:1,signalPresent:false}});
assert.match(statuses.at(-1),/Receiving silence/);
client.setVolume(0);
client.node.port.onmessage({data:{type:'presentation',epoch:1,mode:1,signalPresent:true}});
assert.match(statuses.at(-1),/volume is muted/);
client.setVolume(1);
client.node.port.onmessage({data:{type:'underrun'}});
assert.match(statuses.at(-1),/buffering/);
client.node.port.onmessage({data:{type:'accepted',sequence:1}});
assert.equal(client.pending.size,0); assert.deepEqual(socket.sent.at(-1),{ack:1});
client.flush(true); assert.equal(client.minimumEpoch,2);
client.node.port.onmessage({data:{type:'presentation',epoch:1,mode:1}});
assert.match(statuses.at(-1),/Buffering/,'stale presentation cannot undo seek buffering');
socket.onmessage({data:packet()}); assert.equal(client.pending.size,0,'old epoch is acknowledged without playback');
await client.stop(); assert.ok(contextClosed); assert.equal(client.active,false); assert.equal(socket.onmessage,null);
client.updateTransport({playing:false,positionMs:0},60000,{live:true});
assert.equal(client.paused,false,'live PCM does not inherit paused file transport');
await client.start({source:'live'});socket.onopen();socket.onmessage({data:packet()});
assert.equal(client.pending.size,1,'live listening accepts PCM with no playing file');
socket.onmessage({data:JSON.stringify({type:'audioReady',source:'live'})});
assert.match(statuses.at(-1),/Live stream ready/);
socket.onclose({reason:'live_stopped'});
assert.match(statuses.at(-1),/Live Transfer stopped on laptop/);
assert.equal(client.active,false);
await client.start({source:'live'});socket.onopen();
socket.onclose({reason:'socket_limit'});
assert.match(statuses.at(-1),/busy/);
assert.equal(client.active,false);
resumeFails=true; contextClosed=false;
await client.start(); assert.equal(client.active,false); assert.ok(contextClosed);
assert.match(statuses.at(-1),/unavailable/);
resumeFails=false;
// prepare() unlocks audio during a tap; a later start() reuses that context.
let created=0;
const BaseContext=globalThis.AudioContext;
globalThis.AudioContext=class extends BaseContext { constructor(){super();created++;this.id=created;} };
const preparedClient=new BrowserAudio({request:async()=>({ticket:'t'}),status:()=>{},pose:()=>{}});
preparedClient.prepare(); preparedClient.prepare();
assert.equal(created,1,'prepare creates one context and is idempotent');
await preparedClient.start({source:'live'});
assert.equal(created,1,'start reuses the prepared context');
assert.equal(preparedClient.context.id,1);
assert.equal(preparedClient.prepared,null);
await preparedClient.stop();
globalThis.AudioContext=BaseContext;
const busyClient=new BrowserAudio({request:async()=>{throw Error('audio_busy');},status:text=>statuses.push(text),pose:()=>{}});
await busyClient.start();
assert.equal(busyClient.active,false);
assert.match(statuses.at(-1),/busy/,'ticket rejection explains single-listener ownership');
delete globalThis.AudioContext;
await client.start();
assert.equal(client.active,false);
assert.match(statuses.at(-1),/This browser cannot/);
console.log('PASS: browser client authentication, PCM transfer, ACK, stale epoch filtering, shutdown, denied audio device');
