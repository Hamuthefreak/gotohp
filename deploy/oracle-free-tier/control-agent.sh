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
GOTOHP_CONFIG=${GOTOHP_CONFIG:-$STATE_DIR/gotohp.config}
SYNC_USER=${CONTROL_SYNC_USER:-gotohpsync}

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
# activity: the sync run leaves a small JSON file behind, and the last few CLI
# lines next to it. Shipping both is what makes the dashboard live rather than
# a snapshot of the last finished run.
# ---------------------------------------------------------------------------
json_text() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\000-\010\013\014\016-\037'
}

activity_payload() {
	local activity="{}" log_lines=""
	if [[ -r $STATE_DIR/activity.json ]]; then
		activity=$(cat "$STATE_DIR/activity.json" 2>/dev/null) || activity="{}"
		[[ $activity == \{* ]] || activity="{}"
	fi
	if [[ -r $STATE_DIR/gotohp.log ]]; then
		log_lines=$(tail -n 6 "$STATE_DIR/gotohp.log" 2>/dev/null | tail -c 700) || log_lines=""
	fi
	printf '{"activity":%s,"log":"%s"}' "$activity" "$(json_text "$log_lines")"
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
CREDS_B64=""

parse_response() {
	local line key value
	while IFS= read -r line; do
		case $line in
		CREDS\ *) CREDS_B64=${line#CREDS } ;;
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

# The control plane never runs anything as root on the box: credentials and
# config belong to the sync user, who owns the config file.
run_as_sync() {
	if command -v runuser >/dev/null 2>&1; then
		runuser -u "$SYNC_USER" -- "$@"
	else
		sudo -n -u "$SYNC_USER" -- "$@"
	fi
}

# What the box really holds, read from the CLI rather than from a guess.
#
# `creds list` prints a header, then one "  * email" (active) or "    email"
# line per account, then a usage footer. Only the account lines carry an @, so
# the email is taken from the line itself instead of a fixed field position -
# awk fields shift when the marker is absent, which silently reported none.
accounts_json() {
	local list
	list=$("$GOTOHP_BIN" creds list --config "$GOTOHP_CONFIG" 2>/dev/null | awk '
		/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/ {
			line = $0
			sub(/^[ \t]+/, "", line)
			selected = (line ~ /^\*/)
			sub(/^\*[ \t]+/, "", line)
			email = line
			sub(/[ \t].*$/, "", email)
			if (email ~ /@/) {
				if (n++) printf ","
				printf "{\"email\":\"%s\",\"selected\":%s}", email, selected ? "true" : "false"
			}
		}
	') || list=""
	printf '{"list":[%s]}' "$list"
}

run_command() {
	local id=$1 kind=$2 arg=${3:-} status=fail message="unknown command"

	case $kind in
	run-now)
		local started_stamp attempt result now
		started_stamp=$(systemctl show -p InactiveEnterTimestampMonotonic --value "$SERVICE" 2>/dev/null)
		if ! systemctl start --no-block "$SERVICE"; then
			message="could not start $SERVICE"
		else
			status=ok
			message="started $SERVICE"
			# A run that fails at once (bad config) used to look identical to one
			# busy for hours: both said "started". Wait for it to leave and return,
			# then report what actually happened - but only if it really ran.
			# Result= is stale on a unit that never became active, which is how
			# an untouched unit reported "finished" while files were still pending.
			for attempt in 1 2 3 4 5 6 7 8; do
				sleep 1
				systemctl is-active --quiet "$SERVICE" || break
			done
			if systemctl is-active --quiet "$SERVICE"; then
				message="running now"
			else
				now=$(systemctl show -p InactiveEnterTimestampMonotonic --value "$SERVICE" 2>/dev/null)
				result=$(systemctl show -p Result --value "$SERVICE" 2>/dev/null)
				if [[ -n $started_stamp && $now == "$started_stamp" ]]; then
					message="running now"
				elif [[ $result == success ]]; then
					message="finished: nothing left to upload"
				else
					status=fail
					message="failed: $(journalctl -u "$SERVICE" -n 3 --no-pager -o cat 2>/dev/null | tr '\n' ' ' | tr -s ' ' | tail -c 220)"
				fi
			fi
		fi
		;;
	rescan)
		rm -f "$STATE_DIR/scan.previous"
		status=ok
		message="next run re-snapshots the repository"
		;;		refresh)
		status=ok
		message="state refreshed"
		;;
	clear-log)
		# "Clear the errors" means the relay's own logs and nothing else: no file
		# under SRC_DIR is touched and nothing is deleted from Google Photos.
		# Deleting the library itself is the separate delete-files command, which
		# only ever runs because the owner pressed a button.
		# truncate keeps the owner, so the sync user can still write afterwards.
		local cleared=0 file
		for file in "$STATE_DIR/gotohp.log" "$STATE_DIR/failures.log"; do
			[[ -f $file ]] || continue
			if truncate -s 0 "$file" 2>/dev/null; then
				cleared=$((cleared + 1))
			fi
		done
		status=ok
		message="cleared $cleared log file(s)"
		;;
	delete-files)
		# The relay's own copies and nothing else: every file under SRC_DIR plus
		# the bookkeeping that says they are uploaded. Google Photos is never
		# touched, and config.env survives so the box stays paired with its
		# accounts. This cannot be undone, so a path that looks like a system
		# directory is refused outright instead of being half-emptied.
		local src=${SRC_DIR:-} count=0
		case $src in
		/ | /bin | /boot | /dev | /etc | /home | /lib | /lib64 | /media | /mnt | /opt | /proc | /root | /run | /sbin | /srv | /sys | /tmp | /usr | /var)
			message="refusing to delete $src"
			;;
		/*)
			if [[ $src == *..* ]]; then
				message="refusing to delete $src"
			elif [[ ! -d $src ]]; then
				message="$src is not a directory on this server"
			else
				count=$(find "$src" -mindepth 1 -type f 2>/dev/null | wc -l) || count=0
				count=${count//[!0-9]/}
				if ! find "$src" -mindepth 1 -delete 2>/dev/null; then
					message="could not delete everything under $src"
				elif ! rm -f "$STATE_DIR/scan.previous" "$STATE_DIR/uploaded.tsv"; then
					message="deleted $count file(s) but could not reset the sync state"
				else
					status=ok
					message="deleted $count file(s) from $src; Google Photos untouched"
				fi
			fi
			;;
		*)
			message="SRC_DIR is not set in $CONFIG_FILE"
			;;
		esac
		;;
	creds-set)
		if [[ -z $arg ]]; then
			message="no account given"
		elif out=$(run_as_sync "$GOTOHP_BIN" creds set "$arg" --config "$GOTOHP_CONFIG" 2>&1); then
			status=ok
			message="uploads now go to $arg"
		else
			message=$(printf '%s' "$out" | tr '\n' ' ' | tail -c 200)
		fi
		;;
	creds-remove)
		if [[ -z $arg ]]; then
			message="no account given"
		elif out=$(run_as_sync "$GOTOHP_BIN" creds remove "$arg" --config "$GOTOHP_CONFIG" 2>&1); then
			status=ok
			message="removed $arg"
		else
			message=$(printf '%s' "$out" | tr '\n' ' ' | tail -c 200)
		fi
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

curl -fsS --max-time 10 -X POST "$CONTROL_URL/api/device/activity" \
	-H "Authorization: Bearer $TOKEN" \
	-H 'content-type: application/json' \
	--data-binary "$(activity_payload)" >/dev/null 2>&1 ||
	log "could not report live activity"

parse_response <<<"$response"

changed=false
if ((${#WANT[@]})); then
	apply_config && changed=true
	apply_timer
fi

results=""

# A credential from the dashboard: piped on stdin so it never appears in
# process listings, applied as the sync user, and reported back either way.
if [[ -n ${CREDS_B64:-} ]]; then
	secret=$(printf '%s' "$CREDS_B64" | base64 -d 2>/dev/null) || secret=""
	if [[ -z $secret ]]; then
		results+="CREDS_RESULT fail could not decode the credential"$'\n'
	else
		if out=$(printf '%s\n' "$secret" | run_as_sync "$GOTOHP_BIN" creds add - --config "$GOTOHP_CONFIG" 2>&1); then
			results+="CREDS_RESULT ok $(printf '%s' "$out" | tr '\n' ' ' | tr -s ' ' | tail -c 200)"$'\n'
			log "added a Google account from the dashboard"
		else
			results+="CREDS_RESULT fail $(printf '%s' "$out" | tr '\n' ' ' | tr -s ' ' | tail -c 200)"$'\n'
			log "a Google account from the dashboard was rejected: $out"
		fi
	fi
	unset secret
fi

for entry in ${CMDS[@]+"${CMDS[@]}"}; do
	entry=${entry#CMD }
	id=${entry%% *}
	rest=${entry#* }
	kind=${rest%% *}
	arg=""
	[[ $rest == *" "* ]] && arg=${rest#* }
	results+=$(run_command "$id" "$kind" "$arg")$'\n'
done

# Always report the account list, so the dashboard shows what the CLI sees
# rather than what it last asked for.
results+="ACCOUNTS $(accounts_json)"$'\n'

if [[ -n $results ]]; then
	printf '%s' "$results" |
		curl -fsS --max-time 15 -X POST "$CONTROL_URL/api/device/result" \
			-H "Authorization: Bearer $TOKEN" \
			-H 'content-type: text/plain; charset=utf-8' \
			--data-binary @- >/dev/null || log "could not report command results"
fi

[[ $changed == true ]] && log "applied settings from the dashboard"
exit 0
