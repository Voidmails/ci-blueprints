const test = require('node:test');
const assert = require('node:assert');
const { createServer } = require('../src/app');

test('GET /health returns ok', async () => {
  const server = createServer().listen(0);
  try {
    const { port } = server.address();
    const res = await fetch(`http://127.0.0.1:${port}/health`);
    assert.strictEqual(res.status, 200);
    assert.deepStrictEqual(await res.json(), { status: 'ok' });
  } finally {
    server.close();
  }
});
