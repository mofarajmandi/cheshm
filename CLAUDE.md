# Frigate NVR Project

Standalone Frigate NVR setup on a home Ubuntu box, starting with one Tapo C211
indoor pan/tilt camera. Following the "Sentry Runbook" ten-step build plan.

## Host

- Ubuntu 24.04.1 LTS, kernel 6.17.0-22-generic
- CPU: Intel Core i7-7700 @ 3.60GHz (4c/8t) — no usable Intel iGPU (not visible
  on the PCI bus at all, likely disabled in BIOS since a discrete GPU is
  installed). If the Nvidia GPU has to be abandoned, the fallback detector is
  CPU-only, not OpenVINO, unless the iGPU is re-enabled in BIOS.
- RAM: 15GiB
- GPU: NVIDIA GeForce GTX 1070, 8GB VRAM (Pascal). Driver 580.173.02 via
  nvidia-dkms-550 (the apt-provided prebuilt kernel module didn't exist for
  this kernel version, so DKMS builds it from source — this should
  auto-rebuild on future kernel upgrades via DKMS's kernel hook, but if
  `nvidia-smi` ever breaks after a kernel update, check `dkms status` first).
  Confirmed working both on the host and passed through into Docker
  containers (`docker run --gpus all ...`).
- Docker 27.4.0 + Compose plugin v2.31.0. nvidia-container-toolkit confirmed
  working.
- Network: wired `enp3s0` (192.168.68.130/24) and wifi `wlp4s0`, both on the
  192.168.68.0/24 LAN. Tailscale already installed and connected
  (100.104.115.71) — use this for remote access, never port-forward Frigate.

## Storage

- `/mnt/nvr` — dedicated ext4 partition, `/dev/sda3`, 442G (UUID
  `f73bca0e-0782-40b2-bbbf-e4b4a568489c`), mounted via `/etc/fstab`, owned by
  `mamad`. This is where Frigate recordings live.
- This partition was carved out of a 1.4TB leftover partition (originally an
  old Ubuntu install's `/home` from 2018/2019) on the same physical 2TB HDD
  (`ST2000DM001`, `/dev/sda`) that also holds the Windows partitions, the EFI
  partition, and the current Ubuntu root (`/`). Only `sda3`'s end boundary was
  moved — `sda4` (EFI) and `sda5` (root) are untouched.
- ~940GB of that HDD is left unallocated on purpose, deliberately not given to
  this project, for other future use.
- The old home directory's data (14GB — mostly `Downloads` and old CUDA 10.0
  samples, nothing that looked important) was backed up to
  `~/old-home-2019-backup` before the partition was reformatted. Safe to
  delete once reviewed.
- Measured storage math (Step 03): main stream (what gets recorded) runs
  ~1.09Mbps -> ~11.75GB/day/camera continuous. A 7-day continuous window for
  3 cameras (the eventual plan) is only ~245GB, comfortably inside the 420GB
  free here even before accounting for the smaller motion/alert tiers.

## Camera

- One TP-Link Tapo C211, indoor pan/tilt. Firmware `1.2.7 Build 260818
  Rel.64715n`, serial `7461f574`. Unboxed and on the network (Step 02 done).
- RTSP on port 554: `/stream1` (main, 2304x1296, ~15fps, ~1.09Mbps incl.
  audio) and `/stream2` (sub, 1280x720, ~15fps, ~190kbps incl. audio). Both
  H.264 + PCM A-law audio. A third profile, `jpegStream` (640x360), also
  exists via ONVIF media profiles but isn't used by the plan.
- ONVIF on port 2020. Confirmed working: device info, media profiles, and PTZ
  all respond correctly. `onvif-zeep` needs a monkey-patch for a
  known `AnySimpleType.pytonvalue()` incompatibility with modern `zeep` --
  see `scripts/onvif_ptz_test.py`.
- **PTZ confirmed working** (Step 04 done) -- `ContinuousMove` physically
  pans the camera. Note: the PTZ node only exposes *generic* (normalized)
  velocity/position/translation spaces, not the FOV-calibrated
  `TranslationSpaceFov` space that Frigate's autotracking feature relies on.
  Not a blocker here since the plan uses a static home preset + fixed zones,
  not autotracking.
- Credentials are the camera's own "Camera Account" (set in the Tapo app),
  not the TP-Link cloud login. Stored in `.env`, never in chat or in the repo.

## Frigate / detector (Step 06 -- settled)

- Frigate 0.18.0, image `ghcr.io/blakeblackshear/frigate:stable-tensorrt`.
- Detector: `onnx` type, running on the GPU via onnxruntime's CUDA/TensorRT
  execution provider. **Not** the `tensorrt` detector type -- that plugin was
  removed for amd64 in 0.18 ("no longer supported on amd64, use ONNX
  instead"); it still exists in the docs because it's still used on Jetson.
- Model: YOLOv9-s at 320x320, exported to ONNX manually. On amd64 there is no
  more automatic `YOLO_MODELS`-driven download/convert-at-startup for the
  onnx path -- you have to export the model yourself and place it at
  `config/model_cache/yolo.onnx`. The export command is saved at
  `scripts/yolov9-export.Dockerfile`; run it with:
  `docker build . -f scripts/yolov9-export.Dockerfile --build-arg MODEL_SIZE=s --build-arg IMG_SIZE=320 --output .`
  then move the resulting `yolov9-s-320.onnx` to `config/model_cache/yolo.onnx`.
  Note: `config/model_cache/` ends up owned by `root` (Frigate's container
  creates it), so `sudo chown mamad:mamad config/model_cache` before moving
  the file in.
- **Confirmed stable**: ~12.3-12.5ms inference speed, ~10% detector CPU,
  ~5% GPU usage, no CUDA errors over 90 minutes of continuous running. Pascal
  is not a problem for this GPU/model/image combination.
- `config/model_cache/` is gitignored (regenerable via the Dockerfile above,
  no need to commit a 28MB binary).

## Decisions already made

- Standalone Frigate, no Home Assistant.
- Detect on the sub stream, record the main stream with no re-encode.
- Retention: continuous 7 days, motion 30 days, alerts 60 days.
- Alerts via Telegram, using the `frigate-notify` container.
- Camera's Motion Tracking feature stays off — zones are drawn once against a
  static framing (a saved "home" preset).

## Conventions

- Every config change is a git commit, with a message that says what changed
  and why.
- Secrets only ever go in `.env`, never committed, never in a Frigate URL
  (Telegram renders credentialed links unclickable anyway).
- Never expose Frigate to the internet. Tailscale (already set up) or
  WireGuard only.

## Future / open items

- **OpenVINO fallback — investigate before assuming it's unavailable.** No
  Intel iGPU currently shows up in `lspci` at all (likely disabled in BIOS,
  not physically absent — this is a Kaby Lake/LGA1151 board, which commonly
  supports running the iGPU alongside a discrete GPU via a BIOS setting like
  "iGPU Multi-Monitor" or "Primary Display: Auto/IGPU/PEG"). Step 06 is
  settled and the GTX 1070 is stable, so this is now a **contingency only** --
  two things to check if the GPU ever becomes unreliable:
  1. Check BIOS for that setting — if enabled, the iGPU should reappear in
     `lspci` and become usable as Frigate's OpenVINO GPU device.
  2. Independent of the iGPU: OpenVINO's CPU backend is a distinct option
     from Frigate's default plain-CPU (tflite) detector and is typically
     faster. Worth benchmarking against the GTX 1070's numbers in Step 06
     rather than treating "no iGPU" as "no OpenVINO."

## Notifications (Step 09 -- working)

- `frigate-notify` (separate container, `ghcr.io/0x2142/frigate-notify`)
  polls Frigate's **REST API** every 30s -- MQTT is not needed and stays
  disabled.
- Config lives in `frigate-notify/config.yml`, deliberately its own directory
  rather than `config/` (which is gitignore-whitelisted to Frigate's own
  `config.yml`, since Frigate dumps runtime state and secrets there).
- **No secrets in that file.** They're injected as `FN_`-prefixed env vars in
  docker-compose.yml; frigate-notify maps `FN_A__B__C` -> `a.b.c` (double
  underscore per level of nesting).
- It authenticates to Frigate with **Frigate's own admin login**
  (`FRIGATE_ADMIN_USER` / `FRIGATE_ADMIN_PASSWORD` in `.env`) -- a completely
  different credential from the camera's Camera Account. Easy to confuse.
- `app.mode: reviews` + `notify_detections: false` means only Frigate's
  *alert*-severity review items reach Telegram, not plain detections.
- It de-duplicates per zone, so a single ongoing event notifies once rather
  than on every poll. With no zones drawn yet the zone is empty; revisit the
  zone filters in `frigate-notify/config.yml` once Step 08 lands.

## Boot & power resilience (Step 11 -- pending)

Hardware context: this box is an **OMEN by HP Desktop PC 880-p0xx** (HP board
8307, BIOS F.05 / 2017-07-03).

Audited 2026-09-13, already correct:

- `docker`, `containerd`, `tailscaled` are all `enabled` at boot and active.
- Both containers use `restart: unless-stopped`. Note this deliberately does
  *not* restart containers stopped by hand -- correct behaviour here, but not
  the same as `always`.
- `/mnt/nvr` has an `/etc/fstab` entry, so it mounts at boot.
- Tailscale auth state persists across reboots; the camera reconnecting is
  self-healing since Frigate retries ffmpeg indefinitely, so boot ordering
  between router, camera and server doesn't matter.

Still to do:

1. **BIOS: power on after AC loss.** Consumer desktops often default to
   staying off when mains power returns. Look for "After Power Loss" /
   "AC Power Recovery" and set to *Power On*. Not settable from Linux.
   Do this in the same BIOS trip as the iGPU check in "Future / open items".
2. **Disable Tailscale key expiry** for this node (currently expires
   **2027-03-08**). When it lapses, the box drops off the tailnet and remote
   access dies with no obvious cause. Admin console -> Machines -> `mamadml`.
3. **Harden the `/mnt/nvr` mount.** Current entry uses `defaults`, so a disk
   that fails to mount can drop the boot into emergency mode -- unreachable
   even over Tailscale. But bare `nofail` is worse in a subtler way: the host
   boots, `/mnt/nvr` is an empty dir on the OS disk (~110GB), and Frigate
   records onto it until full. Do both: `nofail` in fstab, *plus*
   `RequiresMountsFor=/mnt/nvr` on `docker.service` (via `systemctl edit`) so
   the host boots reachable but Frigate won't start degraded.
4. **UPS** -- none attached. Optional; protects against unclean shutdown
   mid-write, which is the main threat to already-recorded footage.

Then verify for real: cut power at the wall (not `sudo reboot` -- a clean
shutdown exercises none of the interesting failure modes) and confirm live
view, a mounted and growing `/mnt/nvr`, and a Telegram alert all come back
with no keyboard involved.

## Runbook checklist

- [x] 01. Survey the Ubuntu box (Docker confirmed, `/mnt/nvr` mounted, GPU
      passthrough confirmed working)
- [x] 02. Camera out of the box — all app work (by hand)
- [x] 03. Prove the streams before Frigate exists
- [x] 04. Prove ONVIF pan/tilt (camera physically moved via ContinuousMove)
- [x] 05. Frigate up, detection only, no recording
- [x] 06. Settle the detector (onnx + GPU, ~12.4ms, stable 90min)
- [ ] 07. Turn on recording and let it run a day -- **in progress**, started
      2026-09-13 14:38. Recording confirmed landing on `/mnt/nvr` correctly.
      Check back after 24h: scrub through yesterday's footage in the UI, and
      confirm measured GB/day is within ~20% of the ~11.75GB/day estimate.
- [ ] 08. Home preset, then zones
- [x] 09. Telegram (alerts confirmed arriving; zone filtering still to come
      with Step 08)
- [ ] 10. Tune for a week, then scale
- [ ] 11. Make it survive the power going out — see "Boot & power resilience"
      below
