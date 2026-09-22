# Tag Drift Fix

Fixes CloudFormation tag drift on resources whose tags are missing on the live resource while the template still expects them (`/Tags` → `REMOVE`).

## What

- `fix-tag-drift.sh`: fixes one stack.
- `run-tag-fix-batch.sh`: runs the fix over a list of stacks, then triggers drift detection and prints a status report.

Supported resource types:

| Resource type | Fix command | Tags support (CFN docs) |
|---|---|---|
| `AWS::ElasticLoadBalancingV2::Listener` | `elbv2 add-tags` | [docs](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-elasticloadbalancingv2-listener.html#cfn-elasticloadbalancingv2-listener-tags) |
| `AWS::ElasticLoadBalancingV2::ListenerRule` | `elbv2 add-tags` | [docs](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-elasticloadbalancingv2-listenerrule.html#cfn-elasticloadbalancingv2-listenerrule-tags) |
| `AWS::ApplicationAutoScaling::ScalableTarget` | `application-autoscaling tag-resource` | [docs](https://docs.aws.amazon.com/AWSCloudFormation/latest/TemplateReference/aws-resource-applicationautoscaling-scalabletarget.html#cfn-applicationautoscaling-scalabletarget-tags) |

## Why

The scope is **existing stacks that predate the introduction of tag support (in 2026)** for these resource types plus **stacks using stack-level tags** (often if you use CDK). In both cases the template now expects tags on the resource, but the deployed resource has none - So drift detection reports a `/Tags` `REMOVE`. The functional config is fine; only the tags are missing. These scripts re-apply the exact tags from the template.

## How

```bash
# Single stack, dry-run (default, read-only):
./tag-drift/fix-tag-drift.sh <STACK_NAME>

# Single stack, actually apply tags:
./tag-drift/fix-tag-drift.sh <STACK_NAME> --apply

# Batch (edit the STACKS list inside the script first):
./tag-drift/run-tag-fix-batch.sh           # dry-run
./tag-drift/run-tag-fix-batch.sh --apply   # apply + drift detection + report
```

## Safety

- Only touches the supported resource types above.
- Only acts when **all** drift differences are under `/Tags` **and** all are `REMOVE`. Anything else (changed values, other properties) is skipped.
- Dry-run by default; nothing is written without `--apply`.
- Tags are read from each resource's own `ExpectedProperties` (the template), so values stay stack-specific.

## Notes

- Region is hardcoded to `eu-central-1` (edit `REGION` if needed).
- **ScalableTarget ARN:** the CFN `PhysicalResourceId` is not the tag-capable ARN. The script resolves the real ARN via `describe-scalable-targets`. If the `PhysicalResourceId` is missing (`null`), it derives `ResourceId` / `ServiceNamespace` from `ExpectedProperties`.
- **ScalableTarget without ARN:** some older targets return no `ScalableTargetARN`. The script mints one via `register-scalable-target` (without `--tags`, using the template's Min/Max — no capacity change), then tags it. `register-scalable-target --tags` fails on existing targets ("use TagResource"), which is why it's a two-step flow.