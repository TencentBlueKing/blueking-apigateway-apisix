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

-- # bk-auth-validate
--
-- Validate current request and return an error response if the validation is required
-- and the verified data is not valid.
--
-- This plugin heavily depends on the "bk-auth-verify" plugin, the latter adds the required
-- app and user objects to the context, so that "bk-auth-validate" can read these objects and
-- check them directly.
--
-- The whitelist configuration is used during the validation to check if the process should
-- be skipped.
--
-- This plugin depends on:
--     * bk-resource-auth: To determine whether a verified data is necessary.
--     * bk-auth-verify: Get the verified bk_app and bk_user objects.
--     * bk-verified-user-exempted-apps: Get the whitelist configurations of current gateway.
--
local core = require("apisix.core")
local errorx = require("apisix.plugins.bk-core.errorx")
local pl_types = require("pl.types")
local tostring = tostring

local plugin_name = "bk-auth-validate"

local schema = {
    type = "object",
    properties = {},
}

local _M = {
    version = 0.1,
    priority = 17680,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

-- Check if the current request is exempt from the requirement to provide a verified user.
-- @param app_code The Application code.
-- @bk_resource_id The ID of current resource.
-- @verified_user_exempted_apps The whitelist configuration data of current gateway.
-- @return The bool result.
local function is_app_exempted_from_verified_user(app_code, bk_resource_id, verified_user_exempted_apps)
    if pl_types.is_empty(app_code) or verified_user_exempted_apps == nil then
        return false
    end

    if verified_user_exempted_apps.by_gateway[app_code] == true then
        return true
    end

    if bk_resource_id ~= nil and verified_user_exempted_apps.by_resource[app_code] and
        verified_user_exempted_apps.by_resource[app_code][tostring(bk_resource_id)] == true then
        return true
    end

    return false
end

-- Validate the given app object.
-- @return An error message when invalid.
local function validate_app(bk_resource_auth, app)
    if not bk_resource_auth:get_verified_app_required() then
        return nil
    end

    if app.verified then
        return nil
    end

    return app.valid_error_message
end

local function validate_user(bk_resource_id, bk_resource_auth, user, app, verified_user_exempted_apps)
    if (not bk_resource_auth:get_verified_user_required() or
            is_app_exempted_from_verified_user(app:get_app_code(), bk_resource_id, verified_user_exempted_apps) or
            bk_resource_auth:get_skip_user_verification()) then
        return nil
    end

    if user.verified then
        return nil
    end

    return user.valid_error_message
end

function _M.rewrite(conf, ctx) -- luacheck: no unused
    -- Return directly if "bk-resource-auth" is not loaded by checking "bk_resource_auth"
    if ctx.var.bk_resource_auth == nil then
        return
    end

    local err = validate_app(ctx.var.bk_resource_auth, ctx.var.bk_app)
    if err ~= nil then
        return errorx.exit_with_apigw_err(ctx, errorx.new_invalid_args():with_field("reason", err), _M)
    end

    err = validate_user(
        ctx.var.bk_resource_id, ctx.var.bk_resource_auth, ctx.var.bk_user, ctx.var.bk_app,
        ctx.var.verified_user_exempted_apps
    )
    if err ~= nil then
        return errorx.exit_with_apigw_err(ctx, errorx.new_invalid_args():with_field("reason", err), _M)
    end
end

if _TEST then -- luacheck: ignore
    _M._is_app_exempted_from_verified_user = is_app_exempted_from_verified_user
    _M._validate_app = validate_app
    _M._validate_user = validate_user
end

return _M
