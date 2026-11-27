"""Adds the read tools and fixes upstream does not have to a checked-out omnivox-mcp tree.

    python3 patch-extra-tools.py /opt/omnivox-mcp/app

Why a patch rather than a fork: the installer re-fetches the upstream source on
every deploy (fetch_source), so anything edited by hand disappears - and worse,
comes back as a half old, half new tree. Everything here is re-applied on each
install, is idempotent, and a moved anchor fails the install loudly instead of
quietly shipping fewer tools.

What it adds
  1. Four read tools upstream has no tool for, all `/Mobl/` reads:
       get-college-document-link  a document the college sent (DocMessageCollege)
       get-mio-message-link       a MIO attachment that really exists (Mio)
       get-campus-events          the college's events list (College)
       get-upcoming-schedule      every calendar page until the next N days are covered
  2. `scripts/toolscheck.ts`: imports every tool module and names the one that
     throws on load. A module that throws does not just lose its own tool, it
     exits the server at startup - that is how `delete-mio-message` vanished at
     some point with "Cannot access 'cacheDestandataire' before initialization".
     The installer runs this before restarting anything, so a broken build is
     reported instead of crash-looping.
  3. `read-document`: the text inside a course document, an assignment file, a
     MIO attachment or a college document, so a client reads the solutions
     instead of holding a path it cannot open. It needs one dependency, which
     this patch adds to package.json.
  4. A guard on MIO attachment ids: an attachment id that does not belong to the
     message used to go to Omnivox anyway, which answered a bare 404 for an id
     that was never going to exist. Now the message's own attachment list decides,
     and the answer names what it does have.

Write tools are not touched: nothing here sends, moves, deletes or creates.
"""

import json
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
import { z } from "zod";

// A college document is a file the college pushes to you. It is a DocMessageCollege
export async function GetCollegeDocumentFile(documentId: string) {
    const model: any = await omnivox.postJson('/Mobl/DocMessageCollege/GetDefaultModel', {});
    // Every list the model carries, not the first one that is an array: the
    // documents and the messages are separate lists, and picking one of them
    // hid a listed id from the very tool the list points at.
    const lists = [
        model?.ListeDocumentsMessages?.ListeDocuments,
        model?.ListeDocuments,
        model?.ListeDocument,
        model?.ListeDocumentsMessages,
        model?.ListeMessages,
        model?.ListeMessagesDocuments,
    ];
    const items: any[] = lists.filter(Array.isArray).flat();
    if (!items.length) {
        items.push(...Object.values(model ?? {}).filter((value) => Array.isArray(value)).flat());
    }
    const wanted = documentId.toLowerCase();
    const item = items.find((entry) =>
        [entry?.IDDocument, entry?.IdDocument, entry?.Id, entry?.Guid].some((value) => String(value ?? '').toLowerCase() === wanted)
    );
    if (!item) {
        throw new Error(`No college document with id ${documentId}. Call get-college-documents for the current list.`);
    }

    const raw: string = item.PathFichier ?? item.UrlFichier ?? item.Url ?? '';
    if (!raw.trim() && String(item.NomDocument ?? '').trim()) {
        // Omnivox fills these in already: the text, the file name, the type and
        // size. Nothing is opened in the portal to read them, which matters
        // because opening a document is recorded on the student file.
        const text = [item.Description, item.Commentaire].map((v) => String(v ?? '').trim()).filter(Boolean).join(String.fromCharCode(10, 10));
        const size = Number(item.TailleOctet) > 0 ? ` (${Math.round(Number(item.TailleOctet) / 1024)} KB)` : '';
        return {
            url: '',
            filename: String(item.NomDocument).trim(),
            contentType: item.ContentType || 'application/octet-stream',
            contentDisposition: `attachment; filename="${String(item.NomDocument).trim()}"`,
            text,
            title: String(item.Titre ?? '').trim() || String(item.NomDocument).trim(),
            type: String(item.Extention ?? '').toUpperCase(),
            size,
        };
    }
    if (!raw) {
        // Some entries are notices with no file at all: the listing marks them
        // by type, and there is nothing to fetch.
        // Every field that could carry the file, so an entry whose file hides
        // under a name this code does not know says so instead of "no file".
        const shape = Object.entries(item)
            .filter(([key, value]) => value !== null && value !== '' && typeof value !== 'object' && /path|url|fich|file|doc|ext|type|titre|nom/i.test(key))
            .map(([key, value]) => `${key}=${String(value).slice(0, 40)}`)
            .join(' ');
        const seen = Object.keys(item).sort().join(',') || 'none';
        throw new Error(`College document ${documentId} has no file attached (${String(item.Titre ?? item.NomDocument ?? '').trim() || 'untitled'}; ${shape || 'no file-like field at all'}; fields ${seen}). Call get-college-documents for the ones that do.`);
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

// Ids as the listings print them: any UUID version, since Omnivox does not
// only use v4 and a listed id has to be usable.
const listedIdSchema = z.string().regex(/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/, 'a UUID as the listing prints it');

const input = z.object({
    document_id: listedIdSchema.describe('The document ID listed by get-college-documents.'),
});

mcpServer.registerTool('get-college-document-link',
    {
        title: 'Get College Document',
        description: 'Read the text of a document the college sent you: registration and pre-requisite letters, the course drop and incomplete grade reminders, the midterm assessment notice, the registrar guide. It reads the text Omnivox already has for it and opens nothing in the portal, so it is not the same as opening the notice yourself: it does not acknowledge anything, and a notice with no file says so. document_id comes from get-college-documents. In HTTP mode with MCP_SERVER_URL set it returns a link that expires in 15 minutes; otherwise the file is saved on the server and its path is returned.',
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

        const file: any = await GetCollegeDocumentFile(args.document_id);
        if (!file.url) {
            return {
                content: [{
                    type: 'text',
                    text: [
                        `# ${file.title}`,
                        `File: ${file.filename} (${file.type}${file.size}) - the college does not serve this one as a download, so no file was fetched and nothing was opened.`,
                        '',
                        file.text || 'Omnivox has no text for this document.',
                    ].join(String.fromCharCode(10)),
                }],
            };
        }
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
import { createWebToken } from "src/security/omniWebToken";
import { saveDownload } from "@common/downloads";
import { z } from "zod";

// Ids as the listings print them: any UUID version, since Omnivox does not
// only use v4 and a listed id has to be usable.
const listedIdSchema = z.string().regex(/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/, 'a UUID as the listing prints it');

const input = z.object({
    message_id: listedIdSchema.describe('The MIO message ID from get-mio-messages or read-mio-message.'),
    attachment_id: listedIdSchema.describe('The attachment_id read-mio-message lists under Attachments.'),
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

# The app calendar answers one page per call. "What is on for the next two
# weeks" is not one page: paging stops when an empty page arrives, when the page
# is the first one with nothing in the window, or at a hard cap - so a calendar
# with months of past events still reaches the days the reader asked about.
UPCOMING_SCHEDULE = '''import { GetCalendrierModel } from "@api/Calendrier";
import { mcpServer } from "src/mcp/server";
import { z } from "zod";

const input = z.object({
    days: z.number().int().min(1).max(90).default(7).describe(\'How many days ahead to cover, counted from the start of today (default 7, max 90).\'),
});

const MAX_PAGES = 20;

const startOfToday = () => {
    const d = new Date();
    d.setHours(0, 0, 0, 0);
    return d;
};

const showTime = (ms: number) => {
    if (!Number.isFinite(ms) || ms <= 0) return "";
    const d = new Date(ms);
    return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
};

const showDay = (ms: number) => {
    if (!Number.isFinite(ms) || ms <= 0) return "";
    return new Date(ms).toLocaleDateString("en-CA", { weekday: "short", month: "short", day: "numeric" });
};

const CANCELLED = /annul|cancel/i;

mcpServer.registerTool(\'get-upcoming-schedule\',
    {
        title: \'Get Upcoming Schedule\',
        description: \'What happens over the next N days (default 7): classes, exams, deadlines, holidays and day swaps from the real calendar, covering every page until the window ends. Cancelled classes are marked as cancelled. Read-only.\',
        inputSchema: input,
        annotations: {
            readOnlyHint: true,
            destructiveHint: false,
        },
    },
    async (args) => {
        const days = args.days ?? 7;
        const from = startOfToday().getTime();
        const to = from + days * 86_400_000;
        const seen = new Set<string>();
        const inWindow: any[] = [];
        let pages = 0;
        let reachedEnd = false;

        for (let page = 0; page < MAX_PAGES; page++) {
            const model: any = await GetCalendrierModel(page);
            pages = page + 1;
            const list: any[] = Array.isArray(model?.ListeEvenements) ? model.ListeEvenements : [];
            if (list.length === 0) {
                reachedEnd = true;
                break;
            }
            let afterWindow = 0;
            for (const item of list) {
                const event = item?.Evenement ?? item;
                const start = Number(event?.TimestampDateEvenement);
                if (!Number.isFinite(start) || start <= 0) continue;
                if (start >= to) {
                    afterWindow++;
                    continue;
                }
                const end = Number(event?.TimestampDateFin);
                if (start < from && !(Number.isFinite(end) && end >= from)) continue;
                const key = `${event?.IdEvenement ?? ""}|${start}`;
                if (seen.has(key)) continue;
                seen.add(key);
                inWindow.push({ event, start });
            }
            // The calendar runs forwards in time: a page that has not reached
            // the window end yet is the only reason to ask for another.
            if (afterWindow > 0 || (!model?.IndicateurPageSuivante && page === 0)) {
                reachedEnd = true;
                break;
            }
            if (model?.IndicateurPageSuivante === false) {
                reachedEnd = true;
                break;
            }
        }

        inWindow.sort((a, b) => a.start - b.start);
        const header = `# Next ${days} day${days === 1 ? "" : "s"}: ${inWindow.length} entr${inWindow.length === 1 ? "y" : "ies"}`;
        if (!inWindow.length) {
            return {
                content: [{ type: \'text\', text: `${header}\\nNothing on the calendar for this window.` }],
            };
        }

        const lines = [header, ""];
        if (!reachedEnd) lines.push(`(stopped after ${pages} pages; the window may continue)`, "");
        let day = "";
        for (const { event, start } of inWindow) {
            const heading = showDay(start);
            if (heading !== day) {
                day = heading;
                lines.push(`## ${heading}`);
            }
            const title = String(event?.Titre ?? event?.TitreAng ?? "(untitled)");
            const time = showTime(start);
            const cancelled = CANCELLED.test(title) || CANCELLED.test(String(event?.Type ?? ""));
            const bits = [time ? `${time} ` : "", title, cancelled ? " (cancelled)" : ""];
            const room = event?.Details?.Local ?? event?.Details?.NoLocal;
            if (room) bits.push(` - ${room}`);
            lines.push(`- ${bits.join("")}`);
        }
        return { content: [{ type: \'text\', text: lines.join("\\n") }] };
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

# The half the link tools were missing: the same file, read, instead of a path
# on the server that a client cannot open. It needs one dependency (`unpdf`,
# added to package.json below) and nothing else, and it never writes.
READ_DOCUMENT = r'''import { GetDocumentFichier, GetEnonceTravailFichier, GetDepotTravailFichier, GetCopieCorrigeTravailFichier } from "@api/LeaDownload";
import { GetMioAttachment, ResolveMioAttachment } from "@api/Mio";
import { omnivox } from "../../../omnivox-api/puppet";
import { getDefaultTermId } from "@common/omnivoxHelper";
import { mcpServer } from "src/mcp/server";
import { inflateRawSync } from "node:zlib";
import { z } from "zod";
import { GetCollegeDocumentFile } from "./college-document-link";

// Upstream answers a document request with a path on the server (/or a 15 minute
// link). A client that asks "what does Test 2 say" then holds a path it cannot
// open, which is where reading a document used to stop. This tool is the other
// half: it fetches the same file and returns the text inside it.

const MAX_DEFAULT = 60_000;
const MAX_HARD = 300_000;

const input = z.object({
    source: z.enum(['course-document', 'assignment-file', 'mio-attachment', 'college-document'])
        .describe('Where the file lives: a Lea course document, an assignment file (teacher document, your submission or the correction), a MIO attachment, or a college document.'),
    course_id: z.string().optional().describe('Course id, for source course-document or assignment-file.'),
    document_id: z.string().optional().describe('Document id from get-course-documents (course-document) or get-college-documents (college-document).'),
    assignment_id: z.string().optional().describe('Assignment id from get-course-assignments or get-assignment-detail.'),
    file_id: z.string().optional().describe('File ID printed by get-assignment-detail, with its role.'),
    role: z.enum(['teacher_document', 'submission', 'correction']).optional().describe('Which assignment file file_id is.'),
    message_id: z.string().optional().describe('MIO message id from get-mio-messages or read-mio-message.'),
    attachment_id: z.string().optional().describe('Attachment id read-mio-message lists under Attachments.'),
    term_id: z.string().optional().describe('Term, when not the default one.'),
    max_chars: z.number().int().min(1_000).max(MAX_HARD).optional()
        .describe('How much of the text to return before saying it was cut (default 60000).'),
});

type Args = z.infer<typeof input>;

const NEEDED: Record<Args['source'], (keyof Args)[]> = {
    'course-document': ['course_id', 'document_id'],
    'assignment-file': ['course_id', 'assignment_id', 'file_id', 'role'],
    'mio-attachment': ['message_id', 'attachment_id'],
    'college-document': ['document_id'],
};

const HOW: Record<Args['source'], string> = {
    'course-document': 'Ids come from get-course-documents.',
    'assignment-file': 'Ids and role come from get-assignment-detail.',
    'mio-attachment': 'Ids come from read-mio-message, which lists each attachment with its id.',
    'college-document': 'The id comes from get-college-documents.',
};

function check(args: Args) {
    const missing = NEEDED[args.source].filter((key) => {
        const value = args[key];
        return value === undefined || String(value).trim() === '';
    });
    if (missing.length) {
        throw new Error(`read-document needs ${missing.join(', ')} for source ${args.source}. ${HOW[args.source]}`);
    }
}

// --- reading the bytes Omnivox streams
async function bytes(file: any): Promise<Buffer> {
    const chunks: Buffer[] = [];
    for await (const chunk of file.body) chunks.push(Buffer.from(chunk));
    return Buffer.concat(chunks);
}

const ENTITIES: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' };
const decodeEntities = (text: string) => text.replace(/&(#x?[0-9a-fA-F]+|[a-z]+);/g, (all, body: string) => {
    if (body[0] === '#') {
        const code = body[1] === 'x' || body[1] === 'X' ? parseInt(body.slice(2), 16) : parseInt(body.slice(1), 10);
        return Number.isFinite(code) && code > 0 && code < 0x110000 ? String.fromCodePoint(code) : all;
    }
    return ENTITIES[body.toLowerCase()] ?? all;
});

// .docx is a zip: the central directory says where word/document.xml is and how
// it is packed, so a Word file is read without adding a second library.
function zipEntries(buf: Buffer) {
    let at = -1;
    for (let i = buf.length - 22; i >= Math.max(0, buf.length - 66_000); i--) {
        if (buf.readUInt32LE(i) === 0x06054b50) { at = i; break; }
    }
    if (at === -1) throw new Error('not a zip archive');
    const count = buf.readUInt16LE(at + 10);
    let at2 = buf.readUInt32LE(at + 16);
    const entries = new Map<string, { method: number; compressed: number; localAt: number }>();
    for (let i = 0; i < count; i++) {
        if (buf.readUInt32LE(at2) !== 0x02014b50) break;
        const method = buf.readUInt16LE(at2 + 10);
        const compressed = buf.readUInt32LE(at2 + 20);
        const nameLen = buf.readUInt16LE(at2 + 28);
        const extraLen = buf.readUInt16LE(at2 + 30);
        const commentLen = buf.readUInt16LE(at2 + 32);
        const localAt = buf.readUInt32LE(at2 + 42);
        entries.set(buf.toString('utf8', at2 + 46, at2 + 46 + nameLen), { method, compressed, localAt });
        at2 += 46 + nameLen + extraLen + commentLen;
    }
    return {
        read(name: string) {
            const entry = entries.get(name);
            if (!entry) return undefined;
            const nameLen = buf.readUInt16LE(entry.localAt + 26);
            const extraLen = buf.readUInt16LE(entry.localAt + 28);
            const start = entry.localAt + 30 + nameLen + extraLen;
            const raw = buf.subarray(start, start + entry.compressed);
            return entry.method === 0 ? Buffer.from(raw) : inflateRawSync(raw);
        },
    };
}

const stripWordXml = (xml: string) => decodeEntities(xml
    .replace(/<w:tab\s*\/>/g, '\t')
    .replace(/<w:br\s*\/>/g, '\n')
    .replace(/<\/w:p>/g, '\n')
    .replace(/<[^>]+>/g, ''))
    .replace(/\n{3,}/g, '\n\n');

const htmlToPlain = (html: string) => decodeEntities(html
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<\/(p|div|li|h[1-6]|tr|br)>/gi, '\n')
    .replace(/<[^>]+>/g, ' ')
    .replace(/[ \t]{2,}/g, ' '));

type Extracted = { kind: string; text: string; pages?: number };

async function extractText(buf: Buffer, filename: string, contentType: string): Promise<Extracted> {
    const ext = (filename.match(/\.([a-z0-9]+)$/i)?.[1] ?? '').toLowerCase();
    const type = (contentType || '').toLowerCase();
    if (buf.subarray(0, 4).toString('latin1') === '%PDF' || ext === 'pdf' || type.includes('pdf')) {
        // Loaded here, not at the top of the module: a dependency that cannot
        // load should fail this one call with a message, not exit the server.
        const { extractText: pdfText, getDocumentProxy } = await import('unpdf');
        const pdf = await getDocumentProxy(new Uint8Array(buf));
        const { totalPages, text } = await pdfText(pdf, { mergePages: true });
        return { kind: 'pdf', pages: totalPages, text: String(text ?? '') };
    }
    if (buf.subarray(0, 2).toString('latin1') === 'PK' && (ext === 'docx' || type.includes('wordprocessingml'))) {
        const body = zipEntries(buf).read('word/document.xml');
        if (!body) throw new Error('this .docx carries no word/document.xml');
        return { kind: 'docx', text: stripWordXml(body.toString('utf8')) };
    }
    const textual = ['txt', 'md', 'markdown', 'csv', 'tsv', 'json', 'xml', 'html', 'htm', 'log', 'ics', 'vtt', 'srt', 'yml', 'yaml'].includes(ext)
        || type.startsWith('text/') || type.includes('json') || type.includes('xml');
    if (textual) {
        const text = buf.toString('utf8');
        const markup = ext === 'html' || ext === 'htm' || ext === 'xml' || type.includes('html') || type.includes('xml');
        return { kind: 'text', text: markup ? htmlToPlain(text) : text };
    }
    return { kind: 'binary', text: '' };
}

const kb = (n: number) => `${Math.max(1, Math.round(n / 1024))} KB`;

mcpServer.registerTool('read-document',
    {
        title: 'Read Document',
        description: 'Read what a document says, as text, without a download link or a path on the server: a Lea course document, an assignment file (teacher document, your submission or the correction), a MIO attachment, or a college document. PDFs are extracted page by page, .docx is read too, and plain text, CSV, JSON, HTML and XML come back as they are. source plus that source\'s ids are all it needs, and a file whose format carries no text (an image, a scan, a .doc or .xls) says so instead of guessing. Fetching a Lea document marks it as read on Omnivox, exactly like get-document-link; nothing is sent, moved, deleted or acknowledged.',
        inputSchema: input,
        annotations: {
            readOnlyHint: true,
            destructiveHint: false,
        },
    },
    async (args: Args) => {
        check(args);
        const term = args.term_id || await getDefaultTermId();

        let file: any;
        let label = '';

        if (args.source === 'course-document') {
            file = await GetDocumentFichier(args.course_id as string, args.document_id as string, term);
            label = `course document ${args.document_id} (course ${args.course_id}, term ${term})`;
        } else if (args.source === 'assignment-file') {
            const role = args.role as 'teacher_document' | 'submission' | 'correction';
            const fetch = role === 'submission' ? GetDepotTravailFichier
                : role === 'correction' ? GetCopieCorrigeTravailFichier
                    : GetEnonceTravailFichier;
            file = await fetch(args.course_id as string, args.assignment_id as string, args.file_id as string, term);
            label = `${role.replace('_', ' ')} of assignment ${args.assignment_id} (course ${args.course_id}, term ${term})`;
        } else if (args.source === 'mio-attachment') {
            // The message decides that the attachment is real, before Omnivox is asked.
            await ResolveMioAttachment(args.message_id as string, args.attachment_id as string);
            file = await GetMioAttachment(args.message_id as string, args.attachment_id as string);
            label = `attachment ${args.attachment_id} of MIO message ${args.message_id}`;
        } else {
            const college: any = await GetCollegeDocumentFile(args.document_id as string);
            label = `college document ${args.document_id}`;
            if (!college.url) {
                // Omnivox keeps the text itself for a notice it does not serve
                // as a file: that text is the answer, and nothing is opened.
                return {
                    content: [{
                        type: 'text',
                        text: [`# ${college.title || college.filename}`, `Source: ${label}`, '', college.text || 'Omnivox has no text for this document.'].join('\n'),
                    }],
                };
            }
            file = await omnivox.download(college.url);
            file.filename = file.filename || college.filename;
            file.contentType = file.contentType || college.contentType;
        }

        const buf = await bytes(file);
        const name = String(file.filename ?? `${args.document_id ?? args.file_id ?? args.attachment_id ?? 'document'}.bin`);
        const type = String(file.contentType ?? 'application/octet-stream');
        if (buf.length === 0) {
            return { content: [{ type: 'text', text: `# ${name}\nSource: ${label}\n\nOmnivox answered with an empty file: nothing to read.` }] };
        }

        const found = await extractText(buf, name, type);
        const limit = Math.min(args.max_chars ?? MAX_DEFAULT, MAX_HARD);
        const text = found.text.replace(/\r\n/g, '\n').trim();
        const head = [
            `# ${name}`,
            `${type}, ${kb(buf.length)}${found.pages ? `, ${found.pages} page${found.pages === 1 ? '' : 's'}` : ''}, ${found.kind}`,
            `Source: ${label}`,
            '',
        ];

        if (!text) {
            const why = found.kind === 'pdf'
                ? 'The PDF has no text layer: it is a scan or an image-only export, so the words are pixels and there is nothing to read here.'
                : found.kind === 'binary'
                    ? 'This format carries no text this server can read (an image, a .doc or .xls, an archive).'
                    : 'The file came back empty.';
            return {
                content: [{
                    type: 'text',
                    text: [...head, why, 'The document itself is still there: the matching get-*-link tool returns the file (or a 15 minute link) if a reader that sees pages is needed.'].join('\n'),
                }],
            };
        }

        const cut = text.length > limit;
        const body = cut ? `${text.slice(0, limit)}\n\n[... cut at ${limit} of ${text.length} characters; ask again with a larger max_chars for the rest]` : text;
        return { content: [{ type: 'text', text: [...head, body].join('\n') }] };
    }
);
'''

# ---------------------------------------------------------------- MIO attachment guard

MIO_ANCHOR = '''export function GetMioAttachment(messageId: string, attachmentId: string): Promise<DownloadResult> {'''

MIO_GUARD = '''// An attachment id that is not part of the message used to reach Omnivox anyway,
// which answered a bare "404 instead of sending the file" for an id that was never
// going to exist. The message itself already lists its attachments, so the pair is
// checked here and a wrong one says what the message does have.
export async function ResolveMioAttachment(messageId: string, attachmentId: string) {
    const answer: any = await GetMessage(messageId);
    // The attachments sit on the message itself (MioMessage.Attachements), which
    // is the field upstream's own read-mio-message prints.
    const message: any = answer?.MioMessage ?? answer?.Message ?? answer ?? {};
    const files: any[] =
        message?.Attachements ?? message?.ListeFichiersJoint ?? message?.ListeFichiers ?? message?.Fichiers ?? [];
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
MIO_GUARD_OLD = '''export async function ResolveMioAttachment(messageId: string, attachmentId: string) {
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
        # An earlier version of this patch shipped a call Omnivox does not
        # serve. A box that ran it keeps the old function, so the one this
        # patch defines replaces it instead of being skipped as applied.
        wanted = addition[addition.index('export async function GetListeEvenement'):].rstrip()
        start = src.find('export function GetListeEvenement')
        if start == -1:
            start = src.find('export async function GetListeEvenement')
        end = src.find('\n}\n', start)
        # The function may be the last thing in the file, with no newline after it.
        tail = 3
        if end == -1 and src.rstrip().endswith('}'):
            end = src.rstrip().rfind('\n}')
            tail = len(src) - end
        if start != -1 and end != -1:
            current = src[start:end + tail]
            if current.rstrip() != wanted:
                path.write_text(src[:start] + wanted + src[end + tail:])
                print(f'{label}: replaced the older version')
                return True
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
        ('upcoming-schedule.ts', UPCOMING_SCHEDULE),
        ('read-document.ts', READ_DOCUMENT),
    ):
        path = target / name
        if path.is_file() and path.read_text() == body:
            print(f'tool {name}: already applied')
            continue
        path.write_text(body)
        print(f'tool {name}: written')
    return True


PACKAGE_JSON = 'package.json'
# The PDF text extractor read-document uses: pure JS, no system package, no
# browser. Kept in this patch for the same reason the tools are - fetch_source
# restores package.json on every deploy, so a dependency added by hand would be
# gone by the next one - and the installer's npm install runs after this patch,
# which is what fetches it.
PDF_READER = ('unpdf', '^2.2.3')


def add_pdf_reader(root: pathlib.Path) -> bool:
    path = root / PACKAGE_JSON
    if not path.is_file():
        print(f'pdf reader: {PACKAGE_JSON} is not in the checkout', file=sys.stderr)
        return False
    try:
        data = json.loads(path.read_text())
    except ValueError:
        print(f'pdf reader: {PACKAGE_JSON} is not valid JSON', file=sys.stderr)
        return False
    deps = data.setdefault('dependencies', {})
    if deps.get(PDF_READER[0]) == PDF_READER[1]:
        print(f'pdf reader: {PDF_READER[0]} already in {PACKAGE_JSON}')
        return True
    deps[PDF_READER[0]] = PDF_READER[1]
    data['dependencies'] = dict(sorted(deps.items()))
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + '\n')
    print(f'pdf reader: {PDF_READER[0]} {PDF_READER[1]} added to {PACKAGE_JSON}')
    return True


def main() -> int:
    if len(sys.argv) != 2:
        print('usage: patch-extra-tools.py <app-dir>', file=sys.stderr)
        return 2
    root = pathlib.Path(sys.argv[1])
    ok = add_tool_files(root)
    ok = add_pdf_reader(root) and ok
    # The name alone: "export function GetListeEvenement" is not found in the async
    # version this patch writes, so that marker appended a second copy each run.
    ok = append(root / COLLEGE_REL, EVENTS_REQUEST, 'GetListeEvenement', 'events list') and ok
    # The first guard looked for the attachments on the envelope, where they are
    # not (they sit on MioMessage.Attachements), so it refused every attachment
    # a message really had. A box that ran it keeps that copy unless it is
    # replaced here, not skipped by its marker.
    mio = root / MIO_REL
    if mio.is_file() and MIO_GUARD_OLD in mio.read_text():
        mio.write_text(mio.read_text().replace(MIO_GUARD_OLD, '', 1))
        print('attachment guard: the guard that read the wrong field removed')
    ok = patch_file(root / MIO_REL, MIO_ANCHOR, MIO_GUARD, 'const message: any = answer?.MioMessage', 'attachment guard') and ok
    ok = add_toolcheck_script(root) and ok
    ok = add_entry_hook(root) and ok
    return 0 if ok else 1



PASS_THROUGH_FLAGS = '''
// `npm start -- --kill-others-on-fail`: npm hands its own extra arguments to
// `tsx`, not to the server, so a unit that passes one would either be ignored or
// stop the server from starting. A launcher that understands it is not needed
// here - npm's children already go with it in the unit's mixed cgroup - so the
// flag is accepted and ignored, and `npm start -- <anything else>` still fails
// loudly instead of starting a server that answers nothing.
for (const flag of ['--kill-others-on-fail']) {
    const at = process.argv.indexOf(flag);
    if (at !== -1) process.argv.splice(at, 1);
}
'''

ENTRY_FILE = 'src/index.ts'
# A real line of the hook below, so a second run sees it and stops.
ENTRY_MARKER = "process.argv.splice(at, 1)"


def add_entry_hook(root: pathlib.Path) -> bool:
    # The server's own file, where it is (upstream keeps it as src/index.js).
    # A tree that carries no entry point is reported, not treated as a failure:
    # the hook only lets the unit's pass-through flag be accepted.
    found = [p for p in (root / ENTRY_FILE, root / 'src/index.js') if p.is_file()]
    if not found:
        print(f'entry hook: neither {ENTRY_FILE} nor src/index.js is here, skipped', file=sys.stderr)
        return True
    path = found[0]
    src = path.read_text()
    if ENTRY_MARKER in src:
        print('entry hook: already applied')
        return True
    path.write_text(PASS_THROUGH_FLAGS.lstrip('\n') + '\n' + src)
    print('entry hook: applied')
    return True

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
