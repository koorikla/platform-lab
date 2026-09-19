#!/usr/bin/env bash
# fleet file `ring:` becomes label platform.lab/ring on the CAPI Cluster and the Argo cluster secret (default stable)
source "$(dirname "$0")/lib.sh"
o=$(render dev2 $charts/cluster -f $config/fleet/clusters/dev/dev1.yaml --set ring=canary)
assert_yq "$o" 'select(.kind=="Cluster") | .metadata.labels["platform.lab/ring"]' canary
assert_yq "$o" 'select(.kind=="ExternalSecret") | .spec.target.template.metadata.labels["platform.lab/ring"]' canary
o=$(render dev1 $charts/cluster -f $config/fleet/clusters/dev/dev1.yaml)
assert_yq "$o" 'select(.kind=="Cluster") | .metadata.labels["platform.lab/ring"]' stable
