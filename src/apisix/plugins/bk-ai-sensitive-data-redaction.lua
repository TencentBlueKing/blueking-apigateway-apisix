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
local ipairs = ipairs
local math_min = math.min
local pcall = pcall
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

-- A response contains the masked raw JSON string plus replacement strings. Any raw body or
-- decoded mapping byte can occupy at most six wire bytes as a \u00XX escape. The fixed compact
-- envelope is 29 bytes,
-- and each mapping entry adds at most 33 structural bytes including its separator:
--   29 + 6*max_request_body_bytes + 6*max_mapping_bytes + 33*max_mapping_entries
-- The hard ceiling keeps a misconfigured limit from permitting an unbounded worker buffer.
local MAX_RESPONSE_WIRE_BYTES = 64 * 1024 * 1024
local MAX_RESPONSE_READ_BYTES = 8192
local MAX_RESPONSE_CHUNK_PARTS = 8192
local RESPONSE_ENVELOPE_BYTES = 29
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
    -- The same hard/config-derived ceiling bounds response restoration so a
    -- small masked payload cannot expand into an unbounded worker allocation.
    conf = conf or {}
    local derived = RESPONSE_ENVELOPE_BYTES
                    + JSON_ESCAPE_MULTIPLIER * (
                        conf.max_request_body_bytes
                        or schema.properties.max_request_body_bytes.default
                    )
                    + JSON_ESCAPE_MULTIPLIER * (
                        conf.max_mapping_bytes
                        or schema.properties.max_mapping_bytes.default
                    )
                    + MAPPING_ENTRY_STRUCTURE_BYTES * (
                        conf.max_mapping_entries
                        or schema.properties.max_mapping_entries.default
                    )
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
    local chunk_parts = {}
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
        chunk_parts[#chunk_parts + 1] = chunk
        if #chunk_parts >= MAX_RESPONSE_CHUNK_PARTS then
            chunks[#chunks + 1] = table_concat(chunk_parts)
            chunk_parts = {}
        end
    end

    if #chunk_parts > 0 then
        chunks[#chunks + 1] = table_concat(chunk_parts)
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
    local target_protocol = ctx.ai_target_protocol
    local protocol = protocols.get(target_protocol)
    local matches_target = protocol and protocol.matches(masked, ctx)
    if target_protocol == "vertex-predict" then
        matches_target = type(masked.instances) == "table"
                         and getmetatable(masked.instances) == core.json.array_mt
                         and #masked.instances > 0
        if matches_target then
            for _, instance in ipairs(masked.instances) do
                if type(instance) ~= "table"
                        or type(instance.content) ~= "string" then
                    matches_target = false
                    break
                end
            end
        end
    end
    if not matches_target then
        return "redaction service changed the AI protocol"
    end

    if masked.model ~= original.model then
        return "redaction service changed model"
    end

    if masked.stream ~= original.stream then
        return "redaction service changed stream"
    end
end


local function clear_attempt_state(ctx)
    ctx._ai_redaction_mapping = nil
    ctx._ai_redaction_sse_restorer = nil
    ctx._ai_redaction_stream_passthrough = nil
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
    ctx.var.llm_request_body = {}

    if not ctx.picked_ai_instance or not ctx.ai_client_protocol then
        return 500,
               "bk-ai-sensitive-data-redaction must be used with ai-proxy or ai-proxy-multi"
    end

    if ctx.var.request_type == "ai_stream"
            and not SUPPORTED_STREAM_PROTOCOLS[ctx.ai_client_protocol] then
        return 400, "streaming protocol " .. ctx.ai_client_protocol ..
                    " is not supported for response restoration"
    end

    local raw_body, body_err = core.request.get_body(conf.max_request_body_bytes, ctx)
    if not raw_body then
        return body_status(body_err), {message = body_err}
    end

    local request_id = resolve_request_id(ctx)
    local session_id, session_err = resolve_session_id(conf, ctx)
    if session_err then
        return 400, session_err
    end

    if not has_safe_runtime_auth(conf) then
        return 500, "invalid redaction service authentication configuration"
    end

    if ctx.ai_final_request_body_filter ~= nil then
        return 500, "AI final request body filter is already registered"
    end

    local namespace = namespace_for(request_id)
    ctx._ai_redaction_request_id = request_id
    ctx._ai_redaction_session_id = session_id
    ctx._ai_redaction_namespace = namespace
    ctx.ai_final_request_body_filter = function(final_raw_body)
        clear_attempt_state(ctx)
        ctx.var.llm_request_body = {}

        if type(final_raw_body) ~= "string" then
            return nil, {
                message = "final AI request body must be a JSON object string",
            }, 400
        end
        if #final_raw_body > conf.max_request_body_bytes then
            return nil, {message = "request body is greater than the maximum size"}, 413
        end

        local original = core.json.decode(final_raw_body)
        if not original then
            return nil, {message = "final AI request body must be valid JSON"}, 400
        end
        if type(original) ~= "table"
                or getmetatable(original) == core.json.array_mt then
            return nil, {
                message = "final AI request body must be a JSON object string",
            }, 400
        end

        local result, redact_err = call_redaction_service(
            conf, request_id, session_id, namespace, final_raw_body
        )
        if not result then
            return nil, {message = redact_err}, 502
        end

        if type(result.body) ~= "string" then
            return nil, {message = "redaction service body must be a raw JSON string"}, 502
        end
        if #result.body > conf.max_request_body_bytes then
            return nil, {message = "masked body size limit exceeded"}, 502
        end

        local masked = core.json.decode(result.body)
        if not masked then
            return nil, {message = "redaction service body must be valid JSON"}, 502
        end
        if type(masked) ~= "table"
                or getmetatable(masked) == core.json.array_mt then
            return nil, {message = "redaction service body must be an object"}, 502
        end

        local control_err = validate_control_fields(ctx, original, masked)
        if control_err then
            return nil, {message = control_err}, 502
        end

        if type(result.replacements) ~= "table"
                or getmetatable(result.replacements) ~= core.json.array_mt then
            return nil, {message = "replacements must be a JSON array"}, 502
        end

        local mapping, mapping_err = restorer.validate_mapping(
            namespace,
            result.body,
            result.replacements,
            conf.max_mapping_entries,
            conf.max_mapping_bytes,
            response_wire_limit(conf)
        )
        if not mapping then
            return nil, {message = mapping_err}, 502
        end

        local integrity_ok, integrity_err = restorer.verify_redaction(
            final_raw_body,
            result.body,
            mapping,
            namespace,
            response_wire_limit(conf)
        )
        if not integrity_ok then
            return nil, {message = integrity_err}, 502
        end

        ctx._ai_redaction_mapping = mapping
        return result.body
    end
end


function _M.lua_body_filter(conf, ctx, _, body, eof)
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
                ctx._ai_redaction_namespace,
                response_wire_limit(conf)
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

    local ok, restored, count = pcall(
        restorer.restore_json_text,
        body,
        ctx._ai_redaction_mapping,
        ctx._ai_redaction_namespace,
        response_wire_limit(conf)
    )
    if not ok or type(restored) ~= "string" or type(count) ~= "number" then
        core.log.error(
            "failed to restore masked AI response",
            ", request_id: ", ctx._ai_redaction_request_id
        )
        clear_sensitive_state(ctx)
        return
    end

    ctx._ai_redaction_restored_count = count
    clear_sensitive_state(ctx)
    return nil, restored
end


return _M
