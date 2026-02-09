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
local config = require("apisix.plugins.bk-core.config")

local ngx = ngx
local ngx_escape_uri = ngx.escape_uri
local string_match = string.match
local string_gsub = string.gsub
local string_format = string.format

local _M = {}


local function escape_auth_header_value(value)
    if value == nil or value == "" then
        return ""
    end

    local escaped = string_gsub(value, "\\", "\\\\")
    escaped = string_gsub(escaped, '"', '\\"')
    return escaped
end

---Build the WWW-Authenticate header value for OAuth2 discovery
---@param ctx table The current context object
---@param error_code string|nil The OAuth2 error code (e.g., "invalid_token", "invalid_request")
---@param error_description string|nil The human-readable error description
---@return string The WWW-Authenticate header value
function _M.build_www_authenticate_header(ctx, error_code, error_description)
    local tmpl = config.get_bk_apigateway_api_tmpl()

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
    local gateway_name = (ctx and ctx.var and ctx.var.bk_gateway_name) or "unknown"
    local rendered_url = string_gsub(tmpl, "{api_name}", gateway_name)
    local rendered_origin = string_match(rendered_url, "^(https?://[^/]+)")

    -- Step 3: Build the resource path and encode it
    local path = (ctx and ctx.var and ctx.var.uri) or "/"
    local resource_url = rendered_origin .. path
    local encoded_resource_url = ngx_escape_uri(resource_url)

    if error_code and error_description then
        local tmpl_str = 'Bearer resource_metadata="%s/prod/api/v2/open/.well-known/' ..
            'oauth-protected-resource?resource=%s", error="%s", error_description="%s"'
        return string_format(
            tmpl_str,
            base_url,
            encoded_resource_url,
            escape_auth_header_value(error_code),
            escape_auth_header_value(error_description)
        )
    end

    return string_format(
        'Bearer resource_metadata="%s/prod/api/v2/open/.well-known/oauth-protected-resource?resource=%s"',
        base_url,
        encoded_resource_url
    )
end


if _TEST then -- luacheck: ignore
    _M._escape_auth_header_value = escape_auth_header_value
end

return _M
