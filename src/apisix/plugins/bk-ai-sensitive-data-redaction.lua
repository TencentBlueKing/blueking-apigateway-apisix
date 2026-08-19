--
-- TencentBlueKing is pleased to support the open source community by making
-- 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
-- Copyright (C) Tencent. All rights reserved.
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
local http = require("resty.http")
local protocols = require("apisix.plugins.ai-protocols")
local restorer = require("apisix.plugins.bk-ai-sensitive-data-redaction.restorer")
local sse_restorer = require("apisix.plugins.bk-ai-sensitive-data-redaction.sse")
local secret = require("apisix.secret")
local url = require("socket.url")
local uuid = require("resty.jit-uuid")
local getmetatable = getmetatable
local math_min = math.min
local pairs = pairs
local pcall = pcall
local setmetatable = setmetatable
local string_byte = string.byte
local string_lower = string.lower
local table_concat = table.concat
local tonumber = tonumber
local tostring = tostring
local type = type

local UUID_PATTERN =
    [[^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-]] ..
    [[[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z]]

local SUPPORTED_STREAM_PROTOCOLS = {
    ["openai-chat"] = true,
    ["openai-responses"] = true,
    ["anthropic-messages"] = true,
}

local FORBIDDEN_AUTH_HEADERS = {
    ["connection"] = true,
    ["content-length"] = true,
    ["content-type"] = true,
    ["host"] = true,
    ["keep-alive"] = true,
    ["proxy-authenticate"] = true,
    ["proxy-authorization"] = true,
    ["te"] = true,
    ["trailer"] = true,
    ["trailers"] = true,
    ["transfer-encoding"] = true,
    ["upgrade"] = true,
}

-- A response contains the masked body plus replacement strings. Any decoded JSON byte can
-- occupy at most six wire bytes as a \u00XX escape. The fixed compact envelope is 27 bytes,
-- and each mapping entry adds at most 33 structural bytes including its separator:
--   27 + 6*max_request_body_bytes + 6*max_mapping_bytes + 33*max_mapping_entries
-- The hard ceiling keeps a misconfigured limit from permitting an unbounded worker buffer.
local MAX_RESPONSE_WIRE_BYTES = 64 * 1024 * 1024
local MAX_RESPONSE_READ_BYTES = 8192
local RESPONSE_ENVELOPE_BYTES = 27
local JSON_ESCAPE_MULTIPLIER = 6
local MAPPING_ENTRY_STRUCTURE_BYTES = 33

local schema = {
    type = "object",
    properties = {
        endpoint = {
            type = "string",
            pattern = [[^https?://]],
            minLength = 1,
        },
        auth_header = {
            type = "string",
            default = "Authorization",
            minLength = 1,
        },
        auth_value = {
            type = "string",
            minLength = 1,
        },
        session_id_header = {
            type = "string",
            default = "X-AI-Session-Id",
            minLength = 1,
        },
        timeout = {
            type = "integer",
            minimum = 1,
            maximum = 60000,
            default = 3000,
        },
        ssl_verify = {
            type = "boolean",
            default = true,
        },
        keepalive = {
            type = "boolean",
            default = true,
        },
        keepalive_pool = {
            type = "integer",
            minimum = 1,
            default = 30,
        },
        keepalive_timeout = {
            type = "integer",
            minimum = 1000,
            default = 60000,
        },
        max_request_body_bytes = {
            type = "integer",
            minimum = 1,
            default = 1048576,
        },
        max_mapping_entries = {
            type = "integer",
            minimum = 1,
            default = 1000,
        },
        max_mapping_bytes = {
            type = "integer",
            minimum = 1,
            default = 1048576,
        },
    },
    encrypt_fields = {"auth_value"},
    required = {"endpoint"},
}

local _M = {
    version = 0.1,
    priority = 1039,
    name = "bk-ai-sensitive-data-redaction",
    schema = schema,
}


local function parse_endpoint(endpoint)
    if type(endpoint) ~= "string" or endpoint:find("[%c%s]") then
        return nil, "endpoint must be an absolute HTTP or HTTPS URL"
    end

    local parsed = url.parse(endpoint)
    if type(parsed) ~= "table"
            or (parsed.scheme ~= "http" and parsed.scheme ~= "https")
            or type(parsed.host) ~= "string"
            or parsed.host == ""
            or parsed.host:find("[%c%s]") then
        return nil, "endpoint must be an absolute HTTP or HTTPS URL"
    end

    return parsed
end


local function is_safe_auth_header(header_name)
    return type(header_name) == "string"
           and core.utils.validate_header_field(header_name)
           and not FORBIDDEN_AUTH_HEADERS[string_lower(header_name)]
end


local function is_safe_auth_value(value)
    if type(value) ~= "string" or value == "" then
        return false
    end

    for index = 1, #value do
        local byte = string_byte(value, index)
        if byte < 32 or byte == 127 then
            return false
        end
    end

    return true
end


local function has_safe_runtime_auth(conf)
    local header_name = conf.auth_header or "Authorization"
    if not is_safe_auth_header(header_name) then
        return false
    end

    if conf.auth_value == nil then
        return true
    end

    return not secret.is_secret_ref(conf.auth_value)
           and is_safe_auth_value(conf.auth_value)
end


function _M.check_schema(conf)
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return false, err
    end

    local _, endpoint_err = parse_endpoint(conf.endpoint)
    if endpoint_err then
        return false, endpoint_err
    end

    local auth_header = conf.auth_header or "Authorization"
    if not is_safe_auth_header(auth_header) then
        return false, "invalid auth_header"
    end

    if conf.auth_value ~= nil
            and not secret.is_secret_ref(conf.auth_value)
            and not is_safe_auth_value(conf.auth_value) then
        return false, "invalid auth_value"
    end

    local session_id_header = conf.session_id_header or "X-AI-Session-Id"
    if not core.utils.validate_header_field(session_id_header) then
        return false, "invalid session_id_header"
    end

    return true
end


local function is_uuid(value)
    if type(value) ~= "string" then
        return false
    end

    return ngx.re.match(value, UUID_PATTERN, "jo") ~= nil
end


local function resolve_request_id(ctx)
    if is_uuid(ctx.var.apisix_request_id) then
        return ctx.var.apisix_request_id
    end

    if is_uuid(ctx.var.bk_request_id) then
        return ctx.var.bk_request_id
    end

    return uuid.generate_v4()
end


local function resolve_session_id(conf, ctx)
    local header_name = conf.session_id_header or "X-AI-Session-Id"
    local session_id = core.request.header(ctx, header_name)
    if session_id == nil or session_id == "" then
        return nil
    end

    if not is_uuid(session_id) then
        return nil, "invalid AI session ID"
    end

    return session_id
end


local function namespace_for(request_id)
    return "__BK_REDACT_" .. request_id:gsub("-", ""):lower() .. "_"
end


local function body_status(err)
    local message = err
    if type(err) == "table" then
        message = err.message
    end

    if type(message) == "string"
            and message:find("greater than the maximum size", 1, true) then
        return 413
    end

    return 400
end


local function close_connection(httpc)
    local ok = pcall(httpc.close, httpc)
    if not ok then
        core.log.warn("failed to close redaction service connection")
    end
end


local function response_wire_limit(conf)
    local derived = RESPONSE_ENVELOPE_BYTES
                    + JSON_ESCAPE_MULTIPLIER * conf.max_request_body_bytes
                    + JSON_ESCAPE_MULTIPLIER * conf.max_mapping_bytes
                    + MAPPING_ENTRY_STRUCTURE_BYTES * conf.max_mapping_entries
    return math_min(derived, MAX_RESPONSE_WIRE_BYTES)
end


local function read_bounded_response(res, max_bytes)
    local headers = res.headers or {}
    local content_length = tonumber(
        headers["Content-Length"] or headers["content-length"]
    )
    if content_length and content_length > max_bytes then
        return nil, "redaction service response size limit exceeded"
    end

    if type(res.body_reader) ~= "function" then
        return nil, "redaction service read failed: response body is unavailable"
    end

    local chunks = {}
    local total = 0
    while true do
        local remaining = max_bytes - total
        -- Read one byte past the remaining allowance to detect overflow without
        -- letting lua-resty-http allocate an entire declared chunk or body.
        local read_size = math_min(MAX_RESPONSE_READ_BYTES, remaining + 1)
        local chunk, read_err = res.body_reader(read_size)
        if read_err then
            return nil, "redaction service read failed: " .. read_err
        end
        if chunk == nil then
            break
        end
        if type(chunk) ~= "string" then
            return nil, "redaction service read failed: invalid response chunk"
        end

        total = total + #chunk
        if total > max_bytes then
            return nil, "redaction service response size limit exceeded"
        end
        chunks[#chunks + 1] = chunk
    end

    return table_concat(chunks)
end


local function call_redaction_service(conf, request_id, session_id, namespace, body)
    local parsed, endpoint_err = parse_endpoint(conf.endpoint)
    if not parsed then
        return nil, endpoint_err
    end

    local httpc = http.new()
    httpc:set_timeout(conf.timeout)
    local connect_options = {
        scheme = parsed.scheme,
        host = parsed.host,
        port = parsed.port,
        ssl_verify = conf.ssl_verify,
        ssl_server_name = parsed.host,
    }
    if conf.keepalive then
        connect_options.pool_size = conf.keepalive_pool
    end

    local ok, err = httpc:connect(connect_options)
    if not ok then
        return nil, "redaction service connect failed: " .. (err or "unknown")
    end

    local payload = {
        request_id = request_id,
        placeholder_namespace = namespace,
        body = body,
    }
    if session_id then
        payload.session_id = session_id
    end

    local encoded_payload, encode_err = core.json.encode(payload)
    if not encoded_payload then
        close_connection(httpc)
        return nil, "failed to encode redaction request: " .. (encode_err or "unknown")
    end

    local headers = {
        ["Content-Type"] = "application/json",
    }
    if conf.auth_value then
        headers[conf.auth_header or "Authorization"] = conf.auth_value
    end

    local path = parsed.path
    if not path or path == "" then
        path = "/"
    end
    if parsed.query then
        path = path .. "?" .. parsed.query
    end

    local res, request_err = httpc:request({
        method = "POST",
        path = path,
        headers = headers,
        body = encoded_payload,
    })
    if not res then
        close_connection(httpc)
        return nil, "redaction service request failed: " .. (request_err or "unknown")
    end

    if res.status ~= 200 then
        close_connection(httpc)
        return nil, "redaction service returned status " .. tostring(res.status)
    end

    local raw, read_err = read_bounded_response(res, response_wire_limit(conf))
    if not raw then
        close_connection(httpc)
        return nil, read_err
    end

    if conf.keepalive then
        local kept = httpc:set_keepalive(conf.keepalive_timeout, conf.keepalive_pool)
        if not kept then
            close_connection(httpc)
            core.log.warn(
                "failed to keep redaction service connection alive, request_id: ",
                request_id
            )
        end
    else
        close_connection(httpc)
    end

    local decoded = core.json.decode(raw)
    if not decoded then
        return nil, "redaction service returned invalid JSON"
    end

    if type(decoded) ~= "table" or getmetatable(decoded) == core.json.array_mt then
        return nil, "redaction service response must be an object"
    end

    return decoded
end


local function validate_control_fields(ctx, original, masked)
    if type(masked) ~= "table" or getmetatable(masked) == core.json.array_mt then
        return "redaction service body must be an object"
    end

    local masked_protocol = protocols.detect(masked, ctx)
    if masked_protocol ~= ctx.ai_client_protocol then
        return "redaction service changed the AI protocol"
    end

    if masked.model ~= original.model then
        return "redaction service changed model"
    end

    if masked.stream ~= original.stream then
        return "redaction service changed stream"
    end
end


local function replace_table(target, source)
    for key in pairs(target) do
        target[key] = nil
    end
    for key, value in pairs(source) do
        target[key] = value
    end
    setmetatable(target, getmetatable(source))
end


local function clear_sensitive_state(ctx)
    ctx._ai_redaction_session_id = nil
    ctx._ai_redaction_namespace = nil
    ctx._ai_redaction_mapping = nil
    ctx._ai_redaction_sse_restorer = nil
end


local function ensure_stream_counts(ctx)
    if type(ctx._ai_redaction_restored_count) ~= "number" then
        ctx._ai_redaction_restored_count = 0
    end
    if type(ctx._ai_redaction_unresolved_count) ~= "number" then
        ctx._ai_redaction_unresolved_count = 0
    end
end


local function latch_stream_passthrough(ctx)
    if ctx._ai_redaction_stream_passthrough then
        return
    end

    ctx._ai_redaction_stream_passthrough = true
    clear_sensitive_state(ctx)
end


function _M.access(conf, ctx)
    if not ctx.picked_ai_instance or not ctx.ai_client_protocol then
        return 500,
               "bk-ai-sensitive-data-redaction must be used with ai-proxy or ai-proxy-multi"
    end

    if ctx.var.request_type == "ai_stream"
            and not SUPPORTED_STREAM_PROTOCOLS[ctx.ai_client_protocol] then
        return 400, "streaming protocol " .. ctx.ai_client_protocol ..
                    " is not supported for response restoration"
    end

    local body, body_err = core.request.get_json_request_body_table(
        conf.max_request_body_bytes
    )
    if not body then
        return body_status(body_err), body_err
    end

    local encoded_body, encode_err = core.json.encode(body)
    if not encoded_body then
        return 400, {message = "failed to encode request body: " .. (encode_err or "unknown")}
    end
    if #encoded_body > conf.max_request_body_bytes then
        return 413, {message = "request body is greater than the maximum size"}
    end

    local request_id = resolve_request_id(ctx)
    local session_id, session_err = resolve_session_id(conf, ctx)
    if session_err then
        return 400, session_err
    end

    if not has_safe_runtime_auth(conf) then
        return 500, "invalid redaction service authentication configuration"
    end

    local namespace = namespace_for(request_id)
    local result, redact_err = call_redaction_service(
        conf, request_id, session_id, namespace, body
    )
    if not result then
        return 502, {message = redact_err}
    end

    local control_err = validate_control_fields(ctx, body, result.body)
    if control_err then
        return 502, {message = control_err}
    end

    if type(result.replacements) ~= "table"
            or getmetatable(result.replacements) ~= core.json.array_mt then
        return 502, {message = "replacements must be a JSON array"}
    end

    local mapping, mapping_err = restorer.validate_mapping(
        namespace,
        result.body,
        result.replacements,
        conf.max_mapping_entries,
        conf.max_mapping_bytes
    )
    if not mapping then
        return 502, {message = mapping_err}
    end

    local masked_body, masked_encode_err = core.json.encode(result.body)
    if not masked_body then
        return 502, {
            message = "failed to encode masked body: " .. (masked_encode_err or "unknown"),
        }
    end
    if #masked_body > conf.max_request_body_bytes then
        return 502, {message = "masked body size limit exceeded"}
    end

    replace_table(body, result.body)
    ngx.req.set_body_data(masked_body)
    ctx._ai_redaction_request_id = request_id
    ctx._ai_redaction_session_id = session_id
    ctx._ai_redaction_namespace = namespace
    ctx._ai_redaction_mapping = mapping
    ctx.ai_request_body_changed = true
end


function _M.lua_body_filter(_, ctx, _, body, eof)
    if ctx.var.request_type == "ai_stream" then
        local chunk = body or ""
        ensure_stream_counts(ctx)
        if ctx._ai_redaction_stream_passthrough then
            return nil, chunk
        end

        if not ctx._ai_redaction_sse_restorer then
            local ok, processor = pcall(
                sse_restorer.new,
                ctx.ai_client_protocol,
                ctx._ai_redaction_mapping,
                ctx._ai_redaction_namespace
            )
            if not ok or type(processor) ~= "table"
                    or type(processor.feed) ~= "function" then
                core.log.error(
                    "failed to create SSE restorer",
                    ", request_id: ", ctx._ai_redaction_request_id
                )
                latch_stream_passthrough(ctx)
                return nil, chunk
            end
            ctx._ai_redaction_sse_restorer = processor
        end

        local processor = ctx._ai_redaction_sse_restorer
        local buffered = type(processor.remainder) == "string"
                         and processor.remainder or ""
        local ok, output, restored_count, unresolved_count = pcall(
            processor.feed, processor, chunk, eof == true
        )
        if not ok or type(output) ~= "string"
                or type(restored_count) ~= "number"
                or type(unresolved_count) ~= "number" then
            local prefix = buffered
            local fallback = processor.fail_closed
            if type(fallback) == "function" then
                local fallback_ok, fallback_output, fallback_unresolved = pcall(
                    fallback, processor, buffered
                )
                if fallback_ok and type(fallback_output) == "string" then
                    prefix = fallback_output
                    if type(fallback_unresolved) == "number" then
                        ctx._ai_redaction_unresolved_count =
                            ctx._ai_redaction_unresolved_count + fallback_unresolved
                    end
                end
            end

            core.log.error(
                "failed to restore masked SSE response",
                ", request_id: ", ctx._ai_redaction_request_id
            )
            latch_stream_passthrough(ctx)
            return nil, prefix .. chunk
        end

        ctx._ai_redaction_restored_count =
            ctx._ai_redaction_restored_count + restored_count
        ctx._ai_redaction_unresolved_count =
            ctx._ai_redaction_unresolved_count + unresolved_count

        if eof then
            clear_sensitive_state(ctx)
        end
        return nil, output
    end

    if ctx.var.request_type ~= "ai_chat" then
        return
    end

    local decoded, decode_err = core.json.decode(body)
    if not decoded then
        core.log.error(
            "failed to decode masked AI response: ", decode_err,
            ", request_id: ", ctx._ai_redaction_request_id
        )
        clear_sensitive_state(ctx)
        return
    end

    local restored, count = restorer.restore_json(decoded, ctx._ai_redaction_mapping)
    local encoded, encode_err = core.json.encode(restored)
    if not encoded then
        core.log.error(
            "failed to encode restored AI response: ", encode_err,
            ", request_id: ", ctx._ai_redaction_request_id
        )
        clear_sensitive_state(ctx)
        return
    end

    ctx._ai_redaction_restored_count = count
    clear_sensitive_state(ctx)
    return nil, encoded
end


return _M
