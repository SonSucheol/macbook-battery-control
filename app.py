#!/usr/bin/env python3
"""맥북 배터리 잔량, 성능, 충전 한도를 보여주는 로컬 화면."""

import json
import plistlib
import re
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent
HELPER = ROOT / "battery-helper"
HOST = "127.0.0.1"
PORT = 8765

PAGE = r"""<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>맥북 배터리 제어</title>
<style>
  :root {
    color-scheme: dark;
    --bg: #121410;
    --card: #1c1f18;
    --ink: #f3f1e7;
    --muted: #a7ab9d;
    --line: #31362b;
    --good: #c6de6a;
    --warn: #e6b15a;
    --hot: #e07a4c;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    min-height: 100vh;
    background:
      radial-gradient(900px 420px at 10% -10%, #2a3320 0%, transparent 55%),
      var(--bg);
    color: var(--ink);
    font: 16px/1.45 "Apple SD Gothic Neo", "Pretendard", sans-serif;
  }
  main {
    width: min(760px, calc(100% - 32px));
    margin: 40px auto 64px;
  }
  header p { margin: 0; color: var(--muted); letter-spacing: 0.08em; font-size: 13px; }
  h1 { margin: 6px 0 0; font-size: 28px; font-weight: 680; }
  .panel {
    margin-top: 22px;
    background: var(--card);
    border: 1px solid var(--line);
    border-radius: 22px;
    padding: 28px;
  }
  .hero { display: flex; justify-content: space-between; gap: 24px; align-items: flex-end; }
  .percent { font-size: 92px; line-height: 0.85; font-weight: 650; letter-spacing: -0.04em; }
  .percent span { font-size: 34px; margin-left: 2px; color: var(--muted); }
  .state { text-align: right; }
  .state strong { display: block; font-size: 22px; font-weight: 640; }
  .state em { display: block; margin-top: 6px; color: var(--muted); font-style: normal; }
  .meter { height: 10px; margin: 26px 0 8px; background: #2a2e24; border-radius: 999px; overflow: hidden; }
  .meter i { display: block; height: 100%; width: 0; background: var(--good); border-radius: inherit; }
  .meter.mid i { background: var(--warn); }
  .meter.low i { background: var(--hot); }
  .grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 10px; margin-top: 22px; }
  .stat { background: #151712; border-radius: 14px; padding: 14px; min-height: 92px; }
  .stat b { display: block; margin-top: 8px; font-size: 22px; font-weight: 640; }
  .stat span, .limit p { color: var(--muted); }
  .limit { margin-top: 26px; }
  .choices { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 12px; }
  button {
    appearance: none;
    border: 1px solid var(--line);
    background: #151712;
    color: var(--ink);
    border-radius: 999px;
    padding: 10px 16px;
    font: inherit;
    cursor: pointer;
  }
  button[aria-pressed="true"] { background: var(--good); color: #1a1d12; border-color: transparent; font-weight: 680; }
  button:disabled { opacity: 0.45; cursor: wait; }
  .note { min-height: 1.4em; margin: 14px 0 0; color: var(--muted); }
  .note.error { color: var(--hot); }
  @media (max-width: 680px) {
    .hero { display: block; }
    .state { text-align: left; margin-top: 16px; }
    .percent { font-size: 76px; }
    .grid { grid-template-columns: repeat(2, 1fr); }
  }
</style>
</head>
<body>
<main>
  <header>
    <p>MACBOOK</p>
    <h1>배터리 제어</h1>
  </header>
  <section class="panel">
    <div class="hero">
      <div class="percent" id="percent">–<span>%</span></div>
      <div class="state">
        <strong id="state">불러오는 중</strong>
        <em id="time"></em>
      </div>
    </div>
    <div class="meter" id="meter"><i id="fill"></i></div>
    <div class="grid">
      <div class="stat"><span>성능 최대치</span><b id="health">–</b></div>
      <div class="stat"><span>충전 횟수</span><b id="cycles">–</b></div>
      <div class="stat"><span>지금 전력</span><b id="power">–</b></div>
      <div class="stat"><span>전압</span><b id="voltage">–</b></div>
    </div>
    <div class="limit">
      <span>충전 한도</span>
      <p>전원에 연결하면 고른 퍼센트에서 충전을 멈춥니다. 100%는 제한 없이 완충합니다.</p>
      <div class="choices" id="choices"></div>
      <p class="note" id="note"></p>
    </div>
  </section>
</main>
<script>
const $ = (id) => document.getElementById(id);
const labels = {
  charging: "충전 중",
  discharging: "배터리 사용 중",
  charged: "완충됨",
  finishing: "충전 마무리",
  "not charging": "충전 멈춤",
  unknown: "상태 확인 중"
};

function hours(text) {
  if (!text || text === "0:00") return "계산 중";
  const [h, m] = text.split(":").map(Number);
  if (Number.isNaN(h)) return text;
  if (!h) return m + "분 남음";
  if (!m) return h + "시간 남음";
  return h + "시간 " + m + "분 남음";
}

function render(data) {
  const pct = data.percent;
  $("percent").innerHTML = (pct ?? "–") + "<span>%</span>";
  $("state").textContent = labels[data.state] || data.state || "상태 확인 중";
  const onBattery = data.source === "battery";
  $("time").textContent = data.timeRemaining ? (onBattery || data.state === "charging" ? hours(data.timeRemaining) : "") : "";
  const meter = $("meter");
  meter.className = "meter" + (pct < 20 ? " low" : pct < 50 ? " mid" : "");
  $("fill").style.width = Math.max(0, Math.min(100, pct || 0)) + "%";
  $("health").textContent = data.healthPercent != null ? data.healthPercent + "%" : "–";
  $("cycles").textContent = data.cycleCount != null ? data.cycleCount.toLocaleString("ko-KR") : "–";
  if (data.powerWatts == null) $("power").textContent = "–";
  else {
    const watts = Math.abs(data.powerWatts).toFixed(1);
    $("power").textContent = (data.powerWatts < 0 ? "방전 " : "충전 ") + watts + "W";
  }
  $("voltage").textContent = data.voltage != null ? data.voltage.toFixed(2) + "V" : "–";
  const box = $("choices");
  const limits = (data.charge && data.charge.available) || [80, 85, 90, 95, 100];
  const current = data.charge ? data.charge.limit : null;
  box.innerHTML = "";
  limits.forEach((limit) => {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = limit + "%";
    button.setAttribute("aria-pressed", String(limit === current));
    button.onclick = () => apply(limit, button);
    box.appendChild(button);
  });
  if (data.charge && data.charge.error) {
    $("note").className = "note error";
    $("note").textContent = data.charge.error;
  }
}

async function refresh() {
  const response = await fetch("/api/status");
  const data = await response.json();
  render(data);
}

async function apply(limit, button) {
  document.querySelectorAll("#choices button").forEach((item) => item.disabled = true);
  $("note").className = "note";
  $("note").textContent = limit + "%로 적용하는 중";
  try {
    const response = await fetch("/api/limit", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({limit})
    });
    const data = await response.json();
    if (!response.ok || data.ok === false) throw new Error(data.error || "적용하지 못했습니다.");
    $("note").textContent = limit === 100 ? "충전 제한을 껐습니다." : "충전 한도를 " + limit + "%로 맞춰 두었습니다.";
    await refresh();
  } catch (error) {
    $("note").className = "note error";
    $("note").textContent = error.message;
    document.querySelectorAll("#choices button").forEach((item) => item.disabled = false);
    button.disabled = false;
  }
}

refresh().catch((error) => {
  $("state").textContent = "연결 실패";
  $("note").className = "note error";
  $("note").textContent = error.message;
});
setInterval(() => refresh().catch(() => {}), 4000);
</script>
</body>
</html>
"""


def run(command):
    return subprocess.run(command, check=False, capture_output=True, text=True)


def find_battery(node):
    if isinstance(node, dict):
        if "CycleCount" in node and "Voltage" in node:
            return node
        for value in node.values():
            found = find_battery(value)
            if found:
                return found
    elif isinstance(node, list):
        for value in node:
            found = find_battery(value)
            if found:
                return found
    return None


def charge_status():
    if not HELPER.exists():
        return {"supported": False, "enabled": False, "limit": None, "available": [], "error": "충전 제어 도구가 없습니다."}
    result = run([str(HELPER), "status"])
    try:
        payload = json.loads(result.stdout or "{}")
    except json.JSONDecodeError:
        payload = {}
    if result.returncode != 0 and "error" not in payload:
        payload["error"] = (result.stderr or "충전 한도를 읽지 못했습니다.").strip()
    return payload


def battery_status():
    pm = run(["pmset", "-g", "batt"]).stdout
    percent = None
    state = "unknown"
    remaining = None
    source = "battery" if "Battery Power" in pm else "ac"
    matched = re.search(r"(\d+)%;\s*([^;]+);\s*(\d+:\d+)?", pm)
    if matched:
        percent = int(matched.group(1))
        state = matched.group(2).strip().lower()
        remaining = matched.group(3)

    raw = subprocess.run(["ioreg", "-rn", "AppleSmartBattery", "-a"], check=False, capture_output=True)
    info = {}
    if raw.returncode == 0 and raw.stdout:
        try:
            info = find_battery(plistlib.loads(raw.stdout)) or {}
        except plistlib.InvalidFileException:
            info = {}

    pack = info.get("BatteryData") if isinstance(info.get("BatteryData"), dict) else {}
    design = pack.get("DesignCapacity") or info.get("DesignCapacity") or 0
    full = pack.get("FullChargeCapacity") or info.get("FullChargeCapacity") or 0
    health = round(full / design * 100) if design else None
    power = pack.get("BatteryPower", info.get("BatteryPower"))
    voltage = info.get("Voltage")
    live = run(["pmset", "-g", "live"]).stdout
    low_power = any(line.strip().startswith("lowpowermode") and line.strip().endswith("1") for line in live.splitlines())

    return {
        "percent": percent if percent is not None else info.get("CurrentCapacity"),
        "state": state,
        "timeRemaining": remaining,
        "source": source,
        "healthPercent": health,
        "cycleCount": info.get("CycleCount"),
        "designCycles": info.get("DesignCycleCount9C"),
        "fullChargeMah": full or None,
        "designMah": design or None,
        "powerWatts": round(power / 1000, 2) if isinstance(power, (int, float)) else None,
        "voltage": round(voltage / 1000, 2) if isinstance(voltage, (int, float)) else None,
        "lowPowerMode": low_power,
        "charge": charge_status(),
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def send_json(self, payload, code=200):
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/api/status":
            self.send_json(battery_status())
            return
        if path != "/":
            self.send_error(404)
            return
        body = PAGE.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if urlparse(self.path).path != "/api/limit":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", "0"))
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
            limit = int(payload["limit"])
        except (ValueError, KeyError, json.JSONDecodeError):
            self.send_json({"ok": False, "error": "충전 한도를 확인하지 못했습니다."}, 400)
            return
        result = run([str(HELPER), "set", str(limit)])
        try:
            body = json.loads(result.stdout or "{}")
        except json.JSONDecodeError:
            body = {"ok": False, "error": "충전 한도 응답을 읽지 못했습니다."}
        if result.returncode != 0:
            body.setdefault("ok", False)
            self.send_json(body, 400)
            return
        self.send_json(body)


def main():
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"http://{HOST}:{PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
