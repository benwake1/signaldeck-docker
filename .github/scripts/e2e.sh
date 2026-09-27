#!/usr/bin/env bash
#
# End-to-end check of a running SignalDeck stack: creates a Cypress and a
# Playwright project through the REST API, runs each against the ci-fixture
# branch of this repo and checks the results, browser and artifacts.
#
# The fixture only visits the container's own pages, so nothing here depends
# on an outside website. Each runner has 3 tests with exactly 1 intentional
# failure (per Playwright browser).
#
# Usage (from the repo root, with the stack up and .env in place):
#   .github/scripts/e2e.sh
#
# Env: API_URL (default http://localhost:8080/api/v1), SERVICE (signaldeck),
#      FIXTURE_REPO, FIXTURE_BRANCH (ci-fixture), RUN_TIMEOUT (seconds, 900).

set -euo pipefail

API_URL=${API_URL:-http://localhost:8080/api/v1}
SERVICE=${SERVICE:-signaldeck}
FIXTURE_REPO=${FIXTURE_REPO:-https://github.com/benwake1/signaldeck-docker.git}
FIXTURE_BRANCH=${FIXTURE_BRANCH:-ci-fixture}
RUN_TIMEOUT=${RUN_TIMEOUT:-900}
PW_BROWSERS='["chromium","firefox","webkit"]'

env_value() { grep -E "^$1=" .env | tail -1 | cut -d= -f2-; }
fail() { echo "::error::$*"; exit 1; }

token=$(jq -n --arg e "$(env_value ADMIN_EMAIL)" --arg p "$(env_value ADMIN_PASSWORD)" '{email:$e,password:$p}' \
    | curl -fsS -X POST "$API_URL/auth/login" -H 'Accept: application/json' -H 'Content-Type: application/json' -d @- \
    | jq -r .token)
[[ -n "$token" && "$token" != null ]] || fail "API login failed"

api() {
    curl -sS --fail-with-body -X "$1" "$API_URL$2" \
        -H "Authorization: Bearer $token" -H 'Accept: application/json' -H 'Content-Type: application/json' \
        ${3:+-d "$3"}
}

# On amd64 the image ships Chrome and the app always runs Cypress in it;
# on arm64 Cypress falls back to its bundled Electron.
if docker compose exec -T "$SERVICE" test -x /usr/local/bin/chrome-cypress; then
    cypress_browser=Chrome
else
    cypress_browser=Electron
fi

# Client and project names must be unique; a timestamp keeps the script
# re-runnable against the same stack.
stamp=$(date -u +%Y%m%d-%H%M%S)
client_id=$(api POST /clients "{\"name\":\"CI e2e ${stamp}\"}" | jq -r .data.id)

# run_fixture <runner> <expected total> <expected failed>
run_fixture() {
    local runner=$1 want_total=$2 want_failed=$3
    local project_id suite_json suite_id run_id run status log results

    echo "── ${runner} ──────────────────────────────────────────"
    project_id=$(api POST /projects "$(jq -n --argjson c "$client_id" --arg r "$runner" \
        --arg u "$FIXTURE_REPO" --arg b "$FIXTURE_BRANCH" --arg s "$stamp" \
        '{client_id:$c,name:"CI \($r) \($s)",repo_url:$u,default_branch:$b,runner_type:$r}')" | jq -r .data.id)

    suite_json='{"name":"CI fixture","timeout_minutes":15}'
    if [[ $runner == playwright ]]; then
        local found
        found=$(api POST "/projects/${project_id}/discover-projects" | jq -c '.projects | sort')
        echo "Discovered Playwright projects: ${found}"
        [[ "$found" == "$(jq -c 'sort' <<< "$PW_BROWSERS")" ]] \
            || fail "Playwright discovery returned ${found}, expected ${PW_BROWSERS}"
        suite_json=$(jq -c --argjson p "$PW_BROWSERS" '. + {playwright_projects:$p}' <<< "$suite_json")
    fi
    suite_id=$(api POST "/projects/${project_id}/suites" "$suite_json" | jq -r .data.id)

    run_id=$(api POST /test-runs "{\"project_id\":${project_id},\"test_suite_id\":${suite_id}}" | jq -r .data.id)
    echo "Run ${run_id} started"

    local waited=0
    while :; do
        run=$(api GET "/test-runs/${run_id}")
        status=$(jq -r .data.status <<< "$run")
        [[ $status =~ ^(passing|failed|error|cancelled)$ ]] && break
        (( waited >= RUN_TIMEOUT )) && { api GET "/test-runs/${run_id}/logs" | jq -r .log_output; fail "${runner} run still ${status} after ${RUN_TIMEOUT}s"; }
        sleep 10; waited=$((waited + 10))
    done

    log=$(api GET "/test-runs/${run_id}/logs" | jq -r .log_output)
    show_log() { echo "$log"; echo "Run: $(jq -c '.data | {status,total_tests,passed_tests,failed_tests,error_message}' <<< "$run")"; }

    local total failed
    total=$(jq -r .data.total_tests <<< "$run")
    failed=$(jq -r .data.failed_tests <<< "$run")
    echo "Finished in ${waited}s: status=${status} total=${total} failed=${failed}"
    [[ $status == failed && $total == "$want_total" && $failed == "$want_failed" ]] \
        || { show_log; fail "${runner}: expected status failed, ${want_total} tests, ${want_failed} failed"; }

    if [[ $runner == cypress ]]; then
        grep -qE "Browser: +(Custom )?${cypress_browser}" <<< "$log" \
            || { show_log; fail "cypress: did not run in ${cypress_browser}"; }
        echo "Browser: ${cypress_browser}"
    fi

    results=$(api GET "/test-runs/${run_id}/results")
    jq -e '[.data[] | select(.status == "failed") | select((.screenshot_paths // []) | length > 0)] | length > 0' <<< "$results" > /dev/null \
        || { echo "$results" | jq '.data[] | {full_title,status,screenshot_paths,video_path}'; fail "${runner}: no screenshot on the failed test"; }
    jq -e '[.data[] | select(.video_path != null)] | length > 0' <<< "$results" > /dev/null \
        || { echo "$results" | jq '.data[] | {full_title,status,screenshot_paths,video_path}'; fail "${runner}: no video recorded"; }

    api GET "/test-runs/${run_id}/report" > /dev/null || fail "${runner}: report endpoint failed"
    echo "Screenshots, video and report OK"
}

run_fixture cypress 3 1
run_fixture playwright 9 3
echo "End-to-end: OK"
