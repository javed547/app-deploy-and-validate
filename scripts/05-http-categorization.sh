#!/usr/bin/env bash
# ============================================================
# scripts/05-http-categorization.sh
# Stage: http-categorization
#
# Executes INSIDE each running pod via `oc exec` to:
#   1. Parse the application's own access log
#   2. Categorise HTTP requests by method, status class, path
#   3. Detect 5xx spikes, slow requests, anomalous endpoints
#   4. Emit structured JSON report
#
# Supports log locations:
#   /var/log/app/access.log   (Spring Boot / custom)
#   /opt/app/logs/access.log
#   /tmp/access.log
#   /proc/1/fd/1              (stdout — parsed live)
# ============================================================
set -euo pipefail
source scripts/lib/logger.sh
source scripts/lib/thresholds.sh

section "HTTP Request Categorization (via oc exec)"
oc_login

# ── Python analyser injected into the container ──────────────
# This script runs INSIDE the pod — keep dependencies to stdlib only
HTTP_ANALYSER_SCRIPT='
import sys, json, re, os
from collections import defaultdict

SLOW_MS    = int(os.environ.get("SLOW_MS",    "3000"))
MAX_5XX_PC = float(os.environ.get("MAX_5XX_PC", "5.0"))

# Regex patterns covering common log formats:
# Combined Log Format:   127.0.0.1 - - [date] "GET /path HTTP/1.1" 200 512 "-" "agent" 123
# Spring Boot JSON:      {"timestamp":"...","method":"GET","uri":"/path","status":200,"duration":45}
# Nginx extended:        127.0.0.1 - - [date] "GET /path HTTP/1.1" 200 512 0.045
COMBINED_RE = re.compile(
    r"\"(?P<method>[A-Z]+)\s+(?P<path>[^\s\"]+)[^\"]*\"\s+(?P<status>\d{3})\s+\d+(?:\s+\S+\s+\S+)?\s*(?P<dur>\d+)?")
JSON_RE = re.compile(
    r"\{.*?\"method\"\s*:\s*\"(?P<method>[A-Z]+)\".*?"
    r"\"(?:uri|url|path)\"\s*:\s*\"(?P<path>[^\"]*)\".*?"
    r"\"status\"\s*:\s*(?P<status>\d{3}).*?"
    r"\"(?:duration|elapsed|responseTime)\"\s*:\s*(?P<dur>\d+)", re.DOTALL)

stats = {
    "total":         0,
    "by_method":     defaultdict(int),
    "by_status_class": defaultdict(int),   # 2xx/3xx/4xx/5xx
    "by_status_code":  defaultdict(int),
    "slow_requests": 0,
    "top_paths":     defaultdict(int),
    "error_paths":   defaultdict(int),
    "slow_paths":    defaultdict(int),
}

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue

    m = JSON_RE.search(line) or COMBINED_RE.search(line)
    if not m:
        continue

    method = m.group("method")
    path   = m.group("path").split("?")[0]   # strip query string
    status = int(m.group("status"))
    dur    = int(m.group("dur") or 0)

    stats["total"] += 1
    stats["by_method"][method] += 1
    sc = f"{status // 100}xx"
    stats["by_status_class"][sc] += 1
    stats["by_status_code"][str(status)] += 1
    stats["top_paths"][path] += 1

    if status >= 500:
        stats["error_paths"][path] += 1

    if dur > SLOW_MS:
        stats["slow_requests"] += 1
        stats["slow_paths"][path] += 1

# Derived metrics
total = stats["total"] or 1
pct_5xx  = round(stats["by_status_class"].get("5xx", 0) / total * 100, 2)
pct_4xx  = round(stats["by_status_class"].get("4xx", 0) / total * 100, 2)
pct_slow = round(stats["slow_requests"]                  / total * 100, 2)

top_10_paths  = sorted(stats["top_paths"].items(),  key=lambda x: -x[1])[:10]
top_5xx_paths = sorted(stats["error_paths"].items(), key=lambda x: -x[1])[:5]
top_slow      = sorted(stats["slow_paths"].items(),  key=lambda x: -x[1])[:5]

result = {
    "summary": {
        "total_requests":     stats["total"],
        "pct_5xx":            pct_5xx,
        "pct_4xx":            pct_4xx,
        "pct_slow":           pct_slow,
        "slow_threshold_ms":  SLOW_MS,
    },
    "by_method":       dict(stats["by_method"]),
    "by_status_class": dict(stats["by_status_class"]),
    "by_status_code":  dict(stats["by_status_code"]),
    "top_paths":       top_10_paths,
    "top_5xx_paths":   top_5xx_paths,
    "top_slow_paths":  top_slow,
    "verdict": {
        "5xx_ok":  pct_5xx  <= MAX_5XX_PC,
        "slow_ok": pct_slow <= 20.0,
    }
}

print(json.dumps(result, indent=2))
'

# ── Find running pods ─────────────────────────────────────────
PODS=$(oc get pods -n "$NAMESPACE" -l "app=$APP_NAME" \
  --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -3 || true)

if [[ -z "$PODS" ]]; then
  warn "No running pods found for app=$APP_NAME — skipping HTTP categorisation"
  exit 0
fi

REPORT_JSON="$REPORT_DIR/http-categorization.json"
echo "[]" > "$REPORT_JSON"
ALL_RESULTS="[]"

for POD in $PODS; do
  log "Analysing HTTP logs in pod: $POD"

  # ── Detect log location inside container ─────────────────
  LOG_PATH=""
  for CANDIDATE in \
    "/var/log/app/access.log" \
    "/opt/app/logs/access.log" \
    "/app/logs/access.log" \
    "/tmp/access.log" \
    "/var/log/nginx/access.log"; do
    EXISTS=$(oc exec "$POD" -n "$NAMESPACE" -- \
      sh -c "[ -f '$CANDIDATE' ] && echo yes || echo no" 2>/dev/null || echo "no")
    if [[ "$EXISTS" == "yes" ]]; then
      LOG_PATH="$CANDIDATE"
      break
    fi
  done

  if [[ -z "$LOG_PATH" ]]; then
    log "  No access log file found — falling back to stdout capture (last 500 lines)"
    # Capture recent stdout via oc logs (last 500 lines from current deploy)
    RAW_LOG=$(oc logs "$POD" -n "$NAMESPACE" --since=15m --tail=500 2>/dev/null || echo "")
  else
    log "  Reading from: $LOG_PATH"
    # Stream last 2000 lines from log file inside container
    RAW_LOG=$(oc exec "$POD" -n "$NAMESPACE" -- \
      sh -c "tail -n 2000 '$LOG_PATH'" 2>/dev/null || echo "")
  fi

  if [[ -z "$RAW_LOG" ]]; then
    warn "  No log data available for pod $POD"
    continue
  fi

  log "  Lines collected: $(echo "$RAW_LOG" | wc -l)"

  # ── Run analyser inside the pipeline runner (not the pod) ──
  # The Python script is injected via stdin — no file writes to container
  POD_RESULT=$(echo "$RAW_LOG" | \
    SLOW_MS="$HTTP_SLOW_THRESHOLD" \
    MAX_5XX_PC="$HTTP_5XX_THRESHOLD" \
    python3 -c "$HTTP_ANALYSER_SCRIPT" 2>/dev/null || echo '{}')

  # ── Persist per-pod result ────────────────────────────────
  echo "$POD_RESULT" > "$REPORT_DIR/http-${POD}.json"
  log "  Saved: $REPORT_DIR/http-${POD}.json"

  # ── Evaluate verdicts ─────────────────────────────────────
  PCT_5XX=$(echo "$POD_RESULT"  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('summary',{}).get('pct_5xx',0))" 2>/dev/null || echo "0")
  PCT_SLOW=$(echo "$POD_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('summary',{}).get('pct_slow',0))" 2>/dev/null || echo "0")
  TOTAL_REQ=$(echo "$POD_RESULT"| python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('summary',{}).get('total_requests',0))" 2>/dev/null || echo "0")
  TOP_5XX=$(echo "$POD_RESULT"  | python3 -c "import sys,json; d=json.load(sys.stdin); [print('   ',p,n) for p,n in d.get('top_5xx_paths',[])]" 2>/dev/null || true)

  log "  Total requests parsed: $TOTAL_REQ"
  log "  5xx rate: ${PCT_5XX}%  |  Slow (>${HTTP_SLOW_THRESHOLD}ms): ${PCT_SLOW}%"
  [[ -n "$TOP_5XX" ]] && log "  Top 5xx paths:\n$TOP_5XX"

  if (( $(echo "$PCT_5XX > $HTTP_5XX_THRESHOLD" | bc -l) )); then
    fail "Pod $POD — 5xx rate ${PCT_5XX}% exceeds threshold ${HTTP_5XX_THRESHOLD}%"
  else
    pass "Pod $POD — 5xx rate ${PCT_5XX}% within threshold ${HTTP_5XX_THRESHOLD}%"
  fi

  if (( $(echo "$PCT_SLOW > 20.0" | bc -l) )); then
    warn "Pod $POD — ${PCT_SLOW}% of requests exceed ${HTTP_SLOW_THRESHOLD}ms"
  else
    pass "Pod $POD — slow request rate ${PCT_SLOW}% is acceptable"
  fi

  # ── Print human-readable summary table ───────────────────
  echo ""
  echo "  ┌─────────────────────────────────────────────────────┐"
  echo "  │  HTTP Request Summary — $POD"
  echo "  ├────────────────┬────────────────────────────────────┤"
  python3 - <<PYEOF
import json, sys
data = json.loads('''$POD_RESULT''')
s = data.get("summary", {})
m = data.get("by_method", {})
sc = data.get("by_status_class", {})
print(f"  │ Total Requests │ {s.get('total_requests',0):<34} │")
print(f"  │ 2xx Success    │ {sc.get('2xx',0):<34} │")
print(f"  │ 3xx Redirect   │ {sc.get('3xx',0):<34} │")
print(f"  │ 4xx Client Err │ {sc.get('4xx',0):<34} │")
print(f"  │ 5xx Server Err │ {sc.get('5xx',0)} ({s.get('pct_5xx',0)}%){'':<25} │")
print(f"  │ Slow Requests  │ {s.get('pct_slow',0)}% over {s.get('slow_threshold_ms',0)}ms{'':<20} │")
for meth, cnt in sorted(m.items()):
    print(f"  │ Method {meth:<7} │ {cnt:<34} │")
PYEOF
  echo "  └────────────────┴────────────────────────────────────┘"

done

# ── Aggregate report ─────────────────────────────────────────
log "Aggregating HTTP categorization across all pods..."
python3 - <<PYEOF > "$REPORT_DIR/http-aggregate.json"
import json, glob, os

files = glob.glob("$REPORT_DIR/http-*.json")
files = [f for f in files if "aggregate" not in f and "categorization" not in f]

totals = {"total_requests":0,"5xx":0,"4xx":0,"2xx":0,"3xx":0,"slow":0}
for f in files:
    try:
        with open(f) as fh:
            d = json.load(fh)
        s   = d.get("summary", {})
        sc  = d.get("by_status_class", {})
        tr  = s.get("total_requests", 0)
        totals["total_requests"] += tr
        totals["5xx"]  += sc.get("5xx", 0)
        totals["4xx"]  += sc.get("4xx", 0)
        totals["2xx"]  += sc.get("2xx", 0)
        totals["3xx"]  += sc.get("3xx", 0)
        totals["slow"] += round(tr * s.get("pct_slow", 0) / 100)
    except Exception:
        pass

t = totals["total_requests"] or 1
print(json.dumps({
    "pods_analysed":   len(files),
    "total_requests":  totals["total_requests"],
    "pct_5xx":         round(totals["5xx"]/t*100, 2),
    "pct_4xx":         round(totals["4xx"]/t*100, 2),
    "pct_2xx":         round(totals["2xx"]/t*100, 2),
    "pct_slow":        round(totals["slow"]/t*100, 2),
}, indent=2))
PYEOF

log "Aggregate HTTP report saved: $REPORT_DIR/http-aggregate.json"
cat "$REPORT_DIR/http-aggregate.json" | tee -a "$LOG_FILE"

# JUnit
cat > "$REPORT_DIR/junit-05-http.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="HTTP_Categorization" tests="$((CHECKS_PASSED+CHECKS_FAILED))" failures="$CHECKS_FAILED">
$(grep "|" "$REPORT_DIR/check-results.txt" 2>/dev/null | tail -20 | while IFS="|" read -r status msg; do
  SAFE=$(echo "$msg" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g;s/"/\&quot;/g')
  [[ "$status" == "FAIL" ]] \
    && echo "  <testcase name=\"$SAFE\"><failure>$SAFE</failure></testcase>" \
    || echo "  <testcase name=\"$SAFE\"/>"
done)
</testsuite>
EOF

[[ "$CHECKS_FAILED" -gt 0 ]] && { echo "FAIL" > "$REPORT_DIR/overall-status.txt"; exit 1; }
log "HTTP categorization complete"
