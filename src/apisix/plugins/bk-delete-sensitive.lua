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

local pl_types = require("pl.types")
local core = require("apisix.core")
local bk_core = require("apisix.plugins.bk-core.init")
local ngx = ngx -- luacheck: ignore
local ipairs = ipairs

local plugin_name = "bk-delete-sensitive"

local BKAPI_AUTHORIZATION_HEADER = "X-Bkapi-Authorization"

local schema = {
    type = "object",
    properties = {},
}

local _M = {
    version = 0.1,
    priority = 17450,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

local function delete_sensitive_params(ctx, sensitive_keys, unfiltered_sensitive_keys)
    local include_sensitive_params = {}
    for _, key in ipairs(unfiltered_sensitive_keys) do
        include_sensitive_params[key] = true
    end

    local uri_args = core.request.get_uri_args(ctx)
    local json_body = bk_core.request.get_json_body()
    local form_data = bk_core.request.get_form_data(ctx)

    local check_query = not pl_types.is_empty(uri_args)
    local check_form = not pl_types.is_empty(form_data)
    local check_body = not pl_types.is_empty(json_body)

    local query_changed = false
    local form_changed = false
    local body_changed = false

    for _, key in ipairs(sensitive_keys) do
        if include_sensitive_params[key] then
            goto continue
        end

        if check_query and uri_args[key] ~= nil then
            uri_args[key] = nil
            query_changed = true
        end

        -- only when the content-type is application/x-www-form-urlencoded
        if check_form and form_data ~= nil and form_data[key] ~= nil then
            form_data[key] = nil
            form_changed = true
        end

        if check_body and json_body ~= nil and json_body[key] ~= nil then
            json_body[key] = nil
            body_changed = true
        end

        ::continue::
    end

    if check_query and query_changed then
        core.request.set_uri_args(ctx, uri_args)
    end

    if check_form and form_changed then
        bk_core.request.set_body_data(ctx, ngx.encode_args(form_data))
    end

    if check_body and body_changed then
        local new_body = core.json.encode(json_body)
        if new_body ~= nil then
            bk_core.request.set_body_data(ctx, new_body)
        end
    end
end

local function delete_sensitive_headers()
    ngx.req.clear_header("X-Request-Uri")
    ngx.req.clear_header(BKAPI_AUTHORIZATION_HEADER)
end

function _M.rewrite(conf, ctx) -- luacheck: no unused
    if ctx.var.bk_api_auth and ctx.var.bk_api_auth:is_filter_sensitive_params() then
        delete_sensitive_params(
            ctx, bk_core.config.get_sensitive_keys(), ctx.var.bk_api_auth:get_unfiltered_sensitive_keys()
        )
    end

    delete_sensitive_headers()
end

if _TEST then -- luacheck: ignore
    _M._delete_sensitive_params = delete_sensitive_params
    _M._delete_sensitive_headers = delete_sensitive_headers
end

return _M
