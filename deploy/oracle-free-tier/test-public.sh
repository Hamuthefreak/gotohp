#!/usr/bin/env bash
# Runs ON the relay box, after the gate is installed. Drives the *public*
# Cloudflare URL the way an MCP client would: no loopback shortcuts, the token
# the dashboard hands out, and the real Omnivox session behind it.
#
#   sudo bash test-public.sh
#
# Checks: /healthz, the setup redirect, /mcp refusing a tokenless call, and then
# the download guard - a bad document id must fail and leave no file, a good one
# must save the real document.

set -uo pipefail

GATE_BIN=${GATE_BIN:-/tmp/ovx-gate-ship/omnivox-gate.sh}
DATA=${DATA:-/opt/omnivox-mcp/data}
DOWNLOADS=$DATA/downloads
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() {
	printf '  FAIL %s\n' "$1"
	fail=$((fail + 1))
}

[[ -r $GATE_BIN ]] || {
	echo "cannot read $GATE_BIN" >&2
	exit 1
}

url=$(bash "$GATE_BIN" url 2>/dev/null || true)
if [[ -z $url ]]; then
	echo 'no public url yet (is the tunnel up?)' >&2
	exit 1
fi
echo "public url: $url"

# A quick tunnel registers its hostname a moment after cloudflared starts, so
# the first request of a fresh install can answer 000. Wait for the host to
# serve /healthz before asserting anything; a deploy that skipped this failed
# six checks against a tunnel that was up seconds later.
ready=no
for _ in $(seq 1 30); do
	if [[ $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url/healthz") == 200 ]]; then
		ready=yes
		break
	fi
	sleep 2
done
if [[ $ready == no ]]; then
	echo "the tunnel never answered at $url/healthz" >&2
	exit 1
fi

# Never printed: this is the same secret the dashboard shows.
token=$(bash "$GATE_BIN" token) || {
	echo 'could not get the mcp token' >&2
	exit 1
}
[[ -n $token ]] || {
	echo 'empty mcp token' >&2
	exit 1
}

code=$(curl -s -o "$TMP/body" -w '%{http_code}' --max-time 30 "$url/healthz")
if [[ $code == 200 ]] && grep -q '"ok":true' "$TMP/body"; then
	ok '/healthz answers 200 ok'
else
	no "/healthz answered $code: $(head -c 120 "$TMP/body")"
fi

code=$(curl -s -o /dev/null -D "$TMP/head" -w '%{http_code}' --max-time 30 "$url/")
loc=$(grep -i '^location:' "$TMP/head" | tr -d '\r' | awk '{print $2}')
if [[ $code == 303 && $loc =~ /(setup|login)$ ]]; then
	ok "/ redirects to ${loc##*/}"
else
	no "/ answered $code location '$loc' (expected 303 to /setup or /login)"
fi

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X POST "$url/mcp" \
	-H 'content-type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
[[ $code == 401 ]] && ok '/mcp refuses a call without a token' || no "/mcp without a token answered $code"

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X POST "$url/mcp" \
	-H 'authorization: Bearer wrong-token' -H 'content-type: application/json' \
	-d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
[[ $code == 401 ]] && ok '/mcp refuses a wrong token' || no "/mcp with a wrong token answered $code"

code=$(curl -s -o "$TMP/tools" -w '%{http_code}' --max-time 60 -X POST "$url/mcp" \
	-H "authorization: Bearer $token" -H 'content-type: application/json' \
	-H 'accept: application/json, text/event-stream' \
	-d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
if [[ $code == 200 ]] && grep -q '"tools"' "$TMP/tools"; then
	ok '/mcp lists tools for the bearer token'
else
	no "/mcp tools/list answered $code: $(head -c 160 "$TMP/tools")"
fi

tool() {
	local name=$1 body=$2
	curl -s -o "$TMP/tool" -w '%{http_code}' --max-time 150 -X POST "$url/tools/$name" \
		-H "authorization: Bearer $token" -H 'content-type: application/json' -d "$body"
}

tool get-courses-summary '{}' >/dev/null
course=$(grep -oE '\([0-9A-Z]{4,}\.[0-9]{4,}\)' "$TMP/tool" 2>/dev/null | head -n 1 | tr -d '()')
if [[ -n ${course:-} ]]; then
	ok "course id harvested from the account ($course)"
else
	no 'no course id in the courses summary'
fi

doc_id=''
if [[ -n ${course:-} ]]; then
	code=$(tool get-course-documents "{\"course_id\":\"$course\"}")
	doc_id=$(sed -n 's/^- ID: //p' "$TMP/tool" | head -n 1)
	if [[ $code == 200 && -n $doc_id ]]; then
		ok "document id harvested ($doc_id)"
	else
		no "could not list documents for $course (status $code)"
	fi
fi

# The old behaviour wrote the error page into the downloads folder. Clear any
# leftover so the assertion below is about this run.
rm -f "$DOWNLOADS/Error.txt"

if [[ -n ${course:-} && -n $doc_id ]]; then
	# A valid id still works.
	code=$(tool get-document-link "{\"course_id\":\"$course\",\"document_id\":\"$doc_id\"}")
	saved=$(sed -n 's/^File saved to: //p' "$TMP/tool" | head -n 1)
	if [[ $code == 200 && -n $saved && -s $saved ]] && [[ $(basename "$saved") != Error.txt ]]; then
		ok "a valid document saves the real file ($(basename "$saved"), $(wc -c <"$saved") bytes)"
	else
		no "a valid document did not save (status $code): $(head -c 160 "$TMP/tool")"
	fi
fi

if [[ -n ${course:-} ]]; then
	# A bogus id must not look like a success.
	code=$(tool get-document-link "{\"course_id\":\"$course\",\"document_id\":\"999999999999999\"}")
	body=$(head -c 400 "$TMP/tool")
	if [[ $code != 200 ]]; then
		ok "a bogus document id answers $code"
	elif grep -qiE 'error|not found|instead of a file' <<<"$body" && ! grep -q 'File saved to: ' <<<"$body"; then
		ok 'a bogus document id answers 200 with an explicit error'
	else
		no "a bogus document id answered $code like a success: $body"
	fi
	if [[ -e $DOWNLOADS/Error.txt ]]; then
		no "the bogus call wrote $DOWNLOADS/Error.txt"
	else
		ok 'the bogus call wrote no file'
	fi
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
