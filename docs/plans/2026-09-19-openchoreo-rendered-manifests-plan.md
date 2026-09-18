# OpenChoreo portal + rendered manifests — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Every fleet cluster and every app automatically appears in OpenChoreo's Backstage; apps are deployed by
OpenChoreo; apps and worker addons are promoted by Kargo using the rendered manifests pattern.

**Architecture:** Kargo renders plain YAML (`helm template`) at promotion time into `rendered/<env>` branches.
Argo CD syncs those branches: worker addons to workers via argocd-agent, OpenChoreo CRs to the hub. The `cluster` chart
registers every worker as an OpenChoreo `ClusterDataPlane` + `Environment`. Per-cluster fan-out (ReleaseBindings,
identity values) is done by ApplicationSets with inline kustomize patches. Design:
`docs/plans/2026-09-19-openchoreo-rendered-manifests-design.md`.

**Tech stack:** Kargo 1.11.4, Argo CD 3.5 (argo-helm 10.9.2), argocd-agent v0.10.0, OpenChoreo 1.2.5, kgateway v2.3.1,
Gateway API v1.5.1, OpenBao chart 0.25.6, Thunder chart (`oci://ghcr.io/asgardeo/helm-charts/thunder`), ESO 2.10.0,
cert-manager v1.21.2, Helm 4, yq 4, kubeconform.

**Ground rules for the implementer**
- Read `CLAUDE.md` first. Invariants 1–8 still hold unless this plan changes them explicitly (Task 1.9 / 3.8).
- Hub context: `kubectl --context mgmt`. Worker: `make kubeconfig CLUSTER=dev1 > /tmp/dev1.kc`, then
  `kubectl --kubeconfig /tmp/dev1.kc --server https://127.0.0.1:$(docker port dev1-lb 6443/tcp | cut -d: -f2)`.
- Upstream OpenChoreo sources at tag v1.2.5 are the reference for every OpenChoreo value:
  `gh api 'repos/openchoreo/openchoreo/contents/<path>?ref=v1.2.5' --jq .content | base64 -d`.
- **Never** `kind delete cluster` (it lists the CAPD clusters mgmt/dev1 too). Keep ≥25 GB Docker disk free.
- Tests = render assertions in `hack/tests/` (run by `make test`) + the end-to-end checks listed per task.
- Commit after every task; push (Argo pulls from GitHub `main`).

---

## Phase 0 — prerequisites

### Task 0.1: Test harness for render assertions

**Files:**
- Create: `hack/tests/lib.sh`, `hack/tests/run.sh`
- Modify: `Makefile` (add `test` target)

**Step 1: Create the helper library**

```bash
# hack/tests/lib.sh — sourced by every test_*.sh. Render with helm, assert with yq.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
charts=repos/platform-charts
config=repos/platform-config
fail() { echo "FAIL: $*" >&2; exit 1; }
# assert_yq <file> <yq-expression> <expected>
assert_yq() { local got; got=$(yq eval-all "$2" "$1"); [ "$got" = "$3" ] || fail "$1: $2 = '$got', want '$3'"; }
render() { local out; out=$(mktemp); helm template "$@" > "$out"; echo "$out"; }
```

```bash
# hack/tests/run.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
rc=0
for t in test_*.sh; do if bash "$t"; then echo "ok   $t"; else echo "FAIL $t"; rc=1; fi; done
exit $rc
```

Makefile:
```make
test:            ## render assertions (hack/tests/test_*.sh)
	./hack/tests/run.sh
```
(add `test` to `.PHONY`).

**Step 2: Add a first test for existing behaviour (must pass immediately)**

```bash
# hack/tests/test_cluster_identity.sh — worker gets agent identity, hub does not
source "$(dirname "$0")/lib.sh"
w=$(render dev1 $charts/cluster -f $config/fleet/clusters/dev/dev1.yaml)
assert_yq "$w" '[select(.kind=="PushSecret")] | length' 2
h=$(render mgmt $charts/cluster -f $config/fleet/clusters/mgmt/mgmt.yaml)
assert_yq "$h" '[select(.kind=="PushSecret")] | length' 0
```

**Step 3:** `chmod +x hack/tests/*.sh && make test` → Expected: `ok   test_cluster_identity.sh`.

**Step 4: Commit** — `git add hack/tests Makefile && git commit -m "test: render assertion harness"`

### Task 0.2: Kargo git credential = repo-scoped deploy key (done by the controller, not a subagent)

Decision (user, 2026-09-19): a write-enabled **deploy key** on `koorikla/platform-lab`, created with `gh`, instead of a
PAT. The private key never touches the repo or the terminal output.

```bash
k=$(mktemp -d)/kargo && ssh-keygen -q -t ed25519 -N '' -C kargo@platform-lab -f "$k"
gh repo deploy-key add "$k.pub" -R koorikla/platform-lab --allow-write -t kargo-platform-lab
kubectl --context mgmt -n kargo-shared-resources create secret generic git-platform-lab \
  --from-literal=repoURL=git@github.com:koorikla/platform-lab.git --from-file=sshPrivateKey="$k"
kubectl --context mgmt -n kargo-shared-resources label secret git-platform-lab kargo.akuity.io/cred-type=git
rm -f "$k" "$k.pub"
```
Consequences for every Kargo object: `repoURL: git@github.com:koorikla/platform-lab.git` (credentials match by
repoURL); Argo CD keeps the HTTPS URL. A deploy key cannot open PRs → prod stages push directly (`pr: "false"`)
until a GitHub token exists; the `pr` var and PR steps stay in `render-*` for later.
The secret is imperative state (like the bootstrap): note in CLAUDE.md that `make up` on a fresh hub needs it re-run
(`hack/kargo-deploy-key.sh`, which wraps the commands above and first deletes an existing `kargo-platform-lab` key).

Verify: re-run the podinfo dev promotion after switching `repos/platform-config/kargo/podinfo/promotion-task.yaml`
`repoURL` to the SSH URL → Stage Succeeded, `git fetch && git log origin/main -1` shows the Kargo commit.

### Task 0.3: Create the rendered branches

**Files:** Create `hack/init-rendered-branches.sh`

```bash
#!/usr/bin/env bash
# Orphan branches written only by Kargo. Idempotent. Argo references them from day one.
set -euo pipefail
cd "$(dirname "$0")/.."
for b in dev-canary dev test prod; do
  git ls-remote --exit-code --heads origin "rendered/$b" >/dev/null && continue
  tmp=$(mktemp -d); git worktree add --orphan -b "rendered/$b" "$tmp" >/dev/null
  printf '# rendered/%s\nWritten only by Kargo (rendered manifests pattern). Do not edit.\n' "$b" > "$tmp/README.md"
  mkdir -p "$tmp/addons" "$tmp/apps" && touch "$tmp/addons/.keep" "$tmp/apps/.keep"
  git -C "$tmp" add -A && git -C "$tmp" commit -qm "init rendered/$b" && git -C "$tmp" push -q origin "rendered/$b"
  git worktree remove "$tmp"
done
```

Run it; verify `git ls-remote --heads origin 'rendered/*'` lists 4 branches. Commit the script.

### Task 0.4: Argo Rollouts on the management cluster

Kargo verification (AnalysisTemplates/AnalysisRuns) is executed by the Argo Rollouts controller next to Kargo.

**Files:** Create `repos/platform-charts/argo-rollouts/{Chart.yaml,values.yaml}`,
`repos/platform-config/addons/management/argo-rollouts/{addon.yaml,values.yaml}`; Test `hack/tests/test_argo_rollouts.sh`.
- Dep: `argo-rollouts` from `oci://ghcr.io/argoproj/argo-helm` (latest chart; `helm show chart` to pin).
- values: `argo-rollouts: { installCRDs: true, dashboard: { enabled: false } }` (keys: confirm with `helm show values`).
- addon.yaml: `name: argo-rollouts, chart: argo-rollouts, namespace: argo-rollouts, releaseName: argo-rollouts, chartRevision: main`.
- Test: render has `CustomResourceDefinition analysisruns.argoproj.io` and a Deployment.
- E2E: `kubectl --context mgmt get crd analysistemplates.argoproj.io`; `mgmt-argo-rollouts` Synced/Healthy;
  kargo-controller logs no longer warn about missing Rollouts CRDs.

---

## Phase 1 — rendered manifests for worker addons

### Task 1.1: `kargo-pipeline` chart — failing test first

One local chart renders the Kargo objects for **one** addon or app; ApplicationSets instantiate it per folder, so a new
addon/app gets its pipeline automatically.

**Files:**
- Create: `repos/platform-charts/kargo-pipeline/{Chart.yaml,values.yaml,templates/_helpers.tpl,templates/addon.yaml}`
- Test: `hack/tests/test_kargo_addon_pipeline.sh`

**Step 1: Write the failing test**

```bash
source "$(dirname "$0")/lib.sh"
o=$(render p $charts/kargo-pipeline --set kind=addon --set name=cert-manager --set chart=cert-manager \
      --set namespace=cert-manager --set releaseName=cert-manager)
assert_yq "$o" 'select(.kind=="Project") | .metadata.name' addon-cert-manager
assert_yq "$o" 'select(.kind=="Warehouse") | .spec.subscriptions[0].git.includePaths | join(",")' \
  'repos/platform-charts/cert-manager/,repos/platform-config/addons/workers/cert-manager/'
assert_yq "$o" '[select(.kind=="Stage")] | map(.metadata.name) | join(",")' 'dev-canary,dev,test,prod'
assert_yq "$o" 'select(.kind=="Stage" and .metadata.name=="dev") | .spec.requestedFreight[0].sources.stages[0]' dev-canary
assert_yq "$o" 'select(.kind=="Warehouse") | .spec.subscriptions[0].git.repoURL' 'git@github.com:koorikla/platform-lab.git'
```

**Step 2:** `make test` → FAIL (chart missing).

**Step 3: Implement**

`Chart.yaml`: `apiVersion: v2, name: kargo-pipeline, version: 0.1.0, type: application`,
description "Kargo Project/Warehouse/Stages for one addon or app (rendered manifests pattern)".

`values.yaml`:
```yaml
kind: addon                 # addon | app
name: ""                    # addon or app name
chart: ""                   # addon: chart folder under repos/platform-charts
namespace: ""               # addon: target namespace
releaseName: ""
image: ""                   # app: image repository (Warehouse subscription)
repoURL: git@github.com:koorikla/platform-lab.git   # Kargo uses the deploy key (Task 0.2)
stages: [dev-canary, dev, test, prod]   # order = promotion order
autoPromote: [dev-canary, dev]
```

`templates/addon.yaml` (guard with `{{- if eq .Values.kind "addon" }}`):
```yaml
{{- $p := printf "addon-%s" .Values.name }}
apiVersion: kargo.akuity.io/v1alpha1
kind: Project
metadata: { name: {{ $p }} }
---
apiVersion: v1
kind: Namespace
metadata: { name: {{ $p }}, labels: { kargo.akuity.io/project: "true" } }
---
apiVersion: kargo.akuity.io/v1alpha1
kind: ProjectConfig
metadata: { name: {{ $p }}, namespace: {{ $p }} }
spec:
  promotionPolicies:
  {{- range .Values.autoPromote }}
    - stageSelector: { name: {{ . }} }
      autoPromotionEnabled: true
  {{- end }}
---
apiVersion: kargo.akuity.io/v1alpha1
kind: Warehouse
metadata: { name: {{ .Values.name }}, namespace: {{ $p }} }
spec:
  subscriptions:
    - git:
        repoURL: {{ .Values.repoURL }}
        branch: main
        commitSelectionStrategy: NewestFromBranch
        includePaths:   # freight = a commit touching the chart or its fleet/env config
          - repos/platform-charts/{{ .Values.chart }}/
          - repos/platform-config/addons/workers/{{ .Values.name }}/
{{- range $i, $s := .Values.stages }}
---
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata: { name: {{ $s }}, namespace: {{ $p }} }
spec:
  requestedFreight:
    - origin: { kind: Warehouse, name: {{ $.Values.name }} }
      sources:
        {{- if eq $i 0 }}
        direct: true
        {{- else }}
        stages: [{{ index $.Values.stages (sub $i 1) }}]
        {{- end }}
  promotionTemplate:
    spec:
      steps:
        - task: { name: render-addon, kind: ClusterPromotionTask }
          vars:
            - { name: addon, value: {{ $.Values.name }} }
            - { name: chart, value: {{ $.Values.chart }} }
            - { name: namespace, value: {{ $.Values.namespace }} }
            - { name: releaseName, value: {{ $.Values.releaseName }} }
            - { name: env, value: {{ splitList "-" $s | first }} }      # dev-canary renders with dev values
            - { name: branch, value: {{ $s }} }
            - { name: pr, value: "false" }   # deploy key can't open PRs; flip to (eq $s "prod") with a token
{{- end }}
```

**Step 4:** `make test` → PASS. **Step 5:** `make lint` still OK (add `--set kind=addon,name=x,chart=x,namespace=x,releaseName=x`
to the lint loop's `helm lint` for this chart, or give values.yaml non-empty lint defaults). Commit.

### Task 1.2: `render-addon` ClusterPromotionTask

**Files:**
- Create: `repos/platform-config/kargo/shared/render-addon.yaml`, `repos/platform-config/kargo/shared/kustomization.rendered.yaml`
- Modify: `repos/platform-config/argocd/apps.yaml` (`kargo-pipelines` app already syncs `repos/platform-config/kargo`
  recursively; ClusterPromotionTask is cluster-scoped, so nothing else is needed)

`kustomization.rendered.yaml` (copied next to every rendered manifest, so Argo can apply inline kustomize patches):
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: [manifests.yaml]
```

`render-addon.yaml`:
```yaml
apiVersion: kargo.akuity.io/v1alpha1
kind: ClusterPromotionTask
metadata: { name: render-addon }
spec:
  vars:
    - { name: repoURL, value: "git@github.com:koorikla/platform-lab.git" }
    - name: addon
    - name: chart
    - name: namespace
    - name: releaseName
    - name: env
    - name: branch
    - { name: pr, value: "false" }
  steps:
    - uses: git-clone
      config:
        repoURL: ${{ vars.repoURL }}
        checkout:
          - { commit: "${{ commitFrom(vars.repoURL).ID }}", path: ./src }
          - { branch: "rendered/${{ vars.branch }}", create: true, path: ./out }
    - uses: helm-template
      config:
        path: ./src/repos/platform-charts/${{ vars.chart }}
        releaseName: ${{ vars.releaseName }}
        namespace: ${{ vars.namespace }}
        buildDependencies: true
        includeCRDs: true
        kubeVersion: "1.34.11"
        ignoreMissingValueFiles: true
        valuesFiles:
          - ./src/repos/platform-config/addons/workers/${{ vars.addon }}/values.yaml
          - ./src/repos/platform-config/addons/workers/${{ vars.addon }}/envs/${{ vars.env }}.values.yaml
        outPath: ./out/addons/${{ vars.addon }}/manifests.yaml
    - uses: copy
      config:
        inPath: ./src/repos/platform-config/kargo/shared/kustomization.rendered.yaml
        outPath: ./out/addons/${{ vars.addon }}/kustomization.yaml
    - uses: git-commit
      as: commit
      config:
        path: ./out
        message: "render(${{ vars.addon }}): ${{ vars.branch }} <- ${{ commitFrom(vars.repoURL).ID }}"
    - uses: git-push
      if: ${{ vars.pr != "true" }}
      config: { path: ./out }
    - uses: git-push
      as: push
      if: ${{ vars.pr == "true" }}
      config: { path: ./out, generateTargetBranch: true }
    - uses: git-open-pr
      as: open-pr
      if: ${{ vars.pr == "true" }}
      config:
        repoURL: ${{ vars.repoURL }}
        sourceBranch: ${{ outputs.push.branch }}
        targetBranch: rendered/${{ vars.branch }}
        title: "render(${{ vars.addon }}): prod"
    - uses: git-wait-for-pr
      if: ${{ vars.pr == "true" }}
      config:
        repoURL: ${{ vars.repoURL }}
        prNumber: ${{ outputs['open-pr'].pr.id }}
```

**Verify schema before committing:** `kubeconform -strict -schema-location default -schema-location
'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'`
on the file, or extract the ClusterPromotionTask CRD from the vendored kargo chart and validate against it.
Check step output field names (`outputs.push.branch`, `outputs['open-pr'].pr.id`) against
`gh api 'repos/akuity/kargo/contents/docs/docs/50-user-guide/60-reference-docs/30-promotion-steps?ref=v1.11.4'`.
Commit.

### Task 1.3: ApplicationSet that creates addon pipelines

**Files:** Create `repos/platform-config/argocd/appset-kargo-pipelines.yaml`

```yaml
# One Kargo pipeline per worker addon folder (and, in Phase 3, per app). addon.yaml.disabled => no pipeline.
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata: { name: kargo-addon-pipelines, namespace: argocd }
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - git:
        repoURL: https://github.com/koorikla/platform-lab.git
        revision: main
        files: [{ path: repos/platform-config/addons/workers/*/addon.yaml }]
  template:
    metadata: { name: 'kargo-addon-{{ .addon.name }}' }
    spec:
      project: platform-mgmt
      source:
        repoURL: https://github.com/koorikla/platform-lab.git
        targetRevision: main
        path: repos/platform-charts/kargo-pipeline
        helm:
          valuesObject:
            kind: addon
            name: '{{ .addon.name }}'
            chart: '{{ .addon.chart }}'
            namespace: '{{ .addon.namespace }}'
            releaseName: '{{ .addon.releaseName }}'
      destination: { name: in-cluster, namespace: kargo }
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        syncOptions: [ServerSideApply=true]
```

**Verify (E2E):** push; `kubectl --context mgmt get projects.kargo.akuity.io` shows `addon-cert-manager`,
`addon-external-secrets`; `kubectl --context mgmt -n addon-cert-manager get freight` shows ≥1 freight within 5 min;
`dev-canary` and `dev` auto-promote; `git fetch origin && git show origin/rendered/dev:addons/cert-manager/kustomization.yaml`
exists. Commit.

### Task 1.4: Ring label in fleet files

**Files:** Modify `repos/platform-charts/cluster/templates/_helpers.tpl`, `repos/platform-charts/cluster/values.yaml`;
Test: `hack/tests/test_cluster_ring.sh`

**Step 1: failing test**
```bash
source "$(dirname "$0")/lib.sh"
o=$(render dev2 $charts/cluster -f $config/fleet/clusters/dev/dev1.yaml --set ring=canary)
assert_yq "$o" 'select(.kind=="Cluster") | .metadata.labels["platform.lab/ring"]' canary
assert_yq "$o" 'select(.kind=="ExternalSecret") | .spec.target.template.metadata.labels["platform.lab/ring"]' canary
o=$(render dev1 $charts/cluster -f $config/fleet/clusters/dev/dev1.yaml)
assert_yq "$o" 'select(.kind=="Cluster") | .metadata.labels["platform.lab/ring"]' stable
```
**Step 3:** values.yaml: `ring: stable   # stable | canary — canary clusters follow rendered/<env>-canary`;
helper: add `platform.lab/ring: {{ .Values.ring }}`. **Step 4:** PASS. Commit.

### Task 1.5: worker-addons ApplicationSet → rendered branches

**Files:** Modify `repos/platform-config/argocd/appset-worker-addons.yaml` (full rewrite); Test: manual E2E.

```yaml
# addon x worker cluster. Source = plain YAML rendered by Kargo into rendered/<branch>/addons/<addon>, where
# branch = <env> or <env>-canary (fleet file `ring: canary`). addon.yaml on main is the on/off switch.
# Per-cluster rendering is identity only: optional addon.yaml `clusterIdentity` → env var CLUSTER_NAME patch.
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata: { name: worker-addons, namespace: argocd }
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  syncPolicy: { preserveResourcesOnDeletion: true }
  generators:
    - matrix:
        generators:
          - git:
              repoURL: https://github.com/koorikla/platform-lab.git
              revision: main
              files: [{ path: repos/platform-config/addons/workers/*/addon.yaml }]
          - clusters:
              selector: { matchLabels: { platform.lab/role: worker } }
              values:
                env: '{{ index .metadata.labels "platform.lab/env" }}'
                branch: '{{ index .metadata.labels "platform.lab/env" }}{{ if eq (index .metadata.labels "platform.lab/ring") "canary" }}-canary{{ end }}'
  template:
    metadata:
      name: '{{ .addon.name }}-{{ .name }}'
      labels:
        argocd-agent: "true"
        platform.lab/addon: '{{ .addon.name }}'
        platform.lab/env: '{{ .values.env }}'
        platform.lab/cluster: '{{ .name }}'
    spec:
      project: platform-workers
      source:
        repoURL: https://github.com/koorikla/platform-lab.git
        targetRevision: 'rendered/{{ .values.branch }}'
        path: 'addons/{{ .addon.name }}'
      destination: { name: '{{ .name }}', namespace: '{{ .addon.namespace }}' }
      syncPolicy:
        automated: { prune: true, selfHeal: true }
        retry: { limit: 20, backoff: { duration: 15s, factor: 2, maxDuration: 5m } }
        syncOptions: [CreateNamespace=true, ServerSideApply=true, SkipDryRunOnMissingResource=true]
  templatePatch: |
    {{- if hasKey .addon "clusterIdentity" }}
    spec:
      source:
        kustomize:
          patches:
            - target: { kind: Deployment, name: {{ .addon.clusterIdentity.deployment }} }
              patch: |-
                - op: add
                  path: /spec/template/spec/containers/0/env/-
                  value: { name: CLUSTER_NAME, value: {{ .name }} }
    {{- end }}
```

Notes: the cluster generator's `values` are templated from cluster-secret labels; the `platform.lab/ring` label comes
from Task 1.4 (older secrets without it: `index` returns "" → stable). `containers/0/env/-` requires an existing `env`
list; if the target container has none, change `op`/`path` in the task that introduces the first identity patch (3.x).

**Verify (E2E):** push; after Task 1.3's first promotions `cert-manager-dev1` and `external-secrets-dev1` stay
Synced/Healthy with `spec.source.targetRevision=rendered/dev`; `kubectl --context mgmt -n argocd get app
cert-manager-dev1 -o jsonpath='{.status.sync.revision}'` equals `git rev-parse origin/rendered/dev`. On dev1 nothing is
recreated (same manifests; SSA adopts). Commit.

### Task 1.6: Remove rollout pins and per-cluster values

**Files:** Delete `repos/platform-config/addons/workers/*/envs/{dev,test,prod}.yaml`, `repos/platform-config/addons/workers/*/clusters/`;
keep `envs/<env>.values.yaml`. Update `hack/lint.sh` worker-addon loop (no rollout files). `make lint && make test`. Commit.

### Task 1.7: Canary ring end to end (dev2)

**Step 1:** Rename `fleet/clusters/dev/dev2.yaml.disabled` → `dev2.yaml`, add `ring: canary`. Push.
**Step 2:** Wait: `kubectl --context mgmt -n fleet get cluster dev2` Available (~5 min).
**Step 3:** Bump cert-manager fleet values (e.g. `cert-manager: { replicaCount: 1, podDisruptionBudget: { enabled: false } }`
in `addons/workers/cert-manager/values.yaml`), push. Expected: new freight; `dev-canary` auto-promotes →
`cert-manager-dev2` syncs a new revision of `rendered/dev-canary`; then `dev` auto-promotes → dev1.
Set `autoPromote: [dev-canary]` in values.yaml of kargo-pipeline if you want a manual gate between canary and dev.
**Step 4:** Record the result in CLAUDE.md verification status. Commit.

### Task 1.8: Promote to test/prod manually once

`kargo promote --project addon-cert-manager --stage test` (CLI logged in via `kargo login http://localhost:8081
--admin` after `make ui`). prod: expect an open PR against `rendered/prod` on GitHub; merge it; Stage succeeds.
No test/prod clusters exist yet → nothing deploys; the branches just advance. Commit notes.

### Task 1.9: Docs + invariants

Update `CLAUDE.md` (invariant 5 → "Kargo writes only `rendered/*` branches; main holds no versions for promoted
things"; addon convention: `addons/workers/<name>/{addon.yaml,values.yaml,envs/<env>.values.yaml}`; rings) and README
"How targeting works" table (rings replace pins). Commit + push.

---

## Phase 2 — OpenChoreo on hub and workers; clusters appear in Backstage

Upstream reference for every value: `install/k3d/common/*` and `install/k3d/multi-cluster/*` at tag v1.2.5.

### Task 2.1: Gateway API CRDs chart

**Files:** Create `repos/platform-charts/gateway-api-crds/{Chart.yaml,values.yaml,templates/crds.yaml,files/standard-install-v1.5.1.yaml}`,
`repos/platform-config/addons/management/gateway-api-crds/{addon.yaml,values.yaml}`,
`repos/platform-config/addons/workers/gateway-api-crds/{addon.yaml,values.yaml,envs/.gitkeep}`.

- Vendor: `curl -fsSL https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml > files/standard-install-v1.5.1.yaml`.
- `templates/crds.yaml`: `{{ .Files.Get "files/standard-install-v1.5.1.yaml" }}` (templates, not `crds/`, so Argo and
  Kargo upgrade them).
- addon.yaml (both scopes): `name: gateway-api-crds, chart: gateway-api-crds, namespace: kube-system, releaseName: gateway-api-crds`.
- Test `hack/tests/test_gateway_api_crds.sh`: rendered doc count of `kind: CustomResourceDefinition` ≥ 5 and includes
  `gateways.gateway.networking.k8s.io`.
- Mgmt addons appset: add `ServerSideApply=true` already present (CRDs are large). Commit.

### Task 2.2: Enable kgateway (hub + workers)

Rename `addon.yaml.disabled` → `addon.yaml` in `addons/management/kgateway` and `addons/workers/kgateway`; remove the
worker's rollout pins (`envs/*.yaml`, Task 1.6 rule). Hub namespace stays `openchoreo-control-plane` per upstream?
→ No: use `kgateway-system` on both (upstream uses `--namespace openchoreo-control-plane` only for convenience; check
`install/k3d/k3d-prerequisites.sh` at v1.2.5 and follow it exactly). Verify `kubectl --context mgmt get gatewayclass kgateway`
Accepted. Commit.

### Task 2.3: OpenBao + ClusterSecretStore `default` (hub)

**Files:** Create `repos/platform-charts/openbao/{Chart.yaml,values.yaml,templates/clustersecretstore.yaml}`,
`repos/platform-config/addons/management/openbao/{addon.yaml,values.yaml}` (namespace `openbao`, releaseName `openbao`).

- Chart dep: `openbao` 0.25.6 from `oci://ghcr.io/openbao/charts`.
- `values.yaml`: nest upstream `install/k3d/common/values-openbao.yaml` (v1.2.5) under `openbao:` verbatim (dev mode,
  root token `root`, postStart policies/roles/KV seeds — LAB ONLY comment).
- `templates/clustersecretstore.yaml`: the ServiceAccount `external-secrets-openbao` + `ClusterSecretStore default`
  exactly as in the v1.2.x guide (vault provider, `http://openbao.openbao.svc:8200`, path `secret`, v2, kubernetes auth
  role `openchoreo-secret-writer-role`).
- Test: render contains `ClusterSecretStore/default`. E2E: `kubectl --context mgmt get clustersecretstore default`
  Ready=True. Commit.

### Task 2.4: Thunder IdP (hub)

**Files:** `repos/platform-charts/thunder/{Chart.yaml,values.yaml}`, `repos/platform-config/addons/management/thunder/{addon.yaml,values.yaml}`.
- Dep: `thunder` from `oci://ghcr.io/asgardeo/helm-charts` — version: the one `install/k3d/k3d-install.sh` at v1.2.5
  resolves (run `helm show chart oci://ghcr.io/asgardeo/helm-charts/thunder` and pick the version whose appVersion the
  v1.2.x docs name; record it in Chart.yaml with a comment).
- `values.yaml`: upstream `install/k3d/common/values-thunder.yaml` (v1.2.5) nested under `thunder:`.
- Its setup job is a **pre-install helm hook**: Argo runs hooks as sync hooks — verify it runs once and the admin
  secret `thunder-admin-credentials` exists. Commit.

### Task 2.5: Hostnames, DNS and UI access for `*.openchoreo.localhost`

- Hub CoreDNS rewrite so pods resolve `*.openchoreo.localhost` to the kgateway gateway service: port upstream
  `install/k3d/common/coredns-custom.yaml` as a mgmt addon manifest (k3s reads ConfigMap `kube-system/coredns-custom`).
  Put it in the `openchoreo-control-plane` umbrella chart templates.
- Browser: `make ui` gains `kubectl -n <gateway ns> port-forward svc/<gateway-svc> 8080:<port>`; move Argo CD to 8090
  and Kargo to 8091 (issuer URLs contain `:8080`, same as upstream). Update README/Makefile/bootstrap echo lines.

### Task 2.6: OpenChoreo control plane (hub)

**Files:** Modify `repos/platform-charts/openchoreo-control-plane/values.yaml`; rename
`addons/management/openchoreo-control-plane/addon.yaml.disabled` → `addon.yaml`; Modify `repos/platform-config/fleet/base/hub-lb.yaml`.

- Values = upstream `install/k3d/multi-cluster/values-cp.yaml` (v1.2.5) under `openchoreo-control-plane:`, plus:
  ```yaml
  clusterGateway:
    service: { type: NodePort, port: 8443, nodePort: 30843 }
    tlsRoute: { enabled: false }          # workers dial the NodePort through mgmt-lb, not a hostname route
    tls:
      dnsNames: [cluster-gateway.openchoreo-control-plane.svc, cluster-gateway.openchoreo-control-plane.svc.cluster.local, mgmt-lb]
  ```
  (confirm key names with `helm show values oci://ghcr.io/openchoreo/helm-charts/openchoreo-control-plane --version 1.2.5`).
- hub-lb.yaml: add frontend/backend `:30843` exactly like the `argocd-agent-principal` pair.
- Upstream types: create `repos/platform-charts/openchoreo-app/files/types/*.yaml` from `samples/getting-started/all.yaml`
  (v1.2.5): the 4 `ClusterComponentType`s + `ClusterProjectType` + DeploymentPipeline/Project are **not** copied here
  (Phase 3). A mgmt addon `openchoreo-types` renders `openchoreo-app` with `mode: types` (Task 3.1 creates the chart; until
  then vendor the files and apply via that addon in 3.1).
- E2E: all control-plane pods Running; `kubectl --context mgmt -n openchoreo-control-plane get svc cluster-gateway-external`
  NodePort 30843; Backstage reachable at http://openchoreo.localhost:8080 after `make ui`; login with Thunder admin. Commit.

### Task 2.7: `cluster` chart registers workers in OpenChoreo — failing test first

**Files:** Create `repos/platform-charts/cluster/templates/openchoreo.yaml` (replaces `openchoreo-dataplane.yaml`, delete it);
Modify `repos/platform-charts/cluster/values.yaml`; Test `hack/tests/test_cluster_openchoreo.sh`.

**Step 1: failing test**
```bash
source "$(dirname "$0")/lib.sh"
o=$(render dev1 $charts/cluster -f $config/fleet/clusters/dev/dev1.yaml --set openchoreo.enabled=true)
assert_yq "$o" 'select(.kind=="ClusterDataPlane") | .spec.planeID' dev1
assert_yq "$o" 'select(.kind=="ClusterDataPlane") | .spec.clusterAgent.clientCA.secretKeyRef.name' dev1-oc-agent-ca
assert_yq "$o" 'select(.kind=="Environment") | .spec.dataPlaneRef.name' dev1
assert_yq "$o" 'select(.kind=="Environment") | .spec.isProduction' false
assert_yq "$o" '[select(.kind=="Certificate" and .spec.isCA==true)] | length' 1
assert_yq "$o" '[select(.kind=="PushSecret")] | length' 3      # agent client tls, agent ca, + oc agent tls
p=$(render prod1 $charts/cluster -f $config/fleet/clusters/prod/prod1.yaml.disabled --set openchoreo.enabled=true)
assert_yq "$p" 'select(.kind=="Environment") | .spec.isProduction' true
h=$(render mgmt $charts/cluster -f $config/fleet/clusters/mgmt/mgmt.yaml --set openchoreo.enabled=true)
assert_yq "$h" '[select(.kind=="ClusterDataPlane")] | length' 0
```

**Step 3: implement** (`{{- if and .Values.openchoreo.enabled (eq .Values.role "worker") }}`):
```yaml
{{- $n := .Values.name }}
# Per-cluster CA: OpenChoreo's gateway trusts planeID from the URL, so each plane needs its own CA (see design doc).
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: {{ $n }}-oc-agent-ca, namespace: {{ .Values.fleetNamespace }} }
spec:
  isCA: true
  commonName: {{ $n }}-oc-agent-ca
  secretName: {{ $n }}-oc-agent-ca
  duration: 87600h
  privateKey: { algorithm: ECDSA, size: 256 }
  issuerRef: { name: openchoreo-agent-selfsigned, kind: ClusterIssuer }
---
apiVersion: cert-manager.io/v1
kind: Issuer
metadata: { name: {{ $n }}-oc-agent-ca, namespace: {{ .Values.fleetNamespace }} }
spec: { ca: { secretName: {{ $n }}-oc-agent-ca } }
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: {{ $n }}-oc-agent-tls, namespace: {{ .Values.fleetNamespace }} }
spec:
  secretName: {{ $n }}-oc-agent-tls
  commonName: {{ $n }}
  usages: [client auth]
  privateKey: { algorithm: ECDSA, size: 256 }
  issuerRef: { name: {{ $n }}-oc-agent-ca, kind: Issuer }
---
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterDataPlane
metadata:
  name: {{ $n }}
  labels: {{- include "cluster.labels" . | nindent 4 }}
spec:
  planeID: {{ $n }}
  clusterAgent:
    clientCA:
      secretKeyRef: { name: {{ $n }}-oc-agent-ca, namespace: {{ .Values.fleetNamespace }}, key: ca.crt }
  secretStoreRef: { name: default }
  gateway:
    ingress:
      external:
        name: gateway-default
        namespace: openchoreo-data-plane
        http: { host: {{ printf "%s.apps.openchoreo.localhost" $n | quote }}, listenerName: http, port: 80 }
---
apiVersion: openchoreo.dev/v1alpha1
kind: Environment
metadata:
  name: {{ $n }}
  namespace: {{ .Values.openchoreo.namespace }}
  labels: {{- include "cluster.labels" . | nindent 4 }}
  annotations: { openchoreo.dev/display-name: {{ printf "%s / %s" .Values.env $n | quote }} }
spec:
  dataPlaneRef: { kind: ClusterDataPlane, name: {{ $n }} }
  isProduction: {{ eq .Values.env "prod" }}
---
# Agent client cert → worker (namespace created by the openchoreo-data-plane addon's CreateNamespace).
apiVersion: external-secrets.io/v1alpha1
kind: PushSecret
metadata: { name: {{ $n }}-oc-agent-tls, namespace: {{ .Values.fleetNamespace }} }
spec:
  refreshInterval: 5m
  updatePolicy: Replace
  deletionPolicy: Delete
  secretStoreRefs: [{ kind: ClusterSecretStore, name: fleet-{{ $n }}-openchoreo }]
  selector: { secret: { name: {{ $n }}-oc-agent-tls } }
  data:
    - match: { remoteRef: { remoteKey: cluster-agent-tls } }
---
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata: { name: fleet-{{ $n }}-openchoreo }
spec:
  provider:
    kubernetes:
      remoteNamespace: openchoreo-data-plane
      authRef: { name: {{ $n }}-kubeconfig, namespace: {{ .Values.fleetNamespace }}, key: value }
```
Plus one `ClusterIssuer openchoreo-agent-selfsigned` (selfSigned) in the **openchoreo-control-plane umbrella** chart
(shared, not per cluster). values.yaml: `openchoreo: { enabled: false, namespace: default }` — then set
`openchoreo.enabled: true` in the chart default once Phase 2 is live (single switch for the fleet). Note: the
Environment namespace must carry `openchoreo.dev/control-plane: "true"`; add that label to `default` via the
control-plane umbrella (Namespace object with SSA) or pick a dedicated namespace (`openchoreo`) and use it everywhere.

**Step 4:** PASS. **Step 5:** push; E2E: `kubectl --context mgmt get clusterdataplanes,environments -A` lists dev1,
dev2; **Backstage catalog shows Dataplanes dev1/dev2 and Environments `dev / dev1`, `dev / dev2`** (connected=false
until 2.8). Commit.

### Task 2.8: Data plane on workers (via rendered addons)

**Files:** Modify `repos/platform-charts/openchoreo-data-plane/values.yaml`,
`repos/platform-config/addons/workers/openchoreo-data-plane/{addon.yaml(.disabled→.yaml),values.yaml}`; delete its `envs/*.yaml` pins.

- addon.yaml gains identity: `clusterIdentity: { deployment: cluster-agent-dataplane }` (confirm the Deployment name in
  `helm template` output).
- values (fleet): upstream `install/k3d/multi-cluster/values-dp.yaml` (v1.2.5) under `openchoreo-data-plane:` plus
  ```yaml
  clusterAgent:
    planeID: "$(CLUSTER_NAME)"        # expanded by kubelet from the env var the appset injects (identity patch)
    serverUrl: wss://mgmt-lb:30843/ws
    tls:
      generateCerts: true             # chart always renders a Certificate; point it at a throwaway secret
      secretName: cluster-agent-selfsigned-unused
      clientSecretName: cluster-agent-tls   # pushed from the hub (Task 2.7)
      serverCAConfigMap: cluster-gateway-ca
  ```
  and a template in the umbrella rendering ConfigMap `cluster-gateway-ca` from `.Values.hubGatewayCA` (the hub
  cluster-gateway CA **certificate**, public). Fill `hubGatewayCA` once:
  `kubectl --context mgmt -n openchoreo-control-plane get secret <cluster-gateway CA secret> -o jsonpath='{.data.ca\.crt}' | base64 -d`
  → paste into `addons/workers/openchoreo-data-plane/values.yaml`. (Long-lived CA; document the rotation step.)
- Confirm `--plane-id` is passed via args so `$(CLUSTER_NAME)` expansion applies (it's args in
  `templates/cluster-agent/deployment.yaml:63`); if the container has no `env:` list, switch the appset patch to
  `op: add, path: /spec/template/spec/containers/0/env, value: [ {name: CLUSTER_NAME, value: ...} ]`.
- Test `hack/tests/test_openchoreo_dp.sh`: rendered Deployment args contain `--plane-id=$(CLUSTER_NAME)`; ConfigMap
  `cluster-gateway-ca` present.
- E2E: Kargo promotes `addon-openchoreo-data-plane` → dev-canary (dev2) → dev (dev1); on each worker the
  cluster-agent logs "connected"; `kubectl --context mgmt get clusterdataplane dev1 -o jsonpath='{.status.agentConnection.connected}'`
  = true; Backstage shows both planes connected. Commit.

---

## Phase 3 — apps deployed by OpenChoreo, promoted by Kargo (rendered)

### Task 3.1: `openchoreo-app` chart — failing tests first

**Files:** Create `repos/platform-charts/openchoreo-app/{Chart.yaml,values.yaml,files/types/*.yaml,templates/{_helpers.tpl,types.yaml,component.yaml,release.yaml,binding.yaml}}`;
Test `hack/tests/test_openchoreo_app.sh`.

Modes (`.Values.mode`): `types` (hub addon: ClusterComponentTypes/ClusterProjectType from `files/types`),
`component` (hub, from main: Project + Component), `release` (Kargo: Workload [dev only] + ComponentRelease),
`binding` (Kargo: ReleaseBinding template).

**Step 1: failing test**
```bash
source "$(dirname "$0")/lib.sh"
a=repos/apps/podinfo
r=$(render podinfo $charts/openchoreo-app -f $a/app.yaml -f $a/envs/dev/values.yaml --set mode=release \
      --set env=dev --set image.tag=6.15.0)
name=$(yq 'select(.kind=="ComponentRelease") | .metadata.name' "$r")
[[ "$name" =~ ^podinfo-dev-6-15-0-[0-9a-f]{8}$ ]] || fail "release name $name"
assert_yq "$r" 'select(.kind=="ComponentRelease") | .spec.workload.container.image' ghcr.io/stefanprodan/podinfo:6.15.0
assert_yq "$r" 'select(.kind=="ComponentRelease") | .spec.componentType.name' deployment/service
r2=$(render podinfo $charts/openchoreo-app -f $a/app.yaml -f $a/envs/dev/values.yaml --set mode=release --set env=dev --set image.tag=6.16.0)
[ "$(yq 'select(.kind=="ComponentRelease") | .metadata.name' "$r2")" != "$name" ] || fail "tag change must change release name"
b=$(render podinfo $charts/openchoreo-app -f $a/app.yaml -f $a/envs/dev/values.yaml --set mode=binding --set env=dev --set image.tag=6.15.0)
assert_yq "$b" 'select(.kind=="ReleaseBinding") | .spec.releaseName' "$name"
c=$(render podinfo $charts/openchoreo-app -f $a/app.yaml --set mode=component)
assert_yq "$c" 'select(.kind=="Component") | .spec.autoDeploy' false
t=$(render types $charts/openchoreo-app --set mode=types)
assert_yq "$t" '[select(.kind=="ClusterComponentType")] | length' 4
```

**Step 3: implement**
- `files/types/`: split upstream `samples/getting-started/all.yaml` (v1.2.5) — keep the 4 `ClusterComponentType`s and
  the `ClusterProjectType`; header comment with source + tag.
- `_helpers.tpl`:
  ```
  {{- define "oc.componentType" -}}   {{/* frozen spec for .Values.componentType, e.g. deployment/service */}}
  {{- $want := .Values.componentType -}}
  {{- range $f, $_ := .Files.Glob "files/types/*.yaml" }}{{- $d := $.Files.Get $f | fromYaml }}
  {{- if and (eq $d.kind "ClusterComponentType") (eq (printf "%s/%s" $d.spec.workloadType $d.metadata.name) $want) }}{{ toYaml $d.spec }}{{ end }}
  {{- end }}{{- end }}
  {{- define "oc.releaseName" -}}
  {{- $frozen := dict "type" (include "oc.componentType" . ) "workload" (include "oc.workload" .) "traits" .Values.traits -}}
  {{- printf "%s-%s-%s-%s" .Values.name .Values.env (.Values.image.tag | replace "." "-") (toJson $frozen | sha256sum | trunc 8) -}}
  {{- end }}
  ```
  (verify the exact field that holds the `deployment` workload type in ClusterComponentType at v1.2.5 and adjust.)
- `release.yaml` → `ComponentRelease` with `spec.owner {projectName, componentName}`, `spec.componentType {kind:
  ClusterComponentType, name, spec: <frozen>}`, `spec.workload` (container image `repository:tag`, endpoints, env from
  app.yaml + env values), `traits: []`. For `env == dev` also render `Workload <name>-workload` (latest).
- `binding.yaml` → `ReleaseBinding` name `<app>` (suffix added by the appset), `spec.environment: __CLUSTER__`
  (replaced by the appset), `spec.releaseName: {{ include "oc.releaseName" . }}`, owner.
- `component.yaml` → `Project <project>` (once per app is fine if identical across apps? No: render Project only when
  `.Values.createProject`; the `lab` project comes from the `openchoreo-types` addon values instead) + `Component`.
- `values.yaml` defaults: `mode: component, name: "", project: lab, componentType: deployment/service, image: {repository: "", tag: ""}, endpoints: {}, env: [], traits: [], namespace: default`.

**Step 4:** PASS; `make lint`. Commit.

### Task 3.2: App definition for podinfo

**Files:** Create `repos/apps/podinfo/app.yaml`; Modify `repos/apps/podinfo/envs/*/values.yaml` (drop `image.tag`,
keep only env config); Delete `repos/apps/podinfo/chart/` and `repos/apps/podinfo/clusters/`.
```yaml
# repos/apps/podinfo/app.yaml — what the app is. No version: Kargo supplies image.tag at render time.
name: podinfo
project: lab
componentType: deployment/service
image: { repository: ghcr.io/stefanprodan/podinfo }
endpoints:
  http: { type: HTTP, port: 9898, visibility: [external] }
```
envs/dev/values.yaml: `env: [{ key: PODINFO_UI_MESSAGE, value: "podinfo @ dev" }]` (map to the Workload env schema
at v1.2.5). Run Task 3.1 tests. Commit.

### Task 3.3: `render-app` ClusterPromotionTask + app pipelines

- `repos/platform-config/kargo/shared/render-app.yaml`: same shape as `render-addon` but two `helm-template` steps into
  `./out/apps/<app>/release/manifests.yaml` (`mode=release`) and `./out/apps/<app>/binding/manifests.yaml`
  (`mode=binding`), each with `setValues: [{key: env, value: ${{ vars.env }}}, {key: image.tag, value: ${{ imageFrom(vars.image).Tag }}}]`
  and valuesFiles `repos/apps/<app>/app.yaml`, `repos/apps/<app>/envs/<env>/values.yaml`; `copy` the kustomization into both dirs.
  Before `helm-template`, `git-clear` is **not** used (other apps share the branch) — instead delete the app's old
  `release/manifests.yaml`? Not needed: the file is overwritten.
- `kargo-pipeline` chart: add `templates/app.yaml` (`kind: app`): Project `app-<name>`, Warehouse on the image
  (`image: {repoURL, imageSelectionStrategy: SemVer, constraint, discoveryLimit: 5}`) **plus** a git subscription on
  `repos/apps/<name>/` and `repos/platform-charts/openchoreo-app/` (config changes are promotable too), Stages
  `dev → test → prod` (no canary for apps unless a ring cluster exists — reuse the same `stages` value), task
  `render-app`. Extend `hack/tests/test_kargo_addon_pipeline.sh` with an app case first (TDD).
- `appset-kargo-pipelines.yaml`: second ApplicationSet `kargo-app-pipelines` over `repos/apps/*/app.yaml`.
- Delete `repos/platform-config/kargo/podinfo/` (replaced). Commit.

### Task 3.4: Hub ApplicationSets for OpenChoreo apps

**Files:** Create `repos/platform-config/argocd/appset-openchoreo-apps.yaml`; Delete `appset-workloads.yaml`;
Modify `projects.yaml` (drop `workloads` project or keep for later; remove its `argocd-agent` label use).

```yaml
# Project + Component from main (intent), per app.
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata: { name: openchoreo-components, namespace: argocd }
spec:
  goTemplate: true
  generators:
    - git: { repoURL: https://github.com/koorikla/platform-lab.git, revision: main, files: [{ path: repos/apps/*/app.yaml }] }
  template:
    metadata: { name: 'oc-component-{{ .name }}' }
    spec:
      project: platform-mgmt
      sources:
        - repoURL: https://github.com/koorikla/platform-lab.git
          targetRevision: main
          path: repos/platform-charts/openchoreo-app
          helm: { valuesObject: { mode: component }, valueFiles: ['$values/{{ .path.path }}/app.yaml'] }
        - { repoURL: https://github.com/koorikla/platform-lab.git, targetRevision: main, ref: values }
      destination: { name: in-cluster, namespace: default }
      syncPolicy: { automated: { prune: true, selfHeal: true }, syncOptions: [ServerSideApply=true] }
---
# Releases per app x env branch (rendered by Kargo).
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata: { name: openchoreo-releases, namespace: argocd }
spec:
  goTemplate: true
  generators:
    - matrix:
        generators:
          - git: { repoURL: https://github.com/koorikla/platform-lab.git, revision: main, files: [{ path: repos/apps/*/app.yaml }] }
          - list: { elements: [{ branch: dev }, { branch: test }, { branch: prod }] }
  template:
    metadata: { name: 'oc-release-{{ .name }}-{{ .branch }}' }
    spec:
      project: platform-mgmt
      source: { repoURL: https://github.com/koorikla/platform-lab.git, targetRevision: 'rendered/{{ .branch }}', path: 'apps/{{ .name }}/release' }
      destination: { name: in-cluster, namespace: default }
      syncPolicy: { automated: { prune: false, selfHeal: true } }   # releases are immutable history; never prune
---
# One ReleaseBinding per app x worker cluster, stamped from the env's rendered binding template.
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata: { name: openchoreo-bindings, namespace: argocd }
spec:
  goTemplate: true
  generators:
    - matrix:
        generators:
          - git: { repoURL: https://github.com/koorikla/platform-lab.git, revision: main, files: [{ path: repos/apps/*/app.yaml }] }
          - clusters:
              selector: { matchLabels: { platform.lab/role: worker } }
              values:
                branch: '{{ index .metadata.labels "platform.lab/env" }}{{ if eq (index .metadata.labels "platform.lab/ring") "canary" }}-canary{{ end }}'
  template:
    metadata: { name: 'oc-binding-{{ .name }}-{{ .nameNormalized }}' }   # verify param names: app `name` vs cluster `name` collide!
    spec:
      project: platform-mgmt
      source:
        repoURL: https://github.com/koorikla/platform-lab.git
        targetRevision: 'rendered/{{ .values.branch }}'
        path: 'apps/{{ .name }}/binding'
        kustomize:
          nameSuffix: '-{{ .nameNormalized }}'
          patches:
            - target: { kind: ReleaseBinding }
              patch: |-
                - { op: replace, path: /spec/environment, value: '{{ .nameNormalized }}' }
      destination: { name: in-cluster, namespace: default }
      syncPolicy: { automated: { prune: true, selfHeal: true } }
```
**Param collision:** the git files generator exposes app.yaml's `name` and the cluster generator exposes `name` too.
Fix before shipping: rename the app key in app.yaml to `app:` (update Task 3.1/3.2 accordingly) or use
`pathParamPrefix`/`values`. Write a lint check that renders each appset with `argocd appset generate` if available
(`argocd appset generate <file> --core` needs a cluster; alternatively verify on the hub with
`kubectl get applications -l` after push).
For canary clusters the binding reads `rendered/dev-canary`, so apps need the `dev-canary` stage too — keep
`stages` identical for apps and addons (single value in kargo-pipeline chart).
Commit.

### Task 3.5: `openchoreo-types` hub addon + default pipeline/project

- `repos/platform-config/addons/management/openchoreo-types/{addon.yaml,values.yaml}` → chart `openchoreo-app`,
  `mode: types`; values also create `Project lab` + `DeploymentPipeline default` (`promotionPaths: []` first).
- E2E: Backstage shows System `lab`. Commit.

### Task 3.6: End to end — podinfo through OpenChoreo

1. Push; `kargo-app-pipelines` creates `app-podinfo`; freight appears (latest 6.x semver).
2. dev-canary/dev auto-promote → `rendered/dev/apps/podinfo/{release,binding}` exist.
3. Hub: `kubectl --context mgmt get componentrelease,releasebinding -n default` → `podinfo-dev-<tag>-<hash>`,
   `podinfo-dev1`, `podinfo-dev2`.
4. Worker dev1: namespace `dp-default-lab-dev1-*` has the podinfo Deployment Running.
5. Backstage: Component `podinfo` under System `lab`, deployed in `dev / dev1` and `dev / dev2`.
6. Promote to test (`kargo promote --project app-podinfo --stage test`); `git diff origin/rendered/dev
   origin/rendered/test -- apps/podinfo` shows only env/name differences.
If Backstage's component view needs the DeploymentPipeline to show environments (step 5 fails with envs missing),
do Task 3.7; otherwise skip it.

### Task 3.7 (conditional): DeploymentPipeline from the fleet

Generate `repos/platform-config/fleet/pipeline.yaml` (promotionPaths `dev* → test* → prod*` from fleet file names)
with `hack/gen-pipeline.sh`; `make lint` fails if it's stale (`hack/gen-pipeline.sh --check`). Rendered by
`openchoreo-types`. Document as a derived artifact in CLAUDE.md invariant 2.

### Task 3.8: Cleanup + docs

- Remove `workloads` AppProject if unused; remove `repos/apps/*/chart` references from `hack/lint.sh`; lint renders
  `openchoreo-app` for every app × env.
- CLAUDE.md: Flow section, invariants (apps = OpenChoreo Components; Kargo writes `rendered/*` only; identity patches),
  backlog item 5 marked done with remaining OpenChoreo items (workflow/observability planes, auth hardening).
- README: diagram + "How targeting works" (rings, rendered branches), `make ui` ports.
- `make lint && make test`; commit; push; final E2E: add `fleet/clusters/test/test1.yaml` (rename from `.disabled`)
  and confirm test1 appears in Backstage, gets addons from `rendered/test`, and podinfo from `rendered/test`.

---

## Execution notes
- Phases are independently shippable; stop after each and verify on the live lab.
- Memory: Phase 2 adds ~2–3 GB to the hub. If the hub's nodes go `MemoryPressure`, raise `workerReplicas` in
  `fleet/clusters/mgmt/mgmt.yaml` to 2 (CAPI rolls it out; the hub manages itself).
- Things flagged "verify" above are real unknowns from research — resolve them in the task, record the answer in a
  comment at the point of use, and remove the corresponding `# VERIFY` marker.
