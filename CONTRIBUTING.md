# Contributing

This repo is a template for a team: several people (and agents) change it in parallel, extend it with new providers,
and should find it shaped like production. Before changing anything, read the **invariants in [CLAUDE.md](CLAUDE.md)**.
PRs that break one are not merged.

Contents: [How work flows](#how-work-flows) · [Local checks](#local-checks) · [Recipes](#recipes) ·
[Secrets](#secrets) · [Conventions](#conventions) · [Dependency updates (Renovate)](#dependency-updates-renovate)

## How work flows

```
GitHub issue ──claim──▶ worktree branch ──TDD──▶ PR ──review──▶ squash-merge to main ──▶ Argo CD / Kargo
 (status:ready)          issue-<n>-<slug>        Closes #n    coordinator             (needs-lab: verify live
                                                              + CODEOWNERS              under the lab lock)
```

1. **Pick an issue.** The backlog is [GitHub issues](https://github.com/koorikla/platform-lab/issues), not a doc.
   Labels:

   | Label | Meaning |
   |---|---|
   | `status:ready` / `status:blocked` / `status:in-progress` | exactly one; `blocked` until every "Blocked by: #n" is closed |
   | `phase:<n>` | phase of the plan in `docs/plans/*-plan.md` |
   | `area:*` | argocd, kargo, capi, openbao, openchoreo, ci, docs, backstage, security, networking |
   | `needs-lab` | acceptance needs the shared live lab, not only offline renders |

   New work gets an issue first (templates in `.github/ISSUE_TEMPLATE/`).
2. **Claim it.** Assign yourself, swap `status:ready` for `status:in-progress`, comment "claimed by <you>". One issue
   per person or agent at a time.
3. **Branch in your own worktree** from `origin/main`: `git worktree add ../lab-issue-<n> -b issue-<n>-<slug> origin/main`.
   Parallel workers never share a working tree.
4. **Test first.** Add or extend `hack/tests/test_*.sh`, watch it fail, implement, then `make lint && make test`
   (see [Local checks](#local-checks)).
5. **Open a PR** for that one issue with `Closes #<n>`; the template asks for tests run, lab verification and the
   invariants checklist. Rebase on `origin/main` yourself if it moved.
6. **Review.** CODEOWNERS (`.github/CODEOWNERS`) requests the owners of the paths you touched. The coordinator reviews
   twice: spec (does it do what the issue asks) and quality. You don't merge your own PR unless the issue says so.
   Merges are squash merges.
7. **Verify live** (`needs-lab` only, after merge): `hack/lab-lock.sh acquire issue-<n>/<you> [minutes]`, wait for
   Argo CD to sync `main`, run the issue's acceptance checks, comment the evidence on the issue (key lines only,
   never secret material), then `hack/lab-lock.sh release issue-<n>/<you>`. If it fails, fix forward while you still
   hold the lock, or revert.

Agents follow the same flow through the project skill
[`.claude/skills/platform-lab-issue/SKILL.md`](.claude/skills/platform-lab-issue/SKILL.md). It is also the most
precise description of the process for humans, including the coordinator's checklist.

### The shared lab
There is **one** live lab (hub context `mgmt`, workers `dev1`, …). Read-only `kubectl` needs nothing. Anything that
mutates it needs the lab lock (`hack/lab-lock.sh status|acquire|release`, a `Lease` on the hub): merging a change Argo
CD applies, `kubectl apply/patch/delete`, Kargo promotions, `docker` on lab containers, cluster rebirths.
- Never `kind delete cluster` (the CAPD clusters show up in `kind get clusters`); never delete `Cluster/mgmt`.
- Keep ≥25 GB free Docker disk (`docker system df`): DiskPressure evicts pods on every cluster at once.
- `rendered/*` branches are written only by Kargo.

## Local checks

Needs `helm` and [mikefarah `yq` v4](https://github.com/mikefarah/yq) (python-yq has a different syntax and fails the
tests on purpose). Running the lab also needs `docker`, `k3d`, `kubectl`, `clusterctl` (see README).

| Command | What it proves |
|---|---|
| `make lint` (`hack/lint.sh`) | every chart builds its deps and passes `helm lint`; every hub addon renders with its values; every worker addon renders for dev/test/prod with no nameless or duplicate resources (Kargo's flat layout would overwrite them); `addon.name` == folder name; fleet `kubernetesVersion` minor == `render-addon` `kubeVersion` minor; every cluster file renders, enabled or not |
| `make test` (`hack/tests/run.sh`) | render assertions in `hack/tests/test_*.sh`, each in its own process |

Writing a test: `source "$(dirname "$0")/lib.sh"`, then `o=$(render <release> <chart> [helm args])` and
`assert_yq "$o" '<yq expression>' '<expected>'` or `assert_fails <cmd>`. Assign `render` output to a variable first
(an inline `$(render …)` swallows its exit code) and don't set your own `EXIT` trap. See `hack/tests/test_cluster_ring.sh`
for a minimal example.

CI running both on every PR, plus a chart-version-bump guard, is planned (#1). Until then, paste the summary lines
into the PR.

## Recipes

Paths below are relative to `repos/platform-config/` (config) or `repos/platform-charts/` (charts) unless they start
with `repos/`.

### Add a worker cluster
1. Create `fleet/clusters/<env>/<name>.yaml`. Copy `fleet/clusters/dev/dev1.yaml`, or enable a shipped one by
   renaming `dev2.yaml.disabled` → `dev2.yaml`. Keys are values of the `cluster` chart (defaults and comments in
   `repos/platform-charts/cluster/values.yaml`):
   - `name`: unique, DNS-safe. It becomes the CAPI Cluster, agent name, cert CN and Argo destination (invariant 1).
     Never rename a running cluster; create a new one.
   - `env`: `dev` | `test` | `prod`. Selects env values and pins for addons and apps.
   - `provider`, `region`, `clusterClass`: `docker`, `local`, `k3s-docker` today.
   - `kubernetesVersion`: a k3s version. Keep the minor equal to the fleet's (`make lint` checks it against
     `kargo/shared/render-addon.yaml`).
   - `controlPlaneReplicas`, `workerReplicas`.
   - optional `ring: canary` (label `platform.lab/ring`, default `stable`). See [canary](#promote-and-canary-with-kargo).
   - optional `extraLabels`, and `variables` (ClusterClass variables; this **replaces** the chart default list, so
     keep `kindImageVersion` in it).
2. `make lint && make test`. Merge; this is `needs-lab`: hold the lab lock when it merges.
3. What happens: the `fleet-clusters` ApplicationSet renders the `cluster` chart into `fleet` on the hub: CAPI
   `Cluster`, agent client cert, labelled Argo CD cluster secret, and a PushSecret of the cert to OpenBao. CAPI builds
   the cluster; the CAAPH birth kit (`fleet/base/helmchartproxies.yaml`) installs argo-cd, argocd-agent, ESO and the
   OpenBao pull wiring; the agent connects; `worker-addons` and `workloads` select the cluster by its labels. Watch
   with `make status`; get a kubeconfig with `make kubeconfig CLUSTER=<name> > <name>.kubeconfig`.
4. Budget: each CAPD cluster runs as containers on the same Docker VM (memory and the shared disk).

Removing a cluster (under the lab lock): rename the file to `.yaml.disabled` first. `fleet-clusters` never
auto-prunes (`prune: false`), so check `kubectl --context mgmt -n fleet get cluster <name>` and delete the `Cluster`
if it is still there. Deleting `Cluster/<name>` while its file is still enabled does not remove it: Argo CD re-creates
it and CAPI builds a fresh cluster (that is how a rebirth is done).

### Add a worker addon
1. **Umbrella chart** `repos/platform-charts/<name>/` (invariant 4):
   - `Chart.yaml`: `apiVersion: v2`, `version: 0.1.0`, one upstream dependency pinned to an exact version
     (OCI `repository:` where upstream publishes one). A second dependency only if both must land in the same sync.
   - `values.yaml`: defaults, under the dependency's key; extra `templates/` allowed.
   - `helm dependency update repos/platform-charts/<name>` and commit `Chart.lock` (`charts/*.tgz` is gitignored).
2. **Config** `addons/workers/<name>/`:
   - `addon.yaml`: `addon.name` (== folder name, lint checks it), `chart`, `namespace`, `releaseName`
     (see `addons/workers/cert-manager/addon.yaml`).
   - `values.yaml`: fleet-wide values. Optional `envs/<env>.values.yaml` (per env) and `clusters/<cluster>.values.yaml`
     (one cluster). Precedence: fleet < env < cluster.
   - `envs/{dev,test,prod}.yaml`: rollout pin per env (`rollout.chartRevision: main`, `rollout.clusters: {}`). **Every
     env the addon should run in needs this file**; without it the `worker-addons` appset generates nothing there.
     Pins and per-cluster values are removed once workers sync rendered branches (#3, #4).
3. **What appears automatically** on merge:
   - Argo CD Application `<name>-<cluster>` for every worker (`worker-addons` appset, project `platform-workers`,
     label `argocd-agent: "true"`), shipped to the cluster by the principal. Today it syncs the chart from `main` at
     the env pin, so a merge reaches every cluster of that env.
   - Kargo project `addon-<name>` (`kargo-addon-pipelines` appset → `repos/platform-charts/kargo-pipeline`): a
     Warehouse on commits touching the chart or the addon's config, and stages `dev-canary → dev → test → prod` that
     `helm template` fleet + env values into `rendered/<stage>:addons/<name>/` (`kargo/shared/render-addon.yaml`).
     Workers don't consume those branches yet; switching `worker-addons` to them is #3.
4. Rendering happens on the hub for the fleet's Kubernetes version: no `lookup()`, and `.Capabilities` only knows the
   `apiVersions` listed in `render-addon.yaml`. Every resource needs a `metadata.name`.
5. Anything bound to a cluster's identity (its name, its credentials) does not belong in a worker addon: it goes into
   the CAAPH birth kit (invariant 7).
6. Hub and workers resolve a fixed list of registry/git domains through public resolvers (`coredns-custom`:
   `fleet/base/hub-coredns.yaml` for the hub, its copy in the birth kit for workers; a test keeps them equal), because
   the Docker Desktop resolver times out now and then. A new chart or image registry goes into both lists.
7. Switch it off by renaming `addon.yaml` → `addon.yaml.disabled`: the Applications and the Kargo pipeline go away.
   Stale folders on `rendered/*` are handled in #3.

### Add a hub addon
1. Umbrella chart as above.
2. `addons/management/<name>/addon.yaml` (`name`, `chart`, `namespace`, `releaseName`, `chartRevision: main`) and
   `values.yaml` (hub overrides).
3. The `mgmt-addons` appset creates `mgmt-<name>` (project `platform-mgmt`, `CreateNamespace`, server-side apply;
   CRD ordering between addons settles by retries). Hub addons are not promoted through Kargo: **merge = deploy to
   the hub**, so merge under the lab lock.
4. cert-manager, capi-operator and capi-providers are also applied by `bootstrap/bootstrap.sh` from the same chart
   and values before Argo CD exists, with `helm template --no-hooks | kubectl apply`: they must work without hooks.

### Promote and canary with Kargo
Kargo UI: `make ui` → http://localhost:8081. Kargo's git credential is a repo-scoped deploy key: run
`hack/kargo-deploy-key.sh` after a fresh hub. Promotions change the lab: hold the lab lock.

- **Worker addons** (project `addon-<name>`): Freight = a `main` commit touching the addon. `dev-canary` and `dev`
  auto-promote; `test` and `prod` are promoted by hand (UI: pick the Freight on the stage → Promote). Each promotion
  commits plain YAML to `rendered/<stage>`; the diff of that commit is the change. Prod through a PR (`pr: true`)
  needs a token that can open PRs (#6).
- **podinfo** (project `podinfo`, `kargo/podinfo/`): Warehouse on `ghcr.io/stefanprodan/podinfo` (semver `^6`).
  `dev` auto-promotes, `test`/`prod` by hand. A promotion commits `podinfo.image.tag` into
  `repos/apps/podinfo/envs/<env>/values.yaml` on `main`.
- **Canary ring**: a cluster with `ring: canary` in its fleet file gets label `platform.lab/ring=canary`; the
  `dev-canary` stage renders to `rendered/dev-canary` first. Canary clusters following that branch lands with #3,
  proven end to end in #5. Until then, run one cluster ahead with a pin: `rollout.clusters.<cluster>.chartRevision`
  in `addons/workers/<addon>/envs/<env>.yaml`, or `repos/apps/<app>/clusters/<cluster>/values.yaml` for apps.
- Never edit `rendered/*` by hand. Editing `envs/<env>.yaml` by hand is break-glass only: say so in the PR.

### Add an app
Today (the `workloads` appset; every folder in `repos/apps/` is an app):
1. `repos/apps/<app>/chart/`: a chart (typically an umbrella over the upstream chart, as `repos/apps/podinfo/chart`).
2. `repos/apps/<app>/envs/{dev,test,prod}/values.yaml`: per-env values; the image tag here is written by Kargo.
   Optional `clusters/<cluster>/values.yaml` for one cluster.
3. Result: Application `<app>-<cluster>` on every worker, namespace `<app>`, project `workloads` (which allows only
   `Namespace` as a cluster-scoped kind).
4. Promotion: copy `kargo/podinfo/` to `kargo/<app>/` and change project/namespace name, image repository and
   constraint, and the `yaml-update` path/key in `promotion-task.yaml`.

Planned: apps become OpenChoreo Components with `repos/apps/<app>/app.yaml`, rendered by an `openchoreo-app` chart
and promoted by a `render-app` Kargo task, visible in Backstage; the `workloads` appset is retired (#15–#18).

### Add a CAPI provider or ClusterClass (planned: #23)
Today there is one ClusterClass, `fleet/base/clusterclass-k3s-docker.yaml`, and provider toggles in
`repos/platform-charts/capi-providers/values.yaml` (`infrastructure.openstack` / `infrastructure.aws`, disabled,
versions TODO). A cluster file chooses `clusterClass`, `provider` and `variables`, so a new provider should not need
more than that in the cluster file. #23 defines the layout (`fleet/base/clusterclasses/<class>.yaml`), disabled
example cluster files for `k3s-openstack` and `eks`, and how the birth kit differs per provider (EKS has no k3s).
Constraints meanwhile: invariants 1, 2 and 7 hold for every provider; CAPI core stays on 1.12.x while
`cluster-api-k3s` is a v1beta1-contract provider; cloud credentials never go into git.

## Secrets
- No secret material in git, PRs, issues or logs. Evidence comments show key names or HTTP status, not values.
  Remaining literals are being moved out (#21).
- **Hub → worker is a pull model** (invariant 7). The hub issues material (cert-manager) and a hub-local `PushSecret`
  writes it to OpenBao through `ClusterSecretStore openbao` at `secret/clusters/<name>/<item>`; only namespaces in the
  openbao chart's `hubWriter.namespaces` may push. The worker's ESO reads it through `ClusterSecretStore hub-openbao`
  (birth kit), which authenticates as that worker (`auth/k8s-<name>`, maintained by the `openbao-fleet-sync` CronJob)
  and can read only its own path. Widen the store's `conditions.namespaces` for a new consumer namespace. Nothing on
  the hub writes into a worker with the CAPI admin kubeconfig. Example: `repos/platform-charts/cluster/templates/argocd-identity.yaml`
  (push) and `worker-secret-bootstrap` in `fleet/base/helmchartproxies.yaml` (pull).
- OpenBao runs in dev mode (in-memory): anything in it must be re-creatable from the hub (PushSecrets refill it
  within minutes). Don't hand-write secrets into it and expect them to survive a restart. Production shape: #30.
  OpenChoreo's secrets and `ClusterSecretStore default`: #9.
- Kargo pushes with a deploy key (`hack/kargo-deploy-key.sh` puts it straight into a hub Secret); a PR-capable token
  comes via OpenBao/ESO (#6).

## Conventions
- **Minimal YAML; comments explain why**, not what the next line says.
- Labels use the `platform.lab/` prefix. Namespaces: `argocd`, `fleet`, `kargo`.
- **Enable/disable by file extension** (`*.yaml` ⇄ `*.yaml.disabled`), never by commenting out blocks.
- **Chart versions**: bump `version` in `Chart.yaml` of every chart you change: patch for fixes and dependency bumps,
  minor for new values or templates, major when existing values change meaning. Upstream dependencies are pinned
  exactly and `Chart.lock` is committed. CI will enforce the bump (#1).
- **Upstream facts are verified, not guessed**: `helm show values` at the pinned version, `kubectl explain`, upstream
  source at the tag. Anything inferred carries a `# VERIFY` comment (`grep -rn VERIFY repos/`).
- `repos/*` are future repositories: no relative references across them except ApplicationSet `repoURL`/`$values`.
- One push must not change an Argo CD Application's spec *and* the content it syncs (auto-sync may retry the old
  spec): split it into two merges.
- After editing `fleet/base/hub-lb.yaml` on a running hub, run `hack/hub-lb-reload.sh` (CAPD renders it only when a
  control-plane machine is created or deleted).
- Commits: short imperative subject, body says why. Agent co-authored commits end with a `Co-Authored-By:` trailer.

## Dependency updates (Renovate)
`renovate.json` keeps pins current; it needs the Renovate GitHub App (or a self-hosted Renovate) on the repo.
It covers:
- Chart dependencies in every `Chart.yaml` (including OCI) and image pins in `values.yaml` files, with a patch
  bump of the chart's own `version`.
- Birth-kit HelmChartProxies and the agent image inside their `valuesTemplate`.
- CAPI providers in `capi-providers/values.yaml`, grouped with the capi-operator chart; core/CAPD held below 1.13.
- The Kubernetes version as one group: fleet `kubernetesVersion` (k3s), `render-addon` `kubeVersion`, the k3d
  bootstrap image, `kindImageVersion`/`kindest/node`, and `alpine/k8s`. Patch updates open a PR; minor/major wait for
  approval on the Dependency Dashboard issue, since they change the whole fleet.

PRs are grouped per area and labelled `dependencies` plus the `area:*` label. Nothing automerges. Kargo-owned files
(`addons/workers/*/envs/`, `repos/apps/*/envs/`) are ignored. When Renovate changes a chart through a regex-managed pin
(`capi-providers/values.yaml`, `cluster/values.yaml`), bump that chart's `version` in the PR (the PR body says so). Review a Renovate PR like any other:
upstream changelog, `make lint && make test`, and live verification under the lab lock when it changes the lab.
