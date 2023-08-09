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
local response = require("apisix.core.response")
local ratelimit = require("apisix.plugins.bk-rate-limit.init")
local rate_limit_redis = require("apisix.plugins.bk-rate-limit.rate-limit-redis")

describe(
    "bk-rate-limit", function()
        context(
            "schema", function()
                it(
                    "should check resource limiter schema", function()
                        local conf = {
                            rates = {
                                ["__default"] = {
                                    {
                                        period = 1,
                                        tokens = 1,
                                    },
                                },
                                ["bk-app"] = {
                                    {
                                        period = 1,
                                        tokens = 1,
                                    },
                                },
                            },
                        }
                        assert.is_true(core.schema.check(ratelimit.app_limiter_schema, conf))
                    end
                )
            end
        )

        context(
            "rate_limit", function()
                local conf
                local ctx

                before_each(
                    function()
                        conf = {
                            ["__default"] = {
                                {
                                    period = 1,
                                    tokens = 1,
                                },
                            },
                            allow_degradation = true,
                            show_limit_quota_header = true,
                        }
                        ctx = {
                            conf_type = "route",
                            conf_id = "1",
                        }
                    end
                )

                context(
                    "create rate-limit-redis failed", function()
                        before_each(
                            function()
                                stub(
                                    rate_limit_redis, "new", function()
                                        return nil, "failed to create"
                                    end
                                )
                            end
                        )
                        after_each(
                            function()
                                rate_limit_redis.new:revert()
                            end
                        )

                        it(
                            "allow_degradation=true", function()
                                conf.allow_degradation = true

                                local code = ratelimit.rate_limit(
                                    conf, ctx, "rate_limit_with_create_limit_obj_error", "key-1", 1, 60
                                )
                                assert.is_nil(code)
                            end
                        )

                        it(
                            "allow_degradation=false", function()
                                conf.allow_degradation = false

                                local code = ratelimit.rate_limit(
                                    conf, ctx, "rate_limit_with_create_limit_obj_error", "key-2", 1, 60
                                )
                                assert.is_equal(code, 500)
                            end
                        )
                    end
                )

                context(
                    "rate_limit", function()
                        local mock_delay, mock_remaining, mock_reset

                        before_each(
                            function()
                                mock_delay = nil
                                mock_remaining = nil
                                mock_reset = nil

                                stub(
                                    rate_limit_redis, "new", function()
                                        return {
                                            incoming = function()
                                                return mock_delay, mock_remaining, mock_reset
                                            end,
                                        }
                                    end
                                )
                                stub(response, "set_header")
                            end
                        )

                        after_each(
                            function()
                                rate_limit_redis.new:revert()
                                response.set_header:revert()
                            end
                        )

                        it(
                            "error", function()
                                mock_delay = nil
                                mock_remaining = "error"
                                mock_reset = nil
                                local code

                                conf.allow_degradation = true

                                code = ratelimit.rate_limit(conf, ctx, "rate_limit", "key", 1, 60)
                                assert.is_nil(code)

                                conf.allow_degradation = false

                                code = ratelimit.rate_limit(conf, ctx, "rate_limit", "key", 1, 60)
                                assert.is_equal(code, 500)
                            end
                        )

                        it(
                            "rejected", function()
                                mock_delay = nil
                                mock_remaining = "rejected"
                                mock_reset = 20
                                local code

                                conf.allow_degradation = true
                                conf.show_limit_quota_header = true

                                code = ratelimit.rate_limit(conf, ctx, "rate_limit", "key", 1, 60)
                                assert.is_equal(code, 429)
                                assert.stub(response.set_header).was_called_with(
                                    "X-Bkapi-RateLimit-Limit", 1, "X-Bkapi-RateLimit-Remaining", 0,
                                    "X-Bkapi-RateLimit-Reset", 20, "X-Bkapi-RateLimit-Plugin", "rate_limit"
                                )

                                response.set_header:clear()
                                conf.allow_degradation = false
                                conf.show_limit_quota_header = false

                                code = ratelimit.rate_limit(conf, ctx, "rate_limit", "key", 1, 60)
                                assert.is_equal(code, 429)
                                assert.stub(response.set_header).was_not_called()
                            end
                        )

                        it(
                            "ok", function()
                                mock_delay = 0
                                mock_remaining = 10
                                mock_reset = 30
                                local code

                                conf.allow_degradation = true
                                conf.show_limit_quota_header = true

                                code = ratelimit.rate_limit(conf, ctx, "rate_limit", "key", 30, 60)
                                assert.is_nil(code)
                                assert.stub(response.set_header).was_called_with(
                                    "X-Bkapi-RateLimit-Limit", 30, "X-Bkapi-RateLimit-Remaining", 10,
                                    "X-Bkapi-RateLimit-Reset", 30, "X-Bkapi-RateLimit-Plugin", "rate_limit"
                                )

                                response.set_header:clear()
                                conf.allow_degradation = false
                                conf.show_limit_quota_header = false

                                code = ratelimit.rate_limit(conf, ctx, "rate_limit", "key", 30, 60)
                                assert.is_nil(code)
                                assert.stub(response.set_header).was_not_called()
                            end
                        )
                    end
                )
            end
        )
    end
)
