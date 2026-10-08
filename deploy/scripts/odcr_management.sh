#!/bin/bash
# ODCR Management Script for SAP VMs
#
# Usage: odcr_management.sh <create|plan|info> <sid_resource_group> <subscription_id> [expected_location]
# Location is discovered from all VMs in the resource group. The optional legacy fourth argument
# is checked against that location, never used to override it.
#
#   create  - reserve capacity and associate VMs
#   plan    - dry run; show what create would do without changing anything
#   info    - show CRGs, reservations and VM associations
#
# The SID resource group must follow the SDAF naming convention <ENV>-<REGION>-<VNET>-<SID>
# (e.g. PRD-SCUS-TFO01-PGY). ENV selects the prod / non-prod tier and REGION the region code.
#
# Role-based placement (role is read from the VM name, e.g. PRD-SCUS-TFO01-PGY_pgyapp01l0a25):
#   app  -> central App server CRG for the tier/region (shared by all SIDs, separate resource group)
#           The central resource group is never created; if it is missing (or the tier can't be
#           resolved) the script stops before making any change. The CRG in it is created if missing.
#   scs  -> SID CRG in the SID resource group
#   db   -> SID CRG in the SID resource group
#   web  -> skipped, reported as not reserved
#
# Naming (e.g. SID resource group PRD-SCUS-TFO01-PGY):
#   Central resource group  <ENV>-<REGION>-CR                PRD-SCUS-CR
#   Central CRG             <REGION>-CR                      SCUS-CR
#   App reservation         <REGION>-AZ<zz>-Apps             SCUS-AZ01-Apps
#   SID CRG                 <REGION>-<SID>-CR                SCUS-PGY-CR
#   SCS / DB reservation    <REGION>-<SID>-AZ<zz>-ACS|DB     SCUS-PGY-AZ01-ACS, SCUS-PGY-AZ03-DB
# Azure allows one reservation per VM size per zone in a CRG, so existing reservations are matched by
# size and zone (not name). If a new reservation's name is already used by another size, the size is
# appended (e.g. SCUS-AZ01-Apps-D4ds_v5).
#
# VMs already associated with a CRG are skipped. Regional (non-zonal) VMs are skipped because
# associating them requires a deallocation.
#
# Optional environment overrides:
#   ODCR_TIER          prod | nonprod | test   (default: derived from ENV code, PRD=prod, NRD=nonprod, LAC=test)
#   ODCR_CENTRAL_RG    central App server CRG resource group name
#   ODCR_CENTRAL_CRG   central App server CRG name
#   ODCR_CRG_ZONES     zones used when a CRG is created (default: "1 2 3")
#   ODCR_SKU_CACHE_DIR directory for the subscription/region SKU cache
#                      (default: ${XDG_CACHE_HOME:-$HOME/.cache}/sdaf-odcr)
#   ODCR_SKU_CACHE_REFRESH
#                      true | false (default: false); force an Azure SKU refresh for plan/create
#                      Cache lifetime is 24 hours. Plan may write this local cache but never changes Azure.
#                      Info does not use or refresh it. VM and reservation data are always read live.
#   ODCR_SHARE_SUBSCRIPTIONS
#                      subscription IDs (space or comma separated) the central App server CRG is shared with
#                      (CRG sharing, preview). The current subscription is ignored, so the same list (prod + non-prod)
#                      can be passed for every run. Add-only: subscriptions are never removed from the sharing list.

set -uo pipefail

OPERATION="${1:-}"
RESOURCE_GROUP="${2:-}"
SUBSCRIPTION_ID="${3:-}"
EXPECTED_LOCATION="${4:-}"

if (( $# < 3 || $# > 4 )) || [[ ! "$OPERATION" =~ ^(create|plan|info)$ ]] || [[ -z "$RESOURCE_GROUP" || -z "$SUBSCRIPTION_ID" ]]; then
    echo "Usage: $0 <create|plan|info> <sid_resource_group> <subscription_id> [expected_location]" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Tier / central CRG configuration
# ---------------------------------------------------------------------------
# TODO: TEST ONLY - LAC is the single Sweden Central lab environment. Remove the "test" entries before production use.
declare -A ENV_TO_TIER=( [PRD]="prod" [NRD]="nonprod" [LAC]="test" )
declare -A TIER_TO_CODE=( [prod]="PRD" [nonprod]="NRD" [test]="LAC" )

# Central App server resource group: one per tier per region, e.g. PRD-SCUS-CR / NRD-SCUS-CR.
central_rg_name()  { echo "${1}-${2}-CR"; }         # args: <PRD|NRD> <REGION>
central_crg_name() { echo "${2}-CR"; }              # args: <PRD|NRD> <REGION>

IFS='-' read -r ENV_CODE REGION_CODE _ <<< "$RESOURCE_GROUP"
ENV_CODE="${ENV_CODE^^}"
REGION_CODE="${REGION_CODE^^}"
SID="${RESOURCE_GROUP##*-}"
SID="${SID^^}"

TIER="${ODCR_TIER:-${ENV_TO_TIER[$ENV_CODE]:-}}"
TIER="${TIER,,}"
CENTRAL_RG=""
CENTRAL_CRG=""
if [[ -n "$TIER" && -n "${TIER_TO_CODE[$TIER]:-}" ]]; then
    CENTRAL_RG="${ODCR_CENTRAL_RG:-$(central_rg_name "${TIER_TO_CODE[$TIER]}" "$REGION_CODE")}"
    CENTRAL_CRG="${ODCR_CENTRAL_CRG:-$(central_crg_name "${TIER_TO_CODE[$TIER]}" "$REGION_CODE")}"
fi

SID_CRG="${REGION_CODE}-${SID}-CR"
CRG_ZONES="${ODCR_CRG_ZONES:-1 2 3}"

SHARE_SUBS=()
share_input="${ODCR_SHARE_SUBSCRIPTIONS:-}"
for s in ${share_input//,/ }; do
    s="${s,,}"
    s="${s#/subscriptions/}"
    s="${s#subscriptions/}"
    [[ "$s" == "${SUBSCRIPTION_ID,,}" ]] && continue
    if [[ ! "$s" =~ ^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$ ]]; then
        echo "ERROR: invalid subscription ID in odcr_share_subscriptions: '$s'" >&2
        exit 1
    fi
    SHARE_SUBS+=("$s")
done
DRY_RUN=false
[[ "$OPERATION" == "plan" ]] && DRY_RUN=true
SKU_CACHE_REFRESH="${ODCR_SKU_CACHE_REFRESH:-false}"
SKU_CACHE_REFRESH="${SKU_CACHE_REFRESH,,}"
if [[ "$SKU_CACHE_REFRESH" != "true" && "$SKU_CACHE_REFRESH" != "false" ]]; then
    echo "ERROR: ODCR_SKU_CACHE_REFRESH must be true or false" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
run() {
    if $DRY_RUN; then
        echo "    [plan] az $*"
        return 0
    fi
    az "$@" --subscription "$SUBSCRIPTION_ID" -o none
}

crg_id() {
    echo "/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${1}/providers/Microsoft.Compute/capacityReservationGroups/${2}"
}

# SAP SIDs are always 3 characters; the role follows the SID in the computer name part of the VM name.
vm_role() {
    local short="${1##*_}"
    short="${short,,}"
    short="${short:3}"
    case "$short" in
        app*) echo "app" ;;
        scs*) echo "scs" ;;
        web*) echo "web" ;;
        d*)   echo "db" ;;
        *)    echo "unknown" ;;
    esac
}

SKU_CACHE_JSON=""
SKU_CACHE_FILE=""
SKU_CACHE_MAX_AGE=86400

valid_sku_cache() {
    jq -e --arg sub "${SUBSCRIPTION_ID,,}" --arg loc "$LOCATION" '
        .schema_version == 1 and .subscription == $sub and .location == $loc and
        (.fetched_at | type == "number" and . == floor and . >= 0 and . <= 253402300799) and
        (.skus | type == "object" and length > 0 and
            all(to_entries[]; (.key | test("^[a-z0-9_-]+$")) and (.value | type == "boolean")))
        ' <<< "$1" >/dev/null
}

# A same-directory rename exposes only complete snapshots to other runs.
write_sku_cache() (
    local directory="${SKU_CACHE_FILE%/*}" temp
    umask 077
    if ! mkdir -p -- "$directory"; then
        echo "ERROR: unable to create SKU cache directory $directory" >&2
        exit 1
    fi
    if ! temp=$(mktemp "${SKU_CACHE_FILE}.tmp.XXXXXX"); then
        echo "ERROR: unable to create temporary SKU cache file" >&2
        exit 1
    fi
    trap 'rm -f -- "$temp"' EXIT
    if ! printf '%s\n' "$SKU_CACHE_JSON" > "$temp" || ! mv -f -- "$temp" "$SKU_CACHE_FILE"; then
        echo "ERROR: unable to save SKU cache $SKU_CACHE_FILE" >&2
        exit 1
    fi
)

refresh_sku_cache() {
    local response skus fetched_at
    echo "SKU support source: Azure (refreshing $SKU_CACHE_FILE)"
    if ! response=$(az vm list-skus --location "$LOCATION" --resource-type virtualMachines \
            --subscription "$SUBSCRIPTION_ID" --query '[].{name:name, capabilities:capabilities}' -o json); then
        echo "ERROR: unable to refresh SKU support in $LOCATION; cached data will not be used" >&2
        return 1
    fi
    # Retain false entries too, so known unsupported sizes are not mistaken for unseen sizes.
    if ! skus=$(jq -ce '
            if type == "array" and length > 0 and all(.[];
                (.name | type == "string" and test("^[a-zA-Z0-9_-]+$")) and
                (.capabilities | type == "array" and all(.[];
                    (.name | type == "string") and (.value | type == "string"))) and
                ([.capabilities[] | select(.name == "CapacityReservationSupported")] |
                    length <= 1 and all(.[]; (.value | ascii_downcase) as $v |
                        $v == "true" or $v == "false")))
            then
                map({key: (.name | ascii_downcase), value: any(.capabilities[];
                    .name == "CapacityReservationSupported" and (.value | ascii_downcase) == "true")}) |
                if (map(.key) | unique | length) != length then error("duplicate SKU names")
                else from_entries end
            else error("expected a non-empty SKU capability list") end
            ' <<< "$response"); then
        echo "ERROR: invalid Azure SKU response; cache was not replaced" >&2
        return 1
    fi
    if ! fetched_at=$(date +%s) || ! SKU_CACHE_JSON=$(jq -cn \
            --arg sub "${SUBSCRIPTION_ID,,}" --arg loc "$LOCATION" \
            --argjson fetched "$fetched_at" --argjson skus "$skus" \
            '{schema_version: 1, subscription: $sub, location: $loc, fetched_at: $fetched, skus: $skus}'); then
        echo "ERROR: unable to build SKU cache" >&2
        return 1
    fi
    if ! valid_sku_cache "$SKU_CACHE_JSON"; then
        echo "ERROR: invalid generated SKU cache; cache was not replaced" >&2
        return 1
    fi
    write_sku_cache || return 1
    echo "SKU cache saved: $SKU_CACHE_FILE (age: 0s; expires after ${SKU_CACHE_MAX_AGE}s)"
}

# Validate all candidate sizes before any Azure mutation, refreshing at most once per run.
prepare_sku_cache() {
    local directory="${ODCR_SKU_CACHE_DIR:-}" now fetched_at age size reason="cache missing"
    if [[ -z "$directory" ]]; then
        if [[ -z "${XDG_CACHE_HOME:-}" && -z "${HOME:-}" ]]; then
            echo "ERROR: set HOME, XDG_CACHE_HOME or ODCR_SKU_CACHE_DIR for the SKU cache" >&2
            return 1
        fi
        directory="${XDG_CACHE_HOME:-${HOME:-}/.cache}/sdaf-odcr"
    fi
    if [[ ! "$SUBSCRIPTION_ID" =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]]; then
        echo "ERROR: a valid subscription ID is required for the SKU cache" >&2
        return 1
    fi
    SKU_CACHE_FILE="${directory%/}/${SUBSCRIPTION_ID,,}-${LOCATION}.json"
    if [[ "$SKU_CACHE_REFRESH" == "true" ]]; then
        reason="manual refresh requested"
    elif [[ -e "$SKU_CACHE_FILE" ]]; then
        if ! SKU_CACHE_JSON=$(cat -- "$SKU_CACHE_FILE"); then
            echo "ERROR: unable to read SKU cache $SKU_CACHE_FILE" >&2
            return 1
        fi
        if valid_sku_cache "$SKU_CACHE_JSON"; then
            if ! now=$(date +%s) || [[ ! "$now" =~ ^[0-9]+$ ]]; then
                echo "ERROR: unable to determine SKU cache age" >&2
                return 1
            fi
            fetched_at=$(jq -r '.fetched_at' <<< "$SKU_CACHE_JSON")
            age=$(( now - fetched_at ))
            if (( age >= 0 && age < SKU_CACHE_MAX_AGE )); then
                reason=""
                for size in "$@"; do
                    if ! jq -e --arg s "${size,,}" '.skus | has($s)' <<< "$SKU_CACHE_JSON" >/dev/null; then
                        reason="previously unseen SKU $size"
                        break
                    fi
                done
                if [[ -z "$reason" ]]; then
                    echo "SKU support source: local cache $SKU_CACHE_FILE (age: ${age}s; expires after ${SKU_CACHE_MAX_AGE}s)"
                    return 0
                fi
            else
                reason="cache expired or timestamp is in the future (age: ${age}s)"
            fi
        else
            reason="cache invalid or scope/schema mismatch"
        fi
    fi
    echo "SKU cache refresh required: $reason"
    refresh_sku_cache
}

sku_supports_odcr() {
    jq -e --arg s "${1,,}" '.skus[$s] == true' <<< "$SKU_CACHE_JSON" >/dev/null
}

declare -A CRG_READY=()
declare -A CRG_ZONE_LIST=()
# Read and validate both target CRGs before any mutation. A successful list distinguishes
# an absent CRG from a failed lookup (which must never be treated as permission to create).
load_crg() {
    local rg="$1" crg="$2" key="$1/$2" groups group location zones
    if ! groups=$(az capacity reservation group list --resource-group "$rg" \
            --subscription "$SUBSCRIPTION_ID" -o json); then
        echo "ERROR: unable to list capacity reservation groups in $rg" >&2
        return 1
    fi
    if ! group=$(jq -ce --arg n "${crg,,}" '
            if type != "array" then error("expected a CRG array")
            else [.[] | select((.name | ascii_downcase) == $n)] |
                if length > 1 then error("duplicate CRG") else .[0] // {} end
            end' <<< "$groups"); then
        echo "ERROR: invalid capacity reservation group data in $rg" >&2
        return 1
    fi
    if [[ "$group" == "{}" ]]; then
        CRG_READY[$key]="missing"
        return 0
    fi
    if ! location=$(jq -er '.location | strings | select(test("^[a-zA-Z0-9]+$")) | ascii_downcase' <<< "$group"); then
        echo "ERROR: missing or invalid location for CRG $key" >&2
        return 1
    fi
    if [[ "$location" != "$LOCATION" ]]; then
        echo "ERROR: CRG $key location '$location' does not match VM location '$LOCATION'" >&2
        return 1
    fi
    if ! zones=$(jq -er '(.zones // []) |
            if type == "array" and all(.[]; type == "string") then join(" ")
            else error("invalid CRG zones") end' <<< "$group"); then
        echo "ERROR: invalid zones for CRG $key" >&2
        return 1
    fi
    CRG_ZONE_LIST[$key]="$zones"
    CRG_READY[$key]="yes"
}

# ensure_crg <rg> <crg> - verify the CRG exists, create it when missing
ensure_crg() {
    local rg="$1" crg="$2" key="$1/$2"
    case "${CRG_READY[$key]:-}" in
        yes) return 0 ;;
        no)  return 1 ;;
        missing) ;;
        *) echo "ERROR: CRG $key was not validated before creation" >&2; return 1 ;;
    esac

    echo "  CRG $key not found - creating (zones: $CRG_ZONES)"
    # shellcheck disable=SC2086
    if run capacity reservation group create --resource-group "$rg" --capacity-reservation-group "$crg" \
            --location "$LOCATION" --zones $CRG_ZONES; then
        CRG_ZONE_LIST[$key]="$CRG_ZONES"
        CRG_READY[$key]="yes"
        return 0
    fi
    echo "  ERROR: failed to create CRG $key"
    CRG_READY[$key]="no"
    return 1
}

crg_shared_subscriptions() {
    az capacity reservation group show --resource-group "$1" --capacity-reservation-group "$2" \
        --subscription "$SUBSCRIPTION_ID" --query "sharingProfile.subscriptionIds[].id" -o tsv 2>/dev/null \
        | tr '[:upper:]' '[:lower:]'
}

SHARING_RESULT="not requested"
# ensure_sharing <rg> <crg> - add-only: make sure every SHARE_SUBS entry is in the CRG sharing profile
ensure_sharing() {
    local rg="$1" crg="$2" current s missing=() all=()
    (( ${#SHARE_SUBS[@]} == 0 )) && return 0

    current=$(crg_shared_subscriptions "$rg" "$crg")
    for s in "${SHARE_SUBS[@]}"; do
        grep -q "/subscriptions/${s}$" <<< "$current" || missing+=("$s")
    done
    if (( ${#missing[@]} == 0 )); then
        echo "  Sharing: $rg/$crg already shared with ${SHARE_SUBS[*]}"
        SHARING_RESULT="already shared with ${SHARE_SUBS[*]}"
        return 0
    fi

    # --sharing-profile replaces the whole list, so pass the existing entries plus the missing ones
    while IFS= read -r s; do [[ -n "$s" ]] && all+=("$s"); done <<< "$current"
    for s in "${missing[@]}"; do all+=("/subscriptions/$s"); done

    echo "  Sharing: adding ${missing[*]} to $rg/$crg"
    if run capacity reservation group update --resource-group "$rg" --capacity-reservation-group "$crg" \
            --sharing-profile "${all[@]}"; then
        SHARING_RESULT="added ${missing[*]}"
        return 0
    fi
    echo "  ERROR: failed to update sharing profile of $rg/$crg"
    SHARING_RESULT="FAILED to add ${missing[*]}"
    FAILED+=("central CRG $rg/$crg: could not share with ${missing[*]}")
    return 1
}

crg_has_zone() {
    local zone
    for zone in ${CRG_ZONE_LIST[$1]:-}; do
        [[ "$zone" == "$2" ]] && return 0
    done
    return 1
}

SKIPPED_ASSOCIATED=()
SKIPPED_WEB=()
SKIPPED_OTHER=()
UNSUPPORTED=()
ASSOCIATED=()
FAILED=()

# reserve_and_associate <rg> <crg> <sku> <zone> <reservation_name> <vm>...
# Uses spare capacity of an existing reservation for the SKU/zone; otherwise grows or creates it.
reserve_and_associate() {
    local rg="$1" crg="$2" sku="$3" zone="$4" base_name="$5"
    shift 5
    local vms=("$@") need=$# reservations res name capacity assoc spare new_capacity vm

    echo ""
    echo "  [$rg/$crg] $sku zone $zone - $need VM(s): ${vms[*]}"

    reservations=$(az capacity reservation list --resource-group "$rg" --capacity-reservation-group "$crg" \
        --subscription "$SUBSCRIPTION_ID" -o json 2>/dev/null || echo "[]")
    res=$(echo "${reservations:-[]}" | jq -c --arg s "$sku" --arg z "$zone" \
        '[.[] | select((.sku.name | ascii_downcase) == ($s | ascii_downcase) and ((.zones // []) | index($z)))] | first // empty')

    if [[ -n "$res" ]]; then
        name=$(echo "$res" | jq -r '.name')
        capacity=$(echo "$res" | jq -r '.sku.capacity // 0')
        # 'list' doesn't return virtualMachinesAssociated; only 'show' does.
        if ! assoc=$(az capacity reservation show --resource-group "$rg" --capacity-reservation-group "$crg" \
                --capacity-reservation-name "$name" --subscription "$SUBSCRIPTION_ID" -o json 2>/dev/null \
                | jq -e '(.virtualMachinesAssociated // []) | length'); then
            echo "    WARNING: could not read associations of $name - treating it as fully used"
            assoc="$capacity"
        fi
        spare=$(( capacity - assoc ))
        (( spare < 0 )) && spare=0
        echo "    Reservation $name: capacity $capacity, associated $assoc, available $spare"

        if (( spare < need )); then
            # Base on associated VMs, not capacity, so an over-allocated reservation (associated > capacity) is fully covered
            new_capacity=$(( assoc + need ))
            echo "    Not enough available capacity - increasing $name to $new_capacity"
            if ! run capacity reservation update --resource-group "$rg" --capacity-reservation-group "$crg" \
                    --capacity-reservation-name "$name" --capacity "$new_capacity"; then
                echo "    ERROR: failed to update reservation $name"
                for vm in "${vms[@]}"; do FAILED+=("$vm: could not increase reservation $name"); done
                return
            fi
        else
            echo "    Available capacity found - associating"
        fi
    else
        name="$base_name"
        if echo "${reservations:-[]}" | jq -e --arg n "$name" 'any(.[]; (.name | ascii_downcase) == ($n | ascii_downcase))' >/dev/null; then
            name="${base_name}-${sku#Standard_}"
        fi
        echo "    No reservation for $sku in zone $zone - creating $name with capacity $need"
        if ! run capacity reservation create --resource-group "$rg" --capacity-reservation-group "$crg" \
                --capacity-reservation-name "$name" --sku "$sku" --capacity "$need" --zone "$zone" \
                --location "$LOCATION"; then
            echo "    ERROR: failed to create reservation $name"
            for vm in "${vms[@]}"; do FAILED+=("$vm: could not create reservation $name"); done
            return
        fi
    fi

    for vm in "${vms[@]}"; do
        echo "    Associating $vm -> $crg"
        if run vm update --resource-group "$RESOURCE_GROUP" --name "$vm" \
                --capacity-reservation-group "$(crg_id "$rg" "$crg")"; then
            ASSOCIATED+=("$vm -> $rg/$crg ($sku, zone $zone)")
        else
            FAILED+=("$vm: association with $rg/$crg failed")
        fi
    done
}

print_list() {
    local title="$1"
    shift
    echo "$title: $#"
    local item
    for item in "$@"; do echo "  - $item"; done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
VM_JSON=$(az vm list --resource-group "$RESOURCE_GROUP" --subscription "$SUBSCRIPTION_ID" \
    --query '[].{id:id, name:name, location:location, size:hardwareProfile.vmSize, zone:zones[0], crg:capacityReservation.capacityReservationGroup.id}' \
    -o json) || { echo "ERROR: unable to list VMs in $RESOURCE_GROUP" >&2; exit 1; }

if ! jq -e 'type == "array"' <<< "$VM_JSON" >/dev/null; then
    echo "ERROR: invalid VM list returned for $RESOURCE_GROUP" >&2
    exit 1
fi
if [[ "$(jq 'length' <<< "$VM_JSON")" == "0" ]]; then
    echo "ERROR: no VMs found in $RESOURCE_GROUP; cannot determine VM location" >&2
    exit 1
fi
if ! jq -e 'all(.[]; (.id | type == "string" and length > 0) and
        (.name | type == "string" and length > 0) and
        (.size | type == "string" and length > 0) and
        (.location | type == "string" and test("^[a-zA-Z0-9]+$")))' <<< "$VM_JSON" >/dev/null; then
    echo "ERROR: missing or invalid VM location, ID, name or size in $RESOURCE_GROUP" >&2
    exit 1
fi
LOCATIONS=$(jq -c '[.[].location | ascii_downcase] | unique' <<< "$VM_JSON")
if [[ "$(jq 'length' <<< "$LOCATIONS")" != "1" ]]; then
    echo "ERROR: multiple VM locations in $RESOURCE_GROUP: $LOCATIONS; target one region per resource group" >&2
    exit 1
fi
LOCATION=$(jq -r '.[0]' <<< "$LOCATIONS")
if [[ -n "$EXPECTED_LOCATION" && "${EXPECTED_LOCATION,,}" != "$LOCATION" ]]; then
    echo "ERROR: supplied location '$EXPECTED_LOCATION' does not match VM location '$LOCATION'" >&2
    exit 1
fi

echo "===== ODCR Management Script ====="
echo "Operation:          $OPERATION"
echo "SID Resource Group: $RESOURCE_GROUP"
echo "Subscription:       $SUBSCRIPTION_ID"
echo "Location:           $LOCATION (from Azure VMs)"
echo "Environment/Region: ${ENV_CODE} / ${REGION_CODE}"
echo "Tier:               ${TIER:-<unresolved>}"
echo "SID CRG (SCS/DB):   ${RESOURCE_GROUP}/${SID_CRG}"
echo "Central App CRG:    ${CENTRAL_RG:-<unresolved>}/${CENTRAL_CRG:-<unresolved>}"
echo "Share central with: ${SHARE_SUBS[*]:-<none>}"
echo "===================================="

APP_PRESENT=false
while IFS= read -r vm_name; do
    [[ "$(vm_role "$vm_name")" == "app" ]] && APP_PRESENT=true
done < <(echo "$VM_JSON" | jq -r '.[].name')

load_crg "$RESOURCE_GROUP" "$SID_CRG" || exit 1
if $APP_PRESENT || [[ "$OPERATION" == "info" ]]; then
    if [[ -z "$CENTRAL_RG" || -z "$CENTRAL_CRG" ]]; then
        if [[ "$OPERATION" != "info" ]]; then
            echo "ERROR: environment code '$ENV_CODE' does not map to a tier. Set odcr_tier (ODCR_TIER) to prod or nonprod." >&2
            exit 1
        fi
    else
        if ! central_exists=$(az group exists --name "$CENTRAL_RG" --subscription "$SUBSCRIPTION_ID" -o tsv); then
            echo "ERROR: unable to check central resource group $CENTRAL_RG" >&2
            exit 1
        fi
        case "$central_exists" in
            true) load_crg "$CENTRAL_RG" "$CENTRAL_CRG" || exit 1 ;;
            false)
                CRG_READY["$CENTRAL_RG/$CENTRAL_CRG"]="missing"
                if [[ "$OPERATION" != "info" ]]; then
                    echo "ERROR: central App server resource group '$CENTRAL_RG' does not exist in subscription $SUBSCRIPTION_ID. It must be provisioned before running ODCR." >&2
                    exit 1
                fi
                ;;
            *) echo "ERROR: invalid resource group existence response for $CENTRAL_RG" >&2; exit 1 ;;
        esac
    fi
fi

if [[ "$OPERATION" == "info" ]]; then
    for target in "$RESOURCE_GROUP/$SID_CRG" "${CENTRAL_RG}/${CENTRAL_CRG}"; do
        rg="${target%%/*}"
        crg="${target#*/}"
        [[ -z "$rg" || -z "$crg" ]] && continue
        echo ""
        echo "Capacity Reservation Group: $target"
        echo "========================================"
        if [[ "${CRG_READY[$target]:-}" == "yes" ]]; then
            printf "%-32s %-20s %-5s %-9s %-11s %s\n" "Name" "Sku" "Zone" "Capacity" "Associated" "Allocated"
            while IFS= read -r res_name; do
                [[ -z "$res_name" ]] && continue
                az capacity reservation show --resource-group "$rg" --capacity-reservation-group "$crg" \
                    --capacity-reservation-name "$res_name" --instance-view --subscription "$SUBSCRIPTION_ID" -o json 2>/dev/null \
                    | jq -r '[.name, .sku.name, (.zones // ["-"])[0], (.sku.capacity | tostring),
                              ((.virtualMachinesAssociated // []) | length | tostring),
                              ((.instanceView.utilizationInfo.virtualMachinesAllocated // []) | length | tostring)] | @tsv' \
                    | while IFS=$'\t' read -r n s z c a l; do
                          printf "%-32s %-20s %-5s %-9s %-11s %s\n" "$n" "$s" "$z" "$c" "$a" "$l"
                      done
            done < <(az capacity reservation list --resource-group "$rg" --capacity-reservation-group "$crg" \
                --subscription "$SUBSCRIPTION_ID" -o json 2>/dev/null | jq -r '.[].name')
            if [[ "$crg" == "$CENTRAL_CRG" ]]; then
                shared=$(crg_shared_subscriptions "$rg" "$crg")
                echo "Shared with: $(echo ${shared:-<none>})"
            fi
        else
            echo "Not found"
        fi
    done

    echo ""
    echo "VM Associations ($RESOURCE_GROUP):"
    echo "================"
    printf "%-45s %-6s %-22s %-5s %s\n" "Name" "Role" "Size" "Zone" "CapacityReservationGroup"
    while IFS= read -r vm; do
        vm_name=$(echo "$vm" | jq -r '.name')
        printf "%-45s %-6s %-22s %-5s %s\n" "$vm_name" "$(vm_role "$vm_name")" \
            "$(echo "$vm" | jq -r '.size')" "$(echo "$vm" | jq -r '.zone // "-"')" \
            "$(echo "$vm" | jq -r '.crg // "-" | split("/") | last')"
    done < <(echo "$VM_JSON" | jq -c '.[]')
    exit 0
fi

echo ""
echo "Found $(echo "$VM_JSON" | jq 'length') VM(s) in $RESOURCE_GROUP"
$DRY_RUN && echo "PLAN MODE - no Azure changes will be made (local SKU cache may be refreshed)"

echo ""
echo "Checking VM sizes for capacity reservation support in $LOCATION..."
# Classify VMs; entries are "<target>|<sku>|<zone>|<vm>|<role>".
CANDIDATES=()
CANDIDATE_SKUS=()
while IFS= read -r vm; do
    vm_name=$(echo "$vm" | jq -r '.name')
    size=$(echo "$vm" | jq -r '.size')
    zone=$(echo "$vm" | jq -r '.zone // empty')
    crg=$(echo "$vm" | jq -r '.crg // empty')
    role=$(vm_role "$vm_name")

    if [[ -n "$crg" ]]; then
        SKIPPED_ASSOCIATED+=("$vm_name ($role) -> ${crg##*/}")
        continue
    fi
    case "$role" in
        web)     SKIPPED_WEB+=("$vm_name ($size)"); continue ;;
        unknown) SKIPPED_OTHER+=("$vm_name: role not recognised from VM name"); continue ;;
    esac
    if [[ -z "$zone" ]]; then
        SKIPPED_OTHER+=("$vm_name ($role): regional VM - association requires deallocation, not automated")
        continue
    fi
    CANDIDATE_SKUS+=("$size")
    if [[ "$role" == "app" ]]; then
        CANDIDATES+=("central|$size|$zone|$vm_name|$role")
    else
        CANDIDATES+=("sid|$size|$zone|$vm_name|$role")
    fi
done < <(echo "$VM_JSON" | jq -c '.[]')

if (( ${#CANDIDATES[@]} > 0 )) || [[ "$SKU_CACHE_REFRESH" == "true" ]]; then
    prepare_sku_cache ${CANDIDATE_SKUS[@]+"${CANDIDATE_SKUS[@]}"} || exit 1
else
    echo "SKU support lookup not needed: no eligible unassociated VMs."
fi
PENDING=()
for entry in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do
    IFS='|' read -r target size zone vm_name role <<< "$entry"
    if sku_supports_odcr "$size"; then
        PENDING+=("$entry")
    else
        UNSUPPORTED+=("$vm_name ($role): $size is not advertised as supporting capacity reservations in $LOCATION")
    fi
done

echo ""
echo "Checking capacity reservation groups..."
if $APP_PRESENT; then
    if ! ensure_crg "$CENTRAL_RG" "$CENTRAL_CRG"; then
        echo "ERROR: central App server CRG '$CENTRAL_RG/$CENTRAL_CRG' could not be created." >&2
        exit 1
    fi
    ensure_sharing "$CENTRAL_RG" "$CENTRAL_CRG"
fi

# Reservation name for a new reservation, e.g. SCUS-AZ01-Apps, SCUS-PGY-AZ01-ACS, SCUS-PGY-AZ03-DB
reservation_name() {
    local role="$1" az
    az=$(printf "AZ%02d" "$2")
    case "$role" in
        app) echo "${REGION_CODE}-${az}-Apps" ;;
        scs) echo "${REGION_CODE}-${SID}-${az}-ACS" ;;
        *)   echo "${REGION_CODE}-${SID}-${az}-DB" ;;
    esac
}

declare -A GROUPED=()
declare -A GROUP_NAME=()
GROUP_ORDER=()
for entry in ${PENDING[@]+"${PENDING[@]}"}; do
    IFS='|' read -r target size zone vm_name role <<< "$entry"
    if [[ "$target" == "central" ]]; then
        rg="$CENTRAL_RG"; crg="$CENTRAL_CRG"
    else
        rg="$RESOURCE_GROUP"; crg="$SID_CRG"
        if ! ensure_crg "$rg" "$crg"; then
            FAILED+=("$vm_name: SID CRG $rg/$crg unavailable")
            continue
        fi
    fi
    if ! crg_has_zone "$rg/$crg" "$zone"; then
        FAILED+=("$vm_name: CRG $rg/$crg does not include zone $zone (zones: ${CRG_ZONE_LIST[$rg/$crg]:-none})")
        continue
    fi
    key="$rg|$crg|$size|$zone"
    if [[ -z "${GROUPED[$key]:-}" ]]; then
        GROUP_ORDER+=("$key")
        GROUP_NAME[$key]=$(reservation_name "$role" "$zone")
    fi
    GROUPED[$key]+="$vm_name "
done

if (( ${#GROUP_ORDER[@]} > 0 )); then
    echo ""
    echo "Reserving capacity and associating VMs..."
    for key in "${GROUP_ORDER[@]}"; do
        IFS='|' read -r rg crg size zone <<< "$key"
        # shellcheck disable=SC2086
        reserve_and_associate "$rg" "$crg" "$size" "$zone" "${GROUP_NAME[$key]}" ${GROUPED[$key]}
    done
fi

echo ""
echo "============ Summary ============"
$DRY_RUN && echo "(plan mode - no Azure changes; local SKU cache may have been refreshed)"
if $DRY_RUN; then
    print_list "Would associate"                     ${ASSOCIATED[@]+"${ASSOCIATED[@]}"}
else
    print_list "Associated"                          ${ASSOCIATED[@]+"${ASSOCIATED[@]}"}
fi
print_list "Skipped - already associated with a CRG" ${SKIPPED_ASSOCIATED[@]+"${SKIPPED_ASSOCIATED[@]}"}
print_list "Skipped - web dispatcher (not reserved)" ${SKIPPED_WEB[@]+"${SKIPPED_WEB[@]}"}
print_list "Not supported - SKU has no ODCR support" ${UNSUPPORTED[@]+"${UNSUPPORTED[@]}"}
print_list "Skipped - other"                         ${SKIPPED_OTHER[@]+"${SKIPPED_OTHER[@]}"}
print_list "Failed"                                  ${FAILED[@]+"${FAILED[@]}"}
echo "Central CRG sharing: $SHARING_RESULT"
echo "================================="

(( ${#FAILED[@]} > 0 )) && exit 1
exit 0
