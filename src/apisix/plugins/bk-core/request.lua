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
local multipart = require("multipart")
local string_split = require("pl.stringx").split
local pl_types = require("pl.types")

local ngx = ngx -- luacheck: ignore
local string_lower = string.lower

local PARSE_FORM_METHODS = {
    POST = true,
    PUT = true,
    PATCH = true,
}

local _M = {}

local function get_content_type(ctx)
    local content_type = core.request.header(ctx, "Content-Type")
    if content_type == nil or content_type == "" then
        return "application/octet-stream"
    end

    return content_type
end

local function is_urlencoded_form(ctx)
    local content_type = get_content_type(ctx)
    if core.string.find(string_lower(content_type), "application/x-www-form-urlencoded") then
        return true
    end
    return false
end

local function is_multipart_form(ctx)
    local content_type = get_content_type(ctx)
    if core.string.find(string_lower(content_type), "multipart/form-data") then
        return true
    end
    return false
end

local function should_check_form(method)
    if PARSE_FORM_METHODS[method] then
        return true
    end

    return false
end

function _M.parse_json_body()
    local body = core.request.get_body()
    if body and core.string.has_prefix(body, "{") then
        return core.json.decode(body)
    end

    return nil, "not a json body"
end

function _M.get_json_body(ctx)
    -- use ctx to cache

    if not ctx then
        ctx = ngx.ctx.api_ctx
    end

    if not ctx.req_json_body then
        ctx.req_json_body = _M.parse_json_body()

        -- 空值判断使用 nil，如果 ctx 中值为 nil，则缓存实际失效
        if ctx.req_json_body == nil then
            ctx.req_json_body = ngx.null
        end
    end

    if ctx.req_json_body == ngx.null then
        return nil
    end

    return ctx.req_json_body
end

function _M.parse_form(ctx)
    -- 1. POST/PUT/PATCH
    -- 2. content-type application/x-www-form-urlencoded 才会 check form
    if not should_check_form(ngx.req.get_method()) then
        return nil
    end

    if not is_urlencoded_form(ctx) then
        return nil
    end

    return core.request.get_post_args(ctx)
end

function _M.get_form_data(ctx)
    -- use ctx to cache

    if not ctx then
        ctx = ngx.ctx.api_ctx
    end

    if not ctx.req_form_data then
        ctx.req_form_data = _M.parse_form(ctx)

        -- 空值判断使用 nil，如果 ctx 中值为 nil，则缓存实际失效
        if ctx.req_form_data == nil then
            ctx.req_form_data = ngx.null
        end
    end

    if ctx.req_form_data == ngx.null then
        return nil
    end

    return ctx.req_form_data
end

function _M.parse_multipart_form(ctx)
    if not is_multipart_form(ctx) then
        return nil
    end

    local body = core.request.get_body()
    if body == nil or body == "" then
        return nil
    end

    local multipart_data = multipart(body, get_content_type(ctx))
    return multipart_data:get_all()
end

---@param ctx? apisix.Context
function _M.get_request_path(ctx)
    if not ctx then
        ctx = ngx.ctx.api_ctx
    end

    local path = core.request.header(nil, "X-Request-Uri")
    if not pl_types.is_empty(path) then
        return string_split(path, "?", 2)[1] or ""
    end

    return ctx.var.uri
end

function _M.set_body_data(ctx, body)
    if not ctx then
        ctx = ngx.ctx.api_ctx
    end

    ctx.req_post_args = nil
    ctx.req_json_body = nil
    ctx.req_form_data = nil

    return ngx.req.set_body_data(body)
end

if _TEST then -- luacheck: ignore
    _M._get_content_type = get_content_type
    _M._is_urlencoded_form = is_urlencoded_form
    _M._is_multipart_form = is_multipart_form
end

return _M
