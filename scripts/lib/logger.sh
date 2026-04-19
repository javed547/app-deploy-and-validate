#!/usr/bin/env bash
# ============================================================
# scripts/lib/logger.sh — Shared logging utilities
# ============================================================

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

REPORT_DIR="${REPORT_DIR:-health-reports}"
mkdir -p "$REPORT_DIR"

LOG_FILE="${LOG_FILE:-$REPORT_DIR/pipeline-$(date +%Y%m%d_%H%M%S).log}"
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNED=0

log()     { echo -e "$(date '+%H:%M:%S') INFO  $*" | tee -a "$LOG_FILE"; }
pass()    { echo -e "$(date '+%H:%M:%S') ${GREEN}PASS${NC}  $*" | tee -a "$LOG_FILE"; ((CHECKS_PASSED++)) || true; echo "PASS|$*" >> "$REPORT_DIR/check-results.txt"; }
fail()    { echo -e "$(date '+%H:%M:%S') ${RED}FAIL${NC}  $*" | tee -a "$LOG_FILE"; ((CHECKS_FAILED++)) || true;  echo "FAIL|$*" >> "$REPORT_DIR/check-results.txt"; }
warn()    { echo -e "$(date '+%H:%M:%S') ${YELLOW}WARN${NC}  $*" | tee -a "$LOG_FILE"; ((CHECKS_WARNED++)) || true;  echo "WARN|$*" >> "$REPORT_DIR/check-results.txt"; }
section() { echo -e "\n${CYAN}${BOLD}══════ $* ══════${NC}" | tee -a "$LOG_FILE"; }
die()     { echo -e "${RED}FATAL: $*${NC}" | tee -a "$LOG_FILE"; exit 1; }

# OCP helper — login once, reuse token
oc_login() {
  [[ -z "${OCP_TOKEN:-}" ]]   && die "OCP_TOKEN not set"
  [[ -z "${OCP_API_URL:-}" ]] && die "OCP_API_URL not set"
  oc login "$OCP_API_URL" --token="$OCP_TOKEN" --insecure-skip-tls-verify=true 2>&1 \
    | tee -a "$LOG_FILE" || die "oc login failed"
}

# Write a key=value into shared state file (cross-job artifact)
set_state() { echo "$1=$2" >> "$REPORT_DIR/pipeline-state.env"; }
get_state() { grep "^$1=" "$REPORT_DIR/pipeline-state.env" 2>/dev/null | cut -d= -f2-; }
