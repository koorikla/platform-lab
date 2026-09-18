REPO ?= https://github.com/koorikla/platform-lab.git
OLD  := $(shell grep -m1 -oE 'https://github.com/[^ ]+\.git' bootstrap/root-app.yaml)
CTX  := --context k3d-mgmt

.PHONY: up down status argocd-password set-repo kubeconfig lint
up:              ## k3d + argo + root app
	./bootstrap/bootstrap.sh
down:            ## delete workers first (CAPD containers), then mgmt
	-kubectl $(CTX) delete clusters.cluster.x-k8s.io -n fleet --all --timeout=5m
	k3d cluster delete mgmt
status:
	kubectl $(CTX) get applications -n argocd
	kubectl $(CTX) get clusters.cluster.x-k8s.io,machines -n fleet
argocd-password:
	@kubectl $(CTX) -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
set-repo:        ## make set-repo REPO=https://github.com/you/fork.git
	grep -rl '$(OLD)' bootstrap repos | xargs sed -i.bak 's#$(OLD)#$(REPO)#g' && find bootstrap repos -name '*.bak' -delete
kubeconfig:      ## make kubeconfig CLUSTER=dev1 > dev1.kubeconfig
	@kubectl $(CTX) -n fleet get secret $(CLUSTER)-kubeconfig -o jsonpath='{.data.value}' | base64 -d
lint:            ## helm lint every chart; render the cluster chart with every fleet file
	./hack/lint.sh
