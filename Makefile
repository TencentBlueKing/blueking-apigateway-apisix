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
# .PHONY: build
# build: 

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

.PHONY: apisix-dependencies
apisix-dependencies: apisix-core
	# yum install -y openresty-openssl-devel
	luarocks install --tree .lua_modules --only-deps --keep \
	${WORKSPACE}/src/apisix-core/rockspec/apisix-3.2.0-0.rockspec --server https://luarocks.cn

.PHONY: apisix-dev-image
apisix-dev-image: edition-ee
	docker build -f Dockerfile . -t bk-micro-gateway-apisix:development

.PHONY: apisix-image-smoke
apisix-image-smoke: edition-ee
	docker build -f Dockerfile . -t bk-micro-gateway-apisix:apisix-3.18-smoke
	docker run --rm --entrypoint /bin/bash bk-micro-gateway-apisix:apisix-3.18-smoke -ec '\
		apisix version | grep -F "3.18.0"; \
		/usr/local/openresty/bin/openresty -V 2>&1 | grep -F "ngx_http_ffi_client"; \
		rpm -q libxslt; \
		saml_path="$$(find /usr/local/apisix -name saml.so -print -quit)"; \
		test -n "$$saml_path"; \
		! ldd /usr/local/openresty/nginx/sbin/nginx | grep -F "not found"; \
		! ldd "$$saml_path" | grep -F "not found"; \
		grep -F "self.dict:flush_expired()" /usr/local/apisix/deps/share/lua/5.1/prometheus_keys.lua; \
		luarocks list --tree=/usr/local/apisix/deps | grep -F "nginx-lua-prometheus-api7"; \
		luarocks list --tree=/usr/local/apisix/deps | grep -F "1.0.0-1"; \
		/usr/local/apisix/ops/prometheus-expiry-smoke.sh; \
		apisix init; \
		apisix test'
	test "$$(docker image inspect --format '{{ index .Config.Labels "apisix_version" }}' bk-micro-gateway-apisix:apisix-3.18-smoke)" = "3.18.0"
