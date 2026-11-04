#!/usr/bin/env bash
# gotohp-sync - push a Watermelon Backup node directory to Google Photos.
#
# gotohp has no server or watch mode: it uploads files that already sit on
# disk. This script is the missing "receive" half of the pipeline, meant to run
# unattended from gotohp-sync.timer.
#
# Reliability properties this script is responsible for:
#   * one run at a time (flock); a run that overlaps another exits quietly
#   * a file is uploaded only after its size and mtime survived a full scan
#     interval, so an SFTP upload still in flight is never handed to gotohp
#   * a ledger keeps finished files from being re-hashed on every run
#   * a failing file is isolated from the rest of its batch, so one bad file
#     cannot hold back a whole month
#   * nothing is ever parked or skipped silently: a file that cannot upload
#     stays pending, is retried, and keeps the unit red until it is dealt with
#
# Exit status: 0 = nothing to do, or all pending files uploaded.
#              1 = at least one file is still pending (files are kept).
#              2 = configuration or state problem.

set -Eeuo pipefail

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
warn() { log "WARN: $*" >&2; }
die() {
	log "ERROR: $*" >&2
	exit 2
}

CONFIG_FILE=${GOTOHP_SYNC_CONFIG:-/etc/gotohp-sync/config.env}
# shellcheck disable=SC1090
if [[ -r $CONFIG_FILE ]]; then
	. "$CONFIG_FILE"
fi

SRC_DIR=${SRC_DIR:-/srv/watermelon/repo}
STATE_DIR=${STATE_DIR:-/var/lib/gotohp-sync}
GOTOHP_BIN=${GOTOHP_BIN:-/usr/local/bin/gotohp-cli}
GOTOHP_CONFIG=${GOTOHP_CONFIG:-$STATE_DIR/gotohp.config}
ACCOUNT=${ACCOUNT:-}
THREADS=${THREADS:-3}
BATCH_SIZE=${BATCH_SIZE:-200}
DELETE_AFTER_UPLOAD=${DELETE_AFTER_UPLOAD:-false}
PAIR_LIVE_PHOTOS=${PAIR_LIVE_PHOTOS:-true}
DRY_RUN=${DRY_RUN:-false}

# Mirrors the upload flags of gotohp-cli. The dashboard writes these; every one
# is optional and defaults to the behaviour the relay shipped with.
SAVER=${SAVER:-false}
USE_QUOTA=${USE_QUOTA:-false}
FORCE_UPLOAD=${FORCE_UPLOAD:-false}
DISABLE_FILTER=${DISABLE_FILTER:-false}
DATE_FROM_FILENAME=${DATE_FROM_FILENAME:-false}
EXCLUDE_PATTERN=${EXCLUDE_PATTERN:-}
ALBUM=${ALBUM:-}
UPLOAD_INCOMPLETE_LIVE=${UPLOAD_INCOMPLETE_LIVE:-false}
UPDATE_EXISTING_TO_LIVE=${UPDATE_EXISTING_TO_LIVE:-false}
IGNORE_APPLE_METADATA=${IGNORE_APPLE_METADATA:-false}
LOG_LEVEL=${LOG_LEVEL:-warn}

[[ -d $SRC_DIR ]] || die "SRC_DIR '$SRC_DIR' is not a directory"
[[ -x $GOTOHP_BIN ]] || die "GOTOHP_BIN '$GOTOHP_BIN' is not executable"
[[ -r $GOTOHP_CONFIG ]] || die "GOTOHP_CONFIG '$GOTOHP_CONFIG' is missing - add a Google account first"
command -v flock >/dev/null 2>&1 || die "flock not found (install util-linux)"

case $LOG_LEVEL in debug | info | warn | error) ;; *) die "LOG_LEVEL must be debug, info, warn or error" ;; esac
if [[ $PAIR_LIVE_PHOTOS != true ]] &&
	[[ $UPLOAD_INCOMPLETE_LIVE == true || $UPDATE_EXISTING_TO_LIVE == true || $IGNORE_APPLE_METADATA == true ]]; then
	warn "Live Photo matching options are ignored because PAIR_LIVE_PHOTOS is false"
fi

install -d -m 0700 "$STATE_DIR"

exec 9>"$STATE_DIR/sync.lock"
if ! flock -n 9; then
	log "another run is still in progress, leaving this one to it"
	exit 0
fi

LEDGER=$STATE_DIR/uploaded.tsv
CURRENT=$STATE_DIR/scan.current
PREVIOUS=$STATE_DIR/scan.previous
ELIGIBLE=$STATE_DIR/eligible.tmp
LAST_RESULT=$STATE_DIR/last-run.json
GOTOHP_LOG=$STATE_DIR/gotohp.log
FAILURES_LOG=$STATE_DIR/failures.log

touch "$LEDGER"

# Extensions Google Photos accepts, mirroring core/upload.go supportedFormats.
# Everything else Watermelon stores in the node (.watermelon_manifest.sqlite,
# .watermelon/*.lock, .aae adjustment sidecars) is deliberately not scanned.
MEDIA_EXTS=(
	avif bmp gif heic heif ico jpg jpeg png tif tiff webp
	cr2 cr3 nef arw orf raf rw2 pef sr2 dng
	3gp 3g2 asf avi divx m2t m2ts m4v mkv mmv
	mod mov mp4 mpg mpeg mts tod wmv ts webm
)

# scan_repo <outfile>
# Emits "size<TAB>mtime<TAB>relative/path" for every media file in SRC_DIR.
scan_repo() {
	local out=$1
	local -a names=()
	local ext

	names+=(-iname "*.${MEDIA_EXTS[0]}")
	for ext in "${MEDIA_EXTS[@]:1}"; do
		names+=(-o -iname "*.$ext")
	done

	find "$SRC_DIR" -type f \( "${names[@]}" \) -printf '%s\t%T@\t%P\n' |
		LC_ALL=C sort -t$'\t' -k3 >"$out.part"
	mv "$out.part" "$out"
}

# Files already present with the exact same size and mtime during the previous
# scan, and not uploaded yet. This is the stability gate: a file that shows up
# for the first time, or that is still growing, waits for the next interval.
select_settled() {
	comm -12 \
		<(LC_ALL=C sort "$PREVIOUS") \
		<(LC_ALL=C sort "$CURRENT") |
		LC_ALL=C sort -t$'\t' -k3 |
		cut -f3 |
		awk -F'\t' -v done="$LEDGER" '
			BEGIN { while ((getline line < done) > 0) seen[line] = 1 }
			!($0 in seen) { print }
		'
}

upload() {
	local -a cmd=(
		"$GOTOHP_BIN" upload
		--config "$GOTOHP_CONFIG"
		--no-tui
		--threads "$THREADS"
		--log-level "$LOG_LEVEL"
	)

	[[ -n $ACCOUNT ]] && cmd+=(--account "$ACCOUNT")
	[[ $PAIR_LIVE_PHOTOS == true ]] && cmd+=(--pair-live-photos)
	[[ $DELETE_AFTER_UPLOAD == true ]] && cmd+=(--delete)
	[[ $SAVER == true ]] && cmd+=(--saver)
	[[ $USE_QUOTA == true ]] && cmd+=(--use-quota)
	[[ $FORCE_UPLOAD == true ]] && cmd+=(--force)
	[[ $DISABLE_FILTER == true ]] && cmd+=(--disable-filter)
	[[ $DATE_FROM_FILENAME == true ]] && cmd+=(--date-from-filename)
	[[ -n $EXCLUDE_PATTERN ]] && cmd+=(--exclude "$EXCLUDE_PATTERN")
	[[ -n $ALBUM ]] && cmd+=(--album "$ALBUM")

	# gotohp-cli rejects these unless pairing is on, so they are dropped rather
	# than handed over to fail the whole batch.
	if [[ $PAIR_LIVE_PHOTOS == true ]]; then
		[[ $UPLOAD_INCOMPLETE_LIVE == true ]] && cmd+=(--upload-incomplete-live-photos)
		[[ $UPDATE_EXISTING_TO_LIVE == true ]] && cmd+=(--update-existing-photos-to-live)
		[[ $IGNORE_APPLE_METADATA == true ]] && cmd+=(--ignore-apple-metadata)
	fi

	"${cmd[@]}" -- "$@" >"$LAST_RESULT" 2>>"$GOTOHP_LOG"
}

mark_uploaded() {
	printf '%s\n' "$@" >>"$LEDGER"
}

# Keep the gotohp result of something that failed, so the reason is still
# readable after the next invocation overwrites last-run.json.
note_failure() {
	{
		printf '=== %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1"
		cat "$LAST_RESULT" 2>/dev/null || true
		printf '\n'
	} >>"$FAILURES_LOG"
}

scan_repo "$CURRENT"
total_media=$(wc -l <"$CURRENT" | tr -d ' ')

if [[ ! -f $PREVIOUS ]]; then
	log "first run: found $total_media media file(s); nothing is uploaded until the next pass confirms they are complete"
	mv "$CURRENT" "$PREVIOUS"
	exit 0
fi

select_settled >"$ELIGIBLE"
settled=$(wc -l <"$ELIGIBLE" | tr -d ' ')

if ((settled == 0)); then
	log "$total_media media file(s) in the node, nothing new and complete to upload"
	mv "$CURRENT" "$PREVIOUS"
	exit 0
fi

log "$settled file(s) waiting for upload"

if [[ $DRY_RUN == true ]]; then
	log "DRY_RUN: would upload in batches of $BATCH_SIZE, first 10:"
	sed -n '1,10p' "$ELIGIBLE"
	exit 0
fi

mapfile -t files <"$ELIGIBLE"

uploaded=0
pending=0
network_suspect=false

for ((offset = 0; offset < ${#files[@]}; offset += BATCH_SIZE)); do
	batch=("${files[@]:offset:BATCH_SIZE}")

	if upload "${batch[@]}"; then
		mark_uploaded "${batch[@]}"
		uploaded=$((uploaded + ${#batch[@]}))
		log "batch of ${#batch[@]} uploaded (${uploaded}/${settled} this run)"
		continue
	fi

	log "batch of ${#batch[@]} reported failures; isolating the files that cause them"

	# Probe a few files on their own. If not one of them can upload, the account
	# or the network is the problem rather than these files, so nothing is
	# blamed and the whole batch stays pending for the next run.
	probe_count=${#batch[@]}
	if ((probe_count > 3)); then
		probe_count=3
	fi
	probe_ok=0
	probe_failed=()

	for ((probe = 0; probe < probe_count; probe++)); do
		if upload "${batch[$probe]}"; then
			mark_uploaded "${batch[$probe]}"
			uploaded=$((uploaded + 1))
			probe_ok=$((probe_ok + 1))
		else
			probe_failed+=("${batch[$probe]}")
			note_failure "${batch[$probe]}"
		fi
	done

	if ((probe_ok == 0)); then
		warn "gotohp could not upload any file in this batch; keeping all ${#batch[@]} file(s) and treating it as an account or network problem"
		note_failure "batch of ${#batch[@]}"
		network_suspect=true
		pending=$((pending + ${#batch[@]}))
		break
	fi

	for path in ${probe_failed[@]+"${probe_failed[@]}"}; do
		warn "'$path' failed on its own; kept for the next run"
		pending=$((pending + 1))
	done

	for path in "${batch[@]:probe_count}"; do
		if upload "$path"; then
			mark_uploaded "$path"
			uploaded=$((uploaded + 1))
		else
			note_failure "$path"
			warn "'$path' failed on its own; kept for the next run"
			pending=$((pending + 1))
		fi
	done
done

mv "$CURRENT" "$PREVIOUS"

log "done: uploaded $uploaded, still pending $pending"

if [[ $network_suspect == true ]]; then
	warn "stopped early: every file in the batch failed. Check the account and the network; see $FAILURES_LOG"
	exit 1
fi
((pending == 0)) || exit 1
