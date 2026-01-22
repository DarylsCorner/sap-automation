#!/bin/bash
# ODCR Management Script for SAP VMs
# Usage: odcr_management.sh [create|info] <resource_group> <subscription_id> <location>

set -e

OPERATION="${1:-create}"
RESOURCE_GROUP="$2"
SUBSCRIPTION_ID="$3"
LOCATION="$4"
CRG_NAME="${RESOURCE_GROUP}-crg"

echo "===== ODCR Management Script ====="
echo "Operation: $OPERATION"
echo "Resource Group: $RESOURCE_GROUP"
echo "Subscription: $SUBSCRIPTION_ID"
echo "Location: $LOCATION"
echo "===================================="

# Set subscription
az account set --subscription "$SUBSCRIPTION_ID"

if [ "$OPERATION" == "create" ]; then
    echo ""
    echo "Getting VMs in resource group..."
    VM_JSON=$(az vm list --resource-group "$RESOURCE_GROUP" --query '[].{Name:name, Size:hardwareProfile.vmSize, Zone:zones[0]}' -o json)
    
    VM_COUNT=$(echo "$VM_JSON" | jq '. | length')
    echo "Found $VM_COUNT VMs"
    
    # Get unique zones
    ZONES=$(echo "$VM_JSON" | jq -r '.[].Zone' | sort -u | tr '\n' ' ' | xargs)
    echo "Zones: $ZONES"
    
    # Check if CRG exists
    if az capacity reservation group show -g "$RESOURCE_GROUP" -n "$CRG_NAME" &>/dev/null; then
        echo "Capacity Reservation Group $CRG_NAME already exists"
    else
        echo "Creating Capacity Reservation Group: $CRG_NAME"
        az capacity reservation group create \
            --resource-group "$RESOURCE_GROUP" \
            --capacity-reservation-group "$CRG_NAME" \
            --location "$LOCATION" \
            --zones $ZONES
    fi
    
    # Count VMs per size/zone
    declare -A capacity_needed
    
    while IFS= read -r vm; do
        size=$(echo "$vm" | jq -r '.Size')
        zone=$(echo "$vm" | jq -r '.Zone')
        key="${size}_${zone}"
        capacity_needed[$key]=$((${capacity_needed[$key]:-0} + 1))
    done < <(echo "$VM_JSON" | jq -c '.[]')
    
    # Create reservations
    echo ""
    echo "Creating capacity reservations..."
    for key in "${!capacity_needed[@]}"; do
        sku="${key%_*}"
        zone="${key##*_}"
        capacity="${capacity_needed[$key]}"
        reservation_name="${CRG_NAME}-${sku}-z${zone}"
        
        echo "  - $reservation_name (SKU: $sku, Zone: $zone, Capacity: $capacity)"
        
        az capacity reservation create \
            --resource-group "$RESOURCE_GROUP" \
            --capacity-reservation-group "$CRG_NAME" \
            --name "$reservation_name" \
            --sku "$sku" \
            --capacity "$capacity" \
            --zone "$zone" 2>/dev/null || echo "    (Already exists or failed)"
    done
    
    # Associate VMs
    echo ""
    echo "Associating VMs with capacity reservation group..."
    while IFS= read -r vm; do
        vm_name=$(echo "$vm" | jq -r '.Name')
        echo "  - $vm_name"
        
        az vm update \
            --resource-group "$RESOURCE_GROUP" \
            --name "$vm_name" \
            --capacity-reservation-group "$CRG_NAME" 2>/dev/null || echo "    (Failed or already associated)"
    done < <(echo "$VM_JSON" | jq -c '.[]')
    
    echo ""
    echo "✓ Capacity reservations created and VMs associated"
    
elif [ "$OPERATION" == "info" ]; then
    echo ""
    echo "Capacity Reservation Group Information:"
    echo "========================================"
    
    if az capacity reservation group show -g "$RESOURCE_GROUP" -n "$CRG_NAME" &>/dev/null; then
        az capacity reservation group show -g "$RESOURCE_GROUP" -n "$CRG_NAME" -o table
        
        echo ""
        echo "Capacity Reservations:"
        echo "======================"
        az capacity reservation list -g "$RESOURCE_GROUP" -c "$CRG_NAME" -o table
        
        echo ""
        echo "VM Associations:"
        echo "================"
        az vm list -g "$RESOURCE_GROUP" \
            --query '[].{Name:name, Size:hardwareProfile.vmSize, Zone:zones[0], CapacityReservation:capacityReservation.capacityReservationGroup.id}' \
            -o table
    else
        echo "Capacity Reservation Group $CRG_NAME not found"
    fi
fi
