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

set -uo pipefail

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
    status, body, _ = call('get-assignment-submit-link', {'course_id': course, 'assignment_id': aid})
    report(f'get-assignment-submit-link {aid}', status, body, limit=110)
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
before = {p.name for p in downloads.glob('*')} if downloads.is_dir() else set()
if documents:
    course, doc = documents[0]
    status, body, _ = call('get-document-link', {'course_id': course, 'document_id': doc})
    report(f'get-document-link {doc}', status, body, limit=120)
    if is_error_page(body) or status != 200:
        failures.append(('get-document-link valid', status, body[:300]))

    after = {p.name for p in downloads.glob('*')} if downloads.is_dir() else set()
    new = [n for n in sorted(after - before) if not re.match(r'Error\.', n, re.I)]
    if new:
        print(f'{"":<46} {"":<4} saved {" ".join(new)}')
    else:
        failures.append(('get-document-link wrote nothing', 0, ''))
        print(f'{"":<46} {"":<4} <-- FAIL (no file saved for a valid id)')

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
for name, args in (
    ('send-mio-message', {'to': BOGUS_UUID, 'subject': 'probe', 'body': 'probe'}),
    ('reply-mio-message', {'message_id': BOGUS_UUID, 'body': 'probe'}),
    ('delete-mio-message', {'message_id': BOGUS_UUID}),
    ('move-mio-message', {'message_id': BOGUS_UUID, 'folder_id': 'SEARCH_FOLDER_MioRecu'}),
    ('restore-mio-message', {'message_id': BOGUS_UUID}),
    ('flag-mio-message', {'message_id': BOGUS_UUID, 'flagged': True}),
    ('create-mio-folder', {'name': ''}),
):
    if name not in tools:
        continue
    status, body, _ = call(name, args)
    report(name, status, body, expect_error=True, limit=110)

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
