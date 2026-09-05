import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

for (const file of ['install/worker.js', 'website/worker/worker.js']) {
  test(`${file}: latest release never falls back to a fabricated version`, async () => {
    const source = await readFile(new URL(`../${file}`, import.meta.url), 'utf8');
    const { default: worker } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
    const originalFetch = globalThis.fetch;
    try {
      for (const tag of ['v0.2.5854', '0.2.5854']) {
        globalThis.fetch = async () => Response.json({ tag_name: tag });
        const response = await worker.fetch(new Request('https://example.com/latest.json'));
        assert.equal(response.status, 200);
        assert.deepEqual(await response.json(), { version: '0.2.5854' });
      }
      for (const upstream of [
        async () => new Response('', { status: 403 }),
        async () => new Response('', { status: 500 }),
        async () => { throw new Error('network unavailable'); },
        async () => new Response('invalid JSON'),
        ...[{}, { tag_name: null }, { tag_name: 42 }, { tag_name: '' }, { tag_name: 'invalid' }].map(body => async () => Response.json(body)),
      ]) {
        globalThis.fetch = upstream;
        const response = await worker.fetch(new Request('https://example.com/latest.json'));
        assert.equal(response.status, 503);
        assert.equal(response.headers.get('Cache-Control'), 'no-store');
        const body = await response.json();
        assert.equal('version' in body, false);
        assert.match(body.error, /retry/i);
      }
    } finally {
      globalThis.fetch = originalFetch;
    }
  });
}
