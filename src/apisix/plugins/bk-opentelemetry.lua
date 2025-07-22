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


-- bk-opentelemetry
--
-- A plugin for Apache APISIX that integrates OpenTelemetry API for observability.
-- This plugin measures the performance and provides distributed tracing capabilities
-- within the API Gateway. It collects various attributes from the request context,
-- such as instance ID, app code, gateway name, stage name, etc., and injects them
-- into the OpenTelemetry spans for better insights into the API Gateway's performance
-- and operation.
--
-- Configurations:
--   enabled: enable or disable the plugin, from dashboard publish
-- other attr:
--   sampler.name
--   sampler.options
--   .... from plugin_metadata


local core = require("apisix.core")
local opentelemetry = require("apisix.plugins.opentelemetry")
local plugin = require("apisix.plugin")
local attr = require("opentelemetry.attribute")
local context = require("opentelemetry.context").new()


local metadata_schema = core.table.deepcopy(opentelemetry.schema)
local plugin_name = "bk-opentelemetry"


local attr_schema = {
    type = "object",
    properties = {
        enabled = {
            type = "boolean",
            description = "enable or disable the plugin",
            default = false,
        },
    },
}

local _M = {
    version = 0.1,
    priority = 18870,
    name = plugin_name,
    schema = {},
    metadata_schema = metadata_schema,
    attr_schema = attr_schema,
}

---@param conf table configuration data
---@param schema_type string Type of schema to check
function _M.check_schema(conf, schema_type)
    if schema_type == core.schema.TYPE_METADATA then
        return core.schema.check(metadata_schema, conf)
    end

    return true
end

local plugin_info

function _M.init()
    -- get the plugin attribute and validate it
    plugin_info = plugin.plugin_attr(plugin_name) or {}
    local ok, err = core.schema.check(attr_schema, plugin_info)
    if not ok then
        core.log.error("failed to check the plugin_attr[", plugin_name, "]",
                ": ", err)
        -- disable the phases
        _M.rewrite = nil
        _M.delayed_body_filter = nil
        _M.log = nil
        return
    end

    if not plugin_info.enabled then
        core.log.info("the bk-opentelemetry plugin is disabled")
        -- disable the phases
        _M.rewrite = nil
        _M.delayed_body_filter = nil
        _M.log = nil
        return
    end

    -- Initialize OpenTelemetry
    opentelemetry.init()
end

---@param conf table configuration data
---@param ctx  apisix.Context
function _M.rewrite(conf, ctx)
    ---@type apisix.PluginMetadata
    local metadata = plugin.plugin_metadata(plugin_name)

    -- check if the metadata is valid and call opentelemetry.rewrite
    if not (metadata and metadata.value) then
        return
    end
    opentelemetry.rewrite(metadata.value, ctx)
end


-- inject the bk_* tags into the span
---@param ctx apisix.Context
local function inject_span(ctx)
    -- inject the tags into span
    local current_ctx = context:current()
    if current_ctx then
        -- get span from current context
        local span = current_ctx:span()

        -- NOTE: reset the name from ctx.var.request_uri to ctx.var.uri,
        --       because the ctx.var.request_uri with args contains some sensitive information
        span:set_name(ctx.var.uri)

        span:set_attributes(
            attr.string("instance_id", ctx.var.instance_id),
            attr.string("bk_app_code", ctx.var.bk_app_code),
            attr.string("bk_gateway_name", ctx.var.bk_gateway_name),
            attr.string("bk_stage_name", ctx.var.bk_stage_name),
            attr.string("bk_resource_name", ctx.var.bk_resource_name),
            attr.string("bk_service_name", ctx.var.bk_service_name),
            attr.string("bk_request_id", ctx.var.bk_request_id),
            attr.string("x_request_id", ctx.var.x_request_id)
        )
    end
end

---@param conf table configuration data
---@param ctx  apisix.Context
function _M.delayed_body_filter(conf, ctx)
    ---@type apisix.PluginMetadata
    local metadata = plugin.plugin_metadata(plugin_name)

    if not (metadata and metadata.value) then
        return
    end

    if ngx.arg[2] then
        inject_span(ctx)
    end

    opentelemetry.delayed_body_filter(metadata.value, ctx)
end

---@param conf table configuration data
---@param ctx  apisix.Context
function _M.log(conf, ctx)
    ---@type apisix.PluginMetadata
    local metadata = plugin.plugin_metadata(plugin_name)

    if not (metadata and metadata.value) then
        return
    end

    inject_span(ctx)
    opentelemetry.log(metadata.value, ctx)
end

if _TEST then -- luacheck: ignore
    _M.inject_span = inject_span
end

return _M
