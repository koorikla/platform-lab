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
   Config repo never contains templates, only `addon.yaml` + values + rollout pins.
5. Version precedence for worker addons: cluster pin > env pin. Values: fleet < env < cluster. Kargo only ever writes
   `envs/<env>.yaml` (addons) or `envs/<env>/values.yaml` (apps).
6. `repos/*` folders are future repositories: no relative references across them except via ApplicationSet
   `repoURL`/`$values`. Splitting = change repoURLs + drop the `repos/<x>/` path prefix.
7. CA private keys never leave the hub. Worker credentials are issued on the hub (cert-manager), written to the hub's
   OpenBao (`secret/clusters/<name>/*`, hub-local `PushSecret` → `ClusterSecretStore openbao`) and **pulled** by the
   worker's ESO (`ClusterSecretStore hub-openbao`, auth `k8s-<name>`: a worker can read only its own path). Nothing on
   the hub writes into a worker with the CAPI admin kubeconfig. Identity-bound worker components (agent, ESO, the
   OpenBao store + ExternalSecrets) are the CAAPH birth kit (`fleet/base/helmchartproxies.yaml`), not worker-addons.
8. Enable/disable by file extension (`.yaml.disabled`), never by commenting blocks.

## Flow
bootstrap.sh → k3d `bootstrap` + cert-manager/capi-operator/capi-providers (same charts+values as GitOps, applied with
`helm template | kubectl apply`) → Cluster `mgmt` (`fleet/clusters/mgmt/mgmt.yaml`, role=management, ClusterClass
variable `managementCluster=true`: docker.sock in nodes + LB frontends :30443, :30820) → same CAPI stack on mgmt →
`clusterctl move -n fleet` → delete k3d → helm install `repos/platform-charts/argo-cd` (release `argocd`) → `root` app →
`platform-config/argocd/*` → `mgmt-addons` appset (cert-manager, ESO, OpenBao, principal, capi-operator,
capi-providers, kargo + argo-rollouts, argo-cd itself) + `fleet-base` (ClusterClass, HelmChartProxies) + `fleet-clusters` appset →
`cluster` chart per file (agent client cert → hub PushSecret → OpenBao `secret/clusters/<name>/argocd-agent`) → CAPI
builds k3s cluster → `openbao-fleet-sync` CronJob adds `auth/k8s-<name>` → CAAPH birth kit installs argo-cd
(controller/repo/redis), argocd-agent, ESO and `secret-bootstrap` (store `hub-openbao` + agent ExternalSecrets) →
worker ESO pulls the cert via `mgmt-lb:30820` → agent dials `mgmt-lb:30443` (hub CAPD LB, `fleet/base/hub-lb.yaml`) →
ESO-rendered cluster secret makes the cluster selectable → `worker-addons` / `workloads` appsets generate labelled Applications → principal
ships them → worker reconciles.

## Hub access
Context `mgmt` in ~/.kube/config (server = 127.0.0.1:<published port of container `mgmt-lb`>; bootstrap re-points it).
UIs: `make ui` (port-forwards; CAPD nodes publish no host ports). Hub `Cluster` carries `Delete=false,Prune=false`.

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

## Known lab constraints
- All CAPD nodes share the Docker VM disk: >90% used → DiskPressure evictions everywhere. Keep ≥25 GB free.
- CAPD nodes publish no host ports: `make ui` port-forwards; hub API via `mgmt-lb`'s published 6443 (context `mgmt`).
- k3s is downloaded at node boot (get.k3s.io) → workers need internet.
- CAPD renders the hub LB template (`fleet/base/hub-lb.yaml`) only on control-plane machine create/delete: after
  editing it on a running hub run `hack/hub-lb-reload.sh`.
- OpenBao is in-memory (dev mode): a pod restart empties it; postStart, fleet-sync (≤2 min) and PushSecrets (1 min)
  refill it. Workers keep their already-synced secrets meanwhile.

## Backlog (ordered)
1. Harden the boot: `make up` should be re-runnable after partial failure (bootstrap cluster already has `mgmt`;
   hub exists but Argo not yet installed); `make down` tested only by hand.
2. Enable dev2, prove env-wide vs single-cluster pinning (`rollout.clusters.dev2`). Then enable test1/prod1.
3. Kargo: git creds via ESO; second pipeline promoting `rollout.chartRevision` of worker addons (Warehouse on git tags
   of platform-charts); prod stage via `git-open-pr` + `git-wait-for-pr`; verification (AnalysisTemplate) per stage.
   Rendered manifests follow-ups:
   - disabling an addon leaves `rendered/<branch>:addons/<x>/` behind → until Task 1.5 automates it,
     `git rm -r addons/<x>` on each `rendered/*` branch by hand;
   - tooling-only changes (`kargo/shared/`) make no Freight → re-promote by hand to re-render;
   - one push changing an Application's spec *and* its content can race: the auto-sync captures the old spec and
     retries it until the limit → `argocd app terminate-op <app>`.
4. Publish umbrella charts to OCI (ghcr) with CI; switch appsets from git-path to `chart:` + semver, and point
   HelmChartProxies at the umbrellas. Per-env HelmChartProxies so agent upgrades are staged too.
5. OpenChoreo (phase 2) — enable `kgateway`, `openchoreo-control-plane` (hub), `kgateway`, `openchoreo-data-plane`
   (workers), `openchoreo.enabled` in cluster files. Missing pieces:
   - Gateway API CRDs v1.5.1 (no chart upstream → small CRD chart or kustomize app), ThunderID, OpenChoreo seeds in
     OpenBao (hub, `addons/management/openbao`) + `ClusterSecretStore/default`, hostnames/TLS for the lab, default resources (Project, Environments, DeploymentPipeline).
   - **OpenChoreo trust, declaratively**: upstream flow extracts the agent's self-signed CA by hand. Target design:
     issue `cluster-agent-tls` on the hub from a dedicated CA, PushSecret it to OpenBao
     (`secret/clusters/<name>/…`) and pull it into `openchoreo-data-plane` with a birth-kit ExternalSecret
     (`clusterAgent.tls.generateCerts=false`), and reference that CA in `DataPlane.spec.clusterAgent.clientCA`
     (check whether the CRD supports `secretRef`; see upstream "mTLS with External CA" guide). The gateway server CA
     must land on the worker as ConfigMap `cluster-gateway-ca` (ESO generic target / `target.manifest: ConfigMap`).
   - per-cluster `clusterAgent.planeId` (= cluster name): add an appset `helm.parameters` hook or per-cluster values.
   - Decide ownership between OpenChoreo deployment pipelines and Kargo for app promotion.
   - Requires Kubernetes >= 1.34 (k3s version in fleet files already is).
6. Istio ambient on hub (chart ready, disabled), then multi-cluster ambient east-west if wanted.
7. Providers: `k3s-openstack` ClusterClass (CAPO + k3s), EKS ClusterClass (CAPA managed control plane, no k3s);
   only `clusterClass`, `provider`, `variables` change in a cluster file. (Hub pivot/self-hosting: done.)
8. Hardening: Kargo admin secret, principal `jwt.allowGenerate`, AppProject `sourceRepos`, RBAC, NetworkPolicies,
   AppSet progressive sync (RollingSync by `platform.lab/env`) as a guard rail besides Kargo. OpenBao prod mode (raft
   PVC, auto-unseal, TLS on :30820 or a gateway); fleet-sync reads whole CAPI kubeconfigs (only server + CA needed).

9. Team template (see docs/plans/ addendum): CI (lint/test/kubeconform), CODEOWNERS, CONTRIBUTING recipes, Renovate,
   provider extension points; **Backstage template "new Helm chart repo"** (pre-commit helm lint + conventional
   commits, semver releases, GitLab CI pushing to Artifactory).

## Conventions
Minimal readable YAML; comments explain *why*. Label prefix `platform.lab/`. Namespaces: `argocd`, `fleet`, `kargo`.
New addon = umbrella chart + `addons/<scope>/<name>/{addon.yaml,values.yaml}` (+ `envs/*.yaml` for workers).
New cluster = one file in `fleet/clusters/<env>/`.
