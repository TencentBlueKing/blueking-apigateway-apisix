ROOT_DIR ?= $(CURDIR)

RUN_WITH_IT ?= -it

.PHONY: apisix-test-busted
apisix-test-busted:
	docker build -t apisix-test-busted -f ci/Dockerfile.apisix-test-busted .

.PHONY: apisix-test-nginx
apisix-test-nginx:
	docker build -t apisix-test-nginx -f ci/Dockerfile.apisix-test-nginx .

.PHONY: test-busted
test-busted:
	@docker run --rm ${RUN_WITH_IT} \
	-v ${ROOT_DIR}/tests/conf/config.yaml:/usr/local/apisix/conf/config.yaml \
	-v ${ROOT_DIR}/tests:/bkgateway/tests/ \
	-v ${ROOT_DIR}/logs/:/bkgateway/logs/ \
	-v ${ROOT_DIR}/tests/conf/nginx.conf:/bkgateway/conf/nginx.conf \
	-v ${ROOT_DIR}/plugins:/bkgateway/apisix/plugins \
	apisix-test-busted "/run-test-busted.sh"

# make test-nginx
# make test-nginx CASE_FILE=bk-traffic-label.t
.PHONY: test-nginx
test-nginx:
	@docker run --rm ${RUN_WITH_IT} \
	-v ${ROOT_DIR}/t:/bkgateway/t/ \
	-v ${ROOT_DIR}/plugins:/bkgateway/apisix/plugins \
	apisix-test-nginx "/run-test-nginx.sh" $(if $(CASE_FILE),$(CASE_FILE))

.PHONY: apisix-test-images
apisix-test-images: apisix-test-busted apisix-test-nginx

.PHONY: test
test: test-busted test-nginx

.PHONY: lint
lint:
	@docker run --rm ${RUN_WITH_IT} \
	-v ${ROOT_DIR}/.luacheckrc:/bkgateway/.luacheckrc \
	-v ${ROOT_DIR}/plugins:/bkgateway/apisix/plugins \
	-v ${ROOT_DIR}/tests:/bkgateway/tests/ \
	-w /bkgateway/apisix \
	apisix-test-busted \
	luacheck --config /bkgateway/.luacheckrc ./plugins

.PHONY: edition
edition:
	editionctl info

.PHONY: edition-te
edition-te:
	editionctl activate TE

.PHONY: edition-ee
edition-ee:
	editionctl activate EE

.PHONY: edition-reset
edition-reset:
	editionctl reset
