WORKSPACE=$(shell pwd)
PACKAGEPATH=./build

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif


ifdef TAG_OVERRIDE
	export GITTAG=${TAG_OVERRIDE}
else
	export GITTAG=$(shell git describe --always)
endif

export BUILDTIME = $(shell date +%Y-%m-%dT%T%z)
export GITHASH=$(shell git rev-parse HEAD)

# Setting SHELL to bash allows bash commands to be executed by recipes.
# This is a requirement for 'setup-envtest.sh' in the test target.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec


##@ Build
.PHONY: all
all: build-all

.PHONY: build-all
build-all: build

.PHONY: build
build: config-watcher

.PHONY: config-watcher
config-watcher:
	mkdir -p "${WORKSPACE}/${PACKAGEPATH}"
	cd src/config-watcher && go build -o ${WORKSPACE}/${PACKAGEPATH}/config-watcher . && cd -

##@ Edition

.PHONY: edition
edition:
	cd src/apisix && editionctl info

.PHONY: edition-te
edition-te:
	cd src/apisix && editionctl activate TE

.PHONY: edition-ee
edition-ee:
	cd src/apisix && editionctl activate EE

.PHONY: edition-reset
edition-reset:
	cd src/apisix && editionctl reset

##@ Develop

.PHONY: init
init: apisix-dependencies apisix-core
	# TODO: install lua rocks first https://luarocks.org/
	pip install -r ./src/apisix/requirements.txt
	pip install pre-commit
	pre-commit install
	cd src/apisix && make apisix-test-busted


.PHONY: lint
lint:
	cd src/apisix && make lint

.PHONY: check-license
check-license:
	find . -name "*.lua" -not -path "./src/apisix-core/*" -not -path "./.lua_modules/*" | xargs -n 1 grep -L 'TencentBlueKing is pleased to '
	find . -name "*.lua" -not -path "./src/apisix-core/*" -not -path "./.lua_modules/*" | xargs -n 1 grep -L 'TencentBlueKing is pleased to ' | wc -l | xargs -I {} bash -c '[[ {} -eq 0 ]] && exit 0 || exit 1'


apisix-core: .gitmodules
	git submodule update --init --recursive
	git submodule update --recursive --remote

.PHONY: apisix-dependencies
apisix-dependencies: apisix-core
	# yum install -y openresty-openssl-devel
	luarocks install --tree .lua_modules --only-deps --keep \
	${WORKSPACE}/src/apisix-core/rockspec/apisix-3.2.2-0.rockspec --server https://luarocks.cn

.PHONY: apisix-dev-image
apisix-dev-image: build edition-ee
	docker build -f Dockerfile . -t bk-micro-gateway-apisix:development
	kind load docker-image bk-micro-gateway-apisix:development 



