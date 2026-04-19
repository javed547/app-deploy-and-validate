# Post-Deployment Health Validation Pipeline

GitLab CI/CD pipeline for automated health validation after OpenShift 4.x
deployments, integrating AppDynamics APM and ELK Stack log analysis.

## Repository Structure

```
.
├── .gitlab-ci.yml                   ← GitLab pipeline definition
├── pipeline.env                     ← Configuration template
├── test-local.sh                    ← Local dry-run test runner
└── scripts/
    ├── lib/
    │   ├── logger.sh                ← Shared logging (pass/fail/warn)
    │   └── thresholds.sh            ← Default threshold values
    ├── 01-validate-env.sh           ← Stage: validate-env
    ├── 02-ocp-rollout.sh            ← Stage: ocp-platform-checks
    ├── 03-ocp-pods.sh               ← Stage: ocp-platform-checks
    ├── 04-ocp-resources.sh          ← Stage: ocp-platform-checks
    ├── 05-http-categorization.sh    ← Stage: http-categorization  ← oc exec
    ├── 06-appdynamics.sh            ← Stage: appdynamics-checks
    ├── 07-elk-analysis.sh           ← Stage: elk-checks
    └── 08-final-report.sh           ← Stage: report (HTML + JSON + JUnit)
```

## Pipeline Stages

| Stage | Jobs | What it validates |
|---|---|---|
| `validate-env` | validate-environment | Variables, tools, OCP login, namespace |
| `ocp-platform-checks` | ocp-rollout-status | Rollout complete, correct image version |
| `ocp-platform-checks` | ocp-pod-health | Readiness, crashes, restarts, conditions |
| `ocp-platform-checks` | ocp-resources-and-route | CPU/mem, routes, endpoints, HPA |
| `http-categorization` | http-request-categorization | **oc exec** into pods to parse access logs |
| `appdynamics-checks` | appdynamics-health | Error rate, response time, health rules |
| `elk-checks` | elk-log-analysis | Error count, exceptions, log spikes |
| `report` | health-gate | Final score + HTML report + PASS/FAIL gate |

## Quick Start

### 1. Test locally (dry-run, no real cluster needed)

```bash
git clone <this-repo> && cd gitlab-health-pipeline
chmod +x test-local.sh scripts/*.sh scripts/lib/*.sh

# Dry-run with all mocks (default)
./test-local.sh

# Run a single stage only
./test-local.sh --stage http
./test-local.sh --stage ocp-pods

# Run against real cluster
source pipeline.env          # fill in your real values first
./test-local.sh --live
```

### 2. GitLab Setup

**Step 1 — Add CI/CD Variables** (Settings → CI/CD → Variables):

| Variable | Type | Notes |
|---|---|---|
| `OCP_API_URL` | Variable | OpenShift API URL |
| `OCP_TOKEN` | Variable (Masked) | Service account token |
| `APPD_CONTROLLER_URL` | Variable | AppDynamics controller URL |
| `APPD_API_KEY` | Variable (Masked) | AppDynamics API client secret |
| `ELASTICSEARCH_URL` | Variable | Elasticsearch URL |
| `ELK_AUTH` | Variable (Masked) | base64(user:pass) |

**Step 2 — Trigger manually** (CI/CD → Pipelines → Run Pipeline):

```
APP_NAME=my-app
NAMESPACE=my-app-prod
APP_VERSION=1.2.3
```

**Step 3 — Or trigger via API** after your deploy stage:

```bash
curl -X POST \
  --fail \
  -F token=$CI_JOB_TOKEN \
  -F ref=main \
  -F "variables[APP_NAME]=my-app" \
  -F "variables[NAMESPACE]=my-app-prod" \
  -F "variables[APP_VERSION]=$NEW_VERSION" \
  "https://gitlab.example.com/api/v4/projects/$PROJECT_ID/trigger/pipeline"
```

### 3. Chain into your deploy pipeline

```yaml
# In your application's .gitlab-ci.yml
trigger-health-check:
  stage: post-deploy
  trigger:
    project: platform/health-validation-pipeline
    branch: main
    strategy: depend          # wait for health pipeline to pass
  variables:
    APP_NAME: $CI_PROJECT_NAME
    NAMESPACE: $KUBE_NAMESPACE
    APP_VERSION: $CI_COMMIT_TAG
```

## HTTP Categorization (oc exec Detail)

Script `05-http-categorization.sh` runs `oc exec` on each running pod to:

1. Detect the access log path (tries 5 common locations)
2. Fall back to `oc logs --since=15m` if no file found
3. Run a Python analyser **in the pipeline runner** (no installs inside pod)
4. Categorise requests by: method, status class (2xx/3xx/4xx/5xx), path
5. Flag: 5xx rate > threshold, slow request %, top error paths

No files are written inside the container. The Python script is piped via stdin.

## Output Artifacts

After each run, `health-reports/` contains:

```
health-reports/
├── health-report.html          ← Visual HTML report
├── health-report-final.json    ← Machine-readable summary
├── check-results.txt           ← PASS|FAIL|WARN per check
├── pipeline-state.env          ← Shared state across stages
├── pod-list.txt                ← OCP pod listing
├── http-<pod-name>.json        ← Per-pod HTTP analysis
├── http-aggregate.json         ← Aggregated HTTP stats
├── appdynamics-summary.json    ← AppD metrics snapshot
├── elk-summary.json            ← ELK query results
├── junit-01-*.xml  ..          ← JUnit test reports (GitLab Test tab)
└── pipeline-*.log              ← Full execution log
```

## Thresholds Reference

| Variable | Default | Meaning |
|---|---|---|
| `ERROR_RATE_THRESHOLD` | 5 | Max % AppDynamics error rate |
| `RESPONSE_TIME_THRESHOLD` | 2000 | Max avg response time (ms) |
| `LOG_ERROR_THRESHOLD` | 10 | Max ERROR logs per 15 min |
| `HTTP_5XX_THRESHOLD` | 5 | Max % HTTP 5xx responses |
| `HTTP_SLOW_THRESHOLD` | 3000 | Slow request cutoff (ms) |
| `MIN_READY_RATIO` | 100 | Min % pods that must be Ready |
| `STABILIZE_WAIT` | 60 | Seconds to wait before checking |
| `ROLLOUT_TIMEOUT` | 300 | Max seconds to wait for rollout |

## OCP Service Account Setup

```bash
# Create dedicated SA for the pipeline
oc create serviceaccount gitlab-health-checker -n monitoring

# Grant view on target namespaces
oc adm policy add-role-to-user view \
  system:serviceaccount:monitoring:gitlab-health-checker \
  -n my-app-prod

# Grant exec access for HTTP categorization
oc create role pod-exec \
  --verb=get,list,create --resource=pods,pods/exec,pods/log \
  -n my-app-prod
oc adm policy add-role-to-user pod-exec \
  system:serviceaccount:monitoring:gitlab-health-checker \
  -n my-app-prod

# Get token (OCP 4.x)
oc create token gitlab-health-checker -n monitoring --duration=8760h
```
