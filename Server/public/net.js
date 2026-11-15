// Push connection to the hub: one long-lived response carrying newline-delimited JSON. The Authorization header
// keeps the key out of URLs. Reconnects by itself; a wrong key is reported and not retried.
export function connect({ token, session, onMessage, onStatus }) {
  let closed = false, controller = null, timer = null;
  async function run() {
    if (closed) return;
    controller = new AbortController();
    try {
      onStatus('connecting');
      const response = await fetch(`/api/stream?session=${encodeURIComponent(session)}`, { headers: { Authorization: `Bearer ${token}` }, signal: controller.signal });
      if (response.status === 401) { onStatus('unauthorized'); return; }
      if (!response.ok || !response.body) throw new Error(`HTTP ${response.status}`);
      onStatus('connected');
      const reader = response.body.getReader(), decoder = new TextDecoder();
      let pending = '';
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        pending += decoder.decode(value, { stream: true });
        let end;
        while ((end = pending.indexOf('\n')) >= 0) {
          const line = pending.slice(0, end); pending = pending.slice(end + 1);
          if (line) { try { onMessage(JSON.parse(line)); } catch (error) { console.error(error); } }
        }
      }
      throw new Error('stream ended');
    } catch (error) {
      if (closed) return;
      onStatus('lost', error.message);
      timer = setTimeout(run, 1000);
    }
  }
  run();
  return { close() { closed = true; clearTimeout(timer); controller?.abort(); } };
}

export async function fetchPreview(token, session, device) {
  const response = await fetch(`/api/preview?session=${encodeURIComponent(session)}&device=${encodeURIComponent(device)}`, { headers: { Authorization: `Bearer ${token}` } });
  if (!response.ok) return null;
  return createImageBitmap(await response.blob());
}
