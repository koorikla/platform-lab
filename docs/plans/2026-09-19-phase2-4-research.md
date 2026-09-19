# Phase 2–4 facts (OpenChoreo 1.2.5, Thunder, OpenBao, Gateway API, Argo CD / Kargo OIDC, secrets)

Researched 2026-09-19. Read-only. Charts pulled/rendered into `scratchpad/p24/` (`openchoreo-control-plane`, `openchoreo-data-plane`,
`thunder`, `openbao`, `egc/*` = envoyproxy gateway-crds-helm, rendered outputs `cp-rendered.yaml`, `dp-rendered.yaml`,
`thunder-rendered.yaml`, `openbao-rendered.yaml`, `gwapi-std-v1.5.1.yaml`).
Short refs: `oc/` = openchoreo repo @ v1.2.5, `site/…v1.2.x` = docs, `ch/kargo` = kargo chart 1.11.4, `charts/argo-cd` = argo-helm 10.9.2,
`agent-v0.10.0/` = argocd-agent source, gitops-engine = `argoproj/argo-cd@master:gitops-engine/pkg/…`.

## Corrections to the plan (read these first)

1. **The Thunder chart deadlocks under Argo CD on the hub as shipped.** Its PVC `thunder-database-pvc` is a `pre-install` hook (weight -15)
   with no delete policy. Argo maps it to a PreSync hook with the default policy `BeforeHookCreation`, and waits until the hook is healthy.
   The hub StorageClass `local-path` is `WaitForFirstConsumer`, so the PVC stays Pending (Argo reads that as Progressing, meaning the
   hook is still running). Nothing in wave -5 (the setup Job, the first consumer) is ever created. Two changes are needed:
   `persistence.annotations: {helm.sh/hook-delete-policy: hook-failed}` and a PVC health override. See §C.
2. **There is no `thunder-admin-credentials` Secret** (Task 2.4 check is wrong). Thunder console admin is `admin`/`admin`, hardcoded in the
   image's `bootstrap/01-default-resources.sh`. The OpenChoreo login is `admin@openchoreo.dev` / `Admin@123`, a literal in values-thunder.
3. **`ClusterDataPlane.spec.secretStoreRef` names a ClusterSecretStore *on the data-plane (worker) cluster*** (CRD description: "Name of the
   ClusterSecretStore resource in the data plane cluster"). It is optional (CRD `required: [clusterAgent, planeID]`). The upstream
   multi-cluster README installs OpenBao **on the DP cluster** and creates `backstage-secrets` on the CP cluster with plain
   `kubectl create secret`. A hub-side `ClusterSecretStore/default` (Task 2.3) only serves hub ExternalSecrets such as backstage-secrets.
   Either omit `secretStoreRef` in the cluster chart, or give each worker its own `ClusterSecretStore default`.
4. **DP gateway port mismatch.** Upstream `values-dp.yaml` sets `gateway.httpPort: 19080` (the k3d host port). The plan's ClusterDataPlane
   uses `port: 80`. Keep the chart default 80 (don't copy 19080), or set both sides to the same value.
5. **Task 2.1 is unnecessary.** `oci://docker.io/envoyproxy/gateway-crds-helm` **v1.8.2** with
   `crds.gatewayAPI.enabled=true, crds.gatewayAPI.channel=standard` renders a CRD `spec` that is byte-identical to Gateway API v1.5.1
   `standard-install.yaml`: same 8 CRDs plus the `safe-upgrades` ValidatingAdmissionPolicy and its binding. See §F.
   `kgateway-crds` v2.3.1 does **not** contain Gateway API CRDs.
6. **Groups.** OpenChoreo's built-in authz mappings (CP values `openchoreoApi.config.security.authorization.bootstrap.mappings`) bind
   Thunder groups `admins`, `developers`, `platform-engineers`, `sres` (claim `groups`). Reuse these names for Argo CD and Kargo instead of
   inventing `platform-admins` / `app-developers`, which would mean overriding the long bootstrap mapping list.
7. **The `cluster-gateway-ca` ConfigMap in the hub's CP namespace is a chart-rendered placeholder.** Upstream overwrites it with kubectl. Under
   Argo it would be reverted, and nothing on the hub mounts it: controller-manager and openchoreo-api mount the **Secret**. Leave it alone.
   Workers get their own ConfigMap (§E).
8. `backstage-secrets` needs **`jenkins-api-key`** as well: the env var is not optional and not guarded by `if`.

---

## A. openchoreo-control-plane 1.2.5 (`helm show values …`, 4329 lines; appVersion v1.2.5; CRDs in `crds/`)

### clusterGateway (exact defaults)
```yaml
clusterGateway:
  name: cluster-gateway
  port: 8443                      # container websocket port
  service:
    type: ClusterIP               # -> Service "cluster-gateway-external" (8443 only). "cluster-gateway" is always ClusterIP (8443 + internal-api 8444)
    port: 8443
    nodePort: null                # rendered only when type == NodePort
    loadBalancerIP: null
    clusterIP: null
  tlsRoute:
    enabled: false                # renders TLSRoute (gateway.networking.k8s.io/v1) only if also gateway.enabled; adds a tls-passthrough listener on gateway.httpsPort
    hosts: []                     # [{host: ...}]
  tls:
    enabled: true
    secretName: cluster-gateway-tls
    existingSecret: ""            # if set: no CA/Issuer/Certificate/placeholder CM rendered; must contain tls.crt, tls.key, ca.crt
    skipClientCertVerify: false
    issuerRef: { kind: Issuer, name: cluster-gateway-selfsigned-issuer }   # chart renders an Issuer with THIS name: spec.ca.secretName: cluster-gateway-ca
    dnsNames: [cluster-gateway.openchoreo-control-plane.svc, cluster-gateway.openchoreo-control-plane.svc.cluster.local]
    duration: 2160h
    renewBefore: 360h
  internalMtls: { enabled: true, caSecretName: cluster-gateway-internal-ca, clientCertDuration: 2160h, clientCertRenewBefore: 360h }
  agentAuth: { mode: mtls, forwardedHeaderName: X-Forwarded-Client-Cert }
  heartbeatInterval: 30s
  heartbeatTimeout: 90s
  resources: { requests: { cpu: 100m, memory: 64Mi }, limits: { cpu: 500m, memory: 256Mi } }
```
The lab override from the plan renders correctly (checked with helm template): Service `cluster-gateway-external` `type: NodePort`,
`port 8443 → nodePort 30843`; Certificate `cluster-gateway-tls` dnsNames include `mgmt-lb`. The hub-lb HAProxy has
`timeout client/server 50000` (50 s), and the agent heartbeat is 30 s, so the idle websocket stays open.

**Gateway CA**: Secret **`cluster-gateway-ca`**, key **`ca.crt`**. It is issued by Certificate `cluster-gateway-ca` (`isCA`,
CN `openchoreo-cluster-gateway-ca`, RSA 4096, `duration: 87600h`, `renewBefore: 720h`, **`rotationPolicy: Always`**) from self-signed
Issuer `cluster-gateway-ca-issuer` (`templates/cluster-gateway/ca-certificate.yaml`). Upstream exports it with
`kubectl get secret cluster-gateway-ca -n openchoreo-control-plane -o jsonpath='{.data.ca\.crt}' | base64 -d`
(`install/k3d/k3d-install.sh`, multi-cluster README). It lasts 10 years, but a renewal changes the key, so the worker ConfigMap
must be updated then.

### backstage / openchoreoApi / security / gateway
```yaml
backstage:
  enabled: true
  secretName: ""                  # REQUIRED (validate.yaml fails if empty)
  baseUrl: "http://openchoreo.invalid"   # validate fails on ".invalid"
  http: { enabled: true, hostnames: [openchoreo.invalid] }   # HTTPRoute "backstage" -> svc backstage:7007
  appConfig: {}
  auth: { clientId: openchoreo-backstage-client, oidcScope: "openid profile email", scope: "", serviceClientId: "", serviceClientSecretKey: client-secret, redirectUrls: [] }
  openchoreoApi: { url: "" }      # default http://openchoreo-api.<ns>.svc.cluster.local:8080/api/v1
  database: { type: sqlite, sqlite: { persistence: { enabled: false } } }
  resources: { requests: { cpu: 200m, memory: 256Mi }, limits: { cpu: 2000m, memory: 2Gi } }
openchoreoApi:
  http: { enabled: true, hostnames: [api.openchoreo.invalid] }  # HTTPRoute "openchoreo-api" -> svc openchoreo-api:8080
  config: { server: { publicUrl: "http://api.openchoreo.invalid", port: 8080 } }
  resources: { requests: { cpu: 200m, memory: 256Mi }, limits: { cpu: 1000m, memory: 1Gi } }
security:
  enabled: true
  oidc:
    issuer: "http://thunder.openchoreo.invalid"
    wellKnownEndpoint: ""
    jwksUrl: ".../oauth2/jwks"
    authorizationUrl: ".../oauth2/authorize"
    tokenUrl: ".../oauth2/token"
    jwksUrlTlsInsecureSkipVerify: false
    uidResolverTlsInsecureSkipVerify: false
    externalClients: [{ name: cli, client_id: openchoreo-cli, scopes: [openid, profile, email] }]
    mcpOAuthScopes: [openid, profile, email]
  jwt: { audience: "" }
  authz: { enabled: true }       # renders post-install/post-upgrade hook Job "openchoreo-authz-bootstrap" (kubectl apply of ClusterAuthzRole/Bindings)
  authServerBaseUrl: ""
features: { secretManagement: { enabled: false, remoteKeyPrefix: secret } }
gateway:
  enabled: true
  gatewayClassName: kgateway
  infrastructure: {}
  httpPort: 80                    # listener "http"
  httpsPort: 443
  tls: { enabled: true, hostname: "*.openchoreo.invalid", certificateRefs: [] }   # validate fails on .invalid if enabled
```
Other requests: controllerManager 200m/256Mi (limits 1000m/1Gi), eventForwarder 50m/64Mi (200m/256Mi); portalAssistant is off.
**Sum of requests ≈ 750m CPU / ~900Mi**, plus the gateway-default envoy proxy.

Objects rendered with upstream values-cp plus the lab override (`cp-rendered.yaml`): 5 Deployments (backstage, openchoreo-api,
controller-manager, cluster-gateway, event-forwarder); Gateway `gateway-default` (listener `http` port **8080**);
`HTTPListenerPolicy enable-websocket` and 2× `TrafficPolicy` (gateway.kgateway.dev/v1alpha1, **so kgateway CRDs must exist first**);
HTTPRoutes `backstage`, `openchoreo-api`; Certificates `cluster-gateway-ca`, `cluster-gateway-tls`, `cluster-gateway-internal-ca`,
`controller-manager-cluster-gateway-client`, `openchoreo-api-cluster-gateway-client`, `controller-manager-webhook-server-cert`;
ConfigMap placeholder `cluster-gateway-ca`. Hooks are only the authz bootstrap: SA/ClusterRole/Binding/ConfigMap/Job,
`post-install,post-upgrade`, `before-hook-creation,hook-succeeded`. Under Argo these become PostSync, run on every sync, and are
idempotent (`kubectl apply`). HookSucceeded deletion happens only after the whole operation (gitops-engine `sync_context.go` ~L629–676),
so the RBAC hooks outlive the Job.

### Secrets the CP expects
`backstage-secrets` in `openchoreo-control-plane` (name comes from `backstage.secretName`). Keys, from `templates/backstage/deployment.yaml`:
- `backend-secret` (required)
- `client-secret` (required; must equal the Thunder Backstage app's `client_secret`, upstream `backstage-portal-secret`; also used as
  `OPENCHOREO_SERVICE_CLIENT_SECRET` via `auth.serviceClientSecretKey`)
- `jenkins-api-key` (**required**, not optional)
- `github-actions-token` (only if `externalCI.githubActions.enabled`, optional:true)
- `github-oauth-client-secret` (only if `…githubActions.oauth.clientId`, optional:true)
- `postgres-*` only if `database.type=postgresql`.

How upstream creates it:
- single-cluster `k3d-install.sh` uses an ExternalSecret from `ClusterSecretStore default` (OpenBao);
- multi-cluster README uses plain `kubectl create secret generic backstage-secrets … --from-literal=client-secret=backstage-portal-secret …`.

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: { name: backstage-secrets, namespace: openchoreo-control-plane }
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: default }
  target: { name: backstage-secrets }
  data:
    - { secretKey: backend-secret,             remoteRef: { key: backstage-backend-secret, property: value } }
    - { secretKey: client-secret,              remoteRef: { key: backstage-client-secret, property: value } }
    - { secretKey: jenkins-api-key,            remoteRef: { key: backstage-jenkins-api-key, property: value } }
    - { secretKey: github-actions-token,       remoteRef: { key: backstage-github-actions-token, property: value } }
    - { secretKey: github-oauth-client-secret, remoteRef: { key: backstage-github-oauth-client-secret, property: value } }
```
Lab alternative with no OpenBao dependency: an ESO `Password` generator for `backend-secret`. `client-secret` must match the Thunder app,
so either keep the upstream literal or pass one generated secret to both sides (Thunder `setup.env` secretKeyRef; the ordering is hard, §C).

### Namespace label and the Environment namespace
- The chart **never creates** a namespace labelled `openchoreo.dev/control-plane: "true"`. It is only mentioned in
  `event-forwarder/clusterrole.yaml` comments.
- The label means "this namespace is an OpenChoreo org namespace" (`oc/internal/labels/labels.go:66-72`). openchoreo-api lists
  namespaces by this label (`internal/openchoreo-api/services/namespace/service.go:140,212`) and the event-forwarder filters informers by it.
  Backstage's catalog comes from openchoreo-api, so Environments/Projects in an unlabelled namespace are invisible.
- Upstream: `kubectl label namespace default openchoreo.dev/control-plane=true` + `samples/getting-started/all.yaml`, where everything is in
  **`default`**: Project `default`, DeploymentPipeline `default`, Environments `development|staging|production`,
  **ProjectReleaseBinding per environment** (`default-development`, …), ClusterProjectType `default`, 4 ClusterComponentTypes,
  3 ClusterResourceTypes, 4 ClusterWorkflows, ClusterTrait. Resources carry label `openchoreo.dev/name: <name>`.
- **Phase 3 impact:** with one Environment per cluster, each Project needs a `ProjectReleaseBinding` per Environment (per cluster).
- Recommendation: use `default`, and label it declaratively in the CP umbrella with SSA plus `Delete=false`:
  ```yaml
  apiVersion: v1
  kind: Namespace
  metadata:
    name: default
    labels: { openchoreo.dev/control-plane: "true" }
    annotations: { argocd.argoproj.io/sync-options: "Delete=false,ServerSideApply=true" }
  ```

---

## B. Upstream k3d values @ v1.2.5 and the `*.openchoreo.localhost:8080` mechanism

`install/k3d/multi-cluster/values-cp.yaml`:
```yaml
openchoreoApi:
  http: { hostnames: [api.openchoreo.localhost] }
  config: { server: { publicUrl: "http://api.openchoreo.localhost:8080" } }
backstage:
  secretName: backstage-secrets
  baseUrl: "http://openchoreo.localhost:8080"
  http: { hostnames: [openchoreo.localhost] }
security:
  oidc:
    issuer: "http://thunder.openchoreo.localhost:8080"
    jwksUrl: "http://thunder.openchoreo.localhost:8080/oauth2/jwks"
    authorizationUrl: "http://thunder.openchoreo.localhost:8080/oauth2/authorize"
    tokenUrl: "http://thunder.openchoreo.localhost:8080/oauth2/token"
clusterGateway:
  tlsRoute: { enabled: true, hosts: [{ host: cluster-gateway.openchoreo.localhost, paths: [{ path: /, pathType: Prefix }] }] }
  tls:
    issuerRef: { name: cluster-gateway-server-issuer }   # just renames the chart's CA Issuer (still backed by secret cluster-gateway-ca)
    dnsNames: [cluster-gateway.openchoreo-control-plane.svc, cluster-gateway.openchoreo-control-plane.svc.cluster.local, cluster-gateway.openchoreo.localhost]
gateway: { httpPort: 8080, httpsPort: 8443, tls: { enabled: false } }
```
`values-dp.yaml`:
```yaml
clusterAgent: { serverUrl: "wss://cluster-gateway.openchoreo.localhost:8443/ws" }
gateway: { httpPort: 19080, httpsPort: 19443, tls: { enabled: false } }
```
`config-cp.yaml` (k3d): `rancher/k3s:v1.36.1-k3s1`, 1 server, `--disable=traefik`, `ports: 8080:8080` and `8443:8443` on the loadbalancer.
`config-dp.yaml`: `19080:19080`, `19443:19443`, `--tls-san=host.k3d.internal`, a registry mirror for `host.k3d.internal:10082`.

`install/k3d/common/coredns-custom.yaml`:
```yaml
apiVersion: v1
kind: ConfigMap
metadata: { name: coredns-custom, namespace: kube-system }
data:
  openchoreo.override: |
    rewrite stop {
      name regex (.+\.)?openchoreo\.localhost host.k3d.internal
      answer auto
    }
```

**Mechanism upstream:**
- The Gateway listener port is **8080** (`gateway.httpPort`). kgateway creates Service `gateway-default` (type LoadBalancer) with port 8080.
  k3s servicelb binds node:8080, and k3d maps host 8080 → the LB → node:8080.
- Browser: `*.localhost` resolves to 127.0.0.1, so `http://openchoreo.localhost:8080` reaches the host port and then the gateway.
  HTTPRoute hostname matching ignores the port.
- In-cluster: CoreDNS rewrites any `*.openchoreo.localhost` to `host.k3d.internal` (the docker host), port 8080, which is the same path.
  So one URL (the issuer, for example) works from both sides.

**Replicating on the hub (no host ports):**
- Keep `gateway.httpPort: 8080`, so Service `openchoreo-control-plane/gateway-default` exposes **8080**. Hub k3s has servicelb enabled
  (only traefik is disabled in `clusterclass-k3s-docker.yaml:117`), so the LB Service gets node IPs. That doesn't matter here.
- CoreDNS: the hub's coredns Deployment already mounts optional ConfigMap `kube-system/coredns-custom` (checked live; it doesn't exist yet).
  The Corefile has `import /etc/coredns/custom/*.override` inside `.:53`. `rewrite` runs before `kubernetes` whatever its position in the
  Corefile (plugin.cfg order), so a service FQDN target resolves:
  ```yaml
  apiVersion: v1
  kind: ConfigMap
  metadata: { name: coredns-custom, namespace: kube-system }
  data:
    openchoreo.override: |
      rewrite stop {
        name regex (.+\.)?openchoreo\.localhost gateway-default.openchoreo-control-plane.svc.cluster.local
        answer auto
      }
  ```
  In-cluster `http://thunder.openchoreo.localhost:8080` then reaches the ClusterIP of `gateway-default:8080`.
- Browser: `kubectl --context mgmt -n openchoreo-control-plane port-forward svc/gateway-default 8080:8080`. Chrome/Firefox resolve
  `*.localhost` to loopback. Safari/others may need `/etc/hosts` entries for `openchoreo.localhost api.openchoreo.localhost thunder.openchoreo.localhost`.
- Workers need no DNS for this: the agent dials `wss://mgmt-lb:30843/ws` directly.

**values-thunder.yaml structure** (1004 lines, `install/k3d/common/values-thunder.yaml`):
- `fullnameOverride: thunder`; `httproute: {enabled: true, parentRefs: [{name: gateway-default, namespace: openchoreo-control-plane}], hostnames: [thunder.openchoreo.localhost]}`;
  `ingress.enabled: false`; `deployment.replicaCount: 1`; `hpa.enabled: false`.
- `configuration.server: {httpOnly: true, publicUrl: "http://thunder.openchoreo.localhost:8080"}`;
  `gateClient: {hostname: thunder.openchoreo.localhost, port: 8080, scheme: http}`; all 3 DBs `type: sqlite`;
  `cors.allowedOrigins: ["http://openchoreo.localhost:8080","http://localhost:7007"]`; `passkey.allowedOrigins: ["http://openchoreo.localhost:8080"]`; `setup.enabled: true`.
- `bootstrap.scripts` are run by the setup Job against `http://localhost:8090`. Every script is check-then-create or PUT-update, so re-runs are safe.
  - `50-user-schema-and-users.sh`: OU `default`; user schema `openchoreo-user` (username, password, given_name, family_name, email).
    Users (username = email): `admin@openchoreo.dev`/`Admin@123`, `developer@openchoreo.dev`/`Dev@123`,
    `platform-engineer@openchoreo.dev`/`PE@123`, `sre@openchoreo.dev`/`SRE@123`. Groups `admins`, `developers`, `platform-engineers`,
    `sres`, one member each.
  - OAuth apps:

    | script | client_id | secret | grants | redirect_uris | auth |
    |---|---|---|---|---|---|
    | 51 Backstage | `openchoreo-backstage-client` | `backstage-portal-secret` | authorization_code, client_credentials, refresh_token | `http://openchoreo.localhost:8080/api/auth/openchoreo-auth/handler/frame` | client_secret_post |
    | 52 Customer Portal | `customer-portal-client` | `supersecret` | client_credentials | – | client_secret_post |
    | 53 RCA Agent | `openchoreo-rca-agent` | `openchoreo-rca-agent-secret` | client_credentials | – | post |
    | 54 OpenChoreo CLI | `openchoreo-cli` | – (public, PKCE) | authorization_code, refresh_token | `http://127.0.0.1:55152/auth-callback` | none |
    | 55 System App | `openchoreo-system-app` | `openchoreo-system-app-secret` | client_credentials | – | post |
    | 56 User MCP App | `user_mcp_client` | – (public, PKCE) | authorization_code, refresh_token | `http://localhost:8075/callback`, `http://127.0.0.1:19876/mcp/oauth/callback` | none |
    | 57 Service MCP App | `service_mcp_client` | `service_mcp_client_secret` | client_credentials | – | client_secret_basic |
    | 58 Workload Publisher | `openchoreo-workload-publisher-client` | `openchoreo-workload-publisher-secret` | client_credentials | – | post |
    | 59 Observer Reader | `openchoreo-observer-resource-reader-client` | `…-client-secret` | client_credentials | – | post |
    | 60 FinOps Agent | `openchoreo-finops-agent` | `openchoreo-finops-agent-secret` | client_credentials | – | post |
    | 61 MCP E2E Subject | `mcp-e2e-subject-client` | `mcp-e2e-subject-secret` | client_credentials | – | post |

    Interactive apps set `token.{access_token,id_token}.user_attributes: [given_name, family_name, username, groups]` and
    `scope_claims: {email:[email], groups:[groups], profile:[username,given_name,family_name,picture]}`.
- Admin password: literal in the ConfigMap (the script's `ensure_user` args). The Thunder console admin `admin`/`admin` comes from the image's
  default bootstrap. No Secret is involved.

---

## C. Thunder chart

- Ref: **`oci://ghcr.io/asgardeo/helm-charts/thunder` version `0.28.0`** (appVersion 0.28.0, image `ghcr.io/asgardeo/thunder:0.28.0`,
  `pullPolicy: Always`). Sources: `k3d-install.sh` `THUNDER_VERSION="0.28.0"`, the multi-cluster README, and
  `site/…v1.2.x/platform-engineer-guide/air-gapped-installation.mdx:227`.
- Required values: the upstream file above (`fullnameOverride`, `httproute`, sqlite, `publicUrl`, `gateClient`, `cors`, `bootstrap.scripts`).
  Chart defaults are postgres, ingress on, replicas 2 and hpa on, so all of these overrides matter.
- Rendered names: Service **`thunder-service`** port **8090** (name `servlet-https`, but it's plain http since httpOnly);
  HTTPRoute **`thunder-httproute`** → `thunder-service:8090`, host `thunder.openchoreo.localhost`, parent `openchoreo-control-plane/gateway-default`.
  Also Deployment `thunder-deployment`, ConfigMap `thunder-config-map`, Role/RoleBinding `thunder-endpoints-reader-*`.
  Resources: requests 100m/50Mi, limits 200m/100Mi.
- Issuer (id_token `iss`) = `configuration.server.publicUrl`, because `jwt.issuer` is empty (`backend/internal/system/config/config.go:440-501`).
  ID token `aud` = client_id (`tokenservice/builder.go:286-288`).
- Hooks (rendered):

  | object | helm hook | weight | delete policy | Argo result |
  |---|---|---|---|---|
  | PVC `thunder-database-pvc` | pre-install | -15 | – | PreSync, **BeforeHookCreation** (default) |
  | SA `thunder-service-account` | pre-install | -10 | – | PreSync, BeforeHookCreation, recreated each sync |
  | CM `thunder-bootstrap`, `thunder-setup-config-map` | pre-install | -10 | – | recreated each sync (picks up new scripts, which is good) |
  | Secret `thunder-db-credentials` | pre-install,pre-upgrade | -6 | before-hook-creation | fine |
  | Job `thunder-setup` | pre-install | -5 | hook-succeeded (+ttl 86400) | PreSync, **re-runs on every sync** |

  Argo facts (verified in code/docs): pre-install and pre-upgrade map to PreSync (`docs/user-guide/helm.md` table). With no delete policy
  "Argo CD will automatically assume BeforeHookCreation" (`sync-waves.md:53`; `gitops-engine/pkg/sync/hook/delete_policy.go`).
  Running hooks block the sync (`sync_context.go` ~L593-615). Hook phase comes from health, and Progressing means Running
  (`getOperationPhase`, L364-386). PVC Pending is Progressing (`health/health_pvc.go`). A `helm.sh/hook: test` Pod has no phase and is
  never applied.
- **Thunder under Argo (hub = local-path, WaitForFirstConsumer):**
  1. **Deadlock:** the PVC hook (wave -15) stays Pending until a pod uses it, and the only consumer is the wave -5 Job. Fix with an
     argocd-cm health override for hook PVCs:
     ```yaml
     argo-cd:
       configs:
         cm:
           resource.customizations.health.PersistentVolumeClaim: |   # core kinds: no "<group>_" prefix (docs/operator-manual/health.md:122-125)
             hs = {}
             local phase = obj.status and obj.status.phase or "Pending"
             if phase == "Bound" then hs.status = "Healthy"; hs.message = "Bound"; return hs end
             if phase == "Lost" then hs.status = "Degraded"; hs.message = "Lost"; return hs end
             -- WaitForFirstConsumer: a Pending Helm-hook PVC (Thunder) must not block PreSync; its consumer is a later hook.
             if obj.metadata.annotations ~= nil and obj.metadata.annotations["helm.sh/hook"] ~= nil then
               hs.status = "Healthy"; hs.message = "Pending until first consumer"; return hs
             end
             hs.status = "Progressing"; hs.message = "Pending"; return hs
     ```
  2. **Data loss / hang on the 2nd sync:** BeforeHookCreation deletes the in-use PVC. pvc-protection blocks it, then it is recreated
     empty. The chart lets us add annotations to the PVC (`persistence.annotations` is appended after hook and weight), so set an explicit
     policy that never fires on success:
     ```yaml
     thunder:
       persistence:
         annotations:
           helm.sh/hook-delete-policy: hook-failed   # -> HookFailed; existing PVC is then just re-applied (kubectl apply) each sync
     ```
  3. The setup Job re-runs on every sync. The upstream scripts and Thunder's own `01-default-resources.sh` are idempotent.
     The init container only copies the DB if `/data/.initialized` is absent. It writes the same sqlite (WAL) as the running pod on the
     same node; RWO local-path is node-affine, so it works. The Job pod carries the Deployment's selector labels, so `thunder-service`
     briefly routes to it too (harmless).
  4. The SA is deleted and recreated each sync, which invalidates the running pod's bound token (the UID changes). Only matters if Thunder
     calls the k8s API (endpoints reader; `cache.disabled: true`). Low risk. Its RoleBinding is a normal resource and still matches by name.
  5. There is no Secret with the admin password (see correction 2).
- Ordering: Thunder needs `gateway-default` (created by the CP chart) only for the HTTPRoute to attach. The Thunder pod itself doesn't need it.
  CP pods need Thunder only at runtime (jwks/token), so CrashLoop until Thunder is up is acceptable.

---

## D. OpenBao chart 0.25.6 (`oci://ghcr.io/openbao/charts/openbao`)

- Upstream `k3d-prerequisites.sh`: `OPENBAO_CHART_VERSION="0.25.6"`, installed with `install/k3d/common/values-openbao.yaml`
  (`injector.enabled: false`, `server.dev.enabled: true`, `devRootToken: root`, and a `server.postStart` shell). The shell does:
  `sleep 5`; enables kubernetes auth with `kubernetes_host=https://$KUBERNETES_PORT_443_TCP_ADDR:443`; policies
  `openchoreo-secret-reader-policy` (read `secret/data/*`) and `…-writer-policy` (CRUD); role `openchoreo-secret-reader-role`
  (SA `default`, ns `dp*`, ttl 20m); role `openchoreo-secret-writer-role` (SA `*`, ns `openbao,openchoreo-workflow-plane`); and KV seeds.
- Rendered (image `quay.io/openbao/openbao:2.5.1`): SA `openbao`, ClusterRoleBinding `openbao-server-binding` (auth-delegator, used by
  k8s auth TokenReview), Services `openbao` (8200) and `openbao-internal`, StatefulSet `openbao` (**no volumeClaimTemplates** in dev mode;
  readiness `bao status`), and Pod `openbao-server-test` (helm test hook, **ignored by Argo**). **No install/upgrade hooks, so it works
  under Argo as is.**
- Caveat: dev mode is in-memory. Every pod restart wipes all data, then postStart re-seeds policies, roles and KV. Anything else
  (PushSecret writes) is gone until ESO re-pushes (PushSecret refreshInterval). `sleep 5` is a race but upstream relies on it.
- Seeds for the OpenChoreo CP (KV v2 at mount `secret`, each with property `value`):
  `backstage-backend-secret=local-dev-backend-secret`, `backstage-client-secret=backstage-portal-secret`,
  `backstage-jenkins-api-key=placeholder-not-in-use`, `backstage-github-actions-token=placeholder-not-in-use`,
  `backstage-github-oauth-client-secret=placeholder-not-in-use`.
  Others: `npm-token, docker-username, docker-password, github-pat, username, password` (samples), `observer-oauth-client-secret`,
  `rca-oauth-client-secret`, `finops-agent-oauth-client-secret`, `opensearch-*`, `openobserve-*`.
- `ClusterSecretStore default` (identical in `k3d-prerequisites.sh` and `k3d-install.sh` @ v1.2.5; the v1.2.x docs defer to these):
  ```yaml
  apiVersion: v1
  kind: ServiceAccount
  metadata: { name: external-secrets-openbao, namespace: openbao }
  ---
  apiVersion: external-secrets.io/v1
  kind: ClusterSecretStore
  metadata: { name: default }
  spec:
    provider:
      vault:
        server: "http://openbao.openbao.svc:8200"
        path: "secret"
        version: "v2"
        auth:
          kubernetes:
            mountPath: "kubernetes"
            role: "openchoreo-secret-writer-role"
            serviceAccountRef: { name: "external-secrets-openbao", namespace: "openbao" }
  ```
- The note on scope from correction 3 applies: this store serves the **hub** only. `ClusterDataPlane.secretStoreRef` names a store on the
  worker.

---

## E. openchoreo-data-plane 1.2.5

- No subchart dependencies. It needs **Gateway API CRDs** (Gateway), **kgateway CRDs** (`HTTPListenerPolicy`
  `openchoreo-data-plane-httplistenerpolicy`), a GatewayClass `kgateway`, and **cert-manager** (Issuers/Certificates).
- Rendered (`dp-rendered.yaml`): SA `cluster-agent-dataplane`; ClusterRole/Binding `cluster-agent-dataplane-openchoreo-data-plane`;
  **Deployment `cluster-agent-dataplane`** (from `clusterAgent.name`), **container `agent`**; Certificate `cluster-agent-dataplane-tls`;
  Issuer `cluster-agent-dataplane-selfsigned-issuer` (or `-ca-issuer`); Certificate `openchoreo-data-plane-serving-cert` → secret
  `webhook-server-cert` + Issuer `openchoreo-data-plane-selfsigned-issuer` (from `security.enabled`); Gateway `gateway-default`.
- **The container has an `env:` list**: `POD_NAME`, `POD_NAMESPACE`, then `clusterAgent.extraEnvs` appended. So an appset JSON patch
  `op: add, path: /spec/template/spec/containers/0/env/-, value: {name: CLUSTER_NAME, value: <cluster>}` works.
  `$(CLUSTER_NAME)` in **args** expands from any env var in the container.
- planeID goes in through **args**: `--plane-id={{ .Values.clusterAgent.planeID | default .Release.Name }}`. The other args are
  `--server-url`, `--plane-type=dataplane`, `--tls-enabled`, `--client-cert=/certs/tls.crt`, `--client-key=/certs/tls.key`,
  `--server-ca=/ca-certs/ca.crt`, `--heartbeat-interval=30s`, `--reconnect-delay=5s`, `--log-level`.
  With `planeID: "$(CLUSTER_NAME)"` the render shows `--plane-id=$(CLUSTER_NAME)`. The Certificate CN also becomes the literal
  `$(CLUSTER_NAME)`, which is harmless when that cert isn't used.
- TLS values (defaults): `tls: {enabled: true, generateCerts: true, secretName: cluster-agent-tls, clientSecretName: cluster-agent-tls,
  serverCAConfigMap: cluster-gateway-ca, caSecretName: cluster-gateway-ca, duration: 2160h, renewBefore: 360h}`.
  - `tls.enabled=false`: no Certificate or Issuer, args `--tls-enabled=false`, no cert volumes.
  - `tls.enabled=true` **always renders the Certificate** `cluster-agent-dataplane-tls` (RSA 2048, `client auth`, CN = planeID) into
    **`tls.secretName`**.
    - `generateCerts=true`: Issuer `cluster-agent-dataplane-selfsigned-issuer` (`selfSigned: {}`), and the cert is self-signed.
    - `generateCerts=false`: Issuer `cluster-agent-dataplane-ca-issuer` with `ca.secretName: <tls.caSecretName>`. **That Secret must
      exist** or the Issuer and Certificate stay not-Ready, which Argo shows as Degraded/Progressing.
  - The Deployment mounts Secret **`tls.clientSecretName`** at `/certs` (needs `tls.crt`, `tls.key`) and ConfigMap
    **`tls.serverCAConfigMap`** at `/ca-certs` (key **`ca.crt`**). `secretName` is only the Certificate's output.
  - So the plan's approach is correct: `generateCerts: true`, `secretName: cluster-agent-selfsigned-unused`,
    `clientSecretName: cluster-agent-tls` (PushSecret from the hub), `serverCAConfigMap: cluster-gateway-ca`.
    Docs (`external-ca-tls-setup.md:273-309`) describe the same split. There is no value that disables the Certificate while TLS is on.
- Gateway values: `gateway: {enabled: true, gatewayClassName: kgateway, infrastructure.labels: {openchoreo.dev/system-component: gateway},
  httpPort: 80, httpsPort: 443, tls: {enabled: true, hostname: "*.openchoreoapis.invalid", certificateRefs: []},
  tlsPassthrough: {enabled: false, port: 8443}}`. `validate` fails if `tls.enabled` and the hostname contains `.invalid`, and requires
  unique listener ports, so set `tls.enabled: false` like upstream.
- The gateway reads `ClusterDataPlane.spec.clusterAgent.clientCA.secretKeyRef` (`oc/internal/cluster-gateway/plane_client_ca.go:340-400`).
  The cluster-gateway ClusterRole has cluster-wide `secrets get,list`, so a CA secret in `fleet` works. Set `namespace` explicitly,
  because a ClusterDataPlane has no namespace to default to.

---

## F. Gateway API v1.5.1 CRDs

- `standard-install.yaml` v1.5.1: **1,024,333 bytes, 17,527 lines**. Contents: 8 CRDs (backendtlspolicies, gatewayclasses, gateways,
  grpcroutes, httproutes, listenersets, referencegrants, tlsroutes) + `ValidatingAdmissionPolicy` and `…Binding`
  `safe-upgrades.gateway.networking.k8s.io`. The largest CRD is httproutes at ~244 KB JSON, near the 256 KiB last-applied limit, so
  **ServerSideApply is required**. It's already in the mgmt and worker appsets.
- **`kgateway-crds` v2.3.1 contains only `gateway.kgateway.dev` CRDs**: backendconfigpolicies, backends, directresponses,
  gatewayextensions, gatewayparameters, httplistenerpolicies, listenerpolicies, trafficpolicies. No Gateway API.
- **Maintained chart:** `oci://docker.io/envoyproxy/gateway-crds-helm`. Values are
  `crds.gatewayAPI.enabled` (default false), `crds.gatewayAPI.channel` (`standard|experimental`, default experimental), and
  `crds.envoyGateway.enabled` (default false). CRDs live under `templates/`, so Argo upgrades them.
  Bundled Gateway API version by chart version: v1.7.x = v1.4.1; **v1.8.0/v1.8.1/v1.8.2 = v1.5.1**; v1.9.x = v1.6.1.
  With v1.8.2 + `gatewayAPI.enabled=true, channel=standard` the render gives the same 8 CRDs + VAP + binding, and **every CRD `.spec` is
  byte-identical** to `standard-install.yaml` (sha1 compared).
  ```yaml
  # repos/platform-charts/gateway-api-crds/Chart.yaml
  dependencies:
    - name: gateway-crds-helm
      version: v1.8.2          # bundles Gateway API v1.5.1 (v1.9.x jumps to v1.6.1)
      repository: oci://docker.io/envoyproxy
  # values.yaml
  gateway-crds-helm:
    crds:
      gatewayAPI: { enabled: true, channel: standard }
      envoyGateway: { enabled: false }
  ```
  If you'd rather not depend on Envoy's chart, keep the vendored-file plan (1 MB file in git).

---

## G. Argo CD OIDC with Thunder (argo-helm 10.9.2, app v3.5.x)

- Keys: `configs.cm.url`, `configs.cm."oidc.config"`, `configs.cm."admin.enabled"` (default true, keep for break-glass),
  `configs.rbac."policy.csv"`, `configs.rbac."policy.default"` (default ""), `configs.rbac.scopes` (default `"[groups]"`),
  `configs.rbac."policy.matchMode"` (glob), `configs.secret.extra` (adds keys to `argocd-secret`), and
  `configs.cm."oidc.tls.insecure.skip.verify"`.
- Secret references in `oidc.config`: `$<key>` reads that key from `argocd-secret`. `$<k8s-secret-name>:<key>` reads another Secret in the
  `argocd` namespace, which **must carry the label `app.kubernetes.io/part-of: argocd`** (`docs/operator-manual/user-management/index.md:756-800`).
- Thunder groups claim: **`groups`**, an array of group **names** (`tokenservice/utils.go:280-291`, `constants.UserAttributeGroups = "groups"`).
  It's emitted only if the app lists `groups` in `token.id_token.user_attributes`, has `scope_claims.groups: [groups]`, and the client
  requests scope `groups`. Argo's default requestedScopes include `groups`. Include `email` in `user_attributes` too if Argo/Kargo should
  show emails (the upstream Backstage app does not).
- Redirect URIs: `<url>/auth/callback` (server flow, **PKCE included**: v3.5.3 does PKCE server-side, `util/oidc/oidc.go`
  `usePKCE`, redirect `common.CallbackEndpoint`); CLI `http://localhost:8085/auth/callback`. Correction (#19): the
  `<url>/pkce/verify` in `keycloak.md:109-113` is the old browser PKCE flow, and v3.5.3 has no such route.
- **Non-https issuer:** Argo does not require https. go-oidc only checks that discovery `issuer` equals the configured string exactly, and
  Thunder's `iss` = publicUrl `http://thunder.openchoreo.localhost:8080`. `rootCA` and `oidc.tls.insecure.skip.verify` only matter for
  https. argocd-server must resolve that host in-cluster (the CoreDNS rewrite in §B). Session cookies over http already work in the lab
  (`server.insecure: true`). Not yet proven by a live login, so verify on first boot.
- Recommended: **public client with PKCE**, so no client secret exists anywhere. Argo's origin needs no Thunder CORS entry: argocd-server
  exchanges the code (correction, #19).
  ```yaml
  # Thunder bootstrap script (add as 62-argocd-app.sh, same pattern as 54-cli-app.sh)
  "client_id": "argocd",
  "redirect_uris": ["http://localhost:8090/auth/callback", "http://localhost:8085/auth/callback"],
  "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"],
  "token_endpoint_auth_method": "none", "pkce_required": true, "public_client": true,
  "token": { "id_token": { "user_attributes": ["username", "email", "given_name", "family_name", "groups"] }, "access_token": { ... same ... } },
  "scope_claims": { "email": ["email"], "groups": ["groups"], "profile": ["username","given_name","family_name"] }
  # + thunder.configuration.cors.allowedOrigins += "http://localhost:8090", "http://localhost:8091"
  ```
  ```yaml
  argo-cd:
    configs:
      cm:
        url: http://localhost:8090               # make ui port-forward
        oidc.config: |
          name: Thunder
          issuer: http://thunder.openchoreo.localhost:8080
          clientID: argocd
          enablePKCEAuthentication: true
          requestedScopes: ["openid", "profile", "email", "groups"]
      rbac:
        policy.default: role:readonly
        scopes: "[groups]"
        policy.csv: |
          g, admins, role:admin
          g, platform-engineers, role:admin
          p, role:app-developer, applications, get, */*, allow
          p, role:app-developer, applications, sync, openchoreo-apps/*, allow
          p, role:app-developer, logs, get, openchoreo-apps/*, allow
          g, developers, role:app-developer
  ```
  Confidential alternative: `clientSecret: $argocd-oidc-thunder:clientSecret` with that Secret labelled `app.kubernetes.io/part-of: argocd`.
  The same value must then reach Thunder's bootstrap: `thunder.setup.env` → `valueFrom.secretKeyRef` in the `thunder` namespace, created
  **before** the PreSync setup Job. That's an ordering problem under Argo, which is why PKCE is simpler.

---

## H. Kargo 1.11.4 OIDC and RBAC

- Chart values (`ch/kargo/values.yaml:227-…`, `templates/api/configmap.yaml:45-75`):
  ```yaml
  api:
    oidc:
      enabled: false
      issuerURL:            # -> OIDC_ISSUER_URL
      clientID:             # -> OIDC_CLIENT_ID
      cliClientID:          # optional -> OIDC_CLI_CLIENT_ID
      additionalScopes: [groups]   # openid/profile/email always requested
      usernameClaim: email
      admins:          { claims: {} }   # -> annotation rbac.kargo.akuity.io/claims on SA kargo/kargo-admin (templates/users/service-accounts.yaml)
      projectCreators: { claims: {} }   # -> kargo-project-creator
      users:           { claims: {} }   # -> kargo-user
      viewers:         { claims: {} }   # -> kargo-viewer
      globalServiceAccounts: { namespaces: [] }
      dex: { enabled: false, ... }
  ```
- Kargo **always uses Authorization Code + PKCE (S256) with no client secret**, so the Thunder app must be public, PKCE,
  `token_endpoint_auth_method: none`. The UI does discovery and the token exchange **in the browser** (oauth4webapi 3.8.6), so Thunder CORS
  must allow the Kargo UI origin. **http issuers are allowed**: `shouldAllowIdpHttpRequest = () => true` (`ui/src/features/auth/oidc-utils.ts:9`).
  UI redirect URI = `window.location.origin + window.location.pathname` = **`http://localhost:8091/login`** with the plan's port.
  CLI redirect is `http://localhost/auth/callback` per the docs. The API server validates the ID token against `clientID`, and needs the
  CoreDNS rewrite to reach the issuer.
- Project RBAC in 1.11: pure Kubernetes RBAC. A user maps to ServiceAccounts in project namespaces (labelled `kargo.akuity.io/project: "true"`)
  or in global SA namespaces via **`rbac.kargo.akuity.io/claims: '{"groups":["x"]}'`**. The legacy `rbac.kargo.akuity.io/claim.<name>`
  (comma-separated) still works and is unioned. A "Kargo Role" is a virtual grouping of SA + Role + RoleBinding (`kargo get roles`, API
  kind `role.rbac.kargo.akuity.io`). Each project gets controller-managed `kargo-admin`, `kargo-promoter` and `kargo-viewer`
  (SA + Role + RoleBinding).
- **Per-stage promotion restriction: yes.** Custom verb **`promote`** on `stages` with `resourceNames`, plus create/patch/update on
  `promotions` (user guide "promote Verb" / "Custom Promoter Role").

Platform admin (all projects), in the kargo umbrella values:
```yaml
kargo:
  api:
    host: localhost:8091
    oidc:
      enabled: true
      issuerURL: http://thunder.openchoreo.localhost:8080
      clientID: kargo
      additionalScopes: [groups]
      usernameClaim: email              # add "email" to the Thunder app's id_token user_attributes
      admins:  { claims: { groups: [admins, platform-engineers] } }
      viewers: { claims: { groups: [developers] } }   # read-only everywhere (no Secrets)
```
Per-project developer who may promote only into dev and test (render from the `kargo-pipeline` chart into each app project namespace,
e.g. `podinfo`; stage names come from `stages: [dev-canary, dev, test, prod]`):
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: developer
  namespace: podinfo
  annotations:
    kargo.akuity.io/description: App developers may promote up to test
    rbac.kargo.akuity.io/claims: '{"groups":["developers"]}'
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: developer, namespace: podinfo }
rules:
  - apiGroups: [kargo.akuity.io]
    resources: [promotions]
    verbs: [create, patch, update]
  - apiGroups: [kargo.akuity.io]
    resources: [stages]
    verbs: [promote]
    resourceNames: [dev, test]        # prod stays platform-admin only
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: developer, namespace: podinfo }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: developer }
subjects: [{ kind: ServiceAccount, name: developer, namespace: podinfo }]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: developer-viewer, namespace: podinfo }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: kargo-viewer }   # controller-created per project
subjects: [{ kind: ServiceAccount, name: developer, namespace: podinfo }]
```
Thunder app for Kargo: `client_id: kargo`, `redirect_uris: ["http://localhost:8091/login"]`,
`grant_types: [authorization_code, refresh_token]`, `public_client: true`, `pkce_required: true`, `token_endpoint_auth_method: none`,
id_token `user_attributes` including `email` and `groups`; CORS origin `http://localhost:8091`.

---

## I. Secrets out of git: Kargo admin, argocd-agent JWT

**Kargo:** `api.secret.name` names an existing Secret loaded with `envFrom` into kargo-api (`templates/api/deployment.yaml:93-97`). With it
set, the chart's own `kargo-api` Secret isn't rendered and `adminAccount.passwordHash/tokenSigningKey` are no longer required
(`templates/api/secret.yaml:1`). Expected keys: **`ADMIN_ACCOUNT_PASSWORD_HASH`** (bcrypt) and **`ADMIN_ACCOUNT_TOKEN_SIGNING_KEY`**.
ESO 2.10 can generate both. It has a `Password` generator with `secretKeys` (several independent passwords), `refreshPolicy: CreatedOnce`,
and sprig `bcrypt` in templates (`runtime/template/v2/sprig/functions.go:255`, x/crypto bcrypt, `$2a$10$…`):
```yaml
apiVersion: generators.external-secrets.io/v1alpha1
kind: Password
metadata: { name: kargo-admin, namespace: kargo }
spec: { length: 32, digits: 6, symbols: 0, noUpper: false, allowRepeat: true, secretKeys: [password, signingKey] }
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: { name: kargo-api-admin, namespace: kargo }
spec:
  refreshPolicy: CreatedOnce          # generate once; never rotate on refresh
  target:
    name: kargo-api-admin             # kargo.api.secret.name
    template:
      data:
        ADMIN_ACCOUNT_PASSWORD_HASH: '{{ .password | bcrypt }}'
        ADMIN_ACCOUNT_TOKEN_SIGNING_KEY: '{{ .signingKey }}'
        adminPassword: '{{ .password }}'   # for humans; note: envFrom also exposes it as env var in kargo-api (lab-acceptable)
  dataFrom:
    - sourceRef:
        generatorRef: { apiVersion: generators.external-secrets.io/v1alpha1, kind: Password, name: kargo-admin }
```

**argocd-agent principal JWT** (source `agent-v0.10.0`):
- When `principal.jwt.keyPath` is empty and `allowGenerate` is false, the principal reads Secret `<ns>/<jwt.secretName>` (default
  `argocd-agent-jwt`) through the API at **startup**, key **`jwt.key`** (`internal/tlsutil/kubernetes.go:42,182-206`). It PEM-decodes it
  and calls **`x509.ParsePKCS8PrivateKey`**. Signing is **RS512 only** (`internal/issuer/jwt.go:131-208`), so the key must be
  **RSA in PKCS#8** (`-----BEGIN PRIVATE KEY-----`).
- `principal.jwt.keyPath` reads a file instead. The chart only mounts item `jwt.key` of `jwt.secretName` at `/app/config/jwt`, and it has
  **no extraVolumes**, so it can't read `tls.key` from another Secret. There's no flag to rename the key.
- ESO `genPrivateKey "rsa"` emits PKCS#1 (`RSA PRIVATE KEY`), which **won't parse**. Its ed25519 output is PKCS#8 but the principal needs RSA.
- **cert-manager can produce it:** `privateKey: {algorithm: RSA, size: 4096, encoding: PKCS8, rotationPolicy: Never}`, so `tls.key` is PKCS#8.
  Project `tls.key` into `jwt.key` with the **existing** `SecretStore in-cluster` (kubernetes provider, SA `eso-in-cluster`, already in
  `repos/platform-charts/argocd-agent-principal/templates/eso-in-cluster-store.yaml`):
  ```yaml
  apiVersion: cert-manager.io/v1
  kind: Certificate
  metadata: { name: argocd-agent-jwt-key }
  spec:
    secretName: argocd-agent-jwt-src
    commonName: argocd-agent-jwt            # cert itself unused; only the key matters
    duration: 87600h
    privateKey: { algorithm: RSA, size: 4096, encoding: PKCS8, rotationPolicy: Never }  # cert-manager >=1.18 defaults to Always
    issuerRef: { name: argocd-agent-selfsigned, kind: Issuer }
  ---
  apiVersion: external-secrets.io/v1
  kind: ExternalSecret
  metadata: { name: argocd-agent-jwt }
  spec:
    refreshInterval: 1h
    secretStoreRef: { kind: SecretStore, name: in-cluster }
    target: { name: argocd-agent-jwt }
    data:
      - secretKey: jwt.key
        remoteRef: { key: argocd-agent-jwt-src, property: tls.key }
  ```
  Then set `principal.jwt.allowGenerate: false` and keep `secretName: argocd-agent-jwt`. The principal CrashLoops until the Secret exists,
  then starts. Changing the key requires a principal restart; agents re-authenticate over mTLS.

---

## Misc facts used above
- Hub (read-only kubectl): k3s v1.34.11, 2 nodes, StorageClass `local-path` (default, **WaitForFirstConsumer**), no `coredns-custom`
  yet, coredns mounts it optionally. NodePorts in use: 30443, 30080, 30082, 30081. 30843 is free.
- Upstream prerequisite versions @ v1.2.5: Gateway API v1.5.1, cert-manager v1.19.4, ESO 2.0.1, kgateway v2.3.1 (installed into
  `openchoreo-control-plane` / `openchoreo-data-plane` for convenience only; the proxy Deployment follows the Gateway's namespace,
  not the controller's), OpenBao chart 0.25.6, Thunder 0.28.0.
- CP namespace for Environments: whatever carries `openchoreo.dev/control-plane=true`. Upstream uses `default`.
