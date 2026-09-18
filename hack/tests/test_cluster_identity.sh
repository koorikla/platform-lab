#!/usr/bin/env bash
# worker gets agent identity (client cert + CA pushed via PushSecret), hub does not
source "$(dirname "$0")/lib.sh"
w=$(render dev1 $charts/cluster -f $config/fleet/clusters/dev/dev1.yaml)
assert_yq "$w" '[select(.kind=="PushSecret")] | length' 2
h=$(render mgmt $charts/cluster -f $config/fleet/clusters/mgmt/mgmt.yaml)
assert_yq "$h" '[select(.kind=="PushSecret")] | length' 0
