KUBE_CONTEXT ?= gke_mofilabs_us-central1-a_ate-cluster
NAMESPACE ?= compute-obtainability
COMPUTE_CLASS ?= obtainable-compute
STATEFUL_NAMESPACE ?= obtainability-stateful
STATEFUL_COMPUTE_CLASS ?= obtainable-stateful

.PHONY: apply apply-multi-arch apply-stateful unlock-arm watch watch-multi-arch status logs verify clean clean-multi-arch clean-stateful

apply: apply-multi-arch

apply-multi-arch:
	kubectl --context="$(KUBE_CONTEXT)" apply -f manifests/01-multi-arch/01-computeclass-fallback.yaml
	kubectl --context="$(KUBE_CONTEXT)" apply -f manifests/01-multi-arch/02-silicon-inspector.yaml

apply-stateful:
	kubectl --context="$(KUBE_CONTEXT)" apply -f manifests/02-stateful-storage/01-computeclass-fallback.yaml
	kubectl --context="$(KUBE_CONTEXT)" apply -f manifests/02-stateful-storage/02-storage-inspector.yaml

unlock-arm:
	kubectl --context="$(KUBE_CONTEXT)" apply -f manifests/01-multi-arch/03-computeclass-obtainable-arm.yaml

watch: watch-multi-arch

watch-multi-arch:
	KUBE_CONTEXT="$(KUBE_CONTEXT)" ./hack/watch.sh

status:
	KUBE_CONTEXT="$(KUBE_CONTEXT)" ./hack/watch.sh --once

logs:
	kubectl --context="$(KUBE_CONTEXT)" -n "$(NAMESPACE)" logs -l app=silicon-inspector --tail=4

verify:
	KUBE_CONTEXT="$(KUBE_CONTEXT)" ./hack/verify-e2e.sh

clean: clean-multi-arch

clean-multi-arch:
	kubectl --context="$(KUBE_CONTEXT)" delete -f manifests/01-multi-arch/02-silicon-inspector.yaml --ignore-not-found=true
	kubectl --context="$(KUBE_CONTEXT)" delete computeclass "$(COMPUTE_CLASS)" --ignore-not-found=true

clean-stateful:
	kubectl --context="$(KUBE_CONTEXT)" -n "$(STATEFUL_NAMESPACE)" delete pvc --all --ignore-not-found=true
	kubectl --context="$(KUBE_CONTEXT)" delete -f manifests/02-stateful-storage/02-storage-inspector.yaml --ignore-not-found=true
	kubectl --context="$(KUBE_CONTEXT)" delete computeclass "$(STATEFUL_COMPUTE_CLASS)" --ignore-not-found=true
