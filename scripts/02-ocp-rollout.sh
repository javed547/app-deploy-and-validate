#!/usr/bin/env bash
# ============================================================
# scripts/02-ocp-rollout.sh
# Stage: ocp-platform-checks
# Validates rollout completion and image version
# ============================================================
set -euo pipefail
source scripts/lib/logger.sh
source scripts/lib/thresholds.sh

section "OpenShift Rollout Checks"
oc_login

# ── 2.1 Stabilisation wait ───────────────────────────────────
log "Waiting ${STABILIZE_WAIT}s for application to stabilise post-deploy..."
sleep "$STABILIZE_WAIT"

# ── 2.2 Rollout status ───────────────────────────────────────
log "Checking rollout status for deployment/$APP_NAME in $NAMESPACE..."
if oc rollout status deployment/"$APP_NAME" \
     -n "$NAMESPACE" --timeout="${ROLLOUT_TIMEOUT}s" 2>&1 | tee -a "$LOG_FILE"; then
  pass "Rollout completed successfully within ${ROLLOUT_TIMEOUT}s"
else
  fail "Rollout did not complete within ${ROLLOUT_TIMEOUT}s"
  oc rollout history deployment/"$APP_NAME" -n "$NAMESPACE" 2>&1 | tee -a "$LOG_FILE" || true
  echo "FAIL" > "$REPORT_DIR/overall-status.txt"
  exit 1
fi

# ── 2.3 Deployed image version ───────────────────────────────
log "Validating deployed image contains version tag: $APP_VERSION"
DEPLOYED_IMAGE=$(oc get deployment "$APP_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")

if [[ -z "$DEPLOYED_IMAGE" ]]; then
  fail "Could not retrieve deployed image — is deployment/$APP_NAME present?"
elif echo "$DEPLOYED_IMAGE" | grep -q "$APP_VERSION"; then
  pass "Correct version deployed: $DEPLOYED_IMAGE"
else
  fail "Version mismatch — Expected: *$APP_VERSION* | Found: $DEPLOYED_IMAGE"
fi

set_state "DEPLOYED_IMAGE" "$DEPLOYED_IMAGE"

# ── 2.4 Rollout revision ─────────────────────────────────────
REVISION=$(oc rollout history deployment/"$APP_NAME" -n "$NAMESPACE" 2>/dev/null \
  | tail -2 | head -1 | awk '{print $1}' || echo "unknown")
log "Current rollout revision: $REVISION"
set_state "ROLLOUT_REVISION" "$REVISION"

# JUnit
cat > "$REPORT_DIR/junit-02-ocp-rollout.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="OCP_Rollout" tests="$((CHECKS_PASSED+CHECKS_FAILED))" failures="$CHECKS_FAILED">
$(grep "|" "$REPORT_DIR/check-results.txt" 2>/dev/null | tail -20 | while IFS="|" read -r status msg; do
  SAFE=$(echo "$msg" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')
  [[ "$status" == "FAIL" ]] \
    && echo "  <testcase name=\"$SAFE\"><failure>$SAFE</failure></testcase>" \
    || echo "  <testcase name=\"$SAFE\"/>"
done)
</testsuite>
EOF

[[ "$CHECKS_FAILED" -gt 0 ]] && { echo "FAIL" > "$REPORT_DIR/overall-status.txt"; exit 1; }
log "Rollout validation complete"
