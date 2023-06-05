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

-- # bk-mock
--
-- support mock the response for an route, you can mock the status, body and headers of the response.
-- note: the plugin not re-use the official plugin mocking
-- because:
-- 1. the official plugin does not support response_headers
-- 2. the official plugin do `core.utils.resolve_var(response_content, ctx.var)` in access phase,
--    may cause sensitive information leakage

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
    -- should skip error wrapper, use the mocking response directly even the status code is 50x
    ctx.var.bk_skip_error_wrapper = true

    return conf.response_status, conf.response_example
end

function _M.header_filter(conf)
    if pl_types.is_empty(conf.response_headers) then
        return
    end

    for key, value in pairs(conf.response_headers) do
        -- set the header if it is not set by other plugins(they have higher priority)
        if not ngx.header[key] then
            core.response.set_header(key, value)
        end
    end
end

return _M
