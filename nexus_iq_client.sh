#!/usr/bin/env bash
# nexus_iq_client.sh - Shared Nexus IQ API client
#
# Source this file from other scripts to get:
#   - Config loading (nexus-iq.cfg -> ~/.nexus-iq.cfg)
#   - Cloud tenant detection (adds /platform prefix for *.sonatype.app)
#   - iq_get <api-path>  - authenticated GET, returns JSON to stdout
#   - Connectivity check via /ping on load
#
# Usage in a script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/nexus_iq_client.sh"

# ----------------------------------------------
# Dependency check
# ----------------------------------------------

_nxiq_check_deps() {
    local missing=0
    for cmd in curl jq; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "ERROR: Required tool not found: ${cmd}" >&2
            echo "       Install it and try again." >&2
            missing=1
        fi
    done
    if [[ "$missing" -eq 1 ]]; then exit 1; fi
}

# ----------------------------------------------
# Config loading
# ----------------------------------------------

_nxiq_load_config() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    local local_cfg="${script_dir}/nexus-iq.cfg"
    local home_cfg="${HOME}/.nexus-iq.cfg"

    if [[ -f "$local_cfg" ]]; then
        # shellcheck source=/dev/null
        source "$local_cfg"
    elif [[ -f "$home_cfg" ]]; then
        # shellcheck source=/dev/null
        source "$home_cfg"
    else
        echo "ERROR: No config file found." >&2
        echo "       Create nexus-iq.cfg next to the script (see nexus-iq.cfg.example)." >&2
        exit 1
    fi

    # Validate required variables
    local missing=0
    for var in NEXUS_IQ_URL NEXUS_IQ_USER NEXUS_IQ_TOKEN; do
        if [[ -z "${!var:-}" ]]; then
            echo "ERROR: ${var} is not set in the config file." >&2
            missing=1
        fi
    done
    if [[ "$missing" -eq 1 ]]; then exit 1; fi

    # Strip trailing slash from URL
    NEXUS_IQ_URL="${NEXUS_IQ_URL%/}"

    # Detect Sonatype Cloud - prepend /platform to all API calls
    _NXIQ_API_BASE="${NEXUS_IQ_URL}"
    if [[ "$NEXUS_IQ_URL" == *".sonatype.app" ]]; then
        _NXIQ_API_BASE="${NEXUS_IQ_URL}/platform"
    fi
}

# ----------------------------------------------
# Core HTTP helper
# ----------------------------------------------

# iq_get <api-path>
#   Makes an authenticated GET request to the Nexus IQ API.
#   Prints the JSON response body to stdout.
#   Exits with an error message on HTTP errors or curl failures.
#
# Example:
#   iq_get "/api/v2/organizations"
iq_get() {
    local path="$1"
    local url="${_NXIQ_API_BASE}${path}"

    local http_code
    local response_body

    # Write body to a temp file so we can read both body and status code
    local tmp_body
    tmp_body="$(mktemp)"

    http_code=$(curl \
        --silent \
        --show-error \
        --write-out "%{http_code}" \
        --output "$tmp_body" \
        --user "${NEXUS_IQ_USER}:${NEXUS_IQ_TOKEN}" \
        --header "Accept: application/json" \
        -- "$url" \
        2>&1)

    local curl_exit=$?
    response_body="$(cat "$tmp_body")"
    rm -f "$tmp_body"

    if [[ "$curl_exit" -ne 0 ]]; then
        echo "ERROR: curl failed for ${url}" >&2
        echo "       ${response_body}" >&2
        exit 1
    fi

    if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
        echo "ERROR: HTTP ${http_code} from ${url}" >&2
        echo "       ${response_body}" >&2
        exit 1
    fi

    echo "$response_body"
}

# ----------------------------------------------
# Connectivity check
# ----------------------------------------------

_nxiq_ping() {
    local ping_url="${NEXUS_IQ_URL}/ping"
    local http_code

    http_code=$(curl \
        --silent \
        --output /dev/null \
        --write-out "%{http_code}" \
        --user "${NEXUS_IQ_USER}:${NEXUS_IQ_TOKEN}" \
        -- "$ping_url" \
        2>/dev/null) || true
    http_code="${http_code:-0}"

    if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
        echo "ERROR: Cannot reach Nexus IQ Server at ${NEXUS_IQ_URL}" >&2
        echo "       /ping returned HTTP ${http_code}. Check URL and credentials." >&2
        exit 1
    fi
}

# ----------------------------------------------
# Initialise on source
# ----------------------------------------------

_nxiq_check_deps
_nxiq_load_config
_nxiq_ping
