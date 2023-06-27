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

-- # bk-debug
--
-- return debug info in response header if request header X-Bkapi-Debug is true
-- this plugin is a default plugin for all `stage` of bk-apigateway
-- so, we can get X-Bkapi-Debug-Info by `curl -H 'X-Bkapi-Debug: True'`


local core = require("apisix.core")
local pl_types = require("pl.types")

-- plugin config
local plugin_name = "bk-debug"
local BK_DEBUG_HEADER = "X-Bkapi-Debug"
local BK_DEBUG_INFO_HEADER = "X-Bkapi-Debug-Info"

local schema = {
    type = "object",
    properties = {},
}

local _M = {
    version = 0.1,
    priority = 145,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

---@param ctx apisix.Context
---@return table<string, any>
local function get_debug_info(ctx)
    return {
        bk_request_id = ctx.var.bk_request_id,
        x_request_id = ctx.var.x_request_id,
        bk_app_code = ctx.var.bk_app_code,
        bk_username = ctx.var.bk_username,
        instance_id = ctx.var.instance_id,
        client_ip = core.request.get_remote_client_ip(ctx),
        request_headers = core.request.headers(ctx),
    }
end

function _M.header_filter(conf, ctx) -- luacheck: no unused
    -- TODO: 99.999% got no BK_DEBUG_HEADER, should we check it first?
    if pl_types.to_bool(core.request.header(ctx, BK_DEBUG_HEADER)) then
        local debug_info = get_debug_info(ctx)
        core.response.set_header(BK_DEBUG_INFO_HEADER, core.json.encode(debug_info))
    end
end

if _TEST then -- luacheck: ignore
    _M._get_debug_info = get_debug_info
end

return _M
