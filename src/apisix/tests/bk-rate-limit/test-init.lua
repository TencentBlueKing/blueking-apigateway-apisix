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
local ratelimit = require("apisix.plugins.bk-rate-limit.init")

describe(
    "bk-rate-limit.init", function()
        ---@type apisix.Context
        local ctx

        before_each(
            function()
                ctx = {
                    var = {
                        bk_gateway_name = "bk-gateway",
                        bk_stage_name = "bk-stage",
                        bk_resource_name = "bk-resource",
                        bk_app_code = "app",
                    },
                }
            end
        )

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

                it(
                    "should check stage limiter schema", function()
                        local conf = {
                            enabled = true,
                            rate = {
                                period = 1,
                                tokens = 1,
                            },
                        }
                        assert.is_true(core.schema.check(ratelimit.app_limiter_schema, conf))
                    end
                )
            end
        )
    end
)
