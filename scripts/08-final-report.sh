#!/usr/bin/env bash
# ============================================================
# scripts/08-final-report.sh
# Stage: report
# Aggregates all check results, computes health score,
# emits final JSON + HTML report, sets pipeline PASS/FAIL
# ============================================================
set -euo pipefail
source scripts/lib/logger.sh
source scripts/lib/thresholds.sh

section "Final Health Gate & Report"

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PASS_COUNT=$(grep -c "^PASS|" "$REPORT_DIR/check-results.txt" 2>/dev/null || echo "0")
FAIL_COUNT=$(grep -c "^FAIL|" "$REPORT_DIR/check-results.txt" 2>/dev/null || echo "0")
WARN_COUNT=$(grep -c "^WARN|" "$REPORT_DIR/check-results.txt" 2>/dev/null || echo "0")
TOTAL=$((PASS_COUNT + FAIL_COUNT))
SCORE=$(python3 -c "print(round($PASS_COUNT/$TOTAL*100, 1) if $TOTAL > 0 else 0)" 2>/dev/null || echo "0")

# Determine final status
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  OVERALL="FAIL"
elif [[ "$WARN_COUNT" -gt 3 ]]; then
  OVERALL="WARN"
else
  OVERALL="PASS"
fi

echo "$OVERALL" > "$REPORT_DIR/overall-status.txt"

# ── Load state values ────────────────────────────────────────
ROUTE_HOST=$(grep "^ROUTE_HOST=" "$REPORT_DIR/pipeline-state.env" 2>/dev/null | cut -d= -f2 || echo "N/A")
DEPLOYED_IMAGE=$(grep "^DEPLOYED_IMAGE=" "$REPORT_DIR/pipeline-state.env" 2>/dev/null | cut -d= -f2 || echo "N/A")
PODS_READY=$(grep "^PODS_READY=" "$REPORT_DIR/pipeline-state.env" 2>/dev/null | cut -d= -f2 || echo "?")
PODS_DESIRED=$(grep "^PODS_DESIRED=" "$REPORT_DIR/pipeline-state.env" 2>/dev/null | cut -d= -f2 || echo "?")
APPD_ERROR_RATE=$(grep "^APPD_ERROR_RATE_PCT=" "$REPORT_DIR/pipeline-state.env" 2>/dev/null | cut -d= -f2 || echo "N/A")
APPD_AVG_RT=$(grep "^APPD_AVG_RT_MS=" "$REPORT_DIR/pipeline-state.env" 2>/dev/null | cut -d= -f2 || echo "N/A")
ELK_ERRORS=$(grep "^ELK_ERROR_COUNT=" "$REPORT_DIR/pipeline-state.env" 2>/dev/null | cut -d= -f2 || echo "N/A")

# ── Console summary ──────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║         POST-DEPLOYMENT HEALTH VALIDATION REPORT         ║"
echo "╠══════════════════════════════════════════════════════════╣"
printf "║  %-20s %-35s ║\n" "Application:"  "$APP_NAME"
printf "║  %-20s %-35s ║\n" "Version:"      "$APP_VERSION"
printf "║  %-20s %-35s ║\n" "Namespace:"    "$NAMESPACE"
printf "║  %-20s %-35s ║\n" "Image:"        "${DEPLOYED_IMAGE:0:35}"
printf "║  %-20s %-35s ║\n" "Route:"        "$ROUTE_HOST"
printf "║  %-20s %-35s ║\n" "Pods:"         "${PODS_READY}/${PODS_DESIRED} ready"
printf "║  %-20s %-35s ║\n" "Timestamp:"    "$TIMESTAMP"
echo "╠══════════════════════════════════════════════════════════╣"
printf "║  %-20s %-35s ║\n" "Checks Passed:"  "$PASS_COUNT / $TOTAL"
printf "║  %-20s %-35s ║\n" "Checks Failed:"  "$FAIL_COUNT"
printf "║  %-20s %-35s ║\n" "Warnings:"       "$WARN_COUNT"
printf "║  %-20s %-35s ║\n" "Health Score:"   "${SCORE}%"
printf "║  %-20s %-35s ║\n" "AppD Error Rate:" "${APPD_ERROR_RATE}%"
printf "║  %-20s %-35s ║\n" "AppD Avg RT:"    "${APPD_AVG_RT}ms"
printf "║  %-20s %-35s ║\n" "ELK Errors:"     "$ELK_ERRORS"
echo "╠══════════════════════════════════════════════════════════╣"
if [[ "$OVERALL" == "PASS" ]]; then
  printf "║  %-56s ║\n" "✔  OVERALL STATUS: PASS — MARK CHANGE AS SUCCESS"
elif [[ "$OVERALL" == "WARN" ]]; then
  printf "║  %-56s ║\n" "⚠  OVERALL STATUS: WARN — REVIEW BEFORE CLOSING"
else
  printf "║  %-56s ║\n" "✘  OVERALL STATUS: FAIL — DO NOT MARK SUCCESS"
fi
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── Failed checks detail ─────────────────────────────────────
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo "─── FAILED CHECKS ────────────────────────────────────────"
  grep "^FAIL|" "$REPORT_DIR/check-results.txt" | while IFS="|" read -r _ msg; do
    echo "  ✘ $msg"
  done
  echo ""
fi

# ── JSON report ──────────────────────────────────────────────
cat > "$REPORT_DIR/health-report-final.json" <<EOF
{
  "app":              "$APP_NAME",
  "namespace":        "$NAMESPACE",
  "version":          "$APP_VERSION",
  "image":            "$DEPLOYED_IMAGE",
  "route":            "$ROUTE_HOST",
  "pods_ready":       "$PODS_READY/$PODS_DESIRED",
  "timestamp":        "$TIMESTAMP",
  "gitlab_pipeline":  "${CI_PIPELINE_ID:-local}",
  "gitlab_job_url":   "${CI_JOB_URL:-local}",
  "checks_passed":    $PASS_COUNT,
  "checks_failed":    $FAIL_COUNT,
  "checks_warned":    $WARN_COUNT,
  "health_score_pct": $SCORE,
  "overall_status":   "$OVERALL",
  "appdynamics": {
    "error_rate_pct": "${APPD_ERROR_RATE:-N/A}",
    "avg_rt_ms":      "${APPD_AVG_RT:-N/A}"
  },
  "elk": {
    "error_count":    "${ELK_ERRORS:-N/A}"
  }
}
EOF

# ── HTML report ──────────────────────────────────────────────
STATUS_COLOR=$( [[ "$OVERALL" == "PASS" ]] && echo "#28a745" || ([[ "$OVERALL" == "WARN" ]] && echo "#ffc107" || echo "#dc3545") )

cat > "$REPORT_DIR/health-report.html" <<HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Health Report — $APP_NAME v$APP_VERSION</title>
  <style>
    body  { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
            background: #0d1117; color: #c9d1d9; margin: 0; padding: 20px; }
    .card { background: #161b22; border: 1px solid #30363d;
            border-radius: 8px; padding: 20px; margin-bottom: 20px; }
    h1    { color: #58a6ff; margin: 0 0 4px; }
    .badge{ display: inline-block; padding: 6px 18px; border-radius: 20px;
            font-weight: bold; font-size: 1.1em;
            background: ${STATUS_COLOR}; color: #fff; }
    table { width: 100%; border-collapse: collapse; }
    th    { background: #21262d; color: #8b949e; text-align: left;
            padding: 8px 12px; font-size: 0.8em; text-transform: uppercase; }
    td    { padding: 8px 12px; border-bottom: 1px solid #21262d; }
    .pass { color: #3fb950; } .fail { color: #f85149; } .warn { color: #d29922; }
    .score{ font-size: 3em; font-weight: bold; color: ${STATUS_COLOR}; }
    .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
    .kv   { display: flex; justify-content: space-between; padding: 4px 0;
            border-bottom: 1px solid #21262d; }
    .kv span:first-child { color: #8b949e; }
  </style>
</head>
<body>
  <div class="card">
    <h1>Post-Deployment Health Report</h1>
    <p>$APP_NAME &nbsp;|&nbsp; v$APP_VERSION &nbsp;|&nbsp; $NAMESPACE &nbsp;|&nbsp; $TIMESTAMP</p>
    <span class="badge">$OVERALL</span>
    &nbsp;&nbsp;<span class="score">${SCORE}%</span>
  </div>
  <div class="grid">
    <div class="card">
      <h3>Deployment Details</h3>
      <div class="kv"><span>Image</span>        <span>${DEPLOYED_IMAGE:0:50}</span></div>
      <div class="kv"><span>Route</span>        <span>$ROUTE_HOST</span></div>
      <div class="kv"><span>Pods</span>         <span>${PODS_READY}/${PODS_DESIRED}</span></div>
      <div class="kv"><span>Pipeline</span>     <span>${CI_PIPELINE_ID:-local}</span></div>
    </div>
    <div class="card">
      <h3>Observability Metrics</h3>
      <div class="kv"><span>AppD Error Rate</span>  <span>${APPD_ERROR_RATE:-N/A}%</span></div>
      <div class="kv"><span>AppD Avg RT</span>      <span>${APPD_AVG_RT:-N/A}ms</span></div>
      <div class="kv"><span>ELK Error Count</span>  <span>${ELK_ERRORS:-N/A}</span></div>
    </div>
  </div>
  <div class="card">
    <h3>Check Results</h3>
    <table>
      <tr><th>Status</th><th>Check</th></tr>
$(grep "|" "$REPORT_DIR/check-results.txt" 2>/dev/null | while IFS="|" read -r status msg; do
  CSS=$( [[ "$status" == "PASS" ]] && echo "pass" || ([[ "$status" == "WARN" ]] && echo "warn" || echo "fail") )
  ICON=$( [[ "$status" == "PASS" ]] && echo "✔" || ([[ "$status" == "WARN" ]] && echo "⚠" || echo "✘") )
  SAFE_MSG=$(echo "$msg" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')
  echo "      <tr><td class=\"$CSS\">$ICON $status</td><td>$SAFE_MSG</td></tr>"
done)
    </table>
  </div>
</body>
</html>
HTMLEOF

log "Reports saved:"
log "  JSON: $REPORT_DIR/health-report-final.json"
log "  HTML: $REPORT_DIR/health-report.html"
log "  Logs: $LOG_FILE"

[[ "$OVERALL" == "FAIL" ]] && exit 1
exit 0
