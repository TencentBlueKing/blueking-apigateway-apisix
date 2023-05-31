--
-- TencentBlueKing is pleased to support the open source community by making
-- 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
-- Copyright (C) 2017 THL A29 Limited, a Tencent company. All rights reserved.
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

-- This plugin is use to get the real ip from the request.
-- Unlike apisix real-ip plugin, this plugin is not depend on plugin configuration,
-- instead, it use the metadata as the configuration.
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

function _M.check_schema(conf, schema_type)
    if schema_type == core.schema.TYPE_METADATA then
        return real_ip.check_schema(conf)
    end

    return true
end

function _M.rewrite(conf, ctx)
    ---@type apisix.PluginMetadata
    local metadata = plugin.plugin_metadata(plugin_name)

    local real_conf = default_metadata
    if metadata and metadata.value then
        real_conf = metadata.value
    end

    -- apisix handle the XFF header in nginx configuration,
    -- so we don't need to handle it here.
    return real_ip.rewrite(real_conf, ctx)
end

return _M
