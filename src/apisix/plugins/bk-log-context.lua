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
local pl_types = require("pl.types")
local ngx = ngx
local string_sub = string.sub
local string_len = string.len

-- plugin config
local plugin_name = "bk-log-context"
local BODY_TOO_LARGE = "[Body Too Large]"
-- 当请求或响应超过这个长度会截断（会产生新的字符串）
local BODY_MAX_LENGTH = 1024

local schema = {
    type = "object",
    properties = {
        log_2xx_response_body = {
            type = "boolean",
        },
    },
}
local metadata_schema = core.table.deepcopy(schema)

---@type apisix.Plugin
local _M = {
    version = 0.1,
    priority = 18800,
    name = plugin_name,
    schema = schema,
    metadata = metadata_schema,
}

function _M.check_schema(conf, schema_type)
    if schema_type == core.schema.TYPE_METADATA then
        return core.schema.check(metadata_schema, conf)
    end

    return core.schema.check(schema, conf)
end

---@param conf table
---@param ctx apisix.Context
function _M.header_filter(conf, ctx)
    ctx.var._backend_part_response_body = ""

    local status = core.response.get_upstream_status(ctx)
    if ctx.var.bk_apigw_error then
        -- 如果 bk_apigw_error 存在，则插件 bk-error-wrapper 会将其内容写到
        -- ctx.var.bk_apigw_error_response_body，用于记录错误响应，而不需要读取当前的响应内容
        ctx.var.should_log_response_body = false
    elseif status == nil or status > 299 then
        -- status 为 nil，bk_apigw_error 为 nil：未处理的网关内部报错
        -- status > 299: 后端响应错误码非 20x
        -- always log response
        ctx.var.should_log_response_body = true
    else
        ctx.var.should_log_response_body = conf.log_2xx_response_body == true
    end

end

---@param conf table
---@param ctx apisix.Context
function _M.body_filter(conf, ctx)
    if not ctx.var.should_log_response_body then
        return
    end

    if not pl_types.is_empty(ctx.var._backend_part_response_body) then
        return
    end

    local response_body = ngx.arg[1]
    if not response_body then
        return
    elseif string_len(response_body) > BODY_MAX_LENGTH then
        ctx.var._backend_part_response_body = string_sub(response_body, 1, BODY_MAX_LENGTH)
    else
        ctx.var._backend_part_response_body = response_body
    end
end

core.ctx.register_var(
    "bk_log_request_timestamp", function(ctx)
        return math.floor(ngx.req.start_time())
    end
)

core.ctx.register_var(
    "bk_log_request_duration", function(ctx)
        return math.floor(ctx.var.request_time * 1000)
    end
)

core.ctx.register_var(
    "bk_log_upstream_duration", function(ctx)
        if not ctx.var.upstream_response_time then
            return 0
        end

        return ctx.var.upstream_response_time * 1000
    end
)

core.ctx.register_var(
    "bk_log_request_body", function(ctx)
        if ctx.var.request_body_file ~= nil then
            -- 请求体在文件中
            return BODY_TOO_LARGE
        end

        local request_body = ctx.var.request_body
        if not request_body then
            -- 客户端没有传递
            return ""
        elseif string_len(request_body) > BODY_MAX_LENGTH then
            -- 请求体在内存中且超长
            return string_sub(request_body, 1, BODY_MAX_LENGTH)
        else
            -- 请求体没有超长
            return request_body
        end

    end
)

core.ctx.register_var(
    "bk_log_response_body", function(ctx)
        if not pl_types.is_empty(ctx.var.bk_apigw_error_response_body) then
            return ctx.var.bk_apigw_error_response_body
        end

        return ctx.var._backend_part_response_body
    end
)

core.ctx.register_var(
    "bk_log_backend_path", function(ctx)
        return ctx.var.upstream_uri_without_args or ctx.var.upstream_uri or ""
    end
)

core.ctx.register_var(
    "bk_apigw_error_message", function(ctx)
        if ctx.var.bk_apigw_error then
            return ctx.var.bk_apigw_error.error.message
        end
        return ""
    end
)

core.ctx.register_var(
    "bk_apigw_error_code_name", function(ctx)
        if ctx.var.bk_apigw_error then
            return ctx.var.bk_apigw_error.error.code_name
        end
        return ""
    end
)

core.ctx.register_var(
    "bk_backend_host", function(ctx)
        -- bk-proxy-rewrite 插件之前，upstream_host 非后端服务地址
        if ctx.var.host == ctx.var.upstream_host then
            return ""
        end
        return ctx.var.upstream_host
    end
)

return _M
