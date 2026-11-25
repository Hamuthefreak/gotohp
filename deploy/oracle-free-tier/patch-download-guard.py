"""Applies the download guards to a checked-out omnivox-mcp tree.

    python3 patch-download-guard.py /opt/omnivox-mcp/app

Omnivox answers a document or attachment id that does not exist with HTTP 200
and an error document named Error.txt, and upstream's downloader only rejects
HTML when the response was redirected. So a typo was saved into the downloads
folder and reported as "File saved to: .../Error.txt" - a broken call that looks
exactly like a working one.

Two independent guards, because the error page does not always come back as
text/html (the first version of this patch assumed it did and missed it):

  1. fetchDownload refuses a response that has no file name, or one the server
     only uses for errors.
  2. saveDownload reads back what it wrote and deletes it if the bytes are an
     HTML page, whatever the header said.

The install path re-fetches the source on every run, so this is re-applied there
instead of being a one-off edit that the next install would erase. Both patches
are idempotent, and a moved anchor is a hard error: a deploy must fail loudly
rather than ship an unfixed downloader.
"""

import pathlib
import sys

FETCH_REL = 'src/omnivox-api/puppet/download.ts'
SAVE_REL = 'src/common/downloads.ts'

FETCH_OLD = """        if (redirected && contentType.startsWith('text/html')) {
            await res.body.dump();
            throw new Error('Omnivox redirected the download to a web page instead of a file. The session has probably expired, log in again with the auth app.');
        }"""

FETCH_NEW = """        // An id that does not exist answers 200 with an error document named
        // Error.txt. Saving that is worse than failing, so HTML with no file name
        // and any name the server uses only for errors are both failures.
        const sentDisposition = header(res.headers, 'content-disposition') || '';
        const sentFilename = parseFilename(sentDisposition);
        const looksLikeErrorPage = /^error\\.(txt|html?)$/i.test(sentFilename || '')
            || (contentType.startsWith('text/html') && (redirected || !sentFilename));
        if (looksLikeErrorPage) {
            await res.body.dump();
            throw new Error('Omnivox answered with an error page instead of a file. The document or attachment id is probably wrong; if every download does this, the session expired and needs a fresh login.');
        }"""

SAVE_OLD = """    const name = path.basename(file.filename || fallbackName).replace(/[<>:"/\\\\|?*\\x00-\\x1f]/g, '_');
    const filePath = path.join(downloadsDir, name);
    await pipeline(file.body, fs.createWriteStream(filePath));

    return filePath;"""

SAVE_NEW = """    const name = path.basename(file.filename || fallbackName).replace(/[<>:"/\\\\|?*\\x00-\\x1f]/g, '_');
    const filePath = path.join(downloadsDir, name);
    await pipeline(file.body, fs.createWriteStream(filePath));

    // Omnivox's error page comes back with a file name and a 200, so the last
    // word is the bytes: an HTML document is never a course file. Remove it and
    // fail instead of leaving a page where a document should be.
    const head = Buffer.alloc(64);
    const fd = fs.openSync(filePath, 'r');
    try {
        fs.readSync(fd, head, 0, head.length, 0);
    } finally {
        fs.closeSync(fd);
    }
    if (/^\\s*<(!doctype\\s+html|html|head|body)/i.test(head.toString('utf8').replace(/\\0+$/, ''))) {
        fs.unlinkSync(filePath);
        throw new Error(`Omnivox sent an HTML page instead of ${name}; the id is probably wrong.`);
    }

    return filePath;"""


def patch(path: pathlib.Path, old: str, new: str, marker: str, label: str) -> bool:
    if not path.is_file():
        print(f'{label}: {path} is missing, upstream moved it', file=sys.stderr)
        return False
    src = path.read_text()
    if marker in src:
        print(f'{label}: already applied')
        return True
    if old not in src:
        print(f'{label}: anchor not found, patch NOT applied', file=sys.stderr)
        return False
    path.write_text(src.replace(old, new, 1))
    print(f'{label}: applied')
    return True


def main() -> int:
    if len(sys.argv) != 2:
        print('usage: patch-download-guard.py <app-dir>', file=sys.stderr)
        return 2
    root = pathlib.Path(sys.argv[1])
    ok = patch(root / FETCH_REL, FETCH_OLD, FETCH_NEW, 'looksLikeErrorPage', 'download guard')
    ok = patch(root / SAVE_REL, SAVE_OLD, SAVE_NEW, 'Omnivox sent an HTML page instead of', 'save guard') and ok
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
