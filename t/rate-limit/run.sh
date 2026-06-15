#!/bin/bash
# Wrapper for the rate-limit regression suite.
# Validates env, runs orphan reaper, then invokes prove.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

REQUIRED=(TN_HOST TN_API_KEY STORAGE_ID)
missing=0
for v in "${REQUIRED[@]}"; do
    if [[ -z "${!v:-}" ]]; then
        echo "ERROR: required env var $v not set" >&2
        missing=1
    fi
done
[[ $missing -eq 1 ]] && {
    echo
    echo "See t/rate-limit/README.md for setup." >&2
    exit 2
}

: "${TEST_VMID_BASE:=99000}"
: "${DRAIN_SECS:=90}"
: "${KEEP_RESOURCES:=0}"

export TN_HOST TN_API_KEY STORAGE_ID TEST_VMID_BASE DRAIN_SECS KEEP_RESOURCES
export TN_LOGIN_COUNT_METHOD="${TN_LOGIN_COUNT_METHOD:-audit}"

echo "=== rate-limit suite ==="
echo "TN_HOST=$TN_HOST"
echo "STORAGE_ID=$STORAGE_ID"
echo "TEST_VMID_BASE=$TEST_VMID_BASE  (range: $TEST_VMID_BASE..$((TEST_VMID_BASE+99)))"
echo "DRAIN_SECS=$DRAIN_SECS"
echo "TN_LOGIN_COUNT_METHOD=$TN_LOGIN_COUNT_METHOD"
echo

echo "--- pre-suite orphan reaper ---"
perl -I"$SCRIPT_DIR/lib" -MRateLimit::Harness=reap_orphans -e '
    my $n = RateLimit::Harness::reap_orphans();
    print "reaped $n orphan(s)\n";
' || {
    echo "ERROR: orphan reaper failed; aborting suite" >&2
    exit 3
}
echo

echo "--- prove ---"
cd "$REPO_ROOT"
exec prove -v -I"$SCRIPT_DIR/lib" "$SCRIPT_DIR"/0*.t
