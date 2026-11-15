import test from 'node:test';
import assert from 'node:assert/strict';
import { WorldModel } from '../world.mjs';
import { poseFromYaw } from '../geometry.mjs';
const camera = {name:'A',pose:poseFromYaw(0,1.4,4,Math.PI),fov:60,tracking:true};
const obs = (x, sigma=.2, label='person') => ({id:1,label,confidence:.9,position:{x,y:0,z:0},sigma});
const entity = w => [...w.entities.values()][0];
function trained(options={}) {
 const w=new WorldModel(options);
 for(let i=0;i<=25;i++) w.observe('A',camera,[obs(-2+i*.1)],i*100);
 return w;
}
test('sigma 5m is explicitly rejected, never clamped into a usable track',()=>{
 const w=new WorldModel();w.observe('A',camera,[obs(0,5)],0);
 assert.equal(w.entities.size,0);assert.equal(w.invalidations.get('A|1'),'uncertainty');
 assert.deepEqual(w.advisoriesFor('A'),[]);
});
test('2500 to 4500ms: one step and twenty steps have identical state and covariance (1e-10)',()=>{
 const a=trained(),b=trained();a.step(4500);
 for(let t=2600;t<=4500;t+=100)b.step(t);
 const x=entity(a),y=entity(b);
 assert.equal(x.state,y.state);assert.equal(x.reason,y.reason);
 for(const axis of ['ax','az'])for(const k of ['p','v','c11','c12','c22'])assert.ok(Math.abs(x[axis][k]-y[axis][k])<1e-10,axis+'.'+k);
 assert.equal(a.reportValid(x,4500),b.reportValid(y,4500));
 console.log(`cadence: state=${x.state}, sigma=${a.sigma(x)}m`);
});
test('straight occlusion preserves velocity, grows uncertainty and expires without declaring safety',()=>{
 const w=trained(),start=entity(w),x=start.ax.p,v=start.ax.v,s=w.sigma(start);
 assert.ok(v>.5);
 w.step(3000);let e=entity(w);
 assert.ok(Math.abs(e.ax.p-(x+v*.5))<1e-10);assert.equal(e.ax.v,v);assert.ok(w.sigma(e)>s);
 w.step(4500);e=entity(w);assert.equal(e.ax.v,v);assert.ok(w.sigma(e)>s);
 // While hidden it is a cloud of possible positions; it expires (too vague or too old), never "all clear".
 w.step(10000);e=entity(w);assert.equal(e.state,'lost');assert.ok(['uncertainty','age'].includes(e.reason),e.reason);
 assert.equal(w.invalidations.get(e.id),e.reason);assert.deepEqual(w.advisoriesFor('A'),[]);
});
test('validated barrier invalidates prediction without changing velocity or crossing it',()=>{
 const w=trained({hiddenMaxSigmaM:100}); const start=entity(w),vx=start.ax.v;
 w.setPlanes('wall',[{id:'wall',vertical:true,vertices:[{x:1,y:0,z:-2},{x:1,y:0,z:2},{x:1,y:3,z:2},{x:1,y:3,z:-2}],triangles:[0,1,2,0,2,3]}]);
 w.step(4500);const e=entity(w);assert.equal(e.state,'lost');assert.equal(e.reason,'barrierConflict');
 assert.ok(e.ax.p<1);assert.equal(e.ax.v,vx);assert.deepEqual(w.advisoriesFor('A'),[]);
});

test('intermediate render ticks do not change a later measurement update',()=>{
 const a=trained(),b=trained();
 for(let t=2600;t<=6500;t+=100)b.step(t);
 for(const w of [a,b])w.observe('A',camera,[obs(4.5)],6500);
 const x=entity(a),y=entity(b);
 assert.equal(x.state,y.state);
 for(const axis of ['ax','az'])for(const k of ['p','v','c11','c12','c22'])assert.ok(Math.abs(x[axis][k]-y[axis][k])<1e-10);
});
test('a fast vehicle 15 m away seen by another phone is forwarded; a slow person that far is not',()=>{
 const w=new WorldModel(), A={name:'A',pose:poseFromYaw(0,1.4,0,Math.PI),fov:60,tracking:true}, B={name:'B',pose:poseFromYaw(20,1.4,8,0),fov:60,tracking:true};
 for(let i=0;i<=10;i++){
  w.observe('A',A,[],i*100);
  w.observe('B',B,[{id:7,label:'car',confidence:.9,position:{x:-25+i*1,y:0,z:-15},sigma:.3},
                    {id:8,label:'person',confidence:.9,position:{x:-15,y:0,z:-12+i*.1},sigma:.3}],i*100);
 }
 const labels=w.advisoriesFor('A').map(a=>a.label);
 assert.ok(labels.includes('car'),`car forwarded (${labels})`);assert.ok(!labels.includes('person'));
});
test('a person standing still, measured with noise, does not drift while hidden or on the dashboard',()=>{
 const w=new WorldModel(); let seed=3; const noise=()=>{seed=(seed*16807)%2147483647;return (seed/2147483647-.5)*0.24;};
 for(let i=0;i<=20;i++) w.observe('A',camera,[{id:1,label:'person',confidence:.9,position:{x:0.5+noise(),y:0,z:noise()},sigma:.2}],i*100);
 const before=entity(w),x0=before.ax.p,z0=before.az.p,s0=w.sigma(before);
 w.step(5000); const e=entity(w);
 assert.ok(Math.hypot(e.ax.p-x0,e.az.p-z0)<1e-9,`stays where it was (moved ${Math.hypot(e.ax.p-x0,e.az.p-z0).toFixed(3)} m)`);
 assert.ok(w.sigma(e)>s0,'only the uncertainty grows');
 const snap=w.snapshot().find(s=>s.id===e.id); assert.equal(snap.vx,0); assert.equal(snap.vz,0); assert.equal(snap.path,undefined);
});
test('small things (bottle, cup, handbag) are not tracked; a chair and a person are',()=>{
 const w=new WorldModel();
 for(let i=0;i<5;i++) w.observe('A',camera,['bottle','cup','handbag','chair','person'].map((label,k)=>({id:k+1,label,confidence:.9,position:{x:-1+k*.6,y:0,z:0},sigma:.2})),i*100);
 assert.deepEqual([...w.entities.values()].map(e=>e.label).sort(),['chair','person']);
});
