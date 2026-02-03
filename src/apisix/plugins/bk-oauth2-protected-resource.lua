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


---Parse Bearer token from Authorization header
---@param authorization string|nil The Authorization header value
---@return string|nil token The extracted token, or nil if not a Bearer token
local function parse_bearer_token(authorization)
    if pl_types.is_empty(authorization) then
        return nil
    end

    local auth_lower = string_lower(authorization)
    if string_sub(auth_lower, 1, BEARER_PREFIX_LEN) ~= BEARER_PREFIX then
        return nil
    end

    local token = string_match(authorization, "^[Bb]earer%s+(.+)$")
    return token
end


---Build the WWW-Authenticate header value for OAuth2 discovery
---@param ctx table The current context object
---@return string The WWW-Authenticate header value
local function build_www_authenticate_header(ctx)
    local origin = bk_core.config.get_bkauth_origin()
    local path = ctx.var.uri or "/"
    local encoded_path = ngx_escape_uri(path)

    return string.format(
        'Bearer resource_metadata="%s/.well-known/oauth-protected-resource?resource=%s"',
        origin,
        encoded_path
    )
end


function _M.rewrite(conf, ctx) -- luacheck: no unused
    -- Check for X-Bkapi-Authorization header first (legacy BlueKing auth)
    -- If present, skip OAuth2 flow and allow legacy flow to handle authentication
    local bkapi_auth = core.request.header(ctx, BKAPI_AUTHORIZATION_HEADER)
    if not pl_types.is_empty(bkapi_auth) then
        ctx.var.is_bk_oauth2 = false
        return
    end

    -- Check for Authorization: Bearer header (OAuth2)
    local authorization = core.request.header(ctx, AUTHORIZATION_HEADER)
    local bearer_token = parse_bearer_token(authorization)

    if bearer_token then
        -- OAuth2 flow: set flag and store token for downstream plugins
        ctx.var.is_bk_oauth2 = true
        ctx.var.oauth2_access_token = bearer_token
        return
    end

    -- No valid auth headers present
    -- Return 401 with WWW-Authenticate header for OAuth2 discovery
    local www_authenticate = build_www_authenticate_header(ctx)
    ngx.header["WWW-Authenticate"] = www_authenticate

    local err = errorx.new_general_unauthorized():with_field("reason", "authentication required")
    return errorx.exit_with_apigw_err(ctx, err, _M)
end


if _TEST then -- luacheck: ignore
    _M._parse_bearer_token = parse_bearer_token
    _M._build_www_authenticate_header = build_www_authenticate_header
end

return _M
