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

local core = require("apisix.core")
local uuid = require("resty.jit-uuid")

-- plugin config
local plugin_name = "bk-request-id"

local REQUEST_ID_HEADER = "X-Bkapi-Request-Id"

local schema = {
    type = "object",
    properties = {},
}

local _M = {
    version = 0.1,
    priority = 18850,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

local function get_request_id()
    return uuid.generate_v4()
end

function _M.rewrite(conf, ctx) -- luacheck: ignore
    local uuid_val = get_request_id()
    core.request.set_header(ctx, REQUEST_ID_HEADER, uuid_val)

    ctx.var.bk_request_id = uuid_val
end

function _M.header_filter(conf, ctx) -- luacheck: ignore
    core.response.set_header(REQUEST_ID_HEADER, ctx.var.bk_request_id)
end

return _M
