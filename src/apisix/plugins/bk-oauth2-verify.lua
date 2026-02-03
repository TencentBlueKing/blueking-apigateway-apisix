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
-- # bk-oauth2-verify
--
-- This plugin verifies OAuth2 access tokens via the bkauth service and sets
-- the authentication-related context variables (bk_app, bk_user, audience, etc.)
--
-- This plugin only runs when ctx.var.is_bk_oauth2 == true (set by bk-oauth2-protected-resource).
-- When is_bk_oauth2 is false or nil, the plugin skips processing to allow the legacy
-- bk-auth-verify flow to handle authentication.
--
-- This plugin depends on:
--     * bk-oauth2-protected-resource: To set is_bk_oauth2 and oauth2_access_token
--     * bk-cache/oauth2-access-token: For token verification with caching
--     * bk-define/app: For creating app objects
--     * bk-define/user: For creating user objects
--
local pl_types = require("pl.types")
local core = require("apisix.core")
local errorx = require("apisix.plugins.bk-core.errorx")
local oauth2_cache = require("apisix.plugins.bk-cache.oauth2-access-token")
local bk_app_define = require("apisix.plugins.bk-define.app")
local bk_user_define = require("apisix.plugins.bk-define.user")

local plugin_name = "bk-oauth2-verify"

local schema = {
    type = "object",
    properties = {},
}

local _M = {
    version = 0.1,
    priority = 18732,
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


---Verify the OAuth2 access token and return the verification result
---@param access_token string The OAuth2 access token
---@return table|nil result The verification result
---@return string|nil err The error message if verification failed
local function verify_token(access_token)
    if pl_types.is_empty(access_token) then
        return nil, "access token is empty"
    end

    return oauth2_cache.get_oauth2_access_token(access_token)
end


---Create an app object from the verification result
---@param result table The verification result from bkauth
---@return table app The app object
local function create_app_from_result(result)
    return bk_app_define.new_app({
        app_code = result.bk_app_code or "",
        verified = true,
        valid_error_message = "",
    })
end


---Create a user object from the verification result
---@param result table The verification result from bkauth
---@return table user The user object
local function create_user_from_result(result)
    return bk_user_define.new_user({
        username = result.bk_username or "",
        verified = not pl_types.is_empty(result.bk_username),
        valid_error_message = "",
    })
end


function _M.rewrite(conf, ctx) -- luacheck: no unused
    -- Only run if OAuth2 flow is active
    if ctx.var.is_bk_oauth2 ~= true then
        return
    end

    -- Get the access token from context (set by bk-oauth2-protected-resource)
    local access_token = ctx.var.oauth2_access_token
    if pl_types.is_empty(access_token) then
        local err = errorx.new_general_unauthorized():with_field("reason", "access token not found")
        return errorx.exit_with_apigw_err(ctx, err, _M)
    end

    -- Verify the token via bkauth (with caching)
    local result, err = verify_token(access_token)
    if result == nil then
        local error_obj = errorx.new_general_unauthorized():with_field("reason", err or "token verification failed")
        return errorx.exit_with_apigw_err(ctx, error_obj, _M)
    end

    -- Create and set app object
    local app = create_app_from_result(result)
    ctx.var.bk_app = app

    -- Create and set user object
    local user = create_user_from_result(result)
    ctx.var.bk_user = user

    -- Set additional context variables
    ctx.var.bk_app_code = result.bk_app_code or ""
    ctx.var.bk_username = result.bk_username or ""
    ctx.var.audience = result.audience or {}
    ctx.var.auth_params_location = "header"
end


if _TEST then -- luacheck: ignore
    _M._verify_token = verify_token
    _M._create_app_from_result = create_app_from_result
    _M._create_user_from_result = create_user_from_result
end

return _M
