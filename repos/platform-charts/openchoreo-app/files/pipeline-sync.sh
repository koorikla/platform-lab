#!/usr/bin/env bash
# pipeline-sync (hub CronJob, openchoreo-app mode=types): writes DeploymentPipeline $PIPELINE's promotionPaths from the
# worker Environments in $NAMESPACE (one per fleet file, rendered by the cluster chart with the file's labels).
# - stage of an Environment = platform.lab/env, plus "-canary" when platform.lab/ring=canary (worker-addons' rule for
#   rendered/<stage>); $STAGES is the Kargo stage order.
# - every Environment of a stage promotes to every Environment of the next non-empty stage; the last stage's have no
#   targets. The first stage's Environments are the pipeline's root (what OpenChoreo's Component controller requires).
# - terminating Environments are left out: OpenChoreo blocks an Environment's deletion while a pipeline references it.
# No cluster names in git (invariant 2): new clusters appear on the next run. A failed read exits before writing.
# Environments whose stage isn't in $STAGES are skipped and fail the run (after the others are written).
# DRY_RUN=1 prints the patch instead of applying it.
set -euo pipefail
: "${NAMESPACE:?}" "${PIPELINE:?}" "${STAGES:?}" "${SELECTOR:?}"

envs=$(kubectl get environments.openchoreo.dev -n "$NAMESPACE" -l "$SELECTOR" -o json)
# -> {groups: [[stage, [names...]]...] (non-empty, in stage order), skipped: ["<name>: <why>"...]}
plan=$(jq -c --arg stages "$STAGES" '
  ($stages | split(" ") | map(select(. != ""))) as $order
  | [.items[] | {name: .metadata.name, terminating: (.metadata.deletionTimestamp != null),
      stage: ((.metadata.labels["platform.lab/env"] // "")
              + (if .metadata.labels["platform.lab/ring"] == "canary" then "-canary" else "" end))}] as $envs
  | {groups: [$order[] as $s | [$s, ([$envs[] | select(.stage == $s and (.terminating | not)) | .name] | sort)]
              | select(.[1] | length > 0)],
     skipped: ([$envs[] | select(.terminating) | "\(.name): terminating"]
               + [$envs[] | select((.terminating | not) and (.stage as $s | $order | index($s) | not))
                  | "\(.name): stage \(.stage) is not a Kargo stage (\($stages))"])}' <<<"$envs")

jq -r '.groups[] | "\(.[0]): \(.[1] | join(" "))"' <<<"$plan"
jq -r '.skipped[] | "skipped \(.)"' <<<"$plan"

patch=$(jq -c '[.groups[] | .[1]] as $g
  | {spec: {promotionPaths: [range(0; $g | length) as $i | $g[$i][]
      | {sourceEnvironmentRef: {kind: "Environment", name: .},
         targetEnvironmentRefs: [($g[$i + 1] // [])[] | {kind: "Environment", name: .}]}]}}' <<<"$plan")

if [ "${DRY_RUN:-0}" = 1 ]; then
  echo "DRY_RUN: patch deploymentpipelines.openchoreo.dev $PIPELINE -n $NAMESPACE $patch"
else
  # merge patch: replaces the whole list (no stale paths); a no-op when nothing changed
  kubectl patch deploymentpipelines.openchoreo.dev "$PIPELINE" -n "$NAMESPACE" --type merge \
    --field-manager openchoreo-pipeline-sync -p "$patch"
fi
# terminating ones are expected (cluster removal); only an unknown stage is a config error
if jq -e '[.skipped[] | select(endswith(": terminating") | not)] | length > 0' <<<"$plan" >/dev/null; then exit 1; fi
