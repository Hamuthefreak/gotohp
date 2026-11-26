// Runs the MIO guard against a stub of Omnivox, so its honest behaviour is
// proved off the live account.
//
//   node check-mio-guard.mjs <patched app dir>
//
// The patched Mio.ts is written into a temp dir and its imports are replaced by
// stubs, so no @api alias, config or browser is needed. Node's module hooks load
// the file as-is; .ts loading needs Node 22.18+ (the deploy box runs 22). The
// stub answers the way Omnivox does: a delete or restore for a real id moves the
// trash count, for an impossible id it answers 200 and changes nothing, and a
// folder create is accepted whether or not the folder lands.

import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const app = path.resolve(process.argv[2] ?? '');
const real = readFileSync(path.join(app, 'src/omnivox-api/requests/Mio.ts'), 'utf8');
assert.ok(real.includes('movedTrashCount'), 'the MIO guard is not applied to Mio.ts');

// The patched file is exercised on its own, so its imports are stripped and a
// stub Omnivox is injected instead. The patch never touches an import line, and
// the real module graph is compiled on the box by the deploy itself.
// One import can wrap onto a second line (import { omnivox, DownloadResult } from
// "../puppet"), so the whole statement is matched up to its semicolon.
const source = real.replace(/^import[\s\S]*?from\s+['"][^'"]+['"];?[ \t]*$/gm, '')
    .replace(/\bomnivox\./g, 'globalThis.__stub.');

const dir = mkdtempSync(path.join(tmpdir(), 'mio-guard-'));
const file = path.join(dir, 'Mio.ts');
writeFileSync(path.join(dir, 'package.json'), '{"type":"module"}');
writeFileSync(file, source);

const folders = {
    ListeFolders: [
        { Id: 'SEARCH_FOLDER_MioRecu', NomCategorie: 'Inbox', NbMessageTotal: 114 },
        { Id: 'SEARCH_FOLDER_MioEnvoye', NomCategorie: 'Sent messages', NbMessageTotal: 15 },
        { Id: 'SEARCH_FOLDER_MioSupprimer', NomCategorie: 'Deleted Items', NbMessageTotal: 0 },
    ],
};

const state = { calls: [], createAccepted: true };
const REAL = '11111111-1111-1111-1111-111111111111';
const BOGUS = '00000000-0000-0000-0000-000000000000';
const trash = () => folders.ListeFolders.find((f) => f.Id === 'SEARCH_FOLDER_MioSupprimer');

globalThis.__stub = {
    async postJson(url, payload) {
        state.calls.push({ url, payload });
        switch (url) {
            case '/Mobl/Mio/GetListeFoldersModel':
                return structuredClone(folders);
            case '/Mobl/Mio/DeleteMessage':
                if (payload.Id === REAL) trash().NbMessageTotal += 1;
                return '';
            case '/Mobl/Mio/RestoreMessage':
                if (payload.Id === REAL) trash().NbMessageTotal -= 1;
                return '';
            case '/Mobl/Mio/AjoutCategorie':
                if (state.createAccepted) {
                    folders.ListeFolders.push({
                        Id: 'SEARCH_FOLDER_Custom_' + folders.ListeFolders.length,
                        NomCategorie: payload.nomCategorie,
                        NbMessageTotal: 0,
                    });
                }
                return '';
            default:
                throw new Error(`unexpected ${url}`);
        }
    },
    async download() {
        throw new Error('not used');
    },
};

const { DeleteMessage, RestoreMessage, AjoutCategorie } = await import(pathToFileURL(file).href);

let bad = 0;
const check = (label, fn) => {
    try {
        fn();
        console.log(`  ok   ${label}`);
    } catch (err) {
        bad += 1;
        console.log(`  FAIL ${label} (${err.message})`);
    }
};
const rejects = async (label, run, needle) => {
    try {
        await run();
        bad += 1;
        console.log(`  FAIL ${label} (resolved; the call has to fail)`);
    } catch (err) {
        if (needle && !err.message.includes(needle)) {
            bad += 1;
            console.log(`  FAIL ${label} (message does not say "${needle}": ${err.message})`);
        } else {
            console.log(`  ok   ${label}`);
        }
    }
};

console.log('delete-mio-message');
state.calls.length = 0;
await rejects('an impossible id fails instead of claiming a delete', () => DeleteMessage(BOGUS), 'nothing moved');
check('the impossible id is named in the failure', () =>
    assert.ok(state.calls.some((c) => c.url === '/Mobl/Mio/DeleteMessage')));
check('the trash count did not move', () => assert.equal(trash().NbMessageTotal, 0));
await DeleteMessage(REAL);
check('a real id moves the count and is reported as done', () => assert.equal(trash().NbMessageTotal, 1));

console.log('restore-mio-message');
// A restore moves the trash count down, so it only has room to move when the
// trash holds something: with 1 in trash a bogus restore would show 0 -> 1 and
// the guard could mistake the line count for proof. Prove the impossible id
// with an empty trash, which is the state it can actually be checked in.
trash().NbMessageTotal = 0;
await rejects('an impossible id fails instead of claiming a restore', () => RestoreMessage(BOGUS), 'nothing moved');
check('the trash count did not move', () => assert.equal(trash().NbMessageTotal, 0));
trash().NbMessageTotal = 1;
await RestoreMessage(REAL);
check('a real id brings it back', () => assert.equal(trash().NbMessageTotal, 0));

console.log('create-mio-folder');
await rejects('an empty name is refused before anything is sent', () => AjoutCategorie(''), 'needs a name');
await rejects('a blank name is refused too', () => AjoutCategorie('   '), 'needs a name');
check('neither refusal reached Omnivox', () =>
    assert.equal(state.calls.filter((c) => c.url === '/Mobl/Mio/AjoutCategorie').length, 0));
await rejects('an existing folder name is refused', () => AjoutCategorie('Inbox'), 'already exists');
state.createAccepted = false;
await rejects('an accepted create that lands nothing fails, not succeeds', () => AjoutCategorie('probe-check'), 'not created');
state.createAccepted = true;
await AjoutCategorie('probe-check');
check('a create that appears in the list is reported as done', () =>
    assert.ok(folders.ListeFolders.some((f) => f.NomCategorie === 'probe-check')));

console.log('');
if (bad) {
    console.log(`${bad} check(s) failed`);
    process.exit(1);
}
console.log('the MIO guard reports only work it can see');
