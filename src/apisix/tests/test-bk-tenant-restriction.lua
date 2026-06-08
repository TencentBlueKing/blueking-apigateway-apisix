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
local plugin = require("apisix.plugins.bk-tenant-restriction")

describe("bk-tenant-restriction", function()
    local ctx, conf

    before_each(function()
        ctx = {
            var = {
                bk_tenant_id = "tenant_default",
            },
        }

        conf = {
            message = "The bk-tenant is not allowed",
            whitelist = { "allowed_tenant" },
        }
    end)

    context("check schema", function()
        it("should reject invalid configuration", function()
            assert.is_false(plugin.check_schema({}))
        end)

        it("should accept valid whitelist configuration", function()
            assert.is_true(plugin.check_schema({
                whitelist = { "tenant_a" },
            }))
        end)

        it("should accept valid blacklist configuration", function()
            assert.is_true(plugin.check_schema({
                blacklist = { "tenant_b" },
            }))
        end)
    end)

    context("access", function()
        it("bk_tenant_id is nil, do nothing", function()
            ctx.var.bk_tenant_id = nil
            local code = plugin.access(conf, ctx)
            assert.is_nil(code)
        end)

        it("bk_tenant_id is empty string, do nothing", function()
            ctx.var.bk_tenant_id = ""
            local code = plugin.access(conf, ctx)
            assert.is_nil(code)
        end)

        it("should deny tenant not in whitelist", function()
            local ok = plugin.check_schema(conf)
            assert.is_true(ok)
            assert.is_not_nil(conf.whitelist_map)

            ctx.var.bk_tenant_id = "unknown_tenant"
            local code = plugin.access(conf, ctx)
            assert.is_equal(code, 403)
            assert.is_not_nil(ctx.var.bk_apigw_error)
            assert.is_true(
                core.string.find(
                    ctx.var.bk_apigw_error.error.message,
                    'Request rejected by bk-tenant restriction'
                ) ~= nil
            )
            assert.is_true(
                core.string.find(
                    ctx.var.bk_apigw_error.error.message,
                    'message="The bk-tenant is not allowed"'
                ) ~= nil
            )
            assert.is_true(
                core.string.find(
                    ctx.var.bk_apigw_error.error.message,
                    'bk_tenant_id="unknown_tenant"'
                ) ~= nil
            )
        end)

        it("should allow tenant in whitelist", function()
            local ok = plugin.check_schema(conf)
            assert.is_true(ok)
            assert.is_not_nil(conf.whitelist_map)

            ctx.var.bk_tenant_id = "allowed_tenant"
            local code = plugin.access(conf, ctx)
            assert.is_nil(code)
            assert.is_nil(ctx.var.bk_apigw_error)
        end)

        it("should deny tenant in blacklist", function()
            conf.whitelist = nil
            conf.blacklist = { "denied_tenant" }
            local ok = plugin.check_schema(conf)
            assert.is_true(ok)
            assert.is_not_nil(conf.blacklist_map)

            ctx.var.bk_tenant_id = "denied_tenant"
            local code = plugin.access(conf, ctx)
            assert.is_equal(code, 403)
            assert.is_not_nil(ctx.var.bk_apigw_error)
            assert.is_true(
                core.string.find(
                    ctx.var.bk_apigw_error.error.message,
                    'Request rejected by bk-tenant restriction'
                ) ~= nil
            )
            assert.is_true(
                core.string.find(
                    ctx.var.bk_apigw_error.error.message,
                    'message="The bk-tenant is not allowed"'
                ) ~= nil
            )
            assert.is_true(
                core.string.find(
                    ctx.var.bk_apigw_error.error.message,
                    'bk_tenant_id="denied_tenant"'
                ) ~= nil
            )
        end)

        it("should allow tenant not in blacklist", function()
            conf.whitelist = nil
            conf.blacklist = { "denied_tenant" }
            local ok = plugin.check_schema(conf)
            assert.is_true(ok)
            assert.is_not_nil(conf.blacklist_map)

            ctx.var.bk_tenant_id = "allowed_tenant"
            local code = plugin.access(conf, ctx)
            assert.is_nil(code)
            assert.is_nil(ctx.var.bk_apigw_error)
        end)
    end)
end)
