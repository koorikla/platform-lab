# Role openchoreo-reader = ClusterSecretStore `default` (templates/openchoreo.yaml): read-only.
path "secret/data/openchoreo/*"     { capabilities = ["read"] }
