--
-- TencentBlueKing is pleased to support the open source community by making
-- 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
-- Copyright (C) 2017 THL A29 Limited, a Tencent company. All rights reserved.
-- Licensed under the MIT License (the "License"); you may not use this file except
-- in compliance with the License. You may obtain a copy of the License at
--
--     http://opensource.org/licenses/MIT
--
-- Unless required by applicable law or agreed to in writing, software distributed under
-- the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
-- either express or implied. See the License for the specific language governing permissions and
-- limitations under the License.
--
-- We undertake not to change the open source license (MIT license) applicable
-- to the current version of the project delivered to anyone in the future.
--

local core = require("apisix.core")
local plugin = require("apisix.plugin")
local bk_opentelemetry = require("apisix.plugins.bk-opentelemetry")

local attr = require("opentelemetry.attribute")
local ocontext = require("opentelemetry.context").new()
local span_kind = require("opentelemetry.trace.span_kind")
local tp_new = require("opentelemetry.trace.tracer_provider").new
local resource_new = require("opentelemetry.resource").new
local always_on_sampler = require("opentelemetry.trace.sampling.always_on_sampler").new()
local exporter_client_new = require("opentelemetry.trace.exporter.http_client").new
local otlp_exporter_new = require("opentelemetry.trace.exporter.otlp").new
local batch_span_processor_new = require("opentelemetry.trace.batch_span_processor").new
local trace_context_propagator =
                require("opentelemetry.trace.propagation.text_map.trace_context_propagator").new()

local lrucache = core.lrucache.new({
    type = 'plugin', count = 128, ttl = 24 * 60 * 60,
})

local function new_trace_object()
    -- create exporter
    local exporter = otlp_exporter_new(exporter_client_new("127.0.0.1:4318", 1, {}))
    -- create span processor
    local batch_span_processor = batch_span_processor_new(exporter, {})
    local tp = tp_new(batch_span_processor, {
        sampler = always_on_sampler,
        resource = resource_new(attr.string("service.name", "openresty"), attr.int("attr_int", 100)),
    })

    return tp:tracer("demo")
end

describe(
    "bk-opentelemetry", function()
        context(
            "check_schema", function()
                local metadata, ctx
                before_each(
                    function()
                        ctx = CTX(
                            {
                                instance_id = RANDSTR(),
                                bk_app_code = "bk_test",
                                bk_gateway_name = RANDSTR(),
                                bk_stage_name = RANDSTR(),
                                bk_resource_name = RANDSTR(),
                                bk_service_name = RANDSTR(),
                                bk_request_id = RANDSTR(),
                                x_request_id = RANDSTR(),
                                request_uri = "/",
                            }
                        )
                        metadata = {
                            value =  {
                                sampler =  {
                                    name = "parent_base",
                                    options = {
                                        root = {
                                            name = "trace_id_ratio",
                                            options = {
                                                fraction = 1,
                                            },
                                        }
                                    },
                                },
                            },
                        }

                        stub(
                            plugin, "plugin_metadata", function()
                                return metadata
                            end
                        )
                    end
                )

                after_each(
                    function()
                        plugin.plugin_metadata:revert()
                    end
                )

                it(
                    "should always return true", function()
                        assert.is_true(bk_opentelemetry.check_schema({}))
                    end
                )

                it(
                    "should support metadata schema", function()
                        local result, _ = bk_opentelemetry.check_schema(metadata.value, core.schema.TYPE_METADATA)

                        assert.is_true(result)
                    end
                )
            end
        )

        context(
            "inject_span", function()
                local metadata, ctx
                local octx
                local otel_context_token
                before_each(
                    function()
                        ctx = CTX(
                            {
                                instance_id = RANDSTR(),
                                bk_app_code = "bk_test",
                                bk_gateway_name = RANDSTR(),
                                bk_stage_name = RANDSTR(),
                                bk_resource_name = RANDSTR(),
                                bk_service_name = RANDSTR(),
                                bk_request_id = RANDSTR(),
                                x_request_id = RANDSTR(),
                                request_uri = "/hello/?a=1&b=2",
                                uri = "/hello/"
                            }
                        )
                        metadata = {
                            value =  {
                                sampler =  {
                                    name = "parent_base",
                                    options = {
                                        root = {
                                            name = "trace_id_ratio",
                                            options = {
                                                fraction = 1,
                                            },
                                        }
                                    },
                                },
                            },
                        }

                        stub(
                            plugin, "plugin_metadata", function()
                                return metadata
                            end
                        )

                        local tracer, _ = core.lrucache.plugin_ctx(lrucache, ctx, nil, new_trace_object, metadata.value)

                        local upstream_context = trace_context_propagator:extract(ocontext, ngx.req)
                        local attributes = {
                            attr.string("service", "test"),
                        }

                        octx = tracer:start(upstream_context, ctx.var.request_uri, {
                            kind = span_kind.client,
                            attributes = attributes,
                        })
                        otel_context_token = octx:attach()
                    end
                )

                after_each(
                    function()
                        plugin.plugin_metadata:revert()

                        -- the order: before_each -> {test, start} -> {test, end} -> after_each
                        --            the ngx.ctx is cleared in the subscribe({test, end}), so we can't detach here
                        -- if otel_context_token then
                        --     octx:detach(otel_context_token)
                        -- end
                    end
                )

                it(
                    "should inject span tags", function()
                        local current_ctx = ocontext:current()
                        assert.is_not_nil(current_ctx)

                        local span = current_ctx:span()
                        assert.is_not_nil(span)

                        -- the old span name is full uri
                        local old_data = span:plain()
                        assert.is_equal(old_data.name, "/hello/?a=1&b=2")

                        -- inject
                        bk_opentelemetry.inject_span(ctx)

                        local data = span:plain()

                        -- the new span name is uri
                        local name = data.name
                        assert.is_equal(name, "/hello/")

                        local attributes = data.attributes

                        assert.is_equal(attributes[3]["key"], "bk_app_code")
                        assert.is_equal(attributes[3]["value"]["string_value"], "bk_test")

                    end
                )
            end
        )

    end
)
