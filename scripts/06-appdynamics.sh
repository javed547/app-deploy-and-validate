#!/usr/bin/env bash
# ============================================================
# scripts/06-appdynamics.sh
# Stage: appdynamics-checks
# AppDynamics REST API health validation
# ============================================================
set -euo pipefail
source scripts/lib/logger.sh
source scripts/lib/thresholds.sh

section "AppDynamics Performance Checks"

[[ -z "${APPD_CONTROLLER_URL:-}" ]] && { warn "APPD_CONTROLLER_URL not set — skipping"; exit 0; }
[[ -z "${APPD_API_KEY:-}" ]]        && { warn "APPD_API_KEY not set — skipping";        exit 0; }

APPD_APP="${APPD_APP_NAME:-$APP_NAME}"
DURATION_MINS=15

# ── Helper: AppDynamics metric query ─────────────────────────
appd_metric() {
  local metric_path="$1"
  curl -sf \
    "${APPD_CONTROLLER_URL}/controller/rest/applications/${APPD_APP}/metric-data" \
    -H "Authorization: Bearer $APPD_API_KEY" \
    -H "Content-Type: application/json" \
    -G \
    --data-urlencode "metric-path=${metric_path}" \
    --data-urlencode "time-range-type=BEFORE_NOW" \
    --data-urlencode "duration-in-mins=${DURATION_MINS}" \
    --data-urlencode "output=JSON" 2>/dev/null || echo "[]"
}

extract_metric_value() {
  python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if d and d[0].get('metricValues'):
        print(d[0]['metricValues'][0]['value'])
    else:
        print(0)
except:
    print(0)
"
}

# ── 6.1 Calls per minute ─────────────────────────────────────
log "Fetching calls per minute..."
CALLS=$(appd_metric "Overall Application Performance|Calls per Minute" | extract_metric_value)
if [[ "$CALLS" -gt 0 ]]; then
  pass "Application receiving traffic: ${CALLS} calls/min"
else
  warn "No traffic detected in AppDynamics (may still be warming up)"
fi
set_state "APPD_CALLS_PER_MIN" "$CALLS"

# ── 6.2 Error rate ───────────────────────────────────────────
log "Fetching error rate..."
ERRORS_PM=$(appd_metric "Overall Application Performance|Errors per Minute" | extract_metric_value)
if [[ "$CALLS" -gt 0 ]]; then
  ERROR_RATE=$(python3 -c "print(round($ERRORS_PM/$CALLS*100, 2))" 2>/dev/null || echo "0")
else
  ERROR_RATE=0
fi

if (( $(echo "$ERROR_RATE <= $ERROR_RATE_THRESHOLD" | bc -l) )); then
  pass "Error rate: ${ERROR_RATE}% (threshold: ${ERROR_RATE_THRESHOLD}%)"
else
  fail "Error rate EXCEEDED: ${ERROR_RATE}% (threshold: ${ERROR_RATE_THRESHOLD}%)"
fi
set_state "APPD_ERROR_RATE_PCT" "$ERROR_RATE"

# ── 6.3 Average response time ────────────────────────────────
log "Fetching average response time..."
AVG_RT=$(appd_metric "Overall Application Performance|Average Response Time (ms)" | extract_metric_value)
if [[ "$AVG_RT" -le "$RESPONSE_TIME_THRESHOLD" ]]; then
  pass "Avg response time: ${AVG_RT}ms (threshold: ${RESPONSE_TIME_THRESHOLD}ms)"
else
  fail "Response time EXCEEDED: ${AVG_RT}ms (threshold: ${RESPONSE_TIME_THRESHOLD}ms)"
fi
set_state "APPD_AVG_RT_MS" "$AVG_RT"

# ── 6.4 95th percentile response time ───────────────────────
log "Fetching 95th percentile response time..."
P95_RT=$(appd_metric "Overall Application Performance|95th Percentile Response Time (ms)" | extract_metric_value)
P95_THRESHOLD=$((RESPONSE_TIME_THRESHOLD * 3))
if [[ "$P95_RT" -le "$P95_THRESHOLD" ]]; then
  pass "P95 response time: ${P95_RT}ms (threshold: ${P95_THRESHOLD}ms)"
else
  warn "P95 response time elevated: ${P95_RT}ms (threshold: ${P95_THRESHOLD}ms)"
fi

# ── 6.5 Health rule violations ───────────────────────────────
log "Checking health rule violations..."
VIOLATIONS=$(curl -sf \
  "${APPD_CONTROLLER_URL}/controller/rest/applications/${APPD_APP}/problems/healthrule-violations" \
  -H "Authorization: Bearer $APPD_API_KEY" \
  -G \
  --data-urlencode "time-range-type=BEFORE_NOW" \
  --data-urlencode "duration-in-mins=${DURATION_MINS}" \
  --data-urlencode "output=JSON" 2>/dev/null || echo "[]")

VIOLATION_COUNT=$(echo "$VIOLATIONS" | python3 -c "
import sys, json
try:
    print(len(json.load(sys.stdin)))
except:
    print(0)
")

if [[ "$VIOLATION_COUNT" -eq 0 ]]; then
  pass "No AppDynamics health rule violations"
else
  fail "$VIOLATION_COUNT health rule violation(s) — review AppDynamics alerts"
  echo "$VIOLATIONS" | python3 -c "
import sys, json
try:
    for v in json.load(sys.stdin):
        print('  >', v.get('name','?'), '—', v.get('severityImage','?'))
except:
    pass
" 2>/dev/null | tee -a "$LOG_FILE" || true
fi

# ── 6.6 Business transactions summary ───────────────────────
log "Fetching top business transaction health..."
BT_DATA=$(curl -sf \
  "${APPD_CONTROLLER_URL}/controller/rest/applications/${APPD_APP}/business-transactions" \
  -H "Authorization: Bearer $APPD_API_KEY" \
  -G --data-urlencode "output=JSON" 2>/dev/null || echo "[]")

echo "$BT_DATA" | python3 -c "
import sys, json
try:
    bts = json.load(sys.stdin)
    print(f'  Business transactions registered: {len(bts)}')
    for bt in sorted(bts, key=lambda x: -x.get('callsPerMinute',0))[:5]:
        print(f\"  - {bt.get('name','?'):40} calls/min: {bt.get('callsPerMinute',0)}\")
except:
    pass
" 2>/dev/null | tee -a "$LOG_FILE" || true

# ── Save AppDynamics summary ──────────────────────────────────
cat > "$REPORT_DIR/appdynamics-summary.json" <<EOF
{
  "app":              "$APPD_APP",
  "duration_mins":    $DURATION_MINS,
  "calls_per_min":    $CALLS,
  "error_rate_pct":   $ERROR_RATE,
  "avg_rt_ms":        $AVG_RT,
  "p95_rt_ms":        $P95_RT,
  "violations":       $VIOLATION_COUNT
}
EOF

# JUnit
cat > "$REPORT_DIR/junit-06-appdynamics.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="AppDynamics" tests="$((CHECKS_PASSED+CHECKS_FAILED))" failures="$CHECKS_FAILED">
$(grep "|" "$REPORT_DIR/check-results.txt" 2>/dev/null | tail -20 | while IFS="|" read -r status msg; do
  SAFE=$(echo "$msg" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g;s/"/\&quot;/g')
  [[ "$status" == "FAIL" ]] \
    && echo "  <testcase name=\"$SAFE\"><failure>$SAFE</failure></testcase>" \
    || echo "  <testcase name=\"$SAFE\"/>"
done)
</testsuite>
EOF

[[ "$CHECKS_FAILED" -gt 0 ]] && { echo "FAIL" > "$REPORT_DIR/overall-status.txt"; exit 1; }
log "AppDynamics checks complete"
