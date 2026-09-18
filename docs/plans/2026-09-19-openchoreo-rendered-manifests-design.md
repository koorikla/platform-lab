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
- **Per-cluster identity in OpenBao:** the `cluster` chart renders a hub Job that (idempotently) enables
  `auth/k8s-<name>` (Kubernetes auth against the worker API from `<name>-kubeconfig`), a role bound to the worker's
  ESO ServiceAccount, and a policy limited to `secret/data/clusters/<name>/*`. A worker can read only its own secrets.
- **Birth kit (CAAPH, per worker):** ESO + the `hub-openbao` ClusterSecretStore + the ExternalSecrets for the agent
  identity + a TokenReview ClusterRoleBinding, installed before argocd-agent. ESO therefore leaves `worker-addons`.
- Lab simplifications (documented, prod path noted): OpenBao dev mode (in-memory, root token) and plain HTTP on the
  frontend; prod = HA storage, auto-unseal, TLS via cert-manager.
