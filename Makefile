KUBE_CONTEXT ?= gke_mofilabs_us-central1-a_ate-cluster
NAMESPACE ?= compute-obtainability
COMPUTE_CLASS ?= obtainable-compute

.PHONY: apply unlock-arm watch status logs verify clean

apply:
	kubectl --context="$(KUBE_CONTEXT)" apply -f manifests/01-computeclass-fallback.yaml
	kubectl --context="$(KUBE_CONTEXT)" apply -f manifests/02-silicon-inspector.yaml

unlock-arm:
	kubectl --context="$(KUBE_CONTEXT)" apply -f manifests/03-computeclass-obtainable-arm.yaml

watch:
	KUBE_CONTEXT="$(KUBE_CONTEXT)" ./hack/watch.sh

status:
	KUBE_CONTEXT="$(KUBE_CONTEXT)" ./hack/watch.sh --once

logs:
	kubectl --context="$(KUBE_CONTEXT)" -n "$(NAMESPACE)" logs -l app=silicon-inspector --tail=4

verify:
	KUBE_CONTEXT="$(KUBE_CONTEXT)" ./hack/verify-e2e.sh

clean:
	kubectl --context="$(KUBE_CONTEXT)" delete -f manifests/02-silicon-inspector.yaml --ignore-not-found=true
	kubectl --context="$(KUBE_CONTEXT)" delete computeclass "$(COMPUTE_CLASS)" --ignore-not-found=true
