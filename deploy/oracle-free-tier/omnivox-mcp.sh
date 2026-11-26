#!/usr/bin/env bash
# Host omnivox-mcp (a headless Chrome holding an Omnivox session) on the same
# free Oracle instance as the gotohp relay.
#
#   sudo omnivox-mcp install                     # node, chrome libs, source, unit, swap
#   sudo omnivox-mcp session cookies.json config.json   # import a login, then verify it
#   sudo omnivox-mcp status
#   sudo omnivox-mcp update                      # pull the newest upstream code
#   sudo omnivox-mcp uninstall                   # stop it, keep the data folder
#
# This box is the free tier shape: 2 vCPU, ~950 MB of RAM, no swap, and it also
# serves the phone's SFTP uploads. So the install is deliberately conservative -
# it adds swap, caps the server's memory, and lets Chrome sleep between requests
# instead of idling in RAM all day. A second server must not cost the relay a run.
#
# Idempotent: re-running install or update keeps an existing login, the generated
# access key and any edits to /etc/omnivox-mcp.env.

set -Eeuo pipefail

PREFIX=${PREFIX:-/opt/omnivox-mcp}
APP=$PREFIX/app
DATA=$PREFIX/data
# Chrome lives outside the checkout on purpose: the checkout is re-fetched and
# cleaned on every update, and a 170 MB browser download is not part of that.
PUPPETEER_DIR=$PREFIX/.puppeteer
SVC_USER=${SVC_USER:-omnivox}
ENV_FILE=${ENV_FILE:-/etc/omnivox-mcp.env}
UNIT=${UNIT:-/etc/systemd/system/omnivox-mcp.service}
PORT=${PORT:-3000}
REF=${REF:-main}
REPO=https://github.com/Beat-YT/omnivox-mcp.git
PATCH_URL=${PATCH_URL:-https://raw.githubusercontent.com/Hamuthefreak/gotohp/main/deploy/oracle-free-tier/patch-download-guard.py}
MIO_PATCH_URL=${MIO_PATCH_URL:-https://raw.githubusercontent.com/Hamuthefreak/gotohp/main/deploy/oracle-free-tier/patch-mio-guard.py}
EXTRA_PATCH_URL=${EXTRA_PATCH_URL:-https://raw.githubusercontent.com/Hamuthefreak/gotohp/main/deploy/oracle-free-tier/patch-extra-tools.py}
SWAPFILE=${SWAPFILE:-/swapfile}
SWAP_MB=${SWAP_MB:-2048}
TZ_NAME=${TZ_NAME:-America/Toronto}

# Chrome idles at ~250 MB. With BROWSER_SLEEP the browser exits after five quiet
# minutes and the next request relaunches it, which costs a couple of seconds and
# leaves the RAM to the relay. BROWSER_REFRESH_INTERVAL is ignored while it is on.
BROWSER_SLEEP=${BROWSER_SLEEP:-true}
MEM_MAX=768M
MEM_SWAP_MAX=1G

say() { printf '\n==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

usage() {
	cat <<'EOF'
Usage: sudo omnivox-mcp <command> [options]

  install                     install node, the Chrome libraries, the server and its unit
  update                      pull the newest upstream code and restart
  session FILE FILE           import cookies.json and config.json from a desktop login
  status                      show whether it is running, healthy and logged in
  uninstall                   stop and remove the unit; the data folder is kept

Options (env vars work too):
  --port N        listen port (default 3000)
  --ref NAME      git branch, tag or commit to install (default main)
  -h, --help      this text

The Omnivox login itself cannot happen here: it needs a real window. Run
`npm start` in omnivox-connection/ on a desktop, log in, save the two files it
offers, then `session` them here.
EOF
}

validate_port() {
	[[ $1 =~ ^[0-9]{1,5}$ ]] && (($1 >= 1024 && $1 <= 65535))
}

# A ref is pasted into git commands, so it is restricted rather than quoted
# everywhere: letters, digits and the punctuation branches and tags actually use.
validate_ref() {
	[[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && $1 != *..* && $1 != */ ]]
}

render_env() {
	cat <<EOF
# Managed by gotohp deploy/oracle-free-tier/omnivox-mcp.sh
# Change a value here, then: systemctl restart omnivox-mcp
PORT=$PORT
TZ=$TZ_NAME
OMNIVOX_DATA_DIR=$DATA
HOME=$PREFIX
PUPPETEER_CACHE_DIR=$PUPPETEER_DIR

# The box has under a gigabyte of RAM and also serves the phone's uploads, so
# Chrome is not kept alive between requests. Set this to false and a
# BROWSER_REFRESH_INTERVAL=10 to keep the Omnivox session warm instead - faster
# replies, a permanently resident browser, and a real risk to the relay's night.
BROWSER_SLEEP=$BROWSER_SLEEP

# Chrome for Testing will not start its own sandbox here: Ubuntu 24.04 restricts
# unprivileged user namespaces, and /dev/shm on this instance is 64 MB. The
# server is bound to this host and protected by its access key, so the tradeoff
# is the one the project's Docker image already makes.
	BROWSER_LAUNCH_ARGS="--no-sandbox --disable-setuid-sandbox --disable-dev-shm-usage"

# A rejected promise nobody caught kills node: the server died at 06:06:31 on
# 2026-11-26 with "Timed out waiting for categories response" from
# MioWeb.ts:59, exit status 1, and every tool after it answered connection
# refused until systemd restarted the unit. One slow Omnivox page must cost that
# one request, not the whole server, so a failure is logged with the stack and
# the process keeps serving.
NODE_OPTIONS=--unhandled-rejections=warn
EOF
}

# The browser's home moved out of the checkout (it was cleaned away on every
# update). An existing env file is kept on purpose, so a path left over from an
# older install has to be repaired here - otherwise the server starts, looks for
# a Chrome that this install no longer has, and answers 503 forever.
migrate_env_paths() {
	[[ -f $ENV_FILE ]] || return 0
	local current
	current=$(sed -n 's/^PUPPETEER_CACHE_DIR=//p' "$ENV_FILE" | head -n 1)
	if [[ -z $current ]]; then
		printf 'PUPPETEER_CACHE_DIR=%s\n' "$PUPPETEER_DIR" >>"$ENV_FILE"
		echo "added PUPPETEER_CACHE_DIR to $ENV_FILE"
	elif [[ $current != "$PUPPETEER_DIR" ]]; then
		sed -i "s|^PUPPETEER_CACHE_DIR=.*|PUPPETEER_CACHE_DIR=$PUPPETEER_DIR|" "$ENV_FILE"
		echo "moved PUPPETEER_CACHE_DIR in $ENV_FILE: $current -> $PUPPETEER_DIR"
	else
		return 0
	fi
	chown root:"$SVC_USER" "$ENV_FILE" 2>/dev/null || warn "could not set the owner of $ENV_FILE"
	chmod 0640 "$ENV_FILE"
}

migrate_unhandled_rejections() {
	# An env file from an older install carries no NODE_OPTIONS, and it is kept on
	# purpose, so the surviving-rejection setting has to be added here or every
	# upgrade keeps a server that dies on one slow page.
	[[ -f $ENV_FILE ]] || return 0
	if grep -q '^NODE_OPTIONS=.*unhandled-rejections=warn' "$ENV_FILE"; then
		return 0
	fi
	if grep -q '^NODE_OPTIONS=' "$ENV_FILE"; then
		sed -i '/^NODE_OPTIONS=/d' "$ENV_FILE"
	fi
	printf 'NODE_OPTIONS=--unhandled-rejections=warn\n' >>"$ENV_FILE"
	echo "added NODE_OPTIONS=--unhandled-rejections=warn to $ENV_FILE"
	chown root:"$SVC_USER" "$ENV_FILE" 2>/dev/null || warn "could not set the owner of $ENV_FILE"
	chmod 0640 "$ENV_FILE"
}

render_unit() {
	cat <<EOF
# Managed by gotohp deploy/oracle-free-tier/omnivox-mcp.sh
[Unit]
Description=Omnivox MCP server (headless Chrome bridge to the Omnivox mobile API)
Documentation=https://github.com/Beat-YT/omnivox-mcp
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=$SVC_USER
Group=$SVC_USER
WorkingDirectory=$APP
EnvironmentFile=$ENV_FILE
ExecStart=/usr/bin/npm start
Restart=always
RestartSec=5
TimeoutStopSec=30
# npm stays the main process and must be signalled; its node and chrome children
# are then killed with the cgroup rather than being left behind.
KillMode=mixed

# Bounded on purpose. A runaway Chrome on a 950 MB host would otherwise be the
# OOM killer's obvious choice, and the relay's upload run is the wrong casualty.
MemoryHigh=512M
MemoryMax=$MEM_MAX
MemorySwapMax=$MEM_SWAP_MAX
TasksMax=256

NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$PREFIX
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
}

ensure_swap() {
	# Without swap a Chrome spike is decided by the OOM killer, and everything on
	# this box - including the uploader - is a candidate. Swap makes that a slow
	# answer instead of a dead run.
	if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SWAPFILE"; then
		echo "swap already on ($SWAPFILE)"
		return 0
	fi
	[[ -f $SWAPFILE ]] || {
		if ! fallocate -l "${SWAP_MB}M" "$SWAPFILE" 2>/dev/null; then
			dd if=/dev/zero of="$SWAPFILE" bs=1M count="$SWAP_MB" status=none
		fi
	}
	chmod 600 "$SWAPFILE"
	if ! swapon --show=NAME --noheadings | grep -qx "$SWAPFILE"; then
		mkswap "$SWAPFILE" >/dev/null
		swapon "$SWAPFILE"
	fi
	grep -q "^$SWAPFILE[[:space:]]" /etc/fstab ||
		printf '%s none swap sw 0 0\n' "$SWAPFILE" >>/etc/fstab
	echo "swap on: $(free -m | awk '/^Swap:/ {print $2" MB"}')"
}

ensure_node() {
	local major=0
	if command -v node >/dev/null 2>&1; then
		major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
	fi
	# The project's image is node:22, and its dependencies assume a modern one.
	if ((major >= 20)); then
		echo "node $(node -v) is new enough"
		return 0
	fi
	say "installing node 22"
	curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
	apt-get install -y --no-install-recommends nodejs >/dev/null
	node -v
}

ensure_chrome_libs() {
	local -a missing=()
	local base=(ca-certificates curl git fonts-liberation libatk-bridge2.0-0
		libatk1.0-0 libcups2 libdbus-1-3 libdrm2 libgbm1 libgtk-3-0 libnspr4
		libnss3 libx11-xcb1 libxcomposite1 libxdamage1 libxfixes3 libxrandr2
		libxshmfence1 xdg-utils)
	# 24.04 renamed the ALSA package for the 64-bit time_t transition.
	if ! apt-get install -y --no-install-recommends libasound2t64 >/dev/null 2>&1; then
		apt-get install -y --no-install-recommends libasound2 >/dev/null
	fi
	for pkg in "${base[@]}"; do
		dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
	done
	((${#missing[@]})) || {
		echo "chrome libraries already present"
		return 0
	}
	apt-get install -y --no-install-recommends "${missing[@]}" >/dev/null
	echo "installed: ${missing[*]}"
}

ensure_user() {
	if ! id -u "$SVC_USER" >/dev/null 2>&1; then
		useradd --system --user-group --home-dir "$PREFIX" \
			--shell /usr/sbin/nologin "$SVC_USER"
	fi
	install -d -m 0755 -o "$SVC_USER" -g "$SVC_USER" "$PREFIX"
	# The session, the access key and the browser profile all live in here.
	install -d -m 0700 -o "$SVC_USER" -g "$SVC_USER" "$DATA"
	install -d -m 0755 -o "$SVC_USER" -g "$SVC_USER" "$PUPPETEER_DIR"
}

fetch_source() {
	# The checkout is owned by the service user on purpose, so git (running as
	# root here) has to be told that is expected. Without this every command on
	# an existing install dies with "detected dubious ownership".
	if ! git config --global --get-all safe.directory 2>/dev/null | grep -qxF -- "$APP"; then
		git config --global --add safe.directory "$APP"
	fi
	if [[ -d $APP/.git ]]; then
		say "fetching $REF"
		git -C "$APP" remote set-url origin "$REPO"
		git -C "$APP" fetch --depth 1 origin "$REF" -q
		git -C "$APP" checkout -q -f FETCH_HEAD
		git -C "$APP" clean -qfd
	else
		say "cloning $REF"
		git clone --depth 1 --branch "$REF" "$REPO" "$APP" -q
	fi
	chown -R "$SVC_USER:$SVC_USER" "$APP"
	# An older install kept its browser inside the checkout, where this clean
	# would have removed it.
	rm -rf "$APP/.puppeteer"
	echo "at $(git -C "$APP" rev-parse --short HEAD)"
}

npm_install() {
	say "installing dependencies (this also downloads its own Chrome)"
	# HOME and the puppeteer cache stay inside the prefix, so the browser belongs
	# to the service user and survives an update.
	(cd "$APP" && runuser -u "$SVC_USER" -- env HOME="$PREFIX" \
		PUPPETEER_CACHE_DIR="$PUPPETEER_DIR" \
		npm install --omit=dev --no-audit --no-fund >/dev/null)

	# npm only runs puppeteer's postinstall when the tree actually changed, so a
	# re-install can leave node_modules without a browser. Ask for it explicitly;
	# puppeteer keeps an existing copy and downloads only what is missing.
	if [[ -x $APP/node_modules/.bin/puppeteer ]]; then
		(cd "$APP" && runuser -u "$SVC_USER" -- env HOME="$PREFIX" \
			PUPPETEER_CACHE_DIR="$PUPPETEER_DIR" \
			./node_modules/.bin/puppeteer browsers install chrome >/dev/null)
	fi
	chown -R "$SVC_USER:$SVC_USER" "$PUPPETEER_DIR" 2>/dev/null || true
	local chrome=""
	chrome=$(find "$PUPPETEER_DIR" -name 'chrome' -type f 2>/dev/null | head -n 1 || true)
	if [[ -n $chrome ]]; then
		echo "chrome: $chrome"
	else
		warn "no chrome binary in $PUPPETEER_DIR - the server cannot answer without one"
	fi
}

install_unit() {
	say "installing the unit"
	# Written once. It is the only place the tiny-box settings can be changed, so
	# a redeploy must not quietly put the defaults back over an edited file.
	if [[ -f $ENV_FILE ]]; then
		echo "keeping existing $ENV_FILE"
		migrate_env_paths
		migrate_unhandled_rejections
	else
		(umask 0027 && render_env >"$ENV_FILE")
		chown root:"$SVC_USER" "$ENV_FILE"
		chmod 0640 "$ENV_FILE"
	fi
	render_unit >"$UNIT"
	chmod 0644 "$UNIT"
	systemctl daemon-reload
	systemctl enable omnivox-mcp.service >/dev/null 2>&1 || true
	# The server exits immediately when config.json is missing, so starting it
	# before a session exists only fills the journal with a restart loop.
	if [[ $(start_decision) == start ]]; then
		systemctl restart omnivox-mcp.service
	else
		systemctl stop omnivox-mcp.service >/dev/null 2>&1 || true
		systemctl reset-failed omnivox-mcp.service >/dev/null 2>&1 || true
		echo "not started: there is no Omnivox session in $DATA yet"
	fi
}

wait_health() {
	local i
	for i in $(seq 1 60); do
		if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
			echo "healthy on 127.0.0.1:$PORT after ${i}s"
			return 0
		fi
		sleep 1
	done
	warn "no answer on /health after 60s"
	journalctl -u omnivox-mcp.service -n 30 --no-pager || true
	return 1
}

logged_in() {
	[[ -s $DATA/cookies.json && -s $DATA/config.json ]]
}

start_decision() {
	if logged_in; then echo start; else echo wait; fi
}

apply_upstream_patches() {
	# See patch-download-guard.py and patch-mio-guard.py. The checkout is re-fetched
	# on every install, so each guard has to be re-applied here instead of living
	# in an edited file.
	apply_patch 'download guard' "${PATCH_SOURCE:-$PREFIX/patches/patch-download-guard.py}" "$PATCH_URL"
	apply_patch 'MIO guard' "${MIO_PATCH_SOURCE:-$PREFIX/patches/patch-mio-guard.py}" "$MIO_PATCH_URL"
	apply_patch 'extra read tools' "${EXTRA_PATCH_SOURCE:-$PREFIX/patches/patch-extra-tools.py}" "$EXTRA_PATCH_URL"
}

# A tool module that throws while it loads exits the whole server at startup (the
# tool list is imported before Express is up), so "is it running" cannot answer
# "are the tools there". This asks every module without starting the server and
# refuses the install when one is broken or none registered.
toolscheck() {
	local out rc
	out=$(cd "$APP" && runuser -u "$SVC_USER" -- env HOME="$PREFIX" \
		OMNIVOX_DATA_DIR="$DATA" PUPPETEER_CACHE_DIR="$PUPPETEER_DIR" \
		./node_modules/.bin/tsx scripts/toolscheck.ts 2>&1)
	rc=$?
	echo "$out" | tail -n 1 | cut -c1-400
	if ((rc != 0)); then
		warn 'a tool module failed to load (see above); the server would exit at startup'
		return 1
	fi
	echo "tools registered: $(echo "$out" | tail -n 1 | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["registered"], "from", d["checked"], "modules")' 2>/dev/null || echo 'unknown')"
}

apply_patch() {
	local label=$1 script=$2 url=$3
	say "patching the $label"
	if [[ ! -s $script ]]; then
		install -d -m 0755 "$PREFIX/patches"
		if ! curl -fsSL -H 'Cache-Control: no-cache' "$url" -o "$script"; then
			warn "could not fetch the $label patch"
			return 1
		fi
		chmod 0644 "$script"
	fi
	python3 "$script" "$APP"
}

do_install() {
	say "swap"
	ensure_swap
	say "packages"
	apt-get update -qq
	ensure_chrome_libs
	ensure_node
	say "service user and folders"
	ensure_user
	say "source"
	fetch_source
	npm_install
	apply_upstream_patches
	say "tools"
	toolscheck || warn "install still done, but the MCP server will not serve until the tool module above is fixed"
	say "unit"
	install_unit
	if [[ $(start_decision) == start ]]; then
		wait_health || true
	fi

	if [[ $(start_decision) == start ]]; then
		printf '\nomnivox-mcp is installed and running on this host.\n'
	else
		printf '\nomnivox-mcp is installed. It is enabled at boot but stopped: the server\n'
		printf 'exits immediately without a session, so nothing runs until step 2.\n'
	fi

	cat <<EOF

1. It has no Omnivox session yet. On a desktop with a screen:

     git clone https://github.com/Beat-YT/omnivox-mcp && cd omnivox-mcp/omnivox-connection
     npm install && npm start
     # log in, save cookies.json and config.json

2. Copy both files to the box, then hand them over:

     scp cookies.json config.json $SVC_USER@<this-host>:/tmp/
     sudo omnivox-mcp session /tmp/cookies.json /tmp/config.json

3. Nothing is exposed to the internet: port $PORT listens on the box only.
   Reach it with a tunnel from the machine that runs your MCP client:

     ssh -N -L $PORT:127.0.0.1:$PORT <user>@<this-host>
     http://127.0.0.1:$PORT/mcp?key=<contents of $DATA/accessKey.txt>

EOF
}

do_update() {
	fetch_source
	npm_install
	apply_upstream_patches
	say "tools"
	toolscheck || warn "the MCP server will not serve until the tool module above is fixed"
	install_unit
	wait_health || true
}

do_session() {
	local cookies=${1:?session needs cookies.json} config=${2:?session needs config.json}
	local f
	for f in "$cookies" "$config"; do
		[[ -f $f ]] || {
			echo "not a file: $f" >&2
			exit 2
		}
		# Refuse a truncated download instead of restarting into a broken session.
		node -e 'JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"))' "$f" ||
			{
				echo "$f is not valid JSON" >&2
				exit 2
			}
	done
	install -m 0600 -o "$SVC_USER" -g "$SVC_USER" "$cookies" "$DATA/cookies.json"
	install -m 0600 -o "$SVC_USER" -g "$SVC_USER" "$config" "$DATA/config.json"
	say "restarting with the new session"
	systemctl restart omnivox-mcp.service
	wait_health || exit 1

	# A healthy process only proves Express started. Asking Omnivox one real
	# question is what proves the imported cookies are live.
	local key
	key=$(cat "$DATA/accessKey.txt" 2>/dev/null || true)
	if [[ -z $key ]]; then
		warn "no access key yet; check: journalctl -u omnivox-mcp -n 30"
		return 0
	fi
	say "asking Omnivox a real question"
	local out
	if out=$(curl -sS --max-time 60 -X POST "http://127.0.0.1:$PORT/tools/get-courses-summary" \
		-H "x-mcp-auth: $key" -d '{}' 2>&1); then
		echo "${out:0:400}"
		case $out in
		*'"error"'* | *'Unauthorized'* | *'login'*)
			warn "the session was rejected; log in again on the desktop and re-run session"
			;;
		*)
			echo
			echo "The session works. Point your MCP client at:"
			echo "  http://127.0.0.1:$PORT/mcp?key=<contents of $DATA/accessKey.txt>"
			;;
		esac
	else
		warn "the request failed: ${out:0:200}"
	fi
}

do_status() {
	printf 'unit:    %s\n' "$(systemctl is-active omnivox-mcp.service 2>/dev/null || echo inactive)"
	printf 'enabled: %s\n' "$(systemctl is-enabled omnivox-mcp.service 2>/dev/null || echo no)"
	printf 'health:  '
	if curl -fsS --max-time 3 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
		echo "answering on 127.0.0.1:$PORT"
	else
		echo "no answer on 127.0.0.1:$PORT"
	fi
	printf 'session: '
	if logged_in; then echo "cookies.json + config.json present"; else echo "NOT logged in yet"; fi
	printf 'key:     '
	if [[ -s $DATA/accessKey.txt ]]; then
		echo "$DATA/accessKey.txt (readable by $SVC_USER)"
	else
		echo "not generated yet"
	fi
	printf 'memory:  %s\n' "$(systemctl show omnivox-mcp.service -p MemoryCurrent --value 2>/dev/null || echo unknown)"
	printf 'chrome:  %s\n' "$(pgrep -fa 'chrome.*--headless' >/dev/null 2>&1 && echo running || echo sleeping)"
	printf 'disk:    %s\n' "$(df -h --output=used,size,pcent / | tail -n 1)"
}

do_uninstall() {
	systemctl disable --now omnivox-mcp.service >/dev/null 2>&1 || true
	rm -f "$UNIT"
	systemctl daemon-reload
	# The login and the access key are deliberately left alone: they are the only
	# things here that cannot be regenerated on this host.
	echo "removed the unit; $DATA and $ENV_FILE are untouched"
}

main() {
	local command=${1:-}
	[[ -n $command ]] && shift
	while (($#)); do
		case $1 in
		--port)
			PORT=${2:?--port needs a number}
			shift 2
			;;
		--ref)
			REF=${2:?--ref needs a name}
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			# Remaining words are arguments to `session`.
			if [[ $command == session ]]; then break; fi
			echo "unknown argument: $1" >&2
			usage
			exit 2
			;;
		esac
	done

	validate_port "$PORT" || {
		echo "invalid port: $PORT (1024-65535)" >&2
		exit 2
	}
	validate_ref "$REF" || {
		echo "invalid ref: $REF" >&2
		exit 2
	}

	case $command in
	install | update | session | status | uninstall) ;;
	help | -h | --help)
		usage
		exit 0
		;;
	*)
		echo "unknown command: ${command:-<none>}" >&2
		usage
		exit 2
		;;
	esac

	[[ $EUID -eq 0 ]] || {
		echo "run this as root (sudo)" >&2
		exit 1
	}

	case $command in
	install) do_install ;;
	update) do_update ;;
	session) do_session "$@" ;;
	status) do_status ;;
	uninstall) do_uninstall ;;
	esac
}

# test-omnivox.sh sources this file to exercise the renderers without a box.
if [[ ${OMNIVOX_LIB:-0} == 1 ]]; then
	return 0
fi

main "$@"
