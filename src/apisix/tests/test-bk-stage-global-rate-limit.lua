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
local plugin = require("apisix.plugins.bk-stage-global-rate-limit")
local ratelimit = require("apisix.plugins.bk-rate-limit.init")

describe(
    "bk-stage-global-rate-limit", function()
        local ctx
        local conf

        before_each(
            function()
                stub(
                    ratelimit, "rate_limit", function()
                        return nil
                    end
                )

                ctx = {
                    var = {
                        bk_gateway_name = "bk-gateway",
                        bk_stage_name = "bk-stage",
                        bk_resource_name = "bk-resource",
                    },
                }
                conf = {
                    enabled = true,
                    rate = {
                        period = 60,
                        tokens = 100,
                    },
                }
            end
        )

        after_each(
            function()
                ratelimit.rate_limit:revert()
            end
        )

        it(
            "should check schema", function()
                assert.is_equal(plugin.priority, 17651)
                assert.is_equal(plugin.name, "bk-stage-global-rate-limit")

                assert.is_true(plugin.check_schema(conf))
            end
        )

        it(
            "should do nothing when config is empty", function()
                local result = plugin.access({}, ctx)
                assert.is_nil(result)
            end
        )

        it(
            "should do ratelimit, not reach the limit", function()
                local result = plugin.access(conf, ctx)
                assert.is_nil(result)
                assert.stub(ratelimit.rate_limit).was_called(1)
            end
        )

        it(
            "should do ratelimit, reach the limit", function()
                stub(
                    ratelimit, "rate_limit", function()
                        return 500
                    end
                )
                local code = plugin.access(conf, ctx)
                assert.is_not_nil(code)
                assert.stub(ratelimit.rate_limit).was_called(1)

                assert.is_equal(429, code)
                assert.is_equal(ctx.var.bk_apigw_error.error.code, 1642901)
                assert.is_equal(ctx.var.bk_apigw_error.error.code_name, "RATE_LIMIT_RESTRICTION")
                assert.is_equal(ctx.var.bk_apigw_error.error.message, "API rate limit exceeded by stage global limit")

            end
        )
    end
)
