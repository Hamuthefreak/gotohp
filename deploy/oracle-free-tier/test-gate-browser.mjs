#!/usr/bin/env node
// Loads a throwaway gatekeeper in real headless Chrome and checks what only a
// browser can show: the stylesheet is applied, the CSP the gate sends is obeyed,
// Copy reaches the clipboard and says so, and Rotate issues a new token that
// works while the old one stops.
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
import { spawn, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

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
if (!chrome || !puppeteer) {
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

// A stand-in for omnivox-mcp: it only answers what the dashboard asks.
const fakeUpstream = `
import http from 'node:http';
http.createServer((req, res) => {
  res.writeHead(200, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ ok: true, browser: true, page: true, omnivox: true, sleeping: true }));
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
const setCookie = login.headers.get('set-cookie') || '';
const pair = setCookie.split(';')[0];
const sessionCookie = { name: pair.slice(0, pair.indexOf('=')), value: pair.slice(pair.indexOf('=') + 1) };
if (sessionCookie.value) ok('the throwaway gate signs the browser in');
else no('the throwaway gate signs the browser in');

const browser = await puppeteer.launch({
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
	const page = await browser.newPage();
	await page.setViewport({ width: 1100, height: 900 });
	await browser.defaultBrowserContext().overridePermissions(base, ['clipboard-read', 'clipboard-write', 'clipboard-sanitized-write']);
	const problems = [];
	// Every request the page itself makes, so a failure the test causes from
	// outside the page can be told apart from one the page causes.
	const pageRequests = [];
	page.on('request', (request) => pageRequests.push(request.url()));
	page.on('pageerror', (error) => problems.push(`pageerror: ${error.message}`));
	page.on('console', (message) => {
		if (message.type() === 'error') problems.push(`console: ${message.text()}`);
	});
	page.on('requestfailed', (request) => problems.push(`requestfailed: ${request.url()}`));

	await page.setCookie({ ...sessionCookie, domain: '127.0.0.1', path: '/', httpOnly: true, sameSite: 'Lax' });

	console.log('in the browser');
	const response = await page.goto(`${base}/`, { waitUntil: 'networkidle0' });
	check('the dashboard loads', 200, response.status());
	const csp = response.headers()['content-security-policy'] || '';
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
	const stillIn = await page.goto(`${base}/`, { waitUntil: 'domcontentloaded' });
	check('rotating does not sign the dashboard out', 200, stillIn.status());
	await page.waitForFunction(() => document.styleSheets.length > 0 && document.getElementById('token'));
	const ruleCount = await page.evaluate(() => document.styleSheets[0].cssRules.length);
	if (ruleCount > 20) ok(`the page after rotating is styled too (${ruleCount} rules)`);
	else no(`the page after rotating is styled too (only ${ruleCount} rules)`);

	// A policy that blocked the page would show up either as a violation or as
	// an element behaving unlike its own stylesheet. Both fail here.
	const violations = problems.filter((line) => /Content Security Policy|refused to|CSP/i.test(line));
	if (csp && violations.length === 0) ok(`the shipped CSP permits the page (${csp.slice(0, 46)}...)`);
	else no(`the shipped CSP permits the page (violations: ${violations.slice(0, 2).join(' | ') || 'none recorded'}, policy: ${csp.slice(0, 40) || 'missing'})`);
	// The test itself asks /tools with the rotated-away token over plain fetch to
	// prove it is dead; Chrome logs that 401 like any other failed resource. The
	// requests the page makes are not fetch, so the page's own errors still fail.
	const other = problems.filter(
		(line) =>
			!violations.includes(line) &&
			!/favicon/i.test(line) &&
			!(/\(Unauthorized\)/.test(line) && pageRequests.some((url) => url.endsWith('/tools'))),
	);
	if (other.length === 0) ok('the page logs no errors while loading and clicking');
	else no(`the page logs no errors while loading and clicking (${other.slice(0, 3).join(' | ')})`);
} catch (error) {
	no(`the browser run finished (${error.message.split('\n')[0]})`);
} finally {
	await browser.close();
}

console.log();
console.log(`${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
