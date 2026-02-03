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
-- # bk-oauth2-audience-validate
--
-- This plugin validates the audience claims in OAuth2 tokens to ensure
-- the token is authorized for the specific resource being accessed.
--
-- Audience formats supported:
--   - mcp_server:{mcp_server_name} - Access to specific MCP server
--   - gateway:{gateway_name}/api:{api_name} - Access to specific gateway API
--   - gateway:{gateway_name}/api:* - Access to all APIs under a gateway (wildcard)
--
-- This plugin only runs when ctx.var.is_bk_oauth2 == true (set by bk-oauth2-protected-resource).
--
-- This plugin depends on:
--     * bk-oauth2-verify: To set ctx.var.audience
--
local pl_types = require("pl.types")
local core = require("apisix.core")
local errorx = require("apisix.plugins.bk-core.errorx")
local ngx = ngx
local ngx_re = ngx.re
local ipairs = ipairs
local string_match = string.match

local plugin_name = "bk-oauth2-audience-validate"

local BK_APIGATEWAY_GATEWAY_NAME = "bk-apigateway"
local MCP_SERVER_PATH_PATTERN = [[/prod/api/v2/mcp-servers/([^/]+)]]

local schema = {
    type = "object",
    properties = {},
}

local _M = {
    version = 0.1,
    priority = 17678,
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


---Parse an audience string into structured data
---@param audience_str string The audience string to parse
---@return table|nil parsed The parsed audience data, or nil if format unknown
local function parse_audience(audience_str)
    if pl_types.is_empty(audience_str) then
        return nil
    end

    -- Try mcp_server:{name} format
    local mcp_name = string_match(audience_str, "^mcp_server:(.+)$")
    if mcp_name then
        return {
            type = "mcp_server",
            name = mcp_name,
        }
    end

    -- Try gateway:{gateway}/api:{api} format
    local gateway, api = string_match(audience_str, "^gateway:([^/]+)/api:(.+)$")
    if gateway and api then
        return {
            type = "gateway_api",
            gateway = gateway,
            api = api,
        }
    end

    -- Unknown format
    return nil
end


---Extract MCP server name from request path
---@param path string The request URI path
---@return string|nil mcp_server_name The extracted MCP server name, or nil if not found
local function extract_mcp_server_from_path(path)
    if pl_types.is_empty(path) then
        return nil
    end

    local m = ngx_re.match(path, MCP_SERVER_PATH_PATTERN, "jo")
    if m and m[1] then
        return m[1]
    end

    return nil
end


---Check if an MCP server audience matches the current request
---@param parsed table The parsed audience data
---@param ctx table The current context
---@return boolean matches Whether the audience matches
---@return string reason The reason for mismatch
local function check_mcp_server_audience(parsed, ctx)
    -- MCP server audiences are only valid for bk-apigateway gateway
    if ctx.var.bk_gateway_name ~= BK_APIGATEWAY_GATEWAY_NAME then
        return false, "mcp_server audience requires bk-apigateway gateway"
    end

    -- Extract MCP server name from path
    local path_mcp_server = extract_mcp_server_from_path(ctx.var.uri)
    if not path_mcp_server then
        -- Path doesn't match MCP server pattern
        return false, "request path does not match mcp_server pattern"
    end

    -- Check if the MCP server from path matches the audience
    if path_mcp_server == parsed.name then
        return true, ""
    end

    return false, "mcp_server mismatch: audience=" .. parsed.name .. ", path=" .. path_mcp_server
end


---Check if a gateway API audience matches the current request
---@param parsed table The parsed audience data
---@param ctx table The current context
---@return boolean matches Whether the audience matches
---@return string reason The reason for mismatch
local function check_gateway_api_audience(parsed, ctx)
    local current_gateway = ctx.var.bk_gateway_name
    local current_resource = ctx.var.bk_resource_name

    -- Check gateway matches
    if parsed.gateway ~= current_gateway then
        return false, "gateway mismatch: audience=" .. parsed.gateway .. ", request=" .. current_gateway
    end

    -- Check API matches (or wildcard)
    if parsed.api == "*" then
        -- Wildcard matches all APIs under this gateway
        return true, ""
    end

    if parsed.api == current_resource then
        return true, ""
    end

    return false, "api mismatch: audience=" .. parsed.api .. ", request=" .. (current_resource or "nil")
end


---Validate the audience claims against the current request
---@param ctx table The current context
---@return boolean valid Whether the audience is valid
---@return string reason The reason for validation failure
local function validate_audience(ctx)
    local audience = ctx.var.audience

    if pl_types.is_empty(audience) then
        return false, "empty audience"
    end

    local last_reason = ""

    -- Check each audience claim
    for _, aud_str in ipairs(audience) do
        local parsed = parse_audience(aud_str)
        if parsed then
            local matches, reason

            if parsed.type == "mcp_server" then
                matches, reason = check_mcp_server_audience(parsed, ctx)
            elseif parsed.type == "gateway_api" then
                matches, reason = check_gateway_api_audience(parsed, ctx)
            end

            if matches then
                return true, ""
            end

            if reason ~= "" then
                last_reason = reason
            end
        end
    end

    if last_reason == "" then
        return false, "no matching audience found"
    end

    return false, last_reason
end


function _M.rewrite(conf, ctx) -- luacheck: no unused
    -- Only run if OAuth2 flow is active
    if ctx.var.is_bk_oauth2 ~= true then
        return
    end

    -- Validate audience
    local valid, reason = validate_audience(ctx)
    if not valid then
        local err = errorx.new_app_no_permission():with_field("reason", reason)
        return errorx.exit_with_apigw_err(ctx, err, _M)
    end

    -- Audience validated successfully, allow request to proceed
end


if _TEST then -- luacheck: ignore
    _M._parse_audience = parse_audience
    _M._extract_mcp_server_from_path = extract_mcp_server_from_path
    _M._check_mcp_server_audience = check_mcp_server_audience
    _M._check_gateway_api_audience = check_gateway_api_audience
    _M._validate_audience = validate_audience
end

return _M
