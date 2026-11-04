#!/usr/bin/env bash
# Contract tests for sync.sh, run with a stub uploader so no Google account is
# needed and nothing leaves the machine.
#
#   bash deploy/oracle-free-tier/test-sync.sh
#
# Covers: first-pass deferral, Live Photo pairing inside one invocation, file
# type filtering, the quiet-interval stability gate, idempotency, per-file
# failure isolation, outage handling, flock, dry run, the --delete opt-in and
# the configuration guard rails.

set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SYNC=$HERE/sync.sh
[[ -f $SYNC ]] || {
	echo "sync.sh not found next to this script" >&2
	exit 2
}
bash -n "$SYNC" || exit 2

BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT
mkdir -p "$BASE/repo/2024/07" "$BASE/repo/.watermelon/locks" "$BASE/state"
export FAKE_LOG="$BASE/calls.log"
: >"$FAKE_LOG"

# Stub uploader: logs argv, fails on any path containing BAD, or on every path
# when FAKE_FAIL_ALL=1 (simulated outage).
cat >"$BASE/fake-gotohp" <<'STUB'
#!/usr/bin/env bash
printf 'CALL %s\n' "$*" >>"$FAKE_LOG"
if [[ ${FAKE_FAIL_ALL:-0} == 1 ]]; then
	echo '{"failed":1,"error":"simulated outage"}'
	exit 1
fi
for arg in "$@"; do
	if [[ $arg == *BAD* ]]; then
		printf '{"path":"%s","success":false,"error":"upload rejected"}\n' "$arg"
		exit 1
	fi
done
echo '{"succeeded":1}'
exit 0
STUB
chmod +x "$BASE/fake-gotohp"

cat >"$BASE/test.env" <<ENV
SRC_DIR=$BASE/repo
STATE_DIR=$BASE/state
GOTOHP_BIN=$BASE/fake-gotohp
GOTOHP_CONFIG=$BASE/state/gotohp.config
BATCH_SIZE=50
PAIR_LIVE_PHOTOS=true
ENV
: >"$BASE/state/gotohp.config"

pass=0
fail=0
RC=0
ck() {
	if eval "$2"; then
		printf 'PASS  %s\n' "$1"
		pass=$((pass + 1))
	else
		printf 'FAIL  %s\n' "$1"
		fail=$((fail + 1))
	fi
}
run() {
	GOTOHP_SYNC_CONFIG=${1:-$BASE/test.env} bash "$SYNC" >"$BASE/out" 2>&1
	RC=$?
	sed 's/^/      /' "$BASE/out" | tail -2
}
calls() { grep -c '^CALL' "$FAKE_LOG" 2>/dev/null || true; }
ledger() { wc -l <"$BASE/state/uploaded.tsv" | tr -d ' '; }

echo "== first pass snapshots, never uploads =="
echo heic >"$BASE/repo/2024/07/IMG_0001.HEIC"
echo mov >"$BASE/repo/2024/07/IMG_0001.MOV"
echo sql >"$BASE/repo/2024/07/.watermelon_manifest.sqlite"
echo lock >"$BASE/repo/.watermelon/locks/writer.lock"
echo aae >"$BASE/repo/2024/07/IMG_0001.AAE"
run
ck "no upload on first pass" "[[ $(calls) -eq 0 ]]"
ck "exit 0" "[[ $RC -eq 0 ]]"

echo "== Live Photo pair uploads in a single invocation =="
run
ck "exactly one invocation" "[[ $(calls) -eq 1 ]]"
ck "both halves in the same call" "grep -q 'IMG_0001.HEIC.*IMG_0001.MOV' $FAKE_LOG"
ck "passes --pair-live-photos" "grep -q -- '--pair-live-photos' $FAKE_LOG"
ck "passes --no-tui and --threads" "grep -q -- '--no-tui' $FAKE_LOG && grep -q -- '--threads 3' $FAKE_LOG"
ck "separates flags from paths" "grep -q -- ' -- ' $FAKE_LOG"
ck "ignores manifest, lock and .aae" "! grep -qiE 'sqlite|\.lock|\.aae' $FAKE_LOG"
ck "ledger holds both halves" "[[ $(ledger) -eq 2 ]]"

echo "== idempotent =="
run
ck "no further invocation" "[[ $(calls) -eq 1 ]]"
ck "reports nothing to do" "grep -q 'nothing new' $BASE/out"

echo "== quiet interval gates in-flight uploads =="
echo partial >"$BASE/repo/2024/07/IMG_0002.JPG"
run
ck "fresh file waits" "[[ $(calls) -eq 1 ]]"
echo partial-plus-more >"$BASE/repo/2024/07/IMG_0002.JPG"
run
ck "still-growing file waits" "[[ $(calls) -eq 1 ]]"
run
ck "uploads once quiet" "[[ $(calls) -eq 2 ]]"
ck "ledger has 3 entries" "[[ $(ledger) -eq 3 ]]"

echo "== a bad file cannot hold back its batch =="
echo bad >"$BASE/repo/2024/07/A_BAD.JPG"
echo good >"$BASE/repo/2024/07/B_GOOD.JPG"
echo good >"$BASE/repo/2024/07/C_GOOD.JPG"
echo good >"$BASE/repo/2024/07/D_GOOD.JPG"
run
run
ck "good files still upload" "grep -q B_GOOD.JPG $BASE/state/uploaded.tsv && grep -q C_GOOD.JPG $BASE/state/uploaded.tsv && grep -q D_GOOD.JPG $BASE/state/uploaded.tsv"
ck "bad file stays pending" "! grep -q A_BAD $BASE/state/uploaded.tsv"
ck "bad file is named in the log" "grep -q 'A_BAD.JPG. failed on its own' $BASE/out"
ck "its reason is kept" "grep -q 'upload rejected' $BASE/state/failures.log"
ck "exit 1 while it is pending" "[[ $RC -eq 1 ]]"

echo "== an outage blames no file and loses nothing =="
rm -f "$BASE/repo/2024/07/A_BAD.JPG"
ledger_before=$(ledger)
echo one >"$BASE/repo/2024/07/IMG_0100.JPG"
echo two >"$BASE/repo/2024/07/IMG_0101.JPG"
run
FAKE_FAIL_ALL=1
export FAKE_FAIL_ALL
run
ck "outage is detected as account/network" "grep -q 'account or network problem' $BASE/out"
ck "nothing is marked uploaded" "[[ $(ledger) -eq $ledger_before ]]"
ck "exit 1" "[[ $RC -eq 1 ]]"
FAKE_FAIL_ALL=0
run
ck "recovers without intervention" "grep -q IMG_0100.JPG $BASE/state/uploaded.tsv && grep -q IMG_0101.JPG $BASE/state/uploaded.tsv"
ck "clean run exits 0" "[[ $RC -eq 0 ]]"

echo "== overlapping run is refused =="
(
	flock -n 8 || exit 9
	GOTOHP_SYNC_CONFIG=$BASE/test.env bash "$SYNC"
) >"$BASE/out-blocked" 2>&1 8>"$BASE/state/sync.lock"
ck "second concurrent run backs off" "grep -q 'still in progress' $BASE/out-blocked"

echo "== dry run changes nothing =="
before_calls=$(calls)
before_ledger=$(ledger)
echo dry >"$BASE/repo/2024/07/IMG_0200.HEIC"
cp "$BASE/test.env" "$BASE/dry.env"
echo "DRY_RUN=true" >>"$BASE/dry.env"
run "$BASE/dry.env"
run "$BASE/dry.env"
ck "no uploader call" "[[ $(calls) -eq $before_calls ]]"
ck "ledger untouched" "[[ $(ledger) -eq $before_ledger ]]"
ck "lists what it would send" "grep -q IMG_0200.HEIC $BASE/out"

echo "== deletion stays opt-in =="
ck "--delete absent by default" "! grep -q -- '--delete' $FAKE_LOG"
cp "$BASE/test.env" "$BASE/del.env"
echo "DELETE_AFTER_UPLOAD=true" >>"$BASE/del.env"
run "$BASE/del.env"
run "$BASE/del.env"
ck "--delete passes through when enabled" "grep -q -- '--delete' $FAKE_LOG"

echo "== upload policy flags reach gotohp =="
cp "$BASE/test.env" "$BASE/full.env"
cat >>"$BASE/full.env" <<ENVF
SAVER=true
USE_QUOTA=true
FORCE_UPLOAD=true
DISABLE_FILTER=true
DATE_FROM_FILENAME=true
EXCLUDE_PATTERN=@eaDir
ALBUM=AUTO
LOG_LEVEL=info
UPLOAD_INCOMPLETE_LIVE=true
UPDATE_EXISTING_TO_LIVE=true
IGNORE_APPLE_METADATA=true
ENVF
: >"$FAKE_LOG"
echo full >"$BASE/repo/2024/07/IMG_0400.HEIC"
run "$BASE/full.env"
run "$BASE/full.env"
ck "every policy flag is passed" "for flag in --saver --use-quota --force --disable-filter --date-from-filename --upload-incomplete-live-photos --update-existing-photos-to-live --ignore-apple-metadata; do grep -q -- \"\$flag\" $FAKE_LOG || exit 1; done"
ck "album and exclude keep their values" "grep -q -- '--album AUTO' $FAKE_LOG && grep -q -- '--exclude @eaDir' $FAKE_LOG"
ck "log level is configurable" "grep -q -- '--log-level info' $FAKE_LOG"

echo "== live photo sub-options need pairing =="
cp "$BASE/test.env" "$BASE/nopair.env"
cat >>"$BASE/nopair.env" <<ENVF
PAIR_LIVE_PHOTOS=false
IGNORE_APPLE_METADATA=true
ENVF
: >"$FAKE_LOG"
echo nopair >"$BASE/repo/2024/07/IMG_0401.HEIC"
run "$BASE/nopair.env"
run "$BASE/nopair.env"
ck "pairing flag absent when disabled" "! grep -q -- '--pair-live-photos' $FAKE_LOG"
ck "dependent option dropped rather than rejected by gotohp" "! grep -q -- '--ignore-apple-metadata' $FAKE_LOG"
ck "says why it was dropped" "grep -q 'PAIR_LIVE_PHOTOS is false' $BASE/out"

echo "== a bad log level is refused =="
cp "$BASE/test.env" "$BASE/badlevel.env"
echo "LOG_LEVEL=loud" >>"$BASE/badlevel.env"
run "$BASE/badlevel.env"
ck "invalid LOG_LEVEL exits 2" "[[ $RC -eq 2 ]] && grep -q LOG_LEVEL $BASE/out"

echo "== guard rails =="
printf 'SRC_DIR=/nope\nSTATE_DIR=%s/state\nGOTOHP_BIN=%s/fake-gotohp\nGOTOHP_CONFIG=%s/state/gotohp.config\n' \
	"$BASE" "$BASE" "$BASE" >"$BASE/bad.env"
run "$BASE/bad.env"
ck "bad SRC_DIR exits 2" "[[ $RC -eq 2 ]] && grep -q SRC_DIR $BASE/out"
GOTOHP_SYNC_CONFIG=/nonexistent bash "$SYNC" >"$BASE/out4" 2>&1
ck "missing env file exits 2" "[[ $? -eq 2 ]]"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
