# Use bash shell with pipefail option enabled so that the return status of a
# piped command is the value of the last (rightmost) commnand to exit with a
# non-zero status. This lets us pipe output into tee but still exit on test
# failures.
SHELL = /bin/bash
.SHELLFLAGS = -o pipefail -c

# Image URL to use all building/pushing image targets
# ENVTEST_K8S_VERSION refers to the version of kubebuilder assets to be downloaded by envtest binary.
ENVTEST_K8S_VERSION = 1.27.1
KUBE_NAMESPACE ?= kube-system
WEBHOOK_SERVICE_NAME = pv-webhook-service
CERT_DIR = /tmp/k8s-webhook-server/serving-certs
TEMP_DIRECTORY := $(shell mktemp -d)
ROOT_DIR:=$(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))
LOG_LEVEL ?= INFO
HELM_CHARTS_TO_PUBLISH ?= cephfs-persistentvolume cephfs-persistentvolume-crd
HELM_CHARTS ?= $(HELM_CHARTS_TO_PUBLISH)
HELM_CHARTS_CHANNEL ?= release

# Produce CRDs that work back to Kubernetes 1.11 (no version conversion)
CRD_OPTIONS ?= "crd:trivialVersions=true"


# Image URL to use all building/pushing image targets
VERSION ?= 0.0.1
IMG ?= registry.gitlab.com/piersharding/cephfs-persistentvolume/controller:$(VERSION)

CAR_OCI_REGISTRY_HOST=registry.gitlab.com/piersharding/cephfs-persistentvolume
TAG=$(VERSION)


# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# CONTAINER_TOOL defines the container tool to be used for building images.
# Be aware that the target commands are only tested with Docker which is
# scaffolded by default. However, you might want to replace it to use other
# tools. (i.e. podman)
CONTAINER_TOOL ?= docker

# Setting SHELL to bash allows bash commands to be executed by recipes.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

.PHONY: all
all: build

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk commands is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Development

.PHONY: manifests
manifests: controller-gen ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
	$(CONTROLLER_GEN) rbac:roleName=manager-role crd webhook paths="./..." output:crd:artifacts:config=config/crd/bases

.PHONY: generate
generate: controller-gen ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
	$(CONTROLLER_GEN) object:headerFile="hack/boilerplate.go.txt" paths="./..."

.PHONY: fmt
fmt: ## Run go fmt against code.
	go fmt ./...

.PHONY: vet
vet: ## Run go vet against code.
	go vet ./...

.PHONY: test
test: manifests generate fmt vet envtest ## Run tests.
	KUBEBUILDER_ASSETS="$(shell $(ENVTEST) use $(ENVTEST_K8S_VERSION) --bin-dir $(LOCALBIN) -p path)" go test ./... -coverprofile cover.out

##@ Build

.PHONY: build
build: manifests generate fmt vet ## Build manager binary.
	go build -o bin/manager cmd/main.go

.PHONY: run
run: manifests generate fmt vet ## Run a controller from your host.
	go run ./cmd/main.go

# If you wish built the manager image targeting other platforms you can use the --platform flag.
# (i.e. docker build --platform linux/arm64 ). However, you must enable docker buildKit for it.
# More info: https://docs.docker.com/develop/develop-images/build_enhancements/
.PHONY: docker-build
docker-build: test ## Build docker image with the manager.
	$(CONTAINER_TOOL) build -t ${IMG} .

.PHONY: docker-push
docker-push: ## Push docker image with the manager.
	$(CONTAINER_TOOL) push ${IMG}

# PLATFORMS defines the target platforms for  the manager image be build to provide support to multiple
# architectures. (i.e. make docker-buildx IMG=myregistry/mypoperator:0.0.1). To use this option you need to:
# - able to use docker buildx . More info: https://docs.docker.com/build/buildx/
# - have enable BuildKit, More info: https://docs.docker.com/develop/develop-images/build_enhancements/
# - be able to push the image for your registry (i.e. if you do not inform a valid value via IMG=<myregistry/image:<tag>> then the export will fail)
# To properly provided solutions that supports more than one platform you should use this option.
PLATFORMS ?= linux/arm64,linux/amd64,linux/s390x,linux/ppc64le
.PHONY: docker-buildx
docker-buildx: test ## Build and push docker image for the manager for cross-platform support
	# copy existing Dockerfile and insert --platform=${BUILDPLATFORM} into Dockerfile.cross, and preserve the original Dockerfile
	sed -e '1 s/\(^FROM\)/FROM --platform=\$$\{BUILDPLATFORM\}/; t' -e ' 1,// s//FROM --platform=\$$\{BUILDPLATFORM\}/' Dockerfile > Dockerfile.cross
	- $(CONTAINER_TOOL) buildx create --name project-v3-builder
	$(CONTAINER_TOOL) buildx use project-v3-builder
	- $(CONTAINER_TOOL) buildx build --push --platform=$(PLATFORMS) --tag ${IMG} -f Dockerfile.cross .
	- $(CONTAINER_TOOL) buildx rm project-v3-builder
	rm Dockerfile.cross

##@ Deployment

ifndef ignore-not-found
  ignore-not-found = false
endif

.PHONY: install
install: manifests kustomize ## Install CRDs into the K8s cluster specified in ~/.kube/config.
	# $(KUSTOMIZE) build config/crd | $(KUBECTL) apply -f -
	kubectl apply -f config/webhook/manifests.yaml

.PHONY: install
testinstall: manifests kustomize ## Install CRDs into the K8s cluster specified in ~/.kube/config.
	# $(KUSTOMIZE) build config/crd | $(KUBECTL) apply -f -
	kubectl apply -f config/webhook/test-manifests.yaml

.PHONY: uninstall
uninstall: manifests kustomize ## Uninstall CRDs from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	$(KUSTOMIZE) build config/crd | $(KUBECTL) delete --ignore-not-found=$(ignore-not-found) -f -

dry-run: manifests
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	mkdir -p dry-run
	$(KUSTOMIZE) build config/default

.PHONY: deploy
deploy: manifests kustomize ## Deploy controller to the K8s cluster specified in ~/.kube/config.
	cd config/manager && $(KUSTOMIZE) edit set image controller=${IMG}
	$(KUSTOMIZE) build config/default | $(KUBECTL) apply -f -

.PHONY: undeploy
undeploy: ## Undeploy controller from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	$(KUSTOMIZE) build config/default | $(KUBECTL) delete --ignore-not-found=$(ignore-not-found) -f -

##@ Build Dependencies

## Location to install dependencies to
LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)

## Tool Binaries
KUBECTL ?= kubectl
KUSTOMIZE ?= $(LOCALBIN)/kustomize
CONTROLLER_GEN ?= $(LOCALBIN)/controller-gen
ENVTEST ?= $(LOCALBIN)/setup-envtest

## Tool Versions
KUSTOMIZE_VERSION ?= v5.0.1
CONTROLLER_TOOLS_VERSION ?= v0.12.0

.PHONY: kustomize
kustomize: $(KUSTOMIZE) ## Download kustomize locally if necessary. If wrong version is installed, it will be removed before downloading.
$(KUSTOMIZE): $(LOCALBIN)
	@if test -x $(LOCALBIN)/kustomize && ! $(LOCALBIN)/kustomize version | grep -q $(KUSTOMIZE_VERSION); then \
		echo "$(LOCALBIN)/kustomize version is not expected $(KUSTOMIZE_VERSION). Removing it before installing."; \
		rm -rf $(LOCALBIN)/kustomize; \
	fi
	test -s $(LOCALBIN)/kustomize || GOBIN=$(LOCALBIN) GO111MODULE=on go install sigs.k8s.io/kustomize/kustomize/v5@$(KUSTOMIZE_VERSION)

.PHONY: controller-gen
controller-gen: $(CONTROLLER_GEN) ## Download controller-gen locally if necessary. If wrong version is installed, it will be overwritten.
$(CONTROLLER_GEN): $(LOCALBIN)
	test -s $(LOCALBIN)/controller-gen && $(LOCALBIN)/controller-gen --version | grep -q $(CONTROLLER_TOOLS_VERSION) || \
	GOBIN=$(LOCALBIN) go install sigs.k8s.io/controller-tools/cmd/controller-gen@$(CONTROLLER_TOOLS_VERSION)

.PHONY: envtest
envtest: $(ENVTEST) ## Download envtest-setup locally if necessary.
$(ENVTEST): $(LOCALBIN)
	test -s $(LOCALBIN)/setup-envtest || GOBIN=$(LOCALBIN) go install sigs.k8s.io/controller-runtime/tools/setup-envtest@latest


testcerts:
	rm -rf $(CERT_DIR)
	mkdir -p $(CERT_DIR)
	openssl req -x509 -newkey rsa:2048 -keyout $(CERT_DIR)/tls.key -out $(CERT_DIR)/tls.crt -days 365 -nodes -subj "/CN=$(WEBHOOK_SERVICE_NAME).$(KUBE_NAMESPACE).svc"

certs:
	# from https://kubernetes.github.io/ingress-nginx/deploy/validating-webhook/
	rm -rf $(CERT_DIR)
	mkdir -p $(CERT_DIR)
	@echo -e "[req]\n" \
	"req_extensions = v3_req\n" \
	"distinguished_name = req_distinguished_name\n" \
	"[req_distinguished_name]\n" \
	"[ v3_req ]\n" \
	"basicConstraints = CA:FALSE\n" \
	"keyUsage = nonRepudiation, digitalSignature, keyEncipherment\n" \
	"extendedKeyUsage = clientAuth\n" \
	"subjectAltName = @alt_names\n" \
	"[alt_names]\n" \
	"DNS.1 = $(WEBHOOK_SERVICE_NAME)\n" \
	"DNS.2 = $(WEBHOOK_SERVICE_NAME).$(KUBE_NAMESPACE)\n" \
	"DNS.3 = $(WEBHOOK_SERVICE_NAME).$(KUBE_NAMESPACE).svc\n" \
	| sed 's/ //' > $(CERT_DIR)/csr.conf
	cat $(CERT_DIR)/csr.conf
	openssl genrsa -out $(CERT_DIR)/tls.key 2048
	openssl req -new -key $(CERT_DIR)/tls.key \
	-subj "/CN=$(WEBHOOK_SERVICE_NAME).$(KUBE_NAMESPACE).svc" \
	-out $(CERT_DIR)/server.csr \
	-config $(CERT_DIR)/csr.conf
	@echo -e \
	"apiVersion: certificates.k8s.io/v1\n" \
	"kind: CertificateSigningRequest\n" \
	"metadata:\n" \
	"  name: $(WEBHOOK_SERVICE_NAME).$(KUBE_NAMESPACE).svc\n" \
	"spec:\n" \
	"  signerName: kubernetes.io/kube-apiserver-client\n" \
	"  request: $$(cat $(CERT_DIR)/server.csr | base64 -w 0)\n" \
	"  usages:\n" \
	"  - client auth\n" \
	"  - digital signature\n" \
	"  - key encipherment\n" \
	| sed 's/^ //' > $(CERT_DIR)/approve.yaml
	ls -latr $(CERT_DIR)
	cat $(CERT_DIR)/approve.yaml
	kubectl delete -f $(CERT_DIR)/approve.yaml || true
	kubectl apply -f $(CERT_DIR)/approve.yaml
	sleep 3
	kubectl certificate approve $(WEBHOOK_SERVICE_NAME).$(KUBE_NAMESPACE).svc

getcert:
	while true; do \
	STATUS=$$(kubectl get csr $(WEBHOOK_SERVICE_NAME).$(KUBE_NAMESPACE).svc  -o jsonpath='{.status.conditions[].type}'); \
	if [ "$${STATUS}" = "Approved" ]; then break; fi; \
	echo "Status is: $${STATUS} - sleeping"; \
	sleep 10; \
	done
	SERVER_CERT=$$(kubectl get csr $(WEBHOOK_SERVICE_NAME).$(KUBE_NAMESPACE).svc  -o jsonpath='{.status.certificate}') && \
	echo $${SERVER_CERT} | openssl base64 -d -A -out $(CERT_DIR)/tls.crt
	mkdir -p config/webhook/secret
	rm -rf config/webhook/secret/tls.*
	cp $(CERT_DIR)/tls.crt $(CERT_DIR)/tls.key config/webhook/secret/

secret: namespace
	kubectl delete secret webhook-server-cert -n $(KUBE_NAMESPACE) || true
	kubectl create secret generic webhook-server-cert \
	--from-file=tls.key=$(CERT_DIR)/tls.key \
	--from-file=tls.crt=$(CERT_DIR)/tls.crt \
	-n $(KUBE_NAMESPACE)
