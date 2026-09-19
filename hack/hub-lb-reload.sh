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
[ -s "$tmp/template" ] || { echo "ConfigMap fleet/k3s-docker-hub-lb has no template (key value)" >&2; exit 1; }
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
	"fmt"
	"net"
	"os"
	"strings"
	"text/template"
)

func die(format string, a ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", a...)
	os.Exit(1)
}

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
	f, err := os.Open(os.Args[2])
	if err != nil {
		die("backends: %v", err)
	}
	s := bufio.NewScanner(f)
	for s.Scan() {
		p := strings.Fields(s.Text())
		if len(p) != 2 || net.ParseIP(p[1]) == nil {
			die("backends: want '<container> <ip>', got %q", s.Text())
		}
		data.BackendServers[p[0]] = BackendServer{Address: p[1], Weight: 100}
	}
	if err := s.Err(); err != nil {
		die("backends: %v", err)
	}
	tpl, err := os.ReadFile(os.Args[1])
	if err != nil {
		die("template: %v", err)
	}
	t, err := template.New("lb").Funcs(template.FuncMap{"JoinHostPort": net.JoinHostPort}).Parse(string(tpl))
	if err != nil {
		die("template: %v", err)
	}
	if err := t.Execute(os.Stdout, data); err != nil {
		die("render: %v", err)
	}
}
EOF
(cd "$tmp" && go run main.go template backends) > "$tmp/haproxy.cfg"
grep -q '^frontend control-plane' "$tmp/haproxy.cfg" || { echo "rendered config has no 'frontend control-plane': refusing" >&2; exit 1; }
# 4. validate with the LB's own haproxy (via stdin: the image has no shell/rm, so no temp file inside), keep the
#    current config as haproxy.cfg.bak, swap in, reload
docker exec -i "$lb" haproxy -c -f /dev/stdin < "$tmp/haproxy.cfg" >/dev/null
docker cp "$lb:$cfg" - | tar -xO > "$tmp/haproxy.cfg.bak"
[ -s "$tmp/haproxy.cfg.bak" ] || { echo "could not read the current $cfg from $lb" >&2; exit 1; }
docker cp "$tmp/haproxy.cfg.bak" "$lb:$cfg.bak"
docker cp "$tmp/haproxy.cfg" "$lb:$cfg"
docker kill -s HUP "$lb" >/dev/null
echo "reloaded $lb: $(awk '/^frontend/ {printf "%s ", $2}' "$tmp/haproxy.cfg")(previous config: $cfg.bak)"
