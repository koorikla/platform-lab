#!/usr/bin/env bash
# One URL per OpenChoreo host for browsers and pods (#11): http://<x>.openchoreo.localhost:8080 hits the control-plane
# Gateway's Service either through the hub CoreDNS rewrite (pods) or `make ui`'s port-forward (browser: *.localhost is
# loopback). Service name/namespace/port come from the rendered control-plane chart, so the three can't drift apart.
source "$(dirname "$0")/lib.sh"
a=$config/addons/management/openchoreo-control-plane
ns=$(yq '.addon.namespace' "$a"/addon.yaml*)
cp=$(render openchoreo-control-plane $charts/openchoreo-control-plane -n "$ns" -f $a/values.yaml)
# kgateway names the proxy Service after the Gateway, one port per listener (deployer: FullnameOverride = gw.Name)
gw=$(yq eval-all 'select(.kind=="Gateway") | .metadata.name' "$cp")
[ "$gw" = gateway-default ] || fail "control-plane Gateway is '$gw', want gateway-default (Service name for DNS + make ui)"
assert_yq "$cp" 'select(.kind=="Gateway") | .metadata.namespace' "$ns"
# its listener (http:8080): openchoreo-control-plane chart unit tests (tests/gateway_test.yaml)

# pods: *.openchoreo.localhost -> the gateway Service (k3s imports *.override into the default server block)
f=$config/fleet/base/hub-coredns.yaml
assert_yq $f '.metadata.namespace + "/" + .metadata.name' kube-system/coredns-custom
ov=$(yq '.data["openchoreo.override"]' $f)
grep -qxF 'rewrite stop {' <<<"$ov" || fail "openchoreo.override: no 'rewrite stop' block"
want="name regex ^(.+\.)?openchoreo\.localhost\.\$ $gw.$ns.svc.cluster.local"
sed 's/^ *//' <<<"$ov" | grep -qxF "$want" || fail "openchoreo.override: want '$want', got: $ov"
grep -qE '^ +answer auto$' <<<"$ov" || fail "openchoreo.override: 'answer auto' missing (clients reject renamed answers)"
# single owner of kube-system/coredns-custom: the existing server block stays
assert_yq $f '.data | has("external.server")' true

# browser: make ui port-forwards the gateway on 8080 and moves Argo CD/Kargo off it
ui=$(make -s -n ui)
grep -qF -- "-n $ns port-forward svc/$gw 8080:8080" <<<"$ui" || fail "make ui: no port-forward of $ns/$gw on 8080"
grep -qF -- '-n argocd port-forward svc/argocd-server 8090:80' <<<"$ui" || fail "make ui: Argo CD not on 8090"
grep -qF -- '-n kargo port-forward svc/kargo-api 8091:80' <<<"$ui" || fail "make ui: Kargo not on 8091"
# Kargo's own idea of where it is served (token audience, OIDC client id/callback in #19)
assert_yq $charts/kargo/values.yaml '.kargo.api.host' localhost:8091
# docs and the bootstrap summary point at the same ports
for d in README.md bootstrap/bootstrap.sh CONTRIBUTING.md; do
  ! grep -qE '(^|[^.])localhost:808[01]|Argo CD :8080|Kargo :8081' $d || fail "$d still mentions the old UI ports"
done
grep -qF 'http://openchoreo.localhost:8080' README.md || fail "README: OpenChoreo URL missing"
