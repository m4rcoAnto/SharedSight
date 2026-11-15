import test from 'node:test';
import assert from 'node:assert/strict';
import { RoomStore } from '../state.mjs';
const object = { id: 1, label: 'person', confidence: .9, box: {x:.2,y:.1,w:.2,h:.5}, position:{x:1,y:0,z:-3}, sigma:.2, evidence:'measurement', measuredAt:10 };
const frame = (patch={}) => ({version:3,deviceID:'a',name:'A',session:'room',epoch:'one',sequence:1,tracking:true,anchorID:'shared',
  camera:{m:[1,0,0,0,0,1,0,0,0,0,1,0,0,1.4,0,1]},t:10,sent:10.9,objects:[object],...patch});
test('900ms processing is retained; receipt echo bounds network without clock offsets', () => {
 let now=100000; const store=new RoomStore(()=>now);
 const first=store.accept(frame()); assert.equal(first.code,200);
 const w=store.world('room','shared:shared'); let e=[...w.entities.values()][0];
 assert.ok(Math.abs(now-e.lastObs-900)<1e-8); assert.equal(e.ageUncertaintyMs,Infinity);
 assert.deepEqual(w.observers(e,now),[]);
 now+=100;
 store.accept(frame({sequence:2,t:11,sent:11.9,receiptToken:first.reply.receiptToken,objects:[{...object,measuredAt:11}]}));
 e=[...w.entities.values()][0]; assert.ok(Math.abs(now-e.lastObs-900)<1e-8); assert.equal(e.ageUncertaintyMs,100);
 assert.deepEqual(w.observers(e,now),[]);
});
test('prediction, bearing, replay and rendering never renew measurement time', () => {
 let now=10000;const store=new RoomStore(()=>now);store.accept(frame());const w=store.world('room','shared:shared');
 const last=[...w.entities.values()][0].lastObs;
 for (const [i,evidence] of ['prediction','bearing','measurement'].entries()) {
   now+=100;store.accept(frame({sequence:i+2,t:11+i,sent:11+i,objects:[{...object,evidence}]}));
   w.step(now+10);assert.equal([...w.entities.values()][0].lastObs,last);
 }
});
test('retired epochs stay rejected after pruning; reset invalidates shared states and tokens', () => {
 let now=10000;const store=new RoomStore(()=>now); const first=store.accept(frame());
 now+=100;const second=store.accept(frame({epoch:'two',sequence:0,objects:[],receiptToken:first.reply.receiptToken}));
 assert.equal(second.code,200);assert.equal(store.world('room','shared:shared').entities.size,0);
 assert.equal(store.accept(frame({sequence:99})).code,409);
 now+=31000;store.prune();assert.equal(store.accept(frame({sequence:100})).code,409);
 assert.equal(store.accept(frame({epoch:'two',sequence:0})).code,409);
});
test('invalid timing and incompatible versions are explicit; old protocols cannot claim freshness', () => {
 const store=new RoomStore(()=>10000);
 assert.equal(store.accept(frame({version:99})).code,426);
 assert.equal(store.accept(frame({sent:9})).code,400);
 assert.equal(store.accept(frame({sent:14})).code,422);
 assert.equal(store.accept(frame({objects:[{...object,measuredAt:11}]})).code,400);
 assert.equal(store.accept(frame({version:2})).code,200);
 const w=store.world('room','shared:shared');assert.deepEqual(w.observers([...w.entities.values()][0],10000),[]);
});
