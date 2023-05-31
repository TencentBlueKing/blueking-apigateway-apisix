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

-- 未使用官方 mocking 插件的原因
-- 1. 官方插件不支持 response_headers
-- 2. 官方插件 access 中 core.utils.resolve_var(response_content) 时，
--    未指定 ctx，响应内容中若包含 "$var_name"，将导致处理异常，
--    如果能解析 var，可能导致敏感信息泄露
local pl_types = require("pl.types")
local core = require("apisix.core")
local ngx = ngx
local pairs = pairs

local plugin_name = "bk-mock"

local schema = {
    type = "object",
    properties = {
        -- specify response status,default 200
        response_status = {
            type = "integer",
            default = 200,
            minimum = 100,
        },
        -- specify response body.
        response_example = {
            type = "string",
        },
        response_headers = {
            type = "object",
        },
    },
}

local _M = {
    version = 0.1,
    priority = 17150,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.access(conf, ctx)
    -- 此插件状态码为 502 时，
    ctx.var.bk_skip_error_wrapper = true

    return conf.response_status, conf.response_example
end

function _M.header_filter(conf)
    if pl_types.is_empty(conf.response_headers) then
        return
    end

    for key, value in pairs(conf.response_headers) do
        -- 如果响应头已被其它插件设置，则不能覆盖，插件中设置的头优先级更高
        if not ngx.header[key] then
            core.response.set_header(key, value)
        end
    end
end

return _M
