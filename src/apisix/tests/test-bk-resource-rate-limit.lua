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

local plugin = require("apisix.plugins.bk-resource-rate-limit")
local ratelimit = require("apisix.plugins.bk-rate-limit.init")

describe(
    "bk-resource-rate-limit", function()
        local ctx
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
            end
        )

        after_each(
            function()
                ratelimit.rate_limit:revert()
            end
        )

        it(
            "should wrap rate limit", function()
                assert.is_equal(plugin.priority, 17653)
                assert.is_equal(plugin.name, "bk-resource-rate-limit")
                assert.is_same(plugin.schema, ratelimit.app_limiter_schema)
            end
        )

        describe(
            "access()", function()
                it(
                    "should return nil when configuration is empty", function()
                        local conf = {}
                        local code, err = plugin.access(conf, ctx)
                        assert.is_nil(code)
                        assert.is_nil(err)
                    end
                )

                it(
                    "should return nil when bk_app_code is missing", function()
                        local conf = {
                            rates = {
                                __default = {
                                    period = 1,
                                    tokens = 10,
                                },
                            },
                        }
                        local code, err = plugin.access(conf, ctx)
                        assert.is_nil(code)
                        assert.is_nil(err)
                    end
                )

                it(
                    "should return nil when there is no conf.rates", function()
                        local conf = {
                            a = 1,
                        }
                        ctx.var.bk_app_code = "test"
                        local code, err = plugin.access(conf, ctx)
                        assert.is_nil(code)
                        assert.is_nil(err)
                    end
                )

                it(
                    "should return nil when there is no conf.rates[__default]", function()
                        local conf = {
                            rates = {
                                a = 1,
                            },
                        }
                        ctx.var.bk_app_code = "test"
                        local code, err = plugin.access(conf, ctx)
                        assert.is_nil(code)
                        assert.is_nil(err)
                    end
                )

                it(
                    "should return nil when there is conf.rates[__default] is empty", function()
                        local conf = {
                            rates = {
                                __default = {},
                            },
                        }
                        ctx.var.bk_app_code = "test"
                        local code, err = plugin.access(conf, ctx)
                        assert.is_nil(code)
                        assert.is_nil(err)
                    end
                )

                it(
                    "should return nil when there is conf.rates[__default], not exceed", function()
                        local conf = {
                            rates = {
                                __default = {
                                    {
                                        period = 1,
                                        tokens = 10,
                                    },
                                },
                            },
                        }
                        ctx.var.bk_app_code = "test"
                        local code, err = plugin.access(conf, ctx)
                        assert.is_nil(code)
                        assert.is_nil(err)
                    end
                )

                it(
                    "should 429, conf.rates[__default] 1 rate exceed", function()
                        stub(
                            ratelimit, "rate_limit", function()
                                return 500
                            end
                        )
                        local conf = {
                            rates = {
                                __default = {
                                    {
                                        period = 1,
                                        tokens = 10,
                                    },
                                },
                            },
                        }
                        ctx.var.bk_app_code = "test"
                        local code = plugin.access(conf, ctx)
                        assert.is_not_nil(code)
                        assert.stub(ratelimit.rate_limit).was_called(1)

                        assert.is_equal(429, code)
                        assert.is_equal(ctx.var.bk_apigw_error.error.code, 1642903)
                        assert.is_equal(ctx.var.bk_apigw_error.error.code_name, "RATE_LIMIT_RESTRICTION")
                        assert.is_equal(
                            ctx.var.bk_apigw_error.error.message, "API rate limit exceeded by resource strategy"
                        )

                    end
                )

                it(
                    "should 429, conf.rates[__default] 3 rate exceed", function()
                        stub(
                            ratelimit, "rate_limit", function()
                                return 500
                            end
                        )
                        local conf = {
                            rates = {
                                __default = {
                                    {
                                        period = 1,
                                        tokens = 10,
                                    },
                                    {
                                        period = 1,
                                        tokens = 20,
                                    },
                                    {
                                        period = 1,
                                        tokens = 30,
                                    },
                                },
                            },
                        }
                        ctx.var.bk_app_code = "test"
                        local code = plugin.access(conf, ctx)
                        assert.is_not_nil(code)
                        assert.stub(ratelimit.rate_limit).was_called(1)

                        assert.is_equal(429, code)
                        assert.is_equal(ctx.var.bk_apigw_error.error.code, 1642903)
                        assert.is_equal(ctx.var.bk_apigw_error.error.code_name, "RATE_LIMIT_RESTRICTION")
                        assert.is_equal(
                            ctx.var.bk_apigw_error.error.message, "API rate limit exceeded by resource strategy"
                        )
                    end
                )

            end
        )

    end
)
