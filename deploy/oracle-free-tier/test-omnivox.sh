#!/usr/bin/env bash
# Proves omnivox-mcp.sh generates the right unit and environment before a deploy
# ships them to the box. No box, no node, no network: every check is on the text
# the installer would write and on its argument handling.

set -uo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")" || exit 1
SELF=./omnivox-mcp.sh
pass=0
fail=0

ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
no() {
	printf '  FAIL %s\n' "$1"
	fail=$((fail + 1))
}

has() {
	local label=$1 needle=$2 hay=$3
	if [[ $hay == *"$needle"* ]]; then
		ok "$label"
	else
		no "$label (missing: $needle)"
	fi
}

lacks() {
	local label=$1 needle=$2 hay=$3
	if [[ $hay == *"$needle"* ]]; then
		no "$label (unexpected: $needle)"
	else
		ok "$label"
	fi
}

# shellcheck source=omnivox-mcp.sh
OMNIVOX_LIB=1 . "$SELF"

echo 'environment file'
env_text=$(render_env)
has 'sets the port' 'PORT=3000' "$env_text"
has 'points the server at the data folder' "OMNIVOX_DATA_DIR=$DATA" "$env_text"
has 'keeps the puppeteer cache inside the prefix' "PUPPETEER_CACHE_DIR=$APP/.puppeteer" "$env_text"
has 'asks chrome to sleep between requests' 'BROWSER_SLEEP=true' "$env_text"
has 'disables the sandbox for this kernel' '--no-sandbox' "$env_text"
has 'avoids the 64 MB /dev/shm' '--disable-dev-shm-usage' "$env_text"
lacks 'never carries the access key' 'accessKey' "$env_text"
lacks 'never carries a session cookie' '"cookies"' "$env_text"

PORT=4567
has 'a --port override reaches the file' 'PORT=4567' "$(render_env)"
PORT=3000
BROWSER_SLEEP=false
has 'a resident browser is possible' 'BROWSER_SLEEP=false' "$(render_env)"
BROWSER_SLEEP=true

first=$(render_env)
second=$(render_env)
if [[ $first == "$second" ]]; then
	ok 'rendering twice is identical (a redeploy changes nothing)'
else
	no 'rendering twice is identical'
fi

echo 'systemd unit'
unit=$(render_unit)
has 'runs as the service user' 'User=omnivox' "$unit"
has 'runs from the source directory' "WorkingDirectory=$APP" "$unit"
has 'reads the environment file' "EnvironmentFile=$ENV_FILE" "$unit"
has 'starts the project the way it documents' 'ExecStart=/usr/bin/npm start' "$unit"
has 'comes back after a crash' 'Restart=always' "$unit"
has 'signals npm and kills its children' 'KillMode=mixed' "$unit"
has 'caps memory' 'MemoryMax=768M' "$unit"
has 'allows a little swap before the cap' 'MemorySwapMax=1G' "$unit"
has 'privacy of the data folder' 'UMask=0077' "$unit"
has 'cannot escalate' 'NoNewPrivileges=yes' "$unit"
has 'writes only inside the prefix' "ReadWritePaths=$PREFIX" "$unit"
has 'is enabled at boot' 'WantedBy=multi-user.target' "$unit"

echo 'argument handling'
echo 'start decision'
# The server exits immediately when config.json is missing. A unit that starts
# anyway turns that into a crash loop, so this branch is the one that matters.
tmp=$(mktemp -d)
DATA=$tmp
if [[ $(start_decision) == wait ]]; then
	ok 'waits for a session instead of crash-looping'
else
	no 'waits for a session instead of crash-looping'
fi
printf 'x' >"$tmp/cookies.json"
printf 'x' >"$tmp/config.json"
if [[ $(start_decision) == start ]]; then
	ok 'starts once both files are present'
else
	no 'starts once both files are present'
fi
rm -rf "$tmp"

rc=0
validate_port 3000 || rc=$?
((rc == 0)) && ok 'accepts the default port' || no 'accepts the default port'
for bad in 80 0 65536 99999 abc ''; do
	rc=0
	validate_port "$bad" || rc=$?
	((rc != 0)) && ok "rejects port '${bad}'" || no "rejects port '${bad}'"
done

rc=0
validate_ref main || rc=$?
((rc == 0)) && ok 'accepts an ordinary branch' || no 'accepts an ordinary branch'
rc=0
validate_ref v3.8.0 || rc=$?
((rc == 0)) && ok 'accepts a tag' || no 'accepts a tag'
for bad in 'main; rm -rf /' '$(id)' 'a..b' '' '-x'; do
	rc=0
	validate_ref "$bad" || rc=$?
	((rc != 0)) && ok "rejects ref '${bad}'" || no "rejects ref '${bad}'"
done

rc=0
bash "$SELF" --help >/dev/null 2>&1 || rc=$?
((rc == 0)) && ok '--help exits 0' || no '--help exits 0'

rc=0
bash "$SELF" nonsense >/dev/null 2>&1 || rc=$?
((rc == 2)) && ok 'an unknown command exits 2' || no "an unknown command exits 2 (got $rc)"

rc=0
bash "$SELF" --port 12 status >/dev/null 2>&1 || rc=$?
((rc == 2)) && ok 'a bad --port is refused before anything runs' || no "a bad --port is refused (got $rc)"

rc=0
bash "$SELF" session >/dev/null 2>&1 || rc=$?
((rc != 0)) && ok 'session without files fails instead of half-importing' || no 'session without files fails'

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
