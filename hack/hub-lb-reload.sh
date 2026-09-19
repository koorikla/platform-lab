#!/usr/bin/env bash
# Re-render the hub LB's HAProxy config from ConfigMap fleet/k3s-docker-hub-lb and reload it, exactly like CAPD does
# (text/template + JoinHostPort, write haproxy.cfg, SIGHUP). Needed after editing fleet/base/hub-lb.yaml on a running
# hub: CAPD only renders the template when a control-plane machine is created or deleted.
#   hack/hub-lb-reload.sh [hub-name]        (default mgmt; needs go, docker, kubectl --context <hub>)
set -euo pipefail
hub=${1:-mgmt}
lb=$hub-lb
cfg=/usr/local/etc/haproxy/haproxy.cfg
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# 1. the template as Argo CD applied it
kubectl --context "$hub" -n fleet get configmap k3s-docker-hub-lb -o jsonpath='{.data.value}' > "$tmp/template"
# 2. control-plane containers + their IP on the kind network (CAPD: container label role=control-plane)
docker ps --filter "label=io.x-k8s.kind.cluster=$hub" --filter label=io.x-k8s.kind.role=control-plane \
  --format '{{.Names}}' | while read -r n; do
  echo "$n $(docker inspect -f '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' "$n")"
done > "$tmp/backends"
[ -s "$tmp/backends" ] || { echo "no control-plane containers for $hub" >&2; exit 1; }
# 3. render with CAPD's data model (internal/loadbalancer/config.go)
cat > "$tmp/main.go" <<'EOF'
package main

import (
	"bufio"
	"net"
	"os"
	"strings"
	"text/template"
)

type BackendServer struct {
	Address string
	Weight  int
}

func main() {
	data := struct {
		FrontendControlPlanePort, BackendControlPlanePort string
		BackendServers                                    map[string]BackendServer
		IPv6                                              bool
	}{"6443", "6443", map[string]BackendServer{}, false}
	f, _ := os.Open(os.Args[2])
	s := bufio.NewScanner(f)
	for s.Scan() {
		p := strings.Fields(s.Text())
		data.BackendServers[p[0]] = BackendServer{Address: p[1], Weight: 100}
	}
	tpl, _ := os.ReadFile(os.Args[1])
	t := template.Must(template.New("lb").Funcs(template.FuncMap{"JoinHostPort": net.JoinHostPort}).Parse(string(tpl)))
	if err := t.Execute(os.Stdout, data); err != nil {
		panic(err)
	}
}
EOF
(cd "$tmp" && go run main.go template backends) > "$tmp/haproxy.cfg"
# 4. validate with the LB's own haproxy, then swap in and reload
docker cp "$tmp/haproxy.cfg" "$lb:$cfg.new"
docker exec "$lb" haproxy -c -f "$cfg.new" >/dev/null
docker cp "$tmp/haproxy.cfg" "$lb:$cfg"
docker kill -s HUP "$lb" >/dev/null
echo "reloaded $lb: $(grep -c '^frontend' "$tmp/haproxy.cfg") frontends ($(awk '/^frontend/ {printf "%s ", $2}' "$tmp/haproxy.cfg"))"
