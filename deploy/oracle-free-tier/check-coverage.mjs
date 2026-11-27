#!/usr/bin/env node
/**
 * Proves COVERAGE.md matches what the server really serves.
 *
 *   node check-coverage.mjs                     # against the pinned live answer
 *   node check-coverage.mjs --tool-list a b c   # against a live /tools answer
 *
 * The ledger is documentation, so the only thing that can go wrong with it is
 * drifting from the server: a tool added upstream with no row, a row for a tool
 * nobody serves, or a category nobody counted. Each of those fails here with
 * the names involved, so a future coverage check cannot quietly claim coverage
 * it does not have.
 */
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const ledgerPath = path.join(here, 'COVERAGE.md');

// The `/tools` answer printed by run 45927975590 (job "Install the gate on the
// relay VM", line "/tools answers 42 tools"), transcribed as printed. The run
// is cited in the ledger, so this fixture and the ledger pin the same thing.
const PINNED_LIVE_TOOLS = `create-mio-folder
delete-mio-message
flag-mio-message
get-absences
get-assignment-detail
get-assignment-file-link
get-assignment-submit-link
get-assignments-summary
get-calendar
get-campus-events
get-cancelled-classes
get-college-document-link
get-college-documents
get-college-list
get-college-news
get-course-announcements
get-course-assignments
get-course-documents
get-course-evals
get-course-info
get-course-people
get-courses-summary
get-document-link
get-grades-summary
get-mio-attachment-link
get-mio-folders
get-mio-message-link
get-mio-messages
get-online-forms
get-overview
get-schedule
get-service-link
get-teachers
get-terms
get-upcoming-schedule
move-mio-message
read-mio-message
reply-mio-message
restore-mio-message
search-mio-messages
search-people
send-mio-message`;

let failures = 0;
function ok(message) {
    console.log(`  ok   ${message}`);
}
let notes = [];
function fail(message) {
    failures += 1;
    notes.push(message);
    console.log(`  FAIL ${message}`);
}

function liveList() {
    const at = process.argv.indexOf('--tool-list');
    const raw = at === -1 ? PINNED_LIVE_TOOLS : process.argv.slice(at + 1).join('\n');
    const names = raw
        .split('\n')
        .map(line => line.trim())
        .filter(Boolean);
    if (names.length === 0) throw new Error('the live tool list is empty');
    return names;
}

// A row for a tool that is in `live` but not in the ledger: the shape the real
// ledger gives a covered tool, so the only gate it can trip is the one about
// names.
function ledgerRows(text) {
    const rows = [];
    for (const line of text.split('\n')) {
        if (!line.startsWith('| `')) continue;
        const cells = line.split('|').slice(1, -1).map(cell => cell.trim());
        if (cells.length !== 5) {
            fail(`a ledger row does not have 5 columns: ${line.slice(0, 90)}`);
            continue;
        }
        const [tool, introduced, exercised, observed, verdict] = cells;
        rows.push({
            tool: tool.replaceAll('`', ''),
            introduced: introduced.replaceAll('`', ''),
            exercised: exercised.replaceAll('`', ''),
            observed,
            verdict,
        });
    }
    return rows;
}

// The three ways this check can be argued with, each a real drift between the
// served list and the ledger. Each carries the thin ledger it is judged against:
// a row for every tool it is meant to cover, so the only gate left to trip is
// the one about that tool's name.
const SELF_TEST = [
    {
        // The server gained a tool and the ledger has no row for it.
        name: 'a served tool with no row',
        live: served => [...served, 'new-upstream-tool'],
        covered: served => served,
        absent: 'new-upstream-tool',
    },
    {
        // The ledger has a row for a tool the server does not serve.
        name: 'a row for a tool nobody serves',
        live: served => served,
        covered: served => [...served, 'get-telepathy'],
        absent: 'get-telepathy',
    },
    {
        // The server stopped serving a tool whose row the ledger still has.
        name: 'one tool fewer than the server serves',
        live: served => served.slice(1),
        covered: served => served.slice(1),
        absent: served => served[0],
    },
];

// The names gates, which are the ones a drift must trip. Anything else firing
// means the thin ledger is wrong, not that coverage is missing.
// A drift can also leave a tool with no evidence call named, which is the same
// gap seen from another angle and not a sign the fixture is wrong.
const NO_EVIDENCE = /^served but no evidence call is named: /;

const NAMES_GATES = [
    'served but not in the ledger',
    'in the ledger but not served',
    'the ledger covers',
];

function thinLedger(live, covered) {
    const rows = covered.map(tool => `| \`${tool}\` | \`6164a1a\` | probe \`${tool}\` | \`200\` | live |`);
    return [
        '# thinning of COVERAGE.md for the self-test',
        '',
        `\`/tools answers ${live.length} tools\``,
        '',
        ...rows,
        '',
        // The same Rollup heading the real ledger uses. It adds up to the live
        // count, so it cannot be what goes red.
        '## Rollup',
        '',
        '| Category | Tools | live | unverified |',
        '| --- | --- | --- | --- |',
        `| Everything | ${live.length} | ${live.length} | 0 |`,
    ].join('\n');
}

function audit(text, live) {
    const liveSet = new Set(live);
    const rows = ledgerRows(text);
    const ledgerTools = new Set(rows.map(row => row.tool));

    console.log(`ledger: ${rows.length} rows over ${ledgerTools.size} tools`);
    console.log(`live:   ${live.length} tools`);

    // Same names, both ways, so a tool with no row and a row with no tool are each
    // named rather than folded into a count.
    const missing = [...liveSet].filter(name => !ledgerTools.has(name));
    const extra = [...ledgerTools].filter(name => !liveSet.has(name));
    if (missing.length) fail(`served but not in the ledger: ${missing.join(', ')}`);
    else ok('every served tool has a row');
    if (extra.length) fail(`in the ledger but not served: ${extra.join(', ')}`);
    if (!extra.length) ok('the ledger lists no tool the server does not serve');

    if (live.length !== liveSet.size) fail('the live list repeats a tool');
    if (ledgerTools.size !== liveSet.size) fail(`the ledger covers ${ledgerTools.size} tools, the server serves ${liveSet.size}`);
    else ok('the ledger tool count is the live count');

    // The count the server itself prints is part of the evidence.
    const stated = text.match(/`\/tools answers (\d+) tools`/);
    if (!stated) fail('the ledger does not cite the /tools answer it was derived from');
    else if (Number(stated[1]) !== live.length) fail(`the ledger cites ${stated[1]} tools, the live list has ${live.length}`);
    else ok(`the ledger cites /tools answers ${stated[1]} tools, which is the live count`);

    // Every tool Omnivox really receives is named somewhere, with a verdict.
    const invoked = new Set();
    for (const row of rows) {
        for (const match of row.exercised.matchAll(/\b([a-z]+(?:-[a-z]+)+)\b/g)) {
            if (liveSet.has(match[1])) invoked.add(match[1]);
        }
    }
    const neverInvoked = [...liveSet].filter(name => !invoked.has(name));
    if (neverInvoked.length) fail(`served but no evidence call is named: ${neverInvoked.join(', ')}`);
    else ok('every served tool names the call that exercised it');

    // A verdict is one of the two words ("empty" called out for an honest "none"),
    // and "unverified" has to say why.
    let badVerdict = 0;
    for (const row of rows) {
        if (row.verdict !== 'live' && !row.verdict.startsWith('live (empty: ') && !row.verdict.startsWith('unverified: ')) {
            badVerdict += 1;
            fail(`${row.tool}: verdict "${row.verdict}" is neither live nor unverified with a reason`);
        }
        if (!row.introduced || !row.observed) {
            badVerdict += 1;
            fail(`${row.tool}: a row needs an introducing commit and an observed result`);
        }
    }
    if (!badVerdict) ok('every row says live, live (empty) or unverified and why');

    // A tool with any unverified row is not live-confirmed as a whole. An empty
    // answer still reached Omnivox, so it counts as live but says so.
    const unverified = new Set(rows.filter(row => row.verdict.startsWith('unverified')).map(row => row.tool));
    const empty = new Set(rows.filter(row => row.verdict.startsWith('live (empty: ')).map(row => row.tool));
    const liveOnly = [...liveSet].filter(name => !unverified.has(name));

    // The rollup has to add up to the same list.
    const rollupSection = text.split('## Rollup')[1]?.split('\n## ')[0] ?? '';
    const rollup = [...rollupSection.matchAll(/^\| ([^|]+?) \| (\d+) \| (\d+) \| (\d+) \|$/gm)]
        .filter(match => !match[1].startsWith('---') && !match[1].startsWith('Served') && match[1] !== 'Category');
    const rollupTotal = rollup.reduce((sum, match) => sum + Number(match[2]), 0);
    if (rollup.length === 0) fail('the ledger has no per-category rollup');
    else if (rollupTotal !== liveSet.size) fail(`the rollup counts ${rollupTotal} tools, the server serves ${liveSet.size}`);
    else ok(`the rollup counts ${rollupTotal} tools, one per served tool`);

    const rollupLive = rollup.reduce((sum, match) => sum + Number(match[3]), 0);
    const rollupUnverified = rollup.reduce((sum, match) => sum + Number(match[4]), 0);
    if (rollupLive !== liveOnly.length) fail(`the rollup says ${rollupLive} live tools, the rows say ${liveOnly.length}`);
    else ok(`the rollup says ${rollupLive} live tools, which the rows agree with`);
    if (rollupUnverified !== unverified.size) fail(`the rollup says ${rollupUnverified} unverified tools, the rows say ${unverified.size}`);
    else ok(`the rollup says ${rollupUnverified} unverified tools, which the rows agree with`);

    return { count: liveSet.size, liveOnly, unverified, empty };
}

const text = readFileSync(ledgerPath, 'utf8');

// --self-test: the three ways the ledger can drift from the server, each a thin
// ledger built here so the only thing left to disagree about is that drift.
if (process.argv.includes('--self-test')) {
    const base = liveList();
    const realLog = console.log;
    const quiet = () => {};

    function judge(ledgerText, served) {
        failures = 0;
        notes = [];
        console.log = quiet;
        try {
            audit(ledgerText, served);
        } catch (error) {
            notes.push(`threw: ${error.message}`);
        }
        console.log = realLog;
        return notes.slice();
    }

    const cases = [
        // The server gained a tool and the ledger has no row for it.
        ['a served tool with no row', [...base, 'new-upstream-tool'], base, 'new-upstream-tool'],
        // The ledger has a row for a tool that is not served.
        ['a row for a tool nobody serves', base, [...base, 'get-telepathy'], 'get-telepathy'],
        // The server lost the first tool and the ledger still has only the rest;
        // the ledger row for it was removed along with the row's tool.
        ['the ledger drops a tool the server serves', base, base.slice(1), base[0]],
        // The server lost a tool the ledger still covers: the served list is
        // missing base[0] while the ledger keeps every row.
        ['one tool fewer than the server serves', base.slice(1), base, base[0]],
    ];

    const clean = judge(text, base);
    if (clean.length) {
        realLog(`self-test: the ledger does not match the live list (${clean[0]}), so no drift can be judged`);
        process.exit(1);
    }
    realLog('self-test  the ledger matches the live list, no fault      exit 0  ok');

    let missed = 0;
    for (const [name, served, covered, blame] of cases) {
        const ledger = thinLedger(served, covered);
        const caught = judge(ledger, served);
        const went = caught.some(note => note.includes(`: ${blame}`));
        if (!went) missed += 1;
        realLog(`self-test  ${name.padEnd(46)} exit ${went ? 1 : 0}  ${went ? 'names the tool' : 'NOT CAUGHT'}  ${went ? 'ok' : '<-- FAIL'}`);
        for (const note of caught) realLog(`           ${note}`);
    }
    realLog(missed === 0
        ? '\nself-test: the check goes red, naming the tool, for every drift'
        : `\nself-test: ${missed} drift(s) went unreported`);
    process.exit(missed === 0 ? 0 : 1);
}

const live = liveList();
const { count, liveOnly, unverified, empty } = audit(text, live);

console.log(failures === 0
    ? `\ncoverage: ${count} of ${count} served tools, ${liveOnly.length} live-confirmed (${empty.size} of them answering "none"), ${unverified.size} unverified`
    : `\n${failures} coverage check(s) failed`);
process.exit(failures === 0 ? 0 : 1);
