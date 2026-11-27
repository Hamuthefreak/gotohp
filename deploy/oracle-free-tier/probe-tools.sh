#!/usr/bin/env bash
# Runs ON the relay box. Calls every tool the MCP server registers, with real
# ids taken from the account, and fails if anything answers badly.
#
#   sudo bash probe-tools.sh
#
# Two things it is strict about, because both hid bugs before:
#   - a tool that needs arguments is called with real ones, so its real path
#     runs, not just its input validation;
#   - a 200 that carries an error page ("File saved to: .../Error.txt") counts as
#     a failure, not as an answer.
#
# Write tools are only ever called with ids that cannot exist, so nothing is
# sent, moved or deleted on the account.
#
#   sudo bash probe-tools.sh --self-test
#
# proves the checks bite: it runs this same script against a fake account whose
# server is broken on purpose four ways - a 200 that is an error page, a
# non-2xx, a call that gets no answer, and a write tool that reports success for
# an impossible id - and fails unless each one exits non-zero naming the
# offending tool. A green probe means nothing otherwise.

set -uo pipefail

if [[ ${1:-} == --self-test ]]; then
	python3 - "$0" <<'PY'
# What the fake account in --self-test serves, kept where both halves of the
# file can see it: the tools a real server lists, the ones that write, and the
# account-wide reads whose answers must not be blank.
TOOLS = [
    'get-courses-summary', 'get-terms', 'get-mio-messages', 'get-mio-folders',
    'get-course-info', 'get-course-assignments', 'get-course-announcements',
    'get-course-documents', 'get-course-evals', 'get-course-people',
    'get-assignment-detail', 'get-assignment-submit-link', 'get-assignment-file-link',
    'get-document-link', 'read-mio-message', 'get-mio-attachment-link',
    'search-mio-messages', 'search-people', 'get-service-link',
    'send-mio-message', 'reply-mio-message', 'delete-mio-message',
    'move-mio-message', 'restore-mio-message', 'flag-mio-message',
    'create-mio-folder',
    'get-absences', 'get-assignments-summary', 'get-calendar',
    'get-cancelled-classes', 'get-college-documents', 'get-college-list',
    'get-college-news', 'get-grades-summary', 'get-online-forms',
    'get-overview', 'get-schedule', 'get-teachers',
    'get-college-document-link', 'get-mio-message-link', 'get-campus-events',
    'get-upcoming-schedule', 'read-document',
]
# Tools whose answer is a stretch of days rather than one list: asked without a
# window, they must still say something about what is on.
WINDOW_TOOLS = {'get-upcoming-schedule'}
WRITE = {
    'send-mio-message', 'reply-mio-message', 'delete-mio-message',
    'move-mio-message', 'restore-mio-message', 'flag-mio-message',
    'create-mio-folder',
}
# A v4, because read-mio-message refuses anything else before it reaches
# Omnivox; the probe only reads ids of this shape.
NOTICE_ID = '44444444-4444-4444-8444-444444444444'
MSG_ID = '11111111-1111-4111-8111-111111111111'
ATT_ID = '22222222-2222-4222-8222-222222222222'
TERM_TOOLS = {
    'get-overview', 'get-schedule', 'get-absences', 'get-teachers',
    'get-grades-summary', 'get-assignments-summary',
}
STATIC_TOOLS = {
    'get-cancelled-classes', 'get-calendar', 'get-college-list',
    'get-college-news', 'get-college-documents', 'get-online-forms',
}
# The reads the mission names: each is called without any id by a client, and
# each has to come back with an answer that shows something, not a blank page.
BOGUS_UUID = '00000000-0000-0000-0000-000000000000'


import json
import os
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

script = str(Path(sys.argv[1]).resolve())

state = {'mode': 'none', 'downloads': Path('.')}


class Fake(BaseHTTPRequestHandler):
    """A minimal MCP server that can be told to misbehave."""

    def log_message(self, *args):
        pass

    def reply(self, status, body):
        data = body.encode()
        self.send_response(status)
        self.send_header('content-type', 'text/plain; charset=utf-8')
        self.send_header('content-length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path != '/tools':
            self.reply(404, 'no such route')
            return
        self.reply(200, json.dumps({
            'tools': [{'name': n, 'inputSchema': {}} for n in TOOLS],
        }))

    def do_POST(self):
        name = self.path.rsplit('/', 1)[-1]
        try:
            raw = self.rfile.read(int(self.headers.get('content-length') or 0))
            args = json.loads(raw or b'{}')
        except ValueError:
            args = {}
        mode = state['mode']
        downloads = state['downloads']

        # One tool starts answering the way a server that died mid-request does:
        # the client gets no answer. Only the one tool, so the self-test proves
        # the probe reports the tool that broke, not every tool after it.
        if mode == 'dead' and name == 'get-overview':
            self.close_connection = True
            return

        # A message that really has an attachment, so the new tools run the way
        # they do on the account.
        if name == 'get-mio-attachments':
            self.reply(200, f'attachments\n- poster.pdf (application/pdf, 1 KB) - message: {MSG_ID}\n')
            return
        if name == 'read-mio-message':
            self.reply(200, f'# hello\n- From: someone\n- Date: Mon, Nov 24\n\n## Attachments\n'
                            f'- poster.pdf (application/pdf, 1 KB) [attachment_id: {ATT_ID}]\n\n'
                            '## Message\nPlease bring a non-perishable item to the food drive.')
            return
        if name == 'get-mio-message-link' and args.get('attachment_id') != ATT_ID:
            self.reply(400, f'Message {args.get("message_id")} has no attachment {args.get("attachment_id")}. It lists: poster.pdf ({ATT_ID}).')
            return
        if name == 'get-mio-message-link':
            # A real save, in the shape the tool reports it, so the check on the
            # file it says it wrote has something to find.
            out = downloads / 'poster.pdf'
            out.write_bytes(b'%PDF-1.4 poster\n')
            self.reply(200, f'File saved to: {out}')
            return
        if name == 'get-college-documents':
            # The list its own file tool reads back from: same shape as the live
            # answer, so a broken list would leave the link tool without an id.
            self.reply(200, '# College documents (2)\n'
                        '\n## Registrar guide\n- File: PDF, 46 KB\n- ID: 33333333-3333-4333-8333-333333333333\n'
                        '\n## Request for a High School or University Pre-requisite Course\n'
                        '- File: PDF, 100 KB\n- Extention: PDF\n- ID: ' + NOTICE_ID)
            return
        if name == 'get-college-document-link' and args.get('document_id') == '33333333-3333-4333-8333-333333333333':
            out = downloads / 'registrar-guide.pdf'
            out.write_bytes(b'%PDF-1.4 registrar\n')
            self.reply(200, f'File saved to: {out}')
            return
        if name == 'get-college-document-link' and args.get('document_id') == NOTICE_ID:
            # A notice whose file Omnivox does not serve: the text it already
            # holds comes back instead, and nothing is opened.
            self.reply(200, f'# Request for a High School or University Pre-requisite Course\n'
                            f'File: The_CRUM_List_annoucement.pdf (PDF (100 KB)) - the college does not serve this one as a download, so no file was fetched and nothing was opened.\n\n'
                            f'Please see the attached document for more information.')
            return
        if name == 'get-college-document-link':
            self.reply(400, f'No college document with id {args.get("document_id")}. Call get-college-documents for the current list.')
            return
        if name == 'get-campus-events':
            self.reply(200, '# Campus events (1)\n\n## Open house\n- When: Sat, Nov 28 10:00\n')
            return
        if name == 'get-upcoming-schedule':
            # Echo the window it was asked for, so a tool that ignores its own
            # argument is visible rather than looking right.
            window = args.get('days', 7)
            self.reply(200, f'# Next {window} days: 1 entry\n\n## Sat, Nov 28\n- 10:00 Open house')
            return
        # The three failure shapes a real server has produced or could produce.
        if mode == 'errorpage' and name == 'get-course-info':
            self.reply(200, f'File saved to: {downloads}/Error.txt')
            return
        if mode == 'http500' and name == 'get-terms':
            self.reply(500, 'internal error')
            return
        if mode == 'silent' and name == 'search-people':
            # Promise a body, send a fragment, hang up: no usable answer.
            self.send_response(200)
            self.send_header('content-length', '500')
            self.end_headers()
            self.wfile.write(b'partial')
            self.close_connection = True
            return

        if name == 'create-mio-folder' and not args.get('name', '').strip():
            self.reply(400, 'A folder needs a name: pass the name to create.')
            return
        # The account-wide reads a client makes with no arguments. Nothing here
        # kills them, so the baseline must reach them and count them.
        # The account-wide reads a client makes. Nothing here kills them, so the
        # baseline has to reach them and the coverage check has to see them.
        if name in TERM_TOOLS:
            self.reply(200, f'# {name}\n- term {args.get("term_id") or "(default)"}')
            return
        if name == 'get-cancelled-classes':
            # The shape this patch now prints: the flag and the array fields it
            # read, so an empty list can be told apart from one read wrongly.
            self.reply(200, '# Cancelled classes\nNo cancelled classes.\n'
                            'Omnivox agrees: IndicateurAucunCoursAnnule is true (array fields: ListeAnnulationCours (0)).')
            return
        if name in STATIC_TOOLS:
            self.reply(200, f'# {name}\n- nothing to show')
            return
    
        if mode == 'miofalse' and name in ('delete-mio-message', 'restore-mio-message'):
            # What the server said before the MIO guard: Omnivox accepts the
            # impossible id, so the tool reports work it did not do.
            verb = 'moved to trash' if name == 'delete-mio-message' else 'restored'
            self.reply(200, f'1 message(s) {verb}.')
            return
        if name == 'get-assignment-submit-link':
            # Mirror a real file-mode deployment: no MCP_SERVER_URL, no link.
            self.reply(500, "get-assignment-submit-link requires HTTP mode with "
                           "MCP_SERVER_URL set to the server's public base URL")
            return
        if name in WRITE:
            self.reply(400, 'no such message or folder')
            return
        if mode == 'ghostfile' and name == 'get-document-link' and args.get('document_id'):
            self.reply(200, f'File saved to: {downloads}/ghost.pdf')
            return
        if name == 'get-document-link':
            if args.get('document_id') in ('DOC1', 'DOC2'):
                out = downloads / 'lab-notes.pdf'
                out.write_bytes(b'%PDF-1.4 fake document\n')
                self.reply(200, f'File saved to: {out}')
            else:
                self.reply(400, f'document {args.get("document_id")} not found')
            return
        if name == 'read-document':
            # The text, not a path: the whole point of the tool. The fake account
            # answers the ids its own listings print, for both sources the probe
            # calls it with.
            if args.get('document_id') in ('DOC1', 'DOC2') and args.get('source') == 'course-document':
                self.reply(200, '# lab-notes.pdf\napplication/pdf, 1 KB, 2 pages, pdf\n'
                                'Source: course document ' + str(args.get('document_id')) + '\n\n'
                                'Question 1: the number of permutations is 720. '
                                'Question 2: the proof follows from the induction hypothesis, '
                                'written out step by step for full marks.')
            elif args.get('source') == 'college-document' and args.get('document_id'):
                self.reply(200, '# Request for a High School or University Pre-requisite Course\n'
                                'Source: college document\n\nPlease see the attached document for more information.')
            elif args.get('attachment_id') == ATT_ID and args.get('source') == 'mio-attachment':
                self.reply(200, '# poster.pdf\napplication/pdf, 1 KB, 1 page, pdf\n'
                                'Source: attachment ' + ATT_ID + '\n\nPoster text.')
            else:
                self.reply(400, f'document {args.get("document_id")} not found for source {args.get("source")}')
            return
        if name == 'get-assignment-file-link':
            ok = args.get('file_id') == 'F1'
            self.reply(200 if ok else 400, 'link ok' if ok else 'file not found')
            return
        if name == 'read-mio-message':
            # The fake account's own body, so it can never fall through to a
            # generic stub with no id in it.
            self.reply(200, f'from: someone\nattachment_id: {ATT_ID}\nbody: hi\n')
            return
        if name == 'get-mio-attachment-link':
            ok = args.get('attachment_id') != BOGUS_UUID
            self.reply(200 if ok else 400, 'link ok' if ok else 'attachment not found')
            return

        bodies = {
            'get-courses-summary': 'Your courses\n- Introduction (ENG1.1234)\n',
            'get-terms': 'Fall 2026 {"default_term":"20263","terms":[{"id":"20263","name":"Fall 2026"}]}',
            'get-mio-messages': f'inbox\n## hello\n- From: someone\n- Attachments: poster.pdf\n- ID: {MSG_ID}\n',
            'get-mio-folders': 'INBOX\nSent',
            'get-course-assignments': '- ID: ASG1\n',
            'get-assignment-detail': '# Lab 3 [DUE IN 2d]\n- Due: Fri, Nov 28 23:59\n\n## Instructions\n'
                                     'Prove by induction that the sum of the first n integers is n(n+1)/2. '
                                     'Show every step, then compute it for n = 10.\n',
            'get-course-documents': '## Course outline\n- ID: DOC1\n\n## Solutions to Test 2\n- ID: DOC2\n',
            'get-assignment-submit-link': 'File ID: F1 (role: teacher_document)\n',
            'read-mio-message': f'from: someone\nattachment_id: {ATT_ID}\nbody: hi\n',
            'search-mio-messages': 'no matches',
            'search-people': 'no matches',
            'get-service-link': 'https://example.test/mio',
            'get-college-document-link': 'college documents',
            'get-mio-message-link': 'attachments',
            'get-campus-events': 'events',
            'get-upcoming-schedule': 'Next 7 days: 1 entry\n- 10:00 Open house',
        }
        self.reply(200, bodies.get(name, f'{name} ok'))


server = HTTPServer(('127.0.0.1', 0), Fake)
server_url = f'http://127.0.0.1:{server.server_address[1]}'
threading.Thread(target=server.serve_forever, daemon=True).start()


def run(mode):
    downloads = Path(tempfile.mkdtemp(prefix='probe-selftest-'))
    keyfile = downloads.parent / (downloads.name + '.key')
    keyfile.write_text('self-test-key')
    state['mode'] = mode
    state['downloads'] = downloads
    env = dict(os.environ, BASE=server_url, KEY_FILE=str(keyfile), DOWNLOADS=str(downloads))
    proc = subprocess.run(['bash', script], env=env, capture_output=True, text=True, timeout=600)
    return proc.returncode, proc.stdout + proc.stderr


bad = 0
rc, out = run('none')
if rc == 0:
    print('self-test  baseline, fake account, no fault       exit 0  ok')
else:
    bad += 1
    print(f'self-test  baseline, fake account, no fault       exit {rc}  FAIL'
          ' (the harness does not pass, so the injections prove nothing)')
    print('\n'.join('    ' + line for line in out.strip().splitlines()[-12:]))
    if os.environ.get('SELFTEST_VERBOSE'):
        print(out)

for mode, tool, shape, needle in (
    ('errorpage', 'get-course-info', 'error page served as a 200', 'Error.txt'),
    ('http500', 'get-terms', 'non-2xx answer', '500'),
    ('silent', 'search-people', 'tool left unanswered', 'no answer'),
    ('ghostfile', 'get-document-link', 'saved path that does not exist', 'missing, empty or stale'),
    # The account-wide reads are the ones a broken or unread tool hid before.
    ('dead', 'get-overview', 'an account-wide read with no answer', 'no answer'),
):
    rc, out = run(mode)
    # Each scenario must fail for its own reason, not some other breakage.
    named = [line for line in out.splitlines() if tool in line and 'FAIL' in line and needle in line]
    if rc != 0 and named:
        print(f'self-test  {shape:<33} exit {rc}  names {tool}  ok')
        print(f'           probe said: {named[0].strip()}')
    else:
        bad += 1
        why = 'exited 0' if rc == 0 else f'never named {tool} as {needle!r}'
        print(f'self-test  {shape:<33} FAIL: {why}')

# The MIO guard's own regression: a server that echoes Omnivox's false success
# (200 "1 message(s) moved to trash." for the all-zeros id) must not pass, or
# the guard could be dropped and every probe would still go green.
rc, out = run('miofalse')
named = [line for line in out.splitlines() if 'says nothing moved' in line and 'FAIL' in line]
if rc != 0 and named:
    print(f'self-test  {"bogus id reported as success":<33} exit {rc}  names the id  ok')
    print(f'           probe said: {named[0].strip()}')
else:
    bad += 1
    print(f'self-test  {"bogus id reported as success":<33} FAIL: ' +
          ('exited 0' if rc == 0 else 'never flagged the false success'))

if bad:
    print(f'\nself-test: {bad} injected failure shape(s) went unreported')
    raise SystemExit(1)
print('\nself-test: the probe fails, naming the tool, for every injected failure shape')
PY
	exit
fi

BASE=${BASE:-http://127.0.0.1:3000}
KEY_FILE=${KEY_FILE:-/opt/omnivox-mcp/data/accessKey.txt}
DOWNLOADS=${DOWNLOADS:-/opt/omnivox-mcp/data/downloads}
# The tools this deployment adds itself. If the server has not loaded them, the
# probe is asking a process that is not running this checkout (an older one
# still holding the port, say), and every answer below would describe that
# process, not the one just installed.
EXTRA_TOOLS=${EXTRA_TOOLS:-get-college-document-link get-mio-message-link get-campus-events get-upcoming-schedule read-document}

key=$(cat "$KEY_FILE" 2>/dev/null || true)
[[ -n $key ]] || {
	echo "no access key in $KEY_FILE" >&2
	exit 1
}

served=$(curl -fsS -m 30 -H "x-mcp-auth: $key" "$BASE/tools" 2>/dev/null || true)
for extra in $EXTRA_TOOLS; do
	case "$served" in
	*"\"$extra\""*) ;;
	*)
		echo "probe: $BASE does not serve $extra, so it is not running this checkout." >&2
		echo 'probe: restart the unit (systemctl restart omnivox-mcp) and run it again.' >&2
		echo "probe: it answered: ${served:0:200}" >&2
		exit 1
		;;
	esac
done

python3 - "$BASE" "$key" "$DOWNLOADS" <<'PROBE'
TOOLS = [
    'get-courses-summary', 'get-terms', 'get-mio-messages', 'get-mio-folders',
    'get-course-info', 'get-course-assignments', 'get-course-announcements',
    'get-course-documents', 'get-course-evals', 'get-course-people',
    'get-assignment-detail', 'get-assignment-submit-link', 'get-assignment-file-link',
    'get-document-link', 'read-mio-message', 'get-mio-attachment-link',
    'search-mio-messages', 'search-people', 'get-service-link',
    'send-mio-message', 'reply-mio-message', 'delete-mio-message',
    'move-mio-message', 'restore-mio-message', 'flag-mio-message',
    'create-mio-folder',
    'get-absences', 'get-assignments-summary', 'get-calendar',
    'get-cancelled-classes', 'get-college-documents', 'get-college-list',
    'get-college-news', 'get-grades-summary', 'get-online-forms',
    'get-overview', 'get-schedule', 'get-teachers',
    'get-college-document-link', 'get-mio-message-link', 'get-campus-events',
    'get-upcoming-schedule', 'read-document',
]
ACCOUNT_TOOLS = {
    'get-upcoming-schedule',
    'get-overview', 'get-schedule', 'get-absences', 'get-teachers',
    'get-grades-summary', 'get-assignments-summary', 'get-cancelled-classes',
    'get-calendar', 'get-college-list', 'get-college-news',
    'get-college-documents', 'get-online-forms',
}
import json
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

base, key, downloads = sys.argv[1], sys.argv[2], Path(sys.argv[3])
BOGUS = '999999999999999'
BOGUS_UUID = '00000000-0000-0000-0000-000000000000'

failures = []
called = set()
answered = 0
rejected = 0


def call(name, args=None):
    data = json.dumps(args if args is not None else {}).encode()
    req = urllib.request.Request(
        f'{base}/tools/{name}', data=data,
        headers={'x-mcp-auth': key, 'content-type': 'application/json'},
    )
    start = time.time()
    try:
        with urllib.request.urlopen(req, timeout=180) as res:
            return res.status, res.read().decode('utf-8', 'replace'), time.time() - start
    except urllib.error.HTTPError as err:
        return err.code, err.read().decode('utf-8', 'replace'), time.time() - start
    except Exception as err:  # noqa: BLE001 - a probe reports, it never raises
        return 0, f'{type(err).__name__}: {err}', time.time() - start


def is_error_page(text):
    """A 200 that is really a failure: Omnivox's error page saved as a file."""
    if re.search(r'File saved to: \S*Error\.(txt|html)', text, re.I):
        return True
    head = text.lstrip()
    if head.startswith('Error:') or head.startswith('Error\n') or head.startswith('Error '):
        return True
    if 'error page instead of a file' in text:
        return True
    return False


def report(label, status, body, expect_error=False, limit=150):
    global answered, rejected
    text = ' '.join(body.split())
    called.add(label.split()[0])

    if status == 0:
        failures.append((label, status, text[:300]))
        print(f'{label:<46} {status:<4} {text[:limit]}  <-- FAIL (no answer)')
        return False

    page = is_error_page(body)
    if expect_error:
        if status == 200 and not page:
            failures.append((label, status, text[:300]))
            print(f'{label:<46} {status:<4} {text[:limit]}  <-- FAIL (bogus input looked like success)')
            return False
        rejected += 1
        print(f'{label:<46} {status:<4} {text[:limit]}  ok (rejected)')
        return True

    if status != 200 or page:
        failures.append((label, status, text[:300]))
        print(f'{label:<46} {status:<4} {text[:limit]}  <-- FAIL')
        return False

    answered += 1
    print(f'{label:<46} {status:<4} {text[:limit]}')
    return True


# ---------------------------------------------------------------- inventory
req = urllib.request.Request(f'{base}/tools', headers={'x-mcp-auth': key})
try:
    with urllib.request.urlopen(req, timeout=60) as res:
        inventory = json.load(res)
except Exception as err:  # noqa: BLE001
    print(f'could not list the tools: {err}')
    raise SystemExit(1)

tools = {t['name']: (t.get('inputSchema') or {}) for t in inventory.get('tools', [])}
WANT_TOKENS = {'send', 'reply', 'delete', 'move', 'restore', 'create', 'flag', 'mark'}
write_tools = {
    name for name in tools
    if any(word in name for word in WANT_TOKENS)
}

print(f'tools registered: {len(tools)}  (write tools not mutated: {len(write_tools)})')
print()

# ---------------------------------------------------------------- inventory of ids
harvest = {}
for name, args in (
    ('get-courses-summary', {}),
    ('get-terms', {}),
    ('get-mio-messages', {}),
    ('get-mio-folders', {}),
):
    status, body, _ = call(name, args)
    harvest[name] = body
    # The inbox listing is parsed for message ids, so it is printed whole: a
    # shape the parser does not expect has to be visible, not guessed.
    report(name, status, body, limit=3000 if name == 'get-mio-messages' else 80)
# The same listing, kept whole: a message body that explains itself is only
# readable when the sections above are not cut at a fixed width.
raw = {name: body for name, body in ((n, harvest[n]) for n in harvest)}

courses = list(dict.fromkeys(re.findall(r'\(([0-9A-Z]{4,}\.[0-9]{4,})\)', harvest['get-courses-summary'])))
print(f'\ncourses harvested: {len(courses)}')
if not courses:
    failures.append(('harvest courses', 0, harvest['get-courses-summary'][:200]))

# ---------------------------------------------------------------- course scoped
documents = []
document_names = {}
assignments = []
for course in courses:
    print(f'\ncourse {course}')
    for name in (
        'get-course-info',
        'get-course-assignments',
        'get-course-announcements',
        'get-course-documents',
        'get-course-evals',
        'get-course-people',
    ):
        status, body, _ = call(name, {'course_id': course})
        if report(f'  {name}', status, body, limit=110):
            if name == 'get-course-documents':
                # The document's own heading, kept with its id: the mission names
                # one document (the Test 2 solutions), and a listing that is read
                # without its titles cannot find it.
                for block in re.split(r'\n## ', body)[1:]:
                    found = re.search(r'^- ID: (\S+)$', block, re.M)
                    if found:
                        documents.append((course, found.group(1)))
                        document_names[(course, found.group(1))] = block.split('\n', 1)[0].strip()
                for doc in re.findall(r'^- ID: (\S+)$', body, re.M):
                    if (course, doc) not in document_names and all(doc != d for _, d in documents):
                        documents.append((course, doc))
            if name == 'get-course-assignments':
                for aid in dict.fromkeys(re.findall(r'^- ID: (\S+)$', body, re.M)):
                    assignments.append((course, aid))

# ---------------------------------------------------------------- assignment detail
print()
instructions = ''
for course, aid in assignments[:6]:
    status, body, _ = call('get-assignment-detail', {'course_id': course, 'assignment_id': aid})
    report(f'get-assignment-detail {aid}', status, body, limit=110)
    # The instructions are the reason this tool exists; an answer that stops at
    # the deadline is the stub the mission is asking to close.
    if not instructions and 200 <= status < 300 and '## Instructions' in body:
        text = body.split('## Instructions', 1)[1].split('\n## ', 1)[0].strip()
        if len(text) > 40:
            instructions = text
            print(f'{"  the instructions text":<46} {"":<4} {len(text)} characters: {" ".join(text.split())[:80]!r}')
    # This deployment serves files and runs without MCP_SERVER_URL, so the tool
    # is documented to refuse and say why. Assert that exact refusal: a silent
    # success would mean link mode turned on, which changes every download.
    status, body, _ = call('get-assignment-submit-link', {'course_id': course, 'assignment_id': aid})
    called.add('get-assignment-submit-link')
    if status != 200 and 'MCP_SERVER_URL' in body:
        rejected += 1
        print(f'{"get-assignment-submit-link " + aid:<46} {status:<4} says it needs MCP_SERVER_URL  ok (documented refusal)')
    else:
        failures.append(('get-assignment-submit-link', status, body[:300]))
        print(f'{"get-assignment-submit-link " + aid:<46} {status:<4} {" ".join(body.split())[:110]}  <-- FAIL (unexpected answer)')
        continue
    if assignments:
        files = re.findall(r'File ID: (\S+) \(role: (\w+)\)', body)
        for file_id, role in files[:1]:
            status, body, _ = call('get-assignment-file-link', {
                'course_id': course, 'assignment_id': aid, 'file_id': file_id, 'role': role,
            })
            report('get-assignment-file-link', status, body, limit=110)

if assignments:
    course, aid = assignments[0]
    status, body, _ = call('get-assignment-file-link', {
        'course_id': course, 'assignment_id': aid, 'file_id': BOGUS, 'role': 'teacher_document',
    })
    report('get-assignment-file-link (bogus)', status, body, expect_error=True, limit=110)

if not instructions:
    failures.append(('no assignment came back with instructions text', 0, f'{len(assignments[:6])} assignment(s) read'))
    print(f'{"  the instructions text":<46} {"":<4} <-- FAIL (none of the assignments read has instructions)')

# ---------------------------------------------------------------- documents
print()
if documents:
    course, doc = documents[0]
    started = time.time()
    status, body, _ = call('get-document-link', {'course_id': course, 'document_id': doc})
    if report(f'get-document-link {doc}', status, body, limit=120):
        # Judge the file the tool says it wrote, not the downloads listing: a
        # file left by an earlier run is still proof this call worked.
        match = re.search(r'File saved to: (\S+)', body)
        if not match:
            failures.append(('get-document-link reported no path', status, body[:300]))
            print(f'{"get-document-link " + doc:<46} {status:<4} <-- FAIL (no saved path in the answer)')
        else:
            saved = Path(match.group(1))
            try:
                st = saved.stat()
            except OSError:
                st = None
            fresh = st is not None and st.st_size > 0 and st.st_mtime >= started - 2
            if fresh and not re.match(r'Error\.', saved.name, re.I):
                print(f'{"":<46} {"":<4} wrote {saved} ({st.st_size} bytes)')
            else:
                failures.append(('get-document-link saved nothing usable', status, str(saved)))
                print(f'{"get-document-link " + doc:<46} {status:<4} <-- FAIL (reported {saved}, which is missing, empty or stale)')

for course, _ in documents[:1]:
    status, body, _ = call('get-document-link', {'course_id': course, 'document_id': BOGUS})
    report('get-document-link (bogus)', status, body, expect_error=True, limit=120)
    created = downloads / 'Error.txt'
    if created.exists():
        failures.append(('bogus document wrote Error.txt', 200, str(created)))
        print(f'{"":<46} {"":<4} <-- FAIL (wrote {created})')

# The read that a client actually needs: the same document the link tool saves to
# disk, arriving as its text instead. A path in the answer is exactly the failure
# this tool was added to remove, so it fails here by name.
if documents:
    course, doc = documents[0]
    status, body, _ = call('read-document', {'source': 'course-document', 'course_id': course, 'document_id': doc})
    report(f'read-document {doc}', status, body, limit=120)
    if 200 <= status < 300:
        head = body.lstrip()
        if 'File saved to:' in body:
            failures.append(('read-document answered a saved path, not the text', status, body[:300]))
            print(f'{"  it came back as text":<46} {"":<4} <-- FAIL (answered a saved path)')
        elif not head.startswith('#') or 'Source:' not in body:
            failures.append(('read-document did not say what it read', status, body[:300]))
            print(f'{"  it came back as text":<46} {"":<4} <-- FAIL (no file header in the answer)')
        else:
            print(f'{"  it came back as text":<46} {"":<4} {len(" ".join(body.split()))} characters, not a path')
    status, body, _ = call('read-document', {'source': 'course-document', 'course_id': course, 'document_id': BOGUS})
    report('read-document (bogus)', status, body, expect_error=True, limit=110)

# The document the mission names: the Test 2 solutions. It is found by the title
# its own listing prints, and it has to come back as text, not as "saved as".
wanted = re.compile(r'test\s*2|test_2|test-2|solution|corrig', re.I)
named = [(c, d) for c, d in documents if wanted.search(document_names.get((c, d), ''))]
if named:
    course, doc = named[0]
    title = document_names.get((course, doc), doc)
    print(f'{"document chosen":<46} {"":<4} {title[:90]}')
    status, body, _ = call('read-document', {'source': 'course-document', 'course_id': course, 'document_id': doc})
    report(f'read-document {title[:40]}', status, body, limit=120)
    if 200 <= status < 300:
        text = body.split('Source:', 1)[-1].split('\n', 1)[-1].strip() if 'Source:' in body else ''
        if 'File saved to:' in body or len(text) < 120:
            failures.append(('the Test 2 solutions did not come back as text', status, body[:400]))
            print(f'{"  the solutions as text":<46} {"":<4} <-- FAIL ({len(text)} characters)')
        else:
            print(f'{"  the solutions as text":<46} {"":<4} {len(text)} characters of it: {" ".join(text.split())[:90]!r}')
    else:
        failures.append(('the Test 2 solutions could not be read', status, body[:300]))
        print(f'{"  the solutions as text":<46} {"":<4} <-- FAIL ({status})')
else:
    failures.append(('no document listing names the Test 2 solutions', 0, f'{len(documents)} document(s) listed'))
    print(f'{"document chosen":<46} {"":<4} <-- FAIL (no listing names a test/solutions document)')

# Any other real document, read: a listing is not content either.
for course, doc in documents[:6]:
    if (course, doc) == (named[0] if named else (None, None)):
        continue
    status, body, _ = call('read-document', {'source': 'course-document', 'course_id': course, 'document_id': doc})
    report(f'read-document (a second document)', status, body, limit=90)
    if 200 <= status < 300 and 'File saved to:' not in body:
        print(f'{"  it is text, not a path":<46} {"":<4} {document_names.get((course, doc), doc)[:70]}')
        break
    failures.append(('a second document did not come back as text', status, body[:200]))
    print(f'{"  it is text, not a path":<46} {"":<4} <-- FAIL')

# ---------------------------------------------------------------- mio
print()
# The ids as the listing writes them, with whatever separator it uses put back
# to a dash so the call gets a plain uuid.
# read-mio-message checks that its id is a UUID v4, so the ids that are one are
# tried first; one that is not is still tried, and counts as exercised.
V4 = re.compile(r'[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-4[0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}')
message_ids = list(dict.fromkeys(
    ''.join(m) for m in re.findall(
        r'\b([0-9A-Fa-f]{8})[- ]([0-9A-Fa-f]{4})[- ]([0-9A-Fa-f]{4})[- ]([0-9A-Fa-f]{4})[- ]([0-9A-Fa-f]{12})\b',
        harvest['get-mio-messages'],
    )
))
message_ids.sort(key=lambda mid: not V4.fullmatch(mid))
if not message_ids:
    failures.append(('get-mio-messages listed no id', 200, harvest['get-mio-messages'][:200]))
    print(f'{"read-mio-message":<46} {"":<4} <-- FAIL (no message id in the inbox listing)')
# Messages without an attachment are normal, so the probe reads messages until
# one lists one. read-mio-message writes it as "[attachment_id: ...]".
attachment = None
message_body = ''
read = 0
# The inbox says which messages carry an attachment, which is exact where
# scanning a body for an id depends on how that body is written.
# The inbox itself says which messages carry an attachment ("- Attachments:
# name"), and reading one of those first is what makes the attachment tools
# reachable at all when the body does not repeat the id.
inbox = harvest['get-mio-messages']
with_file = []
for block in re.split(r'\n## ', inbox):
    if '- Attachments:' in block:
        found = re.search(r'- ID: ([0-9A-Fa-f-]{8}-[0-9A-Fa-f-]{4}-[0-9A-Fa-f-]{4}-[0-9A-Fa-f-]{4}-[0-9A-Fa-f-]{12})', block)
        if found:
            with_file.append(found.group(1))
message_ids = with_file + [m for m in message_ids if m not in with_file]
# A message id that is not a v4 is refused before it reaches Omnivox, so it
# proves nothing and must not eat the budget that finds an attachment.
for mid in [m for m in message_ids if V4.fullmatch(m)][:12]:
    status, body, _ = call('read-mio-message', {'message_id': mid})
    read += 1
    if read == 1 or status != 200:
        report('read-mio-message', status, body, limit=110)
    elif not 200 <= status < 300:
        report('read-mio-message', status, body, limit=110)
    # The body itself, which is what a reader asked for: a message that returns
    # only its subject, sender and attachment list is a stub, not a message.
    if not message_body and '## Message' in body:
        text = body.split('## Message', 1)[1].strip()
        if len(text) > 20 and '(empty body)' not in text:
            message_body = text
            print(f'{"  the message body":<46} {"":<4} {len(text)} characters: {" ".join(text.split())[:80]!r}')
    match = re.search(r'attachment_id: ([0-9A-Fa-f-]{8,})', body)
    if not match:
        print(f'{"  read " + mid: <46} {status:<4} {body[:80]}')
    if 200 <= status < 300 and match:
        attachment = (mid, match.group(1))
        print(f'{"read-mio-message (" + str(read) + " read)":<46} {status:<4} has an attachment: {match.group(1)}')
        break

if attachment:
    mid, att = attachment
    # The link tool the server ships upstream reads a real attachment too, and
    # the new tool must not replace it.
    status, body, _ = call('get-mio-attachment-link', {'message_id': mid, 'attachment_id': att})
    report('get-mio-attachment-link', status, body, limit=110)
    started = time.time()
    status, body, _ = call('get-mio-message-link', {'message_id': mid, 'attachment_id': att})
    report('get-mio-message-link', status, body, limit=110)
    saved = re.search(r'File saved to: (\S+)', body)
    st = None
    try:
        st = Path(saved.group(1)).stat() if saved else None
    except OSError:
        st = None
    if st is not None and st.st_size > 0 and st.st_mtime >= started - 2:
        print(f'{"  it saved the attachment":<46} {"":<4} wrote {saved.group(1)} ({st.st_size} bytes)')
    else:
        failures.append(('get-mio-message-link saved nothing', status, body[:300]))
        print(f'{"  it saved the attachment":<46} {"":<4} <-- FAIL (no fresh file in the answer)')
    # A message that does not own that attachment is refused without asking
    # Omnivox: the matrix below covers every wrong pair on the live account.
    status, body, _ = call('get-mio-message-link', {'message_id': mid, 'attachment_id': BOGUS_UUID})
    report('get-mio-message-link (bogus attachment)', status, body, expect_error=True, limit=110)
    # The same attachment, read. A MIO poster or a solutions sheet is a PDF, and
    # a path is not an answer to "what does it say".
    status, body, _ = call('read-document', {'source': 'mio-attachment', 'message_id': mid, 'attachment_id': att})
    report('read-document (mio attachment)', status, body, limit=110)
    if 200 <= status < 300:
        head = body.lstrip()
        if 'File saved to:' in body or not head.startswith('#') or 'Source:' not in body:
            failures.append(('read-document (mio attachment) did not come back as text', status, body[:300]))
            print(f'{"  the attachment as text":<46} {"":<4} <-- FAIL')
        else:
            print(f'{"  the attachment as text":<46} {"":<4} {len(" ".join(body.split()))} characters, not a path')
else:
    failures.append(('read-mio-message had no attachment to test', 0, ''))
    print(f'{"get-mio-message-link":<46} {"":<4} <-- FAIL (no attachment id found)')

if not message_body:
    failures.append(('no MIO message came back with a body', 0, f'{read} message(s) read'))
    print(f'{"  the message body":<46} {"":<4} <-- FAIL (every message read had an empty body)')

for name, args in (
    ('search-mio-messages', {'query': 'vanier'}),
    ('search-people', {'query': 'smith'}),
    ('get-service-link', {'service': 'mio'}),
):
    status, body, _ = call(name, args)
    report(name, status, body, limit=110)

# ---------------------------------------------------------------- write tools, never mutated
print()
# The MIO guard's regression, before the generic loop so no other scenario can
# stand in for it: Omnivox accepts a delete or restore for an id that does not
# exist, so a server without the guard answers 200 "1 message(s) moved to trash."
# Demand the honest failure - the id named, or the guard saying nothing moved.
for name, args in (
    ('send-mio-message', {'to': BOGUS_UUID, 'subject': 'probe', 'body': 'probe'}),
    ('reply-mio-message', {'message_id': BOGUS_UUID, 'body': 'probe'}),
    ('delete-mio-message', {'message_id': BOGUS_UUID}),
    ('move-mio-message', {'message_id': BOGUS_UUID, 'folder_id': 'SEARCH_FOLDER_MioRecu'}),
    ('restore-mio-message', {'message_id': BOGUS_UUID}),
    ('flag-mio-message', {'message_id': BOGUS_UUID, 'flagged': True}),
    ('create-mio-folder', {'name': ''}),
    ('create-mio-folder', {'name': '   '}),
):
    if name not in tools:
        continue
    status, body, _ = call(name, args)
    report(name, status, body, expect_error=True, limit=110)
    # Omnivox accepts a delete or restore for an id that does not exist and
    # changes nothing, so a server without the MIO guard answers 200
    # "1 message(s) moved to trash." to an impossible id. An honest answer says
    # why: nothing moved, or there is no such message.
    if name in ('delete-mio-message', 'restore-mio-message'):
        text = ' '.join(body.split()).lower()
        if not any(phrase in text for phrase in ('0 message', BOGUS_UUID.lower(), 'no such message')):
            failures.append((f'{name} (bogus) not honest', status, body[:300]))
            print(f'{"  " + name + " says nothing moved":<44} {"":<4} <-- FAIL (a bogus id was not reported honestly)')
        else:
            print(f'{"  " + name + " says nothing moved":<44} {"":<4} ok (honest failure)')

# ---------------------------------------------------------------- account-wide
# These read the whole account rather than one course. None of them has a
# required argument, so each is called exactly as a client would. term_id is
# harvested from get-terms, because passing the live term exercises the term
# path a client would use, and the tools are called again without it to prove
# the default is the same term.
print()
term_ids = re.findall(r'"id":\s*"(\d{5})"', harvest['get-terms'])
term = term_ids[0] if term_ids else None
if not term:
    failures.append(('harvest term', 0, harvest['get-terms'][:200]))
    print(f'{"harvest term":<46} {"":<4} <-- FAIL (no term id in get-terms)')

# The user's own questions, each answered by a tool that has to show it read
# this account instead of returning a blank page.
for name, args in (
    ('get-overview', {'term_id': term} if term else {}),
    ('get-schedule', {'term_id': term} if term else {}),
    ('get-absences', {'term_id': term} if term else {}),
    ('get-teachers', {'term_id': term} if term else {}),
    ('get-grades-summary', {'term_id': term} if term else {}),
    ('get-assignments-summary', {'term_id': term} if term else {}),
    ('get-cancelled-classes', {}),
    ('get-calendar', {'range': 'week'}),
    ('get-calendar (all)', {'range': 'all', 'page': 0}),
    ('get-college-list', {}),
    ('get-college-news', {}),
    ('get-college-documents', {}),
    ('get-online-forms', {}),
):
    status, body, _ = call(name.split(' ')[0], args)
    answer = f'{name} ({term})' if term and 'term_id' in args else name
    harvest[name.split(' ')[0]] = body
    raw[name.split(' ')[0]] = body
    # The college documents listing is the one this probe parses, so it is
    # printed whole: a shape the parser does not expect has to be visible here,
    # not guessed from the one line that happens to fit.
    report(answer, status, body, limit=4000 if name.split(' ')[0] == 'get-college-documents' else 110)
    if status == 200 and name.split(' ')[0] in ACCOUNT_TOOLS and len(' '.join(body.split())) < 20:
        failures.append((answer, status, 'empty answer'))
        print(f'{"  it has something to say":<46} {"":<4} <-- FAIL (blank answer from a read that has one)')

# Cancelled classes: "No cancelled classes." is only honest when Omnivox's own
# flag agrees. The answer now carries that flag and the array fields it read, so
# a list read from the wrong place can be told apart from a real "none".
cancelled = ' '.join(harvest.get('get-cancelled-classes', '').split())
if 'reading gap' in cancelled:
    failures.append(('get-cancelled-classes read the wrong list', 200, cancelled[:400]))
    print(f'{"  cancelled: the list is the right one":<44} {"":<4} <-- FAIL (Omnivox says cancellations exist)')
elif 'No cancelled classes' in cancelled and 'array fields' in cancelled:
    print(f'{"  cancelled: none, and Omnivox agrees":<44} {"":<4} {cancelled[len("# Cancelled classes"):][:110]!r}')
elif cancelled.startswith('# Cancelled classes ('):
    print(f'{"  cancelled: real entries came back":<44} {"":<4} {cancelled[:110]!r}')
else:
    failures.append(('get-cancelled-classes said nothing usable', 200, cancelled[:300]))
    print(f'{"  cancelled: the list is the right one":<44} {"":<4} <-- FAIL (no flag, no entries)')

# The upcoming schedule the mission asks for: the next seven days.
if term:
    status, body, _ = call('get-schedule', {'term_id': term, 'days': 7})
    report('get-schedule (the next 7 days)', status, body, limit=110)

# The term-free form of every term tool: the same call minus term_id.
for name in (
    'get-overview', 'get-schedule', 'get-absences', 'get-teachers',
    'get-grades-summary', 'get-assignments-summary',
):
    status, body, _ = call(name, {})
    report(f'  {name} (no term_id)', status, body, limit=70)

# The three tools this deployment adds on top of upstream, each with the file
# it is supposed to leave behind or the list it is supposed to refuse.
# Only an entry that names a file can be fetched. get-college-documents prints
# "- File: <ext>, <size>" for those, and some notices carry none at all.
# One block per document, so a file line only counts for the id in its own
# block: a loose match paired a notice's id with an earlier document's file and
# asked for a document that has no file at all.
college = []
# A notice the college lists without a file, if the listing has one: fetching it
# has to be a clear refusal that names the notice, never a wrong file.
notice = None
# What belongs to a document is the lines above its id back to the previous id
# (its heading and fields), plus the lines below it up to the next heading. The
# listing does not always start a document with its own heading, so splitting
# on headings alone hid the only document that has a file.
lines = raw.get('get-college-documents', harvest['get-college-documents']).splitlines()
id_at = {i: re.search(r'- ID: ([0-9a-fA-F-]{36})', line).group(1)
         for i, line in enumerate(lines) if re.search(r'- ID: ([0-9a-fA-F-]{36})', line)}
college = []
notice = None
for at, doc_id in id_at.items():
    above = [k for k in id_at if k < at]
    top = (above[-1] + 1) if above else 0
    below = [at] + [k for k in id_at if k > at]
    bottom = min(below[1], len(lines)) if len(below) > 1 else len(lines)
    part = lines[top:min(at, bottom)]
    for k in range(at + 1, bottom):
        if lines[k].startswith('## '):
            break
        part.append(lines[k])
    if any(line.startswith('- File:') for line in part):
        college.append(doc_id)
    elif notice is None:
        notice = doc_id
if college:
    started = time.time()
    status, body, _ = call('get-college-document-link', {'document_id': college[0]})
    # Printed whole: when a fetch is refused, why it was refused is the only
    # thing that says what the tool still does not read.
    report('get-college-document-link', status, body, limit=2000)
    match = re.search(r'File saved to: (\S+)', body)
    saved = Path(match.group(1)) if match else None
    try:
        st = saved.stat() if saved else None
    except OSError:
        st = None
    if st is not None and st.st_size > 0 and st.st_mtime >= started - 2:
        print(f'{"  it saved the file":<46} {"":<4} wrote {saved} ({st.st_size} bytes)')
    elif 200 <= status < 300 and len(' '.join(body.split())) >= 20:
        # A document Omnivox does not serve as a download: its text is the read,
        # and the answer says nothing was opened.
        print(f'{"  it read the document":<46} {"":<4} no download, so its text came back')
        if 'nothing was opened' not in body:
            failures.append(('get-college-document-link read without saying what it did', status, body[:300]))
    else:
        failures.append(('get-college-document-link saved nothing', status, str(saved)))
        print(f'{"  it saved the file":<46} {"":<4} <-- FAIL (reported {saved})')
    status, body, _ = call('get-college-document-link', {'document_id': BOGUS_UUID})
    report('get-college-document-link (bogus)', status, body, expect_error=True, limit=110)
    if notice:
        status, body, _ = call('get-college-document-link', {'document_id': notice})
        report('get-college-document-link (a notice)', status, body, limit=110)
        # Either its text comes back (Omnivox holds it and serves no file) or it
        # says by name that there is no text at all: an empty answer for a listed
        # notice is how a document silently went missing.
        if not 200 <= status < 300:
            failures.append(('get-college-document-link (a notice) refused badly', status, body[:300]))
        elif len(' '.join(body.split())) < 20:
            failures.append(('get-college-document-link (a notice) came back empty', status, body[:300]))
    # A college document read as text: the same file the link tool writes to
    # disk, or the notice text Omnivox already holds - either way, content.
    status, body, _ = call('read-document', {'source': 'college-document', 'document_id': college[0]})
    report('read-document (college document)', status, body, limit=120)
    if not 200 <= status < 300 or 'File saved to:' in body:
        failures.append(('read-document (college document) did not come back as text', status, body[:300]))
        print(f'{"  the college document as text":<46} {"":<4} <-- FAIL')
    else:
        print(f'{"  the college document as text":<46} {"":<4} {len(body)} characters, not a path')
else:
    failures.append(('get-college-documents listed no id', 200, harvest['get-college-documents'][:200]))
    print(f'{"get-college-document-link":<46} {"":<4} <-- FAIL (no college document id to fetch)')

status, body, _ = call('get-campus-events', {})
report('get-campus-events', status, body, limit=110)

# The schedule for the next days and weeks: one page of the calendar would miss
# anything past it, so the tool pages until the window is covered.
status, body, _ = call('get-upcoming-schedule', {})
report('get-upcoming-schedule', status, body, limit=110)
if status == 200 and not any(word in body for word in ('entry', 'entries', 'Nothing on the calendar')):
    failures.append(('get-upcoming-schedule said nothing about the window', status, body[:200]))
    print(f'{"  it describes the window":<46} {"":<4} <-- FAIL')
status, body, _ = call('get-upcoming-schedule', {'days': 14})
report('get-upcoming-schedule (14 days)', status, body, limit=90)
if status == 200 and not any(word in body for word in ('entry', 'entries', 'Nothing on the calendar')):
    failures.append(('get-upcoming-schedule (14 days) said nothing about the window', status, body[:200]))
    print(f'{"  it covers the next two weeks":<46} {"":<4} <-- FAIL')
else:
    print(f'{"  it covers the next two weeks":<46} {"":<4} {body.splitlines()[0][:70]!r}')
status, body, _ = call('get-upcoming-schedule', {'days': 21})
report('get-upcoming-schedule (21 days)', status, body, limit=90)

# Every tool a server lists must be one this probe knows, so an upstream tool -
# a write tool included - cannot slip in unaccounted for.
print()
unknown = sorted(set(tools) - set(TOOLS))
if unknown:
    failures.append(('tools the probe does not know', 0, ', '.join(unknown)))
    print(f'not in the probe: {", ".join(unknown)}')

# ---------------------------------------------------------------- coverage
print()
untouched = sorted(set(tools) - called)
if untouched:
    failures.append(('untouched tools', 0, ', '.join(untouched)))
    print(f'not exercised: {", ".join(untouched)}')

print(f'\n{answered} answered, {rejected} rejected bad input, {len(called)} of {len(tools)} tools exercised')
if failures:
    print(f'{len(failures)} failure(s):')
    for label, status, text in failures:
        print(f'  - {label}: {status} {text[:200]}')
    raise SystemExit(1)
print('probe: every tool answered or rejected bad input, no error page reported as success')
PROBE
