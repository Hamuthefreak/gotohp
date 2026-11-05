#!/usr/bin/env bash
# Tune the receiving side of the SFTP node so the phone's uploads are not
# slowed down by this box.
#
#   sudo ./sftp-tuning.sh                # apply, for user `watermelon`
#   sudo ./sftp-tuning.sh --user NAME    # ... for a different SFTP user
#   sudo ./sftp-tuning.sh --revert       # remove everything it added
#
# What it can and cannot do. It cannot widen the phone's uplink, which is what
# usually limits a backup. It can stop this end from adding delay of its own:
#
#   * a TCP window sized for a high-latency link (16 MB instead of 6 MB), so one
#     SFTP stream is not capped by the distance to the region
#   * tcp_slow_start_after_idle=0 - a backup goes quiet between files and
#     between runs, and without this the transfer restarts from a small
#     congestion window every time it resumes
#   * tcp_mtu_probing=1 - a mobile path that black-holes large packets recovers
#     instead of stalling the transfer
#   * bbr/fq where the kernel has it, so a single lost packet on a lossy link
#     does not halve the window
#   * no compression: photos and videos are already compressed
#   * no 1 GB rekey stall in the middle of a file, and a session whose phone
#     left the network noticed within ~5 minutes instead of holding resources
#     until the TCP timeout
#
# Idempotent and reversible: --revert restores the box exactly. Nothing here
# changes what the relay accepts, where it writes, or the ledger.
#
# Contract tests (fake sshd/sysctl, nothing real touched): test-tuning.sh

set -Eeuo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# Tests point TUNING_ROOT at a temp directory and SSHD/SYSCTL at stubs.
ROOT=${TUNING_ROOT:-}
SSHD=${SSHD:-sshd}
SYSCTL=${SYSCTL:-sysctl}

SFTP_USER=watermelon
REVERT=false

SYSCTL_FILE=$ROOT/etc/sysctl.d/60-watermelon-sftp.conf
SSHD_FILE=$ROOT/etc/ssh/sshd_config.d/10-watermelon-sftp-tuning.conf

usage() {
	cat <<'EOF'
Usage: sudo ./sftp-tuning.sh [options]

  --user NAME   SFTP user whose sessions get the per-connection settings
                (default: watermelon)
  --revert      remove the two files this script installs and reload
  -h, --help    this text
EOF
}

while (($#)); do
	case $1 in
	--user)
		SFTP_USER=${2:?--user needs a name}
		shift 2
		;;
	--revert)
		REVERT=true
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

say() { printf '%s\n' "$*"; }

cc_available() {
	"$SYSCTL" -n net.ipv4.tcp_available_congestion_control 2>/dev/null |
		tr ' ' '\n' | grep -qx bbr
}

reload_sshd() {
	systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null ||
		echo "reload sshd to apply the change" >&2
}

write_sysctl() {
	install -d -m 0755 "$(dirname -- "$SYSCTL_FILE")"
	local tmp=$SYSCTL_FILE.tmp
	{
		cat <<'EOF'
# Managed by gotohp deploy/oracle-free-tier/sftp-tuning.sh.
# Undo with: sudo gotohp-sftp-tuning --revert
#
# The phone uploads one long-lived SFTP stream over the internet, in bursts of
# many small files. These keep this end of that stream from being the limit.

# Room for the window to grow on a long path: the default 6 MB ceiling costs a
# single stream real throughput at mobile round-trip times.
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# A backup pauses between files and between timer runs. Without this every
# resume starts again from a small congestion window.
net.ipv4.tcp_slow_start_after_idle = 0

# Some mobile paths black-hole anything above a smaller MTU; probing finds the
# real size instead of retrying into a stall.
net.ipv4.tcp_mtu_probing = 1

# A phone that changes network reconnects without the extra round trip.
net.ipv4.tcp_fastopen = 3
EOF
		if cc_available; then
			cat <<'EOF'

# Loss-based congestion control halves the window for one dropped packet, which
# is the normal state of a mobile link. bbr measures instead.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
		else
			cat <<'EOF'

# This kernel has no bbr, so keep the default qdisc and change nothing else
# here: the window and probing settings above are the ones that matter.
net.core.default_qdisc = fq_codel
EOF
		fi
	} >"$tmp"
	mv -f "$tmp" "$SYSCTL_FILE"
}

write_sshd() {
	install -d -m 0755 "$(dirname -- "$SSHD_FILE")"
	local tmp=$SSHD_FILE.tmp
	{
		cat <<'EOF'
# Managed by gotohp deploy/oracle-free-tier/sftp-tuning.sh.
# Undo with: sudo gotohp-sftp-tuning --revert
#
# Photos and videos are already compressed: compressing them again spends CPU
# on the box that is also serving the transfer, and saves nothing.
Compression no
EOF
		cat <<EOF

# The phone keeps one SFTP connection open for the whole backup.
#   RekeyLimit      a rekey after 1 GB stalls the stream mid-file; 4 GB lets a
#                   night's run finish first
#   ClientAlive*    a phone that left the network is noticed in ~5 minutes
#                   instead of holding a session until the TCP timeout
Match User $SFTP_USER
    RekeyLimit 4G
    ClientAliveInterval 60
    ClientAliveCountMax 5
# Back to global scope, so whatever Include reads next still applies to everyone.
Match all
EOF
	} >"$tmp"

	# Keep the previous file so a rejected one can be rolled back rather than
	# leaving the box with no tuning at all.
	[[ -f $SSHD_FILE ]] && cp -p "$SSHD_FILE" "$SSHD_FILE.old"
	mv -f "$tmp" "$SSHD_FILE"
	if ! "$SSHD" -t; then
		if [[ -f $SSHD_FILE.old ]]; then
			mv -f "$SSHD_FILE.old" "$SSHD_FILE"
			echo "sshd rejected the tuning file; the previous one is back in place" >&2
		else
			rm -f "$SSHD_FILE"
			echo "sshd rejected the tuning file; it was removed" >&2
		fi
		return 1
	fi
	rm -f "$SSHD_FILE.old"
}

report() {
	say "  congestion control: $("$SYSCTL" -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
	say "  window max:         $("$SYSCTL" -n net.core.rmem_max 2>/dev/null || echo '?') bytes"
	say "  idle slow start:    $("$SYSCTL" -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null || echo '?')"
	say "  mtu probing:        $("$SYSCTL" -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo '?')"
}

if [[ $REVERT == true ]]; then
	rm -f "$SSHD_FILE" "$SSHD_FILE.old" "$SYSCTL_FILE"
	if [[ -n $ROOT ]]; then
		say "removed the tuning files under $ROOT"
		exit 0
	fi
	"$SYSCTL" --system >/dev/null 2>&1 ||
		echo "warning: could not reload sysctl; the kernel keeps the tuning until reboot" >&2
	"$SSHD" -t && reload_sshd
	say "reverted: default kernel network settings, default sshd settings"
	exit 0
fi

write_sysctl
write_sshd || exit 1

if [[ -n $ROOT ]]; then
	say "wrote $SYSCTL_FILE"
	say "wrote $SSHD_FILE"
	exit 0
fi

# Other drop-ins on the box may be unappliable on their own; ours is checked by
# the report below instead of failing the install over an unrelated file.
"$SYSCTL" --system >/dev/null 2>&1 ||
	"$SYSCTL" -p "$SYSCTL_FILE" >/dev/null 2>&1 ||
	echo "warning: could not apply every sysctl setting on this boot" >&2
reload_sshd

say "sftp side tuned for user $SFTP_USER:"
report
say "undo with: sudo gotohp-sftp-tuning --revert"
