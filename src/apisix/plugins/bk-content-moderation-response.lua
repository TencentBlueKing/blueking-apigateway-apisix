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

-- # bk-content-moderation-response
--
-- Response body content moderation companion plugin.
-- Intercepts the proxy process in the access phase (where cosocket works)
-- to enable blocking response moderation with streaming support.
-- Reads config from ctx._content_moderation_conf set by
-- bk-content-moderation plugin.
--
-- Pattern: similar to bk-mock, returns (status, body) from access()
-- to short-circuit APISIX proxy_pass.

local ngx = ngx
local pairs = pairs
local type = type
local core = require("apisix.core")
local errorx = require("apisix.plugins.bk-core.errorx")
local http = require("resty.http")
local uuid = require("resty.jit-uuid")
local aliyun = require(
    "apisix.plugins.bk-content-moderation.aliyun_text_moderation"
)

local plugin_name = "bk-content-moderation-response"

local CHUNK_SIZE = 8192

local schema = {
    type = "object",
    properties = {},
}

---@type apisix.Plugin
local _M = {
    version = 0.1,
    priority = 17100,
    name = plugin_name,
    schema = schema,
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end


local SKIP_HEADERS = {
    ["transfer-encoding"] = true,
    ["connection"] = true,
    ["keep-alive"] = true,
    ["proxy-authenticate"] = true,
    ["proxy-authorization"] = true,
    ["te"] = true,
    ["trailers"] = true,
    ["upgrade"] = true,
}


local function copy_response_headers(res_headers)
    for k, v in pairs(res_headers) do
        local lower_k = k:lower()
        if not SKIP_HEADERS[lower_k] then
            ngx.header[k] = v
        end
    end
end


local function is_streaming_response(res)
    local ct = res.headers["Content-Type"] or ""
    if ct:find("text/event%-stream") then
        return true
    end

    local te = res.headers["Transfer-Encoding"] or ""
    if te:find("chunked") and not ct:find("application/json") then
        return true
    end

    return false
end


local function build_upstream_url(ctx)
    local upstream = ctx.matched_upstream
    if not upstream then
        return nil, "no matched upstream in context"
    end

    local nodes = upstream.nodes
    if not nodes then
        return nil, "no upstream nodes configured"
    end

    local node
    if type(nodes) == "table" then
        if nodes[1] then
            node = nodes[1]
        else
            local host_port = next(nodes)
            if host_port then
                local h, p = host_port:match("^(.+):(%d+)$")
                if h then
                    node = { host = h, port = tonumber(p) }
                end
            end
        end
    end

    if not node then
        return nil, "failed to resolve upstream node"
    end

    local host = node.host
    local port = node.port or 80
    local scheme = upstream.scheme or "http"

    local upstream_host = ctx.var.upstream_host or host
    local upstream_uri = ctx.var.upstream_uri
        or ctx.var.uri
        or "/"

    return {
        scheme = scheme,
        host = host,
        port = port,
        upstream_host = upstream_host,
        uri = upstream_uri,
    }
end


local function forward_request(upstream_info, conf)
    local httpc = http.new()
    httpc:set_timeout(conf.upstream_timeout or 60000)

    local ok, err = httpc:connect({
        scheme = upstream_info.scheme,
        host = upstream_info.host,
        port = upstream_info.port,
    })
    if not ok then
        return nil, "failed to connect to upstream: " .. err
    end

    ngx.req.read_body()
    local req_body = ngx.req.get_body_data()

    local req_headers = ngx.req.get_headers(0, true)
    req_headers["Host"] = upstream_info.upstream_host

    local res, req_err = httpc:request({
        method = ngx.req.get_method(),
        path = upstream_info.uri,
        headers = req_headers,
        body = req_body,
    })
    if not res then
        return nil, "failed to request upstream: " .. req_err
    end

    return res, nil, httpc
end


local function handle_non_streaming(ctx, conf, res, httpc)
    local body, err = res:read_body()
    if not body then
        return nil, "failed to read upstream response: " .. (err or "")
    end

    if httpc and conf.keepalive then
        httpc:set_keepalive(
            conf.keepalive_timeout or 60000,
            conf.keepalive_pool or 30
        )
    end

    local session_id = ctx._content_moderation_session_id
        or uuid.generate_v4()

    local hit, advice, risk_level = aliyun.check_content(
        conf,
        session_id,
        body,
        conf.response_check_length_limit,
        conf.response_check_service
    )

    if hit then
        core.log.warn(
            "response content moderation hit, ",
            "risk_level: ", risk_level, ", ",
            "advice: ", advice or ""
        )
        local apigw_err = errorx.new_content_blocked_by_moderation()
        apigw_err:with_field("direction", "response")
        if advice then
            apigw_err:with_field("advice", advice)
        end
        return errorx.exit_with_apigw_err(ctx, apigw_err, _M)

    elseif hit == nil and advice then
        core.log.error(
            "response content moderation failed: ", advice
        )
    end

    ctx.var.bk_skip_error_wrapper = true
    ngx.status = res.status
    copy_response_headers(res.headers)
    ngx.print(body)

    return res.status
end


local function handle_streaming_realtime(ctx, conf, res)
    local session_id = ctx._content_moderation_session_id
        or uuid.generate_v4()

    ctx.var.bk_skip_error_wrapper = true
    ngx.status = res.status
    copy_response_headers(res.headers)
    ngx.header["X-Content-Moderation"] = "realtime"

    local reader = res.body_reader
    if not reader then
        core.log.error("upstream response has no body_reader")
        return res.status
    end

    local cache = ""
    local last_check_time = ngx.now()

    while true do
        local chunk, err = reader(CHUNK_SIZE)
        if err then
            core.log.error("error reading upstream chunk: ", err)
            break
        end

        if not chunk then
            break
        end

        ngx.print(chunk)
        ngx.flush(true)

        cache = cache .. chunk

        local now = ngx.now()
        local should_check =
            (#cache >= conf.stream_check_cache_size)
            or (now - last_check_time >= conf.stream_check_interval)

        if should_check then
            last_check_time = now
            local hit, advice, risk_level = aliyun.check_content(
                conf,
                session_id,
                cache,
                conf.response_check_length_limit,
                conf.response_check_service
            )

            if hit then
                core.log.warn(
                    "streaming response moderation hit, ",
                    "risk_level: ", risk_level, ", ",
                    "advice: ", advice or ""
                )
                local error_msg = advice
                    or "Content blocked by moderation policy"
                ngx.print(
                    '\n{"error":"' .. error_msg .. '",'
                    .. '"risk_level":"' .. (risk_level or "unknown")
                    .. '"}\n'
                )
                ngx.flush(true)
                break

            elseif hit == nil and advice then
                core.log.error(
                    "streaming moderation check failed: ",
                    advice
                )
            end

            cache = ""
        end
    end

    if #cache > 0 then
        local hit, advice, risk_level = aliyun.check_content(
            conf,
            session_id,
            cache,
            conf.response_check_length_limit,
            conf.response_check_service
        )
        if hit then
            core.log.warn(
                "final streaming moderation hit, ",
                "risk_level: ", risk_level, ", ",
                "advice: ", advice or ""
            )
            local error_msg = advice
                or "Content blocked by moderation policy"
            ngx.print(
                '\n{"error":"' .. error_msg .. '",'
                .. '"risk_level":"' .. (risk_level or "unknown")
                .. '"}\n'
            )
            ngx.flush(true)

        elseif hit == nil and advice then
            core.log.error(
                "final streaming moderation failed: ", advice
            )
        end
    end

    return res.status
end


local function handle_streaming_final_packet(ctx, conf, res, httpc)
    local body, err = res:read_body()
    if not body then
        return nil, "failed to read streaming response: " .. (err or "")
    end

    if httpc and conf.keepalive then
        httpc:set_keepalive(
            conf.keepalive_timeout or 60000,
            conf.keepalive_pool or 30
        )
    end

    local session_id = ctx._content_moderation_session_id
        or uuid.generate_v4()

    local hit, advice, risk_level = aliyun.check_content(
        conf,
        session_id,
        body,
        conf.response_check_length_limit,
        conf.response_check_service
    )

    if hit then
        core.log.warn(
            "response content moderation hit (final_packet), ",
            "risk_level: ", risk_level, ", ",
            "advice: ", advice or ""
        )
        local apigw_err = errorx.new_content_blocked_by_moderation()
        apigw_err:with_field("direction", "response")
        if advice then
            apigw_err:with_field("advice", advice)
        end
        return errorx.exit_with_apigw_err(ctx, apigw_err, _M)

    elseif hit == nil and advice then
        core.log.error(
            "response moderation failed (final_packet): ", advice
        )
    end

    ctx.var.bk_skip_error_wrapper = true
    ngx.status = res.status
    copy_response_headers(res.headers)
    ngx.print(body)

    return res.status
end


---@param conf table
---@param ctx apisix.Context
function _M.access(conf, ctx) -- luacheck: no unused
    local moderation_conf = ctx._content_moderation_conf
    if not moderation_conf then
        return
    end

    if not moderation_conf.check_response then
        return
    end

    local upstream_info, err = build_upstream_url(ctx)
    if not upstream_info then
        core.log.error(
            "content moderation response: ", err
        )
        return
    end

    local res, forward_err, httpc = forward_request(
        upstream_info, moderation_conf
    )
    if not res then
        core.log.error(
            "content moderation response forward failed: ",
            forward_err
        )
        local apigw_err = errorx.new_content_blocked_by_moderation()
        apigw_err:with_field("upstream_error", forward_err)
        return errorx.exit_with_apigw_err(ctx, apigw_err, _M)
    end

    local streaming = is_streaming_response(res)

    if not streaming
        or moderation_conf.stream_check_mode == "final_packet" then
        if streaming then
            return handle_streaming_final_packet(
                ctx, moderation_conf, res, httpc
            )
        end
        return handle_non_streaming(
            ctx, moderation_conf, res, httpc
        )
    end

    return handle_streaming_realtime(ctx, moderation_conf, res)
end


if _TEST then
    _M._build_upstream_url = build_upstream_url
    _M._is_streaming_response = is_streaming_response
    _M._copy_response_headers = copy_response_headers
    _M._forward_request = forward_request
end

return _M
