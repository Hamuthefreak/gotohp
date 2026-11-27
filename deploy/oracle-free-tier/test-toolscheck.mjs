#!/usr/bin/env node
// Proves the tool pre-flight (scripts/toolscheck.ts) before it ships: a module
// that throws while it loads must be named, a tree of good modules must pass,
// and a module copied over another colour must be reported as a duplicate.
//
// No box, no Omnivox and no network: a throwaway tree holds stand-ins for the
// upstream files the script imports. The script itself is taken from the patch
// that installs it, so this test fails if the patch stops writing it.

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ovx-toolscheck-'));
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
	if (String(actual) === String(expected)) ok(label);
	else no(`${label} (wanted ${expected}, got ${actual})`);
};

const cleanup = () => fs.rmSync(root, { recursive: true, force: true });
process.on('exit', cleanup);

// The script the patch writes, extracted from the patch itself: this test would
// otherwise keep passing on a copy that no longer matches what ships.
const patchPath = path.join(here, 'patch-extra-tools.py');
const patch = fs.readFileSync(patchPath, 'utf8');
const start = patch.indexOf("TOOLCHECK = '''");
const end = patch.indexOf("'''", start + "TOOLCHECK = '''".length);
if (start < 0 || end < 0) {
	console.log('the patch no longer writes scripts/toolscheck.ts');
	process.exit(1);
}
const toolcheck = patch.slice(start + "TOOLCHECK = '''".length, end);

// A stand-in for src/mcp/server.ts: the script asks it how many tools are
// registered. Tools are registered by importing a module, as the real server
// does, so a module that throws registers nothing and takes the import down.
const serverSrc = `export const mcpServer = { registerTool(name) { mcpServer._registeredTools[name] = { name }; } };
mcpServer._registeredTools = {};`;

const writeTree = (modules) => {
	const tree = fs.mkdtempSync(path.join(root, 'tree-'));
	fs.mkdirSync(path.join(tree, 'src', 'mcp', 'tools', 'courses'), { recursive: true });
	fs.mkdirSync(path.join(tree, 'scripts'), { recursive: true });
	fs.writeFileSync(path.join(tree, 'src', 'mcp', 'server.ts'), serverSrc);
	fs.writeFileSync(path.join(tree, 'scripts', 'toolscheck.ts'), toolcheck);
	for (const [name, body] of Object.entries(modules)) {
		fs.writeFileSync(path.join(tree, 'src', 'mcp', 'tools', 'courses', name), body);
	}
	return tree;
};

const good = (tool) => `import { mcpServer } from '../../server';
mcpServer.registerTool('${tool}', {});
`;
const throwing = `const config = undefined;
throw new Error('Cannot access \\'cacheDestandataire\\' before initialization');
`;

// tsx is a dependency of the upstream checkout, not of this repository; fall
// back to npx so the test still runs on a machine that has only Node.
// The installer installs tsx with the server, so a checkout that has it uses
// that one; anything else asks npx for it.
const runners = [
	process.env.TSX_PATH,
	path.join(here, '..', '..', 'node_modules', '.bin', 'tsx'),
	path.join(here, 'node_modules', '.bin', 'tsx'),
].filter(Boolean);
const runner = runners.find((candidate) => fs.existsSync(candidate));

const runWith = (tree) => {
	if (runner) {
		return spawnSync(runner, ['scripts/toolscheck.ts'], { cwd: tree, encoding: 'utf8' });
	}
	return spawnSync('npx', ['--yes', 'tsx', 'scripts/toolscheck.ts'], { cwd: tree, encoding: 'utf8', shell: false });
};

const clean = writeTree({ 'a.ts': good('get-terms'), 'b.ts': good('get-overview') });
const cleanRun = runWith(clean);
const cleanJson = (() => {
	try {
		return JSON.parse(cleanRun.stdout.trim().split('\n').pop());
	} catch {
		return null;
	}
})();
check('a tree of good modules exits 0', 0, cleanRun.status);
if (cleanJson && cleanJson.ok === true) ok('and reports ok');
else no(`and reports ok (${cleanRun.stdout.trim().slice(0, 160)} ${cleanRun.stderr.trim().slice(0, 160)})`);
check('two modules, two tools', 2, cleanJson?.registered);

const broken = writeTree({ 'a.ts': good('get-terms'), 'delete-mio-message.ts': throwing });
const brokenRun = runWith(broken);
check('a module that throws exits non-zero', 1, brokenRun.status);
let brokenJson = null;
try {
	brokenJson = JSON.parse(brokenRun.stdout.trim().split('\n').pop());
} catch {}
const named = JSON.stringify(brokenJson?.failures || []).includes('delete-mio-message.ts');
if (named) ok('and names the module that throws');
else no(`and names the module that throws (${brokenRun.stdout.trim().slice(0, 200)})`);
check('while still counting the rest', 2, brokenJson?.checked);

// A copied file over an existing colour is not an error on its own, but it means
// the tool list is not what the tree seems to say, so the pre-flight says so.
// Two directories, one file name: the loader would import whichever came last.
const duplicated = writeTree({ 'a.ts': good('get-terms') });
fs.mkdirSync(path.join(duplicated, 'src', 'mcp', 'tools', 'clubs'), { recursive: true });
fs.writeFileSync(path.join(duplicated, 'src', 'mcp', 'tools', 'clubs', 'a.ts'), good('get-overview'));
fs.writeFileSync(path.join(duplicated, 'src', 'mcp', 'tools', 'clubs', 'a.md'), 'notes');
const dupRun = runWith(duplicated);
let dupJson = null;
try {
	dupJson = JSON.parse(dupRun.stdout.trim().split('\n').pop());
} catch {}
check('a duplicated module name exits non-zero', 1, dupRun.status);
if (dupJson && dupJson.unique === 1) ok('and reports the unique names it found');
else no(`and reports the unique names it found (${dupRun.stdout.trim().slice(0, 200)})`);

// The installer has to refuse to ship a server whose tool list is incomplete.
// The probe has to list every tool it will meet, or it reports the server as
// broken for growing. The list in the probe is the one coverage is judged by.
const toolList = fs.readFileSync(path.join(here, 'probe-tools.sh'), 'utf8');
const listed = (toolList.match(/TOOLS = \[([\s\S]*?)\n\]/) || [])[1] || '';
const probeTools = [...listed.matchAll(/'([a-z0-9-]+)'/g)].map((m) => m[1]);
for (const tool of ['get-college-document-link', 'get-mio-message-link', 'get-campus-events', 'get-upcoming-schedule']) {
	if (probeTools.includes(tool)) ok(`the probe calls ${tool}`);
	else no(`the probe calls ${tool}`);
}
check('the probe knows every tool it lists once', probeTools.length, new Set(probeTools).size);

const installer = fs.readFileSync(path.join(here, 'omnivox-mcp.sh'), 'utf8');
const updateBlock = installer.slice(installer.indexOf('do_update()'), installer.indexOf('do_session()'));
if (/toolscheck \|\| warn/.test(updateBlock)) ok('an update runs the pre-flight and warns on failure');
else no('an update runs the pre-flight and warns on failure');

// The deploy ships the current patch and points the installer at it, so the
// patch that runs has to be that file and never a copy left by an earlier
// deploy - a cached copy kept every later fix from ever reaching the box.
const shipped = fs.readFileSync(path.join(here, 'patch-extra-tools.py'), 'utf8');
if (shipped.includes("'/Mobl/College/EvenementsWeb_GetFirstLoad'") && !shipped.includes("'/Mobl/College/ListeEvenement'")) {
	ok('the shipped events patch asks for the endpoint the app uses');
} else no('the shipped events patch asks for the endpoint the app uses');
if (/apply_patch 'extra read tools' "\$\{EXTRA_PATCH_SOURCE:-\$PREFIX\/patches\/patch-extra-tools\.py\}" "\$EXTRA_PATCH_URL" "\$\{EXTRA_PATCH_SOURCE:-\}"/.test(installer)) {
	ok('the installer prefers the shipped patch over its cached copy');
} else no('the installer prefers the shipped patch over its cached copy');
// Every patch the deploy ships has to be the one the box applies. The extra
// read tools' patch was shipped but never named, so the box kept running the
// copy cached from an earlier deploy - a fixed tool that still sent the old
// request, and a probe that reported it as broken.
// The workflow only exists in a checkout of the repo; on the box it is run on
// these files as shipped, and this part is skipped there.
const workflowPath = path.join(here, '../../.github/workflows/deploy-gate.yml');
if (fs.existsSync(workflowPath)) {
	const workflow = fs.readFileSync(workflowPath, 'utf8');
	// The step now runs update under `bash -x` through a pipeline, so the env
	// and the patch name are further apart than a single short window.
	const at = workflow.indexOf('omnivox-mcp.sh update');
	const updateCall = at === -1 ? '' : workflow.slice(Math.max(0, at - 1200), at + 40);
	for (const [variable, file] of [
		['PATCH_SOURCE', 'patch-download-guard.py'],
		['MIO_PATCH_SOURCE', 'patch-mio-guard.py'],
		['EXTRA_PATCH_SOURCE', 'patch-extra-tools.py'],
	]) {
		if (updateCall.includes(`${variable}=/tmp/ovx-gate-ship/${file}`)) ok(`the deploy hands over the current ${file}`);
		else no(`the deploy hands over the current ${file} (${variable} not passed to update)`);
	}
} else {
	console.log(`  skip no checkout here (${workflowPath}), so the deploy's own wiring is checked in CI only`);
}
const applyBlock = installer.slice(installer.indexOf('apply_patch()'), installer.indexOf('\n}\n', installer.indexOf('apply_patch()')));
// A shipped patch is used from the path the deploy wrote, and a patch that was
// never shipped falls back to the cached copy rather than to nothing.
if (/shipped &\& -s \$shipped/.test(installer) && /script=\$shipped/.test(installer)) ok('and uses the shipped path when a source is given');
else no('and uses the shipped path when a source is given');
if (/elif \[\[ ! -s \$script \]\]/.test(installer)) ok('and fetches a copy when nothing was shipped');
else no('and fetches a copy when nothing was shipped');
// The install must say why a patch failed, and must not let a leftover server
// answer for the build it is about to replace.
if (/patch: exit/.test(installer)) ok('a patch failure is echoed with its exit code');
else no('a patch failure is echoed with its exit code');
if (/do_update\(\) \{\n(\t[^\n]*\n)*\tfree_port/.test(installer)) ok('update stops the old server before patching');
else no('update stops the old server before patching');

// The served tool list is read by its own shipped file, and that file has to
// agree with the probe about which tools this deployment adds.
const live = fs.readFileSync(path.join(here, 'toolscheck-live.py'), 'utf8');
for (const tool of ['get-college-document-link', 'get-mio-message-link', 'get-campus-events', 'get-upcoming-schedule']) {
	if (live.includes(`'${tool}'`)) ok(`the served-tool check asks for ${tool}`);
	else no(`the served-tool check asks for ${tool}`);
}
if (/except urllib\.error\.HTTPError/.test(live)) ok('and reports a refused key instead of crashing');
else no('and reports a refused key instead of crashing');
if (/closed port/.test(live)) ok('and proves it can fail against a closed port');
else no('and proves it can fail against a closed port');

console.log();
console.log(`${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
