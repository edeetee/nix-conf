# Audio on homeserver-edt

## Stack

```
Game/App → Wine → winepulse.drv → pipewire-pulse → PipeWire → ALSA → HDMI → TV
                                    ↑                              ↑
                              PULSE_LATENCY_MSEC              rtkit (RT priority)
```

- **PipeWire 1.6** with pipewire-pulse (PulseAudio compatibility)
- **rtkit** grants realtime scheduling (without it, pipewire falls back to priority 1 — causes popping under load)
- **Wine/Proton** uses `winepulse.drv` to bridge Windows audio to PulseAudio

## The latency problem

Wine's PulseAudio driver defaults to huge buffers:

| Setting | Default | Effect |
|---------|---------|--------|
| `tlength` | 9600 samples (200ms) | Audio lags ~200ms behind video |
| `minreq` | 3840 samples (80ms) | Minimum chunk size — coarse-grained delivery |

This causes noticeable lip-sync issues in games and video.

## The fix

Three layers, each addressing a different part of the stack:

### 1. rtkit — realtime scheduling (`desktop.nix`)

```nix
security.rtkit.enable = true;
```

Without this, pipewire runs at priority 1 instead of realtime priority 88, and
CPU-intensive processes (games, transcoding, rendering) starve the audio thread
→ crackling, popping, dropouts.

### 2. PipeWire quantum and pulse latency (`desktop.nix`)

```nix
services.pipewire = {
  enable = true;
  audio.enable = true;
  pulse.enable = true;
  extraConfig.pipewire = {
    "92-low-latency" = {
      "context.properties" = {
        "default.clock.quantum" = 256;       # 5.3ms (default: 1024 = 21ms)
        "default.clock.min-quantum" = 32;
        "default.clock.max-quantum" = 1024;
      };
    };
  };
  extraConfig.pipewire-pulse = {
    "92-low-latency" = {
      "pulse.properties" = {
        "pulse.min.req" = "128/48000";       # ~2.7ms minimum request
        "pulse.min.quantum" = "128/48000";
      };
    };
  };
};
```

| Setting | Before | After | What it does |
|---------|--------|-------|-------------|
| `clock.quantum` | 1024 (21ms) | 256 (5.3ms) | How often PipeWire processes audio |
| `pulse.min.req` | unset | 128/48000 | Prevents clients requesting huge chunks |

**Runtime tuning:** If 256 quantum causes popping under heavy GPU load (games),
bump to 512:

```bash
pw-metadata -n settings 0 clock.quantum 512
```

This change is temporary (lost on pipewire restart). Make it permanent by
changing the value in `desktop.nix` and rebuilding.

### 3. Wine/PulseAudio buffer sizes (`steam-on-demand` drop-in)

Wine's mmdevapi layer enforces a minimum default period of **10ms**
([source](https://github.com/wine-mirror/wine/blob/master/dlls/mmdevapi/client.c)):

```c
static const REFERENCE_TIME min_def_period = 100000; /* 10 ms */
```

`winepulse.drv` then calculates buffer sizes as `tlength = minreq × 3`
([source](https://github.com/wine-mirror/wine/blob/master/dlls/winepulse.drv/pulse.c)):

```c
attr.minreq = attr.fragsize = period_bytes;
attr.tlength = period_bytes * 3;
```

With `PULSE_LATENCY_MSEC=10` (at the floor), this gives:

| Attribute | Samples | Real time |
|-----------|---------|-----------|
| `minreq` | 2048 | 43ms |
| `tlength` | 6144 | 128ms |

Without the env var, these default to 3840 (80ms) / 11520 (240ms).

The env var is injected via a systemd drop-in for the `steam-on-demand` service
at `~/.config/systemd/user/steam-on-demand.service.d/audio-latency.conf`:

```ini
[Service]
Environment="PULSE_LATENCY_MSEC=10"
```

## Verification

```bash
# Check quantum (should be 256 or 512)
pw-metadata -n settings | grep quantum

# Check for errors (ERR column should be all zeros)
pw-top -b -n 1

# Check Wine stream buffer sizes (launch a game first)
for id in $(pw-cli list-objects | grep -o "id [0-9]*, type PipeWire:Interface:Node" | grep -o "[0-9]*"); do
  bin=$(pw-cli info $id | grep "wine64")
  if [ -n "$bin" ]; then
    pw-cli info $id | grep -E "pulse\.attr|latency|media\.name"
  fi
done

# Check rtkit is granting RT priority
journalctl -u rtkit-daemon --no-pager -n 5

# Check Steam has the env var
cat /proc/$(pgrep -f steam | head -1)/environ | tr '\0' '\n' | grep PULSE
```

## Known limitations

- Wine's 10ms mmdevapi floor means `PULSE_LATENCY_MSEC` values below 10 have no
  effect. pipewire-pulse adds its own cap around 43ms minreq. Total end-to-end
  latency floor is ~54ms (43ms Wine + 11ms PipeWire at quantum 512).
- The pipewire-pulse `pulse.min.*` config only takes effect after a NixOS
  rebuild and pipewire restart.
- PipeWire quantum changes via `pw-metadata` are lost on daemon restart.
  Permanent changes go in `desktop.nix`.
