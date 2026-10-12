# AirPlay on sink-pi

`sink-pi` shows up in the iPhone's AirPlay output picker and plays through the same
3.5 mm jack the instrument uses. Enabled in `hosts/sink-pi/default.nix`:

```nix
services.airplay = {
  enable = true;
  desktop = false;          # no session on this box
  outputDevice = "hw:0,0";  # the card the synth opens
};
```

The module is `modules/nixos/airplay.nix`, shared with `homeserver-edt` — which runs
it in the opposite shape (`desktop = true`, inside Plasma, output to the session's
PipeWire). This file is what is true of the *headless* shape on this hardware;
`hosts/homeserver-edt/AIRPLAY.md` is the desktop story and the troubleshooting
reference for the clients themselves.

## The headless shape

Upstream recommends exactly this and nothing else on a box like this one:

> An ideal system would be a bare Linux system without a GUI and without PipeWire or
> PulseAudio … In this case, Shairport Sync connects directly to the ALSA output DAC.
> — `AIRPLAY2.md`

So `desktop = false` gives: the NixOS shairport-sync module's **system** unit (running
as its `shairport` user, which the module already puts in the `audio` group),
`output_backend = "alsa"`, `alsa.output_device = "hw:0,0"`, ordered `after` and
`wants` `nqptp.service` because shairport-sync exits if nqptp's shared memory is not
there within ten seconds of it starting. No user units, no Qt, no UxPlay — the
now-playing window and screen mirroring need a session, so they are `mkDefault`ed off
by `desktop = false` and asserted off if you turn them on anyway.

AirPlay 2 is on by default (`airplay2 = true` → `shairport-sync-airplay2` + nqptp).
It advertises both `_airplay._tcp` and `_raop._tcp` and falls back to classic AirPlay
for older senders. `airplay2 = false` would swap in plain `shairport-sync`: AirPlay 1
only, no nqptp, RTSP on 5000, and no ffmpeg in the closure — available if the closure
size of the AirPlay 2 build ever matters here.

## Sharing the card with the instrument

This is the part that needed measuring, because upstream says not to do it:

> A problem with this setup is that Shairport Sync expects exclusive access to the
> audio device. If you have other audio sources, this can be problematic. In such a
> situation, an otherwise-bare system … but with PipeWire added, can be used, so that
> all audio sources output to the PipeWire system, which takes care of mixing.
> — `AIRPLAY2.md`

On this board that is not how the hardware behaves. Two facts:

**The synth holds the card permanently.** `sink` writes silence when nothing is
playing, so its PCM never closes:

```
$ cat /proc/asound/card0/pcm0p/sub0/status
state: RUNNING
owner_pid   : 11380            # == sink.service MainPID
hw_params:  S16_LE 2ch 44100 Hz, period 444, buffer 1764
appl_ptr    : 3134372 → 3224355   (2 s apart ≈ 44,991 frames/s)
```

**The driver takes more than one client.** `/proc/asound/pcm` says
`00-00: bcm2835 Headphones : playback 8` — the staging `snd_bcm2835` driver exposes
eight playback substreams, and `snd_bcm2835_playback_open_generic()` only refuses a
second open of the *same* substream index. So a second client lands on `sub1` while
the synth keeps `sub0`.

Measured on 2026-10-12 with `sink-direct-probe` (silent, `--amplitude 0`), against the
running instrument:

| probe | result | sink meanwhile |
|---|---|---|
| `--device hw:0,0 --seconds 8` | opened **sub1**, granted 552/2205, 804 periods of 441 frames in 8.0 s, 0 writei errors | `sub0` RUNNING, 444/1764, unchanged |
| same, `--rate 48000` (sink at 44.1 kHz) | opened sub1, 600/2400, 875 periods in 8.0 s, 0 errors | `sub0` still RUNNING at 44100 |

Its underrun counter was flat across the whole window — 139 at 20:21:49, 140 at
20:22:49 and 140 at 20:23:49 *and* 20:25:49, i.e. every probe produced no new
underruns. Two streams at two different rates both being consumed in real time also
says the substreams are independent, not one shared clock.

Two things this does **not** prove, both worth knowing:

- That both streams are *audible* together. The driver acks each substream
  independently (`snd_bcm2835_pcm_ack` → `snd_pcm_indirect_playback_transfer`), so
  "consumed in real time, no errors" is necessary but not sufficient for "you can hear
  it mixed". The ear test is a tone while the synth runs:
  `sink-direct-probe --seconds 5 --freq 440 --amplitude 0.15`.
- That it holds at other rates in the other direction, or under sustained load. The
  instrument's own output path already has an intermittent fault
  (`plans/latency.md`, `plans/remove-popping.md` in the sink repository), so do not
  read an AirPlay-era dropout as a new bug without checking that first.

The good news is structural: shairport-sync opens the device when a stream starts and
closes it when the stream ends (`audio_alsa.c`: `stop()` → `do_close()`), so an idle
receiver holds no audio device at all — the two only share the card while something is
actually playing. Do not set `alsa.disable_standby_mode = "always"` or
`alsa.use_precision_timing = "yes"` on this box: both flip `keep_dac_busy = 1` and
would pin `hw:0,0` open forever.

## Ports

| what | ports | note |
|---|---|---|
| RTSP (control) | TCP 7000 | AirPlay 2 default; a classic build uses 5000 (`shairport.c`) |
| PTP timing | UDP 319, 320 | nqptp; AirPlay 2 only |
| event channel | TCP 32768-60999 | the sender connects *into* a port the receiver picked |
| AirPlay 2 streams | UDP 32768-60999 | control and realtime audio, same story |
| classic air audio | UDP 6001-6011 | used when the AirPlay 2 build reverts to classic AirPlay |
| mDNS | UDP 5353 | avahi, already on this host |

The bottom two rows are the reason this module owns the firewall rather than using
`services.shairport-sync.openFirewall`, which opens TCP **5000** — the classic port,
i.e. wrong for the AirPlay 2 package — and knows nothing about the dynamic ones.
Those come in two flavours, and getting only one of them is the trap this box already
fell into:

- **UDP**: the control and realtime-audio sockets are bound with local port 0
  (`rtsp.c`: `conn->local_ap2_control_port = 0; // any port`) and the chosen port is
  handed to the sender in the SETUP reply, so its packets arrive inbound on a port
  nothing can predict.
- **TCP**: the *event* channel. The receiver binds a port, advertises it as
  `eventPort`, and `ap2_event_receiver` then accepts the sender's incoming connection
  (`eintr_checked_accept`). With only the UDP range open, the phone's connect to that
  port is silently dropped: the handshake completes, nothing plays, and the journal
  stops one line after a successful PTP setup — no error, because there is nothing on
  the Pi to see.

Both land in the kernel's ephemeral range, which is what `services.airplay.ephemeralPorts`
(default `32768-60999`, applied to TCP and UDP) opens. `= []` closes them if that ever
matters; the last two rows of the table go quiet, nothing else does.

## Operating it

```bash
systemctl status shairport-sync            # the system unit
journalctl -u shairport-sync -f             # what a client is doing
shairport-sync -h                           # build flags + ALSA device names
ss -tlnp | grep 7000                        # is RTSP actually listening
systemctl stop shairport-sync               # give the card back to the synth alone
```

**"The phone connects and nothing plays"** is the signature of a firewall problem on
this box, not an AirPlay bug: the handshake happens over port 7000 and every later
channel is on a port picked at runtime, so the useful question is whether the phone can
reach *those*. Test it from the LAN without a phone at all — a dropped port times out,
an open one is refused, and the difference is the whole diagnosis:

```bash
nc -vz -G 4 192.168.1.27 40000      # timeout = dropped; refused = the rule is in place
```

If it times out, `/etc/shairport-sync.conf` still shows what you expect — the ports are
the module's business (`modules/nixos/airplay.nix`, `ephemeralPorts`), not the daemon's.

To watch the two streams coexist while a phone is playing: `cat
/proc/asound/card0/pcm0p/sub*/status` — `sub0` is the synth, `sub1` is AirPlay.

Do **not** aim AirPlay at the Bluetooth speaker. Upstream is blunt about it ("for the
same reason, Shairport Sync does not work very well with Bluetooth" — `AIRPLAY2.md`),
and this board has one radio shared between WiFi and Bluetooth with the HCI UART pushed
to 460800 for the instrument's sake.
