# ODCR lab demo: X00, without subscription sharing

Updated: 2026-10-09. Lab branch: `feature/odcr-role-based-crg`.

This runbook describes the lab implementation, not the published customer version. Do not promote lab
changes to the customer repository without approval. Subscription sharing, consumer X01 deployment,
cross-subscription pool selection and failover automation are excluded from this demo.

## Verified starting point

At the end of 2026-10-08:

- All eight X00 VMs and the separate consumer X01 app05 were deallocated and unassociated.
- Both lab CRGs and all five reservations were deleted; their resource groups were retained.
- VM disks, networking, logs, SKU cache and consumer lab RBAC were retained. The deployer stayed running.
- Deallocation stopped VM compute charges. Deleting reservations stopped ODCR charges. Retained disks,
  networking and the running deployer may still incur charges.

Verify this baseline again before presenting. Keep consumer X01 untouched and deallocated.
The X00 VM list includes the out-of-band app05 even though it is absent from the SDAF inventory.
Consequently, the initial demo now handles **eight VMs**, not seven.

## Inputs and behavior

- Run from the SID workspace. `X00_hosts.yaml` supplies only `resource_group_name` and `subscription_id`.
  `sap-parameters.yaml`, SSH private keys and inventory host membership are not required by ODCR.
- One resource group is targeted per run. Azure CLI discovers VM ID, name, location, size, zone and CRG link.
  Role is inferred from the VM name; out-of-band VMs must follow the supported naming convention.
- All discovered VMs must have one common Azure region, including skipped roles. The resource group's
  metadata location is not used. The region code in its name is naming metadata only.
- Empty/invalid VM discovery, mixed VM regions, and target CRG region mismatches stop the run before writes.
- App VMs use the central `LAC-SECE-CR/SECE-CR`; SCS/DB use the SID's `SECE-X00-CR`.
  The lab maps `LAC` to the `test` tier. The central resource group must already exist.
- Existing CRG associations are skipped, even if they point to a different pool. This is not reassignment
  or failover automation.
- Reservations match SKU and zone. Spare capacity is reused; insufficient capacity grows to the existing
  association count plus incoming VMs. Excess capacity is not automatically shrunk.
- VM and reservation reads remain live. Only SKU capability results are cached.

### SKU cache

The cache is keyed by subscription and VM region under `${XDG_CACHE_HOME:-$HOME/.cache}/sdaf-odcr`,
with a **24-hour lifetime**. App, SCS and DB candidate sizes are checked.

Missing, expired, invalid, wrong-scope or previously unseen SKU data triggers one Azure refresh per run.
Known unsupported entries are retained as false. A required refresh failure stops before Azure writes;
stale data is not a success fallback. The cache is written atomically, but shared capacity mutations are
not serialized: run one ODCR operation at a time against the pool.

Options:

| Ansible variable | Direct-script environment variable | Meaning |
|---|---|---|
| `odcr_sku_cache_refresh` | `ODCR_SKU_CACHE_REFRESH` | `true` forces refresh for plan/create |
| `odcr_sku_cache_directory` | `ODCR_SKU_CACHE_DIR` | Override the writable cache directory |

`info` never refreshes SKU data. With no eligible unassociated VMs, normal plan/create skips that lookup.
Support information is not a guarantee of available quota or physical capacity.

### Logs and completion marker

Each playbook plan/create/info automatically saves a separate timestamped result log in the workspace's
`logs/odcr` directory and displays its path. It includes scope, UTC times, stdout, stderr and script exit code.
Returned script errors are saved before failure is reported. Directory/file permissions are `0700`/`0600`.

Logs are saved when the script returns, not streamed. Interrupted runs can leave a `started` log; inspect
Azure before retrying. These are not full Ansible transcripts and exclude shell `time` statistics and
pre-script validation failures. Direct script invocation does not create playbook-managed logs.
No log retention cleanup is automatic.

Successful create touches `.progress/odcr-management-done`. Logging and marker tasks can show Ansible
`changed` even if Azure associations/reservations were unchanged. Plan makes no Azure changes, but may
write local logs/cache. Info reads Azure and writes its local result log.

Direct script syntax:

```text
odcr_management.sh <plan|create|info> <SID resource group> <subscription ID> [expected location]
```

The optional fourth argument must match VM-derived location; it cannot override it.

## Demo commands

Run these on the Linux deployer, one step at a time. Stop on errors and verify results before continuing.
All X00 VMs can remain deallocated throughout. Creating reservations is billable even with VMs deallocated.

### 1. Set up once per terminal session

```bash
cd ~/Azure_SAP_Automated_Deployment/sap-automation
git switch feature/odcr-role-based-crg
git pull --ff-only myfork feature/odcr-role-based-crg

cd ~/Azure_SAP_Automated_Deployment/WORKSPACES/SYSTEM/LAC-SECE-SAP04-X00
export ANSIBLE_INVENTORY=X00_hosts.yaml
PB=~/Azure_SAP_Automated_Deployment/sap-automation/deploy/ansible/playbook_11_00_00_capacity_reservations.yaml
SUB=7cbf463c-91b1-4017-8dc8-3939b5c0fc27
RG=LAC-SECE-SAP04-X00
APP05="${RG}_x00app05l415"
```

The inventory export lasts for this shell session; repeat it after reconnecting or changing SID.
Always return to the SID workspace before using `_workspace_directory=$(pwd)`.
Do not pass `odcr_share_subscriptions` or inherited sharing overrides during this demo.

### 2. Baseline info

```bash
ansible-playbook "$PB" --extra-vars="_workspace_directory=$(pwd)" --extra-vars="odcr_action=info"
```

Expect both CRGs not found, eight VMs with no CRG link, and region `swedencentral (from Azure VMs)`.

### 3. Demonstrate Azure refresh and cache reuse

```bash
time ansible-playbook "$PB" --extra-vars="_workspace_directory=$(pwd)" \
  --extra-vars="odcr_action=plan" --extra-vars='{"odcr_sku_cache_refresh":true}'

time ansible-playbook "$PB" --extra-vars="_workspace_directory=$(pwd)" \
  --extra-vars="odcr_action=plan"
```

First: `SKU support source: Azure`, cache age 0. Second: `SKU support source: local cache` and its age.
Both: eight VMs discovered, `Would associate: 8`, `Failed: 0`, no Azure mutation.
Forcing refresh makes the demonstration deterministic even if yesterday's cache is still fresh.

Measured on 2026-10-08 with seven VMs: initial lookup **2m15.583s**, cache reuse **16.266s**,
manual refresh **2m15.292s** (about 88% less elapsed time on reuse). These are observations, not guarantees.

### 4. Create and inspect

```bash
ansible-playbook "$PB" --extra-vars="_workspace_directory=$(pwd)" --extra-vars="odcr_action=create"
ansible-playbook "$PB" --extra-vars="_workspace_directory=$(pwd)" --extra-vars="odcr_action=info"
```

Expected: two CRGs, five reservations, eight associations, zero failures:

| Reservation | Capacity | Associated |
|---|---:|---:|
| `SECE-AZ02-Apps` | 3 | 3 |
| `SECE-AZ03-Apps` | 2 | 2 |
| `SECE-X00-AZ02-ACS` | 1 | 1 |
| `SECE-X00-AZ03-ACS` | 1 | 1 |
| `SECE-X00-AZ02-DB` | 1 | 1 |

Allocated counts reflect actually allocated VMs, not merely associations. Do not expect equality with
Associated while VMs are deallocated. Verify Capacity/Associated and each VM's destination.

### 5. Repeat create

```bash
ansible-playbook "$PB" --extra-vars="_workspace_directory=$(pwd)" --extra-vars="odcr_action=create"
```

Expect `Associated: 0`, eight existing associations skipped, `Failed: 0`, and no capacity growth.
Local logs and the completion marker still change.

### 6. Simulate growth for an unassociated out-of-band app05

App05 already exists: this is a simulation of onboarding an unassociated VM, not a new VM deployment
during the demo. It remains absent from the SDAF inventory; do not edit that file.

```bash
az vm deallocate --subscription "$SUB" -g "$RG" -n "$APP05" &&
az vm update --subscription "$SUB" -g "$RG" -n "$APP05" \
  --capacity-reservation-group None --output none &&
az capacity reservation update --subscription "$SUB" -g LAC-SECE-CR \
  --capacity-reservation-group SECE-CR --capacity-reservation-name SECE-AZ02-Apps \
  --capacity 2 --output none
```

This lab-only setup removes app05's coverage and deliberately shrinks capacity. Use deallocation, not
setting the reservation to zero, so app01/app03 retain their two reserved slots.
Verify the reservation now has capacity 2 and two associations before proceeding.

```bash
ansible-playbook "$PB" --extra-vars="_workspace_directory=$(pwd)" --extra-vars="odcr_action=plan"
ansible-playbook "$PB" --extra-vars="_workspace_directory=$(pwd)" --extra-vars="odcr_action=create"
ansible-playbook "$PB" --extra-vars="_workspace_directory=$(pwd)" --extra-vars="odcr_action=info"
```

Plan: grow `SECE-AZ02-Apps` **2 to 3**, associate app05, skip seven others.
Create: one association, zero failures. Info: capacity 3, associated 3; other reservations unchanged.

### 7. Demonstrate spare-capacity reuse

```bash
az vm deallocate --subscription "$SUB" -g "$RG" -n "$APP05" &&
az vm update --subscription "$SUB" -g "$RG" -n "$APP05" \
  --capacity-reservation-group None --output none

ansible-playbook "$PB" --extra-vars="_workspace_directory=$(pwd)" --extra-vars="odcr_action=plan"
```

Leave capacity at 3. Before applying, confirm:
`capacity 3, associated 2, available 1` and `Available capacity found - associating`.
There must be no reservation update.

```bash
ansible-playbook "$PB" --extra-vars="_workspace_directory=$(pwd)" --extra-vars="odcr_action=create"
ansible-playbook "$PB" --extra-vars="_workspace_directory=$(pwd)" --extra-vars="odcr_action=info"
```

Expect app05 reassociated, capacity still 3, associated 3, other reservations unchanged.

### 8. Show the automatic log

Use the exact path printed by the playbook. No logging export or additional argument is needed.
If you enter the log directory, return to the SID workspace before running the next playbook.

## Cleanup after the demo

Do not rerun create after cleanup; it would recreate billable reservations. Leave the deployer running
unless separately approved. Consumer X01 is excluded and should already remain deallocated.

First deallocate and unlink all eight X00 VMs. The subshell stops on error without closing the terminal.

```bash
(
set -euo pipefail
for suffix in x00app01l415 x00app02l415 x00app03l415 x00app04l415 \
  x00app05l415 x00dhdb01l0415 x00scs01l415 x00scs02l415
do
  az vm deallocate --subscription "$SUB" -g "$RG" -n "${RG}_${suffix}"
  az vm update --subscription "$SUB" -g "$RG" -n "${RG}_${suffix}" \
    --capacity-reservation-group None --output none
done
echo "All X00 VMs deallocated and unlinked."
)
```

Only after that block succeeds, delete the reservations and CRGs. This queries remaining groups and
reservation names on each run, so it can resume after partial deletion without failing on earlier deletions.
Read or delete errors stop the block; they are not treated as successful cleanup.

```bash
(
set -euo pipefail
for target in LAC-SECE-CR/SECE-CR LAC-SECE-SAP04-X00/SECE-X00-CR
do
  target_rg="${target%/*}"
  crg="${target#*/}"
  groups=$(az capacity reservation group list --subscription "$SUB" -g "$target_rg" -o json)
  present=$(jq -er --arg name "$crg" \
    'if type == "array" then any(.[]; .name == $name) else error("Invalid CRG list") end | tostring' \
    <<< "$groups")
  if [[ "$present" == "false" ]]; then
    echo "$target already deleted."
    continue
  fi
  reservations=$(az capacity reservation list --subscription "$SUB" -g "$target_rg" \
    --capacity-reservation-group "$crg" -o json)
  names=$(jq -er 'if type == "array" then
    [.[].name | if type == "string" and length > 0 then . else error("Invalid name") end] |
    join("\n") else error("Invalid reservation list") end' <<< "$reservations")
  while IFS= read -r name
  do
    [[ -z "$name" ]] && continue
    az capacity reservation delete --subscription "$SUB" -g "$target_rg" \
      --capacity-reservation-group "$crg" --capacity-reservation-name "$name" --yes
  done <<< "$names"
  az capacity reservation group delete --subscription "$SUB" -g "$target_rg" \
    --capacity-reservation-group "$crg" --yes
done
echo "ODCR reservations and CRGs deleted."
)
```

If deletion reports a VM reference, inspect the referenced VM and reservation, confirm deallocation,
and remove that association before retrying. Do not assume Azure propagation lag or reduce capacity to
zero as a shortcut. Yesterday's cleanup was blocked by remaining App/SCS/DB references until they were removed.

Finally verify both resource groups return empty CRG lists, and all eight X00 VMs report `VM deallocated`
and null CRG links. VM shutdown alone does not stop reservation charges. Retained disks/networking still cost.

## Coverage and deferred work

Live verified on 2026-10-08: VM-derived region, initial creation, correct placement, repeat-create skips,
cache reuse/forced refresh, automatic logs, genuine out-of-band app05 discovery/growth, spare-capacity
reuse, and final deallocation/disassociation/reservation deletion.

The 27 automated lab tests also cover cache expiry, malformed data, unknown/unsupported SKUs, refresh
failure before writes, log failure handling and representative placement/growth behavior:

```bash
python3 -B -m unittest discover -s tests/deploy/scripts -p 'test_odcr_sku_cache.py' -v
```

Unsupported DB SKUs, all partial Azure failures, concurrent capacity mutation and cross-region failover
are not fully live-validated. Some reservation/sharing read paths still need error-handling hardening
before a customer release. A failed lookup must not be considered evidence of spare capacity.

CRG sharing was applied and verified with the consumer subscription, but consumer capacity consumption
was not tested. Cleanup deleted the shared CRG, removing that sharing profile. Consumer lab RBAC and the
deallocated VM remain. Sharing grants access; it neither selects another subscription's App pool in this
playbook nor implements reassignment/failover. Defer those design decisions and tests to a separate phase.
