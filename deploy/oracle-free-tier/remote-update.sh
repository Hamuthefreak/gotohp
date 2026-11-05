#!/usr/bin/env bash
# Runs ON the Oracle instance, as root. Called by .github/workflows/deploy-vm.yml
# after it copies the new build into a staging directory.
#
#   sudo env SFTP_PASSWORD_FILE=/tmp/gotohp-sftp.pass \
#     bash remote-update.sh /tmp/gotohp-deploy
#
# First run bootstraps the box (users, SFTP chroot, config, units); every later
# run only swaps the binary, the relay script and the units. It never touches
# /etc/gotohp-sync/config.env, the ledger or the stored Google credentials.

set -Eeuo pipefail

SRC=${1:?usage: remote-update.sh <staging-directory>}
SYNC_CONF=${GOTOHP_SYNC_CONFIG:-/etc/gotohp-sync/config.env}
[[ $EUID -eq 0 ]] || {
	echo "run this as root" >&2
	exit 1
}

for file in gotohp-cli sync.sh install.sh config.env.example \
	gotohp-sync.service gotohp-sync.timer \
	control-agent.sh gotohp-control.service gotohp-control.timer media-date.py \
	sftp-tuning.sh; do
	[[ -f $SRC/$file ]] || {
		echo "missing $SRC/$file" >&2
		exit 1
	}
done

# The Watermelon SFTP password arrives as a file so it never appears in a
# process list. Read it, then remove it whether or not it is used.
if [[ -n ${SFTP_PASSWORD_FILE:-} && -r ${SFTP_PASSWORD_FILE} ]]; then
	SFTP_PASSWORD=$(cat -- "$SFTP_PASSWORD_FILE")
	export SFTP_PASSWORD
	rm -f -- "$SFTP_PASSWORD_FILE"
fi

# Same treatment for the dashboard address and the device token: shipped as
# root-only files, consumed here, deleted before anything else runs.
if [[ -n ${CONTROL_URL_FILE:-} && -r ${CONTROL_URL_FILE} ]]; then
	CONTROL_URL=$(tr -d '[:space:]' <"$CONTROL_URL_FILE")
	rm -f -- "$CONTROL_URL_FILE"
	if [[ ! $CONTROL_URL =~ ^https?:// ]]; then
		echo "CONTROL_URL is not an http(s) address; ignoring it" >&2
		CONTROL_URL=""
	fi
	export CONTROL_URL
fi

if [[ -n ${CONTROL_TOKEN_SOURCE:-} && -r ${CONTROL_TOKEN_SOURCE} ]]; then
	install -d -m 0750 -o root -g gotohpsync /etc/gotohp-sync
	install -m 0600 -o root -g root "$CONTROL_TOKEN_SOURCE" /etc/gotohp-sync/device.token
	rm -f -- "$CONTROL_TOKEN_SOURCE"
	echo "device token installed"
fi

# Stage the new binary and prove it runs before replacing the live one, so a
# build for the wrong architecture cannot take the relay down.
install -m 0755 -o root -g root "$SRC/gotohp-cli" /usr/local/bin/gotohp-cli.new
if ! /usr/local/bin/gotohp-cli.new version >/dev/null 2>&1; then
	echo "the new binary does not run on this host; leaving the old one in place" >&2
	rm -f /usr/local/bin/gotohp-cli.new
	exit 1
fi
mv -f /usr/local/bin/gotohp-cli.new /usr/local/bin/gotohp-cli

# A first run that fails halfway leaves the account and the config behind
# without the SFTP directory. That half-state then looks "already installed" on
# the next deploy, which skips the very step that failed - so the directory the
# phone writes into never gets created. Treat any missing piece as not installed
# and bootstrap again; install.sh is idempotent and keeps the existing config.
needs_bootstrap() {
	! id -u gotohpsync >/dev/null 2>&1 ||
		[[ ! -s $SYNC_CONF ]] ||
		[[ ! -d ${SFTP_SRC_DIR:-/srv/watermelon/repo} ]]
}

if needs_bootstrap; then
	echo "==> bootstrap: users, SFTP chroot, config and units"
	bash "$SRC/install.sh" --binary "$SRC/gotohp-cli" --non-interactive
else
	echo "==> updating an existing install"
	install -m 0755 -o root -g root "$SRC/sync.sh" /usr/local/bin/gotohp-sync
	install -m 0755 -o root -g root "$SRC/media-date.py" /usr/local/bin/gotohp-media-date
	install -m 0755 -o root -g root "$SRC/control-agent.sh" /usr/local/bin/gotohp-control
	install -m 0755 -o root -g root "$SRC/sftp-tuning.sh" /usr/local/bin/gotohp-sftp-tuning
	install -m 0644 -o root -g root "$SRC/gotohp-sync.service" /etc/systemd/system/gotohp-sync.service
	install -m 0644 -o root -g root "$SRC/gotohp-sync.timer" /etc/systemd/system/gotohp-sync.timer
	install -m 0644 -o root -g root "$SRC/gotohp-control.service" /etc/systemd/system/gotohp-control.service
	install -m 0644 -o root -g root "$SRC/gotohp-control.timer" /etc/systemd/system/gotohp-control.timer
	systemctl daemon-reload
	systemctl enable --now gotohp-sync.timer >/dev/null 2>&1 || true
	systemctl enable --now gotohp-control.timer >/dev/null 2>&1 || true

	# The dashboard address can change when a site is recreated, so keep it in
	# step with the deploy without disturbing the settings the dashboard wrote.
	if [[ -n ${CONTROL_URL:-} ]]; then
		if grep -q '^CONTROL_URL=' /etc/gotohp-sync/config.env; then
			sed -i "s|^CONTROL_URL=.*|CONTROL_URL=$CONTROL_URL|" /etc/gotohp-sync/config.env
		else
			printf 'CONTROL_URL=%s\n' "$CONTROL_URL" >>/etc/gotohp-sync/config.env
		fi
	fi

	# Removing an uploaded file needs write permission on its directory, and the
	# node's directories belong to the SFTP user. Membership is idempotent, and it
	# is re-asserted on every deploy because an existing box would otherwise keep
	# "local-cleanup-failed": the upload succeeds and the local copy stays.
	node_dir=$(sed -n 's/^SRC_DIR=//p' "$SYNC_CONF" 2>/dev/null | tail -n 1)
	node_dir=${node_dir:-/srv/watermelon/repo}
	if [[ -d $node_dir ]]; then
		node_group=$(stat -c %G -- "$node_dir")
		if [[ -n $node_group && $node_group != "$(id -gn gotohpsync 2>/dev/null)" ]]; then
			usermod -aG "$node_group" gotohpsync &&
				echo "gotohpsync is in group $node_group (so it can remove uploaded files)"
		fi
	fi

	# Applied on every deploy, not only at bootstrap: an existing box would
	# otherwise never pick up a new kernel or sshd setting. It is idempotent and
	# never fails the deploy - a tuning problem must not hold back the relay.
	bash "$SRC/sftp-tuning.sh" ||
		echo "warning: sftp-tuning.sh did not apply; the relay is unaffected" >&2

	# Restart the timer, not the service: a run that is mid-upload finishes on
	# the old binary, which is harmless because every upload is idempotent.
	systemctl restart gotohp-sync.timer
fi

echo -n "installed: "
/usr/local/bin/gotohp-cli version
echo -n "timer:     "
systemctl is-active gotohp-sync.timer
