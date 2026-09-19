# Role openchoreo-seeder = SecretStore openchoreo-seeder (templates/openchoreo.yaml): the PushSecrets write
# secret/openchoreo/*. No delete: the PushSecrets use deletionPolicy None (delete on metadata/ would destroy every
# version).
path "secret/data/openchoreo/*"     { capabilities = ["create", "read", "update"] }
path "secret/metadata/openchoreo/*" { capabilities = ["create", "read", "update"] }
