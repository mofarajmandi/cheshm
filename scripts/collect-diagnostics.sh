#!/usr/bin/env bash
#
# Read-only health snapshot for the Frigate box. Changes nothing, starts
# nothing, restarts nothing -- safe to run at any time, including while
# Frigate is broken.
#
#   ./scripts/collect-diagnostics.sh               # print to the terminal
#   ./scripts/collect-diagnostics.sh > /tmp/d.txt  # capture to a file
#
# Deliberately prints NO secrets: it reads .env only to learn which key names
# are set and to recover CAMERA_IP (needed to test reachability). Every value
# other than CAMERA_IP is masked, so the output is safe to paste into a chat.

set -uo pipefail  # no -e: a failing probe is a *result*, not a reason to stop

cd "$(dirname "$0")/.." || exit 1

section() { printf '\n========== %s ==========\n' "$1"; }
have()    { command -v "$1" >/dev/null 2>&1; }

section "WHEN / WHO"
date
echo "host: $(hostname)"
echo "uptime: $(uptime -p 2>/dev/null) (booted $(uptime -s 2>/dev/null))"

section "KERNEL"
# CLAUDE.md records 6.17.0-22-generic. A change here is the first thing to
# suspect if the GPU stopped working: the Nvidia module is built by DKMS, so a
# new kernel needs a successful rebuild before nvidia-smi works again.
uname -r
echo "--- kernels installed (newest last) ---"
ls -1v /boot/vmlinuz-* 2>/dev/null | sed 's|/boot/vmlinuz-||'

section "GPU / DKMS"
# If nvidia-smi fails, the Frigate container cannot start at all: compose
# reserves an nvidia device, so container *creation* fails, not just detection.
if have nvidia-smi; then
  nvidia-smi 2>&1 | head -20
else
  echo "nvidia-smi NOT FOUND"
fi
echo "--- dkms status ---"
if have dkms; then dkms status 2>&1; else echo "dkms not installed"; fi

section "MEMORY"
free -h

section "DISKS"
# Two failure modes to tell apart:
#  - /mnt/nvr full         -> Frigate cannot write new recordings
#  - /mnt/nvr NOT MOUNTED  -> /mnt/nvr is a bare dir on the OS disk and
#                             Frigate quietly fills the 209G root instead
df -h / /mnt/nvr 2>&1
echo "--- is /mnt/nvr actually a mount point? ---"
if mountpoint -q /mnt/nvr; then
  echo "YES - mounted:"
  findmnt -no SOURCE,FSTYPE,OPTIONS /mnt/nvr
else
  echo "*** NO - /mnt/nvr IS NOT MOUNTED. Anything written there is landing"
  echo "*** on the OS disk. This is the failure mode CLAUDE.md step 11 warns"
  echo "*** about. Do not start Frigate until this is fixed."
fi
echo "--- fstab entry ---"
grep -E 'nvr|f73bca0e' /etc/fstab 2>/dev/null || echo "(no /mnt/nvr line in /etc/fstab)"
echo "--- inode usage (a full inode table looks like a full disk to ffmpeg) ---"
df -ih / /mnt/nvr 2>&1

section "RECORDING FOOTPRINT"
# Answers runbook step 07 as a side effect: GB/day against the 11.75GB/day
# estimate. Also shows whether recordings simply STOPPED on some date.
if [ -d /mnt/nvr/recordings ]; then
  echo "--- size per day (newest last) ---"
  for d in $(ls -1 /mnt/nvr/recordings 2>/dev/null | sort | tail -10); do
    printf '%s  %s\n' "$d" "$(du -sh "/mnt/nvr/recordings/$d" 2>/dev/null | cut -f1)"
  done
  echo "--- newest recording file on disk (how stale is it?) ---"
  find /mnt/nvr/recordings -type f -name '*.mp4' -printf '%T+ %p\n' 2>/dev/null | sort | tail -3
else
  echo "/mnt/nvr/recordings does not exist"
fi

section "SMART / DISK ERRORS"
# The NVR partition lives on a 2018-era 2TB spinner shared with Windows.
if have smartctl; then
  sudo -n smartctl -H /dev/sda 2>&1 | tail -5
else
  echo "(smartctl not installed - skipping)"
fi
echo "--- recent I/O + filesystem + OOM errors in the kernel log ---"
{ sudo -n dmesg -T 2>/dev/null || dmesg -T 2>/dev/null; } \
  | grep -iE 'I/O error|ext4-fs error|remount.*read-only|Out of memory|oom-kill|nvidia' \
  | tail -20
echo "(if that printed nothing, there were no matching errors, or dmesg needs root)"

section "DOCKER"
have docker || echo "docker NOT FOUND"
echo -n "docker service active: "; systemctl is-active docker 2>&1
echo -n "docker service enabled: "; systemctl is-enabled docker 2>&1
echo "--- containers (all states) ---"
docker ps -a --format 'table {{.Names}}\t{{.State}}\t{{.Status}}\t{{.Image}}' 2>&1
echo "--- restart counts + exit codes (a climbing count means a crash loop) ---"
for c in frigate frigate-notify; do
  docker inspect "$c" --format '{{.Name}}: restarts={{.RestartCount}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} started={{.State.StartedAt}} finished={{.State.FinishedAt}} err={{.State.Error}}' 2>&1
done
echo "--- image digests actually running (compare against ghcr) ---"
for c in frigate frigate-notify; do
  docker inspect "$c" --format '{{.Name}}: {{.Config.Image}} -> {{.Image}}' 2>&1
done

section "FRIGATE LOGS (last 200 lines)"
docker logs frigate --tail 200 2>&1

section "FRIGATE-NOTIFY LOGS (last 40 lines)"
docker logs frigate-notify --tail 40 2>&1

section "FRIGATE API"
# 5000 is the internal/unauthenticated UI. If this answers, Frigate itself is
# alive and the problem is upstream of it (camera, network, disk).
curl -sS -m 5 -o /dev/null -w 'GET /api/version -> HTTP %{http_code}\n' http://127.0.0.1:5000/api/version 2>&1
echo -n 'version: '; curl -sS -m 5 http://127.0.0.1:5000/api/version 2>&1; echo
echo "--- per-camera stats (fps, detection fps, process states) ---"
curl -sS -m 5 http://127.0.0.1:5000/api/stats -o /tmp/frigate-stats.json 2>&1
python3 - /tmp/frigate-stats.json <<'PYEOF' 2>&1
import sys, json
try:
    with open(sys.argv[1]) as fh:
        s = json.load(fh)
except Exception as exc:
    print("  could not read /api/stats:", exc)
    raise SystemExit

for name, cam in (s.get("cameras") or {}).items():
    print("  camera {}: camera_fps={} process_fps={} detection_fps={} skipped_fps={} pid={}".format(
        name, cam.get("camera_fps"), cam.get("process_fps"),
        cam.get("detection_fps"), cam.get("skipped_fps"), cam.get("pid")))

for name, det in (s.get("detectors") or {}).items():
    print("  detector {}: inference_speed={}ms".format(name, det.get("inference_speed")))

svc = s.get("service") or {}
print("  frigate version:", svc.get("version"), " uptime(s):", svc.get("uptime"))
for mount, v in (svc.get("storage") or {}).items():
    print("  storage {}: used={}MB total={}MB".format(mount, v.get("used"), v.get("total")))
PYEOF
rm -f /tmp/frigate-stats.json

section "CAMERA REACHABILITY"
# Reads ONLY the camera IP out of .env. Everything else is masked.
CAM_IP=""
if [ -f .env ]; then
  echo "--- keys set in .env (values masked) ---"
  grep -vE '^[[:space:]]*#|^[[:space:]]*$' .env | sed -E 's/=.*/=<set>/'
  CAM_IP="$(grep -E '^CAMERA_IP=' .env | cut -d= -f2- | tr -d '\r' | tr -d "\"'" | xargs)"
else
  echo "*** .env NOT FOUND in $(pwd) -- Frigate would start with an empty"
  echo "*** camera IP and empty credentials."
fi

if [ -n "$CAM_IP" ]; then
  echo "CAMERA_IP in .env = $CAM_IP"
  echo "--- 20 pings (loss % and latency are the numbers that matter) ---"
  ping -c 20 -i 0.3 -W 2 "$CAM_IP" 2>&1 | tail -4
  echo "--- RTSP (554) and ONVIF (2020) reachable? ---"
  for p in 554 2020; do
    if timeout 4 bash -c "exec 3<>/dev/tcp/$CAM_IP/$p" 2>/dev/null; then
      echo "  port $p OPEN"
    else
      echo "  port $p CLOSED/unreachable"
    fi
  done
  echo "--- ARP entry for that address ---"
  ip neigh show "$CAM_IP" 2>&1
else
  echo "(no CAMERA_IP to test)"
fi

echo "--- other hosts answering on the LAN (has the camera taken a new IP?) ---"
ip neigh show 2>/dev/null | grep -vE 'FAILED|INCOMPLETE' | head -20

section "NETWORK / TAILSCALE"
ip -4 -brief addr show 2>&1 | grep -vE '^lo'
if have tailscale; then tailscale status 2>&1 | head -5; else echo "tailscale CLI not found"; fi

section "GIT STATE OF THIS REPO"
git log --oneline -3 2>&1
git status --short 2>&1
echo "(a dirty tree here means local edits that were never committed)"

printf '\n========== END ==========\n'
