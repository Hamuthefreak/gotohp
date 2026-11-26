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
import json
import os
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

script = str(Path(sys.argv[1]).resolve())

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
]
WRITE = {
    'send-mio-message', 'reply-mio-message', 'delete-mio-message',
    'move-mio-message', 'restore-mio-message', 'flag-mio-message',
    'create-mio-folder',
}
MSG_ID = '11111111-1111-1111-1111-111111111111'
ATT_ID = '22222222-2222-2222-2222-222222222222'
BOGUS_UUID = '00000000-0000-0000-0000-000000000000'

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
        if mode == 'ghostfile' and name == 'get-document-link' and args.get('document_id') == 'DOC1':
            self.reply(200, f'File saved to: {downloads}/ghost.pdf')
            return
        if name == 'get-document-link':
            if args.get('document_id') == 'DOC1':
                out = downloads / 'lab-notes.pdf'
                out.write_bytes(b'%PDF-1.4 fake document\n')
                self.reply(200, f'File saved to: {out}')
            else:
                self.reply(400, f'document {args.get("document_id")} not found')
            return
        if name == 'get-assignment-file-link':
            ok = args.get('file_id') == 'F1'
            self.reply(200 if ok else 400, 'link ok' if ok else 'file not found')
            return
        if name == 'get-mio-attachment-link':
            ok = args.get('attachment_id') != BOGUS_UUID
            self.reply(200 if ok else 400, 'link ok' if ok else 'attachment not found')
            return

        bodies = {
            'get-courses-summary': 'Your courses\n- Introduction (ENG1.1234)\n',
            'get-terms': 'Fall 2026',
            'get-mio-messages': f'inbox\n- {MSG_ID} hello\n',
            'get-mio-folders': 'INBOX\nSent',
            'get-course-assignments': '- ID: ASG1\n',
            'get-course-documents': '- ID: DOC1\n',
            'get-assignment-submit-link': 'File ID: F1 (role: teacher_document)\n',
            'read-mio-message': f'from: someone\nattachment_id: {ATT_ID}\nbody: hi\n',
            'search-mio-messages': 'no matches',
            'search-people': 'no matches',
            'get-service-link': 'https://example.test/mio',
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

for mode, tool, shape, needle in (
    ('errorpage', 'get-course-info', 'error page served as a 200', 'Error.txt'),
    ('http500', 'get-terms', 'non-2xx answer', '500'),
    ('silent', 'search-people', 'tool left unanswered', 'no answer'),
    ('ghostfile', 'get-document-link', 'saved path that does not exist', 'missing, empty or stale'),
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

key=$(cat "$KEY_FILE" 2>/dev/null || true)
[[ -n $key ]] || {
	echo "no access key in $KEY_FILE" >&2
	exit 1
}

python3 - "$BASE" "$key" "$DOWNLOADS" <<'PY'
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
    report(name, status, body, limit=80)

courses = list(dict.fromkeys(re.findall(r'\(([0-9A-Z]{4,}\.[0-9]{4,})\)', harvest['get-courses-summary'])))
print(f'\ncourses harvested: {len(courses)}')
if not courses:
    failures.append(('harvest courses', 0, harvest['get-courses-summary'][:200]))

# ---------------------------------------------------------------- course scoped
documents = []
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
                for doc in re.findall(r'^- ID: (\S+)$', body, re.M):
                    documents.append((course, doc))
            if name == 'get-course-assignments':
                for aid in dict.fromkeys(re.findall(r'^- ID: (\S+)$', body, re.M)):
                    assignments.append((course, aid))

# ---------------------------------------------------------------- assignment detail
print()
for course, aid in assignments[:3]:
    status, body, _ = call('get-assignment-detail', {'course_id': course, 'assignment_id': aid})
    report(f'get-assignment-detail {aid}', status, body, limit=110)
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

# ---------------------------------------------------------------- mio
print()
message_ids = list(dict.fromkeys(re.findall(
    r'\b([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\b',
    harvest['get-mio-messages'],
)))
attachment = None
for mid in message_ids[:1]:
    status, body, _ = call('read-mio-message', {'message_id': mid})
    report('read-mio-message', status, body, limit=110)
    match = re.search(r'attachment_id: ([0-9A-Fa-f-]{8,})', body)
    if match:
        attachment = (mid, match.group(1))

if attachment:
    mid, att = attachment
    status, body, _ = call('get-mio-attachment-link', {'message_id': mid, 'attachment_id': att})
    report('get-mio-attachment-link', status, body, limit=110)
    status, body, _ = call('get-mio-attachment-link', {'message_id': mid, 'attachment_id': BOGUS_UUID})
    report('get-mio-attachment-link (bogus)', status, body, expect_error=True, limit=110)
else:
    failures.append(('read-mio-message had no attachment to test', 0, ''))
    print(f'{"get-mio-attachment-link":<46} {"":<4} <-- FAIL (no attachment id found)')

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
PY
