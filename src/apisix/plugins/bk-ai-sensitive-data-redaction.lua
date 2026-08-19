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
local url = require("socket.url")
local uuid = require("resty.jit-uuid")
local getmetatable = getmetatable
local pairs = pairs
local require = require
local setmetatable = setmetatable
local tostring = tostring
local type = type

-- Load the streaming response helper now; response restoration is wired in a later task.
require("apisix.plugins.bk-ai-sensitive-data-redaction.sse")

local UUID_PATTERN =
    [[^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-]] ..
    [[[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z]]

local SUPPORTED_STREAM_PROTOCOLS = {
    ["openai-chat"] = true,
    ["openai-responses"] = true,
    ["anthropic-messages"] = true,
}

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
    if not core.utils.validate_header_field(auth_header) then
        return false, "invalid auth_header"
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
    httpc:close()
end


local function call_redaction_service(conf, request_id, session_id, namespace, body)
    local parsed, endpoint_err = parse_endpoint(conf.endpoint)
    if not parsed then
        return nil, endpoint_err
    end

    local httpc = http.new()
    httpc:set_timeout(conf.timeout)
    local ok, err = httpc:connect({
        scheme = parsed.scheme,
        host = parsed.host,
        port = parsed.port,
        ssl_verify = conf.ssl_verify,
        ssl_server_name = parsed.host,
        pool_size = conf.keepalive and conf.keepalive_pool,
    })
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

    local raw, read_err = res:read_body()
    if not raw then
        close_connection(httpc)
        return nil, "redaction service read failed: " .. (read_err or "unknown")
    end

    if conf.keepalive then
        httpc:set_keepalive(conf.keepalive_timeout, conf.keepalive_pool)
    else
        close_connection(httpc)
    end

    if res.status ~= 200 then
        return nil, "redaction service returned status " .. tostring(res.status)
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

    replace_table(body, result.body)
    ngx.req.set_body_data(masked_body)
    ctx._ai_redaction_request_id = request_id
    ctx._ai_redaction_session_id = session_id
    ctx._ai_redaction_namespace = namespace
    ctx._ai_redaction_mapping = mapping
    ctx.ai_request_body_changed = true
end


return _M
