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


-- bk-real-ip
--
-- This is a custom Apache APISIX plugin named "bk-real-ip" that is responsible
-- for obtaining the real IP address of the client.
--
-- The plugin leverages the official "real-ip" plugin to handle IP extraction
-- and passes the necessary configuration and context.
--
-- configuration:
-- source: The default source is "http_x_forwarded_for".
-- recursive: By default, recursion is disabled.

local core = require("apisix.core")
local plugin = require("apisix.plugin")
local real_ip = require("apisix.plugins.real-ip")

-- trust nothing
local default_metadata = {
    source = "http_x_forwarded_for",
    recursive = false,
}

local plugin_name = "bk-real-ip"

---@type apisix.Plugin
local _M = {
    version = 0.1,
    priority = 18809,
    name = plugin_name,
    schema = {},
    metadata_schema = core.table.deepcopy(real_ip.schema),
}

-- Check configuration schema
-- If schema type is metadata,validate against real-ip plugin schema
-- Otherwise, always return true
---@param conf table
---@param schema_type int
function _M.check_schema(conf, schema_type)
    if schema_type == core.schema.TYPE_METADATA then
        return real_ip.check_schema(conf)
    end

    return true
end



-- Rewrite function that processes the client's request to obtain the real IP address
-- using metadata configurations. The function leverages the official real-ip plugin
-- to handle the IP extraction and passes the necessary configuration and context.
---@param conf any
---@param ctx apisix.Context
function _M.rewrite(conf, ctx)
    -- Obtain plugin metadata configured for the plugin_name
    local metadata = plugin.plugin_metadata(plugin_name)

    -- Assign default_metadata to real_conf to be used as a fallback
    local real_conf = default_metadata

    -- Check if custom metadata exists and use its value as the real configuration
    if metadata and metadata.value then
        real_conf = metadata.value
    end

    -- APISIX handles the XFF (X-Forwarded-For) header in the nginx configuration,
    -- so there is no need to handle it in this Lua script.
    return real_ip.rewrite(real_conf, ctx)
end

return _M
