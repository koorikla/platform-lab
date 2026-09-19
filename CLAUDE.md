# Context for AI-assisted work on this repo

## Goal
Enterprise-style GitOps lab. Management cluster (hub) runs Argo CD, argocd-agent principal, Cluster API, Kargo
(bundling Argo Rollouts for its verification), OpenChoreo control plane and manages itself — including its own CAPI
`Cluster` (self-hosted after a `clusterctl move` pivot from a throw-away k3d cluster). CAPI (k3s bootstrap/control-plane
provider; CAPD infra now, OpenStack and EKS later) creates worker clusters per env (dev/test/prod, N clusters per env).
Everything is k3s. Workers get argocd-agent injected at birth and are then driven from the hub. Everything declarative;
`bootstrap/` is the only imperative entrypoint.

## Invariants — do not break
1. **Cluster name == argocd-agent name == client-cert CN == Argo CD destination name == OpenChoreo planeID.**
2. `fleet/clusters/<env>/<name>.yaml` is the only place cluster facts live. Labels (`platform.lab/*`) flow from there
   to the CAPI Cluster and the Argo cluster secret. ApplicationSets never hardcode cluster names.
3. argocd-agent runs in **hybrid architecture + managed mode + destination-based mapping**:
   - hub keeps a full Argo CD (its app-controller reconciles only `in-cluster`: project `platform-mgmt`);
   - anything for workers must carry label `argocd-agent: "true"` (Application *and* its AppProject) and
     `destination.name: <cluster>`; agent cluster secrets carry `argocd.argoproj.io/skip-reconcile: "true"` (Argo CD >= 3.4).
4. Addons are **umbrella charts** in `repos/platform-charts/<addon>` (upstream chart as dependency, extra templates
   allowed; more than one upstream dependency only when they must land in the same sync — e.g. kargo + argo-rollouts).
   Config repo never contains templates, only `addon.yaml` + values.
   Not an addon, same chart rules: `worker-birth-kit` (CAAPH birth kit) bundles argo-cd + argocd-agent-agent +
   external-secrets because each worker gets exactly one release at birth, before any addon can reach it.
5. **Kargo writes only `rendered/*` branches; `main` holds no versions for promoted things.** A worker addon's version
   is the Freight (a `main` commit of its chart + config) rendered into `rendered/<stage>`; values: fleet < env, nothing
   per cluster. Anything per-cluster is identity only (cluster name), stamped by the CAAPH birth kit. Rings replace
   pins: run clusters ahead with `ring: canary` (stage `<env>-canary`). An app's version is its Freight (image tag x a
   `main` commit of `repos/apps/<app>/` or the `openchoreo-app` chart) rendered as a ComponentRelease into
   `rendered/<stage>:apps/<app>/release/`; `repos/apps/<app>/` holds no tag.
6. `repos/*` folders are future repositories: no relative references across them except via ApplicationSet
   `repoURL`/`$values`. Splitting = change repoURLs + drop the `repos/<x>/` path prefix.
7. CA private keys never leave the hub. Worker credentials are issued on the hub (cert-manager), written to the hub's
   OpenBao (`secret/clusters/<name>/*`, hub-local `PushSecret` → `ClusterSecretStore openbao`) and **pulled** by the
   worker's ESO (`ClusterSecretStore hub-openbao`, auth `k8s-<name>`: a worker can read only its own path). Nothing on
   the hub writes into a worker with the CAPI admin kubeconfig. Identity-bound worker components (agent, ESO, the
   OpenBao store + ExternalSecrets) are the CAAPH birth kit (chart `worker-birth-kit`, one HelmChartProxy in
   `fleet/base/helmchartproxies.yaml`), not worker-addons.
8. Enable/disable by file extension (`.yaml.disabled`), never by commenting blocks.

## Flow
bootstrap.sh → k3d `bootstrap` + cert-manager/capi-operator/capi-providers (same charts+values as GitOps, applied with
`helm template | kubectl apply`) → Cluster `mgmt` (`fleet/clusters/mgmt/mgmt.yaml`, role=management, ClusterClass
variable `managementCluster=true`: docker.sock in nodes + LB frontends :30443, :30820, :30843) → same CAPI stack on mgmt →
`clusterctl move -n fleet` → delete k3d → helm install `repos/platform-charts/argo-cd` (release `argocd`) → `root` app
(then `post`: `hack/init-rendered-branches.sh`, and `hack/kargo-deploy-key.sh` if gh is logged in and the secret is missing) →
`platform-config/argocd/*` → `mgmt-addons` appset (cert-manager, ESO, OpenBao, principal, capi-operator,
capi-providers, kargo + argo-rollouts, argo-cd itself) + `fleet-base` (ClusterClass, HelmChartProxies) + `fleet-clusters` appset →
`cluster` chart per file (agent client cert → hub PushSecret → OpenBao `secret/clusters/<name>/argocd-agent`; with the
OpenChoreo CRDs on the hub also `ClusterDataPlane`/`Environment <name>` + per-cluster OC agent CA, cert and gateway CA →
`secret/clusters/<name>/openchoreo-{agent,gateway-ca}`) → CAPI
builds k3s cluster → `openbao-fleet-sync` CronJob adds `auth/k8s-<name>` → CAAPH installs the birth kit (one release
`worker-birth-kit`: argo-cd controller/repo/redis, argocd-agent, ESO, store `hub-openbao` + agent ExternalSecrets) →
worker ESO pulls the cert via `mgmt-lb:30820` → agent dials `mgmt-lb:30443` (hub CAPD LB, `fleet/base/hub-lb.yaml`) →
ESO-rendered cluster secret makes the cluster selectable → `worker-addons` / `workloads` appsets generate labelled Applications → principal
ships them → worker reconciles. Worker addon content: a `main` commit touching the addon → Freight of Kargo project
`addon-<name>` (`kargo-addon-pipelines` appset) → stages `dev-canary → dev → test → prod` render fleet < env values into
`rendered/<stage>:addons/<name>/` → `worker-addons` syncs that folder by the cluster's env + ring. App content:
`repos/apps/<app>/app.yaml` → Kargo project `app-<app>` (`kargo-app-pipelines` appset), Freight = image tag x `main`
commit → same stages, task `render-app` renders `openchoreo-app` (mode=release) into
`rendered/<stage>:apps/<app>/release/` (branch/folder/file-name contract: header of `kargo/shared/render-app.yaml`).
Nothing syncs `apps/` until #17 (hub components/releases/bindings); meanwhile `workloads` still deploys the legacy
`repos/apps/<app>/chart` from `main` (image = that chart's default tag).

## Hub access
Context `mgmt` in ~/.kube/config (server = 127.0.0.1:<published port of container `mgmt-lb`>; bootstrap re-points it).
UIs: `make ui` (port-forwards: OpenChoreo `*.openchoreo.localhost:8080`, Argo CD :8090, Kargo :8091). Hub `Cluster` carries `Delete=false,Prune=false`.
Worker-facing hub ports on `mgmt-lb`: :30443 argocd-agent principal, :30820 OpenBao, :30843 OpenChoreo cluster gateway.
`make up` is resumable: `bootstrap/bootstrap.sh stage` prints the detected stage (fresh / bootstrap / hub-requested /
pivot-partial / pivoted / argo / orphan) and the steps left; a failed API read aborts rather than counting as absent.
`make down` never runs `kind delete`: Argo scaled to 0, workers deleted via CAPI and awaited, then containers labelled
`io.x-k8s.kind.cluster=mgmt`.
`make doctor` = preflight + health (read-only). Tests: `hack/tests/test_{boot,doctor}.sh` with fake tools (`fakebin.sh`).

## Verification status
Booted end to end on Docker Desktop (2026-09-19): k3d bootstrap → CAPI creates hub → `clusterctl move` (clusterctl
1.14.2 against operator-installed CAPI 1.12.11: works) → Argo CD adopts everything incl. `Cluster/mgmt`. Earlier run on
a k3d hub proved the worker path: CAPD k3s dev1 → CAAPH argo-cd + agent → ESO PushSecret → agent mTLS to principal →
`cert-manager-dev1`, `podinfo-dev1` Synced/Healthy via argocd-agent.
Fixed on first boot (see git log): k3s providers need `fetchConfig.url`; agent images only on quay (v0.10.0);
argo-helm NetworkPolicy blocks principal/agent → redis; PushSecret split (tls vs Opaque CA); Kargo ns label;
argocd-server https NodePort stole 30443; `curl get.k3s.io | sh` races kindest DNS (preK3sCommands wait);
k3s-agent Type=notify deadlocks CAPD bootstrap until timeout (~5 min, Type=exec drop-in); CRD-default drift
(server-side diff). `grep -rn VERIFY repos/` lists what is still inferred (mostly OpenChoreo).
Pull model (Phase 1b, 2026-09-19, dev1 reborn by deleting `Cluster/dev1`): OpenBao 2.6.2 dev mode on the hub,
`openbao-fleet-sync` ensured `auth/k8s-dev1`; birth kit only, no hub→worker writes. Timings from `Cluster` re-created
(00:43:27): CP node +30s, worker ESO Available +61s, agent ExternalSecrets synced +84s, agent authenticated to the
principal +89s, first workload pod (podinfo) +4m. Worker ESO token: reads `clusters/dev1/*` (200), `clusters/dev2/*`
and `clusters/mgmt/*` 403, write 403; other SAs can't log in. CAAPH retries `secret-bootstrap` (failed install →
upgrade) until ESO CRDs/webhook exist: ~40 revisions within a minute at birth, history capped at 10 — harmless.
(That was the 4-HCP kit; the `worker-birth-kit` umbrella (#2) installs in one pass: crds/ bootstrap copies + ESO
webhook `Ignore`.)

## Known lab constraints
- All CAPD nodes share the Docker VM disk: >90% used → DiskPressure evictions everywhere. Keep ≥25 GB free.
- CAPD nodes publish no host ports and the LB maps only 6443/8404 (hard-coded in CAPD, no API field): `make ui`
  port-forwards; hub API via `mgmt-lb`'s published 6443 (context `mgmt`). Hub pods resolve `*.openchoreo.localhost` to
  `openchoreo-control-plane/gateway-default:8080` (CoreDNS rewrite, `fleet/base/hub-coredns.yaml`): same URLs as browsers.
- k3s is downloaded at node boot (get.k3s.io) → workers need internet.
- CAPD renders the hub LB template (`fleet/base/hub-lb.yaml`) only on control-plane machine create/delete: after
  editing it on a running hub run `hack/hub-lb-reload.sh`.
- OpenBao is in-memory (dev mode): a pod restart empties it; postStart, fleet-sync (≤2 min) and PushSecrets (1 min)
  refill it. Workers keep their already-synced secrets meanwhile. Generated sources (`openbao/openchoreo-*`) are k8s
  Secrets and survive a restart.
- Hardening gap: `openbao-fleet-sync` may `get` every Secret in `openbao` (its CA names are dynamic), including the
  generated `openchoreo-*` sources. It can already escalate inside OpenBao (`cluster-*` policy bodies), so treat that
  SA as sensitive.

## Backlog
Lives in **GitHub issues** (koorikla/platform-lab, labels `status:*`, `phase:*`, `area:*`, `needs-lab`). Work them with
the project skill `.claude/skills/platform-lab-issue` (worktree branch → TDD → PR → coordinator review/merge → live
verification under `hack/lab-lock.sh`). Design/plan background: `docs/plans/`.

## Conventions
Minimal readable YAML; comments explain *why*. Label prefix `platform.lab/`. Namespaces: `argocd`, `fleet`, `kargo`.
New addon = umbrella chart + `addons/<scope>/<name>/{addon.yaml,values.yaml}` (+ optional `envs/<env>.values.yaml`
for workers; nothing else in a worker addon folder, `make test` checks).
New cluster = one file in `fleet/clusters/<env>/`.
New app = `repos/apps/<app>/app.yaml` (openchoreo-app values: name == folder, `image.repository`, optional
`image.constraint` for the Warehouse) + optional `envs/<env>/values.yaml`; no tag anywhere (`make test` checks).
New ClusterClass / CAPI provider = `fleet/base/clusterclasses/<class>.yaml` + a `capi-providers` toggle (disabled
examples: `k3s-openstack`, `eks`; recipe and per-provider differences in CONTRIBUTING.md).
Worker addons sync plain YAML from Kargo's `rendered/<env>[-canary]:addons/<addon>/` (`worker-addons` appset, branch
from cluster labels `platform.lab/env` + `platform.lab/ring`). Disable one = rename `addon.yaml` → `.disabled` on main:
its Application and Kargo pipeline go, the workload stays (`preserveResourcesOnDeletion`; delete it by hand if it must
go). Once Kargo project `addon-<addon>` is gone (a running promotion could re-push the folder), `make rendered-prune`
(dry run) / `make rendered-prune APPLY=1` removes the stale `addons/<addon>` from every `rendered/*` branch — the one
documented cleanup besides Kargo that writes those branches (it pushes directly, so prod needs a PR once PR-gated).
A `ring: canary` cluster needs a `<env>-canary` stage in kargo-pipeline (`hack/lint.sh` checks). dev2 is dev's canary
ring; stage `dev` auto-promotes only Freight verified in `dev-canary`: every addon stage runs AnalysisTemplate
`argocd-apps` (its Applications Synced + Healthy at the promoted rendered commit for a streak; no clusters = passes,
except on a canary stage; CONTRIBUTING.md). App pipelines have no verification until apps are deployed (#17/#18):
their `dev` takes Freight after `appSoak` (15 min) in `dev-canary`.
Worker-addon apps carry `platform.lab/ring` but stay auto-sync: RollingSync works through the agent but is off by
decision (costs selfHeal) — why and how to enable: design doc addendum "progressive sync" (#27).
Disabling (`.disabled`) leaves an addon's/cluster's resources running; removal is manual: CONTRIBUTING.md "Disabling".
