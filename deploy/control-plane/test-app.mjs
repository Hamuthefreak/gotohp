// Route tests for the shared app, run with `node test-app.mjs`.
//
// No runtime needed: the app only speaks Web Request/Response, so the tests use
// an in-memory store and a fake signed-in user. This is the contract both hosts
// (Worker + D1, Vercel + Blob) are held to.
import assert from 'node:assert/strict';

import { createApp } from './src/app.js';
import { defaults, SETTINGS } from './src/schema.js';

const ORIGIN = 'https://relay.example';

function memoryStore() {
	const map = new Map();
	return {
		async get(key) {
			return map.has(key) ? map.get(key) : null;
		},
		async set(key, value) {
			map.set(key, value);
		},
		_raw: map,
	};
}

function makeApp({ user = { sub: 'user-1', email: 'me@example.com' } } = {}) {
	const store = memoryStore();
	const app = createApp({
		store,
		origin: ORIGIN,
		sameOrigin: (request) => (request.headers.get('origin') || '') === ORIGIN,
		auth: {
			getUser: async () => user,
			loginUrl: '/api/auth/login',
			signoutUrl: '/api/auth/logout',
		},
	});
	return { app, store };
}

const req = (path, init = {}) => new Request(`${ORIGIN}${path}`, init);
const post = (path, body, contentType = 'application/json', headers = {}) =>
	req(path, { method: 'POST', body: typeof body === 'string' ? body : JSON.stringify(body), headers: { 'content-type': contentType, ...headers } });

let passed = 0;
const failures = [];

async function test(name, fn) {
	try {
		await fn();
		passed += 1;
		console.log(`ok   ${name}`);
	} catch (error) {
		failures.push({ name, error });
		console.log(`FAIL ${name}\n     ${error.message}`);
	}
}

// ---------------------------------------------------------------------------

await test('signed out gets 401 and a session that says so', async () => {
	const { app } = makeApp({ user: null });
	const dashboard = await app(req('/api/dashboard'), {});
	assert.equal(dashboard.status, 401);

	const session = await app(req('/api/session'), {});
	const body = await session.json();
	assert.equal(body.signedIn, false);
	assert.equal(body.configured, true);
	assert.equal(body.loginUrl, '/api/auth/login');
});

await test('the first account claims the dashboard and a second is refused', async () => {
	const store = memoryStore();
	const build = (user) =>
		createApp({
			store,
			origin: ORIGIN,
			sameOrigin: () => true,
			auth: { getUser: async () => user },
		});

	assert.equal((await build({ sub: 'a', email: 'a@x' })(req('/api/dashboard'), {})).status, 200);

	const other = await build({ sub: 'b', email: 'b@x' })(req('/api/dashboard'), {});
	assert.equal(other.status, 403);
	assert.equal(store._raw.get('owner_sub'), 'a');
});

await test('dashboard carries every setting, the schema and a server timestamp', async () => {
	const { app } = makeApp();
	const res = await app(req('/api/dashboard'), {});
	assert.equal(res.status, 200);
	assert.equal(res.headers.get('cache-control'), 'private, no-store');

	const body = await res.json();
	assert.equal(body.schema.length, SETTINGS.length);
	assert.deepEqual(body.settings, defaults());
	assert.equal(body.device.paired, false);
	assert.ok(body.server_time);
});

await test('settings reject foreign origins and bad values, accept good ones', async () => {
	const { app } = makeApp();

	const foreign = await app(
		req('/api/settings', {
			method: 'PUT',
			headers: { 'content-type': 'application/json', origin: 'https://evil.example' },
			body: JSON.stringify({ THREADS: 4 }),
		}),
		{},
	);
	assert.equal(foreign.status, 403);

	const bad = await app(
		req('/api/settings', {
			method: 'PUT',
			headers: { 'content-type': 'application/json', origin: ORIGIN },
			body: JSON.stringify({ THREADS: 99 }),
		}),
		{},
	);
	assert.equal(bad.status, 400);
	assert.match((await bad.json()).errors[0], /at most 8/);

	const good = await app(
		req('/api/settings', {
			method: 'PUT',
			headers: { 'content-type': 'application/json', origin: ORIGIN },
			body: JSON.stringify({ THREADS: 4, PAIR_LIVE_PHOTOS: false, UPLOAD_INCOMPLETE_LIVE: true }),
		}),
		{},
	);
	assert.equal(good.status, 200);
	const saved = (await good.json()).settings;
	assert.equal(saved.THREADS, '4');
	// Sub-options are meaningless without pairing and are cleared for us.
	assert.equal(saved.UPLOAD_INCOMPLETE_LIVE, 'false');
});

await test('device channel: token, poll, activity, commands, results', async () => {
	const { app } = makeApp();

	// No token yet: the VM has nothing to poll with.
	assert.equal((await app(post('/api/device/poll', 'agent=1\n'), {})).status, 401);

	// Issuing a token is a state change, so it needs the dashboard's own origin.
	const issued = await app(post('/api/device/token', {}, 'application/json', { origin: ORIGIN }), {});
	assert.equal(issued.status, 200);
	const { token } = await issued.json();
	assert.equal(token.length, 48);

	const auth = { authorization: `Bearer ${token}` };
	const wrong = await app(post('/api/device/poll', 'agent=1\n', 'text/plain', { authorization: 'Bearer nope' }), {});
	assert.equal(wrong.status, 401);

	const poll = await app(post('/api/device/poll', 'agent=1\npending=3\n', 'text/plain', auth), {});
	assert.equal(poll.status, 200);
	const settingsLines = (await poll.text()).trim().split('\n').filter((l) => l.startsWith('SET '));
	assert.equal(settingsLines.length, SETTINGS.length);

	// Activity: a phase change and rising upload count become feed events.
	await app(
		post(
			'/api/device/activity',
			{ activity: { phase: 'uploading', run_id: 'r1', total: 10, uploaded: 2, current: 'IMG_1.HEIC' }, log: 'sending IMG_1.HEIC' },
			'application/json',
			auth,
		),
		{},
	);
	let live = await (await app(req('/api/activity'), {})).json();
	assert.equal(live.activity.phase, 'uploading');
	assert.equal(live.activity.log, 'sending IMG_1.HEIC');
	assert.ok(live.events.some((e) => e.kind === 'upload'));

	await app(post('/api/device/activity', { activity: { phase: 'uploading', run_id: 'r1', total: 10, uploaded: 5 } }, 'application/json', auth), {});
	live = await (await app(req('/api/activity'), {})).json();
	const uploadEvents = live.events.filter((e) => e.kind === 'upload');
	assert.equal(uploadEvents.length, 2);

	// Garbage from the device is rejected rather than rendered.
	assert.equal((await app(post('/api/device/activity', 'not json', 'application/json', auth), {})).status, 400);

	// A command reaches the VM on the next poll, and its result closes it.
	const queued = await app(post('/api/commands', { kind: 'run-now' }, 'application/json', { origin: ORIGIN }), {});
	assert.equal(queued.status, 200);
	const { command } = await queued.json();

	const withCommand = await (await app(post('/api/device/poll', 'agent=1\n', 'text/plain', auth), {})).text();
	assert.match(withCommand, new RegExp(`CMD ${command.id} run-now`));

	await app(post('/api/device/result', `RESULT ${command.id} ok started\n`, 'text/plain', auth), {});
	const after = await (await app(req('/api/activity'), {})).json();
	assert.equal(after.commands[0].done, true);
	assert.equal(after.commands[0].ok, true);
	assert.ok(after.events.some((e) => /run-now.*done/.test(e.message)));
});

await test('unknown api paths 404, everything else falls through to static assets', async () => {
	const { app } = makeApp();
	assert.equal((await app(req('/api/nope'), {})).status, 404);
	assert.equal(await app(req('/'), {}), null);
});

// ---------------------------------------------------------------------------

console.log(`\n${passed} passed, ${failures.length} failed`);
if (failures.length) process.exitCode = 1;
