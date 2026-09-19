# OpenChoreo as the developer portal + rendered manifests pattern

Status: approved design (2026-09-19). Implementation plan: `2026-09-19-openchoreo-rendered-manifests-plan.md`.

## Goal
- Every cluster added to `fleet/clusters/<env>/<name>.yaml` automatically appears in OpenChoreo's Backstage.
- Every app in `repos/apps/<app>/` automatically appears in OpenChoreo's Backstage, **deployed by OpenChoreo**, with
  real per-environment status. Kargo keeps owning promotion.
- Promotion (apps and worker addons) follows the **rendered manifests pattern**: Kargo renders plain YAML at promotion
  time into `rendered/<env>` branches; Argo CD syncs plain YAML; `main` holds intent only.

## Decisions (and why)
| Decision | Why |
|---|---|
| OpenChoreo deploys apps, Kargo promotes | Backstage only shows OpenChoreo Components; deploying through OpenChoreo gives real env status instead of a directory. |
| One OpenChoreo `Environment` per cluster (`dev1`, `dev2`, …) | `Environment.spec.dataPlaneRef` points at exactly one data plane (immutable). |
| `ClusterDataPlane` + `Environment` rendered by the `cluster` chart | Keeps invariant 2: the fleet file is the only place cluster facts live. |
| Per-cluster agent CA issued on the hub | OpenChoreo's cluster-gateway takes `planeID` from the query string and doesn't check the cert CN, so one shared CA would let any agent claim another cluster. |
| Kargo `helm-template` replaces `occ componentrelease generate` | A ComponentRelease is an immutable rendered snapshot; rendering it at promotion time and committing it is exactly RMP. |
| Per-cluster fan-out by ApplicationSet + inline kustomize patch | Kargo can't list fleet files; the cluster generator already can. No index file, no second source of cluster facts. |
| Canary ring replaces per-cluster version pins | Pins don't fit RMP (nothing is rendered per cluster); a ring is a promotion stage, which is what a pin was emulating. |
| Hub (mgmt) addons stay Argo-rendered Helm | Kargo runs on the hub; a hub-side promotion loop adds risk for little gain. |

## Architecture

```
main (intent, no versions)                          rendered/<env> branches (written only by Kargo)
 repos/platform-charts/<addon>        ─┐             addons/<addon>/*.yaml              (plain YAML)
 repos/platform-config/addons/workers/ ├─ Kargo ─▶   apps/<app>/{component,workload,
 repos/platform-charts/openchoreo-app  │  helm-       componentrelease-<tag>-<hash>,
 repos/apps/<app>/{app.yaml,envs/}    ─┘  template     releasebinding}.yaml

Argo CD (hub)
 worker-addons appset : dirs(rendered/<env>[-<ring>]/addons/*) × clusters(role=worker, env) ─▶ agent ─▶ worker
 openchoreo-apps appset: dirs(rendered/<env>/apps/*) → hub (Component, Workload, ComponentRelease)
 openchoreo-bindings   : dirs(rendered/<env>/apps/*) × clusters(env)  → hub ReleaseBinding per cluster
                         (inline kustomize patch: spec.environment + name suffix = cluster name)
OpenChoreo (hub control plane) ─ cluster-gateway ◀─wss─ cluster-agent (each worker) ─▶ applies RenderedRelease
```

### Clusters → OpenChoreo
The `cluster` chart gains, for `role: worker` and `openchoreo.enabled`:
- cert-manager CA per cluster (`<name>-oc-agent-ca`, self-signed on the hub) + agent client cert issued from it;
- `ClusterDataPlane <name>`: `planeID: <name>`, `clusterAgent.clientCA.secretKeyRef` → that CA,
  `secretStoreRef: default`, gateway `gateway-default` / `openchoreo-data-plane`, host `<name>.apps.lab.localhost`;
- `Environment <name>` in the control-plane namespace: `dataPlaneRef {kind: ClusterDataPlane}`,
  `isProduction: env == prod`, display name `"<env> / <name>"`;
- PushSecrets: agent client cert → worker `openchoreo-data-plane/cluster-agent-tls`; gateway server CA → worker.
  The data-plane chart wants the server CA as a **ConfigMap** (`cluster-gateway-ca`). The CA cert is public, so the
  data-plane umbrella chart renders that ConfigMap from a value, and the hub exports the CA into git once (it's
  long-lived). Fallback: ESO generic target, which is alpha.

`DeploymentPipeline default`: rendered on the hub by an ApplicationSet-driven chart from the cluster list, with
promotion paths `dev* → test* → prod*`. Kargo drives promotion; the pipeline is descriptive but required by `Project`.

### OpenChoreo installation
- Hub (mgmt addons): Gateway API CRDs v1.5.1 (small CRD chart), kgateway v2.3.1, OpenBao + `ClusterSecretStore/default`,
  ThunderID IdP, `openchoreo-control-plane` 1.2.5 with `clusterGateway.service` NodePort fixed and a `fleet/base/hub-lb.yaml`
  frontend so workers dial `mgmt-lb:<port>`; `clusterGateway.tls.dnsNames` includes `mgmt-lb`.
- Upstream `ClusterComponentType`s (`service`, `web-application`, `worker`, `scheduled-task`) + `ClusterProjectType`
  vendored into a platform chart (source: `samples/getting-started/all.yaml` at v1.2.5).
- Workers (worker addons): kgateway, Gateway API CRDs, `openchoreo-data-plane` 1.2.5 with
  `clusterAgent.planeID` (note: `planeID`, not `planeId`) injected per cluster, `serverUrl: wss://mgmt-lb:<port>/ws`,
  `clusterAgent.tls.clientSecretName: cluster-agent-tls` (pushed from hub).

### Apps
`repos/apps/<app>/app.yaml` describes the app for OpenChoreo (project, componentType, endpoints, env vars); image
repository only, no tag. `envs/<env>/values.yaml` holds non-version env config. The platform chart
`repos/platform-charts/openchoreo-app` renders Component (`autoDeploy: false`), Workload,
`ComponentRelease <app>-<tag>-<hash>` (hash over the frozen spec, so any change produces a new immutable release) and
a ReleaseBinding template. Kargo per app: Warehouse on the image → Stages dev → test → prod; each promotion renders
into `rendered/<env>/apps/<app>/` and pushes (prod: `git-open-pr` + `git-wait-for-pr`).

### Worker addons
Kargo project `platform-addons`, one Warehouse per addon on git commits (includePaths: the addon's chart and config).
Stages `dev-canary → dev → test → prod`, each `helm-template` with fleet < env values into
`rendered/<env>/addons/<addon>/`. Clusters opt into the canary ring with `ring: canary` in their fleet file
(label `platform.lab/ring`). Per-cluster values are replaced by identity patches (cluster name only).
CAAPH HelmChartProxies (argo-cd + agent at cluster birth) are unchanged.

## Invariants that change (CLAUDE.md)
- 5 → "Kargo writes only `rendered/*` branches. `main` holds no versions for promoted things."
- Per-cluster addon values (`addons/workers/<addon>/clusters/*.values.yaml`) and `envs/<env>.yaml` rollout pins removed.
- New: "Anything per-cluster in rendered output is identity only (cluster name), injected by ApplicationSet patches."
- Apps are OpenChoreo Components; the `workloads` appset (Argo → agent) is retired.

## Error handling / failure modes
- Kargo push fails (no creds) → promotion Errored, nothing changes on clusters. **Prerequisite: Kargo git credentials.**
- Rendered branch missing for an env → appset generates nothing for that env (no deletion of existing apps; the
  appset uses `preserveResourcesOnDeletion` for worker addons).
- Agent disconnected → ClusterDataPlane still listed in Backstage with `agent-connected=false`; bindings pend.
- New cluster before any promotion → it gets addons and bindings from the current `rendered/<env>` immediately (fan-out
  is at sync time), so new clusters join at their env's current version without a Kargo run.

## Verification
- `make lint`: renders `openchoreo-app` for every app/env, `cluster` for every fleet file, and every addon.
- End to end: add `dev2.yaml` → dev2 appears in Backstage (Dataplane + Environment), gets addons from
  `rendered/dev`, podinfo is bound and running; promote podinfo dev → test through Kargo → `rendered/test` diff shows
  the new ComponentRelease; canary: dev2 `ring: canary` gets a cert-manager bump before dev1.

## Phasing
0. Kargo git credentials (user supplies a fine-grained PAT; stored as a hub secret, later via ESO/OpenBao).
1. RMP for worker addons (no OpenChoreo dependency; proves the pattern on the path that already works).
2. OpenChoreo control plane on hub + data plane on workers; clusters appear in Backstage.
3. Apps through OpenChoreo + RMP; retire the `workloads` appset.

## Risks
- Re-implementing `occ componentrelease generate` in a chart can drift from upstream semantics (traits, profiles).
  Mitigation: keep ComponentType specs in the same chart that renders releases; pin OpenChoreo 1.2.5.
- Memory: OpenChoreo control plane + Thunder + OpenBao + kgateway on the hub add roughly 2–3 GB on a 16 GB Docker VM.
- Argo CD support for OpenChoreo CR health/diff is untested (upstream documents Flux only).

## Addendum: pull-model secrets via OpenBao (user decision 2026-09-19)
Replaces "hub PushSecret writes into the worker with the CAPI admin kubeconfig".
- **OpenBao on the hub** (KV v2 `secret/`), reachable by workers through a `mgmt-lb` TCP frontend.
- **Hub writes:** cert-manager issues per-cluster material (argocd-agent client cert + CA; later OpenChoreo agent
  cert + gateway CA); a hub-local `PushSecret` (OpenBao provider — legitimate PushSecret use) writes it to
  `secret/clusters/<name>/<item>`.
- **Worker pulls:** the worker's ESO (`ClusterSecretStore hub-openbao`) reads only its own path via
  `ExternalSecret`s; the gateway CA becomes a ConfigMap through an ESO generic target.
- **Per-cluster identity in OpenBao** (as built, Phase 1b): one hub **CronJob `openbao-fleet-sync`** in the `openbao`
  chart (not a Job per cluster) reconciles every 2 min: for each CAPI Cluster with `platform.lab/role=worker` it
  enables `auth/k8s-<name>` (Kubernetes auth against the worker API: endpoint from `Cluster.spec.controlPlaneEndpoint`,
  CA from `openbao/<name>-ca-public`), a role `eso` bound to the worker's ESO ServiceAccount, and a policy limited to
  `secret/data/clusters/<name>/*`; mounts/policies of deleted clusters are removed. A worker can read only its own
  secrets. The CronJob can't read the `fleet` namespace: the `cluster` chart grants a projector SA `get` on exactly
  `<name>-ca` and an ExternalSecret copies only its public cert to `<name>-ca-public`. OpenBao's `fleet-sync` policy
  pins mount type, role shape and `cluster-*` policy names (`allowed_parameters`); the policy *body* can't be pinned
  (residual risk, see platform-charts/openbao values.yaml). **#30 removed it:** fleet-sync writes no policy; every
  worker role carries one fixed templated policy `cluster-reader` (`secret/data/clusters/{{identity.entity.metadata.cluster}}/*`)
  and fleet-sync binds the ESO login to entity `cluster-<name>`. Same issue: raft PVC, static-key auto-unseal (lab
  stand-in for KMS), self-init bootstrap + `configure` sidecar instead of dev mode + postStart.
- **Birth kit (CAAPH, per worker):** ESO + the `hub-openbao` ClusterSecretStore + the ExternalSecrets for the agent
  identity + a TokenReview ClusterRoleBinding, installed before argocd-agent. ESO therefore leaves `worker-addons`.
- Lab simplifications (documented, prod path noted): OpenBao dev mode (in-memory, root token) and plain HTTP on the
  frontend; prod = HA storage, auto-unseal, TLS via cert-manager.

## Addendum: no kustomize; identity via CAAPH (user decision 2026-09-19)
- Kargo renders **folders** (`helm-template` `outLayout: flat`, one file per resource) into
  `rendered/<branch>/addons/<addon>/`, after a `delete` step clears that folder; Argo syncs it with
  `directory.recurse`. No kustomization files, no inline patches (Argo only patches when a kustomization exists).
- Rule: **Kargo renders everything versioned; per-cluster stamping is identity only** (cluster name), done where
  templating already exists:
  - cluster-identity-bound components (argocd-agent, OpenChoreo data plane `clusterAgent.planeID`, the ESO store for
    the OpenBao pull model) live in the **CAAPH birth kit** — HelmChartProxy `valuesTemplate` renders
    `{{ .Cluster.metadata.name }}` per cluster;
  - per-cluster OpenChoreo `ReleaseBinding`s: an ApplicationSet (apps × clusters) renders a tiny `openchoreo-binding`
    chart with the cluster name as a Helm parameter and the Kargo-rendered release name from `rendered/<env>` as a
    values file (multi-source `$rendered`).
- Consequences: `addon.yaml` has no `clusterIdentity`; the worker-addons appset has no `templatePatch`; sections above
  that mention kustomize patches are superseded by this addendum.

## Addendum: progressive sync (RollingSync) on worker-addons — not enabled (coordinator decision 2026-09-19, #27)
- **Decision:** `worker-addons` stays auto-sync (AllAtOnce). Generated apps carry `platform.lab/ring` (canary|stable,
  same rule as the branch) so RollingSync, UI filters and Kargo verification (#26) can select on it. Kargo gates
  promotion per addon; #26 adds health verification per stage.
- **It would work through argocd-agent managed mode** (verified in source: Argo CD v3.5.3, argocd-agent v0.10.0):
  - RollingSync reads only hub Application status and writes `automated.enabled=false` + `.operation`
    (`applicationset/progressivesync/progressive_sync.go` 738 `disableAutomatedSync`, 745 `SyncDesiredApplications`,
    775 `syncApplication`: prune = `automated.prune`, retry/syncOptions from `syncPolicy`); a manually set
    `.operation` survives (`applicationset_controller.go:678`).
  - The hub app-controller skips apps on `skip-reconcile` clusters (`controller/sharding/cache.go:66`).
  - The principal forwards a nil→set `.operation` as a `SetOperation` event, like a UI sync
    (`principal/callbacks.go:206,219`); the agent applies labels/spec/operation (`internal/manager/application/
    application.go:308` `UpdateManagedApp`, `:695` `SetOperation`) and mirrors status and the cleared operation back
    (`:573` `UpdateStatus`, `:594`). Worker Argo CD honours `automated.enabled: false` (`types.go:1531`).
    Upstream lists weak progressive syncs as an *autonomous*-mode drawback only (`docs/concepts/agent-modes/autonomous.md:27`).
- **Why not now:**
  - RollingSync forces auto-sync off → no selfHeal on any worker addon (it only reacts to a revision/spec change,
    `progressive_sync.go:411`; drift stays OutOfSync until a new commit or a manual sync).
  - A step starts only when every earlier-step app is Healthy (`getAppsToSync`, `:525`), across all addons: one
    Degraded dev app holds every test/prod sync, including a new cluster's addons.
  - It orders by revisions each worker has already seen (its own ~3 min refresh), so it cannot order `dev-canary` →
    `dev` moved seconds apart by Kargo autoPromote — the one ordering Kargo doesn't enforce today.
  - Pending → Progressing compares the worker's `reconciledAt`/`operationState.startedAt` with the hub controller's
    `lastTransitionTime` (`:468,470`): clock skew between hub and workers can stall or misjudge a step (same Docker
    clock in the lab, not across real clouds).
  - Beta feature (since v3.3); with a single worker (dev1) it buys nothing but costs selfHeal.
- **To enable later** (e.g. many clusters per env): argo-cd umbrella `argo-cd.configs.params` add
  `applicationsetcontroller.enable.progressive.syncs: true` (bump the chart; argo-helm's `checksum/cmd-params` restarts
  the controller), then in `appset-worker-addons.yaml`:
  ```yaml
  strategy:
    type: RollingSync          # no deletionOrder: preserveResourcesOnDeletion leaves nothing to order
    rollingSync:
      steps:                   # Kargo stage order
        - matchExpressions: [{ key: platform.lab/env, operator: In, values: [dev] }, { key: platform.lab/ring, operator: In, values: [canary] }]
        - matchExpressions: [{ key: platform.lab/env, operator: In, values: [dev] }, { key: platform.lab/ring, operator: In, values: [stable] }]
        - matchExpressions: [{ key: platform.lab/env, operator: In, values: [test] }]
        - matchExpressions: [{ key: platform.lab/env, operator: In, values: [prod] }]
          maxUpdate: 25%       # prod apps (addon x cluster) at once; >0% never rounds to 0
  ```
  Escape hatch for a held step: `argocd app sync <addon>-<cluster>` on the hub. Kargo must then not sync these apps
  itself (`argocd-update`). Back out = drop `strategy` (auto-sync returns). Test sketch (step order == Kargo stages,
  every app in exactly one step): PR #51's first revision, commit fbe5e99.

## Addendum: Kargo verification per addon stage (#26, 2026-09-19)
- **Decision:** every stage of an addon pipeline verifies (Stage `spec.verification`, AnalysisTemplate `argocd-apps`
  per project in the `kargo-pipeline` chart). A measurement is a Job on the hub reading the hub Applications of the
  addon on the stage's clusters (labels addon + env + ring, from `worker-addons`): all Synced + Healthy at the promoted
  rendered commit or a descendant on `rendered/<stage>`. Success = 4 in a row, failure = none such streak in 20.
- **Why a Job, not `argocd-update`:** Kargo's Argo CD step and its health checks need Application names in the Stage;
  ours are `<addon>-<cluster>`, generated per cluster (invariant 2: no cluster names outside the fleet files). A label
  selector in the Job keeps the Stage cluster-agnostic, and nothing on the hub triggers syncs of agent-managed apps.
- **Revision:** verification can't read promotion outputs (Kargo v1.11.4: only `ctx.project`, `ctx.stage`, Stage
  vars and data functions), so the promotion's `set-metadata` step stores `outputs.render.commit` as Stage metadata
  `renderedCommit` and the verification arg reads `stageMetadata(ctx.stage)`. Descendants count because every addon
  pipeline pushes to the same branch; ancestry comes from a commit-only fetch (`--filter=tree:0`) of that branch.
- **Soak:** dev's 15 min soak (#61) is dropped: a timer that ignores health. `stages[].soak` stays for a deliberate
  minimum dwell on top of verification.
- **Empty stages pass** (no clusters in test/prod today): the Stage can't know the fleet without breaking invariant 2.
  Except `<env>-canary` stages (arg `requireApps`): an empty canary ring must not open the gate for `<env>`.

## Addendum: rendered app contract (#16, 2026-09-19)
Kargo renders only what is versioned: the ComponentRelease (and the one Workload). Components come from `main`,
ReleaseBindings are stamped per cluster by a hub appset (#17). What #17 consumes:
- **Branches:** `rendered/<stage>` for every `kargo-pipeline` stage (`dev-canary`, `dev`, `test`, `prod`). A cluster
  binds from `rendered/<env>`, or `rendered/<env>-canary` in the canary ring (worker-addons' rule).
- **Folder:** `apps/<app>/release/`, `<app>` = folder under `repos/apps` = Component name. Project `app-<app>` owns
  `apps/<app>/`: each promotion deletes it and renders it again (task `render-app`).
- **Files** (Kargo v1.11.4 flat layout, `<group . -> _>-<kind>-<namespace>-<name>.yaml`, lowercase):
  `openchoreo_dev-componentrelease-default-<app>-<stage>-<tag>-<hash8>.yaml`, exactly one per folder (glob
  `apps/*/release/openchoreo_dev-componentrelease-*.yaml`); binding parameters come from its `metadata.name` and
  `spec.owner.{projectName,componentName}`. `openchoreo_dev-workload-default-<app>-workload.yaml` only on `dev`.
- **Lifecycle:** a new tag or config is a new release name, so a promotion replaces the file and the previous release
  leaves the branch. ComponentReleases are immutable; whether the hub keeps them (no prune) is #17's decision.
- **Transition:** until #17 nothing syncs `apps/`; podinfo keeps running from the `workloads` appset
  (`repos/apps/podinfo/chart` at its default tag + a legacy `podinfo:` block in `envs/<env>/values.yaml`). #17 removes
  both with the appset (spec change and content removal in separate merges).
- **Promotion gate:** the #26 verification (hub Applications of an addon) exists only for `kind: addon`. App
  pipelines have nothing deployed to verify until #17, so their `dev` follows `dev-canary` after a soak
  (`appSoak`, 15 min). App verification (Components/ReleaseBindings Ready on the hub) belongs to #17/#18.

## Addendum: clusters → OpenChoreo as built (#13, 2026-09-19)
Supersedes "Clusters → OpenChoreo" above; details in the plan, Task 2.7 "As built (#13)".
- No `openchoreo.enabled`: the `cluster` chart renders the registration for workers when the hub serves
  `openchoreo.dev/v1alpha1/ClusterDataPlane` (helm `.Capabilities` from Argo), i.e. while the control-plane addon is on.
  The API versions are part of Argo's manifest cache key: once the CRDs appear, the objects render within
  ~120s (`timeout.reconciliation`), no commit or hard refresh needed. Disabling the addon leaves them (prune: false).
- Per-cluster agent CA + client cert in `openchoreo-control-plane`; `ClusterDataPlane.clientCA.secretKeyRef` → that CA,
  no `secretStoreRef`; `Environment <name>` in `default`.
- Pull model, no hub → worker writes: client cert (tls.crt, tls.key) → `secret/clusters/<name>/openchoreo-agent`, the gateway's server CA
  (`ca.crt` only) → `secret/clusters/<name>/openchoreo-gateway-ca`; the worker's ESO pulls them (#14). The CA is not
  exported into git.
- Client cert `duration: 8760h`, `renewBefore: 720h`: upstream cluster-agent loads it once at startup
  (`internal/cluster-agent/agent.go:83`) and never reloads, so #14 must restart the agent when the pulled Secret
  changes (reloader/checksum annotation). The agent's own CA is not pushed: the worker verifies the gateway with
  `openchoreo-gateway-ca` only.

## Addendum: environments are dev, nit, sit, prod (maintainer decision 2026-09-19, #81)
Every `dev/test/prod` above means dev → nit → sit → prod (stages `dev-canary → dev → nit → sit → prod`, `rendered/<stage>`; nit, sit, prod manual; OpenChoreo `isProduction` only for prod).

## Addendum: data plane on workers as built (#14, 2026-09-19)
Supersedes "data plane in the birth kit" above: the birth kit stamps the *identity*; the data plane itself is a worker
addon. Details: plan Task 2.8 "As built (#14)".
- **Why the chart can't be in the birth kit:** with TLS on, `openchoreo-data-plane` 1.2.5 always renders a cert-manager
  `Certificate` + `Issuer` (no value turns them off), and its Gateway/HTTPListenerPolicy need Gateway API + kgateway
  CRDs. All three arrive as worker addons through the birth kit's own argocd-agent. Helm maps every object before it
  creates any, so a birth kit carrying them would fail its first install forever (no agent → no addons → no CRDs).
- **Birth kit (per cluster):** two `ClusterExternalSecret`s for namespace `openchoreo-data-plane` (Argo creates it;
  ESO fills it when it appears): Secret `cluster-agent-tls` = `tls.crt`/`tls.key` from
  `secret/clusters/<name>/openchoreo-agent` + key `plane-id: <name>` (template, `mergePolicy: Merge`); ConfigMap
  `cluster-gateway-ca` = `ca.crt` from `.../openchoreo-gateway-ca` (ESO generic target, `genericTargets.enabled`).
  The `hub-openbao` store admits `openchoreo-data-plane`.
- **Worker addon `openchoreo-data-plane` (Kargo, cluster-agnostic):** `planeID: $(PLANE_ID)`, env `PLANE_ID` from
  `cluster-agent-tls#plane-id` (the chart's `extraEnvs` accept only `secretKeyRef`). The chart's throwaway Certificate
  goes to `cluster-agent-selfsigned-unused`. `security.enabled: false` (a webhook cert for a webhook the data plane
  doesn't run). Gateway `gateway-default` http :80.
- **Restart on renewal:** Reloader (stakater, bundled in the umbrella, namespace-scoped, `reloadStrategy: annotations`)
  rolls `cluster-agent-dataplane` when `cluster-agent-tls` or `cluster-gateway-ca` changes. The annotations sit on the
  pod template, which Reloader v1.4.22 reads when the Deployment itself has none.
- **Gateway proxy:** GatewayParameters `gateway-default` (ClusterIP, envoy requests only), the same shape as the hub's.
  With kgateway's default LoadBalancer, k3s servicelb would bind :80 on every worker node. Exposing worker apps is
  Phase 3's decision (#17/#18).
- **ClusterExternalSecret side effects** (ESO v2.10.0 `ensureNamespaceFinalizer`):
  - ESO puts a finalizer `externalsecrets.external-secrets.io/ces-<name>` on `openchoreo-data-plane`. Deleting that
    namespace therefore needs the worker's ESO running, which it always is while the birth kit is installed.
  - Rolling the birth kit back to a version without the CESs deletes them in the same Helm upgrade that restarts ESO.
    Afterwards, check that the namespace keeps no stale `ces-*` finalizer:
    `kubectl get ns openchoreo-data-plane -o jsonpath='{.metadata.finalizers}'`.
  - `openchoreo-data-plane` also exists when only kgateway is enabled. On a hub without OpenChoreo nothing is pushed,
    so both ExternalSecrets sit in `SecretSyncedError`. That is noise, not harm.
- **Trust boundary: the OpenChoreo control plane is worker admin.** Upstream's agent ClusterRole grants `*` on secrets,
  RBAC and core resources cluster-wide. Whoever controls the hub's OpenChoreo can do anything on every connected
  worker, including reading the argocd-agent client key in `argocd`.

## Addendum: OpenChoreo platform defaults and the DeploymentPipeline (#78, 2026-09-19)
Supersedes "`DeploymentPipeline default`: rendered … from the cluster list" above and plan Task 3.7 (generated file).
- **Why a pipeline at all:** OpenChoreo v1.2.5's Component controller marks a Component Ready only when its
  ClusterComponentType exists, its Project exists and the Project's DeploymentPipeline has a *root* (a
  `promotionPaths[].sourceEnvironmentRef` that is never a target; `internal/controller/component/controller.go`
  `validateAndFetchDeploymentPipeline`, `findRootEnvironment`; it also needs its Workload, which #17 syncs). The root
  matters only for `autoDeploy`, which we keep off. Nothing else reads the pipeline for deployment: ReleaseBindings
  and ProjectReleaseBindings don't check it, so Kargo stays the promotion engine; the pipeline is what Backstage and
  `occ` show. One side effect: an Environment can't be deleted while a pipeline references it
  (`internal/controller/environment/controller_finalize.go`).
- **Env vs cluster:** an `Environment` points at exactly one data plane (`spec.dataPlaneRef`, single object), so
  "one Environment per env with N planes" isn't possible; Environments stay per cluster (#13). The pipeline groups
  them by Kargo stage: stage = `platform.lab/env` label, plus `-canary` for `platform.lab/ring=canary` (the
  worker-addons branch rule). Every Environment of a stage promotes to every Environment of the next non-empty stage
  (`promotionPaths` = complete bipartite links between consecutive stages); the last stage's Environments are listed
  with `targetEnvironmentRefs: []` (accepted by the CRD). Example, dev2 canary, dev1+dev3, nit1, sit1, prod1:
  `dev2 → {dev1, dev3}`, `dev1 → nit1`, `dev3 → nit1`, `nit1 → sit1`, `sit1 → prod1`, `prod1 → []`; root = the first stage.
  The lab today (dev1 only): `dev1 → []`.
- **Data-driven without cluster names in git:** an ApplicationSet can't aggregate fleet files into one object, and
  Helm can't read another repo's files (invariant 6). So the pipeline is derived at runtime from what the fleet
  files already produce: the `cluster` chart's `Environment <name>` objects carry the fleet labels. Hub CronJob
  `openchoreo-pipeline-sync` (every 5 min, `files/pipeline-sync.sh`, same shape as `openbao-fleet-sync`) lists
  Environments labelled `platform.lab/role=worker`, groups them as above in Kargo stage order and merge-patches `spec.promotionPaths` (field manager
  `openchoreo-pipeline-sync`, output sorted so reruns are no-ops). Argo renders the DeploymentPipeline *without*
  `spec`, so its server-side apply never owns, resets or diffs the paths. The stage order is the required chart value
  `pipelineSync.stages` (no default), set in the config repo (`addons/management/openchoreo-types/values.yaml`); a
  config-level test fails when it differs from kargo-pipeline's `stages[].name` (same names, same order). Not read
  from the kargo-pipeline chart directly: the two charts are versioned and published independently. RBAC: list Environments, get/patch that one
  pipeline, in the org namespace only. A failed read exits before writing; terminating Environments are dropped
  (unblocks their deletion within one run); an Environment whose stage isn't a Kargo stage is skipped and fails the
  Job (config drift, e.g. an env renamed in Kargo only).
- **Where:** hub addon `openchoreo-types` = chart `openchoreo-app` with `mode: types`: the vendored
  ClusterComponentTypes/ClusterProjectType (the same files every ComponentRelease freezes), the shared
  `Project lab` (ClusterProjectType `default`, pipeline `default`) and the DeploymentPipeline + CronJob. A change to
  these templates is also new app Freight (the app Warehouses watch the chart); releases re-render unchanged.
- **Other readers of the pipeline:**
  - Project deletion: the Project finalizer takes the Environments whose cell namespaces it cleans up from the
    pipeline (`project/project_context.go` `findEnvironmentNamesFromDeploymentPipeline`). Once the CronJob drops a
    terminating Environment, a later Project deletion no longer cleans that cluster's namespace. That is fine while
    the cluster is going away with it; otherwise delete `dp-*` namespaces there by hand.
  - Promotion from the OpenChoreo UI/API/`occ`: openchoreo-api offers promotions along these paths, and one would
    move a ReleaseBinding past Kargo (no Freight, no verification, not in `rendered/*`, and Argo reverts it on the
    next sync of the bindings appset). #12/#17: restrict promote/ReleaseBinding writes for humans with OpenChoreo
    authz (AuthzRole/AuthzRoleBinding) so that Kargo + git stay the only promotion path.
- **Not here:** ReleaseBindings (#17). Note for #17: the data plane's cell namespace is owned by a
  `ProjectReleaseBinding` per (Project, Environment) (`internal/controller/renderedrelease/controller.go`: the
  data-plane apply never creates namespaces), so each worker also needs `ProjectReleaseBinding lab-<cluster>`
  (`spec.projectRelease` empty: the Project controller seeds it once) before any ReleaseBinding can land.
