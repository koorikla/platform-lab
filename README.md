# platform-lab

Declarative multi-cluster Kubernetes lab: **Cluster API (k3s provider)** builds the fleet, **Argo CD + argocd-agent**
delivers to it, **Kargo** promotes across environments, **OpenChoreo** is the developer platform on top.

```mermaid
flowchart LR
  subgraph mgmt["mgmt (k3s via CAPI, self-hosted) — hub"]
    argo["Argo CD (full) + appsets"]
    principal["argocd-agent principal"]
    capi["CAPI operator: core, k3s, CAPD, CAAPH"]
    kargo[Kargo]
    eso["cert-manager + ESO"]
    oc["OpenChoreo control plane (phase 2)"]
  end
  subgraph dev1["dev1 (k3s via CAPI)"]
    agent["argocd-agent (managed)"]
    ctrl["app-controller + repo-server + redis"]
    dp["OpenChoreo data plane (phase 2)"]
  end
  git[(git)] --> argo
  argo -->|"cluster chart"| capi -->|"Cluster + HelmChartProxy"| dev1
  eso -->|"PushSecret: agent client cert"| agent
  agent -->|"gRPC mTLS :30443"| principal
  argo -->|"Applications labelled argocd-agent=true"| principal
  kargo -->|"commit envs/<env>"| git
```

## Layout

Top-level folders under `repos/` simulate separate git repositories (split later without changing paths inside them).

| Path | Future repo | Owns |
|---|---|---|
| `bootstrap/` | platform-config | the only imperative bit: k3d → CAPI builds hub → `clusterctl move` → Argo CD + root app |
| `repos/platform-charts/` | one repo (or one per chart) | umbrella Helm charts, 1 per addon, + local charts `cluster`, `capi-providers` |
| `repos/platform-config/argocd/` | platform-config | AppProjects, ApplicationSets (root app points here) |
| `repos/platform-config/addons/{management,workers}/` | platform-config | which addon, which version, which values — per fleet / env / cluster |
| `repos/platform-config/fleet/` | platform-config | ClusterClasses, CAAPH HelmChartProxies, one file per cluster |
| `repos/platform-config/kargo/` | platform-config | Kargo projects, warehouses, stages |
| `repos/apps/` | app team repos | workloads: `chart/` + `envs/<env>/values.yaml` |

## How targeting works

`fleet/clusters/<env>/<name>.yaml` is the single source of truth for a cluster. The `cluster` chart stamps the same
`platform.lab/{name,env,role,provider,region}` labels on the CAPI `Cluster` **and** on the Argo CD cluster secret it
mints for the agent. ApplicationSets select on those labels:

| Scope | Where you change it |
|---|---|
| whole env (dev1, dev2, …) | `addons/workers/<addon>/envs/<env>.yaml` → `rollout.chartRevision`; values in `envs/<env>.values.yaml` |
| one cluster | same file → `rollout.clusters.<cluster>.chartRevision`; values in `clusters/<cluster>.values.yaml` |
| whole fleet | `addons/workers/<addon>/values.yaml`, or the chart itself |
| apps | `repos/apps/<app>/envs/<env>/values.yaml` (Kargo writes), `clusters/<cluster>/values.yaml` for one cluster |

Enable/disable anything file-driven by renaming `*.yaml` ⇄ `*.yaml.disabled` (test1, prod1, dev2, OpenChoreo, Istio ship disabled).

## Run

```bash
# 0. push this repo, then point manifests at it (default: github.com/koorikla/platform-lab)
make set-repo REPO=https://github.com/<you>/<repo>.git && git commit -am "set repo" && git push
# 1. needs: docker, k3d, kubectl, helm, clusterctl
make up        # k3d bootstrap -> CAPI creates hub 'mgmt' -> clusterctl move (hub manages itself) -> Argo CD
make status
make ui        # Argo CD :8080, Kargo :8081
make kubeconfig CLUSTER=dev1 > dev1.kubeconfig
```

Linux hosts running several CAPD clusters usually need
`sysctl fs.inotify.max_user_watches=1048576 fs.inotify.max_user_instances=8192`.

Kargo needs git push credentials: see `repos/platform-config/kargo/podinfo/git-credentials.yaml.example`.

## Status

Scaffold — **not yet run end to end**. Open items and everything marked `# VERIFY` are tracked in [CLAUDE.md](CLAUDE.md).
