# Role eso on every auth/k8s-<name> (fleet-sync): one fixed policy for all workers. fleet-sync binds the worker's ESO
# login to entity cluster-<name> (metadata cluster=<name>), so this resolves to that worker's own path. No entity or
# no metadata -> the path is dropped -> nothing readable. OpenBao refuses / * + in substituted values.
path "secret/data/clusters/{{identity.entity.metadata.cluster}}/*" { capabilities = ["read"] }
