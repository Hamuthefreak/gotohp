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
[[ $failed -eq 0 ]]
