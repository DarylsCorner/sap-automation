#!/bin/bash
# ODCR Management Script for SAP VMs
#
# Usage: odcr_management.sh <create|plan|info> <sid_resource_group> <subscription_id> <location>
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
#   scs  -> SID CRG (<sid_resource_group>-crg) in the SID resource group
#   db   -> SID CRG (<sid_resource_group>-crg) in the SID resource group
#   web  -> skipped, reported as not reserved
#
# VMs already associated with a CRG are skipped. Regional (non-zonal) VMs are skipped because
# associating them requires a deallocation.
#
# Optional environment overrides:
#   ODCR_TIER          prod | nonprod | test   (default: derived from ENV code, PRD=prod, NRD=nonprod, LAC=test)
#   ODCR_CENTRAL_RG    central App server CRG resource group name
#   ODCR_CENTRAL_CRG   central App server CRG name
#   ODCR_CRG_ZONES     zones used when a CRG is created (default: "1 2 3")

set -uo pipefail

OPERATION="${1:-}"
RESOURCE_GROUP="${2:-}"
SUBSCRIPTION_ID="${3:-}"
LOCATION="${4:-}"

if [[ ! "$OPERATION" =~ ^(create|plan|info)$ ]] || [[ -z "$RESOURCE_GROUP" || -z "$SUBSCRIPTION_ID" || -z "$LOCATION" ]]; then
    echo "Usage: $0 <create|plan|info> <sid_resource_group> <subscription_id> <location>" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Tier / central CRG configuration
# ---------------------------------------------------------------------------
# TODO: TEST ONLY - LAC is the single Sweden Central lab environment. Remove the "test" entries before production use.
declare -A ENV_TO_TIER=( [PRD]="prod" [NRD]="nonprod" [LAC]="test" )
declare -A TIER_TO_CODE=( [prod]="PRD" [nonprod]="NRD" [test]="LAC" )

# Central App server naming: resource group <ENV>-<REGION>-CR (e.g. PRD-SCUS-CR, NRD-SCUS-CR), one per tier per region.
# The CRG spans all zones; reservations inside it carry the zone: <crg>-<sku>-z<zone>.
central_rg_name()  { echo "${1}-${2}-CR"; }         # args: <PRD|NRD> <REGION>
central_crg_name() { echo "${1}-${2}-APP-CRG"; }    # args: <PRD|NRD> <REGION>

IFS='-' read -r ENV_CODE REGION_CODE _ <<< "$RESOURCE_GROUP"
ENV_CODE="${ENV_CODE^^}"
REGION_CODE="${REGION_CODE^^}"

TIER="${ODCR_TIER:-${ENV_TO_TIER[$ENV_CODE]:-}}"
TIER="${TIER,,}"
CENTRAL_RG=""
CENTRAL_CRG=""
if [[ -n "$TIER" && -n "${TIER_TO_CODE[$TIER]:-}" ]]; then
    CENTRAL_RG="${ODCR_CENTRAL_RG:-$(central_rg_name "${TIER_TO_CODE[$TIER]}" "$REGION_CODE")}"
    CENTRAL_CRG="${ODCR_CENTRAL_CRG:-$(central_crg_name "${TIER_TO_CODE[$TIER]}" "$REGION_CODE")}"
fi

SID_CRG="${RESOURCE_GROUP}-crg"
CRG_ZONES="${ODCR_CRG_ZONES:-1 2 3}"
DRY_RUN=false
[[ "$OPERATION" == "plan" ]] && DRY_RUN=true

echo "===== ODCR Management Script ====="
echo "Operation:          $OPERATION"
echo "SID Resource Group: $RESOURCE_GROUP"
echo "Subscription:       $SUBSCRIPTION_ID"
echo "Location:           $LOCATION"
echo "Environment/Region: ${ENV_CODE} / ${REGION_CODE}"
echo "Tier:               ${TIER:-<unresolved>}"
echo "SID CRG (SCS/DB):   ${RESOURCE_GROUP}/${SID_CRG}"
echo "Central App CRG:    ${CENTRAL_RG:-<unresolved>}/${CENTRAL_CRG:-<unresolved>}"
echo "===================================="

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

# All ODCR-capable VM sizes in the region, fetched once (list-skus is slow) on first use.
ODCR_SKUS=""
ODCR_SKUS_LOADED=false
sku_supports_odcr() {
    if ! $ODCR_SKUS_LOADED; then
        ODCR_SKUS=$(az vm list-skus --location "$LOCATION" --resource-type virtualMachines \
            --subscription "$SUBSCRIPTION_ID" \
            --query "[?capabilities[?name=='CapacityReservationSupported' && value=='True']].name" \
            -o tsv 2>/dev/null | tr '[:upper:]' '[:lower:]')
        ODCR_SKUS_LOADED=true
        if [[ -z "$ODCR_SKUS" ]]; then
            echo "ERROR: unable to retrieve VM sizes supporting capacity reservations in $LOCATION" >&2
            exit 1
        fi
    fi
    grep -qxF "${1,,}" <<< "$ODCR_SKUS"
}

declare -A CRG_READY=()
declare -A CRG_ZONE_LIST=()
# ensure_crg <rg> <crg> - verify the CRG exists, create it when missing
ensure_crg() {
    local rg="$1" crg="$2" key="$1/$2" zones
    case "${CRG_READY[$key]:-}" in
        yes) return 0 ;;
        no)  return 1 ;;
    esac

    if zones=$(az capacity reservation group show --resource-group "$rg" --capacity-reservation-group "$crg" \
            --subscription "$SUBSCRIPTION_ID" --query "zones" -o tsv 2>/dev/null); then
        echo "  CRG $key exists (zones: $(echo $zones))"
        CRG_ZONE_LIST[$key]="$(echo $zones)"
        CRG_READY[$key]="yes"
        return 0
    fi

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

# reserve_and_associate <rg> <crg> <sku> <zone> <vm>...
# Uses spare capacity of an existing reservation for the SKU/zone; otherwise grows or creates it.
reserve_and_associate() {
    local rg="$1" crg="$2" sku="$3" zone="$4"
    shift 4
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
        assoc=$(echo "$res" | jq -r '(.virtualMachinesAssociated // []) | length')
        spare=$(( capacity - assoc ))
        (( spare < 0 )) && spare=0
        echo "    Reservation $name: capacity $capacity, associated $assoc, available $spare"

        if (( spare < need )); then
            new_capacity=$(( capacity + need - spare ))
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
        name="${crg}-${sku}-z${zone}"
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
    --query '[].{name:name, size:hardwareProfile.vmSize, zone:zones[0], crg:capacityReservation.capacityReservationGroup.id}' \
    -o json) || { echo "ERROR: unable to list VMs in $RESOURCE_GROUP" >&2; exit 1; }

if [[ "$OPERATION" == "info" ]]; then
    for target in "$RESOURCE_GROUP/$SID_CRG" "${CENTRAL_RG}/${CENTRAL_CRG}"; do
        rg="${target%%/*}"
        crg="${target#*/}"
        [[ -z "$rg" || -z "$crg" ]] && continue
        echo ""
        echo "Capacity Reservation Group: $target"
        echo "========================================"
        if az capacity reservation group show --resource-group "$rg" --capacity-reservation-group "$crg" \
                --subscription "$SUBSCRIPTION_ID" &>/dev/null; then
            az capacity reservation list --resource-group "$rg" --capacity-reservation-group "$crg" \
                --subscription "$SUBSCRIPTION_ID" \
                --query '[].{Name:name, Sku:sku.name, Zone:zones[0], Capacity:sku.capacity, Associated:length(virtualMachinesAssociated || `[]`)}' \
                -o table
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
$DRY_RUN && echo "PLAN MODE - no changes will be made"

APP_PRESENT=false
while IFS= read -r vm_name; do
    [[ "$(vm_role "$vm_name")" == "app" ]] && APP_PRESENT=true
done < <(echo "$VM_JSON" | jq -r '.[].name')

# App servers: the central resource group must already exist (it is never created by this script).
# Checked first so the run stops quickly, before any change is made.
echo ""
echo "Checking capacity reservation groups..."
if $APP_PRESENT; then
    stop_reason=""
    if [[ -z "$CENTRAL_RG" || -z "$CENTRAL_CRG" ]]; then
        stop_reason="environment code '$ENV_CODE' does not map to a tier (PRD=prod, NRD=nonprod, LAC=test). Set odcr_tier (ODCR_TIER) to override."
    elif ! az group show --name "$CENTRAL_RG" --subscription "$SUBSCRIPTION_ID" &>/dev/null; then
        stop_reason="central App server resource group '$CENTRAL_RG' does not exist in subscription $SUBSCRIPTION_ID. It must be provisioned before running ODCR."
    elif ! ensure_crg "$CENTRAL_RG" "$CENTRAL_CRG"; then
        stop_reason="central App server CRG '$CENTRAL_RG/$CENTRAL_CRG' could not be created."
    fi
    if [[ -n "$stop_reason" ]]; then
        echo ""
        echo "================ STOPPED ================"
        echo "ERROR: $stop_reason"
        echo "No capacity reservations were created and no VMs were associated."
        echo "========================================="
        exit 1
    fi
fi

echo ""
echo "Checking VM sizes for capacity reservation support in $LOCATION..."
# Classify VMs; pending entries are "<target>|<sku>|<zone>|<vm>"
PENDING=()
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
    if ! sku_supports_odcr "$size"; then
        UNSUPPORTED+=("$vm_name ($role): $size does not support capacity reservations in $LOCATION")
        continue
    fi

    if [[ "$role" == "app" ]]; then
        PENDING+=("central|$size|$zone|$vm_name")
    else
        PENDING+=("sid|$size|$zone|$vm_name")
    fi
done < <(echo "$VM_JSON" | jq -c '.[]')

declare -A GROUPED=()
GROUP_ORDER=()
for entry in ${PENDING[@]+"${PENDING[@]}"}; do
    IFS='|' read -r target size zone vm_name <<< "$entry"
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
    [[ -z "${GROUPED[$key]:-}" ]] && GROUP_ORDER+=("$key")
    GROUPED[$key]+="$vm_name "
done

if (( ${#GROUP_ORDER[@]} > 0 )); then
    echo ""
    echo "Reserving capacity and associating VMs..."
    for key in "${GROUP_ORDER[@]}"; do
        IFS='|' read -r rg crg size zone <<< "$key"
        # shellcheck disable=SC2086
        reserve_and_associate "$rg" "$crg" "$size" "$zone" ${GROUPED[$key]}
    done
fi

echo ""
echo "============ Summary ============"
$DRY_RUN && echo "(plan mode - nothing was changed)"
print_list "Associated"                              ${ASSOCIATED[@]+"${ASSOCIATED[@]}"}
print_list "Skipped - already associated with a CRG" ${SKIPPED_ASSOCIATED[@]+"${SKIPPED_ASSOCIATED[@]}"}
print_list "Skipped - web dispatcher (not reserved)" ${SKIPPED_WEB[@]+"${SKIPPED_WEB[@]}"}
print_list "Not supported - SKU has no ODCR support" ${UNSUPPORTED[@]+"${UNSUPPORTED[@]}"}
print_list "Skipped - other"                         ${SKIPPED_OTHER[@]+"${SKIPPED_OTHER[@]}"}
print_list "Failed"                                  ${FAILED[@]+"${FAILED[@]}"}
echo "================================="

(( ${#FAILED[@]} > 0 )) && exit 1
exit 0
