#!/usr/bin/env bash
# Put the Omnivox MCP server on the internet: a login-protected dashboard, a
# bearer-token MCP endpoint, and the Cloudflare tunnel that publishes them.
#
#   sudo omnivox-gate install        install/refresh the gate and its tunnel
#   sudo omnivox-gate status         units, health, public URL
#   sudo omnivox-gate url            just the public URL
#   sudo omnivox-gate uninstall      stop everything, keep the dashboard data
#
# The gate listens on 127.0.0.1:8080 only. cloudflared dials out to Cloudflare
# and gives that a public HTTPS name, so nothing has to be opened in the Oracle
# security list and the box stays unreachable by port scan.
#
# A quick tunnel (what this installs) needs no Cloudflare account, and its name
# changes whenever the tunnel restarts. Pinning the name means a named tunnel on
# a domain, see deploy/oracle-free-tier/SETUP.md.

set -Eeuo pipefail

PREFIX=${PREFIX:-/opt/omnivox-mcp}
GATE_DIR="$PREFIX/gate"
SVC_USER=${SVC_USER:-omnivox}
ENV_FILE=${ENV_FILE:-/etc/ovx-gate.env}
UNIT=${UNIT:-/etc/systemd/system/ovx-gate.service}
TUNNEL_UNIT=${TUNNEL_UNIT:-/etc/systemd/system/ovx-gate-tunnel.service}
PORT=${PORT:-8080}
UPSTREAM=${UPSTREAM:-http://127.0.0.1:3000}
REF=${REF:-main}
RAW="https://raw.githubusercontent.com/Hamuthefreak/gotohp/$REF/deploy/oracle-free-tier"
GATE_USERNAME=${GATE_USERNAME:-2652532}
CLOUDFLARED=${CLOUDFLARED:-/usr/local/bin/cloudflared}
COMMAND=${COMMAND:-/usr/local/bin/omnivox-gate}
NEW_CODE=${NEW_CODE:-0}

say() { printf '\n==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

usage() {
	cat <<'EOF'
Usage: sudo omnivox-gate <command> [options]

  install                  install or refresh the dashboard and its tunnel
  status                   units, health and the public URL
  url                      print the public URL
  code                     print the first-visit setup code
  token                    print the MCP bearer token (creates it if missing)
  reset-setup              mint a new setup code (before the password is set)
  uninstall                stop and remove both units; the dashboard data stays

Options (environment variables work too):
  --port N        local port the dashboard listens on (default 8080)
  --ref NAME      git branch, tag or commit to fetch gate.mjs from (default main)
  --new-code      mint a fresh setup code while installing (a plain install
                  keeps the one already on disk)
  -h, --help      this text

The MCP server itself is installed and logged in by `omnivox-mcp`. This script
only puts a password-protected door in front of it.
EOF
}

validate_port() {
	[[ $1 =~ ^[0-9]{1,5}$ ]] && (($1 >= 1024 && $1 <= 65535))
}

validate_ref() {
	[[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ && $1 != *..* && $1 != */ ]]
}

need_root() {
	[[ $EUID -eq 0 ]] || {
		echo 'run this as root' >&2
		exit 1
	}
}

ensure_node() {
	command -v node >/dev/null 2>&1 || {
		echo 'node is missing: run `sudo omnivox-mcp install` first' >&2
		exit 1
	}
	local major
	major=$(node -p 'process.versions.node.split(".")[0]')
	((major >= 20)) || {
		echo "node $major is too old for the dashboard: run \`sudo omnivox-mcp install\` first" >&2
		exit 1
	}
}

ensure_user() {
	if ! id -u "$SVC_USER" >/dev/null 2>&1; then
		useradd --system --user-group --home-dir "$PREFIX" \
			--shell /usr/sbin/nologin "$SVC_USER"
	fi
	install -d -m 0755 -o "$SVC_USER" -g "$SVC_USER" "$PREFIX"
	install -d -m 0700 -o "$SVC_USER" -g "$SVC_USER" "$GATE_DIR"
}

ensure_cloudflared() {
	if [[ -x $CLOUDFLARED ]]; then
		echo "cloudflared $(cloudflared --version 2>/dev/null | awk '{print $3}')"
		return 0
	fi
	local arch
	case $(uname -m) in
	x86_64) arch=amd64 ;;
	aarch64 | arm64) arch=arm64 ;;
	*)
		echo "no cloudflared build for $(uname -m)" >&2
		exit 1
		;;
	esac
	say "installing cloudflared ($arch)"
	curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$arch" \
		-o "$CLOUDFLARED"
	chmod 0755 "$CLOUDFLARED"
	"$CLOUDFLARED" --version
}

# SETUP.md, the usage text and the first-run banner all tell the operator to run
# `sudo omnivox-gate ...`. Install this script where a plain shell finds it, or
# the deploy leaves it in /tmp/ovx-gate-ship and every documented command fails
# with "command not found".
install_command() {
	local src=${BASH_SOURCE[0]:-}
	if [[ -z $src || ! -f $src ]]; then
		warn "cannot tell where this script lives; install it as $COMMAND"
		return 1
	fi
	src=$(readlink -f "$src")
	[[ $src == "$COMMAND" ]] || install -m 0755 "$src" "$COMMAND"
	echo "$COMMAND"
}

fetch_gate() {
	if [[ -n ${GATE_SOURCE:-} ]]; then
		install -m 0644 "$GATE_SOURCE" "$GATE_DIR/gate.mjs"
		echo "gate.mjs from $GATE_SOURCE"
		return 0
	fi
	say "fetching gate.mjs ($REF)"
	curl -fsSL -H 'Cache-Control: no-cache' "$RAW/gate.mjs" -o "$GATE_DIR/gate.mjs"
	chmod 0644 "$GATE_DIR/gate.mjs"
	node --check "$GATE_DIR/gate.mjs"
	echo "gate.mjs $(wc -l <"$GATE_DIR/gate.mjs") lines"
}

render_env() {
	cat <<EOF
# Managed by gotohp deploy/oracle-free-tier/omnivox-gate.sh
# Change a value here, then: systemctl restart ovx-gate
PORT=$PORT
UPSTREAM=$UPSTREAM
DATA_DIR=$GATE_DIR
OMNIVOX_KEY_FILE=$PREFIX/data/accessKey.txt
GATE_USERNAME=$GATE_USERNAME
CLOUDFLARED_LOG=$GATE_DIR/cloudflared.log
# The tunnel terminates TLS, so the session cookie is marked Secure.
GATE_HTTPS=1
EOF
}

render_units() {
	cat >"$UNIT" <<EOF
# Managed by gotohp deploy/oracle-free-tier/omnivox-gate.sh
[Unit]
Description=Omnivox dashboard and MCP bearer-token gate
Documentation=https://github.com/Beat-YT/omnivox-mcp
After=network-online.target ovx-gate-tunnel.service
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=$SVC_USER
Group=$SVC_USER
WorkingDirectory=$GATE_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$(command -v node) $GATE_DIR/gate.mjs
Restart=always
RestartSec=3
# The box has under a gigabyte of RAM and also serves the phone's uploads.
MemoryMax=192M
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=full
ReadWritePaths=$GATE_DIR
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
	chmod 0644 "$UNIT"

	cat >"$TUNNEL_UNIT" <<EOF
# Managed by gotohp deploy/oracle-free-tier/omnivox-gate.sh
[Unit]
Description=Cloudflare quick tunnel for the Omnivox dashboard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SVC_USER
Group=$SVC_USER
ExecStart=$CLOUDFLARED tunnel --no-autoupdate --loglevel info \\
  --url http://127.0.0.1:$PORT \\
  --logfile $GATE_DIR/cloudflared.log \\
  --metrics 127.0.0.1:20241
Restart=always
RestartSec=5
MemoryMax=128M
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF
	chmod 0644 "$TUNNEL_UNIT"
}

wait_health() {
	local i
	for i in $(seq 1 40); do
		if curl -fsS "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
			echo "gate healthy on 127.0.0.1:$PORT"
			return 0
		fi
		sleep 0.5
	done
	warn "the gate did not answer on 127.0.0.1:$PORT"
	journalctl -u ovx-gate.service -n 20 --no-pager || true
	return 1
}

public_url() {
	local url=''
	if [[ -r $GATE_DIR/cloudflared.log ]]; then
		url=$(grep -oE 'https://[a-z0-9][a-z0-9-]*\.trycloudflare\.com' "$GATE_DIR/cloudflared.log" 2>/dev/null | tail -n 1 || true)
	fi
	echo "$url"
}

wait_tunnel() {
	local i url=''
	for i in $(seq 1 60); do
		url=$(public_url)
		[[ -n $url ]] && {
			echo "$url"
			return 0
		}
		sleep 1
	done
	return 1
}

setup_code() {
	cat "$GATE_DIR/setup-code.txt" 2>/dev/null || true
}

# The setup code belongs to the owner, not to the deploy: a reinstall keeps the
# one already on disk, so a code somebody was handed still works afterwards.
# Only an explicit rotation - install --new-code, or reset-setup - replaces it.
# Once a password exists the code is spent and is removed either way.
prepare_setup_code() {
	if [[ -s $GATE_DIR/auth.json ]]; then
		rm -f "$GATE_DIR/setup-code.txt"
		return 0
	fi
	[[ ${NEW_CODE:-0} == 1 ]] || return 0
	rm -f "$GATE_DIR/setup-code.txt"
	echo 'rotating the setup code (--new-code)'
}

do_install() {
	need_root
	ensure_node
	ensure_user
	ensure_cloudflared
	fetch_gate
	install_command || warn "$COMMAND is not installed; call this script by path"

	say 'units'
	prepare_setup_code
	(umask 0027 && render_env >"$ENV_FILE")
	chown root:"$SVC_USER" "$ENV_FILE"
	chmod 0640 "$ENV_FILE"
	render_units
	systemctl daemon-reload
	systemctl enable ovx-gate-tunnel.service >/dev/null 2>&1 || true
	systemctl enable ovx-gate.service >/dev/null 2>&1 || true
	# A quick tunnel is given a new public name every time it starts, so the log
	# has to start empty: otherwise the name printed below, and the one the
	# dashboard shows, is the dead name from the previous run.
	systemctl stop ovx-gate-tunnel.service >/dev/null 2>&1 || true
	if [[ -f $GATE_DIR/cloudflared.log ]]; then
		mv -f "$GATE_DIR/cloudflared.log" "$GATE_DIR/cloudflared.log.1"
	fi
	systemctl restart ovx-gate-tunnel.service
	systemctl restart ovx-gate.service
	wait_health || true

	say 'public url'
	local url
	if url=$(wait_tunnel); then
		echo "$url"
	else
		warn "no tunnel name yet; check: journalctl -u ovx-gate-tunnel -n 30"
	fi

	if [[ ! -s $GATE_DIR/auth.json ]]; then
		cat <<EOF

Open ${url:-https://<the tunnel name>} and choose the password for username
$GATE_USERNAME. The first-visit form also asks for the setup code, which is
never printed in a log (this one is public). Read it on the box:

    sudo omnivox-gate code

It stops working as soon as the password is set. The dashboard then shows the
MCP endpoint and its bearer token.

Nothing was opened on the firewall: the tunnel dials out from this box.
EOF
	else
		cat <<EOF

Dashboard: ${url:-https://<the tunnel name>}
The password is already set, so there is no setup code.
EOF
	fi
}

do_status() {
	local url code
	url=$(public_url)
	printf 'gate:    %s\n' "$(systemctl is-active ovx-gate.service 2>/dev/null || echo inactive)"
	printf 'tunnel:  %s\n' "$(systemctl is-active ovx-gate-tunnel.service 2>/dev/null || echo inactive)"
	printf 'health:  %s\n' "$(curl -fsS "http://127.0.0.1:$PORT/healthz" 2>/dev/null || echo 'no answer')"
	printf 'url:     %s\n' "${url:-not up yet}"
	printf 'mcp:     %s\n' "${url:+$url/mcp}"
	printf 'password: %s\n' "$([[ -s $GATE_DIR/auth.json ]] && echo 'set' || echo 'not set yet')"
	if [[ -s $GATE_DIR/auth.json ]]; then
		printf 'setup:   closed (the password is set)\n'
	elif [[ -s $GATE_DIR/setup-code.txt ]]; then
		printf 'setup:   open, read the code with: sudo omnivox-gate code\n'
	else
		printf 'setup:   open, the code is minted on the first start\n'
	fi
	if command -v systemctl >/dev/null 2>&1; then
		printf 'omnivox: %s\n' "$(systemctl is-active omnivox-mcp.service 2>/dev/null || echo inactive)"
		printf 'relay:   %s\n' "$(systemctl is-active gotohp-sync.timer 2>/dev/null || echo inactive)"
	fi
}

# Root-only on purpose: this is the one secret that must never reach a log.
do_code() {
	if [[ -s $GATE_DIR/auth.json ]]; then
		echo 'the password is already set; there is no setup code any more' >&2
		return 1
	fi
	local code
	code=$(setup_code)
	if [[ -z $code ]]; then
		echo 'no code yet: start the gate once (systemctl restart ovx-gate)' >&2
		return 1
	fi
	echo "$code"
}

# Root-only, for a shell that needs to call the MCP endpoint itself (the public
# smoke test does) without going through the dashboard.
do_token() {
	need_root
	local file=$GATE_DIR/token.txt
	if [[ ! -s $file ]] || (($(wc -c <"$file") < 32)); then
		(umask 0077 && head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$file")
		chown "$SVC_USER:$SVC_USER" "$file"
		chmod 0600 "$file"
	fi
	cat "$file"
}

do_reset_setup() {	need_root
	if [[ -s $GATE_DIR/auth.json ]]; then
		echo 'a password is already set; reset it by deleting' "$GATE_DIR/auth.json" >&2
		return 1
	fi
	rm -f "$GATE_DIR/setup-code.txt"
	systemctl restart ovx-gate.service
	sleep 1
	do_code >/dev/null && echo 'a new setup code is ready: sudo omnivox-gate code'
}

do_uninstall() {
	need_root
	systemctl disable --now ovx-gate.service >/dev/null 2>&1 || true
	systemctl disable --now ovx-gate-tunnel.service >/dev/null 2>&1 || true
	rm -f "$UNIT" "$TUNNEL_UNIT"
	systemctl daemon-reload
	echo "removed the units; $GATE_DIR (password, token) and $ENV_FILE are untouched"
}

CMD=${1:-}
[[ $# -gt 0 ]] && shift
while [[ $# -gt 0 ]]; do
	case $1 in
	--port)
		validate_port "${2:-}" || {
			echo "bad --port: ${2:-}" >&2
			exit 2
		}
		PORT=$2
		shift 2
		;;
	--ref)
		validate_ref "${2:-}" || {
			echo "bad --ref: ${2:-}" >&2
			exit 2
		}
		REF=$2
		shift 2
		;;
	--new-code)
		NEW_CODE=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "unknown option: $1" >&2
		exit 2
		;;
	esac
done

if [[ ${OMNIVOX_GATE_LIB:-} == 1 ]]; then
	return 0 2>/dev/null || exit 0
fi

case $CMD in
install) do_install ;;
status) do_status ;;
url) public_url ;;
code) do_code ;;
token) do_token ;;
reset-setup) do_reset_setup ;;
uninstall) do_uninstall ;;
'' | -h | --help) usage ;;
*)
	echo "unknown command: $CMD" >&2
	usage >&2
	exit 2
	;;
esac
