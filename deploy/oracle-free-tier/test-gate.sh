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
	"$(curl -s -o /dev/null -w '%{http_code}' -b "$tmp/jar" -X POST "$base/api/token/rotate" -H "Origin: $base")"
# The page sends Referrer-Policy: no-referrer, so Chrome puts the literal
# "null" in Origin on every form post. A dashboard button that arrives that way
# has to work, or nobody can rotate anything from the page.
check 'a form post with the browser null origin is accepted' 303 \
	"$(curl -s -o /dev/null -w '%{http_code}' -b "$tmp/jar" -X POST "$base/api/token/rotate" -H 'Origin: null')"
check 'a cross-origin form post is still refused' 403 \
	"$(curl -s -o /dev/null -w '%{http_code}' -b "$tmp/jar" -X POST "$base/api/token/rotate" -H 'Origin: https://evil.example')"
newtok=$(cat "$token_file")
[[ $newtok != "$tok" ]] && ok 'rotation changes the token' || no 'rotation changes the token'
check 'the old token stops working' 401 \
	"$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/mcp" -H "Authorization: Bearer $tok")"
check 'the new token works' 200 \
	"$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/mcp" -H "Authorization: Bearer $newtok")"

# A jar kept for the session checks, written as well as read: a read-only jar
# used to keep the cookie that /login had just rotated away under it.
curl -s -o /dev/null -c "$tmp/jar4" -X POST "$base/login" -d 'username=2652532&password=correct-horse-battery'

echo 'dashboard page: styled, scripted, permitted'
# The page has to be a styled document, not bare markup: it names a stylesheet,
# that stylesheet and its script are served with the right type and a real
# body, and it carries no inline script or style of its own - because the gate
# sends a policy without 'unsafe-inline', which would block them.
# /login and /logout above both answer with Set-Cookie, so the jar has to be
# written as well as read: a read-only jar kept the cookie /logout expired.
doc=$(curl -s -D "$tmp/doc.head" -b "$tmp/jar4" -c "$tmp/jar4" "$base/")
check 'the signed-in dashboard answers 200 here' 200 "$(grep -m1 '^HTTP' "$tmp/doc.head" | awk '{print $2}')"
contains 'the dashboard links its stylesheet' 'href="/assets/app.css"' "$doc"
contains 'the dashboard loads its script' 'src="/assets/setup.js"' "$doc"
# A style attribute counts: 'style-src self' refuses it exactly as it refuses
# a <style> block, and the browser console is where that showed up first.
if grep -qiE '<script[^>]*>[^<[:space:]]|<style|<[^>]+ on[a-z]+=|<[^>]+ style=' <<<"$doc"; then
	no "the dashboard has no inline script, style or handler for the CSP to block ($(grep -oiE '<[^>]+ style=[^ >]*' <<<"$doc" | head -n 1))"
else
	ok 'the dashboard has no inline script, style or handler for the CSP to block'
fi
csp=$(grep -i '^content-security-policy:' "$tmp/doc.head" | tr -d '\r' | sed 's/^[^:]*: //')
contains 'the dashboard sends a CSP' "script-src 'self'" "$csp"
contains 'the CSP forbids inline script' "default-src 'none'" "$csp"
if grep -q 'unsafe-inline' <<<"$csp"; then no 'the CSP keeps unsafe-inline out'; else ok 'the CSP keeps unsafe-inline out'; fi
css_type=$(curl -s -o "$tmp/app.css" -D "$tmp/css.head" -w '%{http_code}' "$base/assets/app.css")
css_ct=$(grep -i '^content-type:' "$tmp/css.head" | tr -d '\r' | awk '{print $2}')
check 'the stylesheet answers 200' 200 "$css_type"
contains 'the stylesheet is served as CSS' 'text/css' "$css_ct"
css_size=$(wc -c <"$tmp/app.css")
((css_size > 2000)) && ok "the stylesheet has its rules ($css_size bytes)" || no "the stylesheet has its rules (only $css_size bytes)"
contains 'the stylesheet styles the cards the page uses' '.card{' "$(cat "$tmp/app.css")"
js_type=$(curl -s -o "$tmp/setup.js" -D "$tmp/js.head" -w '%{http_code}' "$base/assets/setup.js")
js_ct=$(grep -i '^content-type:' "$tmp/js.head" | tr -d '\r' | awk '{print $2}')
check 'the script answers 200' 200 "$js_type"
contains 'the script is served as JavaScript' 'text/javascript' "$js_ct"
js=$(cat "$tmp/setup.js")
contains 'Copy is wired to the clipboard' 'navigator.clipboard.writeText' "$js"
contains 'Copy reads the field the button names' "box.dataset.copy" "$js"
contains 'Copy shows its feedback' "textContent = 'Copied'" "$js"
contains 'Rotate is wired through its form' 'action="/api/token/rotate"' "$doc"
contains 'Rotate carries its confirmation prompt' 'data-confirm="Rotate the token?' "$doc"
contains 'Rotate asks before it acts' "if (!window.confirm(form.dataset.confirm))" "$js"
# The Copy button must point at a field that exists, or the click does nothing.
copy_id=$(grep -oE 'data-copy="[a-z]+"' <<<"$doc" | head -n 1 | sed 's/.*="//;s/"//')
if [[ -n $copy_id ]] && grep -q "id=\"$copy_id\"" <<<"$doc"; then
	ok "the Copy button targets a field on the page (#$copy_id)"
else
	no "the Copy button targets a field on the page (#${copy_id:-none})"
fi

echo 'dashboard session'
# A session must not wear out: twelve page views in a row on one cookie jar, each
# a fresh authenticated render. A bounce to /login or /setup, or a 401, fails.
views_ok=0
views_bad=''
for view in $(seq 1 14); do
	code=$(curl -s -o "$tmp/view.$view" -D "$tmp/view.head" -b "$tmp/jar4" -c "$tmp/jar4" -w '%{http_code}' "$base/")
	if [[ $code == 200 ]] && grep -q 'Bearer token' "$tmp/view.$view" && grep -q "$(cat "$token_file")" "$tmp/view.$view"; then
		views_ok=$((views_ok + 1))
	else
		views_bad+="$view:$code "
	fi
done
check 'fourteen sequential dashboard views all answer authenticated 200' 14 "$views_ok"
[[ -z $views_bad ]] || no "every view is authenticated (bad views: $views_bad)"
grep -qi '^set-cookie' "$tmp/view.head" && no 'a plain page view does not re-issue the session' || ok 'a plain page view does not re-issue the session'
# The throttling counts wrong passwords per ip. It must not lock out a session
# that is already signed in, nor a sign-in from a different address.
for _ in $(seq 1 11); do curl -s -o /dev/null -H 'CF-Connecting-IP: 198.51.100.4' -X POST "$base/login" -d 'username=2652532&password=typo-typo-typo'; done
check 'the right password is refused from a throttled ip' 429 \
	"$(curl -s -o /dev/null -w '%{http_code}' -H 'CF-Connecting-IP: 198.51.100.4' -X POST "$base/login" -d 'username=2652532&password=correct-horse-battery')"
check 'the throttled ip still sees its own dashboard' 200 \
	"$(curl -s -o "$tmp/after" -w '%{http_code}' -b "$tmp/jar4" "$base/")"
grep -q 'Bearer token' "$tmp/after" && ok 'and that page is the real dashboard' || no 'and that page is the real dashboard'
check 'a different ip signs in normally' 303 \
	"$(curl -s -o /dev/null -w '%{http_code}' -X POST "$base/login" -H 'CF-Connecting-IP: 203.0.113.9' -d 'username=2652532&password=correct-horse-battery')"

if [[ ${GATE_BROWSER:-auto} != off ]]; then
	echo 'dashboard in a real browser'
	set +e
	PUPPETEER_ROOT=${PUPPETEER_ROOT:-} CHROME_PATH=${CHROME_PATH:-} node ./test-gate-browser.mjs ./gate.mjs
	browser_rc=$?
	set -e
	if ((browser_rc == 0)); then
		ok 'the browser test passed (see its checks above)'
	elif ((browser_rc == 2)); then
		echo '  skip no headless browser here: the styles, CSP, Copy and Rotate are proven at HTTP/JS level only'
	else
		no 'the browser test passed'
	fi
fi

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
# One wrong click must not sign the browser out: the counting hits above only
# throttle the wrong password, never the right one.
check 'a wrong password does not kill the session' 200 \
	"$(curl -s -o /dev/null -w '%{http_code}' -b "$tmp/jar2" "$base/")"
# The first-run page must fetch its stylesheet and script, otherwise it is bare.
check 'the stylesheet is served' 200 "$(curl -s -o /dev/null -w '%{http_code}' "$base/assets/app.css")"
check 'the setup script is served' 200 "$(curl -s -o /dev/null -w '%{http_code}' "$base/assets/setup.js")"
check 'wrong passwords alone are what gets throttled' 303 \
	"$(curl -s -o /dev/null -w '%{http_code}' -c "$tmp/jar3" -X POST "$base/login" -H 'CF-Connecting-IP: 203.0.113.9' -d 'username=2652532&password=correct-horse-battery')"
check 'and that new session renders' 200 "$(curl -s -o /dev/null -w '%{http_code}' -b "$tmp/jar3" "$base/")"

echo 'brute force'
codes=''
for _ in $(seq 1 12); do
	codes+=$(curl -s -o /dev/null -w '%{http_code} ' -X POST "$base/login" -d 'username=2652532&password=nope-nope-nope')
done
contains 'attempts are throttled after ten' 429 "$codes"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
