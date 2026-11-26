#!/usr/bin/env node
// The public face of omnivox-mcp: a login-protected dashboard plus a bearer-token
// MCP proxy. It listens on loopback, and cloudflared puts it on the internet.
//
//   /                  dashboard (password login, first run asks for one)
//   /mcp, /sse, ...    proxied to the MCP server with its access key injected
//   /tools, /tools/:t  proxied the same way
//   /healthz           public, no secrets, for tunnel checks
//
// The browser never sees the Omnivox access key: the gatekeeper holds it and the
// dashboard only ever shows the gatekeeper's own token, which can be rotated.
//
// Node 20+, no dependencies.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFile } from 'node:child_process';

const PORT = Number(process.env.PORT || 8080);
const UPSTREAM = process.env.UPSTREAM || 'http://127.0.0.1:3000';
const DATA_DIR = process.env.DATA_DIR || '/opt/omnivox-mcp/gate';
const KEY_FILE = process.env.OMNIVOX_KEY_FILE || '/opt/omnivox-mcp/data/accessKey.txt';
const USERNAME = process.env.GATE_USERNAME || '2652532';
const PUBLIC_URL = (process.env.PUBLIC_URL || '').replace(/\/+$/, '');
const CLOUDFLARED_LOG = process.env.CLOUDFLARED_LOG || path.join(DATA_DIR, 'cloudflared.log');
const HTTPS = process.env.GATE_HTTPS === '1';
const SESSION_TTL = 12 * 60 * 60 * 1000;
const BODY_LIMIT = 32 * 1024;

// Every switch lives under /api, so nothing else can be mistaken for one.
const API = '/api/';

// The dashboard carries no inline style or script any more, so this needs no
// 'unsafe-inline'; the MCP proxy answers with whatever upstream sends.
const CSP = "default-src 'none'; style-src 'self'; script-src 'self'; img-src 'self' data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'";

const FILES = {
	auth: path.join(DATA_DIR, 'auth.json'),
	secret: path.join(DATA_DIR, 'session.key'),
	token: path.join(DATA_DIR, 'token.txt'),
	code: path.join(DATA_DIR, 'setup-code.txt'),
};

// ---------------------------------------------------------------- small helpers

function ensureDir() {
	fs.mkdirSync(DATA_DIR, { recursive: true, mode: 0o700 });
}

function readFileTrim(file, fallback = '') {
	try {
		return fs.readFileSync(file, 'utf8').trim();
	} catch {
		return fallback;
	}
}

function writePrivate(file, value) {
	const tmp = `${file}.${process.pid}.tmp`;
	fs.writeFileSync(tmp, `${value}\n`, { mode: 0o600 });
	fs.renameSync(tmp, file);
}

// A secret this service owns: create it once, keep it private afterwards.
function ensureSecret(file, bytes = 32) {
	const existing = readFileTrim(file);
	if (existing.length >= 16) return existing;
	const value = crypto.randomBytes(bytes).toString('hex');
	writePrivate(file, value);
	return value;
}

function sha(value) {
	return crypto.createHash('sha256').update(String(value)).digest();
}

// Length-independent compare, so a wrong token cannot be guessed byte by byte.
function sameSecret(given, expected) {
	if (typeof given !== 'string' || !given) return false;
	return crypto.timingSafeEqual(sha(given), sha(expected));
}

function hashPassword(password, salt = crypto.randomBytes(16).toString('hex')) {
	const hash = crypto.scryptSync(password, salt, 64).toString('hex');
	return { salt, hash };
}

function checkPassword(password, stored) {
	if (!stored?.salt || !stored?.hash) return false;
	const { hash } = hashPassword(password, stored.salt);
	return crypto.timingSafeEqual(Buffer.from(hash, 'hex'), Buffer.from(stored.hash, 'hex'));
}

function state() {
	let auth = null;
	try {
		auth = JSON.parse(fs.readFileSync(FILES.auth, 'utf8'));
	} catch {
		auth = null;
	}
	return {
		auth,
		hasPassword: Boolean(auth?.hash),
		token: readFileTrim(FILES.token),
		setupCode: readFileTrim(FILES.code),
	};
}

export function hasPassword() {
	return state().hasPassword;
}

// ---------------------------------------------------------------- sessions

ensureDir();
const secret = ensureSecret(FILES.secret);

function b64url(buf) {
	return Buffer.from(buf).toString('base64Url');
}

function signSession(user) {
	const payload = b64url(JSON.stringify({ u: user, exp: Date.now() + SESSION_TTL }));
	const mac = b64url(crypto.createHmac('sha256', secret).update(payload).digest());
	return `${payload}.${mac}`;
}

function readSession(cookieHeader) {
	const raw = cookieValue(cookieHeader, 'ovx_session');
	if (!raw) return null;
	const [payload, mac] = raw.split('.');
	if (!payload || !mac) return null;
	const expect = b64url(crypto.createHmac('sha256', secret).update(payload).digest());
	if (!crypto.timingSafeEqual(sha(mac), sha(expect))) return null;
	try {
		const data = JSON.parse(Buffer.from(payload, 'base64Url').toString('utf8'));
		if (!data?.u || !data?.exp || data.exp < Date.now()) return null;
		return { user: data.u, exp: data.exp };
	} catch {
		return null;
	}
}

function cookieValue(header, name) {
	for (const part of String(header || '').split(';')) {
		const [key, ...rest] = part.trim().split('=');
		if (key === name) return rest.join('=');
	}
	return '';
}

function sessionCookie(value, maxAgeSeconds = SESSION_TTL / 1000) {
	const bits = [`ovx_session=${value}`, 'Path=/', 'HttpOnly', 'SameSite=Lax', `Max-Age=${Math.floor(maxAgeSeconds)}`];
	if (HTTPS) bits.push('Secure');
	return bits.join('; ');
}

// ---------------------------------------------------------------- rate limiting

const attempts = new Map();

function tooManyAttempts(ip) {
	const record = attempts.get(ip);
	return Boolean(record) && record.count >= 10 && Date.now() <= record.reset;
}

// Counted for wrong credentials only, so a correct sign-in never spends the
// budget and ten typos inside a session cannot lock the owner out of a page
// they are already entitled to see.
function recordFailure(ip) {
	const now = Date.now();
	const record = attempts.get(ip) || { count: 0, reset: now + 10 * 60 * 1000 };
	if (now > record.reset) {
		record.count = 0;
		record.reset = now + 10 * 60 * 1000;
	}
	record.count += 1;
	attempts.set(ip, record);
}

function clearAttempts(ip) {
	attempts.delete(ip);
}

// ---------------------------------------------------------------- HTTP plumbing

function send(res, status, body, headers = {}) {
	const isObject = body !== null && typeof body === 'object';
	const payload = isObject ? JSON.stringify(body) : String(body);
	res.writeHead(status, {
		'Content-Type': isObject ? 'application/json; charset=utf-8' : 'text/plain; charset=utf-8',
		'Content-Length': Buffer.byteLength(payload),
		'Cache-Control': 'no-store',
		'Content-Security-Policy': CSP,
		'X-Content-Type-Options': 'nosniff',
		'Referrer-Policy': 'no-referrer',
		...headers,
	});
	res.end(payload);
}

function redirect(res, location, headers = {}) {
	res.writeHead(303, { Location: location, 'Cache-Control': 'no-store', ...headers });
	res.end();
}

function html(res, status, markup) {
	send(res, status, markup, { 'Content-Type': 'text/html; charset=utf-8' });
}

function readBody(req) {
	return new Promise((resolve, reject) => {
		let size = 0;
		const chunks = [];
		req.on('data', (chunk) => {
			size += chunk.length;
			if (size > BODY_LIMIT) {
				reject(new Error('body too large'));
				req.destroy();
				return;
			}
			chunks.push(chunk);
		});
		req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
		req.on('error', reject);
	});
}

async function readForm(req) {
	const raw = await readBody(req);
	const type = String(req.headers['content-type'] || '');
	if (type.includes('application/json')) {
		try {
			return JSON.parse(raw || '{}');
		} catch {
			return {};
		}
	}
	return Object.fromEntries(new URLSearchParams(raw));
}

function sameOrigin(req) {
	const origin = req.headers.origin;
	// curl and MCP clients send no Origin, and a browser form on a no-referrer
	// page sends the literal "null" for its own origin. Refusing that would
	// break every button on the dashboard; the session cookie's SameSite and
	// this host compare still turn away anything another site sends.
	if (!origin || origin === 'null') return true;
	try {
		return new URL(origin).host === req.headers.host;
	} catch {
		return false;
	}
}

function clientIp(req) {
	return String(req.headers['cf-connecting-ip'] || req.socket.remoteAddress || '');
}

// ---------------------------------------------------------------- secrets and keys

function omnivoxKey() {
	return readFileTrim(KEY_FILE);
}

function ensureToken() {
	const current = readFileTrim(FILES.token);
	if (current.length >= 32) return current;
	const next = crypto.randomBytes(32).toString('hex');
	writePrivate(FILES.token, next);
	return next;
}

function ensureSetupCode() {
	const current = readFileTrim(FILES.code);
	if (current) return current;
	const next = crypto.randomBytes(5).toString('hex');
	writePrivate(FILES.code, next);
	return next;
}

// ---------------------------------------------------------------- host facts

function systemdUnit(unit) {
	return new Promise((resolve) => {
		execFile('systemctl', ['is-active', unit], { timeout: 2000 }, (err, stdout) => {
			resolve(String(stdout || '').trim() || (err ? 'unknown' : 'inactive'));
		});
	});
}

function diskFree() {
	try {
		const s = fs.statfsSync('/');
		return { free: s.bavail * s.bsize, total: s.blocks * s.bsize };
	} catch {
		return null;
	}
}

function memory() {
	try {
		const text = fs.readFileSync('/proc/meminfo', 'utf8');
		const grab = (name) => Number((text.match(new RegExp(`^${name}:\\s+(\\d+)`, 'm')) || [])[1] || 0) * 1024;
		return { total: grab('MemTotal'), available: grab('MemAvailable') };
	} catch {
		return null;
	}
}

function upstreamHealth() {
	const key = omnivoxKey();
	return new Promise((resolve) => {
		const url = new URL('/health', UPSTREAM);
		const req = http.request(
			{
				hostname: url.hostname,
				port: url.port,
				path: url.pathname,
				method: 'GET',
				timeout: 5000,
				headers: key ? { 'x-mcp-auth': key } : {},
			},
			(res) => {
				const chunks = [];
				res.on('data', (c) => chunks.push(c));
				res.on('end', () => {
					const text = Buffer.concat(chunks).toString('utf8');
					let body = null;
					try {
						body = JSON.parse(text);
					} catch {
						body = { raw: text.slice(0, 200) };
					}
					resolve({ status: res.statusCode, body });
				});
			},
		);
		req.on('timeout', () => req.destroy(new Error('timeout')));
		req.on('error', (error) => resolve({ status: 0, body: { error: error.message } }));
		req.end();
	});
}

// The latest URL cloudflared announced, or '' when it has not yet.
function tunnelUrl() {
	if (PUBLIC_URL) return PUBLIC_URL;
	const remembered = readFileTrim(path.join(DATA_DIR, 'tunnel-url.txt'));
	let text = '';
	try {
		const stat = fs.statSync(CLOUDFLARED_LOG);
		const start = Math.max(0, stat.size - 16384);
		const fd = fs.openSync(CLOUDFLARED_LOG, 'r');
		const buffer = Buffer.alloc(stat.size - start);
		fs.readSync(fd, buffer, 0, buffer.length, start);
		fs.closeSync(fd);
		text = buffer.toString('utf8');
	} catch {
		return remembered;
	}
	const matches = text.match(/https:\/\/[a-z0-9][a-z0-9-]*\.trycloudflare\.com/gi);
	if (!matches?.length) return remembered;
	return matches[matches.length - 1].toLowerCase();
}

// ---------------------------------------------------------------- proxy

function proxy(req, res) {
	const key = omnivoxKey();
	if (!key) {
		send(res, 503, { error: 'The Omnivox session key is missing on the server' });
		return;
	}
	const target = new URL(UPSTREAM);
	// The client's own credential never travels further than this process, not
	// even as a query parameter the upstream log would keep.
	const forwarded = new URL(req.url, 'http://gate.local');
	forwarded.searchParams.delete('key');
	const upstreamPath = forwarded.pathname + forwarded.search;
	const headers = { ...req.headers };
	for (const name of ['authorization', 'x-mcp-auth', 'cookie', 'host', 'cf-connecting-ip', 'cf-ray', 'cf-visitor', 'x-forwarded-for', 'x-forwarded-proto']) {
		delete headers[name];
	}
	headers['x-mcp-auth'] = key;
	headers.host = target.host;

	const upstream = http.request(
		{
			hostname: target.hostname,
			port: target.port || 80,
			path: upstreamPath,
			method: req.method,
			headers,
		},
		(upstreamRes) => {
			res.writeHead(upstreamRes.statusCode || 502, upstreamRes.headers);
			upstreamRes.pipe(res);
		},
	);
	upstream.on('error', (error) => {
		if (!res.headersSent) send(res, 502, { error: `MCP server unreachable: ${error.message}` });
		else res.end();
	});
	req.on('aborted', () => upstream.destroy());
	req.pipe(upstream);
}

function bearerOk(req, url) {
	const state_ = state();
	const header = String(req.headers.authorization || '');
	const bearer = /^bearer\s+(.+)$/i.exec(header)?.[1];
	const given = req.headers['x-mcp-auth'] || bearer || url.searchParams.get('key');
	return sameSecret(typeof given === 'string' ? given : '', state_.token);
}

// ---------------------------------------------------------------- pages

const STYLE = `
:root{--bg:#0b0f14;--panel:#121821;--line:#1f2937;--ink:#e6edf7;--muted:#8b9bb4;--accent:#3ddc97;--warn:#f4a259;--bad:#ef6461}
*{box-sizing:border-box}
body{margin:0;background:radial-gradient(1200px 600px at 20% -10%,#152233 0%,var(--bg) 55%);color:var(--ink);
font:15px/1.55 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;min-height:100vh}
main{max-width:900px;margin:0 auto;padding:40px 22px 70px}
.brand{display:flex;align-items:center;gap:12px;margin-bottom:26px}
.dot{width:10px;height:10px;border-radius:50%;background:var(--accent);box-shadow:0 0 0 4px rgba(61,220,151,.14)}
h1{font-size:20px;margin:0;letter-spacing:.2px}
h2{font-size:13px;text-transform:uppercase;letter-spacing:.12em;color:var(--muted);margin:30px 0 10px;font-weight:600}
.card{background:linear-gradient(180deg,rgba(255,255,255,.03),rgba(255,255,255,0)) ,var(--panel);border:1px solid var(--line);border-radius:14px;padding:18px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px}
.kv{font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:.08em}
.val{font-size:18px;margin-top:4px;font-variant-numeric:tabular-nums}
.chip{display:inline-flex;align-items:center;gap:6px;border:1px solid var(--line);border-radius:999px;padding:4px 10px;font-size:12px;color:var(--muted);margin:0 6px 6px 0}
.chip b{color:var(--ink);font-weight:600}
.ok{color:var(--accent)}.bad{color:var(--bad)}.warn{color:var(--warn)}
code,pre{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
pre{background:#0a0e13;border:1px solid var(--line);border-radius:10px;padding:12px;overflow:auto;font-size:12.5px}
.row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
input{width:100%;padding:11px 12px;border-radius:10px;border:1px solid var(--line);background:#0a0e13;color:var(--ink);font:inherit}
label{display:block;font-size:12.5px;color:var(--muted);margin:12px 0 6px}
button{padding:10px 14px;border-radius:10px;border:1px solid var(--line);background:#18202b;color:var(--ink);font:inherit;cursor:pointer}
button.primary{background:var(--accent);color:#062015;border-color:transparent;font-weight:650}
button:hover{filter:brightness(1.08)}
.muted{color:var(--muted)}.small{font-size:12.5px}
a{color:var(--accent)}
.token{display:flex;gap:8px;align-items:center}
.token input{font-family:ui-monospace,monospace;letter-spacing:.02em}
.banner{border:1px solid #3a2b18;background:#1d1608;color:var(--warn);padding:10px 12px;border-radius:10px;font-size:13px;margin-bottom:16px}
`;

// Every interactive bit the page had inline, now a real file so the page can
// carry a Content-Security-Policy without 'unsafe-inline'.
const SCRIPT = `
for (const box of document.querySelectorAll('[data-copy]')) {
  box.addEventListener('click', async () => {
    const field = document.getElementById(box.dataset.copy);
    if (!field) return;
    try {
      await navigator.clipboard.writeText(field.value);
      const was = box.textContent;
      box.textContent = 'Copied';
      setTimeout(() => { box.textContent = was; }, 1500);
    } catch { field.select(); }
  });
}
for (const form of document.querySelectorAll('form[data-confirm]')) {
  form.addEventListener('submit', (event) => {
    if (!window.confirm(form.dataset.confirm)) event.preventDefault();
  });
}
`;

function layout(title, body, script = '') {
	return `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow">
<title>${title}</title><link rel="stylesheet" href="/assets/app.css"></head><body><main>${body}</main>${
		script ? `<script src="${script}" defer></script>` : ''
	}</body></html>`;
}

function loginPage(error = '') {
	return layout(
		'Sign in',
		`<div class="brand"><span class="dot"></span><h1>Omnivox</h1></div>
    <div class="card">
      <h1>Sign in</h1>
      <p class="muted small">The dashboard for the Omnivox MCP server on this box.</p>
      ${error ? `<div class="banner">${error}</div>` : ''}
      <form method="post" action="/login">
        <label for="u">Username</label>
        <input id="u" name="username" value="${USERNAME}" autocomplete="username" readonly>
        <label for="p">Password</label>
        <input id="p" name="password" type="password" autocomplete="current-password" autofocus>
        <div class="row" style="margin-top:16px"><button class="primary" type="submit">Sign in</button></div>
      </form>
    </div>`,
	);
}

function setupPage(error = '') {
	return layout(
		'First run',
		`<div class="brand"><span class="dot"></span><h1>Omnivox</h1></div>
    <div class="card">
      <h1>Set a password</h1>
      <p class="muted small">This is the first run. Choose the password for <b>${USERNAME}</b>; it protects the
      dashboard and the MCP token. The setup code is printed by the installer on the server
      (<code>setup-code.txt</code>) and stops working the moment this form succeeds.</p>
      ${error ? `<div class="banner">${error}</div>` : ''}
      <form method="post" action="/setup">
        <label for="u">Username</label>
        <input id="u" value="${USERNAME}" readonly>
        <label for="c">Setup code</label>
        <input id="c" name="code" autocomplete="one-time-code" autofocus>
        <label for="p">New password (12 characters or more)</label>
        <input id="p" name="password" type="password" autocomplete="new-password">
        <label for="p2">Repeat it</label>
        <input id="p2" name="password2" type="password" autocomplete="new-password">
        		        <div class="row" style="margin-top:16px"><button class="primary" type="submit">Set password</button></div>
      </form>
    </div>`,
		'/assets/setup.js',
	);
}

function dashboardPage(summary) {
	const caps = summary.upstream.body || {};
	const chip = (label, value) =>
		`<span class="chip">${label} <b class="${value === true ? 'ok' : value === false ? 'bad' : ''}">${value === true ? 'yes' : value === false ? 'no' : String(value)}</b></span>`;
	const gb = (bytes) => `${(bytes / 1024 / 1024 / 1024).toFixed(1)} GB`;
	return layout(
		'Omnivox',
		`<div class="brand"><span class="dot"></span><h1>Omnivox MCP</h1>
     <span class="muted small" style="margin-left:auto">${summary.user}</span></div>

    <h2>Service</h2>
    <div class="card">
      <div class="row">${chip('MCP server', caps.ok === true)}${chip('Browser', caps.browser === true)}${chip('Page', caps.page === true)}${chip('Omnivox session', caps.omnivox === true)}${chip('Chrome', caps.sleeping === true ? 'asleep' : 'awake')}</div>
      <div class="grid" style="margin-top:14px">
        <div><div class="kv">mcp unit</div><div class="val ${summary.units.mcp === 'active' ? 'ok' : 'bad'}">${summary.units.mcp}</div></div>
        <div><div class="kv">photo relay</div><div class="val ${summary.units.relay === 'active' ? 'ok' : 'bad'}">${summary.units.relay}</div></div>
        <div><div class="kv">disk free</div><div class="val">${summary.disk ? gb(summary.disk.free) : 'n/a'}</div></div>
        <div><div class="kv">memory free</div><div class="val">${summary.memory ? `${Math.round(summary.memory.available / 1024 / 1024)} MB` : 'n/a'}</div></div>
      </div>
      <p class="muted small" style="margin:14px 0 0">Health answered ${
				summary.upstream.status === 200 ? '200' : `HTTP ${summary.upstream.status}`
			}; Chrome asleep means the next request wakes it in about 20 seconds.</p>
    </div>

    <h2>MCP endpoint</h2>
    <div class="card">
      <div class="kv">URL</div>
      <pre style="margin:6px 0 14px">${summary.mcpUrl || 'The tunnel is still starting - reload in a moment.'}</pre>${
				summary.mcpUrl
					? ''
					: `<form method="post" action="${API}tunnel/refresh" style="margin:0 0 12px"><button type="submit" id="tunnel-refresh">Look again</button></form>`
			}
      <div class="kv">Bearer token</div>
      <div class="token" style="margin:8px 0 4px">
        <input id="token" value="${summary.token}" readonly>
        <button type="button" data-copy="token">Copy</button>
      </div>
      <p class="muted small">Send it as <code>Authorization: Bearer &lt;token&gt;</code> to the URL above. Rotating it
      signs every client out; the dashboard stays signed in.</p>
      <div class="row" style="margin-top:12px">
        <form method="post" action="${API}token/rotate" data-confirm="Rotate the token? Every client using the old one stops working.">
          <button type="submit">Rotate token</button>
        </form>
        <form method="post" action="/logout"><button type="submit">Sign out</button></form>
      </div>
    </div>

    <h2>Client configuration</h2>
    <div class="card">
      <p class="muted small" style="margin-top:0">For clients that take a URL and a header (Codebuff, Claude Code, Cursor, any MCP over HTTP client):</p>
      <pre>{
  "mcpServers": {
    "omnivox": {
      "type": "http",
      "url": "${summary.mcpUrl || 'https://<your-tunnel>/mcp'}",
      "headers": { "Authorization": "Bearer ${summary.tokenSlice}" }
    }
  }
}</pre>
      <p class="muted small">For clients that only speak stdio, run <code>npx mcp-remote &lt;url&gt; --header "Authorization: Bearer $TOKEN"</code>.</p>
    </div>`,
		'/assets/setup.js',
	);
}

// ---------------------------------------------------------------- routes

async function handle(req, res) {
	const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
	const method = req.method || 'GET';
	const session = readSession(req.headers.cookie);
	const st = state();

	if (url.pathname === '/healthz') {
		return send(res, 200, { ok: true, uptime: Math.round(process.uptime()) });
	}

	// The page is served under that exact path, never passed to the proxy.
	if (url.pathname === '/assets/app.css') {
		return send(res, 200, STYLE, { 'Content-Type': 'text/css; charset=utf-8', 'Cache-Control': 'public, max-age=3600' });
	}

	if (url.pathname === '/assets/setup.js') {
		return send(res, 200, SCRIPT, { 'Content-Type': 'text/javascript; charset=utf-8', 'Cache-Control': 'public, max-age=3600' });
	}

	if (url.pathname === '/setup') {
		if (st.hasPassword) return redirect(res, '/login');
		if (method === 'GET') return html(res, 200, setupPage());
		if (method !== 'POST') return send(res, 405, { error: 'method not allowed' });
		if (!sameOrigin(req)) return send(res, 403, { error: 'cross-origin request refused' });
		const form = await readForm(req);
		const code = String(form.code || '').trim();
		const password = String(form.password || '');
		if (!sameSecret(code, ensureSetupCode())) return html(res, 403, setupPage('That setup code is not right.'));
		if (password.length < 12) return html(res, 400, setupPage('Use at least 12 characters.'));
		if (password !== String(form.password2 || '')) return html(res, 400, setupPage('The two passwords differ.'));
		const { salt, hash } = hashPassword(password);
		fs.mkdirSync(DATA_DIR, { recursive: true, mode: 0o700 });
		writePrivate(FILES.auth, JSON.stringify({ user: USERNAME, salt, hash, created: new Date().toISOString() }, null, 2));
		try {
			fs.unlinkSync(FILES.code);
		} catch {}
		ensureToken();
		return redirect(res, '/', { 'Set-Cookie': sessionCookie(signSession(USERNAME)) });
	}

	if (url.pathname === '/login') {
		if (!st.hasPassword) return redirect(res, '/setup');
		if (method === 'GET') return html(res, 200, loginPage());
		if (method !== 'POST') return send(res, 405, { error: 'method not allowed' });
		if (!sameOrigin(req)) return send(res, 403, { error: 'cross-origin request refused' });
		const ip = clientIp(req);
		if (tooManyAttempts(ip)) return html(res, 429, loginPage('Too many attempts. Wait ten minutes.'));
		const form = await readForm(req);
		const ok = String(form.username || '') === st.auth.user && checkPassword(String(form.password || ''), st.auth);
		if (!ok) {
			recordFailure(ip);
			return html(res, 401, loginPage('Wrong username or password.'));
		}
		clearAttempts(ip);
		return redirect(res, '/', { 'Set-Cookie': sessionCookie(signSession(st.auth.user)) });
	}

	if (url.pathname === '/logout') {
		return redirect(res, '/login', { 'Set-Cookie': sessionCookie('', 0) });
	}

	if (url.pathname === '/') {
		if (!st.hasPassword) return redirect(res, '/setup');
		if (!session) return redirect(res, '/login');
		const token = ensureToken();
		const summary = {
			user: session.user,
			mcpUrl: tunnelUrl() ? `${tunnelUrl()}/mcp` : '',
			token,
			tokenSlice: `${token.slice(0, 6)}…`,
			upstream: await upstreamHealth(),
			units: { mcp: await systemdUnit('omnivox-mcp.service'), relay: await systemdUnit('gotohp-sync.timer') },
			disk: diskFree(),
			memory: memory(),
			uptime: Math.round(process.uptime()),
		};
		return html(res, 200, dashboardPage(summary));
	}

	if (url.pathname === '/api/tunnel/refresh') {
		if (!session) return send(res, 401, { error: 'sign in first' });
		if (method !== 'POST') return send(res, 405, { error: 'method not allowed' });
		if (!sameOrigin(req)) return send(res, 403, { error: 'cross-origin request refused' });
		const found = tunnelUrl();
		// The tunnel prints its name once; remember it so a later restart of the
		// gatekeeper does not have to race the log to show it again.
		if (found) writePrivate(path.join(DATA_DIR, 'tunnel-url.txt'), found);
		return redirect(res, '/');
	}

	if (url.pathname === '/api/summary') {
		if (!session) return send(res, 401, { error: 'sign in first' });
		return send(res, 200, {
			user: session.user,
			mcpUrl: tunnelUrl() ? `${tunnelUrl()}/mcp` : '',
			token: ensureToken(),
			upstream: await upstreamHealth(),
			units: { mcp: await systemdUnit('omnivox-mcp.service'), relay: await systemdUnit('gotohp-sync.timer') },
			disk: diskFree(),
			memory: memory(),
			uptime: Math.round(process.uptime()),
		});
	}

	if (url.pathname === '/api/token/rotate') {
		if (!session) return send(res, 401, { error: 'sign in first' });
		if (!sameOrigin(req)) return send(res, 403, { error: 'cross-origin request refused' });
		const next = crypto.randomBytes(32).toString('hex');
		writePrivate(FILES.token, next);
		return redirect(res, '/');
	}

	// Everything else is the MCP server: /mcp, /sse, /messages, /tools, /download...
	// A dashboard switch that reaches here is a typo, not an MCP call.
	if (url.pathname.startsWith(API)) {
		return send(res, 404, { error: `no such dashboard endpoint: ${url.pathname}` });
	}
	if (!bearerOk(req, url)) {
		return send(res, 401, { error: 'Send Authorization: Bearer <token>' }, { 'WWW-Authenticate': 'Bearer realm="omnivox"' });
	}
	return proxy(req, res);
}

function createServer() {
	ensureDir();
	ensureSecret(FILES.secret);
	ensureToken();
	if (!hasPassword()) ensureSetupCode();
	return http.createServer((req, res) => {
		handle(req, res).catch((error) => {
			if (!res.headersSent) send(res, 500, { error: error.message });
			else res.end();
		});
	});
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === path.resolve(new URL(import.meta.url).pathname);
if (isMain) {
	createServer().listen(PORT, '127.0.0.1', () => {
		const st = state();
		console.log(`gate listening on http://127.0.0.1:${PORT}`);
		console.log(`upstream ${UPSTREAM}, data ${DATA_DIR}`);
		if (!st.hasPassword) console.log(`first run: password not set, setup code is ${st.setupCode}`);
	});
} else {
	// imported by the tests
}

export { createServer, hashPassword, checkPassword, signSession, readSession, tunnelUrl };
