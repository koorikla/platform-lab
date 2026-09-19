# Role operator (SA openbao-operator, no pod runs as it; `make bao`): hand-written hub material that has no source
# in the cluster, e.g. cloud provider credentials for CAPI (#23). Durable since #30. Hub consumers get their own
# read-only store/policy when they arrive.
path "secret/data/hub/*"     { capabilities = ["create", "read", "update", "delete"] }
path "secret/metadata/hub/*" { capabilities = ["read", "list", "delete"] }
