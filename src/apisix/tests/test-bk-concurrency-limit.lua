--
-- TencentBlueKing is pleased to support the open source community by making
-- 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
-- Copyright (C) 2025 Tencent. All rights reserved.
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
local concurrency_limit = require("apisix.plugins.bk-concurrency-limit")
local limiter = require("apisix.plugins.limit-conn.init")

describe(
    "bk-concurrency-limit", function()
        local metadata, ctx

        before_each(
            function()

                ctx = CTX(
                    {
                        bk_gateway_name = RANDSTR(),
                        bk_stage_name = RANDSTR(),
                        bk_app_code = RANDSTR(),
                    }
                )
                metadata = {
                    value = {
                        conn = 1,
                        burst = 1,
                        default_conn_delay = 0.01,
                        key_type = "var",
                        key = "bk_concurrency_limit_key",
                        policy = "local",
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

        context("bk_concurrency_limit_key", function()
                it(
                    "should return correct key", function()
                        local key = ctx.var.bk_concurrency_limit_key

                        assert.is_equal(key, table.concat({
                            ctx.var.bk_gateway_name,
                            ctx.var.bk_stage_name,
                            ctx.var.bk_app_code
                        }, ":"))
                    end
                )
            end
        )

        context(
            "check_schema", function()
                it(
                    "should always return true", function()
                        assert.is_true(concurrency_limit.check_schema({}))
                    end
                )

                it(
                    "should support metadata schema", function()
                        local result, _ = concurrency_limit.check_schema(metadata.value, core.schema.TYPE_METADATA)

                        assert.is_true(result)
                    end
                )
            end
        )

        context(
            "access", function()
                local increase_result

                before_each(
                    function()
                        increase_result = nil
                        stub(
                            limiter, "increase", function()
                                return increase_result
                            end
                        )
                    end
                )

                after_each(
                    function()
                        limiter.increase:revert()
                    end
                )

                it(
                    "should do nothing when metadata is not set", function()
                        metadata = nil

                        local result = concurrency_limit.access({}, {})

                        assert.is_nil(result)
                    end
                )

                it(
                    "should increase limiter", function()
                        local code = concurrency_limit.access({}, ctx)

                        assert.is_nil(code)
                        assert.stub(limiter.increase).was_called_with(metadata.value, ctx)
                    end
                )

                it(
                    "should return error when request concurrency limit exceeded", function()
                        increase_result = 503

                        local code = concurrency_limit.access({}, ctx)

                        assert.is_equal(429, code)
                        assert.is_equal(ctx.var.bk_apigw_error.error.code_name, "CONCURRENCY_LIMIT_RESTRICTION")
                    end
                )
            end
        )

        context(
            "log", function()
                before_each(
                    function()
                        stub(limiter, "decrease")
                    end
                )

                after_each(
                    function()
                        limiter.decrease:revert()
                    end
                )

                it(
                    "should do nothing when metadata is not set", function()
                        metadata = nil

                        local result = concurrency_limit.log({}, {})
                        assert.is_nil(result)
                    end
                )

                it(
                    "should decrease limiter", function()
                        local code = concurrency_limit.log({}, ctx)

                        assert.is_nil(code)
                        assert.stub(limiter.decrease).was_called_with(metadata.value, ctx)
                    end
                )
            end
        )

        context(
            "usage", function()

                before_each(
                    function()
                    end
                )

                it(
                    "should accept the request", function()
                        local result = concurrency_limit.access({}, ctx)
                        assert.is_nil(result)
                    end
                )

                it(
                    "should delay the request", function()
                        limiter.increase(metadata.value, ctx)
                        local result = concurrency_limit.access({}, ctx)

                        assert.is_nil(result)
                    end
                )

                it(
                    "should reject the request", function()
                        limiter.increase(metadata.value, ctx)
                        limiter.increase(metadata.value, ctx)
                        local result = concurrency_limit.access({}, ctx)

                        assert.is_equal(429, result)
                    end
                )
            end
        )
    end
)
