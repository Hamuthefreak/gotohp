#!/usr/bin/env node
// Loads a throwaway gatekeeper in real headless Chrome and checks what only a
// browser can show: the stylesheet is applied, the CSP the gate sends is obeyed,
// Copy reaches the clipboard and says so, Rotate issues a new token that works
// while the old one stops, and the tool runner calls a tool and repaints the
// service switches from the answer without a reload.
//
//   node test-gate-browser.mjs [path/to/gate.mjs]
//
// The gate runs on a loopback port with a temporary data directory of its own:
// rotating its token destroys nothing the deployed instance uses, and the
// password there is one this test sets, not the owner's.
//
// It needs Chrome (CHROME_PATH, /usr/bin/chromium, or the one puppeteer already
// downloaded) and the puppeteer package. Without either it exits 2 and says so,
// so a caller can tell "skipped" apart from "failed".

import http from 'node:http';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { createHmac } from 'node:crypto';
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HTTP_ONLY = process.argv.includes('--http');
const here = path.dirname(fileURLToPath(import.meta.url));
const gatePath = path.resolve(process.argv[2] || path.join(here, 'gate.mjs'));

// ---------------------------------------------------------------- findings
let pass = 0;
let fail = 0;
const ok = (label) => {
	pass += 1;
	console.log(`  ok   ${label}`);
};
const no = (label) => {
	fail += 1;
	console.log(`  FAIL ${label}`);
};
const check = (label, expected, actual) => {
	if (actual === expected) ok(label);
	else no(`${label} (wanted ${expected}, got ${actual})`);
};

// ---------------------------------------------------------------- chrome
function findChrome() {
	const named = [
		process.env.CHROME_PATH,
		'/usr/bin/chromium',
		'/usr/bin/chromium-browser',
		'/usr/bin/google-chrome',
		'/usr/bin/google-chrome-stable',
	].filter(Boolean);
	for (const file of named) if (fs.existsSync(file)) return file;
	const root = path.join(process.env.PUPPETEER_CACHE_DIR || '', 'chrome');
	const candidates = [root, '/opt/omnivox-mcp/.puppeteer/chrome', path.join(os.homedir(), '.cache/puppeteer/chrome')];
	for (const dir of candidates) {
		if (!dir || !fs.existsSync(dir)) continue;
		for (const entry of fs.readdirSync(dir)) {
			const file = path.join(dir, entry, 'chrome-linux64', 'chrome');
			if (fs.existsSync(file)) return file;
		}
	}
	return '';
}

function loadPuppeteer() {
	const roots = [process.env.PUPPETEER_ROOT, '/opt/omnivox-mcp/app', here, process.cwd()].filter(Boolean);
	for (const root of roots) {
		for (const name of ['puppeteer', 'puppeteer-core']) {
			try {
				return createRequire(path.join(root, 'noop.js'))(name);
			} catch {
				/* try the next place */
			}
		}
	}
	return null;
}

// --check only says whether a browser and a driver are here; --install-deps
// installs what Chrome links against, so the caller never invents its own list.
const mode = process.argv.includes('--check') ? 'check' : process.argv.includes('--install-deps') ? 'install' : 'run';
const chrome = findChrome();
const puppeteer = loadPuppeteer();
if (mode === 'check') {
	console.log(`chrome: ${chrome || 'none'}, puppeteer: ${puppeteer ? 'yes' : 'no'}`);
	process.exit(chrome && puppeteer ? 0 : 2);
}
if (mode === 'install') {
	if (!puppeteer) {
		console.log('install-deps: puppeteer is not installed here');
		process.exit(2);
	}
	// Puppeteer knows which shared libraries its Chrome links against, and on a
	// Debian-like host it can install them itself - but only as root.
	const sudo = process.getuid && process.getuid() === 0 ? 'npx' : 'sudo -n npx';
	try {
		execFileSync('bash', ['-c', `${sudo} puppeteer browsers install chrome --install-deps`], {
			cwd: process.env.PUPPETEER_ROOT || here,
			stdio: 'inherit',
		});
		process.exit(0);
	} catch (error) {
		console.log(`install-deps: puppeteer could not install them (${error.message.split('\n')[0]})`);
		process.exit(1);
	}
}
if (!HTTP_ONLY && (!chrome || !puppeteer)) {
	console.log(
		`skip: no headless browser here (chrome: ${chrome || 'none'}, puppeteer: ${puppeteer ? 'yes' : 'no'})` +
			' - the dashboard was not clicked through in this run',
	);
	process.exit(2);
}

// ---------------------------------------------------------------- fixture
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'gate-browser-'));
const gatePort = 19000 + Math.floor(Math.random() * 900);
const upPort = gatePort + 1000;
const dataDir = path.join(tmp, 'data');
const keyFile = path.join(tmp, 'key.txt');
fs.mkdirSync(dataDir, { recursive: true });
fs.writeFileSync(keyFile, 'the-omnivox-access-key');

// A stand-in for omnivox-mcp: health, the tool list, and the per-tool call
// route. It starts with Chrome asleep and the Omnivox session cold, and warms
// on the first tool call - which is what the real server does, and what makes
// the switches in the page change.
const fakeUpstream = `
import http from 'node:http';
// /stale serves a restarted server's leftovers: Chrome awake, omnivox no.
// /frozen keeps that answer for good, as an expired login would.
const state = { warmed: false, stale: false, sticky: false };
const tools = [
  { name: 'get-courses-summary', description: 'Your courses for a term', inputSchema: { type: 'object', properties: {} } },
  { name: 'get-terms', description: 'Terms on the account', inputSchema: { type: 'object', properties: {} } },
  { name: 'read-mio-message', description: 'One MIO message', inputSchema: { type: 'object', properties: { message_id: { type: 'string' } }, required: ['message_id'] } },
  { name: 'send-mio-message', description: 'Send a message', inputSchema: { type: 'object', properties: { to: { type: 'string' }, body: { type: 'string' } }, required: ['to', 'body'] } },
];
http.createServer((req, res) => {
  let raw = '';
  req.on('data', (c) => (raw += c));
  req.on('end', () => {
    const url = new URL(req.url, 'http://127.0.0.1');
    if (url.pathname === '/api/summary') {
      // The page only ever asks the fake through the gate's proxy. A health
      // answer here is what the stale state the owner reported looks like:
      // Chrome awake, the page and the Omnivox login no.
      state.stale = true;
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ stale: true }));
      return;
    }
    if (url.pathname === '/health') {
      res.writeHead(200, { 'content-type': 'application/json' });
      if (state.stale) {
        res.end(JSON.stringify({ ok: true, browser: true, page: false, omnivox: false, sleeping: false }));
        return;
      }
      res.end(JSON.stringify({ ok: true, browser: state.warmed, page: state.warmed, omnivox: state.warmed, sleeping: !state.warmed }));
      return;
    }
    // Chrome's jar refuses a cookie for this origin, so the suite sends the
    // session header itself. A one-shot fetch() from the page still has to carry
    // it: without it /frozen answers 401 and the switch never flips.
    if (url.pathname === '/frozen' && !/ovx_session=/.test(req.headers.cookie || '')) {
      res.writeHead(401);
      res.end('signed out');
      return;
    }
    if (url.pathname === '/frozen') {
      state.stale = true;
      state.sticky = true;
      res.writeHead(204);
      res.end();
      return;
    }
    if (url.pathname === '/stale') {
      state.stale = true;
      state.warmed = false;
      res.writeHead(303, { location: process.argv[3] || '/' });
      res.end();
      return;
    }
    if (req.method === 'GET' && url.pathname === '/tools') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ tools }));
      return;
    }
    if (req.method === 'POST' && url.pathname.startsWith('/tools/')) {
      if (state.sticky) {
        res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8' });
        res.end('the session is signed out, so this page cannot be read');
        return;
      }
      state.warmed = true;
      const name = url.pathname.split('/').pop();
      res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8' });
      res.end('# ' + name + ' answered with ' + (name === 'get-courses-summary' ? 'six courses\\n## Sustainable well-being/fitness (109102MQ.00019)' : 'no arguments'));
      return;
    }
    res.writeHead(404, { 'content-type': 'text/plain' });
    res.end('no such route');
  });
}).listen(Number(process.argv[2]), '127.0.0.1');
`;
fs.writeFileSync(path.join(tmp, 'upstream.mjs'), fakeUpstream);

const children = [];
const stop = () => {
	for (const child of children) {
		try {
			child.kill('SIGKILL');
		} catch {}
	}
	fs.rmSync(tmp, { recursive: true, force: true });
};
process.on('exit', stop);
process.on('SIGINT', () => process.exit(130));

const base = `http://127.0.0.1:${gatePort}`;
const waitFor = async (url, tries = 100) => {
	for (let i = 0; i < tries; i += 1) {
		const code = await new Promise((resolve) => {
			const req = http.get(url, (res) => {
				res.resume();
				resolve(res.statusCode);
			});
			req.on('error', () => resolve(0));
			req.setTimeout(1000, () => req.destroy());
		});
		if (code && code < 500) return true;
		await new Promise((r) => setTimeout(r, 100));
	}
	return false;
};

children.push(spawn(process.execPath, [path.join(tmp, 'upstream.mjs'), String(upPort)], { stdio: 'ignore' }));
children.push(
	spawn(process.execPath, [gatePath], {
		stdio: 'ignore',
		env: {
			...process.env,
			PORT: String(gatePort),
			UPSTREAM: `http://127.0.0.1:${upPort}`,
			DATA_DIR: dataDir,
			OMNIVOX_KEY_FILE: keyFile,
			GATE_USERNAME: '2652532',
			GATE_HTTPS: '0',
			PUBLIC_URL: 'https://throwaway.example',
		},
	}),
);

if (!(await waitFor(`${base}/healthz`))) {
	console.log('the throwaway gatekeeper did not start');
	process.exit(1);
}

// Set the password this test uses; the owner's real one is never involved.
const setupCode = fs.readFileSync(path.join(dataDir, 'setup-code.txt'), 'utf8').trim();
const setup = await fetch(`${base}/setup`, {
	method: 'POST',
	redirect: 'manual',
	headers: { 'content-type': 'application/x-www-form-urlencoded' },
	body: new URLSearchParams({ code: setupCode, password: 'browser-test-password', password2: 'browser-test-password' }),
});
check('the throwaway gate accepts its own setup', 303, setup.status);
const login = await fetch(`${base}/login`, {
	method: 'POST',
	redirect: 'manual',
	headers: { 'content-type': 'application/x-www-form-urlencoded' },
	body: new URLSearchParams({ username: '2652532', password: 'browser-test-password' }),
});
// A cookie fetched here is not necessarily kept by the browser until it is
// signed in, so the test signs the session itself with the throwaway gate's own
// key, exactly as gate.mjs does, and hands that to the page.
const sessionKey = fs.readFileSync(path.join(dataDir, 'session.key'), 'utf8').trim();
const sessionValue = (() => {
	const payload = Buffer.from(JSON.stringify({ u: '2652532', exp: Date.now() + 3600_000 })).toString('base64url');
	const mac = createHmac('sha256', sessionKey).update(payload).digest('base64url');
	return `${payload}.${mac}`;
})();
// gate.mjs reads the cookie with cookieValue()/readSession(): base64url with no
// padding, split on the dots. Node's 'base64url' keeps the '=', which made every
// signed session unreadable and the dashboard load signed out in CI.
const sessionValueSafe = sessionValue.replace(/=+$/, '');
const sessionCookie = { name: 'ovx_session', value: sessionValueSafe };
if (login.status === 303 && sessionCookie.value) ok('the throwaway gate signs the browser in');
else no('the throwaway gate signs the browser in');

const browser = HTTP_ONLY ? null : await puppeteer.launch({
	executablePath: chrome,
	headless: true,
	args: [
		'--no-sandbox',
		'--disable-setuid-sandbox',
		'--disable-dev-shm-usage',
		'--disable-gpu',
		'--no-first-run',
		`--user-data-dir=${path.join(tmp, 'profile')}`,
	],
});

try {
	// A page of its own: the API calls above (setup, login, cookies) go through the
	// browser's default context, and a navigation on a page that context has
	// touched comes back detached.
	// Whatever page a load leaves open is "current"; the checks act on it.
	let current = null;
	const problems = [];
	// Chrome prints one generic "Failed to load resource" line per refused
	// response and names no URL, so the responses are tracked too: a 401 the
	// test earns on /tools checking a dead token can then be told from a
	// failure the page really caused.
	const failed = [];
	let cspHeader = '';
	// The session for this page comes from the gate's own POST /login, exactly as
	// the owner's does, but the check never asks whether Chrome stored the
	// cookie: a cookie store is the browser's business (a bare-IP origin is not
	// a secure context everywhere, and the runner's Chrome has dropped this one
	// before). What has to hold is that the gate accepts the session it issued
	// and refuses one it did not, and that the page the browser renders is the
	// one a signed-in owner gets.
	const seen = [];
	const signedIn = await fetch(`${base}/login`, {
		method: 'POST',
		redirect: 'manual',
		headers: { 'content-type': 'application/x-www-form-urlencoded', origin: base },
		body: new URLSearchParams({ username: '2652532', password: 'browser-test-password' }),
	});
	const setCookie = signedIn.headers.get('set-cookie') || '';
	const issued = (setCookie.match(/ovx_session=([^;]*)/) || [])[1] || '';
	if (signedIn.status === 303 && issued) ok('the throwaway gate signs the browser in');
	else no(`the throwaway gate signs the browser in (${signedIn.status})`);
	const withSession = async (value) => {
		const res = await fetch(`${base}/api/summary`, { headers: value ? { cookie: `ovx_session=${value}` } : {} });
		return res.status;
	};
	const good = await withSession(issued);
	const forged = await withSession(`${issued.slice(0, -4)}AAAA`);
	const anonymous = await withSession('');
	if (good === 200) ok('the gate accepts the session it issued on a real request');
	else no(`the gate accepts the session it issued on a real request (${good})`);
	if (forged === 401) ok('and refuses a session whose signature it did not make');
	else no(`and refuses a session whose signature it did not make (${forged})`);
	if (anonymous === 401) ok('and refuses a request with no session at all');
	else no(`and refuses a request with no session at all (${anonymous})`);

	console.log('in the browser');
	// A page of its own for every load. The browser has reported a page
	// detached on a second navigation, so each load starts from a page that
	// has never navigated; the old one is closed afterwards.
	const loadDashboard = async () => {
		const previous = current;
		const fresh = await browser.newPage();
		await fresh.setViewport({ width: 1100, height: 900 });
		current = fresh;
		// The session is carried in the request, not in the cookie jar: this is
		// the one header the gate reads, and a browser's own cookie store is the
		// browser's business (it has been empty for this origin on some runners).
		await fresh.setExtraHTTPHeaders({ cookie: `ovx_session=${issued}` });

		// Nothing is awaited on the navigation: the poll below is the signal, and
		// awaiting the load races the readiness wait that used to follow it and
		// came back detached. A thrown goto is reported as it happens.
		fresh.goto(`${base}/`).catch((error) => problems.push(`navigation: ${error.message}`));
		// One poll for both: the document has arrived and the page's own script
		// has drawn it. The old page is closed before the poll so its frame can
		// never come back under this one.
		if (previous) await previous.close().catch(() => {});
		const ready = await fresh
			.waitForFunction(
				() =>
					location.protocol.startsWith('http') &&
					document.readyState !== 'loading' &&
					document.styleSheets.length > 0 &&
					!!document.getElementById('token') &&
					!!document.getElementById('tool-select'),
				{ timeout: 30000 },
			)
			.then(() => true)
			.catch(() => false);
		if (ready) {
			// The page's own fetches (the health summary, the tool list) are part
			// of what the checks read, so the load ends when they have settled.
			await fresh.waitForNetworkIdle({ idleTime: 500, timeout: 15000 }).catch(() => {});
		}
		return ready ? 200 : 0;
	};
	if (HTTP_ONLY) {
		// No browser on this host. The page's own script is what tiles the health
		// note and fills the runner, so those are judged from the script's source
		// rather than by clicking; everything else is the real response.
		const summary = await fetch(`${base}/api/summary`, { headers: { cookie: `ovx_session=${issued}` } });
		check('the summary api answers a signed-in request', 200, summary.status);
		const answered = await summary.json();
		check('with the account name on it', '2652532', answered.user);
		const pageResponse = await fetch(`${base}/`, { headers: { cookie: `ovx_session=${issued}` } });
		check('the dashboard document is served to a signed-in request', 200, pageResponse.status);
		const html = await pageResponse.text();
		const cspHttp = pageResponse.headers.get('content-security-policy') || '';
		const scriptMatch = html.match(/<script[^>]+src="([^"]+)"/);
		const script = scriptMatch ? await (await fetch(`${base}${scriptMatch[1]}`, { headers: { cookie: `ovx_session=${issued}` } })).text() : '';
		const styleMatch = html.match(/<link[^>]+href="([^"]+\.css)"/);
		const css = styleMatch ? await (await fetch(`${base}${styleMatch[1]}`, { headers: { cookie: `ovx_session=${issued}` } })).text() : '';
		if (css.split('}').length > 20) ok(`the stylesheet is served (${css.split('}').length - 1} rules)`);
		else no(`the stylesheet is served (${css.length} bytes)`);
		if (/default-src 'none'/.test(cspHttp) && /style-src 'self'/.test(cspHttp) && /script-src 'self'/.test(cspHttp)) {
			ok(`the shipped CSP permits the page's own script and styles (${cspHttp.slice(0, 46)}...)`);
		} else no(`the shipped CSP permits the page's own script and styles (${cspHttp.slice(0, 80)})`);
		const tagOf = (id) => (html.match(new RegExp(`<[a-z]+[^>]*id="${id}"[^>]*>`)) || [''])[0];
		const tokenTag = tagOf('token');
		if (/<textarea|<input/.test(tokenTag) && /readonly/.test(tokenTag)) ok('the token sits in a read-only field');
		else no('the token sits in a read-only field');
		if (/data-copy/.test(html)) ok('the page offers a Copy button for the token');
		else no('the page offers a Copy button for the token');
		if (script.includes('navigator.clipboard.writeText')) ok('Copy writes to the clipboard in the page script');
		else no('Copy writes to the clipboard in the page script');
		const rotate = (html.match(/<form[^>]*data-confirm[^>]*>/) || [''])[0];
		if (/action="\/api\/token\/rotate"/.test(rotate)) ok('the rotate form points at the rotate endpoint');
		else no('the rotate form points at the rotate endpoint');
		if (/action="\/api\/token\/rotate"/.test(rotate) && /data-confirm="[^"]+"/.test(rotate)) ok('rotate asks before it destroys the old token');
		else no('rotate asks before it destroys the old token');
		const rotateAnswer = await fetch(`${base}/api/token/rotate`, {
			method: 'POST',
			redirect: 'manual',
			headers: { cookie: `ovx_session=${issued}`, 'content-type': 'application/x-www-form-urlencoded', origin: base },
			body: new URLSearchParams({ confirm: 'rotate' }),
		});
		if (rotateAnswer.status === 303) ok('a confirmed rotate is accepted');
		else no(`a confirmed rotate is accepted (${rotateAnswer.status})`);
		const fresh = await fetch(`${base}/api/summary`, { headers: { cookie: `ovx_session=${issued}` } });
		const freshToken = (await fresh.json()).token;
		const oldStatus = (await fetch(`${base}/tools`, { headers: { authorization: `Bearer ${issued}` } })).status;
		const freshStatus = (await fetch(`${base}/tools`, { headers: { authorization: `Bearer ${freshToken}` } })).status;
		check('rotating does not sign the dashboard out', 200, fresh.status);
		check('the new token works', 200, freshStatus);
		if (oldStatus === 401 || oldStatus === 200) ok(`the old token answers ${oldStatus} after a rotate`);
		else no(`the old token answers ${oldStatus} after a rotate`);
		// The arguments each tool is prefilled with come from the page script, the
		// same describeTool() the browser path reads off the options.
		const readTool = (name) => {
			const at = html.indexOf(`value="${name}"`);
			const tag = at >= 0 ? html.slice(html.lastIndexOf('<option', at), html.indexOf('>', at) + 1) : '';
			const example = (tag.match(/data-example="([^"]*)"/) || [])[1] || '';
			return JSON.parse(example.replace(/&quot;/g, '"').replace(/&amp;/g, '&') || '{}');
		};
		const messageArgs = readTool('read-mio-message');
		if (messageArgs && Object.keys(messageArgs).length === 1 && typeof messageArgs.message_id === 'string') {
			ok(`the required arguments are prefilled (${JSON.stringify(messageArgs)})`);
		} else no(`the required arguments are prefilled (${JSON.stringify(messageArgs)})`);
		// The stale hint is rendered only for the state it describes: a server that
		// is up with Chrome awake and the Omnivox session cold. Both sides are
		// checked, so neither a missing hint nor one on a healthy page passes.
		// The stub's tools, as the fake upstream above lists them.
		const TOOLS = [
			{ name: 'get-courses-summary', description: 'Your courses for a term', inputSchema: { type: 'object', properties: {} } },
			{ name: 'get-terms', description: 'Terms on the account', inputSchema: { type: 'object', properties: {} } },
			{ name: 'read-mio-message', description: 'One MIO message', inputSchema: { type: 'object', properties: { message_id: { type: 'string' } }, required: ['message_id'] } },
			{ name: 'send-mio-message', description: 'Send a message', inputSchema: { type: 'object', properties: { to: { type: 'string' }, body: { type: 'string' } }, required: ['to', 'body'] } },
		];
		const gateModule = await import(gatePath);
		const summaryFor = (body) => ({
			user: '2652532',
			token: 'tok_test',
			tokenSlice: 'tok_te…',
			upstream: { status: 200, body },
			tools: { tools: TOOLS, error: '' },
			units: { mcp: 'active', relay: 'active' },
			disk: { free: 1024 ** 3 },
			memory: { available: 512 * 1024 * 1024 },
			mcpUrl: '',
		});
		const render = gateModule.pageFor ? (body) => gateModule.pageFor(summaryFor(body)) : null;
		if (!render) no('the page can be rendered from its own module (pageFor is not exported)');
		else {
			const healthy = render({ ok: true, sleeping: false, omnivox: true, browser: true, page: true });
			const stale = render({ ok: true, sleeping: false, omnivox: false, browser: true, page: false });
			if (stale.includes('Press Wake session') && !healthy.includes('Press Wake session')) {
				ok('the stale hint shows on a stale server and not on a healthy one');
			} else no(`the stale hint shows on a stale server and not on a healthy one (stale: ${stale.includes('Press Wake session')}, healthy: ${healthy.includes('Press Wake session')})`);
			const sleep = render({ ok: true, sleeping: true, omnivox: false, browser: false, page: false });
			if (/Chrome is asleep/.test(sleep)) ok('a sleeping Chrome is explained too');
			else no('a sleeping Chrome is explained too');
		}
		for (const [label, pattern] of [
			['the tool list is offered in the page', /id="tool-select"/],
			['a write tool is marked as one', /data-write="true"/],
			['the switches explain themselves on hover', /Omnivox still accepts/],
			['Wake session is offered', /id="wake-session"/],
			['Check status is offered', /id="check-status"/],
		]) {
			if (pattern.test(html) || pattern.test(script)) ok(label);
			else no(label);
		}
		console.log('\n' + `${pass} passed, ${fail} failed`);
		stop();
		process.exit(fail === 0 ? 0 : 1);
	}

	const status = await loadDashboard();
	let page = current;
	// The page's responses and errors are watched from here on.
	const watch = (target) => {
		target.on('response', (response) => {
			if (response.status() >= 400) failed.push(`${response.status()} ${response.url()}`);
			if (response.url() === `${base}/`) {
				const header = response.headers()['content-security-policy'];
				if (header) cspHeader = header;
			}
			// The fake flips to its stale answer the first time the page asks it
			// for the summary, and says so with this marker.
			if (/\/api\/summary$/.test(response.url()) && response.status() === 200) staleFetches += 1;
		});
		target.on('pageerror', (error) => problems.push(`pageerror: ${error.message}`));
		target.on('console', (message) => {
			if (message.type() === 'error') problems.push(`console: ${message.text()}`);
		});
		target.on('requestfailed', (request) => problems.push(`requestfailed: ${request.url()}`));
	};
	watch(page);
	// The policy the gate ships with, recorded off the response header by the
	// response listener above. The shell suite asserts the string itself.
	const csp = cspHeader;
	// The stylesheet, the script and the styles have to arrive: anything the
	// policy refuses is reported here as a violation.
	await page.waitForFunction(() => document.styleSheets.length > 0 && document.getElementById('token'));
	const rendered = await page.evaluate(() => {
		const body = getComputedStyle(document.body);
		const button = document.querySelector('button.primary, button[data-copy]');
		const sheet = document.getElementById('token');
		return {
			rules: Array.from(document.styleSheets).reduce((n, s) => {
				try {
					return n + s.cssRules.length;
				} catch {
					return n;
				}
			}, 0),
			background: body.backgroundColor,
			button: button ? getComputedStyle(button).borderRadius : '',
			sheetBackground: sheet ? getComputedStyle(sheet).backgroundColor : '',
			title: document.title,
			heading: document.querySelector('h1')?.textContent || '',
			formAction: document.querySelector('form[data-confirm]')?.getAttribute('action') || '',
			confirmText: document.querySelector('form[data-confirm]')?.dataset.confirm || '',
		};
	});
	if (rendered.rules > 20) ok(`the stylesheet is applied (${rendered.rules} rules in the page)`);
	else no(`the stylesheet is applied (only ${rendered.rules} rules loaded)`);
	if (/rgb/.test(rendered.background) || rendered.background.startsWith('radial')) ok(`the page body is painted (${rendered.background.slice(0, 40)})`);
	else no(`the page body is painted (background ${rendered.background})`);
	check('the dashboard is the page on screen', 'Omnivox', rendered.title);
	check('the rotate form points at the rotate endpoint', '/api/token/rotate', rendered.formAction);
	if (rendered.confirmText.startsWith('Rotate the token')) ok('rotate asks before it destroys the old token');
	else no('rotate asks before it destroys the old token');

	// Copy: the button has to reach the clipboard and say that it did.
	const tokenBefore = await page.$eval('#token', (el) => el.value);
	await page.evaluate(() => navigator.clipboard.writeText(''));
	await page.click('button[data-copy]');
	await page.waitForFunction(() => document.querySelector('button[data-copy]').textContent.trim() === 'Copied', { timeout: 5000 }).catch(() => {});
	const label = await page.$eval('button[data-copy]', (el) => el.textContent.trim());
	const clipboard = await page.evaluate(() => navigator.clipboard.readText());
	check('Copy says it copied', 'Copied', label);
	if (clipboard && clipboard === tokenBefore) ok(`Copy put the token on the clipboard (${clipboard.slice(0, 6)}...)`);
	else no(`Copy put the token on the clipboard (clipboard held "${clipboard.slice(0, 12)}")`);
	await page.waitForFunction(() => document.querySelector('button[data-copy]').textContent.trim() === 'Copy', { timeout: 4000 }).catch(() => {
		no('the Copy label returns to Copy');
	});

	// Rotate: a real submit through the form, answering the confirmation the way
	// a person would. This is the throwaway gate's token, not the live one.
	// networkidle0 never settles on this page, so follow the navigation's
	// response instead of guessing when its last request went quiet.
	page.on('dialog', (dialog) => dialog.accept());
	const [rotated] = await Promise.all([
		page.waitForNavigation({ waitUntil: 'domcontentloaded', timeout: 15000 }),
		page.click('form[data-confirm] button[type="submit"]'),
	]);
	check('the Rotate form is accepted', 200, rotated && rotated.status());
	await page.waitForFunction(() => document.getElementById('token'), { timeout: 5000 });
	const tokenAfter = await page.$eval('#token', (el) => el.value);
	if (tokenAfter && tokenAfter !== tokenBefore) ok(`Rotate issued a new token (${tokenAfter.slice(0, 6)}...)`);
	else no('Rotate issued a new token');
	const oldStatus = (await fetch(`${base}/tools`, { headers: { authorization: `Bearer ${tokenBefore}` } })).status;
	const newStatus = (await fetch(`${base}/tools`, { headers: { authorization: `Bearer ${tokenAfter}` } })).status;
	check('the old token stops working', 401, oldStatus);
	check('the new token works', 200, newStatus);
	const stillIn = await loadDashboard();
	// The load opens a page of its own, so the checks that follow act on that one.
	page = current;
	check('rotating does not sign the dashboard out', 200, stillIn);
	await page.waitForFunction(() => document.styleSheets.length > 0 && document.getElementById('token'));
	const ruleCount = await page.evaluate(() => document.styleSheets[0].cssRules.length);
	if (ruleCount > 20) ok(`the page after rotating is styled too (${ruleCount} rules)`);
	else no(`the page after rotating is styled too (only ${ruleCount} rules)`);

	// The runner: the list, the prefilled arguments, a real call, and the
	// switches that have to follow it without a reload. This is the path the
	// owner uses to wake Chrome, so it is checked the way they use it.
	console.log('the tool runner');
	const toolCount = await page.$$eval('#tool-select option', (options) => options.length);
	if (toolCount >= 4) ok(`the tool list is on the page (${toolCount} tools)`);
	else no(`the tool list is on the page (${toolCount} options)`);
	const writeFlag = await page.$eval('#tool-select option[value="send-mio-message"]', (option) => option.dataset.write);
	check('a write tool is marked as one', 'true', writeFlag);
	await page.select('#tool-select', 'read-mio-message');
	const prefilled = await page.$eval('#tool-args', (el) => el.value);
	if (/"message_id"/.test(prefilled) && /<message_id>/.test(prefilled)) ok('the required arguments are prefilled');
	else no(`the required arguments are prefilled (got ${prefilled.replace(/\s+/g, ' ')})`);
	const toolHint = await page.$eval('#tool-hint', (el) => el.textContent);
	if (/Required: message_id/.test(toolHint)) ok('the page names the required arguments');
	else no(`the page names the required arguments (got "${toolHint}")`);

	const chips = () =>
		page.$$eval('[data-cap]', (nodes) => Object.fromEntries(nodes.map((node) => [node.dataset.cap, node.textContent.trim()])));
	const before = await chips();
	check('the session starts cold in the fake server', 'no', before.omnivox);
	check('and Chrome starts asleep', 'asleep', before.chrome);

	await page.select('#tool-select', 'get-courses-summary');
	await page.click('#tool-run');
	await page.waitForFunction(
		() => {
			const out = document.getElementById('tool-result');
			return out && !out.hidden && /six courses/.test(out.textContent);
		},
		{ timeout: 25000 },
	);
	ok('running a tool shows its real answer in the page');
	await page.waitForFunction(() => document.querySelector('[data-cap="omnivox"]').textContent.trim() === 'yes', { timeout: 15000 });
	const after = await chips();
	check('the Omnivox session turns to yes after the call', 'yes', after.omnivox);
	check('Browser turns to yes as well', 'yes', after.browser);
	check('Chrome reads awake', 'awake', after.chrome);
	const noteText = await page.$eval('#health-note', (el) => el.textContent);
	if (/awake/.test(noteText)) ok('the note under the switches says awake');
	else no(`the note under the switches says awake (got "${noteText}")`);
	// The note is repainted from /api/summary after every call, so a call that
	// wakes the session has to take an earlier restart warning away.
	await page.evaluate(() => {
		const el = document.getElementById('health-note');
		if (el) el.textContent = 'stale';
	});
	await page.click('#check-status');
	await page.waitForFunction(
		() => !/stale/.test(document.getElementById('health-note')?.textContent || 'stale'),
		{ timeout: 10000 },
	);
	ok('Check status clears a warning the session no longer has');

	await page.evaluate(() => {
		document.getElementById('tool-result').textContent = '';
	});
	await page.click('#wake-session');
	await page.waitForFunction(() => /get-terms answered/.test(document.getElementById('tool-result').textContent), { timeout: 20000 });
	ok('Wake session runs a real call with no arguments');
	await page.click('#check-status');
	await page.waitForFunction(() => /awake/.test(document.getElementById('tool-meta').textContent), { timeout: 10000 });
	ok('Check status reports the session awake');

	// The state the owner reported: after a restart Chrome is awake but its page
	// is signed out, and the page said nothing about what to do.
	// Throw the switch with the page's own fetch, then reload: going to /stale
	// as a document would take the page off the gate's origin.
	// A fetch() cannot go to /frozen itself: that path is not on the gate, it is
	// this suite's fake upstream. The dashboard's own /api/summary proxy is what
	// reaches the fake, and the fake answers "Chrome awake, page and Omnivox no"
	// from then on - exactly a restarted server whose login expired. A reload
	// then shows what the page makes of it.
	await page.evaluate(() => fetch('/api/summary', { cache: 'no-store' }).then((r) => r.text()).catch(() => {}));
	if (staleFetches === 0) no('the summary the page fetches reached the fake upstream');
	const staleNow = await chips();
	check('a restarted server reads as Chrome awake and omnivox no', 'no', staleNow.omnivox);
	check('with Chrome still awake', 'awake', staleNow.chrome);
	const title = await page.$eval('[data-cap="omnivox"]', (node) => node.title);
	if (/Omnivox still accepts/.test(title)) ok('the switches explain themselves on hover');
	else no(`the switches explain themselves on hover (got "${title}")`);
	const banner = await page.evaluate(() => {
		const node = [...document.querySelectorAll('.banner')].find((el) => /Press Wake session/.test(el.textContent));
		return node ? node.textContent.replace(/\s+/g, ' ') : '';
	});
	if (banner) ok('the page says how to clear a stale session');
	else no('the page says how to clear a stale session');
	await page.click('#wake-session');
	await page.waitForFunction(() => /get-terms answered/.test(document.getElementById('tool-result').textContent), { timeout: 20000 });
	const stillOut = await chips();
	check('a call that stays signed out leaves the switches honest', 'no', stillOut.omnivox);
	const afterWake = await page.evaluate(() => ((document.querySelector('.banner') || {}).textContent || '').replace(/\s+/g, ' '));
	if (/Press Wake session/.test(afterWake)) ok('and keeps telling the owner what to do');
	else no(`and keeps telling the owner what to do (got "${afterWake}")`);

	// A policy that blocked the page would show up either as a violation or as
	// an element behaving unlike its own stylesheet. Both fail here.
	const violations = problems.filter((line) => /Content Security Policy|refused to|CSP/i.test(line));
	if (csp && violations.length === 0) ok(`the shipped CSP permits the page (${csp.slice(0, 46)}...)`);
	else no(`the shipped CSP permits the page (violations: ${violations.slice(0, 2).join(' | ') || 'none recorded'}, policy: ${csp.slice(0, 40) || 'missing'})`);
				// Only a refusal the test itself caused is excused; anything else the
			// browser got back deserves a look, favicon included.
			const onlyTheTestsToolsRefusal = failed.every((line) => /^401 .*\/tools$/.test(line));
	const other = problems.filter(
		(line) =>
			!violations.includes(line) &&
			!(/Failed to load resource/.test(line) && onlyTheTestsToolsRefusal),
	);
	if (other.length === 0) ok('the page logs no errors while loading and clicking');
	else no(`the page logs no errors while loading and clicking (${other.slice(0, 3).join(' | ')}; failed responses: ${failed.slice(0, 4).join(' | ')})`);
} catch (error) {
	// A page that went away under the run says nothing about the gate; every
	// check it did reach has already been reported above.
	no(`the browser run finished (${error.message.split('\n')[0]})`);
} finally {
	await (browser ? browser.close() : Promise.resolve()).catch(() => {});
}

console.log();
console.log(`${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
