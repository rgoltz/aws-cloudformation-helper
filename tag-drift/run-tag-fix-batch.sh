#!/usr/bin/env bash
#
# run-tag-fix-batch.sh
#
# Fuehrt fix-tag-drift.sh ueber eine Liste von Stacks aus und macht
# anschliessend (nur bei --apply) eine Drift-Detection + Status-Report.
#
# Usage:
#   ./run-tag-fix-batch.sh [--apply]
#
set -euo pipefail

REGION="eu-central-1"
APPLY="${1:-dryrun}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STACKS=(
  "ecs-qa-service-grindr"
  "ecs-prd-service-tinder"
  "ecs-uat-service-sniffies"
)

echo "########## PHASE 1: FIX (${APPLY}) ##########"
for s in "${STACKS[@]}"; do
  "${SCRIPT_DIR}/fix-tag-drift.sh" "${s}" "${APPLY}" || echo "  !! error on ${s}"
done

if [[ "${APPLY}" != "--apply" ]]; then
  echo "Dry-run complete. Re-run with --apply to set tags."
  exit 0
fi

echo "########## PHASE 2: DRIFT DETECTION ##########"
declare -A DETECT_IDS
for s in "${STACKS[@]}"; do
  ID=$(aws cloudformation detect-stack-drift --region "${REGION}" \
        --stack-name "${s}" --query StackDriftDetectionId --output text)
  DETECT_IDS["${s}"]="${ID}"
done

echo "Waiting 60s for drift detection to complete..."
sleep 60

echo "########## PHASE 3: STATUS REPORT ##########"
for s in "${STACKS[@]}"; do
  ID="${DETECT_IDS[${s}]}"
  RESULT=$(aws cloudformation describe-stack-drift-detection-status \
            --region "${REGION}" --stack-drift-detection-id "${ID}" \
            --query '[StackDriftStatus,DriftedStackResourceCount,DetectionStatus]' \
            --output text 2>/dev/null || echo "ERROR - -")
  printf "  %-55s %s\n" "${s}" "${RESULT}"
done
echo "=== Batch done ==="