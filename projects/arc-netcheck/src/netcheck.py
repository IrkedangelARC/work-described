#!/usr/bin/env python3
#
#  Copyright (c) 2025-2026 ARC Event Productions.
#  Published under the license in the repository root.
#
#

"""
arc-netcheck - venue network readiness for YouTube Live and Zoom webinar streams.

Stdlib only. No pip, no config, runs on any venue laptop.

    python netcheck.py check --label "Main Hall"
    python netcheck.py quick
    python netcheck.py soak --minutes 45
"""

from __future__ import annotations

import argparse
import concurrent.futures
import http.client
import json
import os
import platform
import re
import socket
import ssl
import statistics
import struct
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone

VERSION = "1.0"

# --------------------------------------------------------------------------
# Targets
# --------------------------------------------------------------------------

YOUTUBE_INGEST = [
    ("a.rtmp.youtube.com", 1935, "RTMP primary ingest"),
    ("b.rtmp.youtube.com", 1935, "RTMP backup ingest"),
    ("a.rtmps.youtube.com", 443, "RTMPS primary ingest"),
    ("b.rtmps.youtube.com", 443, "RTMPS backup ingest"),
]

ZOOM_TCP = [
    ("zoom.us", 443, "Zoom signaling"),
    ("us02web.zoom.us", 443, "Zoom web tier"),
]

STUN_TARGETS = [
    ("stun.l.google.com", 19302, "UDP egress (generic)"),
    ("stun.cloudflare.com", 3478, "UDP/3478 - the port Zoom uses for STUN"),
]

DNS_HOSTS = ["a.rtmp.youtube.com", "www.youtube.com", "zoom.us", "speed.cloudflare.com"]

TLS_INSPECT_HOSTS = [("www.youtube.com", 443), ("zoom.us", 443)]

SPEED_HOST = "speed.cloudflare.com"

# Firewall middleboxes that break RTMP and degrade Zoom to TCP fallback.
INSPECTION_VENDORS = [
    "palo" " alto", "fortinet", "fortigate", "zscaler", "blue coat", "bluecoat",
    "symantec web", "sophos", "sonicwall", "watchguard", "barracuda",
    "cisco umbrella", "forcepoint", "websense", "mcafee web", "netskope",
    "checkpoint", "check point", "untangle", "smoothwall", "lightspeed",
    "iboss", "securly", "meraki", "kaspersky", "eset", "bitdefender", "avast",
]

# --------------------------------------------------------------------------
# Encode profiles. bitrate_mbps = what you would actually configure in OBS/Zoom.
# --------------------------------------------------------------------------

YOUTUBE_PROFILES = [
    ("2160p60 (4K)", 51.0),
    ("2160p30 (4K)", 34.0),
    ("1440p60", 18.0),
    ("1080p60", 9.0),
    ("1080p30", 6.0),
    ("720p60", 6.0),
    ("720p30", 4.0),
    ("480p30", 2.0),
]

ZOOM_PROFILES = [
    # name, upload_mbps, download_mbps
    ("Webinar panelist 1080p", 3.8, 3.0),
    ("Webinar panelist 720p", 2.6, 2.6),
    ("Group meeting 1080p", 3.8, 3.8),
    ("Screen share + video", 2.0, 2.0),
    ("Webinar attendee (view only)", 0.15, 2.5),
]

AUDIO_OVERHEAD_MBPS = 0.128
GO_HEADROOM = 1.5      # want 50% margin over encode bitrate
CAUTION_HEADROOM = 1.2

# Realtime health thresholds (Zoom cares far more about these than raw speed)
RTT_GOOD, RTT_CAUTION = 100.0, 200.0
JITTER_GOOD, JITTER_CAUTION = 20.0, 40.0
LOSS_GOOD, LOSS_CAUTION = 1.0, 3.0

GO, CAUTION, NOGO = "GO", "CAUTION", "NO-GO"

# --------------------------------------------------------------------------
# Console
# --------------------------------------------------------------------------

USE_COLOR = True


def enable_ansi() -> None:
    """Turn on VT processing so ANSI colors work in conhost."""
    if os.name != "nt":
        return
    try:
        import ctypes

        k = ctypes.windll.kernel32
        for handle in (-11, -12):
            mode = ctypes.c_ulong()
            if k.GetConsoleMode(k.GetStdHandle(handle), ctypes.byref(mode)):
                k.SetConsoleMode(k.GetStdHandle(handle), mode.value | 0x0004)
    except Exception:
        pass


def c(text: str, color: str) -> str:
    if not USE_COLOR:
        return text
    codes = {
        "red": "31", "green": "32", "yellow": "33", "blue": "34",
        "magenta": "35", "cyan": "36", "grey": "90", "bold": "1",
    }
    return f"\033[{codes.get(color, '0')}m{text}\033[0m"


def status_tag(state: str) -> str:
    return {
        "ok": c("[ OK ]", "green"),
        "warn": c("[WARN]", "yellow"),
        "fail": c("[FAIL]", "red"),
        "info": c("[ -- ]", "grey"),
    }[state]


def line(state: str, label: str, detail: str = "") -> None:
    print(f"  {status_tag(state)} {label:<38} {detail}")


def header(title: str) -> None:
    print()
    print(c(f"== {title} " + "=" * max(0, 62 - len(title)), "bold"))


def verdict_color(v: str) -> str:
    return {GO: "green", CAUTION: "yellow", NOGO: "red"}[v]


# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------

def run_cmd(args, timeout=20):
    """Run a command, return stdout or '' on any failure."""
    try:
        p = subprocess.run(
            args, capture_output=True, timeout=timeout,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0) if os.name == "nt" else 0,
        )
        return p.stdout.decode("utf-8", "replace")
    except Exception:
        return ""


def recv_exactly(sock, n, deadline):
    buf = b""
    while len(buf) < n:
        if time.monotonic() > deadline:
            raise TimeoutError("handshake timed out")
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("peer closed early")
        buf += chunk
    return buf


def mbps(byte_count: float, seconds: float) -> float:
    if seconds <= 0:
        return 0.0
    return (byte_count * 8.0) / seconds / 1_000_000.0


def pct(x):
    return f"{x:.1f}%"


def fmt_mbps(x):
    return f"{x:.1f} Mbps" if x is not None else "measurement failed"


def throughput_line(label, result, suffix="", good_above=5.0):
    if not result.get("ok"):
        detail = result.get("errors", ["no data returned"])
        line("fail", label, f"failed - {detail[0] if detail else 'no data'}")
        return
    state = "ok" if result["mbps"] > good_above else "warn"
    line(state, label, f"{fmt_mbps(result['mbps'])}{suffix}")


# --------------------------------------------------------------------------
# Probe: local network + Wi-Fi
# --------------------------------------------------------------------------

def local_network() -> dict:
    info = {"hostname": socket.gethostname(), "platform": platform.platform()}
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("dns.google", 80))
        info["local_ip"] = s.getsockname()[0]
        s.close()
    except Exception:
        info["local_ip"] = None

    if os.name == "nt":
        out = run_cmd(["route", "print", "0.0.0.0"])
        m = re.search(r"0\.0\.0\.0\s+0\.0\.0\.0\s+(\S+)", out)
        info["gateway"] = m.group(1) if m else None

        out = run_cmd(["ipconfig", "/all"])
        dns = re.findall(r"DNS Servers[ .]*:\s*(\d+\.\d+\.\d+\.\d+)", out)
        extra = re.findall(r"^\s{20,}(\d+\.\d+\.\d+\.\d+)\s*$", out, re.M)
        info["dns_servers"] = list(dict.fromkeys(dns + extra))[:4]
    else:
        info["gateway"] = None
        info["dns_servers"] = []
    return info


def wifi_info() -> dict | None:
    """Wi-Fi radio details. Signal and channel matter as much as bandwidth."""
    if os.name != "nt":
        return None
    out = run_cmd(["netsh", "wlan", "show", "interfaces"])
    if "SSID" not in out:
        return None

    def grab(pattern):
        m = re.search(pattern + r"\s*:\s*(.+)", out)
        return m.group(1).strip() if m else None

    if (grab(r"^\s*State") or "").lower() not in ("connected",):
        return None

    signal = grab(r"^\s*Signal")
    wifi = {
        "ssid": grab(r"^\s*SSID"),
        "bssid": grab(r"^\s*BSSID"),
        "radio": grab(r"Radio type"),
        "band": grab(r"^\s*Band"),
        "channel": grab(r"^\s*Channel"),
        "signal": signal,
        "rx_rate": grab(r"Receive rate"),
        "tx_rate": grab(r"Transmit rate"),
        "auth": grab(r"Authentication"),
    }
    try:
        wifi["signal_pct"] = int(str(signal).rstrip("%"))
    except (TypeError, ValueError):
        wifi["signal_pct"] = None
    return wifi


# --------------------------------------------------------------------------
# Probe: internet identity + captive portal
# --------------------------------------------------------------------------

def https_json(host, path, timeout=8):
    conn = http.client.HTTPSConnection(host, timeout=timeout, context=ssl.create_default_context())
    try:
        conn.request("GET", path, headers={"User-Agent": f"arc-netcheck/{VERSION}"})
        resp = conn.getresponse()
        return json.loads(resp.read().decode("utf-8", "replace"))
    finally:
        conn.close()


def cloudflare_meta():
    """cdn-cgi/trace gives public IP, edge PoP and WARP/Gateway state as key=value."""
    try:
        conn = http.client.HTTPSConnection(
            "www.cloudflare.com", timeout=8, context=ssl.create_default_context()
        )
        try:
            conn.request("GET", "/cdn-cgi/trace",
                         headers={"User-Agent": f"arc-netcheck/{VERSION}"})
            body = conn.getresponse().read().decode("utf-8", "replace")
        finally:
            conn.close()
        meta = dict(
            l.split("=", 1) for l in body.splitlines() if "=" in l
        )
        return {
            "clientIp": meta.get("ip"),
            "colo": meta.get("colo"),
            "country": meta.get("loc"),
            "tls": meta.get("tls"),
            "warp": meta.get("warp"),
            "gateway": meta.get("gateway"),
        }
    except Exception as e:
        return {"error": str(e)}


def captive_portal_check():
    """204 with an empty body means clean egress. Anything else is interception."""
    try:
        conn = http.client.HTTPConnection("connectivitycheck.gstatic.com", timeout=8)
        conn.request("GET", "/generate_204", headers={"User-Agent": f"arc-netcheck/{VERSION}"})
        resp = conn.getresponse()
        body = resp.read(2048)
        conn.close()
        if resp.status == 204 and not body:
            return {"captive": False, "status": resp.status}
        return {
            "captive": True,
            "status": resp.status,
            "location": resp.getheader("Location"),
            "body_bytes": len(body),
        }
    except Exception as e:
        return {"captive": None, "error": str(e)}


# --------------------------------------------------------------------------
# Probe: DNS
# --------------------------------------------------------------------------

def dns_checks():
    results = []
    for host in DNS_HOSTS:
        t0 = time.monotonic()
        try:
            addrs = sorted({ai[4][0] for ai in socket.getaddrinfo(host, None, socket.AF_INET)})
            results.append({
                "host": host, "ok": True,
                "ms": (time.monotonic() - t0) * 1000.0,
                "addresses": addrs[:4],
            })
        except Exception as e:
            results.append({"host": host, "ok": False, "error": str(e),
                            "ms": (time.monotonic() - t0) * 1000.0})

    bogus = f"arc-netcheck-{os.urandom(6).hex()}.invalid"
    try:
        socket.getaddrinfo(bogus, None, socket.AF_INET)
        hijack = True
    except Exception:
        hijack = False
    return {"lookups": results, "nxdomain_hijack": hijack}


# --------------------------------------------------------------------------
# Probe: TCP reachability + handshake RTT
# --------------------------------------------------------------------------

def tcp_rtt(host, port, samples=5, timeout=5.0):
    """TCP handshake RTT. Works where ICMP is filtered, which is most campuses."""
    times, err = [], None
    for _ in range(samples):
        t0 = time.monotonic()
        try:
            s = socket.create_connection((host, port), timeout=timeout)
            times.append((time.monotonic() - t0) * 1000.0)
            s.close()
        except Exception as e:
            err = str(e)
        time.sleep(0.05)

    if not times:
        return {"host": host, "port": port, "open": False, "error": err,
                "loss_pct": 100.0, "samples": samples}

    jitter = 0.0
    if len(times) > 1:
        jitter = statistics.mean(abs(b - a) for a, b in zip(times, times[1:]))

    return {
        "host": host, "port": port, "open": True,
        "min_ms": min(times), "avg_ms": statistics.mean(times), "max_ms": max(times),
        "jitter_ms": jitter,
        "loss_pct": (samples - len(times)) / samples * 100.0,
        "samples": samples, "succeeded": len(times),
    }


def icmp_ping(host, count=10):
    """Secondary signal only. Plenty of venues drop ICMP but pass traffic fine."""
    if os.name == "nt":
        out = run_cmd(["ping", "-n", str(count), "-w", "2000", host], timeout=count * 3 + 15)
    else:
        out = run_cmd(["ping", "-c", str(count), "-W", "2", host], timeout=count * 3 + 15)
    if not out:
        return {"host": host, "available": False}

    rtts = [float(x) for x in re.findall(r"time[=<]\s?([\d.]+)\s?ms", out)]
    rtts += [0.5] * len(re.findall(r"time<1\s?ms", out))
    m = re.search(r"\((\d+)% (?:loss|packet loss)\)", out) or re.search(r"([\d.]+)% packet loss", out)
    loss = float(m.group(1)) if m else (count - len(rtts)) / count * 100.0

    if not rtts:
        return {"host": host, "available": False, "loss_pct": 100.0}
    return {
        "host": host, "available": True, "loss_pct": loss,
        "min_ms": min(rtts), "avg_ms": statistics.mean(rtts), "max_ms": max(rtts),
        "jitter_ms": statistics.mean(abs(b - a) for a, b in zip(rtts, rtts[1:])) if len(rtts) > 1 else 0.0,
        "count": len(rtts),
    }


# --------------------------------------------------------------------------
# Probe: STUN (proves UDP egress - the single biggest Zoom quality factor)
# --------------------------------------------------------------------------

def stun_binding(host, port, timeout=3.0):
    txid = os.urandom(12)
    packet = struct.pack(">HHI", 0x0001, 0, 0x2112A442) + txid
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    t0 = time.monotonic()
    try:
        s.sendto(packet, (host, port))
        data, _ = s.recvfrom(2048)
    except Exception as e:
        return {"host": host, "port": port, "udp_ok": False, "error": str(e)}
    finally:
        s.close()

    rtt = (time.monotonic() - t0) * 1000.0
    if len(data) < 20 or data[8:20] != txid:
        return {"host": host, "port": port, "udp_ok": False, "error": "bad STUN response"}

    msg_type, msg_len = struct.unpack(">HH", data[:4])
    if msg_type != 0x0101:
        return {"host": host, "port": port, "udp_ok": False, "error": f"STUN type 0x{msg_type:04x}"}

    mapped, i, end = None, 20, min(20 + msg_len, len(data))
    while i + 4 <= end:
        atype, alen = struct.unpack(">HH", data[i:i + 4])
        val = data[i + 4:i + 4 + alen]
        if atype == 0x0020 and len(val) >= 8 and val[1] == 0x01:   # XOR-MAPPED-ADDRESS, IPv4
            xport = struct.unpack(">H", val[2:4])[0] ^ 0x2112
            xip = bytes(a ^ b for a, b in zip(val[4:8], struct.pack(">I", 0x2112A442)))
            mapped = f"{socket.inet_ntoa(xip)}:{xport}"
            break
        i += 4 + alen + (-alen % 4)

    return {"host": host, "port": port, "udp_ok": True, "rtt_ms": rtt, "mapped": mapped}


# --------------------------------------------------------------------------
# Probe: real RTMP handshake (an open port is not the same as a working path)
# --------------------------------------------------------------------------

def rtmp_handshake(host, port, use_tls=False, timeout=10.0):
    deadline = time.monotonic() + timeout
    result = {"host": host, "port": port, "tls": use_tls}
    sock = None
    try:
        t0 = time.monotonic()
        sock = socket.create_connection((host, port), timeout=timeout)
        result["connect_ms"] = (time.monotonic() - t0) * 1000.0

        if use_tls:
            ctx = ssl.create_default_context()
            sock = ctx.wrap_socket(sock, server_hostname=host)
            result["tls_version"] = sock.version()
            cert = sock.getpeercert() or {}
            issuer = {k: v for part in cert.get("issuer", ()) for k, v in part}
            result["tls_issuer"] = issuer.get("organizationName") or issuer.get("commonName")

        sock.settimeout(max(1.0, deadline - time.monotonic()))
        sock.sendall(b"\x03" + struct.pack(">II", 0, 0) + os.urandom(1528))  # C0 + C1

        s0s1 = recv_exactly(sock, 1537, deadline)
        if s0s1[0] != 3:
            result.update(reachable=True, handshake=False,
                          error=f"unexpected RTMP version 0x{s0s1[0]:02x}")
            return result

        sock.sendall(s0s1[1:])                 # C2 echoes S1
        recv_exactly(sock, 1536, deadline)     # S2
        result.update(reachable=True, handshake=True)
        return result
    except Exception as e:
        result.setdefault("reachable", "connect_ms" in result)
        result.update(handshake=False, error=f"{type(e).__name__}: {e}")
        return result
    finally:
        if sock:
            try:
                sock.close()
            except Exception:
                pass


# --------------------------------------------------------------------------
# Probe: TLS inspection / MITM detection
# --------------------------------------------------------------------------

def tls_inspection(host, port=443, timeout=8.0):
    result = {"host": host, "port": port}
    try:
        ctx = ssl.create_default_context()
        with socket.create_connection((host, port), timeout=timeout) as raw:
            with ctx.wrap_socket(raw, server_hostname=host) as s:
                cert = s.getpeercert() or {}
                issuer = {k: v for part in cert.get("issuer", ()) for k, v in part}
                org = issuer.get("organizationName") or issuer.get("commonName") or "unknown"
                result.update(verified=True, tls_version=s.version(), issuer=org)
    except ssl.SSLCertVerificationError as e:
        result.update(verified=False, inspected=True,
                      error=f"certificate verification failed: {e.verify_message or e}")
        return result
    except Exception as e:
        result.update(verified=None, error=f"{type(e).__name__}: {e}")
        return result

    low = result["issuer"].lower()
    vendor = next((v for v in INSPECTION_VENDORS if v in low), None)
    expected = ("google", "digicert", "amazon", "let's encrypt", "sectigo",
                "globalsign", "entrust", "identrust", "cloudflare")
    result["inspected"] = bool(vendor) or not any(e in low for e in expected)
    result["vendor"] = vendor
    return result


# --------------------------------------------------------------------------
# Probe: throughput via Cloudflare speed endpoints
# --------------------------------------------------------------------------

class Counter:
    def __init__(self):
        self._n = 0
        self._lock = threading.Lock()

    def add(self, n):
        with self._lock:
            self._n += n

    @property
    def value(self):
        with self._lock:
            return self._n


def _speed_conn(timeout):
    return http.client.HTTPSConnection(
        SPEED_HOST, timeout=timeout, context=ssl.create_default_context()
    )


def _download_worker(counter, deadline, chunk_bytes, errors):
    conn = None
    chunk = chunk_bytes
    throttled = 0
    while time.monotonic() < deadline:
        try:
            if conn is None:
                conn = _speed_conn(20)
            conn.request("GET", f"/__down?bytes={chunk}",
                         headers={"User-Agent": f"arc-netcheck/{VERSION}"})
            resp = conn.getresponse()
            if resp.status == 429:
                # Cloudflare caps large single transfers. Shrink and keep going
                # rather than burning the whole window on rejected requests.
                resp.read()
                throttled += 1
                chunk = max(262_144, chunk // 2)
                errors.append(f"HTTP 429 from /__down - chunk reduced to {chunk}")
                time.sleep(min(1.0, 0.15 * throttled))
                continue
            if resp.status != 200:
                resp.read()
                errors.append(f"HTTP {resp.status} from /__down")
                conn.close()
                conn = None
                time.sleep(0.3)
                continue
            throttled = 0
            while True:
                block = resp.read(65536)
                if not block:
                    break
                counter.add(len(block))
                if time.monotonic() > deadline:
                    resp.read()
                    break
            if resp.getheader("Connection", "").lower() == "close":
                conn.close()
                conn = None
        except Exception as e:
            errors.append(str(e))
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass
            conn = None
            if time.monotonic() < deadline:
                time.sleep(0.2)
    if conn:
        try:
            conn.close()
        except Exception:
            pass


def _upload_worker(counter, deadline, payload, errors):
    conn = None
    headers = {
        "Content-Type": "application/octet-stream",
        "User-Agent": f"arc-netcheck/{VERSION}",
        "Content-Length": str(len(payload)),
    }
    while time.monotonic() < deadline:
        try:
            if conn is None:
                conn = _speed_conn(30)
            conn.request("POST", "/__up", body=payload, headers=headers)
            resp = conn.getresponse()
            resp.read()
            if resp.status not in (200, 204):
                errors.append(f"HTTP {resp.status} from /__up")
                conn.close()
                conn = None
                time.sleep(1.0 if resp.status == 429 else 0.3)
                continue
            # Only count bytes the far end actually acknowledged.
            counter.add(len(payload))
            if resp.getheader("Connection", "").lower() == "close":
                conn.close()
                conn = None
        except Exception as e:
            errors.append(str(e))
            if conn:
                try:
                    conn.close()
                except Exception:
                    pass
            conn = None
            if time.monotonic() < deadline:
                time.sleep(0.2)
    if conn:
        try:
            conn.close()
        except Exception:
            pass


def calibrate_upload_chunk(probe_bytes=1_000_000):
    """Size each POST to land near 2s so slow links still produce samples."""
    payload = os.urandom(probe_bytes)
    try:
        conn = _speed_conn(30)
        t0 = time.monotonic()
        conn.request("POST", "/__up", body=payload, headers={
            "Content-Type": "application/octet-stream",
            "Content-Length": str(probe_bytes),
        })
        conn.getresponse().read()
        elapsed = max(0.05, time.monotonic() - t0)
        conn.close()
        rate = probe_bytes / elapsed
        return int(min(32_000_000, max(262_144, rate * 2)))
    except Exception:
        return 2_000_000


def measure_throughput(direction, duration, streams, chunk_bytes=None):
    counter, errors = Counter(), []
    if direction == "up":
        chunk = chunk_bytes or calibrate_upload_chunk()
        payload = os.urandom(chunk)
        worker, arg = _upload_worker, payload
    else:
        chunk = chunk_bytes or 4_000_000
        worker, arg = _download_worker, chunk

    deadline = time.monotonic() + duration
    t0 = time.monotonic()
    with concurrent.futures.ThreadPoolExecutor(max_workers=streams) as pool:
        futures = [pool.submit(worker, counter, deadline, arg, errors) for _ in range(streams)]
        concurrent.futures.wait(futures)
    elapsed = time.monotonic() - t0
    total = counter.value

    # Under a few hundred KB the far end rejected us (rate limit, portal, proxy).
    # Report that honestly instead of passing a fake 0 Mbps into the verdict.
    ok = total >= 200_000
    return {
        "direction": direction, "streams": streams,
        "bytes": total, "seconds": elapsed,
        "ok": ok,
        "mbps": mbps(total, elapsed) if ok else None,
        "chunk_bytes": chunk,
        "errors": errors[:5], "error_count": len(errors),
    }


# --------------------------------------------------------------------------
# Verdict engine
# --------------------------------------------------------------------------

def realtime_health(rtt_ms, jitter_ms, loss_pct):
    """Zoom lives or dies on these three, not on raw bandwidth."""
    notes, worst = [], GO

    def demote(level, note):
        nonlocal worst
        notes.append(note)
        if level == NOGO or worst == NOGO:
            worst = NOGO
        elif level == CAUTION and worst == GO:
            worst = CAUTION

    if rtt_ms is None:
        demote(CAUTION, "latency could not be measured")
    elif rtt_ms > RTT_CAUTION:
        demote(NOGO, f"latency {rtt_ms:.0f} ms is too high for interactive video")
    elif rtt_ms > RTT_GOOD:
        demote(CAUTION, f"latency {rtt_ms:.0f} ms is elevated")

    if jitter_ms is not None:
        if jitter_ms > JITTER_CAUTION:
            demote(NOGO, f"jitter {jitter_ms:.0f} ms will cause audio artifacts")
        elif jitter_ms > JITTER_GOOD:
            demote(CAUTION, f"jitter {jitter_ms:.0f} ms is marginal")

    if loss_pct is not None:
        if loss_pct > LOSS_CAUTION:
            demote(NOGO, f"packet loss {pct(loss_pct)} will break video")
        elif loss_pct > LOSS_GOOD:
            demote(CAUTION, f"packet loss {pct(loss_pct)} is noticeable")

    return worst, notes


def bandwidth_verdict(available_mbps, required_mbps):
    if available_mbps is None:
        return CAUTION
    if available_mbps >= required_mbps * GO_HEADROOM:
        return GO
    if available_mbps >= required_mbps * CAUTION_HEADROOM:
        return CAUTION
    return NOGO


def combine(*verdicts):
    if NOGO in verdicts:
        return NOGO
    if CAUTION in verdicts:
        return CAUTION
    return GO


def build_verdicts(results):
    up = (results.get("throughput", {}).get("upload_single") or {}).get("mbps")
    down = (results.get("throughput", {}).get("download") or {}).get("mbps")

    all_tcp = results.get("tcp", [])
    open_tcp = [r for r in all_tcp if r.get("open")]

    # RTT to the services themselves; min_ms strips queuing noise from each target.
    rtt = statistics.median([r["min_ms"] for r in open_tcp]) if open_tcp else None
    tcp_jitter = statistics.median([r["jitter_ms"] for r in open_tcp]) if open_tcp else None
    tcp_loss = statistics.mean([r.get("loss_pct", 0.0) for r in all_tcp]) if all_tcp else None

    # TCP handshake timing includes server accept latency, so it overstates jitter.
    # Prefer ICMP where the venue allows it; fall back to TCP only when it does not.
    ping = results.get("ping") or {}
    if ping.get("available"):
        jitter = ping.get("jitter_ms")
        loss = max(ping.get("loss_pct", 0.0), tcp_loss or 0.0)
        jitter_source = "icmp"
    else:
        jitter = tcp_jitter
        loss = tcp_loss
        jitter_source = "tcp-handshake"

    health, health_notes = realtime_health(rtt, jitter, loss)
    if jitter_source == "tcp-handshake" and jitter is not None:
        health_notes.append("jitter estimated from TCP handshakes (ICMP filtered) - treat as approximate")

    # --- YouTube ---
    rtmp_ok = any(r.get("handshake") for r in results.get("rtmp", []))
    yt_rows = []
    for name, bitrate in YOUTUBE_PROFILES:
        need = bitrate + AUDIO_OVERHEAD_MBPS
        v = bandwidth_verdict(up, need)
        if not rtmp_ok:
            v = NOGO
        yt_rows.append({
            "profile": name, "required_mbps": need,
            "headroom_mbps": need * GO_HEADROOM,
            "verdict": v,
        })

    best_yt = next((r for r in yt_rows if r["verdict"] == GO), None)

    # --- Zoom ---
    udp_ok = any(s.get("udp_ok") for s in results.get("stun", []))
    zoom_rows = []
    for name, need_up, need_down in ZOOM_PROFILES:
        v = combine(bandwidth_verdict(up, need_up), bandwidth_verdict(down, need_down), health)
        if not udp_ok and v == GO:
            v = CAUTION
        zoom_rows.append({
            "profile": name, "required_up_mbps": need_up,
            "required_down_mbps": need_down, "verdict": v,
        })

    blockers = []
    if not rtmp_ok:
        blockers.append("No working RTMP/RTMPS path to YouTube - streaming will fail.")
    if not udp_ok:
        blockers.append("UDP egress blocked - Zoom will fall back to TCP/443 with worse quality.")
    if results.get("captive", {}).get("captive"):
        blockers.append("Captive portal detected - authenticate before the event and expect timed logouts.")
    if results.get("dns", {}).get("nxdomain_hijack"):
        blockers.append("DNS returns addresses for nonexistent domains - a filtering resolver is in path.")
    for t in results.get("tls", []):
        if t.get("inspected"):
            v = t.get("vendor") or t.get("issuer") or "unknown"
            blockers.append(f"TLS inspection on {t['host']} (issuer: {v}) - breaks RTMPS and degrades Zoom.")

    if up is None or down is None:
        blockers.append("Throughput measurement failed - rerun; if it keeps failing, a proxy "
                        "is intercepting HTTPS to speed.cloudflare.com.")

    zoom_baseline = next((r["verdict"] for r in zoom_rows
                          if r["profile"] == "Webinar panelist 720p"), CAUTION)

    return {
        "measured": {"upload_mbps": up, "download_mbps": down,
                     "rtt_ms": rtt, "jitter_ms": jitter, "loss_pct": loss,
                     "jitter_source": jitter_source},
        "realtime_health": health,
        "health_notes": health_notes,
        "youtube": yt_rows,
        "youtube_best": best_yt["profile"] if best_yt else None,
        "zoom": zoom_rows,
        "blockers": blockers,
        "overall": combine(
            health,
            GO if rtmp_ok else NOGO,
            GO if best_yt else CAUTION,
            zoom_baseline,
            GO if (up is not None and down is not None) else CAUTION,
        ),
    }


# --------------------------------------------------------------------------
# Runner
# --------------------------------------------------------------------------

def run_check(args):
    quick = args.mode == "quick"
    results = {
        "tool": "arc-netcheck", "version": VERSION,
        "label": args.label,
        "started": datetime.now(timezone.utc).isoformat(),
        "mode": args.mode,
    }

    print()
    print(c(f"  arc-netcheck {VERSION}  -  YouTube Live + Zoom webinar readiness", "bold"))
    if args.label:
        print(c(f"  site: {args.label}", "cyan"))
    print(c(f"  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}  ({args.mode} mode)", "grey"))

    # ---- Local ----
    header("Local network")
    results["local"] = local_network()
    loc = results["local"]
    line("info", "Host", f"{loc['hostname']}  ({loc.get('local_ip') or 'no IP'})")
    line("info", "Gateway", loc.get("gateway") or "unknown")
    line("info", "DNS servers", ", ".join(loc.get("dns_servers") or []) or "unknown")

    results["wifi"] = wifi_info()
    if results["wifi"]:
        w = results["wifi"]
        sig = w.get("signal_pct")
        state = "ok" if (sig or 0) >= 70 else "warn" if (sig or 0) >= 50 else "fail"
        line(state, "Wi-Fi signal", f"{w.get('signal')}  ({w.get('radio')}, ch {w.get('channel')})")
        line("info", "Wi-Fi SSID", f"{w.get('ssid')}  [{w.get('bssid')}]")
        line("info", "Wi-Fi link rate", f"tx {w.get('tx_rate')} Mbps / rx {w.get('rx_rate')} Mbps")
        if (sig or 100) < 70:
            line("warn", "Wi-Fi advisory", "use wired uplink for the encoder if at all possible")
    else:
        line("info", "Wi-Fi", "not connected (wired or adapter off)")

    # ---- Internet identity ----
    header("Internet path")
    results["captive"] = captive_portal_check()
    cap = results["captive"]
    if cap.get("captive") is True:
        line("fail", "Captive portal", f"HTTP {cap.get('status')} -> {cap.get('location') or 'intercepted'}")
    elif cap.get("captive") is False:
        line("ok", "Captive portal", "none - clean egress")
    else:
        line("warn", "Captive portal", cap.get("error", "unknown"))

    results["meta"] = cloudflare_meta()
    meta = results["meta"]
    if "error" not in meta:
        line("ok", "Public IP", f"{meta.get('clientIp')}  ({meta.get('country')})")
        line("info", "Edge PoP", f"{meta.get('colo')}  TLS {meta.get('tls')}")
        if meta.get("warp") not in (None, "off"):
            line("warn", "Cloudflare WARP", f"{meta.get('warp')} - VPN in path will skew results")
        if meta.get("gateway") not in (None, "off"):
            line("warn", "Cloudflare Gateway", f"{meta.get('gateway')} - filtering proxy in path")
    else:
        line("fail", "Public IP", meta["error"])

    # ---- DNS ----
    header("DNS")
    results["dns"] = dns_checks()
    for r in results["dns"]["lookups"]:
        if r["ok"]:
            state = "ok" if r["ms"] < 100 else "warn"
            line(state, r["host"], f"{r['ms']:.0f} ms -> {', '.join(r['addresses'])}")
        else:
            line("fail", r["host"], r.get("error", "lookup failed"))
    if results["dns"]["nxdomain_hijack"]:
        line("warn", "NXDOMAIN handling", "hijacked - resolver answers for bogus names")
    else:
        line("ok", "NXDOMAIN handling", "correct")

    # ---- TCP reachability ----
    header("Endpoint reachability (TCP)")
    samples = 3 if quick else 5
    results["tcp"] = []
    targets = YOUTUBE_INGEST + ZOOM_TCP
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        futs = {pool.submit(tcp_rtt, h, p, samples): (h, p, d) for h, p, d in targets}
        for fut in concurrent.futures.as_completed(futs):
            host, port, desc = futs[fut]
            r = fut.result()
            r["description"] = desc
            results["tcp"].append(r)
    results["tcp"].sort(key=lambda r: (r["port"], r["host"]))
    for r in results["tcp"]:
        label = f"{r['host']}:{r['port']}"
        if r["open"]:
            line("ok", label, f"{r['avg_ms']:.0f} ms avg, jitter {r['jitter_ms']:.0f} ms  ({r['description']})")
        else:
            line("fail", label, f"BLOCKED - {r.get('error', 'no route')}  ({r['description']})")

    # ---- UDP / STUN ----
    header("UDP egress (Zoom media)")
    results["stun"] = []
    for host, port, desc in STUN_TARGETS:
        r = stun_binding(host, port)
        r["description"] = desc
        results["stun"].append(r)
        if r["udp_ok"]:
            line("ok", f"{host}:{port}", f"{r['rtt_ms']:.0f} ms, mapped {r.get('mapped')}  ({desc})")
        else:
            line("fail", f"{host}:{port}", f"no UDP reply - {r.get('error')}  ({desc})")
    if not any(s["udp_ok"] for s in results["stun"]):
        line("fail", "UDP verdict", "Zoom will fall back to TCP - expect audio drops under load")
    else:
        line("ok", "UDP verdict", "Zoom can use UDP media (preferred path)")
    line("info", "UDP 8801-8810", "not directly testable - confirm with a live Zoom call on site")

    # ---- RTMP ----
    header("YouTube RTMP handshake")
    results["rtmp"] = []
    for host, port, desc in YOUTUBE_INGEST:
        r = rtmp_handshake(host, port, use_tls=(port == 443))
        r["description"] = desc
        results["rtmp"].append(r)
        label = f"{host}:{port}"
        if r.get("handshake"):
            extra = f", TLS {r.get('tls_version')}" if r.get("tls") else ""
            line("ok", label, f"handshake OK ({r['connect_ms']:.0f} ms{extra})  ({desc})")
        elif r.get("reachable"):
            line("warn", label, f"port open but handshake failed - {r.get('error')}")
        else:
            line("fail", label, f"unreachable - {r.get('error')}")

    # ---- TLS inspection ----
    header("TLS integrity")
    results["tls"] = []
    for host, port in TLS_INSPECT_HOSTS:
        r = tls_inspection(host, port)
        results["tls"].append(r)
        if r.get("verified") and not r.get("inspected"):
            line("ok", host, f"{r.get('tls_version')}, issuer {r.get('issuer')}")
        elif r.get("inspected"):
            line("fail", host, f"INSPECTED - issuer {r.get('issuer') or r.get('error')}")
        else:
            line("warn", host, r.get("error", "unknown"))

    # ---- Latency ----
    header("Latency")
    results["ping"] = icmp_ping("one.one.one.one", count=5 if quick else 10)
    p = results["ping"]
    if p.get("available"):
        state = "ok" if p["avg_ms"] < RTT_GOOD and p["loss_pct"] < LOSS_GOOD else "warn"
        line(state, "ICMP one.one.one.one",
             f"{p['avg_ms']:.0f} ms avg, {p['min_ms']:.0f}-{p['max_ms']:.0f} ms, "
             f"jitter {p['jitter_ms']:.0f} ms, loss {pct(p['loss_pct'])}")
    else:
        line("info", "ICMP one.one.one.one", "no reply (commonly filtered - not a fault by itself)")

    # ---- Throughput ----
    header("Throughput")
    dur = 5 if quick else args.duration
    results["throughput"] = {}

    print(c(f"  measuring download ({dur}s, {args.streams} streams)...", "grey"))
    results["throughput"]["download"] = measure_throughput("down", dur, args.streams)
    throughput_line("Download (multi-stream)", results["throughput"]["download"])

    print(c(f"  measuring upload ({dur}s, {args.streams} streams)...", "grey"))
    results["throughput"]["upload_multi"] = measure_throughput("up", dur, args.streams)
    um = results["throughput"]["upload_multi"]
    throughput_line("Upload (multi-stream)", um, suffix="  [link capacity]")

    print(c(f"  measuring upload ({dur}s, single stream)...", "grey"))
    results["throughput"]["upload_single"] = measure_throughput(
        "up", dur, 1, chunk_bytes=um.get("chunk_bytes")
    )
    us = results["throughput"]["upload_single"]
    throughput_line("Upload (single stream)", us, suffix="  [what OBS/RTMP actually gets]")

    if um.get("ok") and us.get("ok") and us["mbps"] < um["mbps"] * 0.6:
        line("warn", "Single-stream shaping",
             f"one connection gets only {us['mbps'] / um['mbps'] * 100:.0f}% of capacity")

    results["verdict"] = build_verdicts(results)
    results["finished"] = datetime.now(timezone.utc).isoformat()
    return results


def run_soak(args):
    """Repeated sampling. Venue networks look great empty and fall apart at showtime."""
    print()
    print(c(f"  arc-netcheck soak  -  {args.minutes} min, sampling every {args.interval}s", "bold"))
    if args.label:
        print(c(f"  site: {args.label}", "cyan"))
    print(c("  Ctrl-C to stop early and write the report.", "grey"))
    print()
    print(f"  {'time':<10} {'up Mbps':>9} {'down Mbps':>10} {'rtt ms':>8} {'jitter':>8} {'loss':>7}")
    print(f"  {'-' * 10} {'-' * 9:>9} {'-' * 10:>10} {'-' * 8:>8} {'-' * 8:>8} {'-' * 7:>7}")

    samples = []
    end = time.monotonic() + args.minutes * 60
    chunk = None
    try:
        while time.monotonic() < end:
            t_sample = datetime.now()
            rtt_probe = tcp_rtt("a.rtmp.youtube.com", 1935, samples=5)
            up = measure_throughput("up", args.sample_seconds, 1, chunk_bytes=chunk)
            chunk = up.get("chunk_bytes")
            down = measure_throughput("down", args.sample_seconds, 2)

            s = {
                "t": t_sample.isoformat(),
                "up_mbps": up.get("mbps"), "down_mbps": down.get("mbps"),
                "rtt_ms": rtt_probe.get("avg_ms"),
                "jitter_ms": rtt_probe.get("jitter_ms"),
                "loss_pct": rtt_probe.get("loss_pct", 0.0),
            }
            samples.append(s)

            worst = "green"
            if s["loss_pct"] > LOSS_GOOD or (s["rtt_ms"] or 0) > RTT_GOOD:
                worst = "yellow"
            if s["loss_pct"] > LOSS_CAUTION or (s["rtt_ms"] or 0) > RTT_CAUTION:
                worst = "red"
            if s["up_mbps"] is None or s["down_mbps"] is None:
                worst = "red"

            def col(v):
                return f"{v:>9.1f}" if v is not None else f"{'FAIL':>9}"

            print(c(
                f"  {t_sample.strftime('%H:%M:%S'):<10} {col(s['up_mbps'])} {col(s['down_mbps']):>10} "
                f"{(s['rtt_ms'] or 0):>8.0f} {(s['jitter_ms'] or 0):>8.0f} {s['loss_pct']:>6.1f}%",
                worst))

            sleep_for = args.interval - (2 * args.sample_seconds)
            if sleep_for > 0 and time.monotonic() + sleep_for < end:
                time.sleep(sleep_for)
    except KeyboardInterrupt:
        print(c("\n  stopped early by user", "yellow"))

    if not samples:
        print(c("  no samples collected", "red"))
        return {"tool": "arc-netcheck", "mode": "soak", "samples": []}

    ups = [s["up_mbps"] for s in samples if s["up_mbps"] is not None]
    downs = [s["down_mbps"] for s in samples if s["down_mbps"] is not None]
    rtts = [s["rtt_ms"] for s in samples if s["rtt_ms"] is not None]
    losses = [s["loss_pct"] for s in samples]
    failed = sum(1 for s in samples if s["up_mbps"] is None or s["down_mbps"] is None)

    if not ups:
        header("Soak summary")
        line("fail", "Upload", f"every sample failed ({len(samples)} attempts)")
        return {"tool": "arc-netcheck", "version": VERSION, "mode": "soak",
                "label": args.label, "samples": samples,
                "summary": {"upload_all_failed": True, "samples": len(samples)}}

    header("Soak summary")
    line("info", "Samples", f"{len(samples)}  ({failed} partial/failed)" if failed else str(len(samples)))
    line("info", "Upload  min / median / max",
         f"{min(ups):.1f} / {statistics.median(ups):.1f} / {max(ups):.1f} Mbps")
    if downs:
        line("info", "Download min / median / max",
             f"{min(downs):.1f} / {statistics.median(downs):.1f} / {max(downs):.1f} Mbps")
    else:
        line("warn", "Download", "all download samples failed (upstream rate limit or proxy)")
    if rtts:
        line("info", "RTT min / median / max",
             f"{min(rtts):.0f} / {statistics.median(rtts):.0f} / {max(rtts):.0f} ms")
    line("info", "Worst loss", pct(max(losses)))

    med_up = statistics.median(ups)
    if min(ups) < med_up * 0.5:
        line("warn", "Stability", f"upload dipped to {min(ups):.1f} Mbps ({min(ups) / med_up * 100:.0f}% of median)")
    else:
        line("ok", "Stability", "no significant upload dips")

    # Plan against the sustained floor, not the peak.
    floor = min(ups)
    line("info", "Plan against", f"{floor:.1f} Mbps sustained upload floor")
    safe = [n for n, b in YOUTUBE_PROFILES if floor >= (b + AUDIO_OVERHEAD_MBPS) * GO_HEADROOM]
    line("ok" if safe else "fail", "Safe YouTube profile",
         safe[0] if safe else "none - upload floor too low for reliable streaming")

    return {
        "tool": "arc-netcheck", "version": VERSION, "mode": "soak",
        "label": args.label, "samples": samples,
        "summary": {
            "upload_min": min(ups), "upload_median": med_up, "upload_max": max(ups),
            "download_min": min(downs) if downs else None,
            "download_median": statistics.median(downs) if downs else None,
            "rtt_median": statistics.median(rtts) if rtts else None,
            "worst_loss_pct": max(losses),
            "failed_samples": failed,
            "safe_youtube_profile": safe[0] if safe else None,
        },
    }


# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------

def print_verdict(results):
    v = results["verdict"]
    m = v["measured"]

    header("VERDICT")
    parts = [
        "Upload " + (c(f"{m['upload_mbps']:.1f} Mbps", "bold") if m["upload_mbps"] else "n/a"),
        "Download " + (c(f"{m['download_mbps']:.1f} Mbps", "bold") if m["download_mbps"] else "n/a"),
        "RTT " + (f"{m['rtt_ms']:.0f} ms" if m["rtt_ms"] else "n/a"),
        "jitter " + (f"{m['jitter_ms']:.0f} ms" if m["jitter_ms"] is not None else "n/a"),
        "loss " + (pct(m["loss_pct"]) if m["loss_pct"] is not None else "n/a"),
    ]
    print("  " + "   ".join(parts))
    print(f"  Realtime health: {c(v['realtime_health'], verdict_color(v['realtime_health']))}")
    for note in v["health_notes"]:
        print(c(f"    - {note}", "yellow"))

    print()
    print(c("  YouTube Live", "bold"))
    for row in v["youtube"]:
        tag = c(f"{row['verdict']:<7}", verdict_color(row["verdict"]))
        print(f"    {tag} {row['profile']:<16} needs {row['required_mbps']:.1f} Mbps "
              f"(+50% = {row['headroom_mbps']:.1f})")
    print(f"  -> recommended: {c(v['youtube_best'] or 'do not stream', verdict_color(GO if v['youtube_best'] else NOGO))}")

    print()
    print(c("  Zoom", "bold"))
    for row in v["zoom"]:
        tag = c(f"{row['verdict']:<7}", verdict_color(row["verdict"]))
        print(f"    {tag} {row['profile']:<30} needs {row['required_up_mbps']:.1f} up / "
              f"{row['required_down_mbps']:.1f} down")

    if v["blockers"]:
        print()
        print(c("  BLOCKERS", "red"))
        for b in v["blockers"]:
            print(c(f"    ! {b}", "red"))

    print()
    print(f"  OVERALL: {c(v['overall'], verdict_color(v['overall']))}")
    print()


def write_markdown(results, path):
    v = results.get("verdict")
    lines = [
        f"# Network readiness report{' - ' + results['label'] if results.get('label') else ''}",
        "",
        f"- Tool: arc-netcheck {results.get('version', VERSION)}",
        f"- Run: {results.get('started')}",
        f"- Mode: {results.get('mode')}",
        "",
    ]

    if results.get("mode") == "soak":
        s = results.get("summary", {})

        def num(key, fmt="{:.1f}"):
            val = s.get(key)
            return fmt.format(val) if isinstance(val, (int, float)) else "n/a"

        lines += [
            "## Sustained performance",
            "",
            "| Metric | Value |",
            "|---|---|",
            f"| Upload min / median / max | {num('upload_min')} / {num('upload_median')} / {num('upload_max')} Mbps |",
            f"| Download min / median | {num('download_min')} / {num('download_median')} Mbps |",
            f"| Median RTT | {num('rtt_median', '{:.0f}')} ms |",
            f"| Worst packet loss | {num('worst_loss_pct')}% |",
            f"| Failed samples | {s.get('failed_samples', 0)} |",
            f"| Safe YouTube profile | {s.get('safe_youtube_profile') or 'none'} |",
            f"| Samples | {len(results.get('samples', []))} |",
            "",
        ]
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines))
        return

    m = v["measured"]
    lines += [
        "## Summary",
        "",
        f"**Overall: {v['overall']}**",
        "",
        "| Metric | Value |",
        "|---|---|",
        f"| Upload (single stream) | {m['upload_mbps']:.1f} Mbps |" if m["upload_mbps"] else "| Upload | n/a |",
        f"| Download | {m['download_mbps']:.1f} Mbps |" if m["download_mbps"] else "| Download | n/a |",
        f"| RTT | {m['rtt_ms']:.0f} ms |" if m["rtt_ms"] else "| RTT | n/a |",
        f"| Jitter | {m['jitter_ms']:.0f} ms |" if m["jitter_ms"] else "| Jitter | n/a |",
        f"| Packet loss | {m['loss_pct']:.1f}% |" if m["loss_pct"] is not None else "| Loss | n/a |",
        f"| Recommended YouTube profile | {v['youtube_best'] or 'do not stream'} |",
        "",
    ]

    if v["blockers"]:
        lines += ["## Blockers", ""]
        lines += [f"- {b}" for b in v["blockers"]]
        lines.append("")

    lines += ["## YouTube Live profiles", "", "| Profile | Needs | Verdict |", "|---|---|---|"]
    for row in v["youtube"]:
        lines.append(f"| {row['profile']} | {row['required_mbps']:.1f} Mbps | {row['verdict']} |")
    lines.append("")

    lines += ["## Zoom profiles", "", "| Profile | Up | Down | Verdict |", "|---|---|---|---|"]
    for row in v["zoom"]:
        lines.append(f"| {row['profile']} | {row['required_up_mbps']:.1f} | "
                     f"{row['required_down_mbps']:.1f} | {row['verdict']} |")
    lines.append("")

    blocked = [r for r in results.get("tcp", []) if not r.get("open")]
    lines += ["## Requests for venue IT", ""]
    if blocked:
        lines.append("Please permit outbound access from the production VLAN to:")
        lines.append("")
        for r in blocked:
            lines.append(f"- `{r['host']}:{r['port']}` (TCP) - {r.get('description', '')}")
    if not any(s.get("udp_ok") for s in results.get("stun", [])):
        lines.append("- UDP 3478-3479 and UDP 8801-8810 outbound to Zoom (`*.zoom.us`)")
    if any(t.get("inspected") for t in results.get("tls", [])):
        lines.append("- Bypass TLS inspection for `*.youtube.com`, `*.googlevideo.com`, `*.zoom.us` "
                     "(inspection breaks RTMPS ingest)")
    if not blocked and not lines[-1].startswith("-"):
        lines.append("No firewall changes required - all tested endpoints reachable.")
    lines.append("")

    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        prog="netcheck",
        description="Venue network readiness for YouTube Live and Zoom webinar streams.",
    )
    sub = parser.add_subparsers(dest="mode")

    def common(p):
        p.add_argument("--label", default="", help='site name, e.g. "Main Hall"')
        p.add_argument("--json", metavar="PATH", help="write raw results JSON")
        p.add_argument("--report", metavar="PATH", help="write a markdown report for venue IT")
        p.add_argument("--outdir", default=".", help="directory for auto-named reports (default: cwd)")
        p.add_argument("--no-color", action="store_true")

    p_check = sub.add_parser("check", help="full assessment (~90s)")
    common(p_check)
    p_check.add_argument("--duration", type=int, default=10, help="seconds per throughput test")
    p_check.add_argument("--streams", type=int, default=4, help="parallel streams for capacity test")

    p_quick = sub.add_parser("quick", help="fast assessment (~30s)")
    common(p_quick)
    p_quick.add_argument("--duration", type=int, default=5)
    p_quick.add_argument("--streams", type=int, default=4)

    p_soak = sub.add_parser("soak", help="sustained stability test over time")
    common(p_soak)
    p_soak.add_argument("--minutes", type=int, default=30)
    p_soak.add_argument("--interval", type=int, default=60, help="seconds between samples")
    p_soak.add_argument("--sample-seconds", type=int, default=4, help="seconds per throughput sample")

    args = parser.parse_args()
    if not args.mode:
        args = parser.parse_args(["check"])

    global USE_COLOR
    USE_COLOR = not args.no_color and sys.stdout.isatty()
    enable_ansi()

    start = time.monotonic()
    if args.mode == "soak":
        results = run_soak(args)
    else:
        results = run_check(args)
        print_verdict(results)

    results["elapsed_seconds"] = time.monotonic() - start

    stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    slug = re.sub(r"[^A-Za-z0-9]+", "-", args.label).strip("-").lower() or "site"
    os.makedirs(args.outdir, exist_ok=True)

    json_path = args.json or os.path.join(args.outdir, f"netcheck_{slug}_{stamp}.json")
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(results, f, indent=2, default=str)

    md_path = args.report or os.path.join(args.outdir, f"netcheck_{slug}_{stamp}.md")
    write_markdown(results, md_path)

    print(c(f"  raw results : {json_path}", "grey"))
    print(c(f"  IT report   : {md_path}", "grey"))
    print()

    if results.get("verdict", {}).get("overall") == NOGO:
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print(c("\naborted", "yellow"))
        sys.exit(130)
