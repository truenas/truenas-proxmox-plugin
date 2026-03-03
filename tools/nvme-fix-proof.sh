#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <DEVICE_UUID> [STORAGE_ID] [WAIT_SECONDS]"
  exit 1
fi

DEVICE_UUID="$1"
STORAGE_ID="${2:-}"
WAIT_SECONDS="${3:-20}"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run as root on the affected Proxmox node."
  exit 1
fi

for cmd in perl nvme awk tr; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $cmd"
    exit 1
  }
done

norm_guid() {
  local s="${1:-}"
  s="${s,,}"
  s="${s//-/}"
  echo "$s"
}

is_all_zero_guid() {
  local n
  n="$(norm_guid "${1:-}")"
  [[ -n "$n" && "$n" =~ ^0+$ ]]
}

find_storage_for_uuid() {
  local uuid="$1"
  perl -e '
use strict; use warnings;
use lib "/usr/share/perl5";
use PVE::Storage;
use PVE::Storage::Custom::TrueNASPlugin;

my $uuid = $ARGV[0];
my $cfg = PVE::Storage::config();

for my $id (sort keys %{$cfg->{ids}}) {
  my $scfg = $cfg->{ids}{$id};
  next unless ($scfg->{type} // q()) eq q(truenasplugin);
  next unless ($scfg->{transport_mode} // q(iscsi)) eq q(nvme-tcp);

  my $ok = eval {
    my $r = PVE::Storage::Custom::TrueNASPlugin::_api_call(
      $scfg,
      q(nvmet.namespace.query),
      [[[q(device_uuid), q(=), $uuid]]]
    );
    if ($r && ref($r) eq q(ARRAY) && scalar(@$r) > 0) {
      print "$id\n";
      exit 0;
    }
    1;
  };

  # Ignore storage-specific API errors and keep searching.
}

exit 1;
' "$uuid"
}

echo "=== NVMe Fix Proof Script ==="
echo "Device UUID  : $DEVICE_UUID"
echo "Wait seconds : $WAIT_SECONDS"

if [[ -z "$STORAGE_ID" ]]; then
  echo "Storage ID   : auto-detect"
  if ! STORAGE_ID="$(find_storage_for_uuid "$DEVICE_UUID")"; then
    echo
    echo "RESULT: UUID not found on any local nvme-tcp truenasplugin storage."
    echo "This host cannot prove mapping behavior for that UUID."
    exit 2
  fi
fi

echo "Storage ID   : $STORAGE_ID"
echo

echo "== 1) Read storage config from Proxmox =="
CFG_OUT="$(perl -e '
use strict; use warnings;
use lib "/usr/share/perl5";
use PVE::Storage;
my $sid = $ARGV[0];
my $cfg = PVE::Storage::config();
my $scfg = $cfg->{ids}{$sid} or die "Storage not found: $sid\n";
print "TRANSPORT_MODE=",($scfg->{transport_mode}//"iscsi"),"\n";
print "SUBSYSTEM_NQN=",($scfg->{subsystem_nqn}//""),"\n";
print "DISCOVERY_PORTAL=",($scfg->{discovery_portal}//""),"\n";
print "API_HOST=",($scfg->{api_host}//""),"\n";
' "$STORAGE_ID")"

echo "$CFG_OUT"

TRANSPORT_MODE="$(echo "$CFG_OUT" | awk -F= '/^TRANSPORT_MODE=/{print $2}')"
SUBSYSTEM_NQN="$(echo "$CFG_OUT" | awk -F= '/^SUBSYSTEM_NQN=/{print $2}')"

if [[ "$TRANSPORT_MODE" != "nvme-tcp" ]]; then
  echo "ERROR: storage '$STORAGE_ID' is not nvme-tcp (got '$TRANSPORT_MODE')."
  exit 1
fi

if [[ -z "$SUBSYSTEM_NQN" ]]; then
  echo "ERROR: subsystem_nqn is missing in storage '$STORAGE_ID'."
  exit 1
fi

echo
echo "== 2) Check subsystem connectivity =="
if nvme list-subsys | grep -qF "$SUBSYSTEM_NQN"; then
  echo "OK: subsystem NQN appears in nvme list-subsys"
else
  echo "WARN: subsystem NQN not visible in nvme list-subsys"
fi

echo
echo "== 3) Query TrueNAS namespace metadata via plugin API =="
API_OUT="$(perl -e '
use strict; use warnings;
use lib "/usr/share/perl5";
use PVE::Storage;
use PVE::Storage::Custom::TrueNASPlugin;

my ($sid, $uuid) = @ARGV;
my $cfg = PVE::Storage::config();
my $scfg = $cfg->{ids}{$sid} or die "Storage not found: $sid\n";

my $res = eval {
  PVE::Storage::Custom::TrueNASPlugin::_api_call(
    $scfg,
    "nvmet.namespace.query",
    [[["device_uuid", "=", $uuid]]]
  );
};

if ($@) {
  my $e = $@;
  $e =~ s/\n/ /g;
  print "API_ERROR=1\n";
  print "API_ERROR_MSG=$e\n";
  exit 0;
}

if (!$res || ref($res) ne "ARRAY" || scalar(@$res) == 0) {
  print "API_FOUND=0\n";
  exit 0;
}

my $ns = $res->[0];
print "API_FOUND=1\n";
print "API_NSID=",($ns->{nsid}//""),"\n";
print "API_NGUID=",($ns->{device_nguid}//""),"\n";
print "API_DEVICE_PATH=",($ns->{device_path}//""),"\n";
' "$STORAGE_ID" "$DEVICE_UUID")"

echo "$API_OUT"

API_FOUND="$(echo "$API_OUT" | awk -F= '/^API_FOUND=/{print $2}' | tail -n 1)"
API_NSID="$(echo "$API_OUT" | awk -F= '/^API_NSID=/{print $2}' | tail -n 1)"
API_NGUID="$(echo "$API_OUT" | awk -F= '/^API_NGUID=/{print $2}' | tail -n 1)"
API_ERROR="$(echo "$API_OUT" | awk -F= '/^API_ERROR=/{print $2}' | tail -n 1)"

if [[ "${API_ERROR:-0}" == "1" ]]; then
  echo
  echo "RESULT: API query failed; cannot prove UUID matching until API path is stable."
  exit 2
fi

if [[ "${API_FOUND:-0}" != "1" ]]; then
  echo
  echo "RESULT: TrueNAS has no namespace for this UUID on storage '$STORAGE_ID'."
  echo "This is not a Linux matching race for this host/storage."
  exit 2
fi

if is_all_zero_guid "$API_NGUID"; then
  echo "WARN: API_NGUID is all-zero/unusable; NGUID-first matching is expected to fail."
fi

echo
echo "== 4) Observe Linux namespace devices over time =="
echo "Target subsystem NQN: $SUBSYSTEM_NQN"

API_NGUID_NORM="$(norm_guid "$API_NGUID")"

first_seen_t=-1
raw_match_t=-1
norm_match_t=-1
nsid_match_t=-1

for ((t=0; t<=WAIT_SECONDS; t++)); do
  mapfile -t CANDIDATES < <(
    for p in /sys/block/nvme*n* /sys/block/nvme*c*n*; do
      [[ -e "$p" ]] || continue
      d="$(basename "$p")"

      dev_nqn=""
      if [[ -r "/sys/block/$d/device/subsysnqn" ]]; then
        dev_nqn="$(tr -d '\n' < "/sys/block/$d/device/subsysnqn" || true)"
      elif [[ -r "/sys/block/$d/device/../subsysnqn" ]]; then
        dev_nqn="$(tr -d '\n' < "/sys/block/$d/device/../subsysnqn" || true)"
      fi
      [[ "$dev_nqn" == "$SUBSYSTEM_NQN" ]] || continue

      nsid="$(tr -d '\n' < "/sys/block/$d/nsid" 2>/dev/null || true)"
      nguid="$(tr -d '\n' < "/sys/block/$d/nguid" 2>/dev/null || true)"
      echo "$d|$nsid|$nguid"
    done
  )

  if [[ ${#CANDIDATES[@]} -gt 0 && $first_seen_t -lt 0 ]]; then
    first_seen_t=$t
  fi

  for row in "${CANDIDATES[@]}"; do
    IFS='|' read -r dev nsid nguid <<<"$row"

    if [[ -n "$API_NGUID" && -n "$nguid" && "$nguid" == "$API_NGUID" && $raw_match_t -lt 0 ]]; then
      raw_match_t=$t
    fi

    if [[ -n "$API_NGUID_NORM" && -n "$nguid" ]]; then
      if [[ "$(norm_guid "$nguid")" == "$API_NGUID_NORM" && $norm_match_t -lt 0 ]]; then
        norm_match_t=$t
      fi
    fi

    if [[ -n "$API_NSID" && -n "$nsid" && "$nsid" == "$API_NSID" && $nsid_match_t -lt 0 ]]; then
      nsid_match_t=$t
    fi
  done

  if [[ $norm_match_t -ge 0 || $nsid_match_t -ge 0 ]]; then
    break
  fi

  sleep 1
done

echo
echo "== 5) Results =="
echo "First Linux candidate seen at     : ${first_seen_t}s"
echo "Raw NGUID match at                : ${raw_match_t}s"
echo "Normalized NGUID match at         : ${norm_match_t}s"
echo "NSID match at                     : ${nsid_match_t}s"

echo
echo "== 6) Verdict =="
if [[ $norm_match_t -ge 0 && $raw_match_t -lt 0 ]]; then
  echo "LIKELY FIXED by NGUID normalization."
  exit 0
fi

if [[ $raw_match_t -gt 5 || $norm_match_t -gt 5 || $nsid_match_t -gt 5 ]]; then
  echo "LIKELY FIXED by extending wait/retry window beyond 5 seconds."
  exit 0
fi

if [[ $raw_match_t -ge 0 || $norm_match_t -ge 0 || $nsid_match_t -ge 0 ]]; then
  echo "MATCH FOUND within current window; mapping works for this UUID now."
  exit 0
fi

echo "NO MATCH FOUND; normalization/wait fix alone is likely insufficient."
echo "Investigate connectivity/auth, stale controllers, or namespace publication state."
exit 3
