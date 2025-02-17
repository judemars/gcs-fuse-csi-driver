# Copyright 2018 The Kubernetes Authors.
# Copyright 2022 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

export REGISTRY ?= jiaxun
export STAGINGVERSION ?= $(shell git describe --long --tags --match='v*' --dirty 2>/dev/null || git rev-list -n1 HEAD)
export OVERLAY ?= stable
export BUILD_GCSFUSE_FROM_SOURCE ?= false
BINDIR ?= bin
GCSFUSE_PATH ?= $(shell cat cmd/sidecar_mounter/gcsfuse_binary)
LDFLAGS ?= -s -w -X main.version=${STAGINGVERSION} -extldflags '-static'
PROJECT ?= $(shell gcloud config get-value project 2>&1 | head -n 1)
CA_BUNDLE ?= $(shell kubectl config view --raw -o json | jq '.clusters[]' | jq "select(.name == \"$(shell kubectl config current-context)\")" | jq '.cluster."certificate-authority-data"' | head -n 1)

DRIVER_BINARY = gcs-fuse-csi-driver
SIDECAR_BINARY = gcs-fuse-csi-driver-sidecar-mounter
WEBHOOK_BINARY = gcs-fuse-csi-driver-webhook

DRIVER_IMAGE = ${REGISTRY}/${DRIVER_BINARY}
SIDECAR_IMAGE = ${REGISTRY}/${SIDECAR_BINARY}
WEBHOOK_IMAGE = ${REGISTRY}/${WEBHOOK_BINARY}

DOCKER_BUILDX_ARGS ?= --push --builder multiarch-multiplatform-builder --build-arg STAGINGVERSION=${STAGINGVERSION}
ifneq ("$(shell docker buildx build --help | grep 'provenance')", "")
DOCKER_BUILDX_ARGS += --provenance=false
endif

$(info OVERLAY is ${OVERLAY})
$(info STAGINGVERSION is ${STAGINGVERSION})
$(info DRIVER_IMAGE is ${DRIVER_IMAGE})
$(info SIDECAR_IMAGE is ${SIDECAR_IMAGE})
$(info WEBHOOK_IMAGE is ${WEBHOOK_IMAGE})

all: build-image-and-push-multi-arch

driver:
	mkdir -p ${BINDIR}
	CGO_ENABLED=0 GOOS=linux GOARCH=$(shell dpkg --print-architecture) go build -mod vendor -ldflags "${LDFLAGS}" -o ${BINDIR}/${DRIVER_BINARY} cmd/csi_driver/main.go

sidecar-mounter:
	mkdir -p ${BINDIR}
	CGO_ENABLED=0 GOOS=linux GOARCH=$(shell dpkg --print-architecture) go build -mod vendor -ldflags "${LDFLAGS}" -o ${BINDIR}/${SIDECAR_BINARY} cmd/sidecar_mounter/main.go

webhook:
	mkdir -p ${BINDIR}
	CGO_ENABLED=0 GOOS=linux GOARCH=$(shell dpkg --print-architecture) go build -mod vendor -ldflags "${LDFLAGS}" -o ${BINDIR}/${WEBHOOK_BINARY} cmd/webhook/main.go

download-gcsfuse:
	mkdir -p ${BINDIR}/linux/amd64 ${BINDIR}/linux/arm64
	
ifeq (${BUILD_GCSFUSE_FROM_SOURCE}, true)
	docker rm -f local_gcsfuse 2> /dev/null || true
	
	docker buildx build \
		--file ./cmd/sidecar_mounter/Dockerfile.gcsfuse \
		--tag local/gcsfuse:latest \
		--load .
	docker create --name local_gcsfuse local/gcsfuse:latest
	docker cp local_gcsfuse:/tmp/linux/amd64/gcsfuse ${BINDIR}/linux/amd64/gcsfuse
	docker cp local_gcsfuse:/tmp/linux/arm64/gcsfuse ${BINDIR}/linux/arm64/gcsfuse
	docker rm -f local_gcsfuse
else
	gsutil cp ${GCSFUSE_PATH}/linux/amd64/gcsfuse ${BINDIR}/linux/amd64/gcsfuse
	gsutil cp ${GCSFUSE_PATH}/linux/arm64/gcsfuse ${BINDIR}/linux/arm64/gcsfuse
endif

	chmod +x ${BINDIR}/linux/amd64/gcsfuse
	chmod +x ${BINDIR}/linux/arm64/gcsfuse
	
	chmod 0555 ${BINDIR}/linux/amd64/gcsfuse
	chmod 0555 ${BINDIR}/linux/arm64/gcsfuse

	${BINDIR}/linux/$(shell dpkg --print-architecture)/gcsfuse --version

init-buildx:
	# Ensure we use a builder that can leverage it (the default on linux will not)
	-docker buildx rm multiarch-multiplatform-builder
	docker buildx create --use --name=multiarch-multiplatform-builder
	docker run --rm --privileged multiarch/qemu-user-static --reset --credential yes --persistent yes
	# Register gcloud as a Docker credential helper.
	# Required for "docker buildx build --push".
	gcloud auth configure-docker --quiet

build-image-and-push-multi-arch: init-buildx download-gcsfuse build-image-linux-amd64 build-image-linux-arm64
	docker manifest create ${DRIVER_IMAGE}:${STAGINGVERSION} ${DRIVER_IMAGE}:${STAGINGVERSION}_linux_amd64 ${DRIVER_IMAGE}:${STAGINGVERSION}_linux_arm64
	docker manifest push --purge ${DRIVER_IMAGE}:${STAGINGVERSION}

	docker manifest create ${SIDECAR_IMAGE}:${STAGINGVERSION} ${SIDECAR_IMAGE}:${STAGINGVERSION}_linux_amd64 ${SIDECAR_IMAGE}:${STAGINGVERSION}_linux_arm64
	docker manifest push --purge ${SIDECAR_IMAGE}:${STAGINGVERSION}

	docker manifest create ${WEBHOOK_IMAGE}:${STAGINGVERSION} ${WEBHOOK_IMAGE}:${STAGINGVERSION}_linux_amd64
	docker manifest push --purge ${WEBHOOK_IMAGE}:${STAGINGVERSION}

build-image-linux-amd64:
	docker buildx build \
		--file ./cmd/csi_driver/Dockerfile \
		--tag validation_linux_amd64 \
		--platform=linux/amd64 \
		--target validation-image .

	docker buildx build ${DOCKER_BUILDX_ARGS} \
		--file ./cmd/csi_driver/Dockerfile \
		--tag ${DRIVER_IMAGE}:${STAGINGVERSION}_linux_amd64 \
		--platform linux/amd64 .

	docker buildx build ${DOCKER_BUILDX_ARGS} \
		--file ./cmd/sidecar_mounter/Dockerfile \
		--tag ${SIDECAR_IMAGE}:${STAGINGVERSION}_linux_amd64 \
		--platform linux/amd64 \
		--build-arg TARGETPLATFORM=linux/amd64 .

	docker buildx build ${DOCKER_BUILDX_ARGS} \
		--file ./cmd/webhook/Dockerfile \
		--tag ${WEBHOOK_IMAGE}:${STAGINGVERSION}_linux_amd64 \
		--platform linux/amd64 .

build-image-linux-arm64:
	docker buildx build \
		--file ./cmd/csi_driver/Dockerfile \
		--tag validation_linux_arm64 \
		--platform=linux/arm64 \
		--target validation-image .
	
	docker buildx build ${DOCKER_BUILDX_ARGS} \
		--file ./cmd/csi_driver/Dockerfile \
		--tag ${DRIVER_IMAGE}:${STAGINGVERSION}_linux_arm64 \
		--platform linux/arm64 .

	docker buildx build ${DOCKER_BUILDX_ARGS} \
		--file ./cmd/sidecar_mounter/Dockerfile \
		--tag ${SIDECAR_IMAGE}:${STAGINGVERSION}_linux_arm64 \
		--platform linux/arm64 \
		--build-arg TARGETPLATFORM=linux/arm64 .

install:
	make generate-spec-yaml OVERLAY=${OVERLAY} REGISTRY=${REGISTRY} STAGINGVERSION=${STAGINGVERSION}
	kubectl apply -f ${BINDIR}/gcs-fuse-csi-driver-specs-generated.yaml
	./deploy/base/webhook/create-cert.sh

uninstall:
	kubectl delete -k deploy/overlays/${OVERLAY} --wait

generate-spec-yaml:
	mkdir -p ${BINDIR}
	./deploy/install-kustomize.sh
	cd ./deploy/overlays/${OVERLAY}; ../../../${BINDIR}/kustomize edit set image gke.gcr.io/gcs-fuse-csi-driver=${DRIVER_IMAGE}:${STAGINGVERSION};
	cd ./deploy/overlays/${OVERLAY}; ../../../${BINDIR}/kustomize edit set image gke.gcr.io/gcs-fuse-csi-driver-webhook=${WEBHOOK_IMAGE}:${STAGINGVERSION};
	cd ./deploy/overlays/${OVERLAY}; ../../../${BINDIR}/kustomize edit add configmap gcsfusecsi-image-config --behavior=merge --disableNameSuffixHash --from-literal=sidecar-image=${SIDECAR_IMAGE}:${STAGINGVERSION};
	echo "[{\"op\": \"replace\",\"path\": \"/spec/tokenRequests/0/audience\",\"value\": \"${PROJECT}.svc.id.goog\"}]" > ./deploy/overlays/${OVERLAY}/project_patch_csi_driver.json
	echo "[{\"op\": \"replace\",\"path\": \"/webhooks/0/clientConfig/caBundle\",\"value\": \"${CA_BUNDLE}\"}]" > ./deploy/overlays/${OVERLAY}/caBundle_patch_MutatingWebhookConfiguration.json
	kubectl kustomize deploy/overlays/${OVERLAY} | tee ${BINDIR}/gcs-fuse-csi-driver-specs-generated.yaml > /dev/null
	git restore ./deploy/overlays/${OVERLAY}/kustomization.yaml
	git restore ./deploy/overlays/${OVERLAY}/project_patch_csi_driver.json
	git restore ./deploy/overlays/${OVERLAY}/caBundle_patch_MutatingWebhookConfiguration.json

verify:
	hack/verify-all.sh

unit-test:
	go test -v -mod=vendor -timeout 30s "./pkg/..." -cover

sanity-test:
	go test -v -mod=vendor -timeout 30s "./test/sanity/" -run TestSanity

e2e-test:
	./test/e2e/run-e2e-local.sh

perf-test:
	make e2e-test E2E_TEST_USE_MANAGED_DRIVER=true E2E_TEST_GINKGO_TIMEOUT=3h E2E_TEST_SKIP= E2E_TEST_FOCUS=should.succeed.in.performance.test E2E_TEST_GINKGO_FLAKE_ATTEMPTS=1
