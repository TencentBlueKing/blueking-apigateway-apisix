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

-- # bk-verified-user-exempted-apps
--
-- Add the whitelist configuration to the current request context, the config data is related to
-- "exempt a user from verification".
--
-- The plugin reads the data from the plugin configuration, then transforms it to another data
-- structure to make it easily usable by other plugins.
--
-- This plugin have no dependencies.

local core = require("apisix.core")
local pl_types = require("pl.types")
local ipairs = ipairs
local tostring = tostring

local plugin_name = "bk-verified-user-exempted-apps"

local schema = {
    type = "object",
    required = {
        "exempted_apps",
    },
    properties = {
        exempted_apps = {
            type = "array",
            items = {
                type = "object",
                properties = {
                    bk_app_code = {
                        type = "string",
                    },
                    dimension = {
                        type = "string",
                    },
                    resource_ids = {
                        type = "array",
                        items = {
                            type = "integer",
                        },
                    },
                },
            },
        },
    },
}

local _M = {
    version = 0.1,
    priority = 18810,
    name = plugin_name,
    schema = schema,
}


---Get the whitelist config of "user exempted from verification".
---@param exempted_apps table A list of raw config data.
---@return table|nil apps A table contains two whitelists in different dimensions.
---
---    An example:
---    {
---       by_gateway = {app1 = true, app2 = true},
---       by_resource = {app3 = {"100" = true, "12" = true}}
---    }
---
---TODO: Rename "Verified User Exempted Apps" to a shorter and more precise name.
local function get_verified_user_exempted_apps(exempted_apps)
    if pl_types.is_empty(exempted_apps) then
        return nil
    end


    local verified_user_exempted_apps = {
        by_gateway = {},
        by_resource = {},
    }
    for _, item in ipairs(exempted_apps) do
        if item.dimension == "api" then
            -- 应用对网关下所有资源均豁免用户认证
            verified_user_exempted_apps.by_gateway[item.bk_app_code] = true
        else
            verified_user_exempted_apps.by_resource[item.bk_app_code] = {}
            for _, resource_id in ipairs(item.resource_ids or {}) do
                -- 将 resource_id 转换为字符串，确保其为字典映射
                verified_user_exempted_apps.by_resource[item.bk_app_code][tostring(resource_id)] = true
            end
        end
    end

    return verified_user_exempted_apps
end

function _M.check_schema(conf)
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return false, err
    end

    conf.verified_user_exempted_apps = get_verified_user_exempted_apps(conf.exempted_apps)
    return true
end

function _M.rewrite(conf, ctx)
    ctx.var.verified_user_exempted_apps = conf.verified_user_exempted_apps
end

if _TEST then -- luacheck: ignore
    _M._get_verified_user_exempted_apps = get_verified_user_exempted_apps
end

return _M
