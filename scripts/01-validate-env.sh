#!/usr/bin/env bash
# ============================================================
# scripts/01-validate-env.sh
# Stage: validate-env
# Validates all required variables and tool availability
# ============================================================
set -euo pipefail
source scripts/lib/logger.sh
source scripts/lib/thresholds.sh

section "Environment Validation"

ERRORS=0
check_var() {
  local var="$1"; local val="${!var:-}"
  if [[ -z "$val" ]]; then
    fail "Required variable \$$var is not set"
    ((ERRORS++)) || true
  else
    pass "\$$var is set"
  fi
}

check_tool() {
  if command -v "$1" &>/dev/null; then
    pass "Tool available: $1 ($(command -v "$1"))"
  else
    fail "Required tool missing: $1"
    ((ERRORS++)) || true
  fi
}

# Required variables
log "Checking required pipeline variables..."
check_var "APP_NAME"
check_var "NAMESPACE"
check_var "APP_VERSION"
check_var "OCP_API_URL"
check_var "OCP_TOKEN"

# Optional (warn only)
for VAR in APPD_CONTROLLER_URL APPD_API_KEY ELASTICSEARCH_URL ELK_AUTH; do
  if [[ -z "${!VAR:-}" ]]; then
    warn "Optional \$$VAR not set — that check stage will be skipped"
  else
    pass "Optional \$$VAR is configured"
  fi
done

# Required tools
log "Checking required tooling..."
for TOOL in oc curl python3 bc jq; do
  check_tool "$TOOL"
done

# OCP login test
log "Testing OpenShift login..."
oc_login
OCP_USER=$(oc whoami 2>/dev/null || echo "unknown")
OCP_SERVER=$(oc whoami --show-server 2>/dev/null || echo "unknown")
pass "Authenticated as: $OCP_USER @ $OCP_SERVER"

# Namespace existence
if oc get namespace "$NAMESPACE" &>/dev/null; then
  pass "Namespace '$NAMESPACE' exists"
else
  fail "Namespace '$NAMESPACE' not found on cluster"
  ((ERRORS++)) || true
fi

# Persist validated state for downstream jobs
set_state "VALIDATED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
set_state "OCP_USER"     "$OCP_USER"
set_state "OCP_SERVER"   "$OCP_SERVER"

# JUnit output
cat > "$REPORT_DIR/junit-01-validate-env.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="EnvironmentValidation" tests="$((CHECKS_PASSED+CHECKS_FAILED))" failures="$CHECKS_FAILED">
$(grep "|" "$REPORT_DIR/check-results.txt" 2>/dev/null | while IFS="|" read -r status msg; do
  TC_STATUS=$( [[ "$status" == "PASS" ]] && echo "passed" || echo "failed" )
  SAFE_MSG=$(echo "$msg" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')
  if [[ "$TC_STATUS" == "failed" ]]; then
    echo "  <testcase name=\"$SAFE_MSG\"><failure>$SAFE_MSG</failure></testcase>"
  else
    echo "  <testcase name=\"$SAFE_MSG\"/>"
  fi
done)
</testsuite>
EOF

[[ "$ERRORS" -gt 0 ]] && { echo "FAIL" > "$REPORT_DIR/overall-status.txt"; exit 1; }
log "Environment validation complete — all required checks passed"
