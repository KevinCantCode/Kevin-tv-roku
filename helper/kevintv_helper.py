#!/usr/bin/env python3
"""Kevin TV converter for Roku.

Runs on a computer on the home network (the Mac). The Roku asks it for movies/episodes whose sound it can't
play (Dolby Digital Plus, DTS, ...). It fetches the file from the provider, converts the sound to stereo AAC and
re-encodes the video (hardware encoder, a keyframe every 6 s so seeking is exact), and serves it to the Roku as an ordinary (VOD) HLS movie: the full
length is known up front, so the Roku's seek bar covers the whole film.

Conversion runs ahead of playback (several times faster than real time). Jumping to a part that isn't
converted yet restarts the conversion from there.

Built for a provider plan that allows ONE stream at a time:
  * one provider connection at most: a restart closes the old one first
  * before connecting it asks the provider (account info, not a stream) until a stream slot is free
  * it never retries a stream on its own
  * if the Roku stops asking (stopped, crashed, turned off) the provider connection is closed
  * it refuses to fetch through a VPN unless started with --allow-vpn

Standard library only (Python 3.9+). Needs ffmpeg.
"""
import argparse
import collections
import ipaddress
import json
import math
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "1.1"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) KevinTV/1.0"
SEG = 6                  # seconds per HLS segment
AHEAD = 30               # a segment this many past the converted part is waited for, not restarted (3 min of video)
IDLE_STOP = 120.0        # no requests from the Roku for this long -> stop converting (closes the provider stream)
FREE_WAIT = 60.0         # longest wait for the provider to free the single stream slot
FREE_POLL = 8.0          # seconds between account checks while waiting (at most ~8 checks per wait)
SEEK_SETTLE = 1.5        # after a far jump, wait this long for the Roku to settle on one spot before restarting
SEG_WAIT = 45.0          # longest a segment request waits for its segment to be converted
DUR_WAIT = 40.0          # longest the playlist waits to learn the movie's length from ffmpeg
FAILED_HOLD = 90.0       # after a failure, the same title isn't retried by itself for this long
WORK = ""                # temp folder for this helper only (set in main, one per port)

CFG = {}
FFMPEG = "ffmpeg"
ALLOW_VPN = False
HW = False               # the Mac's hardware video encoder/decoder (VideoToolbox) is available


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def redact(s):
    """Never print the provider login."""
    s = str(s)
    s = re.sub(r"https?://[^\s'\"]+", "<url>", s)
    for k in ("user", "pass"):
        v = CFG.get(k) or ""
        if len(v) >= 4:
            s = s.replace(v, "<" + k + ">").replace(urllib.parse.quote(v, safe=""), "<" + k + ">")
    return s


def q(x):
    return urllib.parse.quote(x, safe="")


def provider_url(kind, sid, ext):
    return "%s/%s/%s/%s/%s.%s" % (CFG["server"].rstrip("/"), kind, q(CFG["user"]), q(CFG["pass"]), sid, ext)


def connections_in_use():
    """(active, max) from the provider's account info, or None if it can't be read. Not a stream."""
    u = "%s/player_api.php?username=%s&password=%s" % (CFG["server"].rstrip("/"), q(CFG["user"]), q(CFG["pass"]))
    try:
        with urllib.request.urlopen(urllib.request.Request(u, headers={"User-Agent": UA}), timeout=10) as r:
            info = json.loads(r.read().decode("utf-8", "replace")).get("user_info") or {}
        return int(info.get("active_cons") or 0), int(info.get("max_connections") or 1)
    except Exception as e:
        log("account check failed: " + redact(e))
        return None


def provider_route():
    """Network interface the provider is reached through (macOS), e.g. 'en0' (home Wi-Fi) or 'utun4' (a VPN)."""
    if sys.platform != "darwin":
        return ""
    try:
        ip = socket.gethostbyname(urllib.parse.urlparse(CFG["server"]).hostname)
        out = subprocess.run(["route", "-n", "get", ip], capture_output=True, text=True, timeout=5).stdout
        m = re.search(r"interface:\s*(\S+)", out)
        return m.group(1) if m else ""
    except Exception:
        return ""


def vpn_block():
    """Non-empty reason when the provider would be reached through a VPN tunnel (e.g. a work VPN)."""
    if ALLOW_VPN:
        return ""
    i = provider_route()
    if i.startswith(("utun", "ppp", "ipsec", "tun", "tap")):
        return "a VPN is connected (provider traffic would go through %s). Disconnect it, or start with --allow-vpn" % i
    return ""


# ---------------------------------------------------------------- one conversion run (= one provider connection)
class Run:
    def __init__(self, sess, start_idx):
        self.sess = sess
        self.start = start_idx
        self.proc = None
        self.cancelled = False
        self.state = "waiting"            # waiting -> converting -> done | failed | stopped
        self.error = ""
        self.tail = collections.deque(maxlen=12)
        self.ended = 0.0
        threading.Thread(target=self._guard, daemon=True).start()

    def active(self):
        return self.state in ("waiting", "converting")

    def _sleep(self, secs):
        end = time.time() + secs
        while time.time() < end:
            if self.cancelled:
                return False
            time.sleep(0.2)
        return not self.cancelled

    def _fail(self, why):
        self.state = "failed"
        self.error = why
        self.ended = time.time()
        log("[%s] not converting: %s" % (self.sess.id, why))

    def _guard(self):
        try:
            self._run()
        except Exception as e:
            self._fail("helper error: " + redact(e))

    def _run(self):
        s = self.sess
        why = vpn_block()
        if why:
            return self._fail(why)
        # wait until the provider has a free stream slot (the Roku's own stream, or our previous run, may still count)
        give_up = time.time() + FREE_WAIT
        while True:
            if self.cancelled:
                return
            c = connections_in_use()
            if c is None or c[0] < c[1]:
                break
            if time.time() >= give_up:
                return self._fail("your provider still counts another stream as playing (%d of %d in use). "
                                  "Stop it on the other device and play again" % c)
            log("[%s] provider says %d of %d streams in use; checking again in %ds" % (s.id, c[0], c[1], FREE_POLL))
            if not self._sleep(FREE_POLL):
                return
        if self.cancelled:
            return
        at = self.start * SEG
        cmd = [FFMPEG, "-hide_banner", "-nostdin", "-nostats", "-loglevel", "info", "-user_agent", UA]
        if HW:
            cmd += ["-hwaccel", "videotoolbox"]
        if at > 0:
            cmd += ["-ss", str(at)]
        else:
            cmd += ["-seekable", "0"]          # read straight through: no extra range requests to the provider
        # output clock starts at exactly the jump point, so piece N always plays at N*SEG on the Roku's timeline
        # (and pieces from different runs line up), even if the provider can only seek approximately
        cmd += ["-i", provider_url(s.kind, s.sid, s.ext),
                "-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn", "-max_muxing_queue_size", "4096",
                "-muxdelay", "0", "-output_ts_offset", str(at)]
        # The video is re-encoded with a keyframe exactly every SEG seconds. Passing it through untouched can
        # only cut where the file has keyframes (often 10 s apart), so piece N wouldn't start at N*SEG and
        # seeking would drift. The Mac's hardware encoder does this faster than the provider sends the file.
        if HW:
            cmd += ["-c:v", "h264_videotoolbox", "-profile:v", "high", "-b:v", "10M", "-maxrate", "15M", "-bufsize", "20M"]
        else:
            cmd += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-maxrate", "15M", "-bufsize", "20M"]
        cmd += ["-pix_fmt", "yuv420p", "-force_key_frames", "expr:gte(t,n_forced*%d)" % SEG]
        cmd += ["-c:a", "aac", "-ac", "2", "-b:a", "192k",
                "-f", "hls", "-hls_time", str(SEG), "-hls_list_size", "0", "-hls_segment_type", "mpegts",
                "-hls_flags", "temp_file", "-start_number", str(self.start),
                "-hls_segment_filename", os.path.join(s.dir, "seg%05d.ts"),
                os.path.join(s.dir, "run%05d.m3u8" % self.start)]
        log("[%s] converting %s %s.%s from %s - 1 provider connection" % (s.id, s.kind, s.sid, s.ext, hms(at)))
        self.state = "converting"
        t0 = time.time()
        self.proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        # read ffmpeg's messages in memory only (they contain the stream address, i.e. the login)
        for raw in self.proc.stderr:
            line = raw.decode("utf-8", "replace").rstrip()
            if s.duration is None:
                m = re.search(r"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)", line)
                if m:
                    s.duration = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3))
                    log("[%s] movie length %s" % (s.id, hms(s.duration)))
            if line and not line.startswith(" "):
                self.tail.append(redact(line))
        rc = self.proc.wait()
        self.ended = time.time()
        if self.cancelled:
            self.state = "stopped"
        elif rc == 0:
            self.state = "done"
            log("[%s] converted to the end in %ds; provider stream closed" % (s.id, time.time() - t0))
        else:
            err = [l for l in self.tail if "rror" in l or "fail" in l.lower()] or list(self.tail) or ["exit code %s" % rc]
            self._fail(err[-1][:300])

    def stop(self, why):
        self.cancelled = True
        if self.proc and self.proc.poll() is None:
            log("[%s] stopping conversion (%s); closing provider stream" % (self.sess.id, why))
            self.proc.terminate()
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        if self.state in ("waiting", "converting"):
            self.state = "stopped"
            self.ended = time.time()


def hms(secs):
    secs = int(secs)
    return "%d:%02d:%02d" % (secs // 3600, secs % 3600 // 60, secs % 60)


# ---------------------------------------------------------------- one title (kept until another title is played)
class Session:
    def __init__(self, key, kind, sid, ext, vmode):
        self.key = key
        self.kind, self.sid, self.ext, self.vmode = kind, sid, ext, vmode
        self.id = "%x" % int(time.time() * 1000)
        self.dir = os.path.join(WORK, self.id)
        os.makedirs(self.dir, exist_ok=True)
        self.lock = threading.RLock()
        self.run = None
        self.duration = None
        self.want = None              # latest far-jump target (segment index)
        self.last = time.time()
        self.awake = None

    def touch(self):
        self.last = time.time()
        if self.awake is None and sys.platform == "darwin" and shutil.which("caffeinate"):
            # keep the Mac awake while the Roku is watching
            self.awake = subprocess.Popen(["caffeinate", "-i"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def release_awake(self):
        if self.awake and self.awake.poll() is None:
            self.awake.terminate()
        self.awake = None

    def seg_path(self, i):
        return os.path.join(self.dir, "seg%05d.ts" % i)

    def have(self, i):
        return os.path.exists(self.seg_path(i))

    def count(self):
        if not self.duration:
            return 0
        return int(math.ceil(self.duration / SEG))

    def head(self):
        """Last segment the current run has produced (or start - 1)."""
        r = self.run
        if not r:
            return -1
        i = r.start
        while self.have(i):
            i += 1
        return i - 1

    def start_run(self, idx, why):
        with self.lock:
            r = self.run
            if r and r.active():
                if r.start == idx:
                    return r
                r.stop(why)
            self.run = Run(self, idx)
            return self.run

    def recently_failed(self):
        r = self.run
        return r is not None and r.state == "failed" and time.time() - r.ended < FAILED_HOLD

    def stop(self, why):
        with self.lock:
            if self.run:
                self.run.stop(why)
        self.release_awake()

    def remove(self):
        shutil.rmtree(self.dir, ignore_errors=True)


class Manager:
    def __init__(self):
        self.lock = threading.Lock()
        self.cur = None

    def get(self, kind, sid, ext, vmode):
        key = (kind, sid, ext, vmode)
        with self.lock:
            s = self.cur
            if s and s.key == key:
                return s
            if s:
                s.stop("a different title was asked for")
                s.remove()
            s = Session(key, kind, sid, ext, vmode)
            self.cur = s
            return s

    def by_id(self, sid):
        s = self.cur
        return s if s and s.id == sid else None

    def watchdog(self):
        while True:
            time.sleep(5)
            with self.lock:
                s = self.cur
                if not s:
                    continue
                idle = time.time() - s.last
                if idle > IDLE_STOP:
                    if s.run and s.run.active():
                        s.run.stop("the Roku stopped watching %ds ago" % idle)
                    s.release_awake()
                if idle > 6 * 3600:
                    s.remove()
                    self.cur = None

    def stop_all(self):
        with self.lock:
            if self.cur:
                self.cur.stop("helper shutting down")
                self.cur.remove()
                self.cur = None


MGR = Manager()


# ---------------------------------------------------------------- HTTP
ROKU_PATH = re.compile(r"^/roku/(movie|series)/(\d+)\.([A-Za-z0-9]{1,5})/index\.m3u8$")
SEG_PATH = re.compile(r"^/s/([0-9a-f]+)/seg(\d{5})\.ts$")


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        # the Roku closing a connection it no longer needs is normal: don't print a traceback for it
        e = sys.exc_info()[1]
        if isinstance(e, (ConnectionResetError, BrokenPipeError, ConnectionAbortedError, TimeoutError)):
            return
        super().handle_error(request, client_address)


class Handler(BaseHTTPRequestHandler):
    server_version = "KevinTVHelper/" + VERSION
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def send(self, code, body, ctype="text/plain; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def allowed(self):
        try:
            ip = ipaddress.ip_address(self.client_address[0])
            return ip.is_private or ip.is_loopback
        except ValueError:
            return False

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        if not self.allowed():
            return self.send(403, "home network only")
        u = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(u.query)
        if u.path == "/api/status":
            why = vpn_block()
            if why:
                log("status check refused: " + why)
                return self.send(503, json.dumps({"ok": False, "status": why}), "application/json")
            s = MGR.cur
            busy = bool(s and s.run and s.run.active())
            return self.send(200, json.dumps({"ok": True, "status": "ready", "app": "kevintv-helper",
                                              "version": VERSION, "busy": busy}), "application/json")
        m = ROKU_PATH.match(u.path)
        if m:
            return self.playlist(m.group(1), m.group(2), m.group(3).lower(), qs)
        m = SEG_PATH.match(u.path)
        if m:
            return self.segment(m.group(1), int(m.group(2)))
        return self.send(404, "not found")

    # the whole movie as a normal VOD playlist (fixed 6 s pieces, numbered by time), so the Roku can seek anywhere
    def playlist(self, kind, sid, ext, qs):
        def num(name):
            try:
                return max(0, int(float((qs.get(name) or ["0"])[0])))
            except ValueError:
                return 0
        start, hint = num("t"), num("d")
        vmode = (qs.get("v") or ["0"])[0]
        if vmode not in ("0", "1", "auto"):
            vmode = "0"
        s = MGR.get(kind, sid, ext, vmode)
        s.touch()
        idx = start // SEG
        log("[%s] Roku asked for %s %s.%s from %s" % (s.id, kind, sid, ext, hms(start)))
        if not s.have(idx) and not (s.run and s.run.active()):
            if s.recently_failed():
                return self.send(503, "conversion failed a moment ago: " + s.run.error)
            s.start_run(idx, "new play")
        if not s.duration and hint > 0:
            s.duration = float(hint)          # the catalog's runtime; replaced by ffmpeg's if this play learns it
        deadline = time.time() + DUR_WAIT
        while not s.duration and time.time() < deadline:
            if s.run and s.run.state == "failed":
                return self.send(502, "conversion failed: " + s.run.error)
            time.sleep(0.25)
        if not s.duration:
            return self.send(504, "couldn't learn the movie's length in time")
        n = s.count()
        out = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-TARGETDURATION:%d" % SEG,
               "#EXT-X-MEDIA-SEQUENCE:0"]
        for i in range(n):
            d = min(SEG, s.duration - i * SEG)
            out.append("#EXTINF:%.3f," % max(d, 0.1))
            out.append("/s/%s/seg%05d.ts" % (s.id, i))
        out.append("#EXT-X-ENDLIST")
        return self.send(200, "\n".join(out) + "\n", "application/vnd.apple.mpegurl")

    def segment(self, sess_id, i):
        s = MGR.by_id(sess_id)
        if not s:
            return self.send(410, "this conversion has ended; play the title again")
        s.touch()
        if s.count() and i >= s.count():
            return self.send(404, "past the end")
        if not s.have(i):
            r = s.run
            near = r is not None and r.active() and r.start <= i <= s.head() + AHEAD
            if not near:
                # a jump to a part that isn't converted: let the Roku settle, then restart there (one connection)
                s.want = i
                time.sleep(SEEK_SETTLE)
                if s.want != i:
                    return self.send(503, "superseded by a newer jump")
                if not s.have(i):
                    if s.recently_failed() and s.run.start == i:
                        return self.send(503, "conversion failed a moment ago: " + s.run.error)
                    log("[%s] Roku jumped to %s, which isn't converted yet" % (s.id, hms(i * SEG)))
                    s.start_run(i, "the Roku jumped to %s" % hms(i * SEG))
            deadline = time.time() + SEG_WAIT
            while not s.have(i) and time.time() < deadline:
                r = s.run
                if r is None or r.state in ("failed", "stopped"):
                    break
                if r.state == "done" and not s.have(i):
                    break
                time.sleep(0.25)
                s.touch()
            if not s.have(i):
                return self.send(503, "not converted yet")
        path = s.seg_path(i)
        try:
            size = os.path.getsize(path)
            f = open(path, "rb")
        except OSError:
            return self.send(503, "not converted yet")
        with f:
            self.send_response(200)
            self.send_header("Content-Type", "video/mp2t")
            self.send_header("Content-Length", str(size))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if self.command == "HEAD":
                return
            try:
                shutil.copyfileobj(f, self.wfile, 256 * 1024)
            except (BrokenPipeError, ConnectionResetError):
                pass


# ---------------------------------------------------------------- start-up
def load_config(path):
    with open(path, "r", encoding="utf-8") as f:
        c = json.load(f)
    out = {"server": c.get("server") or c.get("base") or "",
           "user": c.get("user") or c.get("username") or "",
           "pass": c.get("pass") or c.get("password") or ""}
    if not all(out.values()):
        raise SystemExit("%s needs server, user and pass" % path)
    s = out["server"].strip()
    if not s.lower().startswith(("http://", "https://")):
        s = "http://" + s
    out["server"] = re.match(r"^(https?://[^/?#]+)", s, re.I).group(1)
    return out


def lan_ip():
    if sys.platform == "darwin":
        for ifc in ("en0", "en1"):
            try:
                ip = subprocess.run(["ipconfig", "getifaddr", ifc], capture_output=True, text=True, timeout=3).stdout.strip()
                if ip:
                    return ip
            except Exception:
                pass
    try:
        k = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        k.connect(("192.168.0.1", 9))      # no packet is sent; this just picks the LAN interface
        ip = k.getsockname()[0]
        k.close()
        return ip
    except OSError:
        return "this-computer's-IP"


def main():
    global CFG, FFMPEG, ALLOW_VPN, HW, WORK
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description="Kevin TV converter for Roku")
    ap.add_argument("--port", type=int, default=8766)
    ap.add_argument("--config", default=os.path.join(here, "..", "data", "personal.json"),
                    help="JSON with server, user, pass (default: the Roku app's data/personal.json)")
    ap.add_argument("--ffmpeg", default="")
    ap.add_argument("--allow-vpn", action="store_true", help="convert even when the provider is reached through a VPN")
    a = ap.parse_args()

    ALLOW_VPN = a.allow_vpn
    CFG = load_config(a.config)
    FFMPEG = a.ffmpeg or shutil.which("ffmpeg") or os.path.expanduser("~/.local/bin/ffmpeg")
    if not os.path.exists(FFMPEG) and not shutil.which(FFMPEG):
        raise SystemExit("ffmpeg not found; install it or pass --ffmpeg /path/to/ffmpeg")

    try:
        enc = subprocess.run([FFMPEG, "-hide_banner", "-encoders"], capture_output=True, text=True, timeout=10).stdout
        HW = sys.platform == "darwin" and "h264_videotoolbox" in enc
    except Exception:
        HW = False

    WORK = os.path.join(tempfile.gettempdir(), "kevintv-helper-%d" % a.port)
    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK, exist_ok=True)
    threading.Thread(target=MGR.watchdog, daemon=True).start()

    srv = Server(("0.0.0.0", a.port), Handler)

    def bye(*_):
        MGR.stop_all()
        shutil.rmtree(WORK, ignore_errors=True)
        os._exit(0)
    signal.signal(signal.SIGINT, bye)
    signal.signal(signal.SIGTERM, bye)

    log("Kevin TV converter %s running (%s video encoding)." % (VERSION, "hardware" if HW else "software"))
    log("On the Roku: Kevin TV > Settings > PC address = %s:%d" % (lan_ip(), a.port))
    log("Leave this window open while watching. Ctrl+C stops it.")
    why = vpn_block()
    if why:
        log("WARNING: " + why + ". Nothing will be converted until it's off.")
    srv.serve_forever()


if __name__ == "__main__":
    main()
