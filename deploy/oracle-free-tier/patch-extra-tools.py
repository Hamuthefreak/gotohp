"""Adds the read tools and fixes upstream does not have to a checked-out omnivox-mcp tree.

    python3 patch-extra-tools.py /opt/omnivox-mcp/app

Why a patch rather than a fork: the installer re-fetches the upstream source on
every deploy (fetch_source), so anything edited by hand disappears - and worse,
comes back as a half old, half new tree. Everything here is re-applied on each
install, is idempotent, and a moved anchor fails the install loudly instead of
quietly shipping fewer tools.

What it adds
  1. Three read tools upstream has no tool for, all `/Mobl/` reads:
       get-college-document-link  a document the college sent (DocMessageCollege)
       get-mio-message-link       a MIO attachment that really exists (Mio)
       get-campus-events          the college's events list (College)
  2. `scripts/toolscheck.ts`: imports every tool module and names the one that
     throws on load. A module that throws does not just lose its own tool, it
     exits the server at startup - that is how `delete-mio-message` vanished at
     some point with "Cannot access 'cacheDestandataire' before initialization".
     The installer runs this before restarting anything, so a broken build is
     reported instead of crash-looping.
  3. A guard on MIO attachment ids: an attachment id that does not belong to the
     message used to go to Omnivox anyway, which answered a bare 404 for an id
     that was never going to exist. Now the message's own attachment list decides,
     and the answer names what it does have.

Write tools are not touched: nothing here sends, moves, deletes or creates.
"""

import pathlib
import sys

COLLEGE_REL = 'src/omnivox-api/requests/College.ts'
MIO_REL = 'src/omnivox-api/requests/Mio.ts'
TOOLS_DIR = 'src/mcp/tools/extra'

# ---------------------------------------------------------------- read tools

COLLEGE_DOCUMENT_LINK = '''import { omnivox } from "../../../omnivox-api/puppet";
import { mcpServer } from "src/mcp/server";
import { isHttpMode } from "@common/transportMode";
import { createWebToken } from "src/security/omniWebToken";
import { saveDownload } from "@common/downloads";
import { messageIdSchema } from "@common/validation";
import { z } from "zod";

// A college document is a file the college pushes to you. It is a DocMessageCollege
// entry, not a Lea document, so get-document-link cannot fetch it.
export async function GetCollegeDocumentFile(documentId: string) {
    const model: any = await omnivox.postJson('/Mobl/DocMessageCollege/GetDefaultModel', {});
    const lists = [
        model?.ListeDocumentsMessages?.ListeDocuments,
        model?.ListeDocuments,
        model?.ListeDocument,
    ];
    const items: any[] = lists.find(Array.isArray) ?? [];
    const wanted = documentId.toLowerCase();
    const item = items.find((entry) =>
        [entry?.IDDocument, entry?.IdDocument, entry?.Id, entry?.Guid].some((value) => String(value ?? '').toLowerCase() === wanted)
    );
    if (!item) {
        throw new Error(`No college document with id ${documentId}. Call get-college-documents for the current list.`);
    }

    const raw: string = item.PathFichier ?? item.UrlFichier ?? item.Url ?? '';
    if (!raw) {
        // Some entries are notices with no file at all: the listing marks them
        // by type, and there is nothing to fetch.
        throw new Error(`College document ${documentId} has no file attached (${String(item.Titre ?? item.NomDocument ?? '').trim() || 'untitled'}; type ${item.TypeDocument ?? '?'}). Call get-college-documents for the ones that do.`);
    }

    const page = await omnivox.page();
    const name = `${String(item.Titre ?? item.NomDocument ?? documentId).trim().replace(/[<>:"/\\|?*]/g, '_')}${item.Extention ? `.${item.Extention}` : ''}`;
    return {
        url: new URL(raw, page.url()).toString(),
        filename: name,
        contentType: item.ContentType || 'application/octet-stream',
        contentDisposition: `attachment; filename="${name}"`,
    };
}

const input = z.object({
    document_id: messageIdSchema.describe('The document ID listed by get-college-documents.'),
});

mcpServer.registerTool('get-college-document-link',
    {
        title: 'Get College Document',
        description: 'Fetch the file of a document the college sent you: registration and pre-requisite letters, the course drop and incomplete grade reminders, the midterm assessment notice, the registrar guide. document_id comes from get-college-documents. In HTTP mode with MCP_SERVER_URL set it returns a link that expires in 15 minutes; otherwise the file is saved on the server and its path is returned.',
        inputSchema: input,
        annotations: {
            readOnlyHint: true,
            destructiveHint: false,
        },
    },
    async (args) => {
        const serverBaseUrl = process.env.MCP_SERVER_URL;
        if (isHttpMode() && serverBaseUrl) {
            const token = createWebToken({ type: 'college-document', documentId: args.document_id });
            return {
                content: [{ type: 'text', text: `Download link (expires in 15 minutes): ${serverBaseUrl}/download/college-document?token=${token}` }],
            };
        }

        const file = await GetCollegeDocumentFile(args.document_id);
        const saved = await saveDownload(file as any, `${args.document_id}.bin`);
        return {
            content: [{ type: 'text', text: `File saved to: ${saved}` }],
        };
    }
);
'''

MIO_MESSAGE_LINK = '''import { GetMioAttachment, ResolveMioAttachment } from "@api/Mio";
import { mcpServer } from "src/mcp/server";
import { isHttpMode } from "@common/transportMode";
import { messageIdSchema } from "@common/validation";
import { createWebToken } from "src/security/omniWebToken";
import { saveDownload } from "@common/downloads";
import { z } from "zod";

const input = z.object({
    message_id: messageIdSchema.describe('The MIO message ID from get-mio-messages or read-mio-message.'),
    attachment_id: messageIdSchema.describe('The attachment_id read-mio-message lists under Attachments.'),
});

mcpServer.registerTool('get-mio-message-link',
    {
        title: 'Get MIO Attachment',
        description: 'Fetch one attachment of a MIO message (posters, PDFs, spreadsheets). Both ids come from read-mio-message, which lists every attachment with its attachment_id. An attachment id that does not belong to the message is refused with the list of ones that do, before anything is asked of Omnivox. In HTTP mode with MCP_SERVER_URL set it returns a link that expires in 15 minutes; otherwise the file is saved on the server.',
        inputSchema: input,
        annotations: {
            readOnlyHint: true,
            destructiveHint: false,
        },
    },
    async (args) => {
        // The message, not Omnivox, decides: a wrong pair answers a bare 404.
        await ResolveMioAttachment(args.message_id, args.attachment_id);

        const serverBaseUrl = process.env.MCP_SERVER_URL;
        if (isHttpMode() && serverBaseUrl) {
            const token = createWebToken({
                type: 'mio-attachment',
                messageId: args.message_id,
                attachmentId: args.attachment_id,
            });
            return {
                content: [{ type: 'text', text: `Download link (expires in 15 minutes): ${serverBaseUrl}/download/mio-attachment?token=${token}` }],
            };
        }

        const file = await GetMioAttachment(args.message_id, args.attachment_id);
        const saved = await saveDownload(file, `${args.attachment_id}.bin`);
        return {
            content: [{ type: 'text', text: `File saved to: ${saved}` }],
        };
    }
);
'''

CAMPUS_EVENTS = '''import { GetListeEvenement } from "@api/College";
import { htmlToText, toDisplayDate } from "@common/transformHelpers";
import { mcpServer } from "src/mcp/server";
import { z } from "zod";

const input = z.object({
    count: z.number().int().min(1).max(50).optional().describe('How many events to return (default 20, max 50).'),
});

const when = (value: any) => {
    const ms = Number(value);
    if (!Number.isFinite(ms) || ms <= 0) return undefined;
    return toDisplayDate(ms);
};

mcpServer.registerTool('get-campus-events',
    {
        title: 'Get Campus Events',
        description: 'Events on the college calendar (talks, open houses, closures, activities), with their start and end from the same call the app calendar makes. Read-only.',
        inputSchema: input,
        annotations: {
            readOnlyHint: true,
            destructiveHint: false,
        },
    },
    async (args) => {
        const events = await GetListeEvenement(args.count ?? 20);
        const list: any[] = Array.isArray(events) ? events : [];
        if (list.length === 0) {
            return {
                content: [{ type: 'text', text: '# Campus events\\nThe college lists no events right now.' }],
            };
        }

        const lines = [`# Campus events (${list.length})`, '', 'The college calendar lists past events too; each one says when it has finished.', ''];
        for (const event of list) {
            const title = event?.Titre ?? event?.NomEvenement ?? event?.Nom ?? event?.TitreEvenement ?? '(untitled event)';
            lines.push(`## ${title}`);
            const start = when(event?.TimestampDateEvenement ?? event?.DateDebut ?? event?.DateEvenement ?? event?.Date);
            const end = when(event?.TimestampDateFin ?? event?.DateFin);
            if (start) lines.push(`- When: ${start}${end ? ` to ${end}` : ''}`);
            if (event?.EstTermine === true) lines.push('- Finished: yes');
            const where = event?.Lieu ?? event?.Local ?? event?.Endroit;
            if (where) lines.push(`- Where: ${where}`);
            const text = htmlToText(event?.Description ?? event?.Texte ?? event?.Contenu ?? event?.Resume);
            if (text) lines.push(`- ${text.trim().slice(0, 500)}`);
            if (event?.IdEvenement ?? event?.Id) lines.push(`- ID: ${event.IdEvenement ?? event.Id}`);
            lines.push('');
        }

        return {
            content: [{ type: 'text', text: lines.join('\\n') }],
        };
    }
);
'''

EVENTS_REQUEST = '''

// The college calendar's first page - the same call the app's own calendar
// makes, read only. It answers an envelope whose ListeEvenements each wrap an
// Evenement; nothing in the app called it yet, so `get-campus-events` is the
// first reader.
export async function GetListeEvenement(count: number = 20) {
    const model: any = await omnivox.postJson('/Mobl/College/EvenementsWeb_GetFirstLoad', {});
    const entries: any[] = Array.isArray(model?.ListeEvenements) ? model.ListeEvenements : [];
    return entries.map((entry: any) => entry?.Evenement ?? entry).filter(Boolean).slice(0, Math.max(1, count));
}
'''

# ---------------------------------------------------------------- MIO attachment guard

MIO_ANCHOR = '''export function GetMioAttachment(messageId: string, attachmentId: string): Promise<DownloadResult> {'''

MIO_GUARD = '''// An attachment id that is not part of the message used to reach Omnivox anyway,
// which answered a bare "404 instead of sending the file" for an id that was never
// going to exist. The message itself already lists its attachments, so the pair is
// checked here and a wrong one says what the message does have.
export async function ResolveMioAttachment(messageId: string, attachmentId: string) {
    const message: any = await GetMessage(messageId);
    const files: any[] =
        message?.ListeFichiersJoint ?? message?.ListeFichiers ?? message?.Fichiers ?? message?.ListeAttachements ?? [];
    const wanted = attachmentId.toLowerCase();
    const match = files.find((file) =>
        [file?.IDFichierAttachement, file?.IdFichierAttachement, file?.Id, file?.Guid].some(
            (value) => String(value ?? '').toLowerCase() === wanted
        )
    );
    if (!match) {
        const listed = files
            .map((file) => `${file?.NomFichier ?? file?.Nom ?? 'attachment'} (${file?.IdFichierAttachement ?? file?.IdFichier ?? 'no id'})`)
            .join(', ');
        throw new Error(
            `Message ${messageId} has no attachment ${attachmentId}. It lists: ${listed || 'no attachments'}. ` +
            'Attachment ids come from read-mio-message.'
        );
    }
    return match;
}

'''

# ---------------------------------------------------------------- toolscheck

# A module that throws on load does not just lose its own tool: src/index imports
# the tool list at startup and never catches it, so the whole server exits (seen
# with `delete-mio-message` and "Cannot access 'cacheDestandataire' before
# initialization", and again here with a deliberately broken module). The install
# therefore cannot ask a running server; it asks this script, before the server is
# ever started, so a broken build is reported instead of crash-looping.
TOOLCHECK_FILE = 'scripts/toolscheck.ts'

TOOLCHECK = '''// Prints { ok, checked, registered, unique, failures } for every tool module,
// without starting the server: `npx tsx scripts/toolscheck.ts`. A module that throws while it loads
// registers none of its tools and exits the server at startup, so the installer
// runs this first and refuses a build whose tool list would be incomplete.
import * as fs from 'fs';
import * as path from 'path';
import { createRequire } from 'module';

const require = createRequire(import.meta.url);
const root = path.join(process.cwd(), 'src', 'mcp', 'tools');

const files: string[] = [];
const walk = (dir: string) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) walk(full);
        else if (entry.name.endsWith('.ts') || entry.name.endsWith('.js')) files.push(full);
    }
};
walk(root);

const failures: { file: string; error: string }[] = [];
for (const file of files.sort()) {
    try {
        require(file);
    } catch (error: any) {
        failures.push({
            file: path.relative(process.cwd(), file),
            error: String(error?.message ?? error).slice(0, 300),
        });
    }
}

const { mcpServer } = require(path.join(process.cwd(), 'src', 'mcp', 'server'));
const registered = Object.keys((mcpServer as any)._registeredTools ?? {}).length;
const unique = new Set(files.map((file) => path.basename(file, path.extname(file))));
const duplicate = files.length !== unique.size;
console.log(
    JSON.stringify({ ok: failures.length === 0 && registered > 0 && !duplicate, checked: files.length, registered, unique: unique.size, failures }),
);
process.exit(failures.length === 0 && !duplicate ? 0 : 1);
'''

def patch_file(path: pathlib.Path, anchor: str, addition: str, marker: str, label: str) -> bool:
    if not path.is_file():
        print(f'{label}: {path} is missing, upstream moved it', file=sys.stderr)
        return False
    src = path.read_text()
    if marker in src:
        print(f'{label}: already applied')
        return True
    if anchor not in src:
        print(f'{label}: anchor not found, patch NOT applied', file=sys.stderr)
        return False
    path.write_text(src.replace(anchor, addition + anchor, 1))
    print(f'{label}: applied')
    return True


def append(path: pathlib.Path, addition: str, marker: str, label: str) -> bool:
    if not path.is_file():
        print(f'{label}: {path} is missing, upstream moved it', file=sys.stderr)
        return False
    src = path.read_text()
    if marker in src:
        print(f'{label}: already applied')
        return True
    path.write_text(src.rstrip() + '\n' + addition)
    print(f'{label}: applied')
    return True


def add_tool_files(root: pathlib.Path) -> bool:
    target = root / TOOLS_DIR
    target.mkdir(parents=True, exist_ok=True)
    for name, body in (
        ('college-document-link.ts', COLLEGE_DOCUMENT_LINK),
        ('mio-message-link.ts', MIO_MESSAGE_LINK),
        ('campus-events.ts', CAMPUS_EVENTS),
    ):
        path = target / name
        if path.is_file() and path.read_text() == body:
            print(f'tool {name}: already applied')
            continue
        path.write_text(body)
        print(f'tool {name}: written')
    return True


def main() -> int:
    if len(sys.argv) != 2:
        print('usage: patch-extra-tools.py <app-dir>', file=sys.stderr)
        return 2
    root = pathlib.Path(sys.argv[1])
    ok = add_tool_files(root)
    ok = append(root / COLLEGE_REL, EVENTS_REQUEST, 'export function GetListeEvenement', 'events list') and ok
    ok = patch_file(root / MIO_REL, MIO_ANCHOR, MIO_GUARD, 'export async function ResolveMioAttachment', 'attachment guard') and ok
    ok = add_toolcheck_script(root) and ok
    return 0 if ok else 1


def add_toolcheck_script(root: pathlib.Path) -> bool:
    path = root / TOOLCHECK_FILE
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_file() and path.read_text() == TOOLCHECK:
        print('toolscheck script: already applied')
        return True
    path.write_text(TOOLCHECK)
    print('toolscheck script: written')
    return True


if __name__ == '__main__':
    raise SystemExit(main())
