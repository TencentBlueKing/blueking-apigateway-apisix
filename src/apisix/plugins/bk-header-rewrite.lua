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

-- bk-header-rewrite
--
-- Rewrite the headers of a request using the plugin configuration.

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
local core        = require("apisix.core")
local plugin_name = "bk-header-rewrite"
local pairs       = pairs
local type        = type

local lrucache = core.lrucache.new({
    type = "plugin",
})

local schema = {
    type = "object",
    properties = {
        headers = {
            description = "new headers for request",
            oneOf = {
                {
                    type = "object",
                    minProperties = 1,
                    additionalProperties = false,
                    properties = {
                        add = {
                            type = "object",
                            patternProperties = {
                                ["^[^:]+$"] = {
                                    oneOf = {
                                        { type = "string" },
                                        { type = "number" }
                                    }
                                }
                            },
                        },
                        set = {
                            type = "object",
                            patternProperties = {
                                ["^[^:]+$"] = {
                                    oneOf = {
                                        { type = "string" },
                                        { type = "number" },
                                    }
                                }
                            },
                        },
                        remove = {
                            type = "array",
                            items = {
                                type = "string",
                                -- "Referer"
                                pattern = "^[^:]+$"
                            }
                        },
                    },
                },
                {
                    type = "object",
                    minProperties = 1,
                    patternProperties = {
                        ["^[^:]+$"] = {
                            oneOf = {
                                { type = "string" },
                                { type = "number" }
                            }
                        }
                    },
                }
            },

        },
    },
    minProperties = 1,
}


local _M = {
    version  = 0.1,
    priority = 17420,
    name     = plugin_name,
    schema   = schema,
}

local function is_new_headers_conf(headers)
    return (headers.add and type(headers.add) == "table") or
        (headers.set and type(headers.set) == "table") or
        (headers.remove and type(headers.remove) == "table")
end

local function check_set_headers(headers)
    for field, value in pairs(headers) do
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

function _M.check_schema(conf)
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return false, err
    end

    -- check headers
    if not conf.headers then
        return true
    end

    if conf.headers then
        if not is_new_headers_conf(conf.headers) then
            ok, err = check_set_headers(conf.headers)
            if not ok then
                return false, err
            end
        end
    end

    return true
end


do
    local function create_header_operation(hdr_conf)
        local set = {}
        local add = {}

        if is_new_headers_conf(hdr_conf) then
            if hdr_conf.add then
                for field, value in pairs(hdr_conf.add) do
                    core.table.insert_tail(add, field, value)
                end
            end
            if hdr_conf.set then
                for field, value in pairs(hdr_conf.set) do
                    core.table.insert_tail(set, field, value)
                end
            end

        else
            for field, value in pairs(hdr_conf) do
                core.table.insert_tail(set, field, value)
            end
        end

        return {
            add = add,
            set = set,
            remove = hdr_conf.remove or {},
        }
    end

function _M.rewrite(conf, ctx)
    if conf.headers then
        local hdr_op, err = core.lrucache.plugin_ctx(lrucache, ctx, nil,
                                    create_header_operation, conf.headers)
        if not hdr_op then
            core.log.error("failed to create header operation: ", err)
            return
        end

        local field_cnt = #hdr_op.add
        for i = 1, field_cnt, 2 do
            local val = core.utils.resolve_var(hdr_op.add[i + 1], ctx.var)
            local header = hdr_op.add[i]
            core.request.add_header(ctx, header, val)
        end

        local field_cnt = #hdr_op.set
        for i = 1, field_cnt, 2 do
            local val = core.utils.resolve_var(hdr_op.set[i + 1], ctx.var)
            core.request.set_header(ctx, hdr_op.set[i], val)
        end

        local field_cnt = #hdr_op.remove
        for i = 1, field_cnt do
            core.request.set_header(ctx, hdr_op.remove[i], nil)
        end

    end
end

end  -- do


return _M