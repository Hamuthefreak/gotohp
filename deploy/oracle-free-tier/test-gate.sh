#!/usr/bin/env bash
# Proves the public gatekeeper before it is shipped: first-run password, login,
# bearer-token proxy, token rotation, rate limiting and cross-origin refusal.
# No box and no network: a fake MCP server stands in for omnivox-mcp, and the
# gatekeeper runs on a loopback port with a throwaway data directory.

set -uo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 1
pass=0
fail=0

ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() {
	printf '  FAIL %s\n' "$1"
	fail=$((fail + 1))
}
check() {
	local label=$1 expected=$2 actual=$3
	if [[ $actual == "$expected" ]]; then ok "$label"; else no "$label (wanted $expected, got $actual)"; fi
}
contains() {
	local label=$1 needle=$2 hay=$3
	if [[ $hay == *"$needle"* ]]; then ok "$label"; else no "$label (missing: $needle)"; fi
}

command -v node >/dev/null 2>&1 || {
	echo 'node is required to test the gatekeeper'
	exit 1
}
command -v curl >/dev/null 2>&1 || {
	echo 'curl is required to test the gatekeeper'
	exit 1
}

tmp=$(mktemp -d)
gate_port=$((18000 + RANDOM % 400))
up_port=$((18400 + RANDOM % 400))
gate_pid=''
up_pid=''

cleanup() {
	[[ -n $gate_pid ]] && kill "$gate_pid" 2>/dev/null
	[[ -n $up_pid ]] && kill "$up_pid" 2>/dev/null
	rm -rf "$tmp"
}
trap cleanup EXIT

cat >"$tmp/upstream.mjs" <<'JS'
import http from 'node:http';
http
	.createServer((req, res) => {
		let body = '';
		req.on('data', (c) => (body += c));
		req.on('end', () => {
			res.writeHead(200, { 'content-type': 'application/json' });
			res.end(
				JSON.stringify({
					path: req.url,
					method: req.method,
					key: req.headers['x-mcp-auth'] || '',
					authorization: req.headers.authorization || '',
					cookie: req.headers.cookie || '',
					body,
				}),
			);
		});
	})
	.listen(Number(process.argv[2]), '127.0.0.1');
JS

printf 'the-omnivox-access-key' >"$tmp/key.txt"
mkdir -p "$tmp/data"

node "$tmp/upstream.mjs" "$up_port" &
up_pid=$!
DATA_DIR="$tmp/data" OMNIVOX_KEY_FILE="$tmp/key.txt" PORT="$gate_port" \
	UPSTREAM="http://127.0.0.1:$up_port" GATE_USERNAME=2652532 \
	node ./gate.mjs >"$tmp/gate.log" 2>&1 &
gate_pid=$!

base="http://127.0.0.1:$gate_port"
for _ in $(seq 1 50); do
	curl -fsS "$base/healthz" >/dev/null 2>&1 && break
	sleep 0.1
done
if ! curl -fsS "$base/healthz" >/dev/null 2>&1; then
	echo 'the gatekeeper did not start:'
	cat "$tmp/gate.log"
	exit 1
fi

code=$(cat "$tmp/data/setup-code.txt" 2>/dev/null || true)
if [[ -n $code ]]; then ok 'first run prints a setup code'; else no 'first run prints a setup code'; fi
token_file="$tmp/data/token.txt"

echo 'public endpoints'
check 'healthz answers without a login' 200 "$(curl -s -o /dev/null -w '%{http_code}' "$base/healthz")"
contains 'healthz carries no secret' '"ok":true' "$(curl -s "$base/healthz")"
check 'the dashboard redirects to setup on first run' 303 \
	"$(curl -s -o /dev/null -w '%{http_code}' "$base/")"
check 'the setup page is reachable' 200 "$(curl -s -o /dev/null -w '%{http_code}' "$base/setup")"
contains 'the setup page shows the username' '2652532' "$(curl -s "$base/setup")"
check 'the MCP proxy refuses an anonymous request' 401 \
	"$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/mcp")"

echo 'first-run password'
check 'a wrong setup code is refused' 403 \
	"$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/setup" -d "code=nope&password=longenough1&password2=longenough1")"
check 'a short password is refused' 400 \
	"$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/setup" -d "code=$code&password=short&password2=short")"
check 'mismatched passwords are refused' 400 \
	"$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/setup" -d "code=$code&password=longenough1&password2=longenough2")"
check 'a cross-origin setup post is refused' 403 \
	"$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/setup" -H 'Origin: https://evil.example' -d "code=$code&password=longenough1&password2=longenough1")"

setup_code=$(curl -s -o "$tmp/setup.out" -w '%{http_code}' -c "$tmp/jar" -X POST "$base/setup" \
	-d "code=$code&password=correct-horse-battery&password2=correct-horse-battery")
check 'the right setup code sets the password' 303 "$setup_code"
grep -q ovx_session "$tmp/jar" 2>/dev/null && ok 'setup signs you in' || no 'setup signs you in'
[[ -f $tmp/data/auth.json ]] && ok 'the password is stored' || no 'the password is stored'
grep -q 'correct-horse-battery' "$tmp/data/auth.json" 2>/dev/null && no 'the password is not stored in clear' || ok 'the password is not stored in clear'
[[ -f $tmp/data/setup-code.txt ]] && no 'the setup code is consumed' || ok 'the setup code is consumed'
check 'setup is closed once a password exists' 303 \
	"$(curl -s -o /dev/null -w '%{http_code}' "$base/setup")"

echo 'dashboard'
dash=$(curl -s -b "$tmp/jar" "$base/")
contains 'the dashboard renders' 'Bearer token' "$dash"
contains 'the dashboard shows the token' "$(cat "$token_file")" "$dash"
contains 'the dashboard shows the relay' 'photo relay' "$dash"
if grep -q 'the-omnivox-access-key' <<<"$dash"; then no 'the dashboard leaks the Omnivox key'; else ok 'the dashboard never shows the Omnivox key'; fi
check 'the summary api needs a login' 401 "$(curl -s -o /dev/null -w '%{http_code}' "$base/api/summary")"
contains 'the summary api returns json' '"mcpUrl"' "$(curl -s -b "$tmp/jar" "$base/api/summary")"

echo 'bearer token proxy'
tok=$(cat "$token_file")
check 'a bad token is refused' 401 \
	"$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/mcp" -H 'Authorization: Bearer nope')"
check 'the bearer token is accepted' 200 \
	"$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/mcp" -H "Authorization: Bearer $tok")"
body=$(curl -s -X POST "$base/mcp" -H "Authorization: Bearer $tok" -d '{"jsonrpc":"2.0"}')
contains 'the proxy reaches the MCP server' '"path":"/mcp"' "$body"
contains 'the proxy injects the Omnivox key' '"key":"the-omnivox-access-key"' "$body"
if grep -q "$tok" <<<"$body"; then no 'the client token is forwarded upstream'; else ok 'the client token never reaches the MCP server'; fi
contains 'the tools route is proxied' '"path":"/tools"' \
	"$(curl -s "$base/tools" -H "Authorization: Bearer $tok")"
contains 'a ?key= query still works' '"path":"/tools"' \
	"$(curl -s "$base/tools?key=$tok")"
check 'a wrong ?key= is refused' 401 "$(curl -s -o /dev/null -w '%{http_code}' "$base/tools?key=wrong")"

echo 'token rotation'
check 'rotation is accepted' 303 \
	"$(curl -s -o /dev/null -w '%{http_code}' -b "$tmp/jar" -X POST "$base/api/token/rotate")"
newtok=$(cat "$token_file")
[[ $newtok != "$tok" ]] && ok 'rotation changes the token' || no 'rotation changes the token'
check 'the old token stops working' 401 \
	"$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/mcp" -H "Authorization: Bearer $tok")"
check 'the new token works' 200 \
	"$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/mcp" -H "Authorization: Bearer $newtok")"

echo 'login'
curl -s -o /dev/null -b "$tmp/jar" -c "$tmp/jar" "$base/logout"
check 'the dashboard needs a login again' 303 "$(curl -s -o /dev/null -w '%{http_code}' -b "$tmp/jar" "$base/")"
check 'a wrong password is refused' 401 \
	"$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/login" -d 'username=2652532&password=wrong-password')"
check 'a wrong username is refused' 401 \
	"$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/login" -d "username=999&password=correct-horse-battery")"
check 'a cross-origin login is refused' 403 \
	"$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/login" -H 'Origin: https://evil.example' -d 'username=2652532&password=correct-horse-battery')"
check 'the right password signs in' 303 \
	"$(curl -s -o /dev/null -w '%{http_code}' -c "$tmp/jar2" -X POST "$base/login" -d 'username=2652532&password=correct-horse-battery')"
check 'the signed-in dashboard renders' 200 "$(curl -s -o /dev/null -w '%{http_code}' -b "$tmp/jar2" "$base/")"

echo 'brute force'
codes=''
for _ in $(seq 1 12); do
	codes+=$(curl -s -o /dev/null -w '%{http_code} ' -X POST "$base/login" -d 'username=2652532&password=nope-nope-nope')
done
contains 'attempts are throttled after ten' 429 "$codes"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
