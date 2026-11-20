import test from 'node:test';
import assert from 'node:assert/strict';
import { RoomStore, validate } from '../state.mjs';
import { createHub } from '../server.mjs';
const frame = (patch={}) => ({version:1,deviceID:'phone-a',name:'iPhone A',session:'1234',epoch:'map-1',sequence:1,tracking:true,
  anchorID:null,camera:{m:[1,0,0,0,0,1,0,0,0,0,1,0,0,1,2,1]},planes:[{id:'floor',vertical:false,
  vertices:[{x:0,y:0,z:0},{x:1,y:0,z:0},{x:1,y:0,z:1}],triangles:[0,1,2]}],
  objects:[{id:1,label:'person',confidence:.9,box:{x:.2,y:.1,w:.3,h:.7},position:{x:1,y:0,z:2},sigma:.3}],...patch});
test('rejects malformed geometry, confidence, huge images and non-finite points',()=>{
  assert.equal(validate(frame()),true);
  for(const bad of [frame({sequence:-1}),frame({camera:{m:[1]}}),frame({objects:[{...frame().objects[0],position:{x:NaN,y:0,z:0}}]}),
    frame({planes:[{...frame().planes[0],triangles:[0,1,999]}]}),frame({jpeg:'x'.repeat(400001)}),frame({objects:[{...frame().objects[0],confidence:2}]})]) assert.equal(validate(bad),false);
});
test('separates rooms, rejects replay, permits a new map epoch, expires stale observations',()=>{
  let now=1000;const store=new RoomStore(()=>now);
  assert.equal(store.ingest(frame()),204);assert.equal(store.ingest(frame()),409);
  assert.equal(store.ingest(frame({epoch:'map-2',sequence:0})),204);
  assert.equal(store.ingest(frame({session:'other'})),204);
  assert.equal(store.snapshot('1234').devices.length,1);
  now+=3100;let d=store.snapshot('1234').devices[0];assert.equal(d.live,false);assert.deepEqual(d.objects,[]);assert.deepEqual(d.planes,[]);assert.equal(d.camera,null);assert.equal(d.jpeg,null);
  now+=30000;assert.deepEqual(store.snapshot('1234').devices,[]);
});
test('multiple phones retain their own coordinates and tracking identity',()=>{
  const store=new RoomStore();store.ingest(frame());store.ingest(frame({deviceID:'phone-b',anchorID:'marker'}));
  const devices=store.snapshot('1234').devices;assert.equal(devices.length,2);assert.equal(devices[0].anchorID,null);assert.equal(devices[1].anchorID,'marker');
});
test('HTTP authentication, ingest, snapshot, invalid JSON, origin and static allowlist',async t=>{
  const {server}=createHub({token:'test-secret'});await new Promise(r=>server.listen(0,'127.0.0.1',r));
  t.after(()=>new Promise(r=>{server.close(r);server.closeAllConnections();}));
  const base=`http://127.0.0.1:${server.address().port}`;
  const headers={Authorization:'Bearer test-secret','Content-Type':'application/json'};
  assert.equal((await fetch(base+'/api/state')).status,401);
  assert.equal((await fetch(base+'/api/frames',{method:'POST',headers,body:JSON.stringify(frame())})).status,204);
  const data=await (await fetch(base+'/api/state?session=1234',{headers})).json();assert.equal(data.devices[0].objects[0].label,'person');
  assert.equal((await fetch(base+'/api/frames',{method:'POST',headers,body:'{'})).status,400);
  assert.equal((await fetch(base+'/api/frames',{method:'POST',headers:{...headers,Origin:'http://evil.example'},body:JSON.stringify(frame())})).status,403);
  assert.equal((await fetch(base+'/server.mjs')).status,404);
  assert.equal((await fetch(base+'/')).status,200);
});

// ---- protocol v2, push stream, previews ---------------------------------------------------------------------
const v2 = (patch = {}) => frame({ version: 2, fov: 55, t: 10, sent: 10.04, ...patch });
test('v2: planes and previews are sent only when they change; the hub keeps the last ones', () => {
  let now = 1000; const store = new RoomStore(() => now);
  assert.equal(store.accept(v2()).code, 200);
  const light = v2({ sequence: 2 }); delete light.planes;
  now += 66; assert.equal(store.accept(light).code, 200);
  let d = store.snapshot('1234').devices[0];
  assert.equal(d.planes.length, 1, 'surfaces from the earlier frame are still the current ones');
  now += 66; assert.equal(store.accept(v2({ sequence: 3, planes: [] })).code, 200);
  assert.equal(store.snapshot('1234').devices[0].planes.length, 0, 'an explicit empty list clears them');
  const again = v2({ epoch: 'map-2', sequence: 0 }); delete again.planes;
  now += 66; store.accept(v2({ sequence: 4 })); now += 66; store.accept(again);
  assert.equal(store.snapshot('1234').devices[0].planes.length, 0, 'a new AR map voids surfaces of the old one');
  for (const bad of [v2({ fov: 500 }), v2({ t: 'now' }), v2({ planes: 'x' }), v2({ objects: [{ ...frame().objects[0], size: { w: -1, h: 1 } }] }),
    v2({ planes: [{ ...frame().planes[0], kind: 'x'.repeat(21) }] }), frame({ version: 3 }), frame({ planes: undefined })]) assert.equal(validate(bad), false);
});
test('v3 reply: fused world, bounded capture age, and what the sender cannot see itself', () => {
  let now = 1000; const store = new RoomStore(() => now);
  const wall = { id: 'w', vertical: true, vertices: [{ x: 2, y: 0, z: -3 }, { x: 2, y: 0, z: 3 }, { x: 2, y: 2.7, z: 3 }, { x: 2, y: 2.7, z: -3 }], triangles: [0, 1, 2, 0, 2, 3] };
  const pose = (x, z, yaw) => ({ m: [Math.cos(yaw), 0, Math.sin(yaw), 0, 0, 1, 0, 0, -Math.sin(yaw), 0, Math.cos(yaw), 0, x, 1.4, z, 1] });
  let reply, tokenA, tokenB;
  for (let i = 1; i <= 20; i++, now += 66) {
    reply = store.accept(v2({ version: 3, receiptToken: tokenA, deviceID: 'a', name: 'A', anchorID: 'm', sequence: i, camera: pose(-2, 0, Math.PI / 2), planes: i === 1 ? [wall] : undefined, objects: [], t: i, sent: i + 0.05 })).reply;
    tokenA = reply.receiptToken;
    const responseB = store.accept(v2({ version: 3, receiptToken: tokenB, t: i, sent: i + 0.05, deviceID: 'b', name: 'B', anchorID: 'm', sequence: i, camera: pose(6, 0, -Math.PI / 2), planes: i === 1 ? [] : undefined,
      objects: [{ evidence: 'measurement', measuredAt: i, id: 3, label: 'person', confidence: .9, box: { x: .4, y: .2, w: .2, h: .6 }, position: { x: 4, y: 0, z: 0.2 }, sigma: .2, size: { w: .5, h: 1.75 } }] }));
    tokenB = responseB.reply.receiptToken;
  }
  assert.equal(reply.v, 3); assert.equal(reply.devices, 2);
  assert.equal(reply.advisories.length, 1);
  assert.deepEqual([reply.advisories[0].kind, reply.advisories[0].relation, reply.advisories[0].occluder, reply.advisories[0].label], ['seen', 'occluded', 'wall', 'person']);
  const state = store.stream('1234');
  assert.equal(state.type, 'world'); assert.equal(state.spaces.length, 1); assert.equal(state.spaces[0].key, 'shared:m');
  assert.equal(state.spaces[0].entities.length, 1); assert.deepEqual(state.spaces[0].entities[0].seenBy, ['b']);
  assert.equal(state.devices.find(d => d.id === 'a').latencyMs, 50, 'processing duration is a lower bound, not one-way network latency');
  assert.ok(!JSON.stringify(state).includes('vertices'), 'the push message carries no surfaces');
  assert.equal(store.surfaces('1234').find(s => s.device === 'a').planes.length, 1);
  // Unaligned phones never share a space.
  store.accept(v2({ deviceID: 'c', name: 'C', anchorID: null, sequence: 1 }));
  assert.deepEqual(store.stream('1234').spaces.map(s => s.key).sort(), ['local:c', 'shared:m']);
});
test('HTTP v2: JSON reply, NDJSON push stream with surfaces once, preview endpoint, no-key rejection', async t => {
  const { server } = createHub({ token: 'test-secret', pushHz: 50 }); await new Promise(r => server.listen(0, '127.0.0.1', r));
  t.after(() => new Promise(r => { server.close(r); server.closeAllConnections(); }));
  const base = `http://127.0.0.1:${server.address().port}`, headers = { Authorization: 'Bearer test-secret', 'Content-Type': 'application/json' };
  const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4, 0xff, 0xd9]).toString('base64');
  const r = await fetch(base + '/api/frames', { method: 'POST', headers, body: JSON.stringify(v2({ jpeg })) });
  assert.equal(r.status, 200); assert.deepEqual((await r.json()).advisories, []);
  assert.equal((await fetch(base + '/api/stream?session=1234')).status, 401);
  const image = await fetch(base + '/api/preview?session=1234&device=phone-a', { headers });
  assert.equal(image.headers.get('content-type'), 'image/jpeg'); assert.equal((await image.arrayBuffer()).byteLength, 10);
  assert.equal((await fetch(base + '/api/preview?session=1234&device=nobody', { headers })).status, 404);
  const controller = new AbortController(), stream = await fetch(base + '/api/stream?session=1234', { headers, signal: controller.signal });
  const reader = stream.body.getReader(), decoder = new TextDecoder(); let text = '';
  const post = async sequence => fetch(base + '/api/frames', { method: 'POST', headers, body: JSON.stringify({ ...v2({ sequence }), planes: undefined }) });
  await post(2); await post(3);
  while ((text.match(/"type":"world"/g) ?? []).length < 3) text += decoder.decode((await reader.read()).value, { stream: true });
  controller.abort();
  const messages = text.split('\n').filter(l => l.endsWith('}')).map(l => JSON.parse(l));
  assert.equal(messages[0].type, 'hello');
  assert.equal(messages.filter(m => m.type === 'planes').length, 1, 'surfaces are pushed once, not with every update');
  const world = messages.filter(m => m.type === 'world').at(-1);
  assert.equal(world.devices[0].previewRev, 1); assert.equal(world.spaces[0].entities[0].label, 'person');
  for (const path of ['/scene.js', '/models.js', '/net.js', '/shared/classes.mjs', '/shared/geometry.mjs', '/vendor/RoundedBoxGeometry.js']) assert.equal((await fetch(base + path)).status, 200, path);
  assert.equal((await fetch(base + '/world.mjs')).status, 404);
});
