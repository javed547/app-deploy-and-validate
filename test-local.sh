#!/usr/bin/env bash
# ============================================================
# test-local.sh
# Run the full pipeline locally WITHOUT GitLab
# Supports dry-run mode (mocks all OCP/AppD/ELK calls)
#
# Usage:
#   ./test-local.sh                         # dry-run with mocks
#   ./test-local.sh --live                  # real cluster (needs oc login + env vars)
#   ./test-local.sh --stage http            # run only one stage
#   ./test-local.sh --dry-run --stage ocp   # dry-run single stage
# ============================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

# ── Defaults ─────────────────────────────────────────────────
DRY_RUN=true
SINGLE_STAGE=""
REPORT_DIR="health-reports"
LOG_FILE="$REPORT_DIR/local-test-$(date +%Y%m%d_%H%M%S).log"

# ── Parse args ───────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --live)       DRY_RUN=false ;;
    --dry-run)    DRY_RUN=true  ;;
    --stage)      SINGLE_STAGE="$2"; shift ;;
    -h|--help)
      echo "Usage: $0 [--live] [--dry-run] [--stage <name>]"
      echo "Stages: env | ocp-rollout | ocp-pods | ocp-resources | http | appdynamics | elk | report"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

mkdir -p "$REPORT_DIR"
touch "$REPORT_DIR/check-results.txt"
touch "$REPORT_DIR/pipeline-state.env"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Local Pipeline Test Runner"
echo "  Mode:  $( $DRY_RUN && echo 'DRY-RUN (mocked)' || echo 'LIVE')"
echo "  Stage: ${SINGLE_STAGE:-all}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Set test pipeline variables ──────────────────────────────
export APP_NAME="${APP_NAME:-my-app}"
export NAMESPACE="${NAMESPACE:-my-namespace}"
export APP_VERSION="${APP_VERSION:-1.2.3}"
export STABILIZE_WAIT="${STABILIZE_WAIT:-0}"    # skip wait in local tests
export ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-60}"
export REPORT_DIR="$REPORT_DIR"
export LOG_FILE="$LOG_FILE"

# Source lib
source scripts/lib/logger.sh
source scripts/lib/thresholds.sh

# ── DRY-RUN: Mock external commands ──────────────────────────
if $DRY_RUN; then
  log "DRY-RUN mode: installing mock overrides..."

  # Mock oc
  OC_MOCK="$REPORT_DIR/.mock-bin/oc"
  mkdir -p "$REPORT_DIR/.mock-bin"
  cat > "$OC_MOCK" <<'OCMOCK'
#!/usr/bin/env bash
# Mock oc for local testing
case "$*" in
  *"login"*)
    echo "Logged into mock cluster as mock-user" ;;
  *"whoami --show-server"*)
    echo "https://mock-ocp.example.com:6443" ;;
  *"whoami"*)
    echo "mock-user" ;;
  *"get namespace"*)
    echo "mock-namespace  Active  5d" ;;
  *"rollout status"*)
    echo "deployment \"$APP_NAME\" successfully rolled out" ;;
  *"rollout history"*)
    echo "REVISION  CHANGE-CAUSE"; echo "1         <none>"; echo "2         v$APP_VERSION" ;;
  *"get deployment"*"replicas"*)
    echo "3" ;;
  *"get deployment"*"readyReplicas"*)
    echo "3" ;;
  *"get deployment"*"availableReplicas"*)
    echo "3" ;;
  *"get deployment"*"image"*)
    echo "registry.example.com/my-app:${APP_VERSION:-1.2.3}" ;;
  *"get deployment"*"resources"*)
    echo '{"limits":{"cpu":"500m","memory":"512Mi"},"requests":{"cpu":"250m","memory":"256Mi"}}' ;;
  *"get pods"*"jsonpath"*"metadata.name"*)
    echo "my-app-abc-1"; echo "my-app-abc-2"; echo "my-app-abc-3" ;;
  *"get pods"*"containerStatuses"*)
    echo "" ;;  # no crashes
  *"get pods"*"restartCount"*)
    printf "my-app-abc-1 0\nmy-app-abc-2 0\nmy-app-abc-3 1\n" ;;
  *"get pod"*"conditions"*)
    echo "" ;;  # all conditions true
  *"get pods"*"-o wide"*)
    printf "NAME          READY  STATUS   RESTARTS  AGE  IP\n"
    printf "my-app-abc-1  1/1    Running  0         2m   10.0.0.1\n"
    printf "my-app-abc-2  1/1    Running  0         2m   10.0.0.2\n"
    printf "my-app-abc-3  1/1    Running  1         2m   10.0.0.3\n" ;;
  *"adm top pods"*)
    printf "NAME          CPU(cores)  MEMORY(bytes)\n"
    printf "my-app-abc-1  150m        210Mi\n"
    printf "my-app-abc-2  180m        225Mi\n" ;;
  *"get route"*"spec.host"*)
    echo "my-app.apps.mock-ocp.example.com" ;;
  *"get routes"*"spec.host"*)
    echo "my-app.apps.mock-ocp.example.com" ;;
  *"get endpoints"*)
    printf '{"subsets":[{"addresses":[{"ip":"10.0.0.1"},{"ip":"10.0.0.2"},{"ip":"10.0.0.3"}]}]}\n' ;;
  *"get hpa"*)
    echo "3/10 (CPU: 42%)" ;;
  *"get events"*)
    echo "" ;;  # no events
  *"exec"*)
    # Simulate log file existence check
    if echo "$*" | grep -q "\[ -f"; then
      echo "no"  # trigger stdout fallback
    else
      echo ""
    fi ;;
  *"logs"*)
    # Emit mock access log lines (Combined Log Format)
    for i in $(seq 1 200); do
      STATUS=$( (( RANDOM % 20 == 0 )) && echo "500" || echo "200")
      DUR=$(( RANDOM % 400 + 50 ))
      echo "10.0.0.1 - - [$(date '+%d/%b/%Y:%H:%M:%S +0000')] \"GET /api/resource/$i HTTP/1.1\" $STATUS 512 \"-\" \"curl/7.68\" $DUR"
    done
    for i in $(seq 1 20); do
      echo "10.0.0.1 - - [$(date '+%d/%b/%Y:%H:%M:%S +0000')] \"POST /api/data HTTP/1.1\" 201 256 \"-\" \"java-client\" $((RANDOM % 100 + 30))"
    done
    echo "10.0.0.1 - - [$(date '+%d/%b/%Y:%H:%M:%S +0000')] \"GET /actuator/health HTTP/1.1\" 200 42 \"-\" \"probe\" 5" ;;
  *)
    echo "mock-oc: unhandled args: $*" >&2 ;;
esac
OCMOCK
  chmod +x "$OC_MOCK"

  # Mock curl (health endpoint + AppDynamics + ES)
  CURL_MOCK="$REPORT_DIR/.mock-bin/curl"
  cat > "$CURL_MOCK" <<'CURLMOCK'
#!/usr/bin/env bash
ARGS="$*"
if echo "$ARGS" | grep -q "appdynamics\|controller/rest"; then
  if echo "$ARGS" | grep -q "Calls per Minute"; then
    echo '[{"metricName":"Calls per Minute","metricValues":[{"value":120}]}]'
  elif echo "$ARGS" | grep -q "Errors per Minute"; then
    echo '[{"metricName":"Errors per Minute","metricValues":[{"value":2}]}]'
  elif echo "$ARGS" | grep -q "Average Response Time"; then
    echo '[{"metricName":"Average Response Time (ms)","metricValues":[{"value":340}]}]'
  elif echo "$ARGS" | grep -q "95th Percentile"; then
    echo '[{"metricName":"95th Percentile","metricValues":[{"value":850}]}]'
  elif echo "$ARGS" | grep -q "healthrule-violations"; then
    echo '[]'
  elif echo "$ARGS" | grep -q "business-transactions"; then
    echo '[{"name":"/api/resource","callsPerMinute":80},{"name":"/api/data","callsPerMinute":40}]'
  else
    echo '[]'
  fi
elif echo "$ARGS" | grep -q "elasticsearch\|9200"; then
  echo '{"hits":{"total":{"value":3},"hits":[{"_source":{"message":"mock error","log.level":"ERROR","@timestamp":"2024-01-01T00:00:00Z","kubernetes.pod.name":"mock-pod"}}]}}'
elif echo "$ARGS" | grep -q "health\|/ping\|/status"; then
  echo -n "200"
else
  echo -n "200"
fi
CURLMOCK
  chmod +x "$CURL_MOCK"

  # Prepend mock bin to PATH
  export PATH="$REPORT_DIR/.mock-bin:$PATH"

  # Dummy OCP vars (not real)
  export OCP_API_URL="https://mock-ocp.example.com:6443"
  export OCP_TOKEN="mock-token-for-dry-run"
  export APPD_CONTROLLER_URL="https://mock.appdynamics.com"
  export APPD_API_KEY="mock-appd-key"
  export APPD_APP_NAME="mock-app"
  export ELASTICSEARCH_URL="https://mock-elasticsearch:9200"
  export ELK_AUTH="bW9jazptb2Nr"  # mock:mock

  log "Mock overrides installed — all external calls are simulated"
fi

# ── Stage runner ─────────────────────────────────────────────
run_stage() {
  local name="$1"; local script="$2"
  echo ""
  echo "┌─────────────────────────────────────────────────────"
  echo "│ STAGE: $name"
  echo "└─────────────────────────────────────────────────────"
  if bash "$script" 2>&1 | tee -a "$LOG_FILE"; then
    echo "  → Stage $name: ✔ PASSED"
  else
    echo "  → Stage $name: ✘ FAILED (exit $?)"
    # In local test, continue to next stage (don't exit)
  fi
}

# ── Execute stages ───────────────────────────────────────────
declare -A STAGE_MAP=(
  ["env"]="scripts/01-validate-env.sh"
  ["ocp-rollout"]="scripts/02-ocp-rollout.sh"
  ["ocp-pods"]="scripts/03-ocp-pods.sh"
  ["ocp-resources"]="scripts/04-ocp-resources.sh"
  ["http"]="scripts/05-http-categorization.sh"
  ["appdynamics"]="scripts/06-appdynamics.sh"
  ["elk"]="scripts/07-elk-analysis.sh"
  ["report"]="scripts/08-final-report.sh"
)

STAGE_ORDER=(env ocp-rollout ocp-pods ocp-resources http appdynamics elk report)

if [[ -n "$SINGLE_STAGE" ]]; then
  SCRIPT="${STAGE_MAP[$SINGLE_STAGE]:-}"
  [[ -z "$SCRIPT" ]] && { echo "Unknown stage: $SINGLE_STAGE"; exit 1; }
  run_stage "$SINGLE_STAGE" "$SCRIPT"
else
  for STAGE in "${STAGE_ORDER[@]}"; do
    run_stage "$STAGE" "${STAGE_MAP[$STAGE]}"
  done
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
FINAL=$(cat "$REPORT_DIR/overall-status.txt" 2>/dev/null || echo "UNKNOWN")
echo "  Local Test Complete — Final Status: $FINAL"
echo "  Reports: $REPORT_DIR/"
echo "  Log:     $LOG_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[[ "$FINAL" != "PASS" ]] && [[ "$FINAL" != "WARN" ]] && exit 1 || exit 0
