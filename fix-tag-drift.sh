#!/usr/bin/env bash
#
# fix-tag-drift.sh
#
# Behebt Tag-Drift auf Ressourcen, deren Tags von der Ressource entfernt wurden
# (DifferenceType REMOVE), obwohl das CloudFormation-Template sie erwartet.
#
# Unterstuetzte Ressourcentypen:
#   - AWS::ElasticLoadBalancingV2::Listener       (elbv2 add-tags)
#   - AWS::ElasticLoadBalancingV2::ListenerRule   (elbv2 add-tags)
#   - AWS::ApplicationAutoScaling::ScalableTarget (application-autoscaling tag-resource)
#
# Sicherheitslogik:
#   - Verarbeitet NUR die o.g. Typen
#   - Verarbeitet NUR Ressourcen, deren Drift ausschliesslich /Tags betrifft
#     UND alle Differenzen vom Typ REMOVE sind (kein bewusstes Aendern von Werten)
#   - DRY-RUN per Default; echtes Setzen nur mit --apply
#
# Usage:
#   ./fix-tag-drift.sh <STACK_NAME> [--apply]
#
set -euo pipefail

REGION="eu-central-1"
STACK_NAME="${1:?Stack name required}"
APPLY="${2:-dryrun}"

echo "=== Stack: ${STACK_NAME} (${APPLY}) ==="

DRIFTS=$(aws cloudformation describe-stack-resource-drifts \
  --region "${REGION}" \
  --stack-name "${STACK_NAME}" \
  --stack-resource-drift-status-filters MODIFIED \
  --output json)

TOTAL=$(echo "${DRIFTS}" | jq '.StackResourceDrifts | length')
echo "MODIFIED resources total: ${TOTAL}"

# Ermittelt die tag-faehige ScalableTarget-ARN aus der CFN PhysicalResourceId.
# PhysicalResourceId-Format: "service/<cluster>/<service>|<scalable-dimension>|<namespace>"
# Benoetigt: describe-scalable-targets, um die echte ARN zu erhalten.
resolve_scalable_target_arn() {
  local pid="$1"
  local resource_id namespace
  resource_id="${pid%%|*}"                 # vor dem ersten |
  namespace="${pid##*|}"                   # nach dem letzten |
  aws application-autoscaling describe-scalable-targets \
    --region "${REGION}" \
    --service-namespace "${namespace}" \
    --resource-ids "${resource_id}" \
    --query 'ScalableTargets[0].ScalableTargetARN' \
    --output text 2>/dev/null
}

echo "${DRIFTS}" | jq -c '.StackResourceDrifts[]' | while read -r drift; do
  RTYPE=$(echo "${drift}" | jq -r '.ResourceType')
  LID=$(echo "${drift}"  | jq -r '.LogicalResourceId')
  PID=$(echo "${drift}"  | jq -r '.PhysicalResourceId')

  case "${RTYPE}" in
    "AWS::ElasticLoadBalancingV2::Listener"|"AWS::ElasticLoadBalancingV2::ListenerRule"|"AWS::ApplicationAutoScaling::ScalableTarget")
      ;;
    *)
      echo "  SKIP (unsupported type): ${LID} [${RTYPE}]"
      continue
      ;;
  esac

  # Nur reiner Tag-REMOVE-Drift
  NON_TAG=$(echo "${drift}" | jq -r '[.PropertyDifferences[] | select(.PropertyPath | test("^/Tags") | not)] | length')
  NON_REMOVE=$(echo "${drift}" | jq -r '[.PropertyDifferences[] | select(.DifferenceType != "REMOVE")] | length')
  if [[ "${NON_TAG}" != "0" ]]; then
    OTHER=$(echo "${drift}" | jq -r '[.PropertyDifferences[] | select(.PropertyPath | test("^/Tags") | not) | .PropertyPath] | join(", ")')
    echo "  SKIP (non-tag drift): ${LID} -> [${OTHER}]"
    continue
  fi
  if [[ "${NON_REMOVE}" != "0" ]]; then
    echo "  SKIP (tag value changed, not just removed): ${LID}"
    continue
  fi

  EXPECTED_TAGS=$(echo "${drift}" | jq -c '.ExpectedProperties | fromjson | .Tags')
  if [[ "${EXPECTED_TAGS}" == "null" || -z "${EXPECTED_TAGS}" ]]; then
    echo "  SKIP (no expected tags): ${LID}"
    continue
  fi
  TAGCOUNT=$(echo "${EXPECTED_TAGS}" | jq 'length')

  case "${RTYPE}" in
    "AWS::ElasticLoadBalancingV2::Listener"|"AWS::ElasticLoadBalancingV2::ListenerRule")
      echo "  FIX (elbv2): ${LID} (${TAGCOUNT} tags)"
      if [[ "${APPLY}" == "--apply" ]]; then
        aws elbv2 add-tags \
          --region "${REGION}" \
          --resource-arns "${PID}" \
          --tags "${EXPECTED_TAGS}"
        echo "       -> tags applied"
      else
        echo "       -> DRY-RUN, would apply: ${EXPECTED_TAGS}"
      fi
      ;;

    "AWS::ApplicationAutoScaling::ScalableTarget")
      # application-autoscaling tag-resource erwartet:
      #   --resource-arn <scalable-target-arn>
      #   --tags KeyName=Value  (Map, nicht Key/Value-Liste!)
      #
      # ResourceId/Namespace primaer aus PhysicalResourceId; falls diese fehlt
      # (manche Stacks melden keine PID im Drift), aus ExpectedProperties ziehen.
      local_resource_id=""
      local_namespace=""
      if [[ -n "${PID}" && "${PID}" != "None" && "${PID}" != "null" ]]; then
        local_resource_id="${PID%%|*}"
        local_namespace="${PID##*|}"
      else
        local_resource_id=$(echo "${drift}" | jq -r '.ExpectedProperties | fromjson | .ResourceId')
        local_namespace=$(echo "${drift}"   | jq -r '.ExpectedProperties | fromjson | .ServiceNamespace')
      fi

      ARN=$(aws application-autoscaling describe-scalable-targets \
              --region "${REGION}" \
              --service-namespace "${local_namespace}" \
              --resource-ids "${local_resource_id}" \
              --query 'ScalableTargets[0].ScalableTargetARN' \
              --output text 2>/dev/null)

      TAGS_MAP=$(echo "${EXPECTED_TAGS}" | jq -c 'map({(.Key): .Value}) | add')

      if [[ -z "${ARN}" || "${ARN}" == "None" ]]; then
        # Sonderfall: Target hat (noch) keine ARN -> per register-scalable-target
        # (ohne --tags) ARN erzeugen, dann taggen. Nur bei --apply, da schreibend.
        echo "  FIX (autoscaling, needs ARN mint): ${LID} (${TAGCOUNT} tags) [${local_resource_id}]"
        if [[ "${APPLY}" == "--apply" ]]; then
          local_min=$(echo "${drift}" | jq -r '.ExpectedProperties | fromjson | .MinCapacity')
          local_max=$(echo "${drift}" | jq -r '.ExpectedProperties | fromjson | .MaxCapacity')
          local_dim=$(echo "${drift}" | jq -r '.ExpectedProperties | fromjson | .ScalableDimension')
          ARN=$(aws application-autoscaling register-scalable-target \
                  --region "${REGION}" \
                  --service-namespace "${local_namespace}" \
                  --resource-id "${local_resource_id}" \
                  --scalable-dimension "${local_dim}" \
                  --min-capacity "${local_min}" --max-capacity "${local_max}" \
                  --query 'ScalableTargetARN' --output text)
          aws application-autoscaling tag-resource \
            --region "${REGION}" --resource-arn "${ARN}" --tags "${TAGS_MAP}"
          echo "       -> ARN minted + tags applied (${ARN})"
        else
          echo "       -> DRY-RUN, would mint ARN (register) + apply: ${TAGS_MAP}"
        fi
        continue
      fi

      echo "  FIX (autoscaling): ${LID} (${TAGCOUNT} tags) -> ${ARN}"
      if [[ "${APPLY}" == "--apply" ]]; then
        aws application-autoscaling tag-resource \
          --region "${REGION}" \
          --resource-arn "${ARN}" \
          --tags "${TAGS_MAP}"
        echo "       -> tags applied"
      else
        echo "       -> DRY-RUN, would apply to ${ARN}: ${TAGS_MAP}"
      fi
      ;;
  esac
done

echo "=== Done for ${STACK_NAME} ==="