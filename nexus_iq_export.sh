#!/usr/bin/env bash
# nexus_iq_export.sh - Nexus IQ Organization & Application Export
#
# Exports all organizations and applications from the live Nexus IQ instance
# in two formats:
#   1. Optical/tree format (.txt) - visual hierarchy
#   2. CSV format (.csv)          - flat rows for KPI analysis
#
# Hierarchy depth mapping (from live API):
#   Level 1  ->  RootOrganization (technical Nexus IQ root container)
#   Level 2  ->  Organization
#   Level 3  ->  Area
#   Level 4  ->  Department
#   Level 5  ->  Team
#   Level 6+ ->  contributes to PathAfterTeam prefix in CSV
#
# Output files are written to the current working directory with a timestamp:
#   export_nexusiq_YYYYMMDD_HHMMSS.txt
#   export_nexusiq_YYYYMMDD_HHMMSS.csv
#
# Prerequisites: curl, jq  (checked on startup via nexus_iq_client.sh)
# Config:        nexus-iq.cfg next to this script (see nexus-iq.cfg.example)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ----------------------------------------------
# Load shared client (config + iq_get + ping)
# ----------------------------------------------
# shellcheck source=nexus_iq_client.sh
source "${SCRIPT_DIR}/nexus_iq_client.sh"

# ----------------------------------------------
# Global data structures (associative arrays)
# ----------------------------------------------
declare -A ORG_NAME        # orgId  -> display name
declare -A ORG_PARENT      # orgId  -> parentOrganizationId  (empty string = root)
declare -A CHILDREN        # orgId  -> space-separated list of child orgIds
declare -A ORG_APPS        # orgId  -> newline-separated "appName|appPublicId" entries
declare -a ROOT_ORGS       # ordered list of root orgIds

# ----------------------------------------------
# Data fetching
# ----------------------------------------------

fetch_organizations() {
    echo "Fetching all organizations from Nexus IQ..."
    local raw
    raw="$(iq_get "/api/v2/organizations")"

    local count
    count="$(echo "$raw" | jq '.organizations | length')"
    echo "  Done. Fetched ${count} organizations."

    # Parse each org and populate lookup arrays
    while IFS='|' read -r org_id org_name parent_id; do
        ORG_NAME["$org_id"]="$org_name"
        ORG_PARENT["$org_id"]="$parent_id"

        if [[ -z "$parent_id" ]]; then
            ROOT_ORGS+=("$org_id")
        else
            # Append to children list (space-separated)
            if [[ -n "${CHILDREN[$parent_id]+_}" ]]; then
                CHILDREN["$parent_id"]+=" $org_id"
            else
                CHILDREN["$parent_id"]="$org_id"
            fi
        fi
    done < <(echo "$raw" | jq -r '
        .organizations[] |
        [
            .id,
            .name,
            (.parentOrganizationId // "")
        ] | join("|")
    ')

    # Sort root orgs alphabetically by name
    _sort_orgs_by_name ROOT_ORGS

    # Sort each children list alphabetically by name
    local pid
    for pid in "${!CHILDREN[@]}"; do
        local -a kids
        read -ra kids <<< "${CHILDREN[$pid]}"
        _sort_orgs_by_name kids
        CHILDREN["$pid"]="${kids[*]}"
    done
}

fetch_applications() {
    echo "Fetching all applications from Nexus IQ..."
    local raw
    raw="$(iq_get "/api/v2/applications")"

    local count
    count="$(echo "$raw" | jq '.applications | length')"
    echo "  Done. Fetched ${count} applications."

    # Map each application to its organization
    while IFS='|' read -r org_id app_name app_public_id; do
        if [[ -n "${ORG_NAME[$org_id]+_}" ]]; then
            local entry="${app_name}|${app_public_id}"
            if [[ -n "${ORG_APPS[$org_id]+_}" ]]; then
                ORG_APPS["$org_id"]+=$'\n'"$entry"
            else
                ORG_APPS["$org_id"]="$entry"
            fi
        fi
    done < <(echo "$raw" | jq -r '
        .applications[] |
        [
            .organizationId,
            .name,
            .publicId
        ] | join("|")
    ')

    # Sort apps within each org alphabetically
    local org_id
    for org_id in "${!ORG_APPS[@]}"; do
        local sorted
        sorted="$(echo "${ORG_APPS[$org_id]}" | sort -t'|' -k1,1 --ignore-case)"
        ORG_APPS["$org_id"]="$sorted"
    done
}

# ----------------------------------------------
# Sorting helper
# ----------------------------------------------

# _sort_orgs_by_name <array_name>
# Sorts the named array of org IDs in-place by their display names.
_sort_orgs_by_name() {
    local -n _arr="$1"
    if [[ ${#_arr[@]} -le 1 ]]; then return; fi

    local -a pairs=()
    local id
    for id in "${_arr[@]}"; do
        pairs+=("${ORG_NAME[$id]}|${id}")
    done

    local -a sorted_pairs
    mapfile -t sorted_pairs < <(printf '%s\n' "${pairs[@]}" | sort -t'|' -k1,1 --ignore-case)

    _arr=()
    local pair
    for pair in "${sorted_pairs[@]}"; do
        _arr+=("${pair##*|}")
    done
}

# ----------------------------------------------
# Statistics
# ----------------------------------------------

declare -i STAT_ORGS=0
declare -i STAT_AREAS=0
declare -i STAT_DEPARTMENTS=0
declare -i STAT_APPS=0

compute_statistics() {
    _walk_for_stats() {
        local org_id="$1"
        local depth="$2"

        case "$depth" in
            2) STAT_ORGS=$(( STAT_ORGS + 1 ))             ;;
            3) STAT_AREAS=$(( STAT_AREAS + 1 ))           ;;
            4) STAT_DEPARTMENTS=$(( STAT_DEPARTMENTS + 1 ));;
        esac

        # Count apps directly in this org
        if [[ -n "${ORG_APPS[$org_id]+_}" ]]; then
            local app_count
            app_count="$(echo "${ORG_APPS[$org_id]}" | grep -c '.' || true)"
            STAT_APPS=$(( STAT_APPS + app_count ))
        fi

        if [[ -n "${CHILDREN[$org_id]+_}" ]]; then
            local child_id
            for child_id in ${CHILDREN[$org_id]}; do
                _walk_for_stats "$child_id" $(( depth + 1 ))
            done
        fi
    }

    local root_id
    for root_id in "${ROOT_ORGS[@]}"; do
        _walk_for_stats "$root_id" 1
    done
}

render_statistics_header() {
    local generated_at="$1"
    local sep
    sep="$(printf '=%.0s' {1..48})"
    echo "$sep"
    echo "Nexus IQ Export - Statistics"
    echo "Generated : ${generated_at}"
    echo "$sep"
    printf "  Organizations : %d\n" "$STAT_ORGS"
    printf "  Areas         : %d\n" "$STAT_AREAS"
    printf "  Departments   : %d\n" "$STAT_DEPARTMENTS"
    printf "  Apps (total)  : %d\n" "$STAT_APPS"
    echo "$sep"
    echo ""
}

# ----------------------------------------------
# Optical (tree) export
# ----------------------------------------------

OPTICAL_LINES=()

render_optical() {
    _render_org() {
        local org_id="$1"
        local prefix="$2"
        local is_last="$3"   # "1" = last sibling
        local is_root="$4"   # "1" = root org

        local name="${ORG_NAME[$org_id]}"
        local child_prefix

        if [[ "$is_root" == "1" ]]; then
            OPTICAL_LINES+=("───${name}")
            child_prefix="    "
        else
            local connector
            [[ "$is_last" == "1" ]] && connector="└──" || connector="├──"
            OPTICAL_LINES+=("${prefix}${connector}(org) ${name}")
            [[ "$is_last" == "1" ]] && child_prefix="${prefix}    " || child_prefix="${prefix}│   "
        fi

        # Collect children and apps
        local -a kids=()
        if [[ -n "${CHILDREN[$org_id]+_}" ]]; then
            read -ra kids <<< "${CHILDREN[$org_id]}"
        fi

        local has_apps=0
        [[ -n "${ORG_APPS[$org_id]+_}" ]] && has_apps=1

        # Render sub-orgs first
        local i
        for (( i=0; i<${#kids[@]}; i++ )); do
            local child_is_last=0
            [[ $i -eq $(( ${#kids[@]} - 1 )) && $has_apps -eq 0 ]] && child_is_last=1
            _render_org "${kids[$i]}" "$child_prefix" "$child_is_last" "0"
        done

        # Render apps section last
        if [[ "$has_apps" == "1" ]]; then
            OPTICAL_LINES+=("${child_prefix}└──Apps:")
            local repo_prefix="${child_prefix}    "
            while IFS='|' read -r app_name app_public_id; do
                OPTICAL_LINES+=("${repo_prefix}${app_name} [${app_public_id}]")
            done <<< "${ORG_APPS[$org_id]}"
        fi
    }

    local i
    for (( i=0; i<${#ROOT_ORGS[@]}; i++ )); do
        _render_org "${ROOT_ORGS[$i]}" "" "1" "1"
        OPTICAL_LINES+=("")   # blank line between root orgs
    done
}

write_optical_file() {
    local filepath="$1"
    printf '%s\n' "${OPTICAL_LINES[@]}" > "$filepath"
    echo "  Written: ${filepath}"
}

# ----------------------------------------------
# CSV export
# ----------------------------------------------

CSV_ROWS=()

collect_csv_rows() {
    _traverse() {
        local org_id="$1"
        local -a ancestors=("${@:2}")

        local current_ancestors=("${ancestors[@]}" "$org_id")
        local depth=${#current_ancestors[@]}

        # Resolve ancestor names by depth
        # Depth 1 = RootOrganization (technical Nexus IQ root container)
        # Depth 2 = Organization, 3 = Area, 4 = Department, 5 = Team, 6+ = PathAfterTeam
        local root_org_name  org_name  area_name  dept_name  team_name  path_after_team

        [[ $depth -ge 1 ]] && root_org_name="${ORG_NAME[${current_ancestors[0]}]}" || root_org_name=""
        [[ $depth -ge 2 ]] && org_name="${ORG_NAME[${current_ancestors[1]}]}"      || org_name=""
        [[ $depth -ge 3 ]] && area_name="${ORG_NAME[${current_ancestors[2]}]}"     || area_name=""
        [[ $depth -ge 4 ]] && dept_name="${ORG_NAME[${current_ancestors[3]}]}"     || dept_name=""
        [[ $depth -ge 5 ]] && team_name="${ORG_NAME[${current_ancestors[4]}]}"     || team_name=""

        # Emit one CSV row per application in this org
        if [[ -n "${ORG_APPS[$org_id]+_}" ]]; then
            while IFS='|' read -r app_name app_public_id; do
                # Build PathAfterTeam from depth 6+ org names + app publicId
                if [[ $depth -gt 5 ]]; then
                    local extra_path="/"
                    local j
                    for (( j=5; j<depth; j++ )); do
                        extra_path+="${ORG_NAME[${current_ancestors[$j]}]}/"
                    done
                    path_after_team="${extra_path}${app_public_id}"
                else
                    path_after_team="/${app_public_id}"
                fi

                # Escape double-quotes in fields (CSV spec: double them)
                local _root _org _area _dept _team _path _name _pubid
                _root="${root_org_name//\"/\"\"}"
                _org="${org_name//\"/\"\"}"
                _area="${area_name//\"/\"\"}"
                _dept="${dept_name//\"/\"\"}"
                _team="${team_name//\"/\"\"}"
                _path="${path_after_team//\"/\"\"}"
                _name="${app_name//\"/\"\"}"
                _pubid="${app_public_id//\"/\"\"}"

                CSV_ROWS+=("\"${_root}\",\"${_org}\",\"${_area}\",\"${_dept}\",\"${_team}\",\"${_path}\",\"${_name}\",\"${_pubid}\"")
            done <<< "${ORG_APPS[$org_id]}"
        fi

        # Recurse into children
        if [[ -n "${CHILDREN[$org_id]+_}" ]]; then
            local child_id
            for child_id in ${CHILDREN[$org_id]}; do
                _traverse "$child_id" "${current_ancestors[@]}"
            done
        fi
    }

    local root_id
    for root_id in "${ROOT_ORGS[@]}"; do
        _traverse "$root_id"
    done
}

write_csv_file() {
    local filepath="$1"
    {
        echo "RootOrganization,Organization,Area,Department,Team,PathAfterTeam,ApplicationName,ApplicationPublicId"
        printf '%s\n' "${CSV_ROWS[@]}"
    } > "$filepath"
    echo "  Written: ${filepath}"
}

# ----------------------------------------------
# Entry point
# ----------------------------------------------

main() {
    echo ""
    echo "Connected to Nexus IQ: ${NEXUS_IQ_URL}"
    echo "This script will export ALL organizations and applications from Nexus IQ."
    echo "Press Enter to continue..."
    read -r

    # -- Fetch ----------------------------------
    fetch_organizations
    fetch_applications

    # -- Build output filenames -----------------
    local ts
    ts="$(date '+%Y%m%d_%H%M%S')"
    local optical_path="export_nexusiq_${ts}.txt"
    local csv_path="export_nexusiq_${ts}.csv"

    # -- Statistics -----------------------------
    compute_statistics
    local generated_at
    generated_at="$(date '+%Y-%m-%d %H:%M:%S')"

    # -- Optical export -------------------------
    echo ""
    echo "Generating optical (tree) export..."
    render_optical
    local stats_header
    stats_header="$(render_statistics_header "$generated_at")"
    {
        echo "$stats_header"
        printf '%s\n' "${OPTICAL_LINES[@]}"
    } > "$optical_path"
    echo "  Written: ${optical_path}"

    # -- CSV export -----------------------------
    echo "Generating CSV export..."
    collect_csv_rows
    write_csv_file "$csv_path"

    # -- Summary --------------------------------
    echo ""
    echo "Export complete."
    printf "  Organizations : %d\n" "$STAT_ORGS"
    printf "  Areas         : %d\n" "$STAT_AREAS"
    printf "  Departments   : %d\n" "$STAT_DEPARTMENTS"
    printf "  Applications  : %d\n" "$STAT_APPS"
    printf "  CSV rows      : %d\n" "${#CSV_ROWS[@]}"
}

main
