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
[[ $EUID -eq 0 ]] || {
	echo "run this as root" >&2
	exit 1
}

for file in gotohp-cli sync.sh install.sh config.env.example \
	gotohp-sync.service gotohp-sync.timer; do
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

# Stage the new binary and prove it runs before replacing the live one, so a
# build for the wrong architecture cannot take the relay down.
install -m 0755 -o root -g root "$SRC/gotohp-cli" /usr/local/bin/gotohp-cli.new
if ! /usr/local/bin/gotohp-cli.new version >/dev/null 2>&1; then
	echo "the new binary does not run on this host; leaving the old one in place" >&2
	rm -f /usr/local/bin/gotohp-cli.new
	exit 1
fi
mv -f /usr/local/bin/gotohp-cli.new /usr/local/bin/gotohp-cli

if ! id -u gotohpsync >/dev/null 2>&1 || [[ ! -s /etc/gotohp-sync/config.env ]]; then
	echo "==> first deploy: creating users, SFTP chroot, config and units"
	bash "$SRC/install.sh" --binary "$SRC/gotohp-cli" --non-interactive
else
	echo "==> updating an existing install"
	install -m 0755 -o root -g root "$SRC/sync.sh" /usr/local/bin/gotohp-sync
	install -m 0644 -o root -g root "$SRC/gotohp-sync.service" /etc/systemd/system/gotohp-sync.service
	install -m 0644 -o root -g root "$SRC/gotohp-sync.timer" /etc/systemd/system/gotohp-sync.timer
	systemctl daemon-reload
	systemctl enable --now gotohp-sync.timer >/dev/null 2>&1 || true

	# Restart the timer, not the service: a run that is mid-upload finishes on
	# the old binary, which is harmless because every upload is idempotent.
	systemctl restart gotohp-sync.timer
fi

echo -n "installed: "
/usr/local/bin/gotohp-cli version
echo -n "timer:     "
systemctl is-active gotohp-sync.timer
