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
tests on purpose). `test_backstage_template.sh` also needs `node` + `npm` with access to the npm registry (it installs
nunjucks, the scaffolder's template engine, into `~/.cache/platform-lab`) and `yamllint`; without them it prints
`skip:` locally, while CI (`CI=true`) always runs it. Running the lab also needs `docker`, `k3d`, `kubectl`,
`clusterctl` (see README). The `hack/` scripts also need `jq` (`lab-lock.sh`, taking over an expired lock), `gh` (`kargo-deploy-key.sh`, and issues/PRs in
general) and `go` (`hub-lb-reload.sh` renders the CAPD LB template with it).

| Command | What it proves |
|---|---|
| `make lint` (`hack/lint.sh`) | every chart builds its deps and passes `helm lint`; every hub addon renders with its values; every worker addon renders for dev/test/prod with no nameless or duplicate resources (Kargo's flat layout would overwrite them); `addon.name` == folder name; fleet `kubernetesVersion` minor == `render-addon` `kubeVersion` minor (enabled worker clusters); every cluster file renders, enabled or not |
| `make test` (`hack/tests/run.sh`) | render assertions in `hack/tests/test_*.sh`, each in its own process |

Writing a test: `source "$(dirname "$0")/lib.sh"`, then `o=$(render <release> <chart> [helm args])` and
`assert_yq "$o" '<yq expression>' '<expected>'` or `assert_fails <cmd>`. Assign `render` output to a variable first
(an inline `$(render …)` swallows its exit code) and don't set your own `EXIT` trap. See `hack/tests/test_cluster_ring.sh`
for a minimal example.

CI running both on every PR, plus a chart-version-bump guard, is planned (#1, PR #35). Until then, paste the summary lines
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
   - `env`: `dev` | `test` | `prod`. Selects the `rendered/<env>` branch for addons and the env values for apps.
   - `provider`, `region`, `clusterClass`: `docker`, `local`, `k3s-docker` on the lab. Other providers:
     [Add a CAPI provider or ClusterClass](#add-a-capi-provider-or-clusterclass).
   - `kubernetesVersion`: a k3s version (EKS: the minor as semver, `v1.34.0`). Keep the minor equal to the fleet's
     (`make lint` checks it against `kargo/shared/render-addon.yaml`).
   - `controlPlaneReplicas` (`null` for a managed control plane), `workerReplicas`, `workerClass` if the class's
     worker class isn't `k3s-default-worker`.
   - optional `ring: canary` (label `platform.lab/ring`, default `stable`). See [canary](#promote-and-canary-with-kargo).
   - optional `extraLabels`, and `variables` (ClusterClass variables; this **replaces** the chart default list, so
     keep `kindImageVersion` in it for `k3s-docker`).
2. `make lint && make test`. Merge; this is `needs-lab`: hold the lab lock when it merges.
3. What happens: the `fleet-clusters` ApplicationSet renders the `cluster` chart into `fleet` on the hub: CAPI
   `Cluster`, agent client cert, labelled Argo CD cluster secret, and a PushSecret of the cert to OpenBao. CAPI builds
   the cluster; the CAAPH birth kit (`fleet/base/helmchartproxies.yaml`) installs argo-cd, argocd-agent, ESO and the
   OpenBao pull wiring; the agent connects; `worker-addons` and `workloads` select the cluster by its labels. Watch
   with `make status`; get a kubeconfig with `make kubeconfig CLUSTER=<name> > <name>.kubeconfig`.
4. Budget: each CAPD cluster runs as containers on the same Docker VM (memory and the shared disk).

**Renaming a cluster file to `.yaml.disabled` deletes only `Application cluster-<name>`.** `fleet-clusters` sets
`preserveResourcesOnDeletion`, so the `Cluster` and everything else the `cluster` chart rendered keep running,
unmanaged; renaming it back adopts them again. See [Disabling](#disabling-rules-for-every-applicationset).
- **Never disable `fleet/clusters/mgmt/mgmt.yaml` or delete `Cluster/mgmt`.** It is the hub.
- To remove a worker (lab lock held, announced on the issue), make sure nothing still depends on it, then:
  1. Before disabling, list what the app owns (the list goes with the Application):
     `kubectl --context mgmt -n argocd get app cluster-<name> -o jsonpath='{range .status.resources[*]}{.kind} {.namespace}/{.name}{"\n"}{end}'`
  2. Rename the file to `.yaml.disabled`, merge, wait until `cluster-<name>` is gone from `kubectl -n argocd get app`.
  3. Delete the leftovers by hand, in this order (all `kubectl --context mgmt`):
     1. `-n fleet delete clusters.cluster.x-k8s.io <name>`, then watch `-n fleet get cluster,machines` until it is
        gone. CAPI tears the machines down; `openbao-fleet-sync` then drops `auth/k8s-<name>` and policy
        `cluster-<name>` (within 2 min).
     2. `-n argocd delete pushsecret <name>-argocd-agent`: `deletionPolicy: Delete` removes the agent cert and key
        from OpenBao (`secret/clusters/<name>/argocd-agent`).
     3. `-n argocd delete externalsecret cluster-<name>`: its Secret is the Argo CD cluster secret (ESO owns it), so
        `worker-addons` and `workloads` stop generating Applications for the cluster.
     4. `-n argocd delete certificate <name>-agent-client-tls` and then `-n argocd delete secret
        <name>-agent-client-tls`: otherwise the hub keeps renewing a valid agent client cert, and cert-manager leaves
        the Secret behind.
     5. `-n argocd delete role,rolebinding eso-in-cluster-<name>` (the in-cluster store's read on that cert),
        `-n fleet delete role,rolebinding <name>-ca-projector`, `-n openbao delete externalsecret <name>-ca-public`,
        and, if `openchoreo.enabled`, `delete dataplane <name>` in the OpenChoreo namespace.
  4. Check nothing is left: `kubectl --context mgmt get certificate,externalsecret,pushsecret,role,rolebinding -A |
     grep <name>`.
- To rebuild a worker from scratch, delete `Cluster/<name>` while its file stays enabled. Argo CD re-creates the
  object and CAPI builds a fresh cluster (a "rebirth").

### Add a worker addon
1. **Umbrella chart** `repos/platform-charts/<name>/` (invariant 4):
   - `Chart.yaml`: `apiVersion: v2`, `version: 0.1.0`, one upstream dependency pinned to an exact version
     (OCI `repository:` where upstream publishes one). A second dependency only if both must land in the same sync.
   - `values.yaml`: defaults, under the dependency's key; extra `templates/` allowed.
   - `helm dependency update repos/platform-charts/<name>` and commit `Chart.lock` (`charts/*.tgz` is gitignored).
2. **Config** `addons/workers/<name>/`:
   - `addon.yaml`: `addon.name` (== folder name, lint checks it), `chart`, `namespace`, `releaseName`
     (see `addons/workers/cert-manager/addon.yaml`).
   - `values.yaml`: fleet-wide values. Optional `envs/<env>.values.yaml` (per env). Precedence: fleet < env.
   - Nothing else: no version pins (the version is the Freight Kargo promotes) and no per-cluster values (a render is
     per env, not per cluster). `make test` fails on any other file in the folder. Something that must differ per
     cluster is cluster identity and belongs in the birth kit (step 5).
3. **What appears automatically** on merge:
   - Kargo project `addon-<name>` (`kargo-addon-pipelines` appset → `repos/platform-charts/kargo-pipeline`): a
     Warehouse on commits touching the chart or the addon's config, and stages `dev-canary → dev → test → prod` that
     `helm template` fleet + env values into `rendered/<stage>:addons/<name>/` (`kargo/shared/render-addon.yaml`).
     `dev-canary` and `dev` auto-promote the new Freight; `test` and `prod` wait for a manual promotion.
   - Argo CD Application `<name>-<cluster>` for every worker (`worker-addons` appset, project `platform-workers`,
     label `argocd-agent: "true"`), shipped to the cluster by the principal. It syncs `addons/<name>/` of
     `rendered/<env>` (`rendered/<env>-canary` for `ring: canary` clusters) as plain YAML. Until the first promotion
     to a stage has rendered the addon, the Applications of that env show a ComparisonError (path missing).
4. Rendering happens on the hub for the fleet's Kubernetes version: no `lookup()`, and `.Capabilities` only knows the
   `apiVersions` listed in `render-addon.yaml`. Every resource needs a `metadata.name`.
5. Anything bound to a cluster's identity (its name, its credentials) does not belong in a worker addon: it goes into
   the CAAPH birth kit (invariant 7).
6. Hub and workers resolve a fixed list of registry/git domains through public resolvers (`coredns-custom`:
   `fleet/base/hub-coredns.yaml` for the hub, its copy in the birth kit for workers; a test keeps them equal), because
   the Docker Desktop resolver times out now and then. A new chart or image registry goes into both lists.
7. Switching it off means renaming `addon.yaml` → `addon.yaml.disabled`: its Applications and Kargo pipeline go, but
   what it deployed stays on the workers (`worker-addons` sets `preserveResourcesOnDeletion`); delete that by hand if
   it must go, consumers of its CRDs first. Once project `addon-<name>` is gone, `make rendered-prune` (dry run) /
   `make rendered-prune APPLY=1` removes the stale `addons/<name>` from every `rendered/*` branch.

### Add a hub addon
1. Umbrella chart as above.
2. `addons/management/<name>/addon.yaml` (`name`, `chart`, `namespace`, `releaseName`, `chartRevision: main`) and
   `values.yaml` (hub overrides).
3. The `mgmt-addons` appset creates `mgmt-<name>` (project `platform-mgmt`, `CreateNamespace`, server-side apply;
   CRD ordering between addons settles by retries). Hub addons are not promoted through Kargo: **merge = deploy to
   the hub**, so merge under the lab lock.
4. cert-manager, capi-operator and capi-providers are also applied by `bootstrap/bootstrap.sh` from the same chart
   and values before Argo CD exists, with `helm template --no-hooks | kubectl apply`: they must work without hooks.
5. Switching it off means renaming `addon.yaml` → `addon.yaml.disabled`, under the lab lock. `mgmt-addons` sets
   `preserveResourcesOnDeletion`, so only `Application mgmt-<name>` goes. What the addon installed (CRDs, controllers,
   namespaces) keeps running unmanaged, and renaming it back adopts it again. To really remove it: list its resources
   before disabling (`kubectl --context mgmt -n argocd get app mgmt-<name> -o jsonpath=…`, as for clusters), disable,
   then delete them by hand: consumers first, CRDs last and only when no custom resources of them are left. Never
   remove `capi-operator` or `capi-providers` (CAPI CRDs: every `Cluster` would go and the workers would be torn down),
   and never remove `cert-manager` or `external-secrets` while anything uses them.

### Disabling: rules for every ApplicationSet
- Each appset either **preserves** (disabling deletes only the Application: `mgmt-addons`, `fleet-clusters`,
  `worker-addons`) or **cascades** (the Application takes its resources along: `kargo-addon-pipelines`, `workloads`).
  `hack/tests/test_appset_deletion.sh` holds the list; a new appset fails it until it is classified.
- **Turn preserve on first, then disable, in separate merges.** The appset controller strips the resources finalizer
  from existing Applications on its next reconcile, but only from apps it still generates. If one push both turns the
  flag on and disables something, that app still cascades. So: merge the flag, check
  `kubectl -n argocd get app <app> -o jsonpath='{.metadata.finalizers}'` is empty (on the hub, and for worker-addons
  also on the worker's copy), and only then disable.
- **Never `argocd app delete --cascade` a generated Application.** The server adds the resources finalizer and deletes
  the app. The appset controller then strips the finalizer and re-creates the app, but the app controller may already
  have deleted some or all of the app's resources by then. It is a race, not an undo.
- Missed listing `.status.resources` before disabling? Leftovers still carry the Argo CD tracking annotation
  `argocd.argoproj.io/tracking-id: <app>:<group>/<kind>:<namespace>/<name>`.

### Promote and canary with Kargo
Kargo UI: `make ui` → http://localhost:8081, user `admin`, password from `make kargo-password`. Kargo's git credential is a repo-scoped deploy key: run
`hack/kargo-deploy-key.sh` after a fresh hub. Promotions change the lab: hold the lab lock.

- **Worker addons** (project `addon-<name>`): Freight = a `main` commit touching the addon. `dev-canary` and `dev`
  auto-promote; `test` and `prod` are promoted by hand (UI: pick the Freight on the stage → Promote). Each promotion
  commits plain YAML to `rendered/<stage>`; the diff of that commit is the change. Prod through a PR (`pr: true`)
  needs a token that can open PRs (#6).
- **podinfo** (project `podinfo`, `kargo/podinfo/`): Warehouse on `ghcr.io/stefanprodan/podinfo` (semver `^6`).
  `dev` auto-promotes, `test`/`prod` by hand. A promotion commits `podinfo.image.tag` into
  `repos/apps/podinfo/envs/<env>/values.yaml` on `main`.
- **Canary ring** (worker addons): rings replace per-cluster version pins. To run a cluster ahead of its env, set
  `ring: canary` in its fleet file (label `platform.lab/ring=canary`): its Applications follow `rendered/<env>-canary`,
  which the `<env>-canary` stage renders before `<env>`. Only `dev-canary` exists today (a canary cluster needs that
  stage; `make lint` checks). To hold the rest of dev until the canary looks good, drop `dev` from `autoPromote` in
  `repos/platform-charts/kargo-pipeline/values.yaml` and promote `dev` by hand. End to end proof with dev2: #5. For
  apps (until #16/#17), one cluster can still run ahead with `repos/apps/<app>/clusters/<cluster>/values.yaml`.
- Never edit `rendered/*` by hand (the one documented exception is `make rendered-prune`). There is no pin file on
  `main` to edit for a break-glass: roll back by promoting older Freight to the stage (Kargo UI, stage → Freight).

### Add an app
Today (the `workloads` appset; every folder in `repos/apps/` is an app):
1. `repos/apps/<app>/chart/`: a chart (typically an umbrella over the upstream chart, as `repos/apps/podinfo/chart`).
2. `repos/apps/<app>/envs/{dev,test,prod}/values.yaml`: per-env values; the image tag here is written by Kargo.
   Optional `clusters/<cluster>/values.yaml` for one cluster.
3. Result: Application `<app>-<cluster>` on every worker, namespace `<app>`, project `workloads` (which allows only
   `Namespace` as a cluster-scoped kind).
4. Promotion: copy `kargo/podinfo/` to `kargo/<app>/` and replace every `podinfo` (`grep -rn podinfo kargo/<app>/`):
   - `project.yaml`: Namespace, Project and ProjectConfig names;
   - `warehouse.yaml`: Warehouse name, image `repoURL` and semver `constraint`;
   - `stages.yaml`: `namespace` and the Warehouse name in `requestedFreight[].origin.name`;
   - `promotion-task.yaml`: `namespace`, the `image` var default, the `yaml-update` path/key and the commit message.
5. Chart bumps in `repos/apps/<app>/chart/Chart.yaml` (yours or Renovate's) **are not promoted by Kargo**: `workloads`
   syncs `main`, so every env gets them at merge. Only the image tag goes through Kargo.

Planned: apps become OpenChoreo Components with `repos/apps/<app>/app.yaml`, rendered by an `openchoreo-app` chart
and promoted by a `render-app` Kargo task, visible in Backstage; the `workloads` appset is retired (#15–#18).

### Add a CAPI provider or ClusterClass
A cluster file picks `clusterClass`, `provider`, `region` and `variables`; everything provider-specific lives in the
class and in the provider toggle. Where things are:
- **ClusterClasses**: `fleet/base/clusterclasses/<class>.yaml`, one file per class with all its templates, namespace
  `fleet`, file name = class name. `fleet-base` syncs `fleet/base` recursively; `*.yaml.disabled` never syncs.
  (`k3s-docker` still sits at `fleet/base/clusterclass-k3s-docker.yaml`; it moves into `clusterclasses/` in a
  separate PR, because one push must not change `fleet-base`'s spec and its content.)
- **Examples, disabled**: `clusterclasses/k3s-openstack.yaml.disabled` (CAPO + k3s) and `clusterclasses/eks.yaml.disabled`
  (CAPA, managed EKS, no k3s), with cluster files `fleet/clusters/dev/os-dev1.yaml.disabled` and
  `eks-dev1.yaml.disabled`. Each class file's header lists its hub prerequisites. Fields are checked against the
  provider CRDs; what couldn't be checked without a cloud is marked `VERIFY`.
- **Provider toggles**: `repos/platform-charts/capi-providers/values.yaml` → `infrastructure.<provider>.enabled` /
  `version` (+ `configSecret` for AWS). Turn one on for the hub in `addons/management/capi-providers/values.yaml`;
  `bootstrap.sh` uses the same values.

**Enable a shipped example** (`needs-lab`; each step is its own PR):
1. Meet the hub prerequisites below and in the class file's header (hub reachable from the cloud, ORC for OpenStack,
   `clusterawsadm` IAM stack for AWS).
2. Credentials, never in git: an `ExternalSecret` on the hub that builds the Secret the provider wants from OpenBao
   (OpenStack: a Secret in `fleet` with key `clouds.yaml`, named by the `identityRef` variable; AWS: `capa-system/capa-variables`
   with `AWS_B64ENCODED_CREDENTIALS`, plus the Secret of the `AWSClusterStaticIdentity` the cluster names; that
   identity's `spec.allowedNamespaces.list` must include `fleet`, where the Clusters live, because an unset
   `allowedNamespaces` allows no namespace). Today's OpenBao is in-memory dev mode, so cloud credentials need a
   durable store first (#30).
3. `infrastructure.<provider>.enabled: true` in `addons/management/capi-providers/values.yaml`.
4. Rename the class file to `.yaml`. `make test` fails if an enabled cluster file names a disabled class.
5. Copy the example cluster file, set its variables, rename it to `.yaml`.

**Add a new provider or class:**
- **Version**: the newest provider release built on our CAPI core minor (`sigs.k8s.io/cluster-api` in the provider's
  `go.mod` at the tag) whose `metadata.yaml` still lists contract `v1beta1` for that minor. Core stays on 1.12 while
  `cluster-api-k3s` is v1beta1-contract, which is why CAPO is on v0.14.x (v0.15 is on CAPI 1.14) and CAPA on v2.12.x
  (v2.13 is on 1.13). Add a Renovate regex manager plus an `allowedVersions` cap in `renovate.json` (copy the CAPO
  ones). The cap is where that line is kept, and `make test` checks the pin stays below it.
- **Operator CR** in `capi-providers/templates/providers.yaml`: `fetchConfig.url` if clusterctl doesn't know the
  provider (k3s), `configSecret` if its components have variables without defaults
  (`grep -o '\${[A-Z_]*}' infrastructure-components.yaml`; CAPA: `AWS_B64ENCODED_CREDENTIALS`).
- **Class file**: copy an example. Use a variable for every per-cluster or per-cloud value. Templates carry
  CRD-valid placeholders that patches replace. No Secrets in the file. Use ClusterClass `cluster.x-k8s.io/v1beta1`,
  like `k3s-docker`. `test_provider_extension_points.sh` checks what CAPI can't check before a cluster exists: refs
  resolve, patches read only declared variables, every variable is used, and the `provider` label matches the class.
  `test_clusterclass_schema.sh` validates the class and every rendered `Cluster` against the pinned CRDs (in CI it
  fails rather than skips when it can't fetch them). Add the new CRD source there, and the
  infrastructure kind → `platform.lab/provider` mapping to the first test.
- **Cluster file**: `provider` (label `platform.lab/provider`: `docker` | `openstack` | `aws`), `region`, `clusterClass`,
  `variables` (replaces the chart default list), `workerClass`, and `controlPlaneReplicas: null` for a managed control
  plane. Provider-specific worker add-ons (cloud controller manager, CSI) select on `platform.lab/provider`.

**What differs per provider** (invariants 1, 2 and 7 hold for all):

| | `k3s-docker` (lab) | `k3s-openstack` | `eks` |
|---|---|---|---|
| Control plane | k3s in CAPD containers | k3s on Nova VMs; API behind Octavia or a floating IP | AWS-managed; no replicas |
| Worker bootstrap | `KThreesConfig` | `KThreesConfig` + kubelet `provider-id=openstack:///…` (CAPI matches Nodes by providerID) | `NodeadmConfig` on Amazon Linux 2023 (no AL2 AMIs for ≥ 1.33) |
| `kubernetesVersion` | k3s (`v1.34.11+k3s1`) | k3s | EKS minor as semver (`v1.34.0`) |
| `<name>-kubeconfig` (CAAPH, `make kubeconfig`) | CAPI, client cert | CAPI, client cert | CAPA: key `value` holds a 15-minute STS token refreshed on reconcile (VERIFY CAAPH copes); `<name>-user-kubeconfig` uses the AWS exec plugin |
| `<name>-ca` → OpenBao `auth/k8s-<name>` | yes | yes | CAPA writes no `<name>-ca` (the CA is only inside the kubeconfig), so fleet-sync skips the cluster and its ESO can't log in. **Blocker, needs its own CA projection** |
| Birth-kit `coredns-custom` | k3s CoreDNS imports it | same | EKS CoreDNS ignores it (harmless) |
| Cloud credentials | none | `clouds.yaml` Secret in `fleet` | `capa-variables` + identity Secret in `capa-system` |

**The hub must be reachable at a real address.** Workers dial the principal (`:30443`) and OpenBao (`:30820`) at
`mgmt-lb`, which is a container on the local Docker network. That name is set in the birth kit's `server: mgmt-lb`
and `http://mgmt-lb:30820`, and in the principal's `hub.host`. Before the first cloud worker, the hub needs a routable
DNS name (public load balancer or VPN) that is in the principal's certificate SANs, and OpenBao needs TLS (it is
plain HTTP today). The other direction must also work: the hub's CAPI, CAAPH and OpenBao TokenReview call the
worker's API. EKS's public endpoint and CAPO's API floating IP provide that. k3s nodes download k3s at boot, so they
need internet egress.

## Secrets
- No secret material in git, PRs, issues or logs. Evidence comments show key names or HTTP status, not values.
- **Generate secrets in the cluster; don't put them in values.** Patterns in use:
  - an ESO `Password` generator plus an `ExternalSecret` with `refreshPolicy: CreatedOnce` (Kargo admin,
    `repos/platform-charts/kargo/templates/admin-secret.yaml`, read with `make kargo-password`; rotate by deleting the
    target Secret and restarting the consumer);
  - a cert-manager key copied into the shape the consumer wants (argocd-agent JWT key,
    `repos/platform-charts/argocd-agent-principal/templates/jwt-key.yaml`).
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
- The workers' Kubernetes version as one group: fleet `kubernetesVersion` (k3s), `render-addon` `kubeVersion`,
  `kindImageVersion`/`kindest/node`, and `alpine/k8s`. Patch updates open a PR; minor/major wait for approval on the
  Dependency Dashboard issue, since they change the whole fleet.
- The hub (`fleet/clusters/mgmt/mgmt.yaml`) and the k3d bootstrap image in a separate `kubernetes hub` group that
  always waits for dashboard approval: rolling the self-hosted, single-control-plane hub is its own change.
- `gateway-crds-helm` grouped with kgateway and held below 1.9 (1.9 brings Gateway API v1.6, which kgateway and
  OpenChoreo have to support first).

PRs are grouped per area and labelled `dependencies` plus the `area:*` label. Nothing automerges. Everything under
`repos/apps/*/envs/` is ignored (Kargo writes the image tag there). When Renovate changes a chart through a
regex-managed pin (`capi-providers/values.yaml`, `cluster/values.yaml`), bump that chart's `version` in the PR (the PR
body says so).

Where a merged bump goes: hub addons and the birth kit deploy at merge. A worker addon chart bump becomes Kargo
Freight and goes dev-canary → dev → test → prod. App chart bumps always deploy at merge (see
[Add an app](#add-an-app)). Review a Renovate PR like any other:
upstream changelog, `make lint && make test`, and live verification under the lab lock when it changes the lab.
