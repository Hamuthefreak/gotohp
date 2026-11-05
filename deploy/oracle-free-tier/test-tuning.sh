#!/usr/bin/env bash
# Contract tests for sftp-tuning.sh. Nothing real is touched: the script is
# pointed at a temp root with stubbed sshd and sysctl.
#
#   bash deploy/oracle-free-tier/test-tuning.sh

set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TUNING=$HERE/sftp-tuning.sh
[[ -f $TUNING ]] || {
	echo "sftp-tuning.sh not found next to this script" >&2
	exit 2
}
bash -n "$TUNING" || exit 2

BASE=$(mktemp -d)
trap 'rm -rf "$BASE"' EXIT
mkdir -p "$BASE/bin"

cat >"$BASE/bin/sshd" <<'STUB'
#!/usr/bin/env bash
if [[ ${FAKE_SSHD_BAD:-0} == 1 ]]; then
	echo 'unsupported option: RekeyLimit' >&2
	exit 255
fi
exit 0
STUB
cat >"$BASE/bin/sysctl" <<'STUB'
#!/usr/bin/env bash
case $* in
*net.ipv4.tcp_available_congestion_control*)
	if [[ ${FAKE_NO_BBR:-0} == 1 ]]; then echo 'reno cubic'; else echo 'reno cubic bbr'; fi
	;;
*) exit 0 ;;
esac
STUB
chmod +x "$BASE/bin/sshd" "$BASE/bin/sysctl"

pass=0
fail=0
ok() {
	pass=$((pass + 1))
	printf '  ok   %s\n' "$1"
}
bad() {
	fail=$((fail + 1))
	printf '  FAIL %s\n' "$1"
}
check() {
	local name=$1
	shift
	if "$@"; then ok "$name"; else bad "$name"; fi
}
has_line() {
	grep -qxF -- "$2" "$1" 2>/dev/null
}
# Run the script against a fresh temp root; everything it writes stays there.
run() {
	local root=$1
	shift
	TUNING_ROOT=$root SSHD=$BASE/bin/sshd SYSCTL=$BASE/bin/sysctl \
		bash "$TUNING" "$@"
}
sysctl_file() { printf '%s/etc/sysctl.d/60-watermelon-sftp.conf' "$1"; }
sshd_file() { printf '%s/etc/ssh/sshd_config.d/10-watermelon-sftp-tuning.conf' "$1"; }

echo 'a fresh apply writes both files'
ROOT=$BASE/root1
run "$ROOT" >/dev/null
check 'exits 0' test $? -eq 0
check 'sysctl drop-in exists' test -f "$(sysctl_file "$ROOT")"
check 'sshd drop-in exists' test -f "$(sshd_file "$ROOT")"
check 'window ceiling raised' has_line "$(sysctl_file "$ROOT")" 'net.core.rmem_max = 16777216'
check 'mtu probing on' has_line "$(sysctl_file "$ROOT")" 'net.ipv4.tcp_mtu_probing = 1'
check 'no idle slow start' has_line "$(sysctl_file "$ROOT")" 'net.ipv4.tcp_slow_start_after_idle = 0'
check 'bbr selected when the kernel has it' has_line "$(sysctl_file "$ROOT")" 'net.ipv4.tcp_congestion_control = bbr'
check 'compression off' has_line "$(sshd_file "$ROOT")" 'Compression no'
check 'settings scoped to the sftp user' has_line "$(sshd_file "$ROOT")" 'Match User watermelon'
check 'rekey stall moved to 4 GB' grep -qxF -- '    RekeyLimit 4G' "$(sshd_file "$ROOT")"
check 'dead sessions noticed' grep -qxF -- '    ClientAliveInterval 60' "$(sshd_file "$ROOT")"
check 'scope returns to global' tail -n 1 "$(sshd_file "$ROOT")" | grep -qxF 'Match all'
check 'no leftover temp files' bash -c '! ls "$1"/*.tmp >/dev/null 2>&1' _ "$(dirname "$(sshd_file "$ROOT")")"

echo 'a second apply is a no-op'
before=$(cksum <"$(sysctl_file "$ROOT")")$(cksum <"$(sshd_file "$ROOT")")
run "$ROOT" >/dev/null
after=$(cksum <"$(sysctl_file "$ROOT")")$(cksum <"$(sshd_file "$ROOT")")
check 'files unchanged' test "$before" = "$after"

echo 'a kernel without bbr still gets the rest'
ROOT=$BASE/root2
FAKE_NO_BBR=1 run "$ROOT" >/dev/null
check 'no bbr line' bash -c '! grep -q tcp_congestion_control "$1"' _ "$(sysctl_file "$ROOT")"
check 'default qdisc kept' has_line "$(sysctl_file "$ROOT")" 'net.core.default_qdisc = fq_codel'
check 'window still raised' has_line "$(sysctl_file "$ROOT")" 'net.core.rmem_max = 16777216'

echo 'a custom SFTP user is honoured'
ROOT=$BASE/root3
run "$ROOT" --user nodeuser >/dev/null
check 'match block uses it' has_line "$(sshd_file "$ROOT")" 'Match User nodeuser'

echo 'a config sshd rejects is rolled back'
ROOT=$BASE/root4
run "$ROOT" >/dev/null
sum=$(cksum <"$(sshd_file "$ROOT")")
FAKE_SSHD_BAD=1 run "$ROOT" >/dev/null 2>&1
check 'exits non-zero' test $? -ne 0
check 'previous file restored' test "$(cksum <"$(sshd_file "$ROOT")")" = "$sum"
check 'no backup left behind' test ! -f "$(sshd_file "$ROOT").old"

echo 'a rejected first attempt leaves nothing behind'
ROOT=$BASE/root5
FAKE_SSHD_BAD=1 run "$ROOT" >/dev/null 2>&1
check 'exits non-zero' test $? -ne 0
check 'sshd drop-in removed' test ! -f "$(sshd_file "$ROOT")"

echo '--revert removes what it added'
ROOT=$BASE/root6
run "$ROOT" >/dev/null
run "$ROOT" --revert >/dev/null
check 'exits 0' test $? -eq 0
check 'sysctl drop-in gone' test ! -f "$(sysctl_file "$ROOT")"
check 'sshd drop-in gone' test ! -f "$(sshd_file "$ROOT")"
run "$ROOT" --revert >/dev/null
check 'reverting twice is fine' test $? -eq 0

echo
if ((fail)); then
	printf '%d passed, %d failed\n' "$pass" "$fail"
	exit 1
fi
printf '%d passed, 0 failed\n' "$pass"
