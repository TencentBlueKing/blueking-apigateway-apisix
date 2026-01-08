--
-- TencentBlueKing is pleased to support the open source community by making
-- 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
-- Copyright (C) 2025 Tencent. All rights reserved.
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

-- # bk-error-wrapper
--
-- this plugin is used to wrap error response from upstream
-- it will check the upstream status and the innner bk_apigw_error, and then
-- wrap the error response to a standard format
-- upstream error: only in `header_filter`, will wrap and add some headers(do nothing to the body)
-- apigw error: in `header_filter` and `body_filter`, will wrap and add some headers, will change the body

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


---get the upstream phase and error message by checking the `ctx.var.upstream_*_time`
---you can know the error detail by check the status_code + error_message
---like:
---  - 502 + failed to connect to upstream: the upstream port is not listened
---  - 504 + failed to connect to upstream: the upstream port is listened, but the handshake timeout
---    usually network problem
---  - 502 + cannot read header from upstream: upstream prematurely closed connection while reading
---    response header from upstream
---  - 504 + cannot read header from upstream: upstream timed out (110: Connection timed out)
---    while reading response header from upstream
---@param ctx apisix.Context
---@return string,string|nil @the specific phase and error message
local function _get_upstream_error_msg(ctx)
    -- Get the error log message from nginx variable
    local ngx_status = ngx.status

    if ngx_status >= 500 and ngx_status <= 599 then
        local upstream_connect_time = ctx.var.upstream_connect_time or 0
        local upstream_header_time = ctx.var.upstream_header_time or 0
        local upstream_response_time = ctx.var.upstream_response_time or 0
        local upstream_bytes_sent = bk_upstream.get_last_upstream_bytes_sent(ctx)
        local upstream_bytes_received = bk_upstream.get_last_upstream_bytes_received(ctx)

        if ngx_status == 502 then
            if upstream_connect_time == 0 then
                if upstream_bytes_sent == 0 then
                    -- connect() failed (111: Connection refused) while connecting to upstream
                    return proxy_phases.CONNECTING, "connection refused"
                end
            else
                -- upstream_connect_time is ok, connected
                if upstream_bytes_sent > 0 and upstream_bytes_received == 0 then
                    -- readv() failed (104: Connection reset by peer) while reading upstream
                    -- recv() failed (104: Connection reset by peer) while reading response header from upstream
                    -- upstream prematurely closed connection while reading upstream
                    -- upstream prematurely closed connection while reading response header from upstream
                    return proxy_phases.HEADER_WAITING,
                        "connection reset by peer OR upstream prematurely closed connection"
                end

            end
        end

        if ngx_status == 504 then
            if upstream_bytes_sent == 0 then
                return proxy_phases.CONNECTING, "connection timed out while connecting to upstream"
            end
            if upstream_bytes_sent > 0 and upstream_bytes_received == 0 then
                return proxy_phases.HEADER_WAITING,
                    "connection timed out while reading response header from upstream OR reading upstream"
            end
        end

        core.log.warn(
            "not catch upstream error: ",
            "[ngx_status: " .. tostring(ngx_status) .. "] ",
            "[upstream_connect_time: " .. tostring(upstream_connect_time) .. "] ",
            "[upstream_header_time: " .. tostring(upstream_header_time) .. "] ",
            "[upstream_response_time: " .. tostring(upstream_response_time) .. "] ",
            "[upstream_bytes_sent: " .. tostring(upstream_bytes_sent) .. "] ",
            "[upstream_bytes_received: " .. tostring(upstream_bytes_received) .. "]"
        )

    end

    -- the legacy logical
    if not ctx.var.upstream_connect_time then -- 握手失败
        return proxy_phases.CONNECTING, "failed to connect to upstream"
    -- note: 此处删掉对$upstream_bytes_sent判断的原因是
    -- 在header_filter阶段，upstream_bytes_sent只生效与响应头读取失败的情况响应头成功读取时,
    -- upstream_bytes_sent为0。这个预期外的行为导致无法根据upstream_bytes_sent来判断向后端发送请求数据过程的异常。
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
    -- if not ctx.var.upstream_status, means from apisix internal or the plugin return

    -- 2024-10-10 封装导致非蓝鲸插件例如 fault-injection 返回非 200 时 response body 被吞掉
    -- 注释掉之后
    -- 1. 插件返回的非 200 不会存在 ctx.var.bk_apigw_error
    -- 2. apisix 和 openresty 默认错误不会被封装, 将返回原始 body

    -- apisix or openresty default error
    -- or it's other plugin return non-200 status
    -- if not ctx.var.bk_apigw_error and ngx.status >= ngx.HTTP_BAD_REQUEST then
    --     -- wrap and generate a bk_apigw_error
    --     local error = errorx.new_default_error_with_status(ngx.status)
    --     -- after set this, the body_filter will be called
    --     ctx.var.bk_apigw_error = error
    -- end

    -- upstream status 报错封装成网关的报错
    if upstream_error_msg then
        if not ctx.var.bk_apigw_error and ngx.status >= ngx.HTTP_BAD_REQUEST then
            -- wrap and generate a bk_apigw_error
            local error = errorx.new_default_error_with_status(ngx.status)
            -- after set this, the body_filter will be called
            ctx.var.bk_apigw_error = error
        end
    end

    local apigw_error = ctx.var.bk_apigw_error
    -- do nothing if no error have to deal with
    if not apigw_error then
        return
    end

    -- append the upstream error message
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

---Parse the response body and extract error message
---from `.error_msg` or `.message` field of response json body, if not found, return the body itself
---if an openresty default error message is found, return nil
---@param body string|nil
---@return string|nil error_msg nil represents no error_msg
local function extract_error_info_from_body(body)
    if pl_types.is_empty(body) then
        return nil
    end
    -- FIXME: should use the raw body as error message?

    -- openresty default error message for non-200 status, for example
    -- <html>\r\n<head><title>404 Not Found<\/title>...
    if pl_stringx.startswith(body, "<html>") then
        -- TODO: 此时这种类型的错误不会有任何信息被注入到 bk_apigw_error, 那么是否意味着错误信息被吞掉了?
        -- will be ignored
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


---Phase body_filter, it's for bk_apigw_error only, will extract the error and make a new response
---@param conf table @apisix plugin configuration
---@param ctx table @apisix context
function _M.body_filter(conf, ctx) -- luacheck: no unused

    local apigw_error = ctx.var.bk_apigw_error
    -- note: only for bk_apigw_error
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

    -- for logging
    ctx.var.bk_apigw_error_response_body = error_str

    -- change the response
    ngx.arg[1] = error_str
    ngx.arg[2] = true
end

if _TEST then
    _M._get_upstream_error_msg = _get_upstream_error_msg
    _M._extract_error_info_from_body = extract_error_info_from_body
end

return _M
