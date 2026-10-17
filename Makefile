KUBE_CONTEXT ?= $(shell kubectl config current-context 2>/dev/null)
NAMESPACE ?= compute-obtainability
COMPUTE_CLASS ?= obtainable-compute
STATEFUL_NAMESPACE ?= obtainability-stateful
STATEFUL_COMPUTE_CLASS ?= obtainable-stateful

.PHONY: apply apply-multi-arch apply-stateful unlock-arm unlock-gen4 \
	watch watch-multi-arch watch-stateful status status-multi-arch status-stateful \
	logs logs-multi-arch logs-stateful verify verify-multi-arch verify-stateful \
	clean clean-multi-arch clean-stateful

apply: apply-multi-arch

apply-multi-arch:
	kubectl --context="$(KUBE_CONTEXT)" apply -f manifests/01-multi-arch/01-computeclass-fallback.yaml
	kubectl --context="$(KUBE_CONTEXT)" apply -f manifests/01-multi-arch/02-silicon-inspector.yaml

apply-stateful:
	kubectl --context="$(KUBE_CONTEXT)" apply -f manifests/02-stateful-storage/01-computeclass-fallback.yaml
	kubectl --context="$(KUBE_CONTEXT)" apply -f manifests/02-stateful-storage/02-storage-inspector.yaml

unlock-arm:
	kubectl --context="$(KUBE_CONTEXT)" apply -f manifests/01-multi-arch/03-computeclass-obtainable-arm.yaml

unlock-gen4:
	kubectl --context="$(KUBE_CONTEXT)" apply -f manifests/02-stateful-storage/03-computeclass-obtainable-gen4.yaml
	kubectl --context="$(KUBE_CONTEXT)" -n "$(STATEFUL_NAMESPACE)" scale statefulset/storage-inspector --replicas=2

watch: watch-multi-arch

watch-multi-arch:
	KUBE_CONTEXT="$(KUBE_CONTEXT)" ./hack/watch.sh

watch-stateful:
	KUBE_CONTEXT="$(KUBE_CONTEXT)" ./hack/watch-stateful.sh

status: status-multi-arch

status-multi-arch:
	KUBE_CONTEXT="$(KUBE_CONTEXT)" ./hack/watch.sh --once

status-stateful:
	KUBE_CONTEXT="$(KUBE_CONTEXT)" ./hack/watch-stateful.sh --once

logs: logs-multi-arch

logs-multi-arch:
	kubectl --context="$(KUBE_CONTEXT)" -n "$(NAMESPACE)" logs -l app=silicon-inspector --tail=4

logs-stateful:
	kubectl --context="$(KUBE_CONTEXT)" -n "$(STATEFUL_NAMESPACE)" logs -l app=storage-inspector --tail=4

verify: verify-multi-arch

verify-multi-arch:
	KUBE_CONTEXT="$(KUBE_CONTEXT)" ./hack/verify-e2e.sh

verify-stateful:
	KUBE_CONTEXT="$(KUBE_CONTEXT)" ./hack/verify-stateful-e2e.sh

clean: clean-multi-arch clean-stateful

clean-multi-arch:
	kubectl --context="$(KUBE_CONTEXT)" delete -f manifests/01-multi-arch/02-silicon-inspector.yaml --ignore-not-found=true
	kubectl --context="$(KUBE_CONTEXT)" delete computeclass "$(COMPUTE_CLASS)" --ignore-not-found=true

clean-stateful:
	kubectl --context="$(KUBE_CONTEXT)" -n "$(STATEFUL_NAMESPACE)" delete statefulset storage-inspector --ignore-not-found=true
	kubectl --context="$(KUBE_CONTEXT)" -n "$(STATEFUL_NAMESPACE)" delete pvc --all --ignore-not-found=true
	kubectl --context="$(KUBE_CONTEXT)" delete -f manifests/02-stateful-storage/02-storage-inspector.yaml --ignore-not-found=true
	kubectl --context="$(KUBE_CONTEXT)" delete computeclass "$(STATEFUL_COMPUTE_CLASS)" --ignore-not-found=true
