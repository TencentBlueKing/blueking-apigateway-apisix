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
--     * bk-oauth2-protected-resource: To set is_bk_oauth2 flag
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

local ngx_time = ngx.time
local string_lower = string.lower
local string_sub = string.sub
local string_match = string.match
local string_gsub = string.gsub
local string_format = string.format

local plugin_name = "bk-oauth2-verify"
local AUTHORIZATION_HEADER = "Authorization"
local BEARER_PREFIX = "bearer "
local BEARER_PREFIX_LEN = #BEARER_PREFIX

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


---Extract Bearer token from Authorization header
---@param ctx table The current context
---@return string|nil token The extracted token, or nil if not found
local function extract_bearer_token(ctx)
    local authorization = core.request.header(ctx, AUTHORIZATION_HEADER)
    if pl_types.is_empty(authorization) then
        return nil
    end

    -- Case-insensitive check for "Bearer " prefix
    local auth_lower = string_lower(authorization)
    if string_sub(auth_lower, 1, BEARER_PREFIX_LEN) ~= BEARER_PREFIX then
        return nil
    end

    -- Extract token after "Bearer " prefix
    local token = string_sub(authorization, BEARER_PREFIX_LEN + 1)
    -- Trim leading whitespace
    token = string_match(token, "^%s*(.+)$")
    return token
end


---Mask token for logging (security)
---@param token string The access token
---@return string masked The masked token
local function mask_token(token)
    if not token or #token < 8 then
        return "***"
    end
    return string_sub(token, 1, 4) .. "******" .. string_sub(token, -4)
end


local function escape_auth_header_value(value)
    if pl_types.is_empty(value) then
        return ""
    end

    local escaped = string_gsub(value, "\\", "\\\\")
    escaped = string_gsub(escaped, '"', '\\"')
    return escaped
end


local function build_www_authenticate_header(ctx, reason, error)
    local realm = "bk-apigateway"
    if ctx and ctx.var and not pl_types.is_empty(ctx.var.bk_gateway_name) then
        realm = ctx.var.bk_gateway_name
    end

    local description = reason or "token verification failed"
    return string_format(
        'Bearer realm="%s", error="%s", error_description="%s"',
        escape_auth_header_value(realm),
        escape_auth_header_value(error),
        escape_auth_header_value(description)
    )
end


local function set_www_authenticate_header(ctx, reason, error)
    local header_value = build_www_authenticate_header(ctx, reason, error or "invalid_token")
    core.response.set_header("WWW-Authenticate", header_value)
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
        core.log.info("bk-oauth2-verify: skipping, is_bk_oauth2=", ctx.var.is_bk_oauth2)
        return
    end

    -- Extract Bearer token from Authorization header
    local access_token = extract_bearer_token(ctx) or ""
    if pl_types.is_empty(access_token) then
        core.log.info("bk-oauth2-verify: Bearer token not found in Authorization header")

        local err = errorx.new_general_unauthorized()
            :with_field("reason", "Bearer token not found in Authorization header")
        set_www_authenticate_header(ctx, "Bearer token not found in Authorization header", "invalid_request")
        return errorx.exit_with_apigw_err(ctx, err, _M)
    end

    local masked_token = mask_token(access_token)
    local error_obj = errorx.new_general_unauthorized():with_field("token_hint", masked_token)

    -- Verify the token via bkauth (with caching)
    local result, err = verify_token(access_token)
    if result == nil then
        core.log.info("bk-oauth2-verify: token verification failed, token_hint=", masked_token, ", error=", err)

        -- wrap it, it's an internal error
        local error_message = "call bkauth api to verify token failed: " .. (err or "unknown error")
        error_obj = error_obj:with_field("reason", error_message)
        set_www_authenticate_header(ctx, error_message)
        return errorx.exit_with_apigw_err(ctx, error_obj, _M)
    end

    if not result.active then
        core.log.info("bk-oauth2-verify: token verification failed, token_hint=", masked_token, ", error=",
                      result.error.message)

        local reason = result.error.message or "token verification failed, active=false"
        error_obj = error_obj:with_field("reason", reason)
        set_www_authenticate_header(ctx, reason, result.error.code)
        return errorx.exit_with_apigw_err(ctx, error_obj, _M)
    end

    -- the token verified is cached, so we need to check if it's expired
    if result.exp < ngx_time() then
        core.log.info("bk-oauth2-verify: token expired, token_hint=", masked_token, ", exp=", result.exp)
        error_obj = error_obj:with_field("reason", "token expired")
        set_www_authenticate_header(ctx, "token expired")
        return errorx.exit_with_apigw_err(ctx, error_obj, _M)
    end

    core.log.info("bk-oauth2-verify: token verified, app=", result.bk_app_code,
                  ", user=", result.bk_username, ", audience_count=", #(result.audience or {}))

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
    _M._extract_bearer_token = extract_bearer_token
    _M._mask_token = mask_token
    _M._verify_token = verify_token
    _M._create_app_from_result = create_app_from_result
    _M._create_user_from_result = create_user_from_result
end

return _M
