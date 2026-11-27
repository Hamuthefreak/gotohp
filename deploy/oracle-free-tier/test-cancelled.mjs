#!/usr/bin/env node
/**
 * Proves the cancelled-classes reader on a real Omnivox answer, not on wording.
 *
 *   npx tsx test-cancelled.mjs /opt/omnivox-mcp/app
 *
 * The account has no cancelled classes right now, so the tool can only be seen
 * answering "none" live. This drives the same transformCoursAnnule() the tool
 * calls - imported from the installed tree, not copied - with a pinned
 * /Mobl/CoursAnnule/GetCoursAnnuleModel answer that carries one cancellation,
 * and fails unless the parse returns the course, its slot and the teacher's
 * reason. The empty answer is parsed too, so the "none" branch is shown to come
 * from an empty list rather than from a broken one.
 *
 * Read-only: a JSON file in, text out. Nothing reaches Omnivox.
 */
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const here = path.dirname(new URL(import.meta.url).pathname);
const app = path.resolve(process.argv[2] ?? '/opt/omnivox-mcp/app');
const fixturePath = path.join(here, 'fixtures', 'cancelled-classes.json');
const transformer = path.join(app, 'src', 'mcp', 'transformers', 'courses', 'cancelled.ts');

let failures = 0;
const ok = (message) => console.log(`  ok   ${message}`);
const no = (message) => {
    failures += 1;
    console.log(`  FAIL ${message}`);
};

let transformCoursAnnule;
try {
    ({ transformCoursAnnule } = await import(pathToFileURL(transformer).href));
} catch (error) {
    console.log(`  FAIL could not import the installed transformer at ${transformer}: ${error.message}`);
    process.exit(1);
}
ok('the installed parser is the one this test runs (transformCoursAnnule)');

// ---------------------------------------------------------------- one cancellation
const fixture = JSON.parse(readFileSync(fixturePath, 'utf8'));
const parsed = transformCoursAnnule(fixture);
const list = parsed?.cancelled_classes ?? [];

if (list.length === 1) ok('a payload with one cancellation parses to one cancelled class');
else no(`a payload with one cancellation parsed to ${list.length}, not 1`);

const entry = list[0] ?? {};
const checks = [
    ['the course name', entry.course_name, 'Discrete Mathematics'],
    ['the course and group', entry.course_id, '201-SF5-RE.00001'],
    ['the teacher', entry.teacher, 'Holly A McIntyre'],
    ['the room', (entry.rooms ?? []).join(','), 'B-429'],
    ['the reason the teacher gave', entry.comment, fixture.ListeAnnulationCours[0].CommentaireProf],
];
for (const [what, actual, wanted] of checks) {
    if (actual === wanted) ok(`${what} comes back: ${JSON.stringify(actual)}`);
    else no(`${what} came back as ${JSON.stringify(actual)}, wanted ${JSON.stringify(wanted)}`);
}

// The slot: Omnivox sends the day as a timestamp and the hours as HHmm, so the
// parse has to land on that day at those wall-clock times.
const start = new Date(entry.start ?? 0);
const end = new Date(entry.end ?? 0);
const clock = (d) => `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
if (clock(start) === '14:00' && clock(end) === '15:30') ok('the slot is 14:00-15:30');
else no(`the slot parsed as ${clock(start)}-${clock(end)}, wanted 14:00-15:30`);
const day = new Date(fixture.ListeAnnulationCours[0].DateCoursAnnule);
if (start.getFullYear() === day.getUTCFullYear() && start.getMonth() === day.getUTCMonth() && start.getDate() === day.getUTCDate()) {
    ok(`the day is the one Omnivox sent (${start.toDateString()})`);
} else {
    no(`the day parsed as ${start.toDateString()}, Omnivox sent ${new Date(fixture.ListeAnnulationCours[0].DateCoursAnnule).toDateString()}`);
}
if (typeof entry.id === 'string' && entry.id === fixture.ListeAnnulationCours[0].IDAnnulation) {
    ok('the cancellation keeps its own id');
} else {
    no('the cancellation lost its id');
}

// ---------------------------------------------------------------- the "none" answer
const empty = transformCoursAnnule({ ListeAnnulationCours: [], DateCoursAnnule: fixture.DateCoursAnnule, IndicateurAucunCoursAnnule: true });
if ((empty.cancelled_classes ?? []).length === 0) ok('an empty payload parses to no cancelled classes');
else no('an empty payload produced cancellations');

// The tool's "none" branch is what the live probe shows on this account: it
// prints Omnivox's own IndicateurAucunCoursAnnule, so "none" is checkable. That
// branch needs the real account to run, so what is checked here is that the
// installed tool still carries it - and the deploy log carries its live output.
const toolPath = path.join(app, 'src', 'mcp', 'tools', 'courses', 'cancelled.ts');
const tool = readFileSync(toolPath, 'utf8');
if (tool.includes('IndicateurAucunCoursAnnule') && tool.includes('No cancelled classes')) {
    ok('the installed tool still reports IndicateurAucunCoursAnnule with "No cancelled classes"');
} else {
    no('the installed tool no longer reports the flag beside "No cancelled classes"');
}
if (tool.includes('reading gap')) ok('and still names a list that is empty while the flag says otherwise');
else no('and no longer distinguishes an empty list from a wrongly read one');

console.log(failures === 0
    ? '\ncancelled classes: the real parser returns course, slot and reason, and "none" keeps its evidence'
    : `\n${failures} cancelled-classes check(s) failed`);
process.exit(failures === 0 ? 0 : 1);
