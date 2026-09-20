#!/usr/bin/env bash
# Probes which Azure region (from the subscription's allowed-region list)
# can actually provision both an IaaS VM and the PaaS General Purpose tier.
# Every check is a REAL resource creation — list-skus / list-usage do not
# catch the capacity and policy restrictions this subscription keeps
# hitting — each is torn down immediately after the attempt.
#
# Run: chmod +x probe-regions.sh && ./probe-regions.sh
# Takes several minutes; stops early if a region passes both checks.

set -uo pipefail

REGIONS=("belgiumcentral" "francecentral" "swedencentral")
VM_SIZES=("Standard_B2s_v2" "Standard_B2s" "Standard_B2ms")
PG_SKU="Standard_D2s_v3"
ADMIN_PASS='TempPassw0rd!2026'

declare -A VM_RESULT
declare -A PG_RESULT

for region in "${REGIONS[@]}"; do
  RG="rg-quota-test-${region}"
  echo "=========================================="
  echo "Region: $region"
  echo "=========================================="
  az group create --name "$RG" --location "$region" -o none

  vm_ok=""
  for size in "${VM_SIZES[@]}"; do
    echo "-> Trying VM size: $size"
    if az vm create \
        --resource-group "$RG" \
        --name "vmtest" \
        --image Ubuntu2204 \
        --size "$size" \
        --admin-username azureuser \
        --generate-ssh-keys \
        --public-ip-address "" \
        > "/tmp/vm_${region}_${size}.log" 2>&1; then
      vm_ok="$size"
      az vm delete --resource-group "$RG" --name "vmtest" --yes -o none
      break
    else
      echo "   failed (log: /tmp/vm_${region}_${size}.log)"
    fi
  done
  if [[ -n "$vm_ok" ]]; then
    VM_RESULT[$region]="OK ($vm_ok)"
  else
    VM_RESULT[$region]="FAIL (tried: ${VM_SIZES[*]})"
  fi

  echo "-> Trying PostgreSQL Flexible Server: $PG_SKU (GeneralPurpose)"
  if az postgres flexible-server create \
      --resource-group "$RG" \
      --name "pgtest-${region}" \
      --location "$region" \
      --sku-name "$PG_SKU" \
      --tier GeneralPurpose \
      --storage-size 32 \
      --version 16 \
      --public-access none \
      --admin-user pgtestadmin \
      --admin-password "$ADMIN_PASS" \
      --yes \
      > "/tmp/pg_${region}.log" 2>&1; then
    PG_RESULT[$region]="OK"
  else
    PG_RESULT[$region]="FAIL: $(tail -3 "/tmp/pg_${region}.log" | tr '\n' ' ')"
  fi

  az group delete --name "$RG" --yes --no-wait
  echo ""

  if [[ "${VM_RESULT[$region]}" == OK* && "${PG_RESULT[$region]}" == "OK" ]]; then
    echo ">>> $region works for both — stopping here, no need to test the rest."
    break
  fi
done

echo "================ SUMMARY ================"
for region in "${REGIONS[@]}"; do
  [[ -z "${VM_RESULT[$region]:-}" ]] && continue
  echo "$region:"
  echo "  VM:         ${VM_RESULT[$region]}"
  echo "  PostgreSQL: ${PG_RESULT[$region]:-not reached}"
done
echo ""
echo "Full error logs saved under /tmp/vm_*.log and /tmp/pg_*.log"