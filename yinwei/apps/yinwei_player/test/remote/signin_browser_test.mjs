import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';

const source = await readFile(new URL('../../assets/remote/signin.js', import.meta.url), 'utf8');
async function attempt({statuses = [{status:200, body:{signedIn:true}}], refreshFails=false}={}) {
  let handler, currentCookie='expired-cookie', refreshes=0, posts=0, destination;
  const calls=[], message={textContent:''}, meta={content:'old-token'};
  const button={disabled:false};
  const form={elements:{username:{value:' test-owner '},password:{value:'synthetic-test-password'}},querySelector:()=>button};
  const context=vm.createContext({AbortSignal,Error,JSON,DOMParser:class {
    parseFromString(text) {return {querySelector:()=>({content:text})};}
  },document:{querySelector(selector) {
    if(selector==='#signin')return {addEventListener:(_,callback)=>{handler=callback;}};
    if(selector==='#message')return message;
    return meta;
  }},location:{assign:path=>destination=path},fetch:async (path,options)=>{
    calls.push({path,options});
    assert.equal(options.credentials,'same-origin');
    if(path==='/remote/signin'){
      refreshes++;if(refreshFails)throw Error('offline');
      currentCookie=String(refreshes).repeat(43);
      return {ok:true,text:async()=>currentCookie};
    }
    // Expired markup alone must never be used for a password submission.
    assert.equal(options.headers['X-CSRF-Token'],currentCookie);
    assert.notEqual(currentCookie,'expired-cookie');
    const body=JSON.parse(options.body);
    assert.equal(body.username,'test-owner');
    assert.equal(body.password,'synthetic-test-password');
    const result=statuses[posts++];
    return {ok:result.status===200,status:result.status,json:async()=>result.body};
  }});
  vm.runInContext(source,context);
  await handler({preventDefault(){},currentTarget:form});
  assert.equal(form.elements.password.value,'');assert.equal(button.disabled,false);
  return {refreshes,posts,destination,message:message.textContent,calls};
}
test('an overnight stale page refreshes cookie/token before login without losing entered password',async()=>{
  const result=await attempt();assert.equal(result.destination,'/remote/app');assert.equal(result.refreshes,1);
  assert.equal(result.calls[0].options.cache,'no-store');
});
test('a replaced prelogin cookie retries once; credentials are submitted only with a new token',async()=>{
  const result=await attempt({statuses:[{status:403,body:{error:'invalid_csrf'}},{status:200,body:{signedIn:true}}]});
  assert.equal(result.posts,2);assert.equal(result.refreshes,2);assert.equal(result.destination,'/remote/app');
});
test('password failure is not retried or confused with an expired token',async()=>{
  const result=await attempt({statuses:[{status:401,body:{error:'invalid_credentials'}}]});
  assert.equal(result.posts,1);assert.match(result.message,/account or password did not match/);
});
test('blocked cookies stop after one retry with an accurate message',async()=>{
  const result=await attempt({statuses:Array(2).fill({status:403,body:{error:'invalid_csrf'}})});
  assert.equal(result.posts,2);assert.match(result.message,/expired or cookies were blocked/);
});
test('server failure does not blame the password',async()=>{
  const result=await attempt({statuses:[{status:503,body:{error:'connection_recovering'}}]});
  assert.equal(result.posts,1);assert.match(result.message,/Laptop connection unavailable/);
});
test('offline refresh submits no password and clears the field',async()=>{
  const result=await attempt({refreshFails:true});assert.equal(result.posts,0);assert.match(result.message,/unavailable/);
});
