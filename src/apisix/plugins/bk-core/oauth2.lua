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
local core = require("apisix.core")
local config = require("apisix.plugins.bk-core.config")
local table_isarray = require("table.isarray")

local ngx = ngx
local ngx_escape_uri = ngx.escape_uri
local ngx_re_find = ngx.re.find
local ipairs = ipairs
local type = type
local string_match = string.match
local string_gsub = string.gsub
local string_format = string.format
local string_sub = string.sub
local string_len = string.len
local table_insert = table.insert

local _M = {}

-- app codes of the builtin OAuth2 clients; other app codes are real BlueKing apps
local BUILTIN_CLIENT_APP_CODES = {
    public = true,
    personal = true,
}


local function strip_subpath_prefix(path, gateway_name)
    local prefix = "/api/" .. gateway_name
    local prefix_len = string_len(prefix)
    if string_sub(path, 1, prefix_len) ~= prefix then
        return path
    end

    local next_char = string_sub(path, prefix_len + 1, prefix_len + 1)
    if next_char ~= "" and next_char ~= "/" then
        return path
    end

    path = string_sub(path, prefix_len + 1)
    if path == "" then
        path = "/"
    end
    return path
end


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

    -- If tmpl is not configured (nil or empty) or has no valid origin, use a minimal challenge.
    local challenge = 'Bearer realm="bk-apigateway"'
    if tmpl ~= nil and tmpl ~= "" then
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
        if rendered_origin then
            -- Step 3: Build the resource path and encode it
            local path = (ctx and ctx.var and ctx.var.uri) or "/"

            -- In some envs, nginx rewrites subdomain to subpath, so the path has an extra /api/{gateway_name} prefix
            -- e.g. /api/bk-apigateway/prod/api/v2/... should be /prod/api/v2/...
            if config.should_strip_subpath_prefix() then
                path = strip_subpath_prefix(path, gateway_name)
            end
            local resource_url = rendered_origin .. path
            local encoded_resource_url = ngx_escape_uri(resource_url)

            challenge = string_format(
                'Bearer resource_metadata="%s/prod/api/v2/open/.well-known/oauth-protected-resource?resource=%s"',
                base_url,
                encoded_resource_url
            )
        end
    end

    if error_code and error_description then
        return challenge .. string_format(
            ', error="%s", error_description="%s"',
            escape_auth_header_value(error_code),
            escape_auth_header_value(error_description)
        )
    end
    return challenge
end


---Check whether the app code belongs to a real BlueKing app instead of a builtin OAuth2 client
---@param app_code string|nil
---@return boolean
function _M.is_real_app_code(app_code)
    return type(app_code) == "string" and app_code ~= "" and not BUILTIN_CLIENT_APP_CODES[app_code]
end


local function check_prefix_pattern(pattern, index)
    local field = "bearer_token_rules[" .. index .. "].prefix_pattern"
    if type(pattern) ~= "string" then
        return field .. " must be a string"
    end

    local _, _, err = ngx_re_find("", pattern, "jo")
    if err then
        return field .. "=" .. pattern .. " is invalid: " .. err
    end
end


---Validate and prepare bearer_token_rules when the plugin loads.
---@return table rules Validated rules, possibly empty if the configuration is invalid
---@return table problems Invalid configuration diagnostics
function _M.validate_bkauth_bearer_token_rules()
    local rules = config.get_oauth2_bearer_token_rules()
    if type(rules) ~= "table" or not table_isarray(rules) then
        return {}, { "bearer_token_rules must be a list" }
    end

    local validated_rules = {}
    local problems = {}
    for index, rule in ipairs(rules) do
        if type(rule) ~= "table" then
            table_insert(problems, "bearer_token_rules[" .. index .. "] must be an object")
        else
            local problem = check_prefix_pattern(rule.prefix_pattern, index)
            if problem then
                table_insert(problems, problem)
            else
                table_insert(validated_rules, { prefix_pattern = rule.prefix_pattern })
            end
        end
    end

    return validated_rules, problems
end


---Match a Bearer token by prefix. Introspection validates the token itself.
---@param token string The Bearer token
---@param rules table The rules prepared at plugin init
---@return boolean
function _M.is_bkauth_bearer_token(token, rules)
    for _, rule in ipairs(rules) do
        local from, _, err = ngx_re_find(token, rule.prefix_pattern, "jo")
        if err then
            core.log.error("invalid bk_oauth2.bearer_token_rules prefix_pattern=", rule.prefix_pattern,
                           ", error: ", err)
        elseif from then
            return true
        end
    end
    return false
end


if _TEST then -- luacheck: ignore
    _M._escape_auth_header_value = escape_auth_header_value
    _M._strip_subpath_prefix = strip_subpath_prefix
end

return _M
