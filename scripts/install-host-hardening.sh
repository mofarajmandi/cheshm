#!/usr/bin/env bash
#
# Installs the host-side half of runbook step 11, item 3: make /mnt/nvr fail
# safe instead of failing silently or failing the whole boot.
#
# Three things, all idempotent:
#   1. Add `nofail` (+ a mount timeout) to the /mnt/nvr line in /etc/fstab, so
#      a missing disk cannot drop a headless box into emergency mode.
#   2. Install the RequiresMountsFor= drop-in for docker.service, so Docker --
#      and therefore Frigate -- will not start onto an unmounted /mnt/nvr.
#   3. Create the /mnt/nvr/.nvr-disk sentinel that the nvr-mount-guard service
#      in docker-compose.yml tests for.
#
#   ./scripts/install-host-hardening.sh           # DRY RUN: show the changes
#   sudo ./scripts/install-host-hardening.sh --apply
#
# Dry run is the default on purpose: this edits /etc/fstab, and a bad fstab is
# one of the few ways to make this machine genuinely hard to recover.

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

MOUNT=/mnt/nvr
SENTINEL="$MOUNT/.nvr-disk"
DROPIN_SRC="host/docker.service.d/10-require-nvr-mount.conf"
DROPIN_DIR=/etc/systemd/system/docker.service.d
DROPIN_DST="$DROPIN_DIR/10-require-nvr-mount.conf"

say()  { printf '\n>>> %s\n' "$1"; }
note() { printf '    %s\n' "$1"; }

if [ "$APPLY" -eq 1 ] && [ "$(id -u)" -ne 0 ]; then
  echo "--apply needs root: sudo $0 --apply" >&2
  exit 1
fi

[ "$APPLY" -eq 0 ] && say "DRY RUN -- nothing will be changed. Re-run with --apply to commit."

# --------------------------------------------------------------------------
say "1. /etc/fstab"

FSTAB_MATCHES="$(grep -cE "^[^#].*[[:space:]]${MOUNT}[[:space:]]" /etc/fstab || true)"
FSTAB_LINE="$(grep -nE "^[^#].*[[:space:]]${MOUNT}[[:space:]]" /etc/fstab | head -1 || true)"

if [ "${FSTAB_MATCHES:-0}" -gt 1 ]; then
  note "REFUSING: found $FSTAB_MATCHES active $MOUNT lines in /etc/fstab."
  note "Two entries for one mount point is already a bug, and editing the"
  note "wrong one would make it worse. Resolve that by hand first:"
  grep -nE "^[^#].*[[:space:]]${MOUNT}[[:space:]]" /etc/fstab | sed 's/^/      /'
  exit 1
fi

if [ -z "$FSTAB_LINE" ]; then
  note "No active $MOUNT line found in /etc/fstab. Nothing to edit here."
  note "That is itself a problem -- $MOUNT would not mount at boot at all."
  note "Add one before continuing; the UUID is in CLAUDE.md."
elif echo "$FSTAB_LINE" | grep -q 'nofail'; then
  note "Already has nofail:"
  note "  ${FSTAB_LINE}"
else
  LINENO_="${FSTAB_LINE%%:*}"
  OLD="${FSTAB_LINE#*:}"
  # Append to the options field (column 4), leaving every other column alone.
  NEW="$(echo "$OLD" | awk '{
    if (NF >= 4) { $4 = $4 ",nofail,x-systemd.device-timeout=30" }
    print
  }' OFS='\t')"
  note "line $LINENO_ changes from:"
  note "  $OLD"
  note "to:"
  note "  $NEW"
  note ""
  note "nofail: a missing disk no longer blocks boot."
  note "x-systemd.device-timeout=30: wait 30s for the spinner to appear,"
  note "  then give up, rather than hanging boot for the default 90s."

  if [ "$APPLY" -eq 1 ]; then
    BACKUP="/etc/fstab.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a /etc/fstab "$BACKUP"
    note "backed up /etc/fstab -> $BACKUP"
    # Rewrite just that line number.
    awk -v n="$LINENO_" -v repl="$NEW" 'NR==n { print repl; next } { print }' \
      "$BACKUP" > /etc/fstab.new
    mv /etc/fstab.new /etc/fstab
    note "written."
    # Verify the result actually parses before we walk away from it.
    if findmnt --verify --fstab >/dev/null 2>&1; then
      note "findmnt --verify: OK"
    else
      note "findmnt --verify reported problems -- review below, restore with:"
      note "  sudo cp $BACKUP /etc/fstab"
      findmnt --verify --fstab || true
    fi
  fi
fi

# --------------------------------------------------------------------------
say "2. docker.service drop-in ($DROPIN_DST)"

if [ ! -f "$DROPIN_SRC" ]; then
  echo "    missing $DROPIN_SRC -- run this from a full checkout." >&2
  exit 1
fi

if [ -f "$DROPIN_DST" ] && cmp -s "$DROPIN_SRC" "$DROPIN_DST"; then
  note "Already installed and identical."
else
  note "Will install $DROPIN_SRC -> $DROPIN_DST"
  note "Effect: Docker will not start until $MOUNT is mounted."
  if [ "$APPLY" -eq 1 ]; then
    install -d -m 0755 "$DROPIN_DIR"
    install -m 0644 "$DROPIN_SRC" "$DROPIN_DST"
    systemctl daemon-reload
    note "installed, daemon-reload done."
    note "Takes effect on the next docker.service start (or reboot)."
  fi
fi

# --------------------------------------------------------------------------
say "3. mount sentinel ($SENTINEL)"

# This is the check that makes the guard meaningful, so it is worth being
# strict: writing the sentinel while the disk is unmounted would put it on the
# OS disk, where it would be found on every future boot and would silently
# certify the exact condition it exists to detect.
if ! mountpoint -q "$MOUNT"; then
  note "REFUSING: $MOUNT is not currently a mount point."
  note "Writing the sentinel now would place it on the OS disk and"
  note "permanently defeat the guard. Mount the NVR partition first:"
  note "  sudo mount $MOUNT && mountpoint $MOUNT"
  note "then re-run this script."
elif [ -f "$SENTINEL" ]; then
  note "Already present on the mounted partition."
else
  note "Will create $SENTINEL on the mounted NVR partition."
  if [ "$APPLY" -eq 1 ]; then
    printf '%s\n' \
      "Sentinel for docker-compose.yml's nvr-mount-guard service." \
      "Its presence proves /mnt/nvr is the real NVR partition and not an" \
      "empty mountpoint on the OS disk. Do not delete." \
      "Created $(date -Is) by scripts/install-host-hardening.sh" > "$SENTINEL"
    note "created."
  fi
fi

# --------------------------------------------------------------------------
if [ "$APPLY" -eq 1 ]; then
  say "Done. Verify without rebooting:"
  note "sudo findmnt --verify --fstab"
  note "systemctl show docker.service -p RequiresMountsFor"
  note "docker compose up -d   # the guard should pass and Frigate should start"
  say "Then verify for real by cutting power at the wall, per runbook step 11."
else
  say "Dry run complete. Re-run with: sudo $0 --apply"
fi
