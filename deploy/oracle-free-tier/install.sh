#!/usr/bin/env bash
# Install the Watermelon -> gotohp -> Google Photos pipeline on this host.
#
# Run as root on the Oracle instance, from the directory that holds sync.sh:
#   sudo ./install.sh --binary /root/gotohp-cli
#
# What it sets up:
#   * a nologin system user `gotohpsync` that owns the ledger and credentials
#   * an SFTP-only, chrooted user `watermelon` that Watermelon Backup writes to
#   * /usr/local/bin/gotohp-cli, /usr/local/bin/gotohp-sync,
#     /usr/local/bin/gotohp-media-date
#   * /etc/gotohp-sync/config.env
#   * gotohp-sync.service + gotohp-sync.timer, timer enabled
#
# Idempotent: re-running it upgrades the script and units in place and leaves an
# existing config.env and password alone.

set -Eeuo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN=""
SFTP_USER=watermelon
SRC_DIR=/srv/watermelon/repo
STATE_DIR=/var/lib/gotohp-sync
SYNC_USER=gotohpsync
WITH_SFTP=true
NONINTERACTIVE=false

usage() {
	cat <<'EOF'
Usage: sudo ./install.sh --binary <path-to-gotohp-cli> [options]

  --binary PATH     gotohp-cli binary to install (required)
  --sftp-user NAME  SFTP-only chroot user Watermelon writes as (default: watermelon)
  --src PATH        node directory inside the chroot (default: /srv/watermelon/repo)
  --no-sftp         skip the SFTP user and sshd changes
  --non-interactive never prompt; take the SFTP password from $SFTP_PASSWORD
  -h, --help        this text
EOF
}

while (($#)); do
	case $1 in
	--binary)
		BIN=${2:?--binary needs a path}
		shift 2
		;;
	--sftp-user)
		SFTP_USER=${2:?--sftp-user needs a name}
		shift 2
		;;
	--src)
		SRC_DIR=${2:?--src needs a path}
		shift 2
		;;
	--no-sftp)
		WITH_SFTP=false
		shift
		;;
	--non-interactive)
		NONINTERACTIVE=true
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "unknown argument: $1" >&2
		usage
		exit 2
		;;
	esac
done

[[ $EUID -eq 0 ]] || {
	echo "run this as root" >&2
	exit 1
}
[[ -n $BIN && -f $BIN ]] || {
	echo "--binary must point at the gotohp-cli binary" >&2
	exit 2
}
[[ -f $HERE/sync.sh ]] || {
	echo "sync.sh not found next to install.sh" >&2
	exit 2
}

say() { printf '\n==> %s\n' "$*"; }

say "creating $SYNC_USER"
if ! id -u "$SYNC_USER" >/dev/null 2>&1; then
	useradd --system --user-group --home-dir "$STATE_DIR" \
		--shell /usr/sbin/nologin "$SYNC_USER"
fi
install -d -m 0700 -o "$SYNC_USER" -g "$SYNC_USER" "$STATE_DIR"

say "installing binaries"
install -m 0755 -o root -g root "$BIN" /usr/local/bin/gotohp-cli
install -m 0755 -o root -g root "$HERE/sync.sh" /usr/local/bin/gotohp-sync
if [[ -f $HERE/control-agent.sh ]]; then
	install -m 0755 -o root -g root "$HERE/control-agent.sh" /usr/local/bin/gotohp-control
fi
if [[ -f $HERE/media-date.py ]]; then
	install -m 0755 -o root -g root "$HERE/media-date.py" /usr/local/bin/gotohp-media-date
fi
if [[ -f $HERE/sftp-tuning.sh ]]; then
	install -m 0755 -o root -g root "$HERE/sftp-tuning.sh" /usr/local/bin/gotohp-sftp-tuning
fi

say "installing configuration"
install -d -m 0750 -o root -g "$SYNC_USER" /etc/gotohp-sync
if [[ -f /etc/gotohp-sync/config.env ]]; then
	echo "keeping existing /etc/gotohp-sync/config.env"
else
	install -m 0640 -o root -g "$SYNC_USER" \
		"$HERE/config.env.example" /etc/gotohp-sync/config.env
	if [[ $SRC_DIR != /srv/watermelon/repo ]]; then
		sed -i "s|^SRC_DIR=.*|SRC_DIR=$SRC_DIR|" /etc/gotohp-sync/config.env
	fi
fi

# The dashboard address is deploy configuration, not a user setting, so it is
# written here every time rather than being editable from the UI.
if [[ -n ${CONTROL_URL:-} ]]; then
	if grep -q '^CONTROL_URL=' /etc/gotohp-sync/config.env; then
		sed -i "s|^CONTROL_URL=.*|CONTROL_URL=$CONTROL_URL|" /etc/gotohp-sync/config.env
	else
		printf 'CONTROL_URL=%s\n' "$CONTROL_URL" >>/etc/gotohp-sync/config.env
	fi
fi

if [[ $WITH_SFTP == true ]]; then
	say "creating SFTP-only user $SFTP_USER"
	CHROOT=$(dirname -- "$SRC_DIR")

	# The account has to exist before anything is chowned to it, and the chroot
	# has to exist before the SFTP directory inside it. Home creation is skipped
	# on purpose: the chroot must stay root-owned and unwritable by the user, or
	# sshd refuses to chroot into it.
	if ! id -u "$SFTP_USER" >/dev/null 2>&1; then
		useradd --no-create-home --home-dir "$CHROOT" \
			--shell /usr/sbin/nologin --user-group "$SFTP_USER"
	fi
	install -d -m 0755 -o root -g root "$CHROOT"
	install -d -m 0755 -o "$SFTP_USER" -g "$SFTP_USER" "$SRC_DIR"

	# Removing an uploaded file needs write permission on its directory, not on
	# the file, and every directory in the node belongs to the SFTP user. So the
	# relay joins that group rather than taking the node over: Watermelon keeps
	# owning its own manifests and can still restore to the phone.
	if [[ $SFTP_USER != "$SYNC_USER" ]]; then
		usermod -aG "$SFTP_USER" "$SYNC_USER" &&
			echo "$SYNC_USER is in group $SFTP_USER (so it can remove uploaded files)"
	fi

	# sshd refuses a chroot that the user can write to, and needs the account to
	# authenticate by password (the app cannot use a key prompt).
	if [[ -z $(passwd -S "$SFTP_USER" | awk '$2 == "P"') ]]; then
		if [[ -n ${SFTP_PASSWORD:-} ]]; then
			# CI path: the password comes from a repository secret.
			printf '%s:%s\n' "$SFTP_USER" "$SFTP_PASSWORD" | chpasswd
			echo "SFTP password set from SFTP_PASSWORD"
		elif [[ $NONINTERACTIVE == true ]]; then
			# 512 random bytes leave ~124 alphanumerics after filtering; take 24.
			PW=$(dd if=/dev/urandom bs=512 count=1 2>/dev/null | tr -dc 'A-Za-z0-9' | cut -c1-24)
			printf '%s:%s\n' "$SFTP_USER" "$PW" | chpasswd
			(umask 077 && printf '%s\n' "$PW" >/root/watermelon-sftp-password)
			unset PW
			echo "SFTP password generated: sudo cat /root/watermelon-sftp-password"
		else
			echo
			echo "Set the password Watermelon will use for SFTP (user: $SFTP_USER):"
			while true; do
				read -r -s -p "  password: " pw1
				echo
				read -r -s -p "  again:    " pw2
				echo
				[[ -n $pw1 && $pw1 == "$pw2" ]] && break
				echo "  empty or mismatched, try again"
			done
			printf '%s:%s\n' "$SFTP_USER" "$pw1" | chpasswd
			unset pw1 pw2
		fi
	fi

	DROPIN=/etc/ssh/sshd_config.d/60-watermelon-sftp.conf
	install -d -m 0755 /etc/ssh/sshd_config.d
	cat >"$DROPIN" <<EOF
# Managed by gotohp deploy/oracle-free-tier/install.sh
# Watermelon Backup node: SFTP only, chrooted, password auth for this user only.
Match User $SFTP_USER
    ChrootDirectory $CHROOT
    ForceCommand internal-sftp
    PasswordAuthentication yes
    AllowTcpForwarding no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTunnel no
EOF

	if ! sshd -t; then
		rm -f "$DROPIN"
		echo "sshd rejected the drop-in; removed it and left sshd untouched" >&2
		exit 1
	fi
	systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null ||
		echo "reload sshd manually to apply $DROPIN" >&2

	# The kernel and sshd knobs that stop this box from adding delay to the
	# phone's uploads. Non-fatal on purpose: without them SFTP works exactly as
	# before, just no faster than the defaults.
	if [[ -f $HERE/sftp-tuning.sh ]]; then
		say "tuning the SFTP side"
		bash "$HERE/sftp-tuning.sh" --user "$SFTP_USER" ||
			echo "warning: sftp-tuning.sh did not apply; SFTP itself is unaffected" >&2
	fi

fi

say "installing systemd units"
install -m 0644 "$HERE/gotohp-sync.service" /etc/systemd/system/gotohp-sync.service
install -m 0644 "$HERE/gotohp-sync.timer" /etc/systemd/system/gotohp-sync.timer
if [[ -f $HERE/gotohp-control.service ]]; then
	install -m 0644 "$HERE/gotohp-control.service" /etc/systemd/system/gotohp-control.service
	install -m 0644 "$HERE/gotohp-control.timer" /etc/systemd/system/gotohp-control.timer
fi
systemctl daemon-reload
systemctl enable --now gotohp-sync.timer
if [[ -f /etc/systemd/system/gotohp-control.timer ]]; then
	systemctl enable --now gotohp-control.timer
fi

cat <<EOF

Done (manual install). Remaining steps:

1. Add a Google account, as $SYNC_USER, from the Embedded Setup oauth_token:
     sudo -u $SYNC_USER /usr/local/bin/gotohp-cli creds add - \\
       --config $STATE_DIR/gotohp.config
   (paste the oauth_token cookie value, then Ctrl-D)

2. Check the SFTP host key fingerprint so Watermelon pins the right one:
     ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub

3. In Watermelon Backup add an SFTP node:
     host: <public IP>, port 22, user: $SFTP_USER
     base path: /$(basename -- "$SRC_DIR")
   Then run a small backup of one month and confirm:
     sudo journalctl -u gotohp-sync.service -n 50
     ls $SRC_DIR

4. Watch the first real run:
     sudo systemctl start gotohp-sync.service

EOF
