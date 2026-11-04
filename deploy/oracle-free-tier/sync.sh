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
	[[ -n ${ACTIVITY:-} ]] && write_activity error 0 0 "" "$*" 2
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
NORMALIZE_DATES=${NORMALIZE_DATES:-true}

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
ACTIVITY=$STATE_DIR/activity.json
RUN_ID=$(date -u +%Y%m%dT%H%M%SZ).$$
RUN_STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)

touch "$LEDGER"

# The CLI log is append-only and a long backfill can make it large; keep the
# tail the dashboard actually shows and nothing more.
if [[ -f $GOTOHP_LOG ]] && (($(wc -c <"$GOTOHP_LOG") > 1048576)); then
	tail -c 262144 "$GOTOHP_LOG" >"$GOTOHP_LOG.trim" && mv -f "$GOTOHP_LOG.trim" "$GOTOHP_LOG"
fi

# --- live activity ---------------------------------------------------------
# One small JSON file describes what this run is doing right now. The control
# agent ships it to the dashboard, which is how a browser sees "uploading 12 of
# 300" instead of only the result of the last finished run. Best effort: it
# must never be the reason an upload stops.
json_text() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\010\013\014\016-\037'
}

write_activity() {
	local phase=$1 up=${2:-0} pend=${3:-0} current=${4:-} message=${5:-} code=${6:-null}
	local batch=${7:-0} batches=${8:-0} tmp
	tmp=$(mktemp "$STATE_DIR/activity.XXXXXX" 2>/dev/null) || return 0
	printf '{"run_id":"%s","phase":"%s","started_at":"%s","updated_at":"%s","total":%d,"uploaded":%d,"pending":%d,"batches":%d,"batch":%d,"current":"%s","message":"%s","exit":%s}\n' \
		"$RUN_ID" "$phase" "$RUN_STARTED" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		"${settled:-0}" "$up" "$pend" "$batches" "$batch" \
		"$(json_text "$current")" "$(json_text "$message")" "$code" >"$tmp" 2>/dev/null || {
		rm -f "$tmp"
		return 0
	}
	chmod 0640 "$tmp" 2>/dev/null || true
	mv -f "$tmp" "$ACTIVITY" 2>/dev/null || rm -f "$tmp"
	return 0
}

# Extensions Google Photos accepts, mirroring core/upload.go supportedFormats.
# Everything else Watermelon stores in the node (.watermelon_manifest.sqlite,
# .watermelon/*.lock, .aae adjustment sidecars) is deliberately not scanned.
MEDIA_EXTS=(
	avif bmp gif heic heif ico jpg jpeg png tif tiff webp
	cr2 cr3 nef arw orf raf rw2 pef sr2 dng
	3gp 3g2 asf avi divx m2t m2ts m4v mkv mmv
	mod mov mp4 mpg mpeg mts tod wmv ts webm
)

# One find expression for media files, shared by the scan and the date pass so
# the two can never disagree about what they are looking at.
MEDIA_FIND=(-iname "*.${MEDIA_EXTS[0]}")
for _ext in "${MEDIA_EXTS[@]:1}"; do
	MEDIA_FIND+=(-o -iname "*.$_ext")
done
unset _ext

# scan_repo <outfile>
# Emits "size<TAB>mtime<TAB>relative/path" for every media file in SRC_DIR.
scan_repo() {
	local out=$1

	find "$SRC_DIR" -type f \( "${MEDIA_FIND[@]}" \) -printf '%s\t%T@\t%P\n' |
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

	# Paths come from the scan relative to SRC_DIR, and gotohp-cli stats every
	# path it is handed. The service runs with no working directory, so a relative
	# path resolved against / and the whole batch was rejected as an invalid
	# upload path before a single file was read - an empty last-run.json and a
	# "batch failed" with no reason. Absolute paths make the upload independent
	# of wherever the unit happens to start.
	local -a absolute=()
	local path
	for path in "$@"; do
		if [[ $path == /* ]]; then
			absolute+=("$path")
		else
			absolute+=("$SRC_DIR/$path")
		fi
	done

	"${cmd[@]}" -- "${absolute[@]}" >"$LAST_RESULT" 2>>"$GOTOHP_LOG"
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
		# The CLI explains itself on stderr, which goes to its own log. Without
		# these lines the dashboard could only ever say "a batch failed" and
		# never why, which is exactly the question this file exists to answer.
		tail -n 4 "$GOTOHP_LOG" 2>/dev/null | sed -e 's/^/    /'
		printf '\n'
	} >>"$FAILURES_LOG"
}

# gotohp dates an upload from the file's mtime (core/upload.go), and SFTP does
# not reliably carry the capture time over. A node that arrived stamped with the
# transfer time would put the whole library under "today" in Google Photos, so
# mtime is corrected from the date stored in the file itself before the scan.
# The stability gate below then works on the corrected value, which is what makes
# the upload date stable rather than the arrival order.
normalize_dates() {
	[[ $NORMALIZE_DATES == true ]] || return 0
	[[ $DRY_RUN != true ]] || return 0

	local helper=${MEDIA_DATE_HELPER:-} candidate
	if [[ -z $helper ]]; then
		for candidate in "$(dirname -- "${BASH_SOURCE[0]}")/media-date.py" \
			/usr/local/bin/gotohp-media-date; do
			if [[ -r $candidate ]]; then
				helper=$candidate
				break
			fi
		done
	fi
	if [[ -z $helper ]]; then
		warn "no media-date helper; uploads keep the mtime they arrived with"
		return 0
	fi
	if ! command -v python3 >/dev/null 2>&1; then
		warn "python3 is missing; uploads keep the mtime they arrived with"
		return 0
	fi

	# Only files that have not been uploaded: already sent files keep whatever
	# date they were sent with, and a large library does not get re-read.
	local summary
	summary=$(
		find "$SRC_DIR" -type f \( "${MEDIA_FIND[@]}" \) -print0 2>/dev/null |
			awk -v RS='\0' -v ORS='\0' -v root="$SRC_DIR/" -v done="$LEDGER" '
				BEGIN { while ((getline line < done) > 0) seen[line] = 1 }
				{
					rel = substr($0, length(root) + 1)
					if (!(rel in seen)) print $0
				}
			' |
			python3 "$helper" 2>&1 >/dev/null
	) || summary=""
	[[ -n $summary ]] && log "$summary"
	return 0
}

normalize_dates
write_activity scanning 0 0 "" "scanning the node"
scan_repo "$CURRENT"
total_media=$(wc -l <"$CURRENT" | tr -d ' ')

if [[ ! -f $PREVIOUS ]]; then
	log "first run: found $total_media media file(s); nothing is uploaded until the next pass confirms they are complete"
	mv "$CURRENT" "$PREVIOUS"
	write_activity idle 0 "$total_media" "" "first run: waiting for a second scan" 0
	exit 0
fi

select_settled >"$ELIGIBLE"
settled=$(wc -l <"$ELIGIBLE" | tr -d ' ')

if ((settled == 0)); then
	log "$total_media media file(s) in the node, nothing new and complete to upload"
	mv "$CURRENT" "$PREVIOUS"
	write_activity idle 0 "$total_media" "" "nothing new to upload" 0
	exit 0
fi

log "$settled file(s) waiting for upload"

if [[ $DRY_RUN == true ]]; then
	log "DRY_RUN: would upload in batches of $BATCH_SIZE, first 10:"
	sed -n '1,10p' "$ELIGIBLE"
	write_activity idle 0 "$settled" "" "dry run: $settled file(s) would be uploaded" 0
	exit 0
fi

mapfile -t files <"$ELIGIBLE"

uploaded=0
pending=0
network_suspect=false
batches=$(((${#files[@]} + BATCH_SIZE - 1) / BATCH_SIZE))
batch_index=0
write_activity uploading 0 "$settled" "" "uploading ${#files[@]} file(s) in $batches batch(es)" null 0 "$batches"

for ((offset = 0; offset < ${#files[@]}; offset += BATCH_SIZE)); do
	batch=("${files[@]:offset:BATCH_SIZE}")
	batch_index=$((batch_index + 1))

	if upload "${batch[@]}"; then
		mark_uploaded "${batch[@]}"
		uploaded=$((uploaded + ${#batch[@]}))
		log "batch of ${#batch[@]} uploaded (${uploaded}/${settled} this run)"
		write_activity uploading "$uploaded" "$pending" "${batch[0]}" "uploading" null "$batch_index" "$batches"
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
			write_activity uploading "$uploaded" "$pending" "${batch[$probe]}" "uploading" null "$batch_index" "$batches"
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
		write_activity uploading "$uploaded" "$pending" "$path" "uploading" null "$batch_index" "$batches"
		if upload "$path"; then
			mark_uploaded "$path"
			uploaded=$((uploaded + 1))
			write_activity uploading "$uploaded" "$pending" "$path" "uploading" null "$batch_index" "$batches"
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
	write_activity error "$uploaded" "$pending" "" "every file in the batch failed: is the Google account still connected?" 1 "$batch_index" "$batches"
	exit 1
fi
if ((pending > 0)); then
	write_activity error "$uploaded" "$pending" "" "$pending file(s) could not upload and stay pending" 1 "$batch_index" "$batches"
	exit 1
fi
write_activity idle "$uploaded" 0 "" "uploaded $uploaded file(s)" 0 "$batch_index" "$batches"
