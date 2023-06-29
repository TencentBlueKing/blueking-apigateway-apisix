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

-- bk-proxy-rewrite
--
-- Rewrite the upstream, headers, uri, and method of a request using the plugin configuration.
-- Each route resource will use this plugin to rewrite upstream, headers, and request methods.
--
--     1. conf.uri used for rewriting the upstream uri.
--     2. conf.method used for rewriting the upstream method.
--     3. conf.host used for rewriting the upstream host.
--     4. conf.headers used for rewriting the request headers.
--     5. conf.use_real_request_uri_unsafe if true, use the original request uri, with a higher priority than conf.uri.
--     6. conf.match_subpath if true, match subpath of upstream uri.
--         if the upstream_uri ends with a slash and the original uri does not,
--         then remove the trailing slash from the upstream_uri.

-- 由 apisix 官方插件改造而来，uri支持路径参数替换
-- 该插件融合了蓝鲸网关对于路径变量和子路径匹配的特殊规则，不应当被手动配置，只允许被 Operator 配置
--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
local core = require("apisix.core")
local plugin_name = "bk-proxy-rewrite"
local pairs = pairs
local ipairs = ipairs
local ngx = ngx -- luacheck: ignore
local type = type
local sub_str = string.sub
local str_find = core.string.find
local str_byte = string.byte

local switch_map = {
    GET = ngx.HTTP_GET,
    POST = ngx.HTTP_POST,
    PUT = ngx.HTTP_PUT,
    HEAD = ngx.HTTP_HEAD,
    DELETE = ngx.HTTP_DELETE,
    OPTIONS = ngx.HTTP_OPTIONS,
    MKCOL = ngx.HTTP_MKCOL,
    COPY = ngx.HTTP_COPY,
    MOVE = ngx.HTTP_MOVE,
    PROPFIND = ngx.HTTP_PROPFIND,
    LOCK = ngx.HTTP_LOCK,
    UNLOCK = ngx.HTTP_UNLOCK,
    PATCH = ngx.HTTP_PATCH,
    TRACE = ngx.HTTP_TRACE,
}
local schema_method_enum = {}
for key in pairs(switch_map) do
    core.table.insert(schema_method_enum, key)
end

local schema = {
    type = "object",
    properties = {
        uri = {
            description = "new uri for upstream",
            type = "string",
            minLength = 1,
            maxLength = 4096,
            pattern = [[^\/.*]],
        },
        method = {
            description = "proxy route method",
            type = "string",
            enum = schema_method_enum,
        },
        host = {
            description = "new host for upstream",
            type = "string",
            pattern = [[^[0-9a-zA-Z-.]+(:\d{1,5})?$]],
        },
        -- deprecated: should not use `scheme`, apisix 3.2 remove it, so we will delete it later
        -- scheme = {
        --     description = "new scheme for upstream",
        --     type = "string",
        --     enum = {
        --         "http",
        --         "https",
        --     },
        -- },
        headers = {
            description = "new headers for request",
            type = "object",
            minProperties = 1,
        },
        use_real_request_uri_unsafe = {
            description = "use real_request_uri instead, THIS IS VERY UNSAFE.",
            type = "boolean",
            default = false,
        },
        match_subpath = {
            description = "whether `match subpath` is truned on",
            type = "boolean",
            default = false,
        },
        subpath_param_name = {
            description = "will use this param name for subpath appending in proxy rewrite, default is `:ext`",
            type = "string",
            default = ":ext",
        },
    },
    minProperties = 1,
}

local _M = {
    version = 0.1,
    priority = 17430,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return false, err
    end

    -- check headers
    if not conf.headers then
        return true
    end

    for field, value in pairs(conf.headers) do
        if type(field) ~= 'string' then
            return false, 'invalid type as header field'
        end

        if type(value) ~= 'string' and type(value) ~= 'number' then
            return false, 'invalid type as header value'
        end

        if #field == 0 then
            return false, 'invalid field length in header'
        end

        core.log.info("header field: ", field)

        if not core.utils.validate_header_field(field) then
            return false, 'invalid field character in header'
        end

        if not core.utils.validate_header_value(value) then
            return false, 'invalid value character in header'
        end
    end

    return true
end

local function check_ending_slash(conf, ctx, upstream_uri, arg_sign_index)
    local slash_str = str_byte("/")
    -- case 1: /origin-path -> /upstream-path   (后缀为空，末尾无/)
    -- case 2: /origin-path/ -> /upstream-path/ (后缀为空，末尾有/)
    -- case 3: /origin-path/subpaths -> /upstream-path/subpaths (后缀不为空)
    -- 当处于后缀匹配模式，且后缀为空的时候，处理源路径末尾不带/的情况，即 case 1
    if conf.match_subpath and conf.subpath_param_name and not ctx.curr_req_matched[conf.subpath_param_name] then
        local uri = ctx.var.uri
        -- 若源路径末尾不为/
        if str_byte(uri, #uri) ~= slash_str then
            -- 若upstream_uri含有参数，则判断?前一个字符是否为/，若是则去掉
            if arg_sign_index then
                if str_byte(upstream_uri, arg_sign_index-1, arg_sign_index-1) == slash_str then
                    return sub_str(upstream_uri, 1, arg_sign_index - 2) .. sub_str(upstream_uri, arg_sign_index)
                end
            -- 若upstream_uri不含有参数，判断最后一个字符是否为/，若是则去掉
            else
                if str_byte(upstream_uri, #upstream_uri) == slash_str then
                    return sub_str(upstream_uri, 1, #upstream_uri-1)
                end
            end
        end
    end
    return upstream_uri
end

do
    local upstream_vars = {
        host = "upstream_host",
        upgrade = "upstream_upgrade",
        connection = "upstream_connection",
    }
    local upstream_names = {}
    for name, _ in pairs(upstream_vars) do
        core.table.insert(upstream_names, name)
    end

    function _M.rewrite(conf, ctx)
        -- rewrite upstream host
        for _, name in ipairs(upstream_names) do
            if conf[name] then
                ctx.var[upstream_vars[name]] = conf[name]
            end
        end
        -- if conf["scheme"] then
        --     ctx.upstream_scheme = conf["scheme"]
        -- end

        -- rewrite upstream uri
        local upstream_uri = ctx.var.uri
        if conf.use_real_request_uri_unsafe then
            upstream_uri = ctx.var.real_request_uri
        elseif conf.uri ~= nil then
            upstream_uri = core.utils.resolve_var(conf.uri, ctx.curr_req_matched)
        end

        if not conf.use_real_request_uri_unsafe then
            local index = str_find(upstream_uri, "?")
            -- if the upstream_uri ends with a slash and the original uri does not,
            -- then remove the trailing slash from the upstream_uri.
            upstream_uri = check_ending_slash(conf, ctx, upstream_uri, index)

            -- concatenate the args in the upstream_uri with the args in the original uri
            if ctx.var.is_args == "?" then
                if index then
                    ctx.var.upstream_uri = upstream_uri .. "&" .. (ctx.var.args or "")
                else
                    ctx.var.upstream_uri = upstream_uri .. "?" .. (ctx.var.args or "")
                end
            else
                ctx.var.upstream_uri = upstream_uri
            end
        end

        -- rewrite headers
        if conf.headers then
            -- 把 conf.headers 放入 conf.headers_arr
            if not conf.headers_arr then
                conf.headers_arr = {}

                for field, value in pairs(conf.headers) do
                    core.table.insert_tail(conf.headers_arr, field, value)
                end
            end

            -- 统一处理  headers_arr
            local field_cnt = #conf.headers_arr
            for i = 1, field_cnt, 2 do
                core.request.set_header(
                    ctx, conf.headers_arr[i], core.utils.resolve_var(conf.headers_arr[i + 1], ctx.var)
                )
            end

            -- Q: 怎么处理的 set / delete
            -- Q: 怎么保证的顺序? set -> delete
        end

        -- rewrite method
        if conf.method then
            ngx.req.set_method(switch_map[conf.method])
        end
    end

end -- do

return _M
