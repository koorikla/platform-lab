# Role openbao-config = the configure sidecar (server SA). Written once by self-init (bootstrap), then kept by
# configure.sh. It may write any policy and any hub role, so it is OpenBao admin by design; its only input is this
# chart. Exactly the calls configure.sh makes (hack/tests/test_openbao.sh checks).
path "sys/mounts"             { capabilities = ["read"] }
path "sys/mounts/secret"      { capabilities = ["create", "update"] }
path "auth/kubernetes/role/*" { capabilities = ["create", "update"] }
path "sys/policies/acl/*"     { capabilities = ["create", "update"] }
