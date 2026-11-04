// Tests for the Turso store against a local imitation of its HTTP pipeline.
//
// The real database cannot be reached from here, but the part that can be wrong
// is this code's side of the wire: the statements it sends, how it reads the
// answers, and whether a key missing from Turso is seeded from the old store.
// The mock below speaks the same JSON as Turso's /v2/pipeline endpoint.
import assert from 'node:assert/strict';
import http from 'node:http';

import { tursoStore } from './src/store-turso.js';

const table = new Map();
let failNext = 0;

const cell = (value) =>
	value === null || value === undefined ? { type: 'null' } : { type: 'text', value: String(value) };

function execute(stmt) {
	const sql = String(stmt?.sql || '').replace(/\s+/g, ' ').trim();
	const args = (stmt?.args || []).map((a) => a?.value ?? null);

	if (/^CREATE TABLE IF NOT EXISTS kv/i.test(sql)) return { cols: [], rows: [] };

	if (/^SELECT v FROM kv WHERE k = \?$/i.test(sql)) {
		const value = table.get(args[0]);
		return { cols: [{ name: 'v' }], rows: value === undefined ? [] : [[cell(value)]] };
	}

	if (/^SELECT k, v FROM kv WHERE k IN \(\?(,\s*\?)*\)$/i.test(sql)) {
		const rows = args.filter((k) => table.has(k)).map((k) => [cell(k), cell(table.get(k))]);
		return { cols: [{ name: 'k' }, { name: 'v' }], rows };
	}

	if (/^INSERT INTO kv \(k, v\) VALUES \(\?, \?\) ON CONFLICT\(k\) DO UPDATE SET v = excluded\.v$/i.test(sql)) {
		table.set(args[0], args[1]);
		return { cols: [], rows: [] };
	}

	throw new Error(`mock does not understand: ${sql}`);
}

const server = http.createServer((req, res) => {
	let body = '';
	req.on('data', (chunk) => (body += chunk));
	req.on('end', () => {
		if (req.headers.authorization !== 'Bearer test-token') {
			res.statusCode = 401;
			res.end('unauthorized');
			return;
		}
		if (failNext > 0) {
			failNext -= 1;
			res.statusCode = 429;
			res.end('rate limited');
			return;
		}

		const requests = JSON.parse(body || '{}').requests || [];
		const results = requests.map((request) =>
			request.type === 'execute'
				? { type: 'ok', response: { type: 'execute', result: execute(request.stmt) } }
				: { type: 'ok', response: { type: request.type } }
		);
		res.setHeader('content-type', 'application/json');
		res.end(JSON.stringify({ results }));
	});
});

await new Promise((resolve) => server.listen(8871, '127.0.0.1', resolve));

// A fresh store per case, so the short read cache does not hide a round trip.
const make = (importFrom) =>
	tursoStore(
		{ TURSO_DATABASE_URL: 'http://127.0.0.1:8871', TURSO_AUTH_TOKEN: 'test-token' },
		importFrom ? { importFrom } : {}
	);

try {
	await make().set('settings', '{"PAUSED":"false"}');
	assert.equal(await make().get('settings'), '{"PAUSED":"false"}', 'a written key reads back');
	assert.equal(await make().get('absent'), null, 'a missing key is null, not an error');

	assert.deepEqual(
		await make().getMany(['settings', 'absent']),
		{ settings: '{"PAUSED":"false"}', absent: null },
		'one round trip answers several keys'
	);

	// Seeding from the previous store: only on a miss, only once, and a failure
	// there leaves the key absent rather than failing the request.
	let legacyReads = 0;
	const legacy = {
		async get(key) {
			legacyReads += 1;
			if (key === 'device_token_hash') return 'hash-from-the-old-store';
			if (key === 'accounts') throw new Error('relay state /api/state/get failed: 429 paused');
			return null;
		},
	};

	assert.equal(await make(legacy).get('device_token_hash'), 'hash-from-the-old-store', 'a missing key is seeded');
	assert.equal(await make(legacy).get('device_token_hash'), 'hash-from-the-old-store', 'and then served from Turso');
	assert.equal(legacyReads, 1, 'the old store is asked once per key');
	assert.equal(table.get('device_token_hash'), 'hash-from-the-old-store', 'the seeded value is written, not just returned');

	assert.equal(await make(legacy).get('accounts'), null, 'an unreachable old store leaves the key absent');
	assert.equal(await make().get('accounts'), null, 'nothing was invented for it');

	// The one that matters on a switch: the pairing survives.
	assert.equal(await make().get('device_token_hash'), 'hash-from-the-old-store', 'a fresh instance sees the seeded pairing');

	// An empty key list is not a query the database should be asked to run.
	assert.deepEqual(await make().getMany([]), {}, 'no keys means no work');

	// A hard failure from Turso is reported, with the status in the message. A key
	// never read before, so the module-level read cache cannot answer for Turso.
	failNext = 1;
	await assert.rejects(() => make().get('not-read-before'), /429/, 'a non-200 answer is an error, not a silent null');

	console.log('turso store: ok');
} finally {
	server.close();
}
