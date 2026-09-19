REPO ?= https://github.com/koorikla/platform-lab.git
OLD  := $(shell grep -m1 -oE 'https://github.com/[^ ]+\.git' bootstrap/root-app.yaml)
CTX  := --context mgmt

.PHONY: up down status ui argocd-password kargo-password set-repo kubeconfig lint test rendered-prune
up:              ## resumable: bootstrap k3d -> CAPI builds hub "mgmt" -> clusterctl move -> Argo CD + root app
	./bootstrap/bootstrap.sh
down:            ## workers via CAPI (waits for their containers), then the hub's containers by CAPD label (FORCE=1: see bootstrap.sh)
	./bootstrap/bootstrap.sh down
.PHONY: doctor
doctor:          ## preflight + lab health: docker disk/memory, tool versions, inotify, boot stage, hub, lab lock
	./hack/doctor.sh
status:
	kubectl $(CTX) get applications -n argocd
	kubectl $(CTX) get clusters.cluster.x-k8s.io,machines -n fleet
# Port-forwards, because CAPD publishes no host ports we could use (its LB container maps only 6443 and 8404, hard-coded).
# :8080 = OpenChoreo gateway: *.localhost is loopback in browsers, so http://openchoreo.localhost:8080 lands here and
# the gateway routes by Host; pods use the same URLs through the hub CoreDNS rewrite (fleet/base/hub-coredns.yaml).
ui:              ## OpenChoreo http://openchoreo.localhost:8080, Argo CD :8090, Kargo :8091
	kubectl $(CTX) -n argocd port-forward svc/argocd-server 8090:80 & \
	kubectl $(CTX) -n kargo port-forward svc/kargo-api 8091:80 & \
	{ kubectl $(CTX) -n openchoreo-control-plane port-forward svc/gateway-default 8080:8080 || \
	  echo "OpenChoreo gateway port-forward ended (not installed yet?): :8080 unavailable"; } & wait
argocd-password:
	@kubectl $(CTX) -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kargo-password:  ## Kargo "admin" password: generated once in-cluster by ESO (repos/platform-charts/kargo/templates/admin-secret.yaml)
	@kubectl $(CTX) -n kargo get secret kargo-api-admin -o jsonpath='{.data.adminPassword}' | base64 -d; echo
# owner/repo slugs: Argo CD uses the https form, Kargo the SSH form (deploy key), hack/kargo-deploy-key.sh the bare slug
slug = $(patsubst https://github.com/%.git,%,$(1))
set-repo:        ## make set-repo REPO=https://github.com/you/fork.git
	@[ "$(call slug,$(REPO))" != "$(REPO)" ] || { echo "REPO must look like https://github.com/<owner>/<repo>.git"; exit 1; }
	grep -rlE 'github.com[/:]$(call slug,$(OLD))\.git|REPO:-$(call slug,$(OLD))\}' bootstrap repos hack | xargs sed -i.bak \
	  -e 's#github.com/$(call slug,$(OLD))\.git#github.com/$(call slug,$(REPO)).git#g' \
	  -e 's#github.com:$(call slug,$(OLD))\.git#github.com:$(call slug,$(REPO)).git#g' \
	  -e 's#REPO:-$(call slug,$(OLD))}#REPO:-$(call slug,$(REPO))}#g' && find bootstrap repos hack -name '*.bak' -delete
# The JWT goes in through stdin into a 0600 file in the pod (never an argv) and is deleted right after the login.
.PHONY: bao
bao:             ## shell in openbao-0 logged in as role operator (30 min): hand-written hub secrets under secret/hub/*
	@kubectl $(CTX) -n openbao create token openbao-operator --duration=10m | \
	  kubectl $(CTX) -n openbao exec -i openbao-0 -c openbao -- sh -c 'umask 077; cat > /home/openbao/.operator-jwt'
	@kubectl $(CTX) -n openbao exec -it openbao-0 -c openbao -- sh -c \
	  'BAO_TOKEN=$$(bao write -field=token auth/kubernetes/login role=operator jwt=@/home/openbao/.operator-jwt); \
	   rm -f /home/openbao/.operator-jwt; export BAO_TOKEN; echo "operator: secret/hub/* (bao kv put/get secret/hub/<item>)"; exec sh'
kubeconfig:      ## make kubeconfig CLUSTER=dev1 > dev1.kubeconfig   (server = LB IP on the docker network)
	@kubectl $(CTX) -n fleet get secret $(CLUSTER)-kubeconfig -o jsonpath='{.data.value}' | base64 -d
lint:            ## helm lint every chart; render every addon and cluster file
	./hack/lint.sh
test:            ## render assertions (hack/tests/test_*.sh)
	./hack/tests/run.sh
rendered-prune:  ## drop rendered/*:addons/<a> of addons disabled on main (dry run; APPLY=1 pushes)
	./hack/rendered-prune.sh $(if $(APPLY),--apply)
