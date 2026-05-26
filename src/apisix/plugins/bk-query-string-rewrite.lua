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

-- bk-query-string-rewrite
--
-- Rewrite the query string parameters of a request using the plugin configuration.
-- - add:    add param only if it does NOT already exist
-- - set:    always set the param value (add or replace)
-- - remove: remove the param if it exists

local core = require("apisix.core")
local pairs = pairs
local ipairs = ipairs
local tostring = tostring

local plugin_name = "bk-query-string-rewrite"

local schema = {
    type = "object",
    description = "rewrite query string parameters",
    minProperties = 1,
    additionalProperties = false,
    properties = {
        add = {
            type = "object",
            patternProperties = {
                ["^[^=&#?]+$"] = {
                    oneOf = {
                        {type = "string"},
                        {type = "number"},
                    },
                },
            },
        },
        set = {
            type = "object",
            patternProperties = {
                ["^[^=&#?]+$"] = {
                    oneOf = {
                        {type = "string"},
                        {type = "number"},
                    },
                },
            },
        },
        remove = {
            type = "array",
            items = {
                type = "string",
                pattern = "^[^=&#?]+$",
            },
        },
    },
}

local _M = {
    version = 0.1,
    priority = 17410,
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


function _M.rewrite(conf, ctx)
    local uri_args = core.request.get_uri_args(ctx)
    local changed = false

    if conf.add then
        for param, value in pairs(conf.add) do
            -- if the param is not in the uri_args, then add it
            -- otherwise, skip it
            if uri_args[param] == nil then
                uri_args[param] = core.utils.resolve_var(tostring(value), ctx.var)
                changed = true
            end
        end
    end

    if conf.set then
        for param, value in pairs(conf.set) do
            uri_args[param] = core.utils.resolve_var(tostring(value), ctx.var)
            changed = true
        end
    end

    if conf.remove then
        for _, param in ipairs(conf.remove) do
            if uri_args[param] ~= nil then
                uri_args[param] = nil
                changed = true
            end
        end
    end

    if changed then
        core.request.set_uri_args(ctx, uri_args)
    end
end


return _M
