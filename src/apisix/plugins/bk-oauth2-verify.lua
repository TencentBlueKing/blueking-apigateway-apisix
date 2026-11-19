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
-- # bk-oauth2-verify
--
-- This plugin verifies OAuth2 access tokens via the bkauth service and sets
-- the authentication-related context variables (bk_app, bk_user, audience, etc.)
--
-- It also detects the token mode from the introspection result and sets
-- ctx.var.bk_oauth2_token_mode:
--     * "delegated": sub ~= client_id and username is not empty, the token carries a user
--     * "app": sub == client_id and username is empty, an app token without user;
--       the user is left empty and unverified, `sub` is never used as the username
--     * "unknown": any other combination, including sub/client_id/username that are missing,
--       empty, JSON null or not a string; the user is set as before, and
--       bk-oauth2-appcode-validate rejects it for real BlueKing apps
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
local oauth2 = require("apisix.plugins.bk-core.oauth2")
local oauth2_cache = require("apisix.plugins.bk-cache.oauth2-access-token")
local bk_app_define = require("apisix.plugins.bk-define.app")
local bk_user_define = require("apisix.plugins.bk-define.user")
local ngx = ngx

local ngx_time = ngx.time
local string_lower = string.lower
local string_sub = string.sub
local string_match = string.match

local plugin_name = "bk-oauth2-verify"
local TOKEN_MODE_DELEGATED = "delegated"
local TOKEN_MODE_APP = "app"
local TOKEN_MODE_UNKNOWN = "unknown"
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


---Introspection fields may be missing, JSON null (cjson.null is truthy) or of another type
---@param value any
---@return string value The value when it is a string, otherwise ""
local function string_field(value)
    if type(value) ~= "string" then
        return ""
    end
    return value
end


---Detect whether the token carries a user (delegated) or only an app (app)
---@param result table The verification result from bkauth
---@return string mode One of "delegated", "app", "unknown"
local function detect_token_mode(result)
    local sub = string_field(result.bk_username)
    local client_id = string_field(result.client_id)
    local username = string_field(result.bk_login_name)
    if sub == "" or client_id == "" then
        return TOKEN_MODE_UNKNOWN
    end

    if sub ~= client_id and username ~= "" then
        return TOKEN_MODE_DELEGATED
    end

    if sub == client_id and username == "" then
        return TOKEN_MODE_APP
    end

    return TOKEN_MODE_UNKNOWN
end


---Create a user object from the verification result
---@param result table The verification result from bkauth
---@param token_mode string The detected token mode
---@return table user The user object
local function create_user_from_result(result, token_mode)
    if token_mode == TOKEN_MODE_APP then
        return bk_user_define.new_anonymous_user("the OAuth2 app token does not carry a user")
    end

    local username = string_field(result.bk_username)
    return bk_user_define.new_user({
        username = username,
        verified = username ~= "",
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
        local www_auth = oauth2.build_www_authenticate_header(
            ctx, "invalid_request", "Bearer token not found in Authorization header")
        ngx.header["WWW-Authenticate"] = www_auth
        return errorx.exit_with_apigw_err(ctx, err, _M)
    end

    local masked_token = mask_token(access_token)

    -- Verify the token via bkauth (with caching)
    -- The cache resolves any usable fallback before returning a dependency error.
    local result, err = verify_token(access_token)
    if result == nil then
        core.log.info("bk-oauth2-verify: introspection failed, token_hint=", masked_token, ", error=", err)
        local error_message = "call bkauth api to verify token failed: " .. (err or "unknown error")
        local error_obj = errorx.new_service_unavailable():with_field("reason", error_message)
        return errorx.exit_with_apigw_err(ctx, error_obj, _M)
    end

    local error_obj = errorx.new_general_unauthorized():with_field("token_hint", masked_token)
    if not result.active then
        local error_message = string_field(result.error.message)
        core.log.info("bk-oauth2-verify: inactive token, token_hint=", masked_token,
                      ", error_code=", string_field(result.error.code),
                      ", error_message=", error_message)

        local reason = "the access token is inactive"
        if error_message ~= "" then
            reason = reason .. " [" .. error_message .. "]"
        end
        error_obj = error_obj:with_field("reason", reason)
        ngx.header["WWW-Authenticate"] = oauth2.build_www_authenticate_header(ctx, "invalid_token", reason)
        return errorx.exit_with_apigw_err(ctx, error_obj, _M)
    end

    -- the token verified is cached, so we need to check if it's expired
    if result.exp < ngx_time() then
        core.log.info("bk-oauth2-verify: token expired, token_hint=", masked_token, ", exp=", result.exp)
        error_obj = error_obj:with_field("reason", "token expired")
        local www_auth = oauth2.build_www_authenticate_header(ctx, "invalid_token", "token expired")
        ngx.header["WWW-Authenticate"] = www_auth

        return errorx.exit_with_apigw_err(ctx, error_obj, _M)
    end

    local token_mode = detect_token_mode(result)
    core.log.info("bk-oauth2-verify: token verified, app=", result.bk_app_code,
                  ", user=", string_field(result.bk_username), ", token_mode=", token_mode,
                  ", audience_count=", #(result.audience or {}))

    -- Create and set app object
    local app = create_app_from_result(result)
    ctx.var.bk_app = app

    -- Create and set user object
    local user = create_user_from_result(result, token_mode)
    ctx.var.bk_user = user

    -- Set additional context variables
    ctx.var.bk_oauth2_token_mode = token_mode
    ctx.var.bk_app_code = result.bk_app_code or ""
    ctx.var.bk_username = user.username
    ctx.var.audience = result.audience or {}
    ctx.var.auth_params_location = "header"

    -- The gateway has consumed this credential; do not forward it upstream.
    core.request.set_header(ctx, AUTHORIZATION_HEADER, nil)
end


if _TEST then -- luacheck: ignore
    _M._extract_bearer_token = extract_bearer_token
    _M._mask_token = mask_token
    _M._verify_token = verify_token
    _M._create_app_from_result = create_app_from_result
    _M._create_user_from_result = create_user_from_result
    _M._detect_token_mode = detect_token_mode
end

return _M
