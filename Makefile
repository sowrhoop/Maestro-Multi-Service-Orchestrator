IMAGE?=maestro-orchestrator
PLATFORMS?=linux/amd64
SMOKE_CONTAINER?=$(IMAGE)-smoke
BUILD_ARGS=\
	--build-arg SERVICE_A_REPO="$(SERVICE_A_REPO)" \
	--build-arg SERVICE_A_REF="$(SERVICE_A_REF)" \
	--build-arg SERVICE_A_SUBDIR="$(SERVICE_A_SUBDIR)" \
	--build-arg SERVICE_A_INSTALL_CMD="$(SERVICE_A_INSTALL_CMD)" \
	--build-arg SERVICE_B_REPO="$(SERVICE_B_REPO)" \
	--build-arg SERVICE_B_REF="$(SERVICE_B_REF)" \
	--build-arg SERVICE_B_SUBDIR="$(SERVICE_B_SUBDIR)" \
	--build-arg SERVICE_B_INSTALL_CMD="$(SERVICE_B_INSTALL_CMD)"

PUSH?=false
ifeq ($(PUSH),true)
	BUILD_OUTPUT=--push
else
	BUILD_OUTPUT=--load
endif

SERVICE_A_REPO?=
SERVICE_A_REF?=main
SERVICE_A_SUBDIR?=
SERVICE_A_INSTALL_CMD?=
SERVICE_B_REPO?=
SERVICE_B_REF?=main
SERVICE_B_SUBDIR?=
SERVICE_B_INSTALL_CMD?=

.PHONY: build buildx push run shell clean tag release smoke test

build:
	docker build -t $(IMAGE) $(BUILD_ARGS) .

buildx:
	docker buildx build $(BUILD_OUTPUT) --platform $(PLATFORMS) -t $(IMAGE) $(BUILD_ARGS) .

push:
	@if [ -z "$(REGISTRY)" ]; then echo "Set REGISTRY, e.g. REGISTRY=docker.io/<namespace>"; exit 1; fi
	docker tag $(IMAGE) $(REGISTRY)/$(IMAGE):latest
	docker push $(REGISTRY)/$(IMAGE):latest

run:
	docker run -d --name $(IMAGE) \
		--read-only --cap-drop ALL --security-opt no-new-privileges \
		--pids-limit 512 --memory 1g --cpus 1.0 \
		--tmpfs /tmp:rw,noexec,nosuid,size=64m \
		--tmpfs /home/svc_a:rw,nosuid,size=32m \
		--tmpfs /home/svc_b:rw,nosuid,size=32m \
		-p 8080:8080 -p 9090:9090 \
		$(IMAGE)

shell:
	docker exec -it $(IMAGE) /bin/sh

smoke: build
	-@docker rm -f $(SMOKE_CONTAINER) >/dev/null 2>&1 || true
	docker run -d --name $(SMOKE_CONTAINER) \
		-e DEFAULT_SERVICES_MODE=never \
		$(IMAGE)
	docker exec $(SMOKE_CONTAINER) pgrep -x supervisord >/dev/null || \
		( docker logs $(SMOKE_CONTAINER) && docker rm -f $(SMOKE_CONTAINER) && exit 1 )
	-@docker rm -f $(SMOKE_CONTAINER) >/dev/null 2>&1 || true

test: smoke
	@echo "Smoke test passed"

clean:
	-docker rm -f $(IMAGE) 2>/dev/null || true
	-docker rmi $(IMAGE) 2>/dev/null || true

# Tag and push a git tag to trigger the workflow
VERSION?=
tag:
	@if [ -z "$(VERSION)" ]; then echo "Usage: make tag VERSION=1.2.3"; exit 1; fi
	git tag -a v$(VERSION) -m "Release v$(VERSION)"
	git push origin v$(VERSION)

release: build tag
