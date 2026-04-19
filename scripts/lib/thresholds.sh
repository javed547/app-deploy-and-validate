#!/usr/bin/env bash
# ============================================================
# scripts/lib/thresholds.sh — Centralised threshold defaults
# All values can be overridden by GitLab CI/CD variables
# ============================================================

: "${ERROR_RATE_THRESHOLD:=5}"        # % — AppDynamics error rate
: "${RESPONSE_TIME_THRESHOLD:=2000}"  # ms — avg response time
: "${LOG_ERROR_THRESHOLD:=10}"        # count — ELK error logs / 15 min
: "${HTTP_5XX_THRESHOLD:=5}"          # % — 5xx share of all requests
: "${HTTP_SLOW_THRESHOLD:=3000}"      # ms — "slow" request cutoff
: "${ROLLOUT_TIMEOUT:=300}"           # seconds
: "${STABILIZE_WAIT:=60}"             # seconds
: "${MIN_READY_RATIO:=100}"           # % pods that must be ready
