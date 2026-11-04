#!/usr/bin/env bash
# Pull settings and commands from the dashboard, apply them here, report state.
#
# The VM never accepts an inbound connection for this. It asks the control plane
# what to do, using a device token, so a box with no domain, no certificate and
# 1 GB of RAM can still be controlled from a browser.
#
# Runs from gotohp-control.timer every minute. Exits 0 on every recoverable
# problem: a dashboard outage must not leave the relay red, and the next run
# retries anyway.

set -Eeuo pipefail

CONFIG_FILE=${GOTOHP_SYNC_CONFIG:-/etc/gotohp-sync/config.env}
TOKEN_FILE=${CONTROL_TOKEN_FILE:-/etc/gotohp-sync/device.token}
TIMER_DROPIN=${CONTROL_TIMER_DROPIN:-/etc/systemd/system/gotohp-sync.timer.d/interval.conf}
SERVICE=${CONTROL_SERVICE:-gotohp-sync.service}
TIMER=${CONTROL_TIMER:-gotohp-sync.timer}

log() { printf '%s control: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }

[[ -r $CONFIG_FILE ]] || exit 0
# shellcheck disable=SC1090
. "$CONFIG_FILE"

CONTROL_URL=${CONTROL_URL:-}
GOTOHP_BIN=${GOTOHP_BIN:-/usr/local/bin/gotohp-cli}
STATE_DIR=${STATE_DIR:-/var/lib/gotohp-sync}

[[ -n $CONTROL_URL ]] || exit 0
[[ -r $TOKEN_FILE ]] || {
	log "no device token at $TOKEN_FILE; not pairing yet"
	exit 0
}
TOKEN=$(tr -d '[:space:]' <"$TOKEN_FILE")
[[ -n $TOKEN ]] || exit 0

# ---------------------------------------------------------------------------
# state: cheap to collect, so this runs every minute. Nothing here scans the
# repository - the file count comes from the last scan sync.sh already did.
# ---------------------------------------------------------------------------
collect_state() {
	local version scan_total=0 uploaded=0 pending=0 free_mb=0 used_pct="?"
	local timer_next="?" paused=false google=false last="" failures=""

	version=$("$GOTOHP_BIN" version 2>/dev/null | head -n 1 | tr -d '\r') || version="unknown"
	[[ -f $STATE_DIR/scan.previous ]] && scan_total=$(wc -l <"$STATE_DIR/scan.previous" | tr -d ' ')
	[[ -f $STATE_DIR/uploaded.tsv ]] && uploaded=$(wc -l <"$STATE_DIR/uploaded.tsv" | tr -d ' ')
	((scan_total >= uploaded)) && pending=$((scan_total - uploaded))

	read -r free_mb used_pct <<<"$(df -Pm / | awk 'NR == 2 { print $4, $5 }')"

	systemctl is-active --quiet "$TIMER" 2>/dev/null || paused=true
	[[ -s ${GOTOHP_CONFIG:-$STATE_DIR/gotohp.config} ]] && google=true

	# systemd prints "n/a" when the timer is stopped; keep that as-is.
	timer_next=$(systemctl list-timers --all --no-legend "$TIMER" 2>/dev/null |
		head -n 1 | awk '{ print $1" "$2" "$3 }') || timer_next="?"
	[[ -n $timer_next ]] || timer_next="?"

	[[ -f $STATE_DIR/last-run.json ]] &&
		last=$(tail -c 240 "$STATE_DIR/last-run.json" | tr '\n\r' '  ' | tr -s ' ')
	[[ -f $STATE_DIR/failures.log ]] &&
		failures=$(tail -n 3 "$STATE_DIR/failures.log" | tr '\n\r' '  ' | tr -s ' ')

	printf 'agent=1\nversion=%s\nscan_total=%s\nuploaded=%s\npending=%s\ndisk_free_mb=%s\ndisk_used_pct=%s\npaused=%s\ngoogle=%s\ntimer_next=%s\nlast_run=%s\nfailures=%s\n' \
		"$version" "$scan_total" "$uploaded" "$pending" "$free_mb" "$used_pct" "$paused" "$google" \
		"$timer_next" "$last" "$failures"
}

# ---------------------------------------------------------------------------
# validation: the dashboard already checked these, but this file is sourced by
# a root shell, so it does not trust the network.
# ---------------------------------------------------------------------------
valid_setting() {
	local key=$1 value=$2
	case $key in
	PAUSED | SAVER | USE_QUOTA | FORCE_UPLOAD | DATE_FROM_FILENAME | DISABLE_FILTER | \
		PAIR_LIVE_PHOTOS | UPLOAD_INCOMPLETE_LIVE | UPDATE_EXISTING_TO_LIVE | \
		IGNORE_APPLE_METADATA | DELETE_AFTER_UPLOAD | DRY_RUN)
		[[ $value == true || $value == false ]]
		;;
	THREADS)
		[[ $value =~ ^[1-8]$ ]]
		;;
	BATCH_SIZE)
		[[ $value =~ ^[0-9]{1,4}$ ]] && ((value >= 1 && value <= 1000))
		;;
	SYNC_INTERVAL)
		[[ $value =~ ^[0-9]{1,3}(s|min|h)$ ]]
		;;
	LOG_LEVEL)
		[[ $value =~ ^(debug|info|warn|error)$ ]]
		;;
	EXCLUDE_PATTERN | ALBUM | ACCOUNT)
		((${#value} <= 200)) && [[ $value =~ ^[A-Za-z0-9\ @._/-]*$ ]]
		;;
	*)
		return 1
		;;
	esac
}

declare -A WANT=()
declare -a CMDS=()

parse_response() {
	local line key value
	while IFS= read -r line; do
		case $line in
		SET\ *)
			line=${line#SET }
			key=${line%%=*}
			value=${line#*=}
			if valid_setting "$key" "$value"; then
				WANT[$key]=$value
			else
				log "ignoring unusable setting $key"
			fi
			;;
		CMD\ *) CMDS+=("$line") ;;
		esac
	done
}

# Rewrite config.env in place: managed keys are replaced, comments and anything
# else (SRC_DIR, CONTROL_URL, credentials paths) survive untouched.
apply_config() {
	local key line tmp

	tmp=$(mktemp "$CONFIG_FILE.XXXXXX")
	while IFS= read -r line; do
		key=${line%%=*}
		if [[ $key == "$line" || -n ${WANT[$key]+x} ]]; then
			[[ $key == "$line" ]] && printf '%s\n' "$line"
			continue
		fi
		printf '%s\n' "$line"
	done <"$CONFIG_FILE" >"$tmp"

	local sorted
	sorted=$(printf '%s\n' "${!WANT[@]}" | sort)
	for key in $sorted; do
		printf '%s=%s\n' "$key" "${WANT[$key]}"
	done >>"$tmp"

	if cmp -s "$tmp" "$CONFIG_FILE"; then
		rm -f "$tmp"
		return 1
	fi
	install -m 0640 -o root -g gotohpsync "$tmp" "$CONFIG_FILE"
	rm -f "$tmp"
	return 0
}

# The interval lives in a drop-in because systemd cannot read the env file, and
# it is only rewritten when it actually changes - restarting the timer every
# minute would stop it from ever firing.
apply_timer() {
	local interval=${WANT[SYNC_INTERVAL]:-} current="" restart=0

	if [[ -n $interval ]]; then
		[[ -r $TIMER_DROPIN ]] && current=$(sed -n 's/^OnUnitActiveSec=//p' "$TIMER_DROPIN")
		if [[ $current != "$interval" ]]; then
			install -d -m 0755 "$(dirname -- "$TIMER_DROPIN")"
			printf '[Timer]\nOnBootSec=%s\nOnUnitActiveSec=%s\n' "$interval" "$interval" >"$TIMER_DROPIN"
			restart=1
		fi
	fi

	if [[ ${WANT[PAUSED]:-} == true ]]; then
		systemctl disable --now "$TIMER" >/dev/null 2>&1 || true
		restart=0
	elif [[ ${WANT[PAUSED]:-} == false ]]; then
		systemctl enable --now "$TIMER" >/dev/null 2>&1 || true
	fi

	if ((restart)); then
		systemctl daemon-reload
		systemctl restart "$TIMER"
	fi
}

run_command() {
	local id=$1 kind=$2 status=fail message="unknown command"

	case $kind in
	run-now)
		if systemctl start --no-block "$SERVICE"; then
			status=ok
			message="started $SERVICE"
		else
			message="could not start $SERVICE"
		fi
		;;
	rescan)
		rm -f "$STATE_DIR/scan.previous"
		status=ok
		message="next run re-snapshots the repository"
		;;
	refresh)
		status=ok
		message="state refreshed"
		;;
	esac

	printf 'RESULT %s %s %s\n' "$id" "$status" "$message"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
state=$(collect_state)
response=$(curl -fsS --max-time 25 -X POST "$CONTROL_URL/api/device/poll" \
	-H "Authorization: Bearer $TOKEN" \
	-H 'content-type: text/plain; charset=utf-8' \
	--data-binary "$state" 2>&1) || {
	log "could not reach the control plane; will retry"
	exit 0
}

parse_response <<<"$response"

changed=false
if ((${#WANT[@]})); then
	apply_config && changed=true
	apply_timer
fi

results=""
for entry in ${CMDS[@]+"${CMDS[@]}"}; do
	entry=${entry#CMD }
	id=${entry%% *}
	kind=${entry#* }
	results+=$(run_command "$id" "$kind")$'\n'
done

if [[ -n $results ]]; then
	printf '%s' "$results" |
		curl -fsS --max-time 15 -X POST "$CONTROL_URL/api/device/result" \
			-H "Authorization: Bearer $TOKEN" \
			-H 'content-type: text/plain; charset=utf-8' \
			--data-binary @- >/dev/null || log "could not report command results"
fi

[[ $changed == true ]] && log "applied settings from the dashboard"
exit 0
