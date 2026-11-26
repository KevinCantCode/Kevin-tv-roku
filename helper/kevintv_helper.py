#!/usr/bin/env python3
"""Kevin TV converter for Roku.

Runs on a computer on the home network (the Mac). The Roku asks it for movies/episodes whose sound it can't
play (Dolby Digital Plus, DTS, ...). It fetches the file from the provider once, passes the video through
untouched, converts only the sound to stereo AAC, and serves the result to the Roku as HLS.

Built for a provider plan that allows ONE stream at a time:
  * only one conversion runs at a time; starting another stops the first before opening a new connection
  * it waits a few seconds before connecting, so the Roku's own stream has closed first
  * it never retries on its own
  * if the Roku stops asking for the stream (stopped, crashed, turned off) the provider connection is closed

Standard library only (Python 3.9+). Needs ffmpeg.
"""
import argparse
import ipaddress
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "1.0"
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) KevinTV/1.0"
START_DELAY = 4.0        # seconds to wait before connecting to the provider (lets the Roku's stream close)
IDLE_STOP = 120.0        # no requests from the Roku for this long -> stop converting (closes the provider stream)
FIRST_SEGMENTS = 2       # segments ready before the playlist is handed to the Roku
PLAYLIST_WAIT = 30.0     # longest the Roku is kept waiting for the first segments
SEGMENT_SECS = 6
WORK = os.path.join(tempfile.gettempdir(), "kevintv-helper")

CFG = {}
FFMPEG = "ffmpeg"
ALLOW_VPN = False


def provider_route():
    """Network interface the provider is reached through (macOS), e.g. 'en0' (home Wi-Fi) or 'utun4' (a VPN)."""
    if sys.platform != "darwin":
        return ""
    try:
        import socket
        host = urllib.parse.urlparse(CFG["server"]).hostname
        ip = socket.gethostbyname(host)
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


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def redact(s):
    """Never print the provider login."""
    s = str(s)
    for k in ("user", "pass"):
        v = CFG.get(k) or ""
        if v:
            s = s.replace(v, "<" + k + ">").replace(urllib.parse.quote(v, safe=""), "<" + k + ">")
    return re.sub(r"https?://[^\s'\"]+", "<url>", s)


def provider_url(kind, sid, ext):
    q = lambda x: urllib.parse.quote(x, safe="")
    return "%s/%s/%s/%s/%s.%s" % (CFG["server"].rstrip("/"), kind, q(CFG["user"]), q(CFG["pass"]), sid, ext)


# ---------------------------------------------------------------- one conversion at a time
class Session:
    def __init__(self, key, kind, sid, ext, start, vmode):
        self.key = key
        self.kind, self.sid, self.ext, self.start, self.vmode = kind, sid, ext, start, vmode
        self.id = "%x" % int(time.time() * 1000)
        self.dir = os.path.join(WORK, self.id)
        os.makedirs(self.dir, exist_ok=True)
        self.proc = None
        self.awake = None
        self.cancelled = False
        self.state = "waiting"       # waiting -> converting -> done | failed | stopped
        self.error = ""
        self.last = time.time()
        self.t0 = time.time()

    @property
    def playlist(self):
        return os.path.join(self.dir, "index.m3u8")

    def touch(self):
        self.last = time.time()

    def run(self):
        # wait for the Roku's own provider stream to close; a newer request may cancel us meanwhile
        end = time.time() + START_DELAY
        while time.time() < end:
            if self.cancelled:
                return
            time.sleep(0.2)
        if self.cancelled:
            return
        why = vpn_block()
        if why:
            self.state = "failed"
            self.error = "not converting: " + why
            log("[%s] %s" % (self.id, self.error))
            return
        cmd = [FFMPEG, "-hide_banner", "-nostdin", "-loglevel", "error", "-user_agent", UA]
        if self.start > 0:
            cmd += ["-ss", str(self.start)]
        else:
            cmd += ["-seekable", "0"]          # read straight through: no extra range requests to the provider
        cmd += ["-i", provider_url(self.kind, self.sid, self.ext),
                "-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn", "-max_muxing_queue_size", "4096"]
        if self.vmode == "1":
            cmd += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "21", "-pix_fmt", "yuv420p"]
        else:
            cmd += ["-c:v", "copy"]
        cmd += ["-c:a", "aac", "-ac", "2", "-b:a", "192k",
                "-f", "hls", "-hls_time", str(SEGMENT_SECS), "-hls_list_size", "0",
                "-hls_playlist_type", "event", "-hls_segment_type", "mpegts", "-start_number", "0",
                "-hls_segment_filename", os.path.join(self.dir, "seg%05d.ts"), self.playlist]
        err = open(os.path.join(self.dir, "ffmpeg.log"), "wb")
        log("[%s] converting %s %s.%s from %ss (video %s) - 1 provider connection" % (
            self.id, self.kind, self.sid, self.ext, self.start, "re-encode" if self.vmode == "1" else "copy"))
        self.state = "converting"
        self.proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=err)
        if sys.platform == "darwin" and shutil.which("caffeinate"):
            # keep the Mac awake while the Roku is watching (stopped when the session ends)
            self.awake = subprocess.Popen(["caffeinate", "-i"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        rc = self.proc.wait()
        err.close()
        if self.cancelled:
            self.state = "stopped"
        elif rc == 0:
            self.state = "done"
            log("[%s] conversion finished in %ds; provider stream closed" % (self.id, time.time() - self.t0))
        else:
            self.state = "failed"
            try:
                with open(os.path.join(self.dir, "ffmpeg.log"), "rb") as f:
                    self.error = redact(f.read().decode("utf-8", "replace").strip().splitlines()[-1][:300])
            except Exception:
                self.error = "ffmpeg exited with code %s" % rc
            log("[%s] conversion FAILED: %s" % (self.id, self.error))

    def stop(self, why):
        self.cancelled = True
        if self.proc and self.proc.poll() is None:
            log("[%s] stopping conversion (%s); closing provider stream" % (self.id, why))
            self.proc.terminate()
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self.release_awake()

    def release_awake(self):
        if self.awake and self.awake.poll() is None:
            self.awake.terminate()
        self.awake = None

    def segments(self):
        try:
            return sum(1 for n in os.listdir(self.dir) if n.endswith(".ts"))
        except OSError:
            return 0

    def remove(self):
        shutil.rmtree(self.dir, ignore_errors=True)


class Manager:
    def __init__(self):
        self.lock = threading.Lock()
        self.cur = None

    def get(self, kind, sid, ext, start, vmode):
        key = (kind, sid, ext, start, vmode)
        with self.lock:
            s = self.cur
            if s and s.key == key and s.state not in ("failed", "stopped"):
                s.touch()
                return s
            if s and s.key == key and s.state == "failed" and time.time() - s.last < 90:
                return s                     # just failed: report it again, never retry the provider by itself
            if s:
                s.stop("a new title was asked for")
                s.remove()
            s = Session(key, kind, sid, ext, start, vmode)
            self.cur = s
            threading.Thread(target=s.run, daemon=True).start()
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
                    if s.state in ("waiting", "converting"):
                        s.stop("the Roku stopped watching %ds ago" % idle)
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
SEG_PATH = re.compile(r"^/s/([0-9a-f]+)/(seg\d{5}\.ts)$")


class Handler(BaseHTTPRequestHandler):
    server_version = "KevinTVHelper/" + VERSION
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def send(self, code, body, ctype="text/plain; charset=utf-8", extra=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
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
        q = urllib.parse.parse_qs(u.query)
        if u.path == "/api/status":
            why = vpn_block()
            if why:
                log("status check refused: " + why)
                return self.send(503, json.dumps({"ok": False, "status": why}), "application/json")
            s = MGR.cur
            busy = bool(s and s.state in ("waiting", "converting"))
            return self.send(200, json.dumps({"ok": True, "status": "ready", "app": "kevintv-helper",
                                              "version": VERSION, "busy": busy}), "application/json")
        m = ROKU_PATH.match(u.path)
        if m:
            return self.playlist(m.group(1), m.group(2), m.group(3).lower(), q)
        m = SEG_PATH.match(u.path)
        if m:
            return self.segment(m.group(1), m.group(2))
        return self.send(404, "not found")

    def playlist(self, kind, sid, ext, q):
        try:
            start = max(0, int(float((q.get("t") or ["0"])[0])))
        except ValueError:
            start = 0
        vmode = (q.get("v") or ["0"])[0]
        if vmode not in ("0", "1", "auto"):
            vmode = "0"
        s = MGR.get(kind, sid, ext, start, vmode)
        first = s.segments() < FIRST_SEGMENTS
        if first:
            log("[%s] Roku asked for %s %s.%s at %ss" % (s.id, kind, sid, ext, start))
        deadline = time.time() + PLAYLIST_WAIT
        while time.time() < deadline:
            if s.state in ("failed", "stopped"):
                break
            if os.path.exists(s.playlist) and (s.segments() >= FIRST_SEGMENTS or s.state == "done"):
                break
            time.sleep(0.25)
        s.touch()
        if s.state == "failed":
            return self.send(502, "conversion failed: " + s.error)
        if not os.path.exists(s.playlist):
            return self.send(504, "the provider didn't send anything in time")
        with open(s.playlist, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
        out = []
        for line in text.splitlines():
            if line.startswith("#EXTM3U"):
                out.append(line)
                out.append("#EXT-X-START:TIME-OFFSET=0,PRECISE=YES")   # play from the start, not the live edge
            elif line and not line.startswith("#"):
                out.append("/s/%s/%s" % (s.id, line.strip()))
            else:
                out.append(line)
        if first:
            log("[%s] playlist ready (%d segments) after %.1fs" % (s.id, s.segments(), time.time() - s.t0))
        return self.send(200, "\n".join(out) + "\n", "application/vnd.apple.mpegurl")

    def segment(self, sess_id, name):
        s = MGR.by_id(sess_id)
        if not s:
            return self.send(410, "this conversion has ended; play the title again")
        s.touch()
        path = os.path.join(s.dir, name)
        if not os.path.exists(path):
            return self.send(404, "segment not ready")
        size = os.path.getsize(path)
        self.send_response(200)
        self.send_header("Content-Type", "video/mp2t")
        self.send_header("Content-Length", str(size))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command == "HEAD":
            return
        with open(path, "rb") as f:
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
    import socket
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
    global CFG, FFMPEG, ALLOW_VPN
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

    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK, exist_ok=True)
    threading.Thread(target=MGR.watchdog, daemon=True).start()

    srv = ThreadingHTTPServer(("0.0.0.0", a.port), Handler)
    srv.daemon_threads = True

    def bye(*_):
        MGR.stop_all()
        shutil.rmtree(WORK, ignore_errors=True)
        os._exit(0)
    signal.signal(signal.SIGINT, bye)
    signal.signal(signal.SIGTERM, bye)

    log("Kevin TV converter %s running." % VERSION)
    log("On the Roku: Kevin TV > Settings > PC address = %s:%d" % (lan_ip(), a.port))
    log("Leave this window open while watching. Ctrl+C stops it.")
    why = vpn_block()
    if why:
        log("WARNING: " + why + ". Nothing will be converted until it's off.")
    srv.serve_forever()


if __name__ == "__main__":
    main()
