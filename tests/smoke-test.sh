#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# AGLedger — Smoke Test
# =============================================================================
# Verifies that AGLedger is running and responding correctly.
#
# Phase 1 (unauthenticated): Health, readiness, conformance, schema seeding
# Phase 2 (authenticated):   Record lifecycle — create enterprise, record,
#                             receipt, verify events. Requires platform API key.
# Verify mode:               Read-only checks against previously created data.
#                             Used after upgrade/restore to confirm data survived.
#
# Usage:
#   ./tests/smoke-test.sh                                  # Health only
#   ./tests/smoke-test.sh http://localhost:3001             # Health only, custom URL
#   ./tests/smoke-test.sh http://localhost:3001 --api-key KEY  # Full lifecycle
#   ./tests/smoke-test.sh URL --save-state /tmp/state.json # Save IDs for later verify
#   ./tests/smoke-test.sh URL --verify /tmp/state.json     # Verify saved data exists
#   AGLEDGER_API_KEY=agl_plt_... ./tests/smoke-test.sh     # Key via env var
#
# The script also auto-reads PLATFORM_API_KEY from docker-compose/.env if
# present and no key is provided via flag or env var.
# =============================================================================

BASE_URL="${1:-http://localhost:3001}"
shift || true

FAILURES=0
API_KEY="${AGLEDGER_API_KEY:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAVE_STATE=""
VERIFY_STATE=""

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-key) API_KEY="$2"; shift 2 ;;
    --api-key=*) API_KEY="${1#*=}"; shift ;;
    --save-state) SAVE_STATE="$2"; shift 2 ;;
    --save-state=*) SAVE_STATE="${1#*=}"; shift ;;
    --verify) VERIFY_STATE="$2"; shift 2 ;;
    --verify=*) VERIFY_STATE="${1#*=}"; shift ;;
    *) shift ;;
  esac
done

# Auto-read from .env if no key provided
if [[ -z "$API_KEY" ]]; then
  ENV_FILE="${SCRIPT_DIR}/../compose/.env"
  if [[ -f "$ENV_FILE" ]]; then
    API_KEY=$(grep '^PLATFORM_API_KEY=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- || true)
  fi
fi

# --- Helpers ---

check() {
    local name="$1" url="$2" expected_field="$3" expected_value="$4"
    local response
    response=$(curl -sf "$url" 2>/dev/null) || { echo "FAIL: $name — connection refused"; FAILURES=$((FAILURES+1)); return; }
    local actual
    actual=$(echo "$response" | jq -r ".$expected_field" 2>/dev/null) || { echo "FAIL: $name — invalid JSON"; FAILURES=$((FAILURES+1)); return; }
    if [ "$actual" = "$expected_value" ]; then
        echo "PASS: $name"
    else
        echo "FAIL: $name — expected $expected_field=$expected_value, got $actual"
        FAILURES=$((FAILURES+1))
    fi
}

# Authenticated API call. Writes response body to $API_BODY and HTTP status to $HTTP_CODE.
# Usage: api POST /path '{"json":"body"}'   or   api GET /path
HTTP_CODE="000"
API_BODY=""
API_BODY_FILE=$(mktemp)
API_CODE_FILE=$(mktemp)
# shellcheck disable=SC2317
cleanup_api_files() { rm -f "$API_BODY_FILE" "$API_CODE_FILE"; }
trap cleanup_api_files EXIT

api() {
    local method="$1" path="$2" body="${3:-}"
    local curl_args=(-s -o "$API_BODY_FILE" -w '%{http_code}' -X "$method"
      "${BASE_URL}${path}" -H "Authorization: Bearer ${API_KEY}")
    if [[ -n "$body" ]]; then
        curl_args+=(-H "Content-Type: application/json" -d "$body")
    fi
    HTTP_CODE=$(curl "${curl_args[@]}" 2>/dev/null) || HTTP_CODE="000"
    echo "$HTTP_CODE" > "$API_CODE_FILE"
    API_BODY=$(cat "$API_BODY_FILE")
}

# --- Phase 1: Unauthenticated Checks ---

echo "AGLedger Smoke Test"
echo "==================="
echo "Target: $BASE_URL"
echo ""

echo "-- Phase 1: Health & Readiness --"
echo ""

check "Health check" "$BASE_URL/health" "status" "ok"
check "Readiness check" "$BASE_URL/health/ready" "status" "ready"
check "Conformance" "$BASE_URL/conformance" "conformanceLevel" "2"

# Schema seeding — verify built-in schemas are present
SCHEMA_COUNT=$(curl -sf "$BASE_URL/v1/schemas" 2>/dev/null | jq '.data | length' 2>/dev/null || echo "0")
if [ "$SCHEMA_COUNT" -ge 11 ]; then
    echo "PASS: $SCHEMA_COUNT schemas seeded"
else
    echo "FAIL: Expected >= 11 built-in schemas, got $SCHEMA_COUNT"
    FAILURES=$((FAILURES+1))
fi

VERSION=$(curl -sf "$BASE_URL/health/ready" | jq -r '.version' 2>/dev/null || echo "unknown")
echo ""
echo "Version: $VERSION"

# --- Phase 2: Record Lifecycle (requires API key) ---

echo ""
if [[ -z "$API_KEY" ]]; then
    echo "-- Phase 2: Record Lifecycle (SKIPPED — no API key) --"
    echo ""
    echo "  Provide a platform API key to run lifecycle checks:"
    echo "    --api-key KEY, AGLEDGER_API_KEY env var, or PLATFORM_API_KEY in .env"
elif [[ -n "$VERIFY_STATE" ]]; then
    # --- Verify mode: read-only checks on previously created data --
    echo "-- Phase 2: Verify Saved Data --"
    echo "  State file: $VERIFY_STATE"
    echo ""

    if [[ ! -f "$VERIFY_STATE" ]]; then
        echo "FAIL: State file not found: $VERIFY_STATE"
        FAILURES=$((FAILURES+1))
    else
        V_ENTERPRISE_ID=$(jq -r '.enterpriseId // empty' "$VERIFY_STATE" 2>/dev/null || true)
        V_RECORD_ID=$(jq -r '.recordId // empty' "$VERIFY_STATE" 2>/dev/null || true)
        V_EVENT_COUNT=$(jq -r '.eventCount // "0"' "$VERIFY_STATE" 2>/dev/null || true)

        # Verify record still exists and has expected state
        if [[ -n "$V_RECORD_ID" ]]; then
            api GET "/v1/records/${V_RECORD_ID}"
            if [[ "$HTTP_CODE" == "200" ]]; then
                V_STATUS=$(echo "$API_BODY" | jq -r '.status // empty' 2>/dev/null || true)
                V_ENT=$(echo "$API_BODY" | jq -r '.enterpriseId // empty' 2>/dev/null || true)
                V_SUBS=$(echo "$API_BODY" | jq -r '.submissionCount // 0' 2>/dev/null || true)
                if [[ "$V_ENT" == "$V_ENTERPRISE_ID" ]]; then
                    echo "PASS: Record $V_RECORD_ID exists — status: $V_STATUS, submissions: $V_SUBS"
                else
                    echo "FAIL: Record enterprise mismatch — expected $V_ENTERPRISE_ID, got $V_ENT"
                    FAILURES=$((FAILURES+1))
                fi
            else
                echo "FAIL: Get record $V_RECORD_ID — HTTP $HTTP_CODE"
                FAILURES=$((FAILURES+1))
            fi
        else
            echo "FAIL: No recordId in state file"
            FAILURES=$((FAILURES+1))
        fi

        # Verify audit events still exist
        if [[ -n "$V_RECORD_ID" ]]; then
            api GET "/v1/events?recordId=${V_RECORD_ID}&since=2020-01-01T00:00:00Z"
            if [[ "$HTTP_CODE" == "200" ]]; then
                CURRENT_EVENTS=$(echo "$API_BODY" | jq '.data | length' 2>/dev/null || echo "0")
                if [[ "$CURRENT_EVENTS" -ge "$V_EVENT_COUNT" ]]; then
                    echo "PASS: $CURRENT_EVENTS audit events (was $V_EVENT_COUNT before)"
                else
                    echo "FAIL: Event count dropped — was $V_EVENT_COUNT, now $CURRENT_EVENTS"
                    FAILURES=$((FAILURES+1))
                fi
            else
                echo "FAIL: Get events — HTTP $HTTP_CODE"
                FAILURES=$((FAILURES+1))
            fi
        fi

        # Verify schemas still present
        api GET "/v1/schemas"
        if [[ "$HTTP_CODE" == "200" ]]; then
            V_SCHEMAS=$(echo "$API_BODY" | jq '.data | length' 2>/dev/null || echo "0")
            if [[ "$V_SCHEMAS" -ge 11 ]]; then
                echo "PASS: $V_SCHEMAS schemas intact"
            else
                echo "FAIL: Schema count dropped to $V_SCHEMAS"
                FAILURES=$((FAILURES+1))
            fi
        else
            echo "FAIL: Get schemas — HTTP $HTTP_CODE"
            FAILURES=$((FAILURES+1))
        fi
    fi
else
    # --- Create mode: full lifecycle --
    echo "-- Phase 2: Record Lifecycle --"
    echo ""

    # Step 1: Create enterprise via admin API (no self-service registration)
    api POST "/v1/admin/enterprises" '{"name":"Smoke Test Enterprise"}'
    if [[ "$HTTP_CODE" =~ ^(200|201)$ ]]; then
        ENTERPRISE_ID=$(echo "$API_BODY" | jq -r '.id // .enterpriseId // empty' 2>/dev/null || true)
        if [[ -n "$ENTERPRISE_ID" ]]; then
            echo "PASS: Created enterprise ($ENTERPRISE_ID)"
        else
            echo "FAIL: Create enterprise — no ID in response"
            echo "      Response: $(echo "$API_BODY" | head -c 200)"
            FAILURES=$((FAILURES+1))
        fi
    else
        echo "FAIL: Create enterprise — HTTP $HTTP_CODE"
        echo "      Response: $(echo "$API_BODY" | head -c 200)"
        FAILURES=$((FAILURES+1))
        ENTERPRISE_ID=""
    fi

    if [[ -n "${ENTERPRISE_ID:-}" ]]; then

        # Step 2: Create an agent via admin API (performer for the record)
        api POST "/v1/admin/agents" '{"displayName":"Smoke Test Agent"}'
        if [[ "$HTTP_CODE" =~ ^(200|201)$ ]]; then
            AGENT_ID=$(echo "$API_BODY" | jq -r '.id // empty' 2>/dev/null || true)
            if [[ -n "$AGENT_ID" ]]; then
                echo "PASS: Created agent ($AGENT_ID)"
            else
                echo "FAIL: Create agent — no ID in response"
                FAILURES=$((FAILURES+1))
            fi
        else
            echo "FAIL: Create agent — HTTP $HTTP_CODE"
            echo "      Response: $(echo "$API_BODY" | head -c 200)"
            FAILURES=$((FAILURES+1))
            AGENT_ID=""
        fi

        # Step 2b: Approve agent for the enterprise
        if [[ -n "${AGENT_ID:-}" ]]; then
            api PUT "/v1/enterprises/${ENTERPRISE_ID}/agents/${AGENT_ID}" '{}'
            if [[ "$HTTP_CODE" =~ ^(200|201)$ ]]; then
                echo "PASS: Approved agent for enterprise"
            else
                echo "FAIL: Approve agent — HTTP $HTTP_CODE"
                echo "      Response: $(echo "$API_BODY" | head -c 200)"
                FAILURES=$((FAILURES+1))
            fi
        fi

        # Step 3: Create record with autoActivate (DRAFT → REGISTERED → ACTIVE)
        api POST "/v1/records" "{
            \"enterpriseId\": \"${ENTERPRISE_ID}\",
            \"performerAgentId\": \"${AGENT_ID}\",
            \"type\": \"ACH-PROC-v1\",
            \"contractVersion\": \"1\",
            \"platform\": \"smoke-test\",
            \"autoActivate\": true,
            \"criteria\": {
                \"item_description\": \"Smoke test item\",
                \"quantity\": { \"target\": 100 }
            }
        }"
        if [[ "$HTTP_CODE" =~ ^(200|201)$ ]]; then
            RECORD_ID=$(echo "$API_BODY" | jq -r '.id // empty' 2>/dev/null || true)
            RECORD_STATUS=$(echo "$API_BODY" | jq -r '.status // empty' 2>/dev/null || true)
            if [[ -n "$RECORD_ID" && "$RECORD_STATUS" == "ACTIVE" ]]; then
                echo "PASS: Created record ($RECORD_ID) — status: ACTIVE"
            elif [[ -n "$RECORD_ID" ]]; then
                echo "PASS: Created record ($RECORD_ID) — status: ${RECORD_STATUS} (expected ACTIVE)"
            else
                echo "FAIL: Create record — no ID in response"
                echo "      Response: $(echo "$API_BODY" | head -c 200)"
                FAILURES=$((FAILURES+1))
            fi
        else
            echo "FAIL: Create record — HTTP $HTTP_CODE"
            echo "      Response: $(echo "$API_BODY" | head -c 200)"
            FAILURES=$((FAILURES+1))
            RECORD_ID=""
        fi

        # Step 4: Submit receipt
        if [[ -n "${RECORD_ID:-}" ]]; then
            api POST "/v1/records/${RECORD_ID}/receipts" "{
                \"evidence\": {
                    \"item_description\": \"Smoke test item\",
                    \"quantity\": 100,
                    \"total_cost\": { \"amount\": 500.00, \"currency\": \"USD\" },
                    \"supplier\": { \"id\": \"SMOKE-001\", \"name\": \"Smoke Supplier\", \"rating\": 95 },
                    \"confirmation_ref\": \"SMOKE-TEST-001\"
                }
            }"
            if [[ "$HTTP_CODE" =~ ^(200|201)$ ]]; then
                RECEIPT_ID=$(echo "$API_BODY" | jq -r '.id // empty' 2>/dev/null || true)
                STRUCTURAL=$(echo "$API_BODY" | jq -r '.structuralValidation // empty' 2>/dev/null || true)
                if [[ -n "$RECEIPT_ID" ]]; then
                    echo "PASS: Submitted receipt ($RECEIPT_ID) — validation: ${STRUCTURAL:-unknown}"
                else
                    echo "FAIL: Submit receipt — no ID in response"
                    echo "      Response: $(echo "$API_BODY" | head -c 200)"
                    FAILURES=$((FAILURES+1))
                fi
            else
                echo "FAIL: Submit receipt — HTTP $HTTP_CODE"
                echo "      Response: $(echo "$API_BODY" | head -c 200)"
                FAILURES=$((FAILURES+1))
                RECEIPT_ID=""
            fi
        fi

        # Step 5: Verify record has progressed (GET record)
        if [[ -n "${RECORD_ID:-}" ]]; then
            api GET "/v1/records/${RECORD_ID}"
            if [[ "$HTTP_CODE" == "200" ]]; then
                FINAL_STATUS=$(echo "$API_BODY" | jq -r '.status // empty' 2>/dev/null || true)
                SUBMISSION_COUNT=$(echo "$API_BODY" | jq -r '.submissionCount // 0' 2>/dev/null || true)
                echo "PASS: Record status: ${FINAL_STATUS}, submissions: ${SUBMISSION_COUNT}"
            else
                echo "FAIL: Get record — HTTP $HTTP_CODE"
                FAILURES=$((FAILURES+1))
            fi
        fi

        # Step 6: Verify audit events exist
        EVENT_COUNT=0
        if [[ -n "${RECORD_ID:-}" ]]; then
            # Use a timestamp from 5 minutes ago to catch all events
            SINCE=$(date -u -d '5 minutes ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
                || date -u -v-5M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
                || echo "2020-01-01T00:00:00Z")
            api GET "/v1/events?recordId=${RECORD_ID}&since=${SINCE}"
            if [[ "$HTTP_CODE" == "200" ]]; then
                EVENT_COUNT=$(echo "$API_BODY" | jq '.data | length' 2>/dev/null || echo "0")
                if [[ "$EVENT_COUNT" -ge 2 ]]; then
                    echo "PASS: $EVENT_COUNT audit events recorded"
                else
                    echo "FAIL: Expected >= 2 audit events, got $EVENT_COUNT"
                    FAILURES=$((FAILURES+1))
                fi
            else
                echo "FAIL: Get events — HTTP $HTTP_CODE"
                FAILURES=$((FAILURES+1))
            fi
        fi

        # Save state for verify mode (upgrade/restore tests)
        if [[ -n "$SAVE_STATE" && -n "${RECORD_ID:-}" ]]; then
            jq -n \
                --arg eid "${ENTERPRISE_ID:-}" \
                --arg aid "${AGENT_ID:-}" \
                --arg mid "${RECORD_ID:-}" \
                --arg rid "${RECEIPT_ID:-}" \
                --arg ec "$EVENT_COUNT" \
                '{enterpriseId: $eid, agentId: $aid, recordId: $mid, receiptId: $rid, eventCount: ($ec | tonumber)}' \
                > "$SAVE_STATE"
            echo ""
            echo "State saved to $SAVE_STATE"
        fi
    fi
fi

# --- Summary ---

echo ""
if [ $FAILURES -eq 0 ]; then
    echo "All checks passed."
    exit 0
else
    echo "$FAILURES check(s) failed."
    exit 1
fi
