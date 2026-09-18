REPO ?= https://github.com/koorikla/platform-lab.git
OLD  := $(shell grep -m1 -oE 'https://github.com/[^ ]+\.git' bootstrap/root-app.yaml)
CTX  := --context mgmt

.PHONY: up down status ui argocd-password set-repo kubeconfig lint test
up:              ## bootstrap k3d -> CAPI builds hub "mgmt" -> clusterctl move -> Argo CD + root app
	./bootstrap/bootstrap.sh
down:            ## workers via CAPI, then the self-hosted hub's containers (it cannot delete itself)
	-kubectl $(CTX) -n fleet delete clusters.cluster.x-k8s.io -l platform.lab/role=worker --timeout=10m
	-k3d cluster delete bootstrap
	-docker ps -aq --filter label=io.x-k8s.kind.cluster=mgmt | xargs docker rm -f
	-kubectl config delete-context mgmt; kubectl config delete-cluster mgmt; kubectl config delete-user mgmt-admin
status:
	kubectl $(CTX) get applications -n argocd
	kubectl $(CTX) get clusters.cluster.x-k8s.io,machines -n fleet
ui:              ## Argo CD on :8080, Kargo on :8081 (CAPD nodes publish no host ports)
	kubectl $(CTX) -n argocd port-forward svc/argocd-server 8080:80 & \
	kubectl $(CTX) -n kargo port-forward svc/kargo-api 8081:80 & wait
argocd-password:
	@kubectl $(CTX) -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
set-repo:        ## make set-repo REPO=https://github.com/you/fork.git
	grep -rl '$(OLD)' bootstrap repos | xargs sed -i.bak 's#$(OLD)#$(REPO)#g' && find bootstrap repos -name '*.bak' -delete
kubeconfig:      ## make kubeconfig CLUSTER=dev1 > dev1.kubeconfig   (server = LB IP on the docker network)
	@kubectl $(CTX) -n fleet get secret $(CLUSTER)-kubeconfig -o jsonpath='{.data.value}' | base64 -d
lint:            ## helm lint every chart; render every addon and cluster file
	./hack/lint.sh
test:            ## render assertions (hack/tests/test_*.sh)
	./hack/tests/run.sh
