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
local plugin = require("apisix.plugins.bk-user-restriction")
local context_resource_bkauth = require("apisix.plugins.bk-define.context-resource-bkauth")
local bk_user_define = require("apisix.plugins.bk-define.user")

describe("bk-user-restriction", function()
    local ctx, conf
    local bk_resource_auth = context_resource_bkauth.new({
        verified_app_required = true,
        verified_user_required = true,
        resource_perm_required = true,
        skip_user_verification = false,
    })

    before_each(function()
        ctx = {
            var = {
                bk_resource_auth = bk_resource_auth,
            },
        }
        ctx.var.bk_user = bk_user_define.new_user({
            username = "test_user",
            verified = true,
        })

        conf = {
            message = "The bk-user is not allowed",
            whitelist = { "allowed_user" },
        }
    end)

    context("check schema", function()
        it("should reject invalid configuration", function()
            assert.is_false(plugin.check_schema({}))
        end)

        it("should accept valid configuration", function()
            assert.is_true(plugin.check_schema({
                whitelist = { "allowed_user" },
            }))
        end)
    end)

    context("access", function()
        it("user is nil, do nothing", function()
            ctx.var.bk_user = nil
            local code = plugin.access(conf, ctx)
            assert.is_nil(code)
        end)

        it("user is not verified, do nothing", function()
            ctx.var.bk_user.verified = false
            local code = plugin.access(conf, ctx)
            assert.is_nil(code)
        end)

        it("bk_resource_auth verified_user_required false, do nothing", function()
            ctx.var.bk_resource_auth = context_resource_bkauth.new({
                verified_app_required = true,
                verified_user_required = false,
                resource_perm_required = true,
                skip_user_verification = false,
            })
            local code = plugin.access(conf, ctx)
            assert.is_nil(code)
        end)


        it("should deny user not in whitelist", function()
            local ok = plugin.check_schema(conf)
            assert.is_true(ok)
            assert.is_not_nil(conf.whitelist_map)

            ctx.var.bk_user.username = "unknown_user"
            local code = plugin.access(conf, ctx)
            assert.is_equal(code, 403)
            assert.is_not_nil(ctx.var.bk_apigw_error)
            assert.is_true(core.string.find(ctx.var.bk_apigw_error.error.message, 'Request rejected by bk-user restriction') ~= nil)
            assert.is_true(core.string.find(ctx.var.bk_apigw_error.error.message, 'message="The bk-user is not allowed"') ~= nil)
            assert.is_true(core.string.find(ctx.var.bk_apigw_error.error.message, 'bk_username="unknown_user"') ~= nil)
        end)

        it("should allow user in whitelist", function()
            local ok = plugin.check_schema(conf)
            assert.is_true(ok)
            assert.is_not_nil(conf.whitelist_map)

            ctx.var.bk_user.username = "allowed_user"
            local code = plugin.access(conf, ctx)
            assert.is_nil(code)
            assert.is_nil(ctx.var.bk_apigw_error)
        end)

        it("should deny user in blacklist", function()
            conf.whitelist = nil
            conf.blacklist = { "denied_user" }
            local ok = plugin.check_schema(conf)
            assert.is_true(ok)
            assert.is_not_nil(conf.blacklist_map)

            ctx.var.bk_user.username = "denied_user"
            local code = plugin.access(conf, ctx)
            assert.is_equal(code, 403)
            assert.is_not_nil(ctx.var.bk_apigw_error)
            assert.is_true(core.string.find(ctx.var.bk_apigw_error.error.message, 'Request rejected by bk-user restriction') ~= nil)
            assert.is_true(core.string.find(ctx.var.bk_apigw_error.error.message, 'message="The bk-user is not allowed"') ~= nil)
            assert.is_true(core.string.find(ctx.var.bk_apigw_error.error.message, 'bk_username="denied_user"') ~= nil)
        end)

        it("should allow user not in blacklist", function()
            conf.whitelist = nil
            conf.blacklist = { "denied_user" }
            local ok = plugin.check_schema(conf)
            assert.is_true(ok)
            assert.is_not_nil(conf.blacklist_map)

            ctx.var.bk_user.username = "allowed_user"
            local code = plugin.access(conf, ctx)
            assert.is_nil(code)
            assert.is_nil(ctx.var.bk_apigw_error)
        end)
    end)
end)
