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
-- # bk-oauth2-protected-resource
--
-- This plugin detects whether a request uses OAuth2 authentication (Authorization: Bearer)
-- or legacy BlueKing authentication (X-Bkapi-Authorization) and routes accordingly.
--
-- Configured user ticket cookies also use legacy authentication when the resource
-- requires only user authentication. Otherwise, missing credentials return 401
-- with a WWW-Authenticate header containing the resource_metadata URL for OAuth2 discovery.
--
-- This plugin depends on:
--     * bk-core.config: For hosts.bk-apigateway-host configuration
--
local pl_types = require("pl.types")
local core = require("apisix.core")
local cookie = require("apisix.plugins.bk-core.cookie")
local oauth2 = require("apisix.plugins.bk-core.oauth2")
local errorx = require("apisix.plugins.bk-core.errorx")
local ngx = ngx
local string_sub = string.sub
local string_lower = string.lower
local string_match = string.match

local plugin_name = "bk-oauth2-protected-resource"

local BKAPI_AUTHORIZATION_HEADER = "X-Bkapi-Authorization"
local AUTHORIZATION_HEADER = "Authorization"
local BEARER_PREFIX = "bearer "
local BEARER_PREFIX_LEN = #BEARER_PREFIX

local schema = {
    type = "object",
    properties = {},
}

local _M = {
    version = 0.1,
    priority = 18740,
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


---Parse Bearer token from Authorization header (RFC 6750 case-insensitive)
---@param authorization string|nil The Authorization header value
---@return string|nil token The extracted token, or nil if not a Bearer token
local function parse_bearer_token(authorization)
    if pl_types.is_empty(authorization) then
        return nil
    end

    -- Case-insensitive check for "Bearer " prefix (RFC 6750)
    local auth_lower = string_lower(authorization)
    if string_sub(auth_lower, 1, BEARER_PREFIX_LEN) ~= BEARER_PREFIX then
        return nil
    end

    -- Extract token after prefix, trim leading whitespace
    local token = string_sub(authorization, BEARER_PREFIX_LEN + 1)
    token = string_match(token, "^%s*(.+)$")
    return token
end


local function has_configured_user_ticket_cookie(ctx)
    local resource_auth = ctx.var.bk_resource_auth
    local api_auth = ctx.var.bk_api_auth
    if not resource_auth or not resource_auth:get_verified_user_required()
        or resource_auth:get_verified_app_required() or not api_auth then
        return false
    end

    local user_conf = api_auth:get_user_conf()
    if not user_conf:is_empty() and user_conf.from_bk_token
        and not pl_types.is_empty(cookie.get_value("bk_token")) then
        return true
    end

    local rtx_conf = api_auth:get_rtx_conf()
    return not api_auth:is_user_type_uin() and not rtx_conf:is_empty() and rtx_conf.from_bk_ticket
        and not pl_types.is_empty(cookie.get_value("bk_ticket"))
end


function _M.rewrite(conf, ctx) -- luacheck: no unused
    -- Check for X-Bkapi-Authorization header first (legacy BlueKing auth)
    -- If present, skip OAuth2 flow and allow legacy flow to handle authentication
    local bkapi_auth = core.request.header(ctx, BKAPI_AUTHORIZATION_HEADER)
    if not pl_types.is_empty(bkapi_auth) then
        ctx.var.is_bk_oauth2 = false
        core.log.info("bk-oauth2-protected-resource: X-Bkapi-Authorization present, using legacy auth")
        return
    end

    -- Check for Authorization: Bearer header (OAuth2)
    local authorization = core.request.header(ctx, AUTHORIZATION_HEADER)
    local bearer_token = parse_bearer_token(authorization)

    if bearer_token then
        -- OAuth2 flow: set flag for downstream plugins
        ctx.var.is_bk_oauth2 = true
        core.log.info("bk-oauth2-protected-resource: Bearer token detected, using OAuth2 flow")
        return
    end

    -- An explicit but malformed Bearer credential must retain the challenge, not use cookies.
    local auth_lower = string_lower(authorization or "")
    local is_bearer_auth = auth_lower == "bearer" or string_match(auth_lower, "^bearer%s")

    -- Only select the legacy flow here; it still verifies the cookie and resource requirements.
    if not is_bearer_auth and has_configured_user_ticket_cookie(ctx) then
        ctx.var.is_bk_oauth2 = false
        core.log.info("bk-oauth2-protected-resource: user cookie detected, using legacy auth")
        return
    end

    -- No supported authentication credentials present
    -- Return 401 with WWW-Authenticate header for OAuth2 discovery
    core.log.info("bk-oauth2-protected-resource: no valid auth header, returning 401 with WWW-Authenticate")
    local www_auth = oauth2.build_www_authenticate_header(
        ctx, "invalid_request", "no valid authentication header found")
    ngx.header["WWW-Authenticate"] = www_auth

    local err = errorx.new_general_unauthorized()
        :with_field("reason", "no valid authentication header found")
        :with_field("expected", "Authorization: Bearer <token>")
    return errorx.exit_with_apigw_err(ctx, err, _M)
end


if _TEST then -- luacheck: ignore
    _M._parse_bearer_token = parse_bearer_token
end

return _M
