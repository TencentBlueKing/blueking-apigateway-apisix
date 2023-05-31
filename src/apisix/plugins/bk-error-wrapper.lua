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
local errorx = require("apisix.plugins.bk-core.errorx")
local bk_upstream = require("apisix.plugins.bk-core.upstream")
local pl_types = require("pl.types")
local pl_stringx = require("pl.stringx")
local proxy_phases = require("apisix.plugins.bk-core.proxy_phases")

local ngx = ngx -- luacheck: ignore

-- plugin config
local plugin_name = "bk-error-wrapper"
local BK_ERROR_CODE_HEADER = "X-Bkapi-Error-Code"
local BK_ERROR_MESSAGE_HEADER = "X-Bkapi-Error-Message"
local CONTENT_TYPE_HEADER = "Content-Type"

local schema = {
    type = "object",
    properties = {},
}

---@type apisix.Plugin
local _M = {
    version = 0.1,
    priority = 0,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

---@param conf any
---@param ctx apisix.Context
function _M.before_proxy(conf, ctx)
    ctx.var.proxy_phase = proxy_phases.PROXYING
end

---@param ctx apisix.Context
---@return string,string|nil
local function _get_upstream_error_msg(ctx)
    --- 此处根据ngx upstream module的变量设置来确定upstream连接状态。连接状态配合status可以大致确认可能发生的问题。例如：
    --- - 502 + failed to connect to upstream一般代表后端端口未监听
    --- - 504 + failed to connect to upstream 一般代表握手超时，说明网络层面有丢包
    if not ctx.var.upstream_connect_time then -- 握手失败
        return proxy_phases.CONNECTING, "failed to connect to upstream"
        -- 此处删掉对$upstream_bytes_sent判断的原因是，在header_filter阶段，upstream_bytes_sent只生效与响应头读取失败的情况
        -- 响应头成功读取时，upstream_bytes_sent为0。这个预期外的行为导致无法根据upstream_bytes_sent来判断向后端发送请求数据
        -- 过程的异常。
        -- elseif not pl_types.to_bool(bk_upstream.get_last_upstream_bytes_sent()) then -- 握手成功，发送请求失败
        --     upstream_error_msg = "cannot send request to upstream"
    elseif not pl_types.to_bool(bk_upstream.get_last_upstream_bytes_received(ctx)) then -- 读取头失败
        return proxy_phases.HEADER_WAITING, "cannot read header from upstream"
    elseif not ctx.var.upstream_header_time then -- 读到了头，但未读完，可能是读头超时，可能是头格式不对
        return proxy_phases.HEAEDER_RECEIVING, "failed to read header from upstream"
    end

    return proxy_phases.FINISH
end

---@param conf any
---@param ctx apisix.Context
function _M.header_filter(conf, ctx) -- luacheck: no unused
    -- proxy error 表示网关请求后端服务出现错误，不包含后端服务正常响应但 status >= 500 的情况
    ctx.var.proxy_error = "0"

    -- upstream real reply does not process
    if ctx.var.bk_skip_error_wrapper then
        return
    end

    local proxy_phase, upstream_error_msg
    if ctx.var.upstream_status then
        proxy_phase, upstream_error_msg = _get_upstream_error_msg(ctx)
        ctx.var.proxy_phase = proxy_phase
        if proxy_phase == proxy_phases.FINISH then -- 后端正常响应
            return
        end

        ctx.var.proxy_error = "1"
    end

    -- apisix or openresty default error
    if not ctx.var.bk_apigw_error and ngx.status >= ngx.HTTP_BAD_REQUEST then
        local error = errorx.new_default_error_with_status(ngx.status)
        ctx.var.bk_apigw_error = error
    end

    local apigw_error = ctx.var.bk_apigw_error
    -- no error have to deal with
    if not apigw_error then
        return
    end

    if upstream_error_msg then
        apigw_error:with_field("upstream_error", upstream_error_msg)
    end

    -- for body filter
    core.response.clear_header_as_body_modified()
    -- set resp headers
    core.response.set_header(CONTENT_TYPE_HEADER, "application/json; charset=utf-8")
    core.response.set_header(BK_ERROR_CODE_HEADER, tostring(apigw_error.error.code))
    core.response.set_header(BK_ERROR_MESSAGE_HEADER, apigw_error.error.message)
end

--- func desc
---@param body string|nil
---@return string|nil error_msg nil represents no error_msg
local function extract_error_info_from_body(body)
    if pl_types.is_empty(body) then
        return nil
    end

    -- openresty default error message for non-200 status, for example
    -- <html>\r\n<head><title>404 Not Found<\/title>...
    if pl_stringx.startswith(body, "<html>") then
        return nil
    end

    -- apisix returned error message
    local json_format = core.json.decode(body)
    if type(json_format) == "table" then
        if json_format["error_msg"] then
            return json_format["error_msg"]

        elseif json_format["message"] then
            return json_format["message"]

        end
    end

    return body
end

function _M.body_filter(conf, ctx) -- luacheck: no unused
    local apigw_error = ctx.var.bk_apigw_error
    if not apigw_error then
        return
    end

    -- error occured
    -- NOTE: 请求头中不包含此错误消息，不符合预期:
    -- 但是，由于 header_filter 中无法获取 ngx.arg, body_filter 中无法 set response header，
    -- 因此，目前，暂无简便的方法使 response header 和 body 中均包含此错误消息
    -- body_filter 会被调用多次，使用 apisix 提供的方法刷入缓冲区，最后统一处理
    local resp_body = core.response.hold_body_chunk(ctx)
    if not resp_body then
        return
    end

    local extra_error_msg = extract_error_info_from_body(resp_body)
    if not pl_types.is_empty(extra_error_msg) then
        apigw_error:with_field("reason", extra_error_msg)
    end

    local ok, error_str = pcall(core.json.encode, apigw_error.error)
    if not ok then
        core.log.error("json encode apigateway error failed, error: " .. tostring(apigw_error))
        return
    end

    -- 方便记录错误响应到日志
    ctx.var.bk_apigw_error_response_body = error_str

    ngx.arg[1] = error_str
    ngx.arg[2] = true
end

if _TEST then
    _M._extract_error_info_from_body = extract_error_info_from_body
end

return _M
