"""Applies the MIO honesty guard to a checked-out omnivox-mcp tree.

    python3 patch-mio-guard.py /opt/omnivox-mcp/app

DeleteMessage, RestoreMessage and AjoutCategorie each end in `.then(r => !!r)`,
and OmnivoxMoblError only looks at NaviguerPage / IsPeriodeArret / IsAvailable.
Measured against the live account on 2026-11-26: DeleteMessage and
RestoreMessage with the all-zeros id, and AjoutCategorie with an empty name, all
answer 200 with an error-free body and change nothing - so `!!r` is true and
delete-mio-message said "1 message(s) moved to trash." about a message that does
not exist. That is a false success.

The fix is not a stricter parser of a body nobody documented; it is proof of
the effect. Delete and restore read the trash count before and after and only
report success when it actually moved. A folder must be named, must not already
exist, and must appear in the folder list afterwards, or it is removed again.
Anything unproven raises with Omnivox's own answer, so the tool fails with the
underlying response instead of claiming work it did not do.

Idempotent, and a moved anchor is a hard error: a deploy must fail loudly
rather than ship a server that still reports false success.
"""

import pathlib
import sys

MIO_REL = 'src/omnivox-api/requests/Mio.ts'

TYPES_OLD = """export function GetListeFoldersModel() {
    return omnivox.postJson<MioFolders.ResponseModel>(
        '/Mobl/Mio/GetListeFoldersModel',
        {}
    );
}"""

TYPES_NEW = """export function GetListeFoldersModel() {
    return omnivox.postJson<MioFolders.ResponseModel>(
        '/Mobl/Mio/GetListeFoldersModel',
        {}
    );
}

// What this guard reads from the list: the trash item a delete or restore
// moves, and the folder names a create has to prove. Structural on purpose, so
// the patch does not depend on the shape of the MIO typings.
type MioFolderItem = { Id?: string; NomCategorie?: string; NbMessageTotal?: number };
type MioFolderList = { ListeFolders?: MioFolderItem[] };

function folderItems(listing: MioFolderList | undefined): MioFolderItem[] {
    return Array.isArray(listing?.ListeFolders) ? listing!.ListeFolders! : [];
}"""

DELETE_OLD = """export function DeleteMessage(messageId: string) {
    return omnivox.postJson<any>(
        '/Mobl/Mio/DeleteMessage',
        {
            "Id": messageId,
            "SupprimerPermanent": false,
            "Envoie": false
        }
    ).then(r => !!r);
}"""

DELETE_NEW = """const TRASH_FOLDER = 'SEARCH_FOLDER_MioSupprimer';

/**
 * Omnivox answers a delete or a restore for an id that does not exist with an
 * error-free body and no change, so the answer alone cannot be trusted. Read
 * the trash count around the call and report success only if it moved.
 */
async function movedTrashCount(messageId: string, run: () => Promise<any>) {
    const before = trashCount(await GetListeFoldersModel());
    const answer = await run();
    const after = trashCount(await GetListeFoldersModel());

    if (after === before) {
        throw new Error(`Omnivox accepted the request for message ${messageId} but the trash still holds ${before} message(s), so nothing moved. The id does not exist or is not in a folder this action can move it from. Omnivox answered: ${JSON.stringify(answer ?? null).slice(0, 300)}`);
    }

    return true;
}

function trashCount(listing: MioFolderList | undefined) {
    const folder = folderItems(listing).find(f => f.Id === TRASH_FOLDER);
    return folder?.NbMessageTotal ?? 0;
}

export async function DeleteMessage(messageId: string) {
    return movedTrashCount(messageId, () => omnivox.postJson<any>(
        '/Mobl/Mio/DeleteMessage',
        {
            "Id": messageId,
            "SupprimerPermanent": false,
            "Envoie": false
        }
    ));
}"""

RESTORE_OLD = """export function RestoreMessage(messageId: string) {
    return omnivox.postJson<any>(
        '/Mobl/Mio/RestoreMessage',
        {
            "Id": messageId,
            "Envoie": false
        }
    ).then(r => !!r);
}"""

RESTORE_NEW = """export async function RestoreMessage(messageId: string) {
    return movedTrashCount(messageId, () => omnivox.postJson<any>(
        '/Mobl/Mio/RestoreMessage',
        {
            "Id": messageId,
            "Envoie": false
        }
    ));
}"""

FOLDER_OLD = """export function AjoutCategorie(nomCategorie: string) {
    return omnivox.postJson<any>(
        '/Mobl/Mio/AjoutCategorie',
        {
            "nomCategorie": nomCategorie
        }
    ).then(r => !!r);
}"""

FOLDER_NEW = """export async function AjoutCategorie(nomCategorie: string) {
    const name = (nomCategorie ?? '').trim();
    if (!name) throw new Error('A folder needs a name: pass the name to create.');

    const existing = folderNames(await GetListeFoldersModel());
    if (existing.some(n => n.toLowerCase() === name.toLowerCase())) {
        throw new Error(`A MIO folder named "${name}" already exists. Pick another name.`);
    }

    const answer = await omnivox.postJson<any>(
        '/Mobl/Mio/AjoutCategorie',
        {
            "nomCategorie": name
        }
    );

    // The request is accepted whether or not the folder is created, so the only
    // proof is the folder list.
    const listing = await GetListeFoldersModel();
    const created = folderItems(listing).find(f => (f.NomCategorie ?? '').toLowerCase() === name.toLowerCase());
    if (created) return true;

    throw new Error(`Omnivox accepted the request for folder "${name}" but the folder list does not contain it, so it was not created. Omnivox answered: ${JSON.stringify(answer ?? null).slice(0, 300)}`);
}

function folderNames(listing: MioFolderList | undefined) {
    return folderItems(listing).map(f => f.NomCategorie ?? '');
}"""

# A marker says "this patch is already in", so it must appear only in that
# patch's own replacement: 'movedTrashCount' appears in the delete guard too and
# made the restore guard skip itself.
PATCHES = [
    (TYPES_OLD, TYPES_NEW, 'function folderItems', 'folder types'),
    (DELETE_OLD, DELETE_NEW, 'movedTrashCount(messageId, () => omnivox.postJson<any>', 'delete guard'),
    (RESTORE_OLD, RESTORE_NEW, 'export async function RestoreMessage', 'restore guard'),
    (FOLDER_OLD, FOLDER_NEW, 'export async function AjoutCategorie', 'create-folder guard'),
]


def patch(path: pathlib.Path, old: str, new: str, marker: str, label: str) -> bool:
    if not path.is_file():
        print(f'{label}: {path} is missing, upstream moved it', file=sys.stderr)
        return False
    src = path.read_text()
    if marker in src:
        print(f'{label}: already applied')
        return True
    # Skipping the patch because of another patch's text would ship the old
    # body, so an anchor that is genuinely still upstream has to be there.
    if old not in src:
        print(f'{label}: anchor not found, patch NOT applied', file=sys.stderr)
        return False
    path.write_text(src.replace(old, new, 1))
    print(f'{label}: applied')
    return True


def main() -> int:
    if len(sys.argv) != 2:
        print('usage: patch-mio-guard.py <app-dir>', file=sys.stderr)
        return 2
    root = pathlib.Path(sys.argv[1])
    ok = True
    for old, new, marker, label in PATCHES:
        ok = patch(root / MIO_REL, old, new, marker, label) and ok
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
