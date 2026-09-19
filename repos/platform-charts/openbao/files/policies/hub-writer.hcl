# Role hub-writer = ClusterSecretStore `openbao` (templates/hub-writer.yaml): PushSecrets of per-cluster material.
path "secret/data/clusters/*"     { capabilities = ["create", "read", "update", "delete"] }
path "secret/metadata/clusters/*" { capabilities = ["create", "read", "update", "delete", "list"] }
