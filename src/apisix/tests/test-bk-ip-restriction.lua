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

local plugin = require("apisix.plugins.bk-ip-restriction")
local core = require("apisix.core")

describe(
    "bk-ip-restriction", function()
        local ctx, conf

        before_each(
            function()
                ctx = CTX(
                    {
                        remote_addr = "127.0.0.1",
                    }
                )

                conf = {
                    message = "IP not allowed",
                    whitelist = {
                        "127.0.0.2",
                    },
                    blacklist = {
                        "127.0.0.3",
                    },
                }
            end
        )

        context(
            "check schema", function()
                it(
                    "should reject invalid configuration", function()
                        assert.is_false(plugin.check_schema({}))
                    end
                )

                it(
                    "should accept valid configuration", function()
                        assert.is_true(
                            plugin.check_schema(
                                {
                                    whitelist = {
                                        "127.0.0.1",
                                    },
                                }
                            )
                        )
                    end
                )
            end
        )

        context(
            "access", function()
                it(
                    "should return standard error", function()
                        local code = plugin.access(conf, ctx)

                        assert.is_not_nil(ctx.var.bk_apigw_error)
                        assert.is_not_equal(
                            0, core.string.find(ctx.var.bk_apigw_error.error.message, ctx.var.remote_addr)
                        )
                        assert.is_equal(code, 403)
                    end
                )

                it(
                    "should work fine", function()
                        for _, case in ipairs(
                            {
                                {
                                    ctx.var.remote_addr,
                                    403,
                                },
                                {
                                    conf.blacklist[1],
                                    403,
                                },
                                {
                                    conf.whitelist[1],
                                    nil,
                                },
                            }
                        ) do

                            ctx.var.remote_addr = case[1]
                            local code = plugin.access(conf, ctx)

                            assert.is_equal(code, case[2])
                        end
                    end
                )
            end
        )
    end
)
