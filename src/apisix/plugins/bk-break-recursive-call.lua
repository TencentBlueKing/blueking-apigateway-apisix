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

-- bk-break-recursive-call
--
-- Retrieve the previously called instance_id through apigateway from the request header.
-- If the current instance_id already exists in the header, return a recursive call error.
-- If it does not exist, add the current instance_id to the header.

local core = require("apisix.core")
local errorx = require("apisix.plugins.bk-core.errorx")
local pl_types = require("pl.types")
local string_split = require("pl.stringx").split
local table_insert = table.insert
local table_concat = table.concat

-- plugin config
local plugin_name = "bk-break-recursive-call"
local BKAPI_INSTANCE_ID_HEADER = "X-Bkapi-Instance-Id"
local INSTANCE_ID_FALLBACK = "bkapi"

local schema = {
    type = "object",
    properties = {},
}

local _M = {
    version = 0.1,
    priority = 17700,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.rewrite(conf, ctx) -- luacheck: no unused
    local current_instance_id = ctx.var.instance_id or INSTANCE_ID_FALLBACK
    local instance_id_in_header = core.request.header(ctx, BKAPI_INSTANCE_ID_HEADER)

    -- no X-Bkapi-Instance-Id header
    if pl_types.is_empty(instance_id_in_header) then
        core.request.set_header(ctx, BKAPI_INSTANCE_ID_HEADER, current_instance_id)
        return
    end

    -- X-Bkapi-Instance-Id allow multiple value: 'instance_id_1,instance_id_2,instance_id_3'
    local instance_ids = string_split(instance_id_in_header, ",")
    if core.table.array_find(instance_ids, current_instance_id) then
        return errorx.exit_with_apigw_err(ctx, errorx.new_recursive_request_detected(), _M)
    end

    table_insert(instance_ids, current_instance_id)
    core.request.set_header(ctx, BKAPI_INSTANCE_ID_HEADER, table_concat(instance_ids, ","))
end

return _M
