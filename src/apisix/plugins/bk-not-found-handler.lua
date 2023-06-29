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

-- bk-not-found-handler (special)
--
-- Rewriting the request returns api not found error.
-- To match the /* route in the virtual stage with a priority of -100,
-- and return a 404 error when none of the routes can be matched

-- 该插件应用于 operator 创建的根路由，所有路由到该路由的请求均应视为404
-- 为了避免覆盖边缘网关可能创建的根路由，operator 会将默认根路由优先级设为 -1
local core = require("apisix.core")
local errorx = require("apisix.plugins.bk-core.errorx")

-- plugin config
local plugin_name = "bk-not-found-handler"

local schema = {
    type = "object",
    properties = {},
}

local _M = {
    version = 0.1,
    priority = 18860,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.rewrite(conf, ctx) -- luacheck: ignore
    local err = errorx.new_api_not_found():with_fields(
        {
            method = ctx.var.request_method,
            path = ctx.var.uri,
        }
    )
    return errorx.exit_with_apigw_err(ctx, err)
end

return _M
