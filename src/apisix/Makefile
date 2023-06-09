ROOT_DIR ?= $(CURDIR)

RUN_WITH_IT ?= -it

.PHONY: apisix-test-image
apisix-test-image:
	docker build -t apisix-test-image -f tests/Dockerfile.apisix-unittest .

.PHONY: test
test:
	$(eval cmd ?= "/run-test.sh")
	$(eval flag ?= )
	@docker run --rm ${RUN_WITH_IT} \
	-v ${ROOT_DIR}/tests/conf/config.yaml:/usr/local/apisix/conf/config.yaml \
	-v ${ROOT_DIR}/tests:/bkgateway/tests/ \
	-v ${ROOT_DIR}/logs/:/bkgateway/logs/ \
	-v ${ROOT_DIR}/tests/conf/nginx.conf:/bkgateway/conf/nginx.conf \
	-v ${ROOT_DIR}/plugins:/bkgateway/apisix/plugins \
	apisix-test-image "${cmd}" ${flag}

.PHONY: lint
lint:
	@docker run --rm ${RUN_WITH_IT} \
	-v ${ROOT_DIR}/.luacheckrc:/bkgateway/.luacheckrc \
	-v ${ROOT_DIR}/plugins:/bkgateway/apisix/plugins \
	-v ${ROOT_DIR}/tests:/bkgateway/tests/ \
	-w /bkgateway/apisix \
	apisix-test-image \
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
