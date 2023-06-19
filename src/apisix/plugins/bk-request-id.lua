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

-- bk-request-id
--
-- Add x-bkapi-request-id and x-request-id to the request and response header,
-- 1. x-bkapi-request-id is unique for each request in bkapi, 36 bytes
--    e.g. X-Bkapi-Request-Id: f2dcff5b-2b42-4dbd-b008-8cca4a87a19c
-- 2. x-request-id, respect the request header(maybe not unique)
--    e.g. X-Request-Id: f2dcff5b2b424dbdb0088cca4a87a19c
--    in request: if the request header has x-request-id, use it
--                else, use the x-bkapi-request-id (remove the `-`, 32 bytes, easy to identify), as ctx.var.x_request_id
--    in response: if the response header has x-request-id, use it
--                else, use the ctx.var.x_request_id

-- NOTE: in some conditions, the x-request-id in response header is not the same as the one in request header
-- if the service be called set the response's x-request-id but not respect the request's x-request-id
-- the apigateway only log the request's x-request-id!!!!!!

local ngx = ngx
local core = require("apisix.core")
local uuid = require("resty.jit-uuid")

-- plugin config
local plugin_name = "bk-request-id"

local BKAPI_REQUEST_ID_HEADER = "X-Bkapi-Request-Id"
local X_REQUEST_ID_HEADER = "X-Request-Id"

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
    core.request.set_header(ctx, BKAPI_REQUEST_ID_HEADER, uuid_val)
    ctx.var.bk_request_id = uuid_val

    local headers = ngx.req.get_headers()
    if not headers[X_REQUEST_ID_HEADER] then
        -- remove the '-' in uuid, make it more easy to identify the x-bkapi-request-id and x-request-id
        local uuid_val_32 = string.gsub(uuid_val, "-", "")
        core.request.set_header(ctx, X_REQUEST_ID_HEADER, uuid_val_32)
        ctx.var.x_request_id = uuid_val_32
    else
        ctx.var.x_request_id = headers[X_REQUEST_ID_HEADER]
    end
end

function _M.header_filter(conf, ctx) -- luacheck: ignore
    -- x-bkapi-request-id
    core.response.set_header(BKAPI_REQUEST_ID_HEADER, ctx.var.bk_request_id)

    -- x-request-id, respect the response header
    local headers = ngx.resp.get_headers()
    if not headers[X_REQUEST_ID_HEADER] then
        core.response.set_header(X_REQUEST_ID_HEADER, ctx.var.x_request_id)
    end

end

return _M
