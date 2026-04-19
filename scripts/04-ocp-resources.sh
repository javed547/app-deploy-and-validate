#!/usr/bin/env bash
# ============================================================
# scripts/04-ocp-resources.sh
# Stage: ocp-platform-checks
# Validates resource usage, routes, services, HPA
# ============================================================
set -euo pipefail
source scripts/lib/logger.sh
source scripts/lib/thresholds.sh

section "OpenShift Resources & Route Checks"
oc_login

# ── 4.1 Resource usage (top pods) ───────────────────────────
log "Collecting resource utilisation metrics..."
TOP_OUTPUT=$(oc adm top pods -n "$NAMESPACE" -l "app=$APP_NAME" \
  --no-headers 2>/dev/null || echo "")

if [[ -z "$TOP_OUTPUT" ]]; then
  warn "oc adm top returned no data — metrics-server may not be available"
else
  echo "$TOP_OUTPUT" | tee -a "$LOG_FILE"
  CPU_TOTAL=$(echo "$TOP_OUTPUT" | awk '{gsub(/m/,"",$2); s+=$2} END {print s+0}')
  MEM_TOTAL=$(echo "$TOP_OUTPUT" | awk '{gsub(/Mi/,"",$3); s+=$3} END {print s+0}')
  pass "Resource metrics: CPU=${CPU_TOTAL}m  MEM=${MEM_TOTAL}Mi"
  set_state "CPU_USAGE_MILLICORES" "$CPU_TOTAL"
  set_state "MEM_USAGE_MI"         "$MEM_TOTAL"
fi

# ── 4.2 Resource limits / requests defined ───────────────────
log "Checking resource limits are defined..."
LIMITS=$(oc get deployment "$APP_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].resources}' 2>/dev/null || echo "{}")

if echo "$LIMITS" | grep -q '"limits"'; then
  pass "Resource limits are configured on deployment"
else
  warn "No resource limits defined — risk of node pressure"
fi

# ── 4.3 Route availability ───────────────────────────────────
log "Checking routes for $APP_NAME..."
ROUTE_HOST=$(oc get route "$APP_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.spec.host}' 2>/dev/null || true)

if [[ -z "$ROUTE_HOST" ]]; then
  warn "No route named '$APP_NAME' — trying to find any route..."
  ROUTE_HOST=$(oc get routes -n "$NAMESPACE" \
    -o jsonpath='{range .items[*]}{.spec.host}{"\n"}{end}' 2>/dev/null | head -1 || true)
fi

if [[ -n "$ROUTE_HOST" ]]; then
  set_state "ROUTE_HOST" "$ROUTE_HOST"
  log "Route found: https://$ROUTE_HOST"

  # Health probe
  for PROBE_PATH in /health /actuator/health /api/health /ping /status; do
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
      "https://${ROUTE_HOST}${PROBE_PATH}" \
      --max-time 10 --connect-timeout 5 2>/dev/null || echo "000")
    log "  $PROBE_PATH → HTTP $HTTP_CODE"
    if [[ "$HTTP_CODE" == "200" ]]; then
      pass "Health endpoint ${PROBE_PATH} returned HTTP 200"
      set_state "HEALTH_ENDPOINT" "https://${ROUTE_HOST}${PROBE_PATH}"
      break
    fi
  done
  [[ "$HTTP_CODE" != "200" ]] && warn "No health endpoint returned 200 — checked common paths"
else
  warn "No route found for $APP_NAME — skipping route checks"
fi

# ── 4.4 Service endpoints ────────────────────────────────────
log "Checking service endpoint availability..."
SVC_ENDPOINTS=$(oc get endpoints "$APP_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)

if [[ -n "$SVC_ENDPOINTS" ]]; then
  EP_COUNT=$(echo "$SVC_ENDPOINTS" | wc -w)
  pass "Service has $EP_COUNT endpoint(s) registered: $SVC_ENDPOINTS"
else
  fail "No endpoints registered for service/$APP_NAME — pods may not be matching service selector"
fi

# ── 4.5 HPA status ───────────────────────────────────────────
log "Checking HorizontalPodAutoscaler..."
HPA_STATUS=$(oc get hpa "$APP_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.currentReplicas}/{.spec.maxReplicas} (CPU: {.status.currentCPUUtilizationPercentage}%)' \
  2>/dev/null || echo "")

if [[ -n "$HPA_STATUS" ]]; then
  pass "HPA status: $HPA_STATUS"
else
  warn "No HPA found for $APP_NAME (may not be required)"
fi

# JUnit
cat > "$REPORT_DIR/junit-04-ocp-resources.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="OCP_Resources" tests="$((CHECKS_PASSED+CHECKS_FAILED))" failures="$CHECKS_FAILED">
$(grep "|" "$REPORT_DIR/check-results.txt" 2>/dev/null | tail -20 | while IFS="|" read -r status msg; do
  SAFE=$(echo "$msg" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g;s/"/\&quot;/g')
  [[ "$status" == "FAIL" ]] \
    && echo "  <testcase name=\"$SAFE\"><failure>$SAFE</failure></testcase>" \
    || echo "  <testcase name=\"$SAFE\"/>"
done)
</testsuite>
EOF

[[ "$CHECKS_FAILED" -gt 0 ]] && { echo "FAIL" > "$REPORT_DIR/overall-status.txt"; exit 1; }
log "Resources and route checks complete"
