"""Fullscreen "now playing" display for the AirPlay receiver, with keep-awake.

What it does
------------
While an AirPlay stream is connected it puts a fullscreen window on the TV
showing the cover art, track, artist, album and a progress bar, and it holds
idle inhibitors so the box behaves the way it does when a video is playing —
i.e. it does not blank/lock/sleep in the middle of an album. When the stream
ends the window disappears and the inhibitors are released.

Where the data comes from
-------------------------
shairport-sync publishes everything on the *session* bus (no extra plumbing
needed — the metadata section is enabled by default in this build):

  org.mpris.MediaPlayer2.ShairportSync   PlaybackStatus, Metadata
                                         (title/artist/album/mpris:length and
                                          mpris:artUrl -> cached cover JPEG)

Inhibitors held while a stream is connected
-------------------------------------------
  * org.freedesktop.ScreenSaver.Inhibit — the call video players make; this is
    what stops KWin/PowerDevil blanking the screen, locking it and running idle
    actions.
  * systemd-inhibit --what=idle:sleep:shutdown (logind), best effort. logind
    only authorises *shutdown* blocking for an active seat session, so when this
    runs as a user service the call may be refused; that is logged, not fatal.

Exit codes: 0 clean shutdown, 1 no display / unusable environment.
"""

from __future__ import annotations

import argparse
import logging
import os
import signal
import subprocess
import sys
import time

from PyQt6.QtCore import Qt, QTimer
from PyQt6.QtDBus import QDBusConnection, QDBusInterface
from PyQt6.QtGui import QColor, QFont, QPainter, QPixmap
from PyQt6.QtWidgets import QApplication, QLabel, QProgressBar, QVBoxLayout, QWidget

MPRIS_SERVICE = "org.mpris.MediaPlayer2.ShairportSync"
MPRIS_PATH = "/org/mpris/MediaPlayer2"
MPRIS_PLAYER = "org.mpris.MediaPlayer2.Player"
DBUS_PROPERTIES = "org.freedesktop.DBus.Properties"
SCREENSAVER_SERVICE = "org.freedesktop.ScreenSaver"
SCREENSAVER_PATH = "/ScreenSaver"

POLL_MS = 1000
#: How long the art stays up after the sender goes quiet. shairport-sync keeps
#: its own session alive for ~60s after the last packet, then reports Stopped.
LINGER_S = 20

log = logging.getLogger("airplay-nowplaying")


def fmt_time(seconds: float) -> str:
    seconds = max(0, int(seconds))
    return f"{seconds // 60}:{seconds % 60:02d}"


def dbus_reply_value(reply):
    """PyQt6 sometimes unwraps QDBusReply, sometimes hands back the wrapper."""
    if hasattr(reply, "value"):
        return reply.value()
    return reply


def mirror_active() -> bool:
    """True while an AirPlay client is connected to the mirroring server.

    UxPlay draws mirrored video into its own fullscreen window on the same
    display, and our album art would fight it for the screen. UxPlay is an
    always-on service here, so "is the process running" is useless — instead
    look for an established TCP connection to its ports (see
    AIRPLAY_MIRROR_PORT, set by modules/nixos/airplay.nix). Failing to detect
    that just means the two windows behave as two ordinary windows.
    """
    try:
        base = int(os.environ.get("AIRPLAY_MIRROR_PORT", "0"))
    except ValueError:
        base = 0
    if base == 0:
        return False
    ports = {base, base + 1, base + 2}
    for path in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            with open(path, encoding="utf-8") as handle:
                next(handle, None)  # header
                for line in handle:
                    fields = line.split()
                    # sl local_address rem_address st ...
                    if len(fields) < 4 or fields[3] != "01":  # 01 = ESTABLISHED
                        continue
                    try:
                        port = int(fields[1].split(":")[1], 16)
                    except (IndexError, ValueError):
                        continue
                    if port in ports:
                        return True
        except OSError:
            continue
    return False


class Inhibitors:
    """Holds the idle inhibitors for as long as a stream is connected."""

    def __init__(self, bus: QDBusConnection, inhibit_logind: bool = True) -> None:
        self.bus = bus
        self.inhibit_logind = inhibit_logind
        self.screensaver_cookie: int | None = None
        self.login1_child: subprocess.Popen | None = None

    @property
    def held(self) -> bool:
        return self.screensaver_cookie is not None or self.login1_child is not None

    def acquire(self, why: str) -> None:
        if self.held:
            return
        log.info("holding idle inhibitors (%s)", why)
        self._acquire_screensaver(why)
        if self.inhibit_logind:
            self._acquire_logind(why)

    def _acquire_screensaver(self, why: str) -> None:
        iface = QDBusInterface(SCREENSAVER_SERVICE, SCREENSAVER_PATH, SCREENSAVER_SERVICE, self.bus)
        if not iface.isValid():
            log.warning("screensaver interface unavailable: %s", iface.lastError().message())
            return
        reply = iface.call("Inhibit", "airplay-nowplaying", why)
        if reply.type() != reply.MessageType.ReplyMessage:
            log.warning("screensaver Inhibit failed: %s", reply.errorMessage())
            return
        arguments = reply.arguments()
        if arguments:
            self.screensaver_cookie = int(arguments[0])
            log.info("screensaver inhibited (cookie %s)", self.screensaver_cookie)

    def _acquire_logind(self, why: str) -> None:
        sh = os.environ.get("AIRPLAY_SH", "/bin/sh")
        sleep = os.environ.get("AIRPLAY_SLEEP", "sleep")
        # The watchdog loop exits by itself if this process disappears, so a
        # hard-killed app cannot leave a stale "shutdown blocked" behind.
        watchdog = f"while kill -0 {os.getpid()} 2>/dev/null; do {sleep} 5; done"
        cmd = [
            os.environ.get("AIRPLAY_SYSTEMD_INHIBIT", "systemd-inhibit"),
            "--what=idle:sleep:shutdown",
            "--mode=block",
            f"--why={why}",
            sh,
            "-c",
            watchdog,
        ]
        try:
            self.login1_child = subprocess.Popen(
                cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE
            )
        except OSError as exc:
            log.warning("could not run systemd-inhibit: %s", exc)
            return
        time.sleep(0.3)
        if self.login1_child.poll() is None:
            log.info("logind idle/sleep/shutdown inhibition granted")
            return
        error = (self.login1_child.stderr.read() or b"").decode(errors="replace").strip()
        log.warning("logind inhibition refused, continuing without it: %s", error)
        self.login1_child = None

    def release(self) -> None:
        if self.screensaver_cookie is not None:
            iface = QDBusInterface(
                SCREENSAVER_SERVICE, SCREENSAVER_PATH, SCREENSAVER_SERVICE, self.bus
            )
            if iface.isValid():
                iface.call("UnInhibit", self.screensaver_cookie)
            log.info("screensaver released")
            self.screensaver_cookie = None
        if self.login1_child is not None:
            self.login1_child.terminate()
            try:
                self.login1_child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.login1_child.kill()
            self.login1_child = None
            log.info("logind inhibition released")


class Player:
    """Reads the current AirPlay stream state off the session bus.

    Note: PyQt6's QDBusInterface.property() does not fetch *D-Bus* properties
    (only Qt ones), so reads go through org.freedesktop.DBus.Properties.Get.
    """

    def __init__(self, bus: QDBusConnection) -> None:
        self.bus = bus
        self._props: QDBusInterface | None = None

    def _properties(self) -> QDBusInterface | None:
        if self._props is not None:
            return self._props
        # Cheap liveness check first: constructing a QDBusInterface for an
        # absent service triggers a (blocking) activation attempt.
        try:
            registered = bool(dbus_reply_value(self.bus.interface().isServiceRegistered(MPRIS_SERVICE)))
        except Exception as exc:  # noqa: BLE001 - never kill the display over this
            log.debug("isServiceRegistered failed: %s", exc)
            return None
        if not registered:
            return None
        iface = QDBusInterface(MPRIS_SERVICE, MPRIS_PATH, DBUS_PROPERTIES, self.bus)
        if not iface.isValid():
            log.debug("properties interface invalid: %s", iface.lastError().message())
            return None
        log.info("connected to shairport-sync on the session bus")
        self._props = iface
        return iface

    def property(self, name: str, interface: str = MPRIS_PLAYER):
        iface = self._properties()
        if iface is None:
            return None
        reply = iface.call("Get", interface, name)
        if reply.type() != reply.MessageType.ReplyMessage:
            log.debug("Get %s failed: %s", name, reply.errorMessage())
            return None
        arguments = reply.arguments()
        return arguments[0] if arguments else None

    def state(self) -> tuple[str, dict]:
        """Returns (playback_status, metadata); 'Stopped' when nothing is there."""
        status = self.property("PlaybackStatus")
        if status is None:
            return "Stopped", {}
        metadata = self.property("Metadata")
        if not isinstance(metadata, dict):
            metadata = {}
        return str(status), metadata


class NowPlayingWindow(QWidget):
    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle("AirPlay")
        self.setWindowFlags(Qt.WindowType.FramelessWindowHint | Qt.WindowType.Window)

        self._art_full: QPixmap | None = None
        self._art_small: QPixmap | None = None  # downscaled source for the backdrop
        self._art_source = ""

        self.art_label = QLabel(alignment=Qt.AlignmentFlag.AlignCenter)
        self.title_label = QLabel(alignment=Qt.AlignmentFlag.AlignHCenter)
        self.title_label.setWordWrap(True)
        self.artist_label = QLabel(alignment=Qt.AlignmentFlag.AlignHCenter)
        self.artist_label.setWordWrap(True)
        self.album_label = QLabel(alignment=Qt.AlignmentFlag.AlignHCenter)
        self.progress = QProgressBar()
        self.progress.setRange(0, 1000)
        self.progress.setTextVisible(False)
        self.progress.setFixedHeight(6)
        self.progress.setStyleSheet(
            "QProgressBar { border: none; border-radius: 3px; background: rgba(255,255,255,0.16); }"
            "QProgressBar::chunk { border-radius: 3px; background: #e9e9ef; }"
        )
        self.elapsed_label = QLabel(alignment=Qt.AlignmentFlag.AlignLeft)
        self.remaining_label = QLabel(alignment=Qt.AlignmentFlag.AlignRight)

        for label in (
            self.art_label,
            self.title_label,
            self.artist_label,
            self.album_label,
            self.elapsed_label,
            self.remaining_label,
        ):
            label.setStyleSheet("color: #f2f2f4; background: transparent;")
        self.album_label.setStyleSheet("color: rgba(242,242,244,0.62); background: transparent;")
        for label in (self.elapsed_label, self.remaining_label):
            label.setStyleSheet("color: rgba(242,242,244,0.55); background: transparent;")

        layout = QVBoxLayout(self)
        layout.setContentsMargins(72, 56, 72, 56)
        layout.setSpacing(6)
        layout.addWidget(self.art_label, stretch=1)
        layout.addSpacing(18)
        layout.addWidget(self.title_label)
        layout.addWidget(self.artist_label)
        layout.addWidget(self.album_label)
        layout.addSpacing(24)
        layout.addWidget(self.progress)
        layout.addWidget(self.elapsed_label)
        layout.addWidget(self.remaining_label)

        self._resize_fonts()

    # ── painting ──────────────────────────────────────────────────────────
    def _resize_fonts(self) -> None:
        screen = self.screen()
        height = screen.size().height() if screen else 1080
        self.title_label.setFont(QFont("", int(height * 0.042), QFont.Weight.DemiBold))
        self.artist_label.setFont(QFont("", int(height * 0.030)))
        self.album_label.setFont(QFont("", int(height * 0.022)))
        self.elapsed_label.setFont(QFont("", int(height * 0.018)))
        self.remaining_label.setFont(QFont("", int(height * 0.018)))

    def resizeEvent(self, event) -> None:  # noqa: N802 - Qt naming
        super().resizeEvent(event)
        self._resize_fonts()
        self._scale_art()

    def paintEvent(self, event) -> None:  # noqa: N802
        painter = QPainter(self)
        painter.fillRect(self.rect(), QColor("#0c0c10"))
        if self._art_small is not None and not self._art_small.isNull():
            # Downscale-then-upscale is a cheap, convincing backdrop blur.
            backdrop = self._art_small.scaled(
                self.size(),
                Qt.AspectRatioMode.KeepAspectRatioByExpanding,
                Qt.TransformationMode.SmoothTransformation,
            )
            painter.setOpacity(0.30)
            painter.drawPixmap(0, 0, backdrop)
            painter.setOpacity(1.0)
        painter.fillRect(self.rect(), QColor(10, 10, 14, 140))

    # ── content ───────────────────────────────────────────────────────────
    def set_art(self, url: str) -> None:
        if url == self._art_source:
            return
        self._art_source = url
        path = url[7:] if url.startswith("file://") else url
        pixmap = QPixmap(path) if path else QPixmap()
        self._art_full = pixmap if not pixmap.isNull() else None
        if self._art_full is None:
            self._art_small = None
        else:
            self._art_small = self._art_full.scaled(
                32,
                18,
                Qt.AspectRatioMode.KeepAspectRatioByExpanding,
                Qt.TransformationMode.SmoothTransformation,
            )
        self._scale_art()
        self.update()

    def _scale_art(self) -> None:
        if self._art_full is None:
            self.art_label.setPixmap(QPixmap())
            return
        side = int(min(self.width(), self.height()) * 0.50)
        self.art_label.setPixmap(
            self._art_full.scaled(
                side,
                side,
                Qt.AspectRatioMode.KeepAspectRatio,
                Qt.TransformationMode.SmoothTransformation,
            )
        )

    def set_text(self, title: str, artist: str, album: str) -> None:
        self.title_label.setText(title or "AirPlay")
        self.artist_label.setText(artist)
        self.album_label.setText(album)

    def set_progress(self, fraction: float, elapsed: float, length: float) -> None:
        self.progress.setValue(int(max(0.0, min(1.0, fraction)) * 1000))
        self.elapsed_label.setText(fmt_time(elapsed))
        self.remaining_label.setText(f"-{fmt_time(length - elapsed)}" if length else "")


def metadata_fields(metadata: dict) -> tuple[str, str, str, str, float]:
    def first(key: str) -> str:
        value = metadata.get(key)
        if isinstance(value, (list, tuple)):
            value = value[0] if value else ""
        return str(value or "")

    try:
        length = float(metadata.get("mpris:length") or 0) / 1_000_000  # µs -> s
    except (TypeError, ValueError):
        length = 0.0
    return (
        first("xesam:title"),
        first("xesam:artist"),
        first("xesam:album"),
        first("mpris:artUrl"),
        length,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Fullscreen AirPlay now-playing display")
    parser.add_argument("--windowed", action="store_true", help="do not go fullscreen (testing)")
    parser.add_argument("--no-inhibit", action="store_true", help="do not hold idle inhibitors")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="[%(levelname)s] %(message)s",
        stream=sys.stderr,
    )

    if not os.environ.get("WAYLAND_DISPLAY") and not os.environ.get("DISPLAY"):
        log.error("no wayland/x11 display in the environment, nothing to draw on")
        return 1

    app = QApplication(sys.argv[:1])
    bus = QDBusConnection.sessionBus()
    if not bus.isConnected():
        log.error("no session bus: %s", bus.lastError().message())
        return 1

    window = NowPlayingWindow()
    player = Player(bus)
    inhibitors = Inhibitors(bus, inhibit_logind=not args.no_inhibit)

    state: dict = {
        "visible": False,
        "track_id": None,
        "playing": False,
        "started": 0.0,
        "elapsed_at_pause": 0.0,
        "last_active": 0.0,
        "length": 0.0,
    }

    def hide_window(reason: str) -> None:
        inhibitors.release()
        if state["visible"]:
            window.hide()
            state["visible"] = False
            log.info("hiding now-playing window (%s)", reason)

    def tick() -> None:
        if mirror_active():
            # A client is mirroring video to this display; stay out of the way
            # (UxPlay's -scrsv handles the screensaver while video plays).
            hide_window("an AirPlay client is mirroring")
            return

        status, metadata = player.state()
        connected = status in ("Playing", "Paused")  # shairport-sync session is live
        playing = status == "Playing"
        now = time.monotonic()

        if connected:
            state["last_active"] = now
        elif state["visible"] and now - state["last_active"] > LINGER_S:
            hide_window("stream ended")
            return
        elif not state["visible"]:
            return

        title, artist, album, art_url, length = metadata_fields(metadata)
        track_id = metadata.get("mpris:trackid") or art_url or title

        if track_id != state["track_id"]:
            state["track_id"] = track_id
            state["started"] = now
            state["elapsed_at_pause"] = 0.0
            if track_id:
                log.info("now playing: %s — %s (%s)", artist or "?", title or "?", album or "?")

        if playing and not state["playing"]:
            state["started"] = now - state["elapsed_at_pause"]
        elif not playing:
            state["elapsed_at_pause"] = now - state["started"]
        state["playing"] = playing

        elapsed = now - state["started"] if playing else state["elapsed_at_pause"]
        window.set_art(art_url)
        window.set_text(title, artist, album)
        window.set_progress(elapsed / length if length else 0.0, elapsed, length)

        if connected:
            why = f"AirPlay is playing: {artist} — {title}".strip(" —") if title or artist else "AirPlay is playing"
            inhibitors.acquire(why)

        if not state["visible"]:
            if args.windowed:
                window.show()
            else:
                window.showFullScreen()
            window.raise_()
            state["visible"] = True
            log.info("stream connected, showing window")

    timer = QTimer()
    timer.timeout.connect(tick)
    timer.start(POLL_MS)
    tick()

    def shutdown(*_args) -> None:
        inhibitors.release()
        app.quit()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
