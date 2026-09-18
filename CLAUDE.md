# Context for AI-assisted work on this repo

## Goal
Enterprise-style GitOps lab. Management cluster (hub) runs Argo CD, argocd-agent principal, Cluster API, Kargo,
OpenChoreo control plane and manages itself. CAPI (k3s bootstrap/control-plane provider; CAPD infra now, OpenStack and
EKS later) creates worker clusters per env (dev/test/prod, N clusters per env). Workers get argocd-agent injected at
birth and are then driven from the hub. Everything declarative; `bootstrap/` is the only imperative entrypoint.

## Invariants — do not break
1. **Cluster name == argocd-agent name == client-cert CN == Argo CD destination name == OpenChoreo planeID.**
2. `fleet/clusters/<env>/<name>.yaml` is the only place cluster facts live. Labels (`platform.lab/*`) flow from there
   to the CAPI Cluster and the Argo cluster secret. ApplicationSets never hardcode cluster names.
3. argocd-agent runs in **hybrid architecture + managed mode + destination-based mapping**:
   - hub keeps a full Argo CD (its app-controller reconciles only `in-cluster`: project `platform-mgmt`);
   - anything for workers must carry label `argocd-agent: "true"` (Application *and* its AppProject) and
     `destination.name: <cluster>`; agent cluster secrets carry `argocd.argoproj.io/skip-reconcile: "true"` (Argo CD >= 3.4).
4. Addons are **umbrella charts** in `repos/platform-charts/<addon>` (upstream chart as dependency, extra templates
   allowed). Config repo never contains templates, only `addon.yaml` + values + rollout pins.
5. Version precedence for worker addons: cluster pin > env pin. Values: fleet < env < cluster. Kargo only ever writes
   `envs/<env>.yaml` (addons) or `envs/<env>/values.yaml` (apps).
6. `repos/*` folders are future repositories: no relative references across them except via ApplicationSet
   `repoURL`/`$values`. Splitting = change repoURLs + drop the `repos/<x>/` path prefix.
7. CA private keys never leave the hub. Worker credentials are issued on the hub (cert-manager) and pushed with ESO
   `PushSecret` through the CAPI-generated kubeconfig (`<name>-kubeconfig`, key `value`).
8. Enable/disable by file extension (`.yaml.disabled`), never by commenting blocks.

## Flow
bootstrap.sh → kind `mgmt` → helm install `repos/platform-charts/argo-cd` (release `argocd`) → `root` app →
`platform-config/argocd/*` → `mgmt-addons` appset (cert-manager, ESO, principal, capi-operator, capi-providers, kargo,
argo-cd itself) + `fleet-base` (ClusterClass, HelmChartProxies) + `fleet-clusters` appset → `cluster` chart per file →
CAPI builds k3s cluster → CAAPH installs argo-cd (controller/repo/redis) + argocd-agent → ESO pushes client cert →
agent dials `mgmt-control-plane:30443` → ESO-rendered cluster secret makes the cluster selectable →
`worker-addons` / `workloads` appsets generate labelled Applications → principal ships them → worker reconciles.

## Verification status
Checked against upstream sources (2026-09): argocd-agent v0.9/v0.10 docs + helm values (principal 0.3.3, agent 0.2.7),
cluster-api-k3s v0.4.0 samples (v1beta1 contract, built on CAPI 1.11 → core pinned to 1.12.x, NOT 1.14),
OpenChoreo v1.2.5 multi-cluster guide, latest tags of argo-helm, kargo, cert-manager, ESO, CAAPH, capi-operator, istio.
**Nothing has been rendered with helm or applied to a cluster yet.** Start with `make lint`, then `make up`.
`grep -rn VERIFY repos/` lists every value that was inferred rather than confirmed.

## Backlog (ordered)
1. First boot: `make lint`, `make up`, fix what breaks. Expected friction points:
   - capi-operator resolving provider name `k3s` (else set `fetchConfig.url`, commented in `capi-providers`);
   - worker pods resolving `mgmt-control-plane` (kindest/node entrypoint should fix DNS; fallback: `hostAliases` in agent values);
   - principal chart: redis/redis-proxy TLS defaults changed in v0.8+ (`principal.redis.tls`, `argocd-redis-proxy-tls`);
   - ESO kubernetes provider `authRef` with CAPD kubeconfig (server = docker LB container IP, reachable from mgmt pods?);
   - argo-cd chart worker profile: is `server.replicas: 0` / `applicationSet.replicas: 0` still the way to disable;
   - multi-source Applications with `$values` through the agent (worker repo-server needs repo access: public = fine,
     private = project-scoped repo secret labelled `argocd-agent=true`).
2. Enable dev2, prove env-wide vs single-cluster pinning (`rollout.clusters.dev2`). Then enable test1/prod1.
3. Kargo: git creds via ESO; second pipeline promoting `rollout.chartRevision` of worker addons (Warehouse on git tags
   of platform-charts); prod stage via `git-open-pr` + `git-wait-for-pr`; verification (AnalysisTemplate) per stage.
4. Publish umbrella charts to OCI (ghcr) with CI; switch appsets from git-path to `chart:` + semver, and point
   HelmChartProxies at the umbrellas. Per-env HelmChartProxies so agent upgrades are staged too.
5. OpenChoreo (phase 2) — enable `kgateway`, `openchoreo-control-plane` (hub), `kgateway`, `openchoreo-data-plane`
   (workers), `openchoreo.enabled` in cluster files. Missing pieces:
   - Gateway API CRDs v1.5.1 (no chart upstream → small CRD chart or kustomize app), ThunderID, OpenBao +
     `ClusterSecretStore/default`, hostnames/TLS for the lab, default resources (Project, Environments, DeploymentPipeline).
   - **OpenChoreo trust, declaratively**: upstream flow extracts the agent's self-signed CA by hand. Target design:
     issue `cluster-agent-tls` on the hub from a dedicated CA, PushSecret it to `openchoreo-data-plane` on the worker
     (`clusterAgent.tls.generateCerts=false`), and reference that CA in `DataPlane.spec.clusterAgent.clientCA`
     (check whether the CRD supports `secretRef`; see upstream "mTLS with External CA" guide). The gateway server CA
     must land on the worker as ConfigMap `cluster-gateway-ca` (PushSecret makes Secrets → needs a converter or chart support).
   - per-cluster `clusterAgent.planeId` (= cluster name): add an appset `helm.parameters` hook or per-cluster values.
   - Decide ownership between OpenChoreo deployment pipelines and Kargo for app promotion.
   - Requires Kubernetes >= 1.34 (k3s version in fleet files already is).
6. Istio ambient on hub (chart ready, disabled), then multi-cluster ambient east-west if wanted.
7. Providers: `k3s-openstack` ClusterClass (CAPO + k3s), EKS ClusterClass (CAPA managed control plane, no k3s);
   only `clusterClass`, `provider`, `variables` change in a cluster file. Move hub off kind (CAPI pivot / self-hosted).
8. Hardening: Kargo admin secret, principal `jwt.allowGenerate`, AppProject `sourceRepos`, RBAC, NetworkPolicies,
   AppSet progressive sync (RollingSync by `platform.lab/env`) as a guard rail besides Kargo.

## Conventions
Minimal readable YAML; comments explain *why*. Label prefix `platform.lab/`. Namespaces: `argocd`, `fleet`, `kargo`.
New addon = umbrella chart + `addons/<scope>/<name>/{addon.yaml,values.yaml}` (+ `envs/*.yaml` for workers).
New cluster = one file in `fleet/clusters/<env>/`.
