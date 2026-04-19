#!/usr/bin/env bash
# ============================================================
# scripts/03-ocp-pods.sh
# Stage: ocp-platform-checks
# Validates pod readiness, restart counts, and event warnings
# ============================================================
set -euo pipefail
source scripts/lib/logger.sh
source scripts/lib/thresholds.sh

section "OpenShift Pod Health Checks"
oc_login

# ── 3.1 Pod readiness count ──────────────────────────────────
log "Checking pod readiness for app=$APP_NAME in $NAMESPACE..."
DESIRED=$(oc get deployment "$APP_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
READY=$(oc get deployment "$APP_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
AVAILABLE=$(oc get deployment "$APP_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo "0")
READY=${READY:-0}; AVAILABLE=${AVAILABLE:-0}

log "Desired: $DESIRED | Ready: $READY | Available: $AVAILABLE"
set_state "PODS_DESIRED"   "$DESIRED"
set_state "PODS_READY"     "$READY"

READY_PCT=$(python3 -c "print(round($READY/$DESIRED*100) if $DESIRED>0 else 0)" 2>/dev/null || echo "0")
if [[ "$READY_PCT" -ge "$MIN_READY_RATIO" ]]; then
  pass "Pod readiness: $READY/$DESIRED (${READY_PCT}%) — meets ${MIN_READY_RATIO}% threshold"
else
  fail "Pod readiness: only $READY/$DESIRED ready (${READY_PCT}%) — threshold ${MIN_READY_RATIO}%"
fi

# ── 3.2 CrashLoopBackOff / OOMKilled / Error states ─────────
log "Scanning for crash/error pod states..."
while IFS= read -r LINE; do
  POD_NAME=$(echo "$LINE" | awk '{print $1}')
  REASON=$(echo "$LINE"   | awk '{print $2}')
  [[ -z "$POD_NAME" ]] && continue
  case "$REASON" in
    CrashLoopBackOff) fail "Pod $POD_NAME — CrashLoopBackOff" ;;
    OOMKilled)        fail "Pod $POD_NAME — OOMKilled (memory limit breached)" ;;
    Error|ImagePullBackOff|ErrImagePull)
                      fail "Pod $POD_NAME — $REASON" ;;
    "")               ;;   # running fine
    *)                warn "Pod $POD_NAME — unexpected state: $REASON" ;;
  esac
done < <(oc get pods -n "$NAMESPACE" -l "app=$APP_NAME" \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.containerStatuses[*]}{.state.waiting.reason}{"\n"}{end}{end}' \
  2>/dev/null || true)

# ── 3.3 Restart count per pod ────────────────────────────────
log "Checking restart counts..."
RESTART_ISSUES=0
while IFS= read -r LINE; do
  [[ -z "$LINE" ]] && continue
  POD=$(echo "$LINE" | awk '{print $1}')
  RESTARTS=$(echo "$LINE" | awk '{print $2}')
  if [[ "$RESTARTS" -gt 3 ]]; then
    fail "Pod $POD has $RESTARTS restarts — investigate"
    ((RESTART_ISSUES++)) || true
  elif [[ "$RESTARTS" -gt 0 ]]; then
    warn "Pod $POD has $RESTARTS restart(s) since deploy"
  fi
done < <(oc get pods -n "$NAMESPACE" -l "app=$APP_NAME" \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].restartCount}{"\n"}{end}' \
  2>/dev/null || true)

[[ "$RESTART_ISSUES" -eq 0 ]] && pass "Restart counts within acceptable range"

# ── 3.4 Pod conditions ───────────────────────────────────────
log "Checking pod conditions (PodScheduled, Initialized, ContainersReady, Ready)..."
while IFS= read -r POD; do
  [[ -z "$POD" ]] && continue
  NOT_READY=$(oc get pod "$POD" -n "$NAMESPACE" \
    -o jsonpath='{range .status.conditions[?(@.status=="False")]}{.type}:{.message}{"\n"}{end}' \
    2>/dev/null || true)
  if [[ -n "$NOT_READY" ]]; then
    fail "Pod $POD has unmet conditions: $NOT_READY"
  else
    pass "Pod $POD — all conditions satisfied"
  fi
done < <(oc get pods -n "$NAMESPACE" -l "app=$APP_NAME" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

# ── 3.5 Recent warning events ────────────────────────────────
log "Fetching recent warning events for $NAMESPACE..."
EVENTS=$(oc get events -n "$NAMESPACE" \
  --sort-by='.lastTimestamp' \
  --field-selector "type=Warning" 2>/dev/null | \
  grep -i "$APP_NAME" | tail -10 || true)

if [[ -z "$EVENTS" ]]; then
  pass "No warning events for $APP_NAME"
else
  warn "Warning events detected:\n$EVENTS"
fi

# ── 3.6 Dump pod list to artifact ────────────────────────────
oc get pods -n "$NAMESPACE" -l "app=$APP_NAME" \
  -o wide 2>/dev/null > "$REPORT_DIR/pod-list.txt" || true
log "Pod list saved to $REPORT_DIR/pod-list.txt"

# JUnit
cat > "$REPORT_DIR/junit-03-ocp-pods.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="OCP_PodHealth" tests="$((CHECKS_PASSED+CHECKS_FAILED))" failures="$CHECKS_FAILED">
$(grep "|" "$REPORT_DIR/check-results.txt" 2>/dev/null | tail -30 | while IFS="|" read -r status msg; do
  SAFE=$(echo "$msg" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g;s/"/\&quot;/g')
  [[ "$status" == "FAIL" ]] \
    && echo "  <testcase name=\"$SAFE\"><failure>$SAFE</failure></testcase>" \
    || echo "  <testcase name=\"$SAFE\"/>"
done)
</testsuite>
EOF

[[ "$CHECKS_FAILED" -gt 0 ]] && { echo "FAIL" > "$REPORT_DIR/overall-status.txt"; exit 1; }
log "Pod health checks complete"
