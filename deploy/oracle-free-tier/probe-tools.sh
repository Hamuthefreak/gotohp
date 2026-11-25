#!/usr/bin/env bash
# Runs ON the relay box. Walks every tool the MCP server registers, calls the
# read-only ones and prints what came back, so a broken tool is visible without
# a client. Write tools are skipped on purpose: this must never message anyone.
#
#   sudo bash probe-tools.sh            every read-only tool
#   sudo bash probe-tools.sh --all      also the write tools (don't)

set -uo pipefail

BASE=${BASE:-http://127.0.0.1:3000}
KEY_FILE=${KEY_FILE:-/opt/omnivox-mcp/data/accessKey.txt}
ALL=0
[[ ${1:-} == --all ]] && ALL=1

key=$(cat "$KEY_FILE" 2>/dev/null || true)
[[ -n $key ]] || {
	echo "no access key in $KEY_FILE" >&2
	exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

curl -fsS "$BASE/tools" -H "x-mcp-auth: $key" -o "$tmp/tools.json" || {
	echo 'the MCP server did not list its tools' >&2
	exit 1
}

count=$(python3 - "$tmp/tools.json" <<'PY'
import json,sys
doc=json.load(open(sys.argv[1]))
print(len(doc.get('tools',[])))
PY
)
echo "tools registered: $count"
echo

# One line per tool: name, status, and the first thing the tool said.
python3 - "$tmp/tools.json" >"$tmp/plan.tsv" <<'PY'
import json,sys
doc=json.load(open(sys.argv[1]))
write_words=('send','reply','delete','move','restore','create','flag','mark','upload','cancel','reply')
for tool in doc.get('tools',[]):
    name=tool.get('name','')
    schema=tool.get('inputSchema') or {}
    required=schema.get('required') or []
    write=any(name.startswith(w) for w in write_words) or 'send' in name or 'reply' in name
    print('\t'.join([name,'write' if write else 'read',','.join(required)]))
PY

ok=0
skipped=0
needs_args=0
failed=0

while IFS=$'\t' read -r name kind required; do
	if [[ $kind == write && $ALL -eq 0 ]]; then
		printf '%-38s SKIP   write tool\n' "$name"
		skipped=$((skipped+1))
		continue
	fi
	code=$(curl -s --max-time 120 -o "$tmp/body" -w '%{http_code}' \
		-X POST "$BASE/tools/$name" \
		-H "x-mcp-auth: $key" -H 'content-type: application/json' -d '{}')
	first=$(head -c 240 "$tmp/body" | tr '\n\t' '  ')
	case $code in
	200) ok=$((ok+1)) ;;
	400)
		needs_args=$((needs_args+1))
		if [[ -n $required ]]; then first="needs: $required"; fi
		;;
	*)
		failed=$((failed+1))
		;;
	esac
	printf '%-38s %-6s %s\n' "$name" "$code" "$first"
done <"$tmp/plan.tsv"

echo
printf '%d answered, %d need arguments, %d skipped, %d failed\n' "$ok" "$needs_args" "$skipped" "$failed"

# Tools that need ids were only argued with. This second pass takes real ids out
# of the answers above and calls those tools for real, which is where a wrong
# URL or a missing field shows up.
echo
echo '--- deep probe (real ids) ---'
python3 - "$BASE" "$key" <<'PY'
import json, re, sys, urllib.error, urllib.request

base, key = sys.argv[1], sys.argv[2]
fail = []


def call(name, args=None):
    data = json.dumps(args or {}).encode()
    req = urllib.request.Request(
        f"{base}/tools/{name}", data=data,
        headers={"x-mcp-auth": key, "content-type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=150) as res:
            return res.status, res.read().decode()
    except urllib.error.HTTPError as err:
        return err.code, err.read().decode()
    except Exception as err:  # noqa: BLE001 - a probe reports, never raises
        return 0, f"{type(err).__name__}: {err}"


def show(label, status, body, limit=200):
    body = " ".join(body.split())[:limit]
    mark = "" if status == 200 else "  <-- " + ("FAIL" if status not in (400,) else "needs args")
    if status not in (200, 400):
        fail.append((label, status, body))
    print(f"{label:<44} {status:<4} {body}{mark}")


status, courses_text = call("get-courses-summary")
show("get-courses-summary (for ids)", status, courses_text, 80)
courses = list(dict.fromkeys(re.findall(r"\(([0-9A-Z]{4,}\.[0-9]{4,})\)", courses_text)))[:2]
if not courses:
    print("no course ids found; skipping the course-scoped tools")

for course in courses:
    print(f"\ncourse {course}")
    for tool in (
        "get-course-info",
        "get-course-assignments",
        "get-course-announcements",
        "get-course-documents",
        "get-course-evals",
        "get-course-people",
    ):
        status, body = call(tool, {"course_id": course})
        show(f"  {tool}", status, body, 160)
        if status != 200:
            continue
        if tool == "get-course-assignments":
            ids = list(dict.fromkeys(re.findall(r"(?:^|[\s:(])(\d{4,8})\b", body)))[:1]
            for aid in ids:
                status, detail = call("get-assignment-detail", {"course_id": course, "assignment_id": aid})
                show(f"    get-assignment-detail {aid}", status, detail, 160)
                status, link = call("get-assignment-submit-link", {"course_id": course, "assignment_id": aid})
                show(f"    get-assignment-submit-link {aid}", status, link, 120)

status, messages = call("get-mio-messages")
show("get-mio-messages (for ids)", status, messages, 120)
msg_ids = list(dict.fromkeys(re.findall(r"\b([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\b", messages)))[:1]
for mid in msg_ids:
    status, body = call("read-mio-message", {"message_id": mid})
    show("read-mio-message", status, body, 160)

for tool, args in (
    ("search-mio-messages", {"query": "vanier"}),
    ("search-people", {"query": "smith"}),
    ("get-service-link", {"service": "mio"}),
    ("get-document-link", {"course_id": courses[0] if courses else "", "document_id": "0"}),
):
    status, body = call(tool, args)
    show(tool, status, body, 160)

print()
if fail:
    print(f"deep probe: {len(fail)} call(s) failed")
    sys.exit(1)
print("deep probe: every call answered or asked for valid arguments")
PY

