#!/usr/bin/env bash
# ============================================================
# scripts/07-elk-analysis.sh
# Stage: elk-checks
# Elasticsearch/ELK log analysis for post-deploy validation
# ============================================================
set -euo pipefail
source scripts/lib/logger.sh
source scripts/lib/thresholds.sh

section "ELK Stack Log Analysis"

[[ -z "${ELASTICSEARCH_URL:-}" ]] && { warn "ELASTICSEARCH_URL not set — skipping"; exit 0; }

INDEX="${ELK_INDEX:-app-logs-prod-*}"
AUTH_HEADER=""
[[ -n "${ELK_AUTH:-}" ]] && AUTH_HEADER="-H \"Authorization: Basic $ELK_AUTH\""

# ── Helper: ES query ─────────────────────────────────────────
es_search() {
  local index="$1"; local body="$2"
  curl -sf "${ELASTICSEARCH_URL}/${index}/_search" \
    ${ELK_AUTH:+-H "Authorization: Basic $ELK_AUTH"} \
    -H "Content-Type: application/json" \
    -d "$body" 2>/dev/null || echo '{"hits":{"total":{"value":-1},"hits":[]}}'
}

get_hit_count() {
  python3 -c "import sys,json; print(json.load(sys.stdin)['hits']['total']['value'])" 2>/dev/null || echo "-1"
}

# ── 7.1 Error / Fatal log count (last 15 min) ────────────────
log "Counting ERROR/FATAL log entries (last 15 min)..."
ERROR_Q=$(cat <<'EOF'
{
  "query": {
    "bool": {
      "must": [
        {"range": {"@timestamp": {"gte": "now-15m"}}},
        {"terms": {"log.level": ["ERROR","FATAL","error","fatal","SEVERE"]}}
      ],
      "filter": [
        {"term": {"kubernetes.namespace.keyword": "NAMESPACE_PLACEHOLDER"}},
        {"term": {"kubernetes.labels.app.keyword": "APP_PLACEHOLDER"}}
      ]
    }
  },
  "aggs": {
    "by_logger": {"terms": {"field": "log.logger.keyword", "size": 10}},
    "by_level":  {"terms": {"field": "log.level.keyword",  "size":  5}}
  },
  "size": 5,
  "_source": ["@timestamp", "message", "log.level", "kubernetes.pod.name"]
}
EOF
)
ERROR_Q="${ERROR_Q/NAMESPACE_PLACEHOLDER/$NAMESPACE}"
ERROR_Q="${ERROR_Q/APP_PLACEHOLDER/$APP_NAME}"

ERROR_RESP=$(es_search "$INDEX" "$ERROR_Q")
ERROR_COUNT=$(echo "$ERROR_RESP" | get_hit_count)

if [[ "$ERROR_COUNT" -eq -1 ]]; then
  warn "Could not reach Elasticsearch — check URL/auth"
elif [[ "$ERROR_COUNT" -le "$LOG_ERROR_THRESHOLD" ]]; then
  pass "Error log count: $ERROR_COUNT (threshold: $LOG_ERROR_THRESHOLD)"
else
  fail "High error count: $ERROR_COUNT errors in last 15 min (threshold: $LOG_ERROR_THRESHOLD)"
  # Print sample error messages
  echo "$ERROR_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for h in d['hits']['hits']:
    s = h.get('_source', {})
    print(f\"  [{s.get('log.level','?')}] {s.get('@timestamp','?')} — {str(s.get('message',''))[:120]}\")
" 2>/dev/null | tee -a "$LOG_FILE" || true
fi

set_state "ELK_ERROR_COUNT" "${ERROR_COUNT:-0}"

# ── 7.2 Exception / Stack trace detection ────────────────────
log "Scanning for Java/Python/Node exceptions and stack traces..."
EXCEPTION_Q=$(cat <<'EOF'
{
  "query": {
    "bool": {
      "must": [
        {"range": {"@timestamp": {"gte": "now-15m"}}},
        {"term": {"kubernetes.namespace.keyword": "NAMESPACE_PLACEHOLDER"}},
        {"term": {"kubernetes.labels.app.keyword": "APP_PLACEHOLDER"}}
      ],
      "should": [
        {"match_phrase": {"message": "Exception"}},
        {"match_phrase": {"message": "OutOfMemoryError"}},
        {"match_phrase": {"message": "NullPointerException"}},
        {"match_phrase": {"message": "StackOverflowError"}},
        {"match_phrase": {"message": "Traceback (most recent call last)"}},
        {"match_phrase": {"message": "UnhandledPromiseRejection"}},
        {"match_phrase": {"message": "FATAL ERROR"}},
        {"match_phrase": {"message": "Caused by:"}}
      ],
      "minimum_should_match": 1
    }
  },
  "size": 5,
  "_source": ["@timestamp", "message", "kubernetes.pod.name", "log.level"]
}
EOF
)
EXCEPTION_Q="${EXCEPTION_Q/NAMESPACE_PLACEHOLDER/$NAMESPACE}"
EXCEPTION_Q="${EXCEPTION_Q/APP_PLACEHOLDER/$APP_NAME}"

EXCEPTION_RESP=$(es_search "$INDEX" "$EXCEPTION_Q")
EXCEPTION_COUNT=$(echo "$EXCEPTION_RESP" | get_hit_count)

if [[ "$EXCEPTION_COUNT" -eq 0 ]]; then
  pass "No critical exceptions found in logs"
elif [[ "$EXCEPTION_COUNT" -gt 0 ]]; then
  fail "$EXCEPTION_COUNT exception(s) detected"
  echo "$EXCEPTION_RESP" | python3 -c "
import sys, json
for h in json.load(sys.stdin)['hits']['hits']:
    s = h.get('_source', {})
    print(f\"  POD: {s.get('kubernetes.pod.name','?')} | {str(s.get('message',''))[:140]}\")
" 2>/dev/null | tee -a "$LOG_FILE" || true
fi

# ── 7.3 Log volume spike (compare 30-15 min ago vs last 15 min) ──
log "Checking log volume for spikes..."
BASELINE_Q='{"query":{"bool":{"must":[{"range":{"@timestamp":{"gte":"now-30m","lte":"now-15m"}}},{"term":{"kubernetes.namespace.keyword":"NAMESPACE_PLACEHOLDER"}},{"term":{"kubernetes.labels.app.keyword":"APP_PLACEHOLDER"}}]}},"size":0}'
CURRENT_Q='{"query":{"bool":{"must":[{"range":{"@timestamp":{"gte":"now-15m"}}},{"term":{"kubernetes.namespace.keyword":"NAMESPACE_PLACEHOLDER"}},{"term":{"kubernetes.labels.app.keyword":"APP_PLACEHOLDER"}}]}},"size":0}'

BASELINE_Q="${BASELINE_Q/NAMESPACE_PLACEHOLDER/$NAMESPACE}"; BASELINE_Q="${BASELINE_Q/APP_PLACEHOLDER/$APP_NAME}"
CURRENT_Q="${CURRENT_Q/NAMESPACE_PLACEHOLDER/$NAMESPACE}";   CURRENT_Q="${CURRENT_Q/APP_PLACEHOLDER/$APP_NAME}"

BASELINE=$(es_search "$INDEX" "$BASELINE_Q" | get_hit_count)
CURRENT=$(es_search  "$INDEX" "$CURRENT_Q"  | get_hit_count)
BASELINE=${BASELINE:-1}; [[ "$BASELINE" -eq 0 ]] && BASELINE=1

SPIKE=$(python3 -c "print(round($CURRENT/$BASELINE, 2))" 2>/dev/null || echo "1.0")

if (( $(echo "$SPIKE <= 3.0" | bc -l 2>/dev/null || echo 1) )); then
  pass "Log volume normal — current/baseline ratio: ${SPIKE}x (baseline: $BASELINE, current: $CURRENT)"
else
  warn "Log volume spike: ${SPIKE}x baseline — may indicate cascading error"
fi

# ── 7.4 Slow query / timeout patterns ───────────────────────
log "Searching for timeout and slow query patterns..."
TIMEOUT_Q=$(cat <<'EOF'
{
  "query": {
    "bool": {
      "must": [
        {"range": {"@timestamp": {"gte": "now-15m"}}},
        {"term": {"kubernetes.namespace.keyword": "NAMESPACE_PLACEHOLDER"}},
        {"term": {"kubernetes.labels.app.keyword": "APP_PLACEHOLDER"}}
      ],
      "should": [
        {"match_phrase": {"message": "timeout"}},
        {"match_phrase": {"message": "timed out"}},
        {"match_phrase": {"message": "connection refused"}},
        {"match_phrase": {"message": "connection reset"}},
        {"match_phrase": {"message": "slow query"}},
        {"match_phrase": {"message": "circuit breaker"}}
      ],
      "minimum_should_match": 1
    }
  },
  "size": 0
}
EOF
)
TIMEOUT_Q="${TIMEOUT_Q/NAMESPACE_PLACEHOLDER/$NAMESPACE}"
TIMEOUT_Q="${TIMEOUT_Q/APP_PLACEHOLDER/$APP_NAME}"

TIMEOUT_COUNT=$(es_search "$INDEX" "$TIMEOUT_Q" | get_hit_count)
if [[ "$TIMEOUT_COUNT" -eq 0 ]]; then
  pass "No timeout/connection error patterns in logs"
elif [[ "$TIMEOUT_COUNT" -le 5 ]]; then
  warn "Minor timeout occurrences: $TIMEOUT_COUNT (investigate if rising)"
else
  fail "Elevated timeout/connection errors: $TIMEOUT_COUNT — downstream dependency issue likely"
fi

# ── 7.5 HTTP error log correlation (from app logs) ───────────
log "Correlating HTTP 5xx patterns in application logs..."
HTTP5XX_Q=$(cat <<'EOF'
{
  "query": {
    "bool": {
      "must": [
        {"range": {"@timestamp": {"gte": "now-15m"}}},
        {"term": {"kubernetes.namespace.keyword": "NAMESPACE_PLACEHOLDER"}},
        {"term": {"kubernetes.labels.app.keyword": "APP_PLACEHOLDER"}},
        {"regexp": {"message": "HTTP.*5[0-9]{2}|5[0-9]{2}.*HTTP|status.*5[0-9]{2}"}}
      ]
    }
  },
  "aggs": {
    "status_codes": {
      "terms": {"field": "http.response.status_code", "size": 10}
    }
  },
  "size": 0
}
EOF
)
HTTP5XX_Q="${HTTP5XX_Q/NAMESPACE_PLACEHOLDER/$NAMESPACE}"
HTTP5XX_Q="${HTTP5XX_Q/APP_PLACEHOLDER/$APP_NAME}"

HTTP5XX_COUNT=$(es_search "$INDEX" "$HTTP5XX_Q" | get_hit_count)
if [[ "$HTTP5XX_COUNT" -le 5 ]]; then
  pass "HTTP 5xx log entries: $HTTP5XX_COUNT — acceptable"
else
  fail "HTTP 5xx patterns in logs: $HTTP5XX_COUNT entries"
fi

# ── Save ELK summary ─────────────────────────────────────────
cat > "$REPORT_DIR/elk-summary.json" <<EOF
{
  "index":            "$INDEX",
  "duration_mins":    15,
  "error_count":      ${ERROR_COUNT:--1},
  "exception_count":  ${EXCEPTION_COUNT:-0},
  "log_spike_ratio":  ${SPIKE:-1.0},
  "timeout_count":    ${TIMEOUT_COUNT:-0},
  "http5xx_log_count":${HTTP5XX_COUNT:-0}
}
EOF

# JUnit
cat > "$REPORT_DIR/junit-07-elk.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="ELK_LogAnalysis" tests="$((CHECKS_PASSED+CHECKS_FAILED))" failures="$CHECKS_FAILED">
$(grep "|" "$REPORT_DIR/check-results.txt" 2>/dev/null | tail -20 | while IFS="|" read -r status msg; do
  SAFE=$(echo "$msg" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g;s/"/\&quot;/g')
  [[ "$status" == "FAIL" ]] \
    && echo "  <testcase name=\"$SAFE\"><failure>$SAFE</failure></testcase>" \
    || echo "  <testcase name=\"$SAFE\"/>"
done)
</testsuite>
EOF

[[ "$CHECKS_FAILED" -gt 0 ]] && { echo "FAIL" > "$REPORT_DIR/overall-status.txt"; exit 1; }
log "ELK log analysis complete"
