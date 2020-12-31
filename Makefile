SHELL := bash
.SHELLFLAGS := -o pipefail -euc

export PATH := bin:$(PATH)

-include .env
export

BUILD := build/$(T)/$(L)
DEB := riju-$(T)-$(L).deb
S3_DEBS := s3://$(S3_BUCKET)-debs
S3_DEB := $(S3_DEBS)/debs/$(DEB)
S3_HASH := $(S3_DEBS)/hashes/riju-$(T)-$(L)

.PHONY: help
help:
	@echo "usage:"
	@echo
	@cat Makefile | \
		grep -E '[.]PHONY|[#]##' | \
		sed -E 's/[.]PHONY: */  make /' | \
		sed -E 's/[#]## *(.+)/\n    (\1)\n/'

### Build artifacts locally

.PHONY: image
image:
	@: $${I}
ifeq ($(I),composite)
	node tools/build-composite-image.js
else
	docker build . -f docker/$(I)/Dockerfile -t riju:$(I)
endif

.PHONY: script
script:
	@: $${L} $${T}
	mkdir -p $(BUILD)
	node tools/generate-build-script.js --lang $(L) --type $(T) > $(BUILD)/build.bash
	chmod +x $(BUILD)/build.bash

.PHONY: pkg
pkg:
	@: $${L} $${T}
	rm -rf $(BUILD)/src $(BUILD)/pkg
	mkdir -p $(BUILD)/src $(BUILD)/pkg
	cd $(BUILD)/src && pkg="$(PWD)/$(BUILD)/pkg" ../build.bash
	fakeroot dpkg-deb --build $(BUILD)/pkg $(BUILD)/$(DEB)

### Manipulate artifacts inside Docker

VOLUME_MOUNT ?= $(PWD)

P1 ?= 6119
P2 ?= 6120

ifneq (,$(E))
SHELL_PORTS := -p 127.0.0.1:$(P1):6119 -p 127.0.0.1:$(P2):6120
else
SHELL_PORTS :=
endif

.PHONY: shell
shell:
	@: $${I}
ifeq ($(I),admin)
	docker run -it --rm --hostname $(I) -v $(VOLUME_MOUNT):/src -v /var/run/docker.sock:/var/run/docker.sock -v $(HOME)/.aws:/var/riju/.aws -v $(HOME)/.docker:/var/riju/.docker -v $(HOME)/.ssh:/var/riju/.ssh -v $(HOME)/.terraform.d:/var/riju/.terraform.d -e AWS_REGION -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e DOCKER_USERNAME -e DOCKER_PASSWORD -e DEPLOY_SSH_PRIVATE_KEY -e DOCKER_REPO -e S3_BUCKET -e DOMAIN -e VOLUME_MOUNT=$(VOLUME_MOUNT) $(SHELL_PORTS) --network host riju:$(I) $(CMD)
else ifneq (,$(filter $(I),compile app))
	docker run -it --rm --hostname $(I) $(SHELL_PORTS) riju:$(I) $(CMD)
else
	docker run -it --rm --hostname $(I) -v $(VOLUME_MOUNT):/src $(SHELL_PORTS) riju:$(I) $(CMD)
endif

.PHONY: install
install:
	@: $${L} $${T}
	if [[ -z "$$(ls -A /var/lib/apt/lists)" ]]; then sudo apt update; fi
	sudo apt reinstall -y ./$(BUILD)/$(DEB)

### Build and run application code

.PHONY: frontend
frontend:
	npx webpack --mode=production

.PHONY: frontend-dev
frontend-dev:
	watchexec -w webpack.config.cjs -w node_modules -r --no-environment -- "echo 'Running webpack...' >&2; npx webpack --mode=development --watch"

.PHONY: system
system:
	./system/compile.bash

.PHONY: system-dev
system-dev:
	watchexec -w system/src -n -- ./system/compile.bash

.PHONY: server
server:
	node backend/server.js

.PHONY: server-dev
server-dev:
	watchexec -w backend -r -n -- node backend/server.js

.PHONY: build
build: frontend system

.PHONY: dev
dev:
	make -j3 frontend-dev system-dev server-dev

.PHONY: test
test:
	node backend/test-runner.js $(F)

### Fetch artifacts from registries

.PHONY: pull-base
pull-base:
	docker pull ubuntu:rolling

.PHONY: pull
pull:
	@: $${I} $${DOCKER_REPO}
	docker pull $(DOCKER_REPO):$(I)
	docker tag $(DOCKER_REPO):$(I) riju:$(I)

.PHONY: download
download:
	@: $${L} $${T} $${S3_BUCKET}
	mkdir -p $(BUILD)
	aws s3 cp $(S3_DEB) $(BUILD)/$(DEB)

### Publish artifacts to registries

.PHONY: push
push:
	@: $${I} $${DOCKER_REPO}
	docker tag riju:$(I) $(DOCKER_REPO):$(I)
	docker push $(DOCKER_REPO):$(I)

.PHONY: upload
upload:
	@: $${L} $${T} $${S3_BUCKET}
	aws s3 rm --recursive $(S3_HASH)
	aws s3 cp $(BUILD)/$(DEB) $(S3_DEB)
	hash=$$(dpkg-deb -f $(BUILD)/$(DEB) Riju-Script-Hash); test $${hash}; echo $${hash}; aws s3 cp - $(S3_HASH)/$${hash} < /dev/null

.PHONY: publish
publish:
	tools/publish.bash

### Miscellaneous

.PHONY: dockerignore
dockerignore:
	echo "# This file is generated by 'make dockerignore', do not edit." > .dockerignore
	cat .gitignore | sed 's#^#**/#' >> .dockerignore

.PHONY: env
env:
	exec bash --rcfile <(cat ~/.bashrc - <<< 'PS1="[.env] $$PS1"')
