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

-- bk-header-rewrite
--
-- Rewrite the headers of a request using the plugin configuration.

local core        = require("apisix.core")
local plugin_name = "bk-header-rewrite"
local pairs       = pairs

local lrucache = core.lrucache.new({
    type = "plugin",
})

local schema = {
    type = "object",
    description = "new headers for request",
    minProperties = 1,
    additionalProperties = false,
    properties = {
        add = {
            type = "object",
            minProperties = 1,
            patternProperties = {
                ["^[^:]+$"] = {
                    oneOf = {
                        { type = "string" },
                        { type = "number" }
                    }
                }
            },
        },
        set = {
            type = "object",
            minProperties = 1,
            patternProperties = {
                ["^[^:]+$"] = {
                    oneOf = {
                        { type = "string" },
                        { type = "number" },
                    }
                }
            },
        },
        remove = {
            type = "array",
            minItems = 1,
            items = {
                type = "string",
                -- "Referer"
                pattern = "^[^:]+$"
            }
        },
    },
}


local _M = {
    version  = 0.1,
    priority = 17420,
    name     = plugin_name,
    schema   = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


-- cache pairs processed data for subsequent JIT hit in calculations
local function create_header_operation(header_conf)
    local set = {}
    local add = {}

    if header_conf.add then
        for field, value in pairs(header_conf.add) do
            core.table.insert_tail(add, field, value)
        end
    end
    if header_conf.set then
        for field, value in pairs(header_conf.set) do
            core.table.insert_tail(set, field, value)
        end
    end

    return {
        add = add,
        set = set,
        remove = header_conf.remove or {},
    }
end

function _M.rewrite(conf, ctx)
    local header_op, err = core.lrucache.plugin_ctx(lrucache, ctx, nil,
                                create_header_operation, conf)
    if not header_op then
        core.log.error("failed to create header operation: ", err)
        return
    end

    local field_cnt = #header_op.add
    for i = 1, field_cnt, 2 do
        local val = core.utils.resolve_var(header_op.add[i + 1], ctx.var)
        local header = header_op.add[i]
        core.request.add_header(ctx, header, val)
    end

    local field_cnt = #header_op.set
    for i = 1, field_cnt, 2 do
        local val = core.utils.resolve_var(header_op.set[i + 1], ctx.var)
        core.request.set_header(ctx, header_op.set[i], val)
    end

    local field_cnt = #header_op.remove
    for i = 1, field_cnt do
        core.request.set_header(ctx, header_op.remove[i], nil)
    end

end


return _M