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
-- # bk-oauth2-protected-resource
--
-- This plugin detects whether a request uses OAuth2 authentication (Authorization: Bearer)
-- or legacy BlueKing authentication (X-Bkapi-Authorization) and routes accordingly.
--
-- When no auth headers are present, it returns 401 with a WWW-Authenticate header
-- containing the resource_metadata URL for OAuth2 discovery.
--
-- This plugin depends on:
--     * bk-core.config: For hosts.bk-apigateway-host configuration
--
local pl_types = require("pl.types")
local core = require("apisix.core")
local bk_core = require("apisix.plugins.bk-core.init")
local errorx = require("apisix.plugins.bk-core.errorx")
local ngx = ngx
local ngx_escape_uri = ngx.escape_uri
local string_sub = string.sub
local string_lower = string.lower
local string_match = string.match
local string_gsub = string.gsub

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


---Build the WWW-Authenticate header value for OAuth2 discovery
---@param ctx table The current context object
---@return string The WWW-Authenticate header value
local function build_www_authenticate_header(ctx)
    local tmpl = bk_core.config.get_bk_apigateway_api_tmpl()

    -- If tmpl is not configured (nil or empty), return minimal header
    if tmpl == nil or tmpl == "" then
        return 'Bearer realm="bk-apigateway", error="invalid_request", error_description="api tmpl is not configured"'
    end

    -- Validate that tmpl is a valid URL format (must start with http:// or https://)
    if not string_match(tmpl, "^https?://") then
        return 'Bearer realm="bk-apigateway", error="invalid_request", error_description="invalid api tmpl format"'
    end

    -- The tmpl can be in two formats:
    -- - subpath: http://bkapi.example.com/api/{api_name}
    -- - subdomain: http://{api_name}.bkapi.example.com

    -- Step 1: Replace {api_name} with "bk-apigateway" to get the base URL
    local base_url = string_gsub(tmpl, "{api_name}", "bk-apigateway")

    -- Step 2: Extract scheme and domain (host) from the rendered URL to get the origin
    -- Pattern matches: scheme://host (stops at first / after host or end of string)
    local gateway_name = ctx.var.bk_gateway_name or "unknown"
    local rendered_url = string_gsub(tmpl, "{api_name}", gateway_name)
    local rendered_origin = string_match(rendered_url, "^(https?://[^/]+)")

    -- Step 3: Build the resource path and encode it
    local path = ctx.var.uri or "/"
    local resource_url = rendered_origin .. path
    local encoded_resource_url = ngx_escape_uri(resource_url)

    return string.format(
        'Bearer resource_metadata="%s/prod/api/v2/open/.well-known/oauth-protected-resource?resource=%s"',
        base_url,
        encoded_resource_url
    )
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

    -- No valid auth headers present
    -- Return 401 with WWW-Authenticate header for OAuth2 discovery
    core.log.info("bk-oauth2-protected-resource: no valid auth header, returning 401 with WWW-Authenticate")
    local www_authenticate = build_www_authenticate_header(ctx)
    ngx.header["WWW-Authenticate"] = www_authenticate

    local err = errorx.new_general_unauthorized()
        :with_field("reason", "no valid authentication header found")
        :with_field("expected", "Authorization: Bearer <token>")
    return errorx.exit_with_apigw_err(ctx, err, _M)
end


if _TEST then -- luacheck: ignore
    _M._parse_bearer_token = parse_bearer_token
    _M._build_www_authenticate_header = build_www_authenticate_header
end

return _M
