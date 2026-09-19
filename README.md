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
    bao["OpenBao (secret/clusters/&lt;name&gt;)"]
    oc["OpenChoreo control plane + Thunder"]
  end
  subgraph dev1["dev1 (k3s via CAPI)"]
    agent["argocd-agent (managed)"]
    weso["ESO (birth kit)"]
    ctrl["app-controller + repo-server + redis"]
    dp["OpenChoreo cluster-agent + gateway (worker addon)"]
  end
  git[(git)] --> argo
  argo -->|"cluster chart"| capi -->|"Cluster + HelmChartProxy"| dev1
  eso -->|"PushSecret: agent client cert"| bao
  weso -->|"pulls its own path :30820"| bao
  weso -->|"argocd-agent-client-tls"| agent
  weso -->|"cluster-agent-tls (cert + plane-id)"| dp
  dp -->|"wss mTLS :30843"| oc
  agent -->|"gRPC mTLS :30443"| principal
  argo -->|"Applications labelled argocd-agent=true"| principal
  kargo -->|"render to rendered/<stage>"| git
```

## Layout

Top-level folders under `repos/` simulate separate git repositories (split later without changing paths inside them).

| Path | Future repo | Owns |
|---|---|---|
| `bootstrap/` | platform-config | the only imperative bit: k3d → CAPI builds hub → `clusterctl move` → Argo CD + root app |
| `repos/platform-charts/` | one repo (or one per chart) | umbrella Helm charts, 1 per addon, + local charts `cluster`, `capi-providers` |
| `repos/platform-config/argocd/` | platform-config | AppProjects, ApplicationSets (root app points here) |
| `repos/platform-config/addons/{management,workers}/` | platform-config | which addon, which values — per fleet / env (worker addon versions travel as Kargo Freight) |
| `repos/platform-config/fleet/` | platform-config | ClusterClasses, CAAPH HelmChartProxies, one file per cluster |
| `repos/platform-config/kargo/` | platform-config | shared Kargo promotion tasks (`render-addon`, `render-app`); the per-addon/app pipelines come from the `kargo-pipeline` chart |
| `repos/apps/` | app team repos | OpenChoreo apps: `app.yaml` + `envs/<env>/values.yaml`, no versions (legacy `chart/` until #17) |

## How targeting works

`fleet/clusters/<env>/<name>.yaml` is the single source of truth for a cluster. The `cluster` chart stamps the same
`platform.lab/{name,env,role,provider,region}` labels on the CAPI `Cluster` **and** on the Argo CD cluster secret it
mints for the agent. ApplicationSets select on those labels:

Worker addons carry no version on `main`: a merge touching an addon's chart or config becomes Kargo Freight, and each
promotion renders it into `rendered/<stage>`. A cluster follows `rendered/<env>`, or `rendered/<env>-canary` if it is
in the canary ring. Rings replace per-cluster pins: nothing is rendered per cluster.

| Scope | Where you change it |
|---|---|
| whole fleet | `addons/workers/<addon>/values.yaml`, or the chart itself; reaches each env by promotion |
| whole env (dev1, dev2, …) | values in `addons/workers/<addon>/envs/<env>.values.yaml`; version = the Freight promoted to that env's stage |
| clusters ahead of their env | `ring: canary` in their fleet file → they follow stage `<env>-canary`, promoted before `<env>` (dev2 in the lab; `dev` follows once Kargo verified the canary Synced + Healthy at the new commit) |
| one cluster's identity | CAAPH birth kit (`fleet/base/helmchartproxies.yaml`, cluster name via `valuesTemplate`) |
| apps | `repos/apps/<app>/app.yaml` (fleet) and `envs/<env>/values.yaml` (env); version = the Freight (image tag) promoted to the stage, rendered to `rendered/<stage>:apps/<app>/`; clusters ahead via the ring, as above |

Enable/disable anything file-driven by renaming `*.yaml` ⇄ `*.yaml.disabled` (nit1, sit1, prod1, OpenChoreo, Istio ship disabled).

## Run

```bash
# 0. push this repo, then point manifests at it (default: github.com/koorikla/platform-lab)
make set-repo REPO=https://github.com/<you>/<repo>.git && git commit -am "set repo" && git push
# 1. needs: docker, k3d, kubectl, helm, clusterctl (+ gh for the Kargo deploy key)
make doctor    # free Docker disk (>= 25 GB), memory, CPUs, load, tool versions, inotify, boot stage, hub, lab lock
make up        # k3d bootstrap -> CAPI creates hub 'mgmt' -> clusterctl move (hub manages itself) -> Argo CD
               # -> rendered/* branches + Kargo deploy key. Re-run after a failure: resumes at the detected stage
make status
make ui        # Argo CD :8090 (admin / make argocd-password), Kargo :8091 (admin / make kargo-password),
               # OpenChoreo http://openchoreo.localhost:8080 (Thunder login: upstream demo users,
               # e.g. admin@openchoreo.dev, see repos/platform-charts/thunder/values.yaml)
make kubeconfig CLUSTER=dev1 > dev1.kubeconfig
make down      # workers via CAPI (waits for their containers), then the hub's containers; FORCE=1 if the hub is gone
```

`make ui` port-forwards, because the CAPD hub publishes no usable host ports (its LB container maps only 6443 and
8404, hard-coded in CAPD). OpenChoreo hosts (`openchoreo.localhost`, `api.`, `thunder.`…`.openchoreo.localhost`) all go
to the control-plane gateway on :8080, which routes by Host. Browsers resolve `*.localhost` to loopback (Chrome,
Firefox); for others add `127.0.0.1 openchoreo.localhost api.openchoreo.localhost thunder.openchoreo.localhost` to
`/etc/hosts`. Pods on the hub use the same URLs: CoreDNS rewrites `*.openchoreo.localhost` to
`gateway-default.openchoreo-control-plane.svc` (`fleet/base/hub-coredns.yaml`), so issuer URLs match on both sides.

Linux hosts running several CAPD clusters usually need
`sysctl fs.inotify.max_user_watches=1048576 fs.inotify.max_user_instances=8192`.

Kargo needs git push credentials: `hack/kargo-deploy-key.sh` (repo-scoped deploy key, straight into a hub Secret).
`make up` runs it when `gh` is logged in and the hub has no such Secret yet. It **replaces** the repo's
`kargo-platform-lab` key, so on a shared repo (e.g. without `make set-repo` to your fork) it cuts off every other lab's
Kargo: log out of `gh` or skip it if that isn't yours to rotate.

SSO: Argo CD and Kargo log in via Thunder (OIDC, public clients with PKCE, no client secret). Thunder groups map to
roles: `admins` → admin in both; `platform-engineers` → Argo CD `role:platform-engineer` (full
Application/ApplicationSet rights in `platform-workers` and `workloads`; in the hub's own `platform-mgmt` only sync
and resource actions; read-only elsewhere) and Kargo admin; `developers`, `sres` → read-only in both. SSO needs
the OpenChoreo gateway, because the issuer `http://thunder.openchoreo.localhost:8080` must resolve in the browser
(through `make ui`'s 8080 forward) and in the hub pods (through the CoreDNS rewrite). The local `admin` accounts stay
as break-glass, with the passwords above, and keep working when Thunder is down.

## Working on this repo

Backlog = [GitHub issues](https://github.com/koorikla/platform-lab/issues). How work flows (claim → worktree branch →
tests → PR → review → live verification under `hack/lab-lock.sh`) and recipes for adding a cluster, addon, app or
provider: [CONTRIBUTING.md](CONTRIBUTING.md). Agents use the skill in
[`.claude/skills/platform-lab-issue`](.claude/skills/platform-lab-issue/SKILL.md). Invariants: [CLAUDE.md](CLAUDE.md).

## Status

Boots end to end on Docker Desktop (CAPI pivot + agent path verified). Open items are GitHub issues; `grep -rn VERIFY repos/` lists values still inferred rather than confirmed. Docker Desktop needs ≥25 GB free disk plus 8 CPUs / 8 GB for hub + one worker, 12 CPUs / 16 GB for the full lab (hub + dev1 + dev2 + OpenChoreo; `make doctor` warns below).
