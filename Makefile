REPO ?= https://github.com/koorikla/platform-lab.git
OLD  := $(shell grep -m1 -oE 'https://github.com/[^ ]+\.git' bootstrap/root-app.yaml)

.PHONY: up down status argocd-password set-repo kubeconfig lint
up:              ## kind + argo + root app
	./bootstrap/bootstrap.sh
down:            ## delete workers first (CAPD containers), then mgmt
	-kubectl --context kind-mgmt delete clusters.cluster.x-k8s.io -n fleet --all --timeout=5m
	kind delete cluster --name mgmt
status:
	kubectl --context kind-mgmt get applications -n argocd
	kubectl --context kind-mgmt get clusters.cluster.x-k8s.io,machines -n fleet
argocd-password:
	@kubectl --context kind-mgmt -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
set-repo:        ## make set-repo REPO=https://github.com/you/fork.git
	grep -rl '$(OLD)' bootstrap repos | xargs sed -i 's#$(OLD)#$(REPO)#g'
kubeconfig:      ## make kubeconfig CLUSTER=dev1 > dev1.kubeconfig
	@kubectl --context kind-mgmt -n fleet get secret $(CLUSTER)-kubeconfig -o jsonpath='{.data.value}' | base64 -d
lint:
	@for c in repos/platform-charts/*/ repos/apps/*/chart/; do helm dependency build $$c >/dev/null && helm lint $$c; done
