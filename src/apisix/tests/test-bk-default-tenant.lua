
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
local plugin = require("apisix.plugins.bk-default-tenant")

describe(
    "bk-default-tenant", function()

        local ctx
        local conf

        before_each(
            function()
                ctx = {
                    var = {
                        uri = "/path/value1/value2?hello=hello",
                    },
                    headers = {
                        ["X-Bk-Tenant-Id"] = nil,
                    },
                    conf_id = "conf_id",
                    conf_type = "conf_type"
                }
            end
        )

        context(
            "header rewrite", function()

                before_each(
                    function()
                        conf = {}
                    end
                )

                it(
                    "header set to default", function()
                        assert.is_equal(ctx.headers["X-Bk-Tenant-Id"], nil)
                        plugin.rewrite(conf, ctx)
                        assert.is_equal(ctx.headers["X-Bk-Tenant-Id"], "default")
                        assert.is_equal(ctx.var.bk_tenant_id, "default")
                    end
                )

                it(
                    "header overwritten to default", function()
                        ctx.headers["X-Bk-Tenant-Id"] = "other"
                        assert.is_equal(ctx.headers["X-Bk-Tenant-Id"], "other")
                        plugin.rewrite(conf, ctx)
                        assert.is_equal(ctx.headers["X-Bk-Tenant-Id"], "default")
                        assert.is_equal(ctx.var.bk_tenant_id, "default")
                    end
                )
            end
        )
    end
)