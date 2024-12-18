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
local bk_cache = require("apisix.plugins.bk-cache.init")
local errorx = require("apisix.plugins.bk-core.errorx")
local plugin = require("apisix.plugins.bk-tenant-verify")


describe(
    "bk-tenant-verify", function()
        local ctx

        before_each(
            function()
                ctx = {
                    var = {
                        bk_app = {
                            get_app_code = function() return "my-app" end,
                            is_verified = function() return true end,
                        },
                        bk_user = {
                            get_username = function() return "admin" end,
                            is_verified = function() return true end,
                        },
                    },
                }

                stub(core.request, "header", function(_, header)
                    if header == "X-Bk-Tenant-Id" then
                        return "tenant-id-from-header"
                    end
                end)

                stub(bk_cache, "get_app_tenant_info", function(app_code)
                    return { tenant_mode = "single", tenant_id = "tenant-id-from-app" }
                end)

                stub(bk_cache, "get_user_tenant_info", function(username)
                    return { tenant_id = "tenant-id-from-user" }
                end)

                stub(errorx, "exit_with_apigw_err", function() end)
            end
        )

        after_each(
            function()
                core.request.header:revert()
                bk_cache.get_app_tenant_info:revert()
                bk_cache.get_user_tenant_info:revert()
                errorx.exit_with_apigw_err:revert()
            end
        )

        it(
            "should get tenant_id from header", function()
                plugin.rewrite({}, ctx)
                assert.is_equal(ctx.var.bk_tenant_id, "tenant-id-from-header")
            end
        )

        it(
            "should get tenant_id from app", function()
                ctx.var.bk_app.get_app_code = function() return "my-app" end
                ctx.var.bk_app.is_verified = function() return true end

                plugin.rewrite({}, ctx)
                assert.is_equal(ctx.var.bk_app.tenant_id, "tenant-id-from-app")
                assert.is_equal(ctx.var.bk_app.tenant_mode, "single")
            end
        )

        it(
            "should get tenant_id from user", function()
                ctx.var.bk_user.get_username = function() return "admin" end
                ctx.var.bk_user.is_verified = function() return true end

                plugin.rewrite({}, ctx)
                assert.is_equal(ctx.var.bk_user.tenant_id, "tenant-id-from-user")
            end
        )

        it(
            "should handle error when getting tenant_id from app", function()
                stub(bk_cache, "get_app_tenant_info", function(app_code)
                    return nil, "error"
                end)

                plugin.rewrite({}, ctx)
                assert.stub(errorx.exit_with_apigw_err).was_called()
            end
        )

        it(
            "should handle error when getting tenant_id from user", function()
                stub(bk_cache, "get_user_tenant_info", function(username)
                    return nil, "error"
                end)

                plugin.rewrite({}, ctx)
                assert.stub(errorx.exit_with_apigw_err).was_called()
            end
        )
    end
)
