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
-- bk-resource-header-rewrite
--
-- Rewrite the headers of a request using the plugin configuration.
-- Copy the logic from bk-stage-header-rewrite to avoid using the same LRU cache
-- which may result in incorrect configuration data.
-- If modifications are needed, both bk-stage-header-rewrite should be modified simultaneously.
local plugin = require("apisix.plugins.bk-stage-header-rewrite")
local core = require("apisix.core")
local pairs = pairs

local plugin_name = "bk-resource-header-rewrite"

local HEADER_REWRITE_CACHE_COUNT = 1000
local lrucache = core.lrucache.new({
    type = "plugin",
    count = HEADER_REWRITE_CACHE_COUNT
})

local _M = {
    version = 0.1,
    priority = 17420,
    name = plugin_name,
    schema = core.table.deepcopy(plugin.schema),
    check_schema = plugin.check_schema
}

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
        remove = header_conf.remove or {}
    }
end

function _M.rewrite(conf, ctx)
    local header_op, err = core.lrucache.plugin_ctx(lrucache, ctx, nil, create_header_operation, conf)
    if not header_op then
        core.log.error("failed to create header operation: ", err)
        return
    end

    local add_cnt = #header_op.add
    for i = 1, add_cnt, 2 do
        local val = core.utils.resolve_var(header_op.add[i + 1], ctx.var)
        local header = header_op.add[i]
        core.request.add_header(ctx, header, val)
    end

    local set_cnt = #header_op.set
    for i = 1, set_cnt, 2 do
        local val = core.utils.resolve_var(header_op.set[i + 1], ctx.var)
        core.request.set_header(ctx, header_op.set[i], val)
    end

    local remove_cnt = #header_op.remove
    for i = 1, remove_cnt do
        core.request.set_header(ctx, header_op.remove[i], nil)
    end

end

return _M
