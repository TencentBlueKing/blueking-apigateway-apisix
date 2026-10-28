--
-- TencentBlueKing is pleased to support the open source community by making
-- 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
-- Copyright (C) Tencent. All rights reserved.
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

local plugin = require("apisix.plugins.bk-resource-user-rate-limit")
local ratelimit = require("apisix.plugins.bk-rate-limit.init")
local core = require("apisix.core")
local resource_auth = require("apisix.plugins.bk-define.context-resource-bkauth")


describe("bk-resource-user-rate-limit", function()
    local ctx
    local conf

    before_each(function()
        stub(ratelimit, "rate_limit")
        ctx = {
            var = {
                bk_username = "alice",
                bk_user = {username = "alice", verified = true},
                bk_resource_auth = resource_auth.new({verified_user_required = true}),
                bk_app_code = "app-one",
                bk_gateway_name = "gateway",
                bk_stage_name = "prod",
                bk_resource_name = "resource",
            },
        }
        conf = {rates = {__default = {{period = 60, tokens = 100}}}}
    end)

    after_each(function()
        ratelimit.rate_limit:revert()
    end)

    describe("check_schema()", function()
        it("accepts defaults, overrides, multiple windows and exemptions", function()
            conf.rates.alice = {{period = 1, tokens = 10}, {period = 60, tokens = 300}}
            conf.rates.bob = {}
            assert.is_true(plugin.check_schema(conf))
            assert.is_true(conf.allow_degradation)
            assert.is_true(conf.show_limit_quota_header)
        end)

        it("preserves explicit degradation and quota header flags", function()
            conf.allow_degradation = false
            conf.show_limit_quota_header = false
            assert.is_true(plugin.check_schema(conf))
            assert.is_false(conf.allow_degradation)
            assert.is_false(conf.show_limit_quota_header)
        end)

        it("accepts disabled configurations", function()
            assert.is_true(plugin.check_schema({}))
            assert.is_true(plugin.check_schema({rates = {}}))
            assert.is_true(plugin.check_schema({rates = {__default = {}}}))
        end)

        for _, rate in ipairs({
            {period = 60}, {tokens = 10}, {period = 0, tokens = 10},
            {period = -1, tokens = 10}, {period = 1.5, tokens = 10},
            {period = "60", tokens = 10}, {period = 60, tokens = 0},
            {period = 60, tokens = -1}, {period = 60, tokens = 1.5},
        }) do
            it("rejects invalid rate " .. core.json.encode(rate), function()
                conf.rates.__default = {rate}
                assert.is_false(plugin.check_schema(conf))
                conf.rates.__default = {}
                conf.rates.alice = {rate}
                assert.is_false(plugin.check_schema(conf))
            end)
        end

        it("rejects a rate object where a list is required", function()
            conf.rates.alice = {period = 60, tokens = 100}
            assert.is_false(plugin.check_schema(conf))
        end)
    end)

    describe("access()", function()
        it("skips absent configuration and default rules", function()
            plugin.access({}, ctx)
            plugin.access({rates = {alice = {{period = 1, tokens = 1}}}}, ctx)
            assert.stub(ratelimit.rate_limit).was_not_called()
        end)

        it("skips missing and anonymous usernames even when an app is present", function()
            ctx.var.bk_user.username = nil
            plugin.access(conf, ctx)
            ctx.var.bk_user.username = ""
            plugin.access(conf, ctx)
            assert.stub(ratelimit.rate_limit).was_not_called()
        end)

        it("skips resources without user authentication, even for verified users", function()
            ctx.var.bk_resource_auth = resource_auth.new({verified_user_required = false})
            plugin.access(conf, ctx)
            ctx.var.bk_resource_auth = nil
            plugin.access(conf, ctx)
            assert.stub(ratelimit.rate_limit).was_not_called()
        end)

        it("skips missing users even when a username is present in context", function()
            ctx.var.bk_user = nil
            plugin.access(conf, ctx)
            assert.stub(ratelimit.rate_limit).was_not_called()
        end)

        it("skips unverified users when user authentication is required", function()
            ctx.var.bk_user.verified = false
            plugin.access(conf, ctx)
            ctx.var.bk_user.verified = nil
            plugin.access(conf, ctx)
            assert.stub(ratelimit.rate_limit).was_not_called()
        end)

        it("uses the verified user rather than a different context username", function()
            ctx.var.bk_username = "bob"
            conf.rates.bob = {}
            plugin.access(conf, ctx)
            assert.stub(ratelimit.rate_limit).was_called_with(
                conf, ctx, plugin.name, "alice:gateway:prod:resource", 100, 60
            )
            ctx.var.bk_username = nil
            plugin.access(conf, ctx)
            assert.stub(ratelimit.rate_limit).was_called(2)
        end)

        it("uses the default rate for each user, without requiring an app", function()
            ctx.var.bk_app_code = nil
            assert.is_nil(plugin.access(conf, ctx))
            assert.stub(ratelimit.rate_limit).was_called_with(
                conf, ctx, plugin.name, "alice:gateway:prod:resource", 100, 60
            )
            ctx.var.bk_user.username = "bob"
            plugin.access(conf, ctx)
            assert.stub(ratelimit.rate_limit).was_called_with(
                conf, ctx, plugin.name, "bob:gateway:prod:resource", 100, 60
            )
        end)

        it("replaces default rates with a user override", function()
            conf.rates.alice = {{period = 10, tokens = 20}}
            plugin.access(conf, ctx)
            assert.stub(ratelimit.rate_limit).was_called(1)
            assert.stub(ratelimit.rate_limit).was_called_with(
                conf, ctx, plugin.name, "alice:gateway:prod:resource", 20, 10
            )
        end)

        it("treats an empty user override as exempt", function()
            conf.rates.alice = {}
            plugin.access(conf, ctx)
            assert.stub(ratelimit.rate_limit).was_not_called()
        end)

        it("allows overrides when the default is empty", function()
            conf.rates.__default = {}
            conf.rates.alice = {{period = 60, tokens = 10}}
            plugin.access(conf, ctx)
            assert.stub(ratelimit.rate_limit).was_called(1)
            ctx.var.bk_user.username = "bob"
            plugin.access(conf, ctx)
            assert.stub(ratelimit.rate_limit).was_called(1)
        end)

        it("shares a user's counter across applications", function()
            plugin.access(conf, ctx)
            ctx.var.bk_app_code = "app-two"
            plugin.access(conf, ctx)
            assert.stub(ratelimit.rate_limit).was_called_with(
                conf, ctx, plugin.name, "alice:gateway:prod:resource", 100, 60
            )
            assert.stub(ratelimit.rate_limit).was_called(2)
        end)

        it("isolates gateways, stages and resources", function()
            ctx.var.bk_gateway_name = "other-gateway"
            plugin.access(conf, ctx)
            assert.stub(ratelimit.rate_limit).was_called_with(
                conf, ctx, plugin.name, "alice:other-gateway:prod:resource", 100, 60
            )
            ctx.var.bk_stage_name = "test"
            plugin.access(conf, ctx)
            assert.stub(ratelimit.rate_limit).was_called_with(
                conf, ctx, plugin.name, "alice:other-gateway:test:resource", 100, 60
            )
            ctx.var.bk_resource_name = "other-resource"
            plugin.access(conf, ctx)
            assert.stub(ratelimit.rate_limit).was_called_with(
                conf, ctx, plugin.name, "alice:other-gateway:test:other-resource", 100, 60
            )
        end)

        it("uses separate counters for multiple windows", function()
            conf.rates.__default = {{period = 1, tokens = 10}, {period = 60, tokens = 100}}
            plugin.access(conf, ctx)
            assert.stub(ratelimit.rate_limit).was_called(2)
            assert.stub(ratelimit.rate_limit).was_called_with(
                conf, ctx, plugin.name, "alice:gateway:prod:resource:1", 10, 1
            )
            assert.stub(ratelimit.rate_limit).was_called_with(
                conf, ctx, plugin.name, "alice:gateway:prod:resource:2", 100, 60
            )
        end)

        it("returns the resource strategy error and stops at the first rejected window", function()
            conf.rates.__default = {{period = 1, tokens = 10}, {period = 60, tokens = 100}}
            ratelimit.rate_limit:revert()
            stub(ratelimit, "rate_limit", function() return 429 end)
            assert.equals(429, plugin.access(conf, ctx))
            assert.stub(ratelimit.rate_limit).was_called(1)
            assert.equals(1642903, ctx.var.bk_apigw_error.error.code)
        end)

        it("also enforces a rejected later window", function()
            conf.rates.__default = {{period = 1, tokens = 10}, {period = 60, tokens = 100}}
            ratelimit.rate_limit:revert()
            stub(ratelimit, "rate_limit", function(_, _, _, _, _, period)
                if period == 60 then
                    return 429
                end
            end)
            assert.equals(429, plugin.access(conf, ctx))
            assert.stub(ratelimit.rate_limit).was_called(2)
        end)

        it("preserves resource-rate-limit's rejection on non-degraded backend errors", function()
            ratelimit.rate_limit:revert()
            stub(ratelimit, "rate_limit", function() return 500 end)
            assert.equals(429, plugin.access(conf, ctx))
            assert.equals(1642903, ctx.var.bk_apigw_error.error.code)
        end)
    end)
end)
