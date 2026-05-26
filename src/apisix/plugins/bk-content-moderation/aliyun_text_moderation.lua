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

local ngx = ngx
local pairs = pairs
local table_insert = table.insert
local table_sort = table.sort
local table_concat = table.concat
local string_gsub = string.gsub
local string_byte = string.byte
local string_sub = string.sub
local os_date = os.date
local url = require("socket.url")
local core = require("apisix.core")
local http = require("resty.http")
local uuid = require("resty.jit-uuid")

local _M = {}


-- Find a safe UTF-8 split position at or before `pos` in `str`.
-- Avoids cutting in the middle of a multi-byte UTF-8 character.
local function utf8_safe_split(str, pos)
    if pos >= #str then
        return #str
    end

    local b = string_byte(str, pos + 1)
    if not b or b < 0x80 or b >= 0xC0 then
        return pos
    end

    while pos > 0 do
        b = string_byte(str, pos)
        if b < 0x80 or b >= 0xC0 then
            return pos - 1
        end
        pos = pos - 1
    end
    return pos
end


local RISK_LEVELS = {
    ["max"] = 4,
    ["high"] = 3,
    ["medium"] = 2,
    ["low"] = 1,
    ["none"] = 0,
}


function _M.risk_level_to_int(risk_level)
    return RISK_LEVELS[risk_level] or -1
end


-- Aliyun requires stricter RFC 3986 sub-delimiter encoding than
-- OpenResty's ngx.escape_uri provides.
local SUB_DELIMS_RFC3986 = {
    ["!"] = "%%21",
    ["'"] = "%%27",
    ["%("] = "%%28",
    ["%)"] = "%%29",
    ["*"] = "%%2A",
}


function _M.url_encoding(raw_str)
    local encoded_str = ngx.escape_uri(raw_str)
    for k, v in pairs(SUB_DELIMS_RFC3986) do
        encoded_str = string_gsub(encoded_str, k, v)
    end
    return encoded_str
end


function _M.calculate_sign(params, secret)
    local params_arr = {}
    for k, v in pairs(params) do
        table_insert(
            params_arr,
            ngx.escape_uri(k) .. "=" .. _M.url_encoding(v)
        )
    end
    table_sort(params_arr)
    local canonical_str = table_concat(params_arr, "&")
    local str_to_sign = "POST&%2F&" .. ngx.escape_uri(canonical_str)
    return ngx.encode_base64(ngx.hmac_sha1(secret, str_to_sign))
end


function _M.check_single_content(conf, session_id, content, service_name)
    local timestamp = os_date("!%Y-%m-%dT%TZ")
    local random_id = uuid.generate_v4()
    local params = {
        ["AccessKeyId"] = conf.access_key_id,
        ["Action"] = "TextModerationPlus",
        ["Format"] = "JSON",
        ["RegionId"] = conf.region_id,
        ["Service"] = service_name,
        ["ServiceParameters"] = core.json.encode({
            sessionId = session_id,
            content = content,
        }),
        ["SignatureMethod"] = "HMAC-SHA1",
        ["SignatureNonce"] = random_id,
        ["SignatureVersion"] = "1.0",
        ["Timestamp"] = timestamp,
        ["Version"] = "2022-03-02",
    }
    params["Signature"] = _M.calculate_sign(
        params, conf.access_key_secret .. "&"
    )

    local httpc = http.new()
    httpc:set_timeout(conf.timeout or 5000)

    local parsed_url = url.parse(conf.endpoint)
    local ok, err = httpc:connect({
        scheme = parsed_url and parsed_url.scheme or "https",
        host = parsed_url and parsed_url.host,
        port = parsed_url and parsed_url.port,
        ssl_verify = conf.ssl_verify,
        ssl_server_name = parsed_url and parsed_url.host,
        pool_size = conf.keepalive and conf.keepalive_pool or 30,
    })
    if not ok then
        return nil, "failed to connect to moderation API: " .. err
    end

    local body = ngx.encode_args(params)
    local res, req_err = httpc:request({
        method = "POST",
        body = body,
        path = "/",
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
        },
    })
    if not res then
        return nil, "failed to request moderation API: " .. req_err
    end

    local raw_body, read_err = res:read_body()
    if not raw_body then
        return nil, "failed to read moderation response: " .. read_err
    end

    if conf.keepalive then
        local ka_ok, ka_err = httpc:set_keepalive(
            conf.keepalive_timeout or 60000,
            conf.keepalive_pool or 30
        )
        if not ka_ok then
            core.log.warn(
                "failed to keepalive moderation connection: ", ka_err
            )
        end
    end

    if res.status ~= 200 then
        return nil, "moderation API returned status "
            .. res.status .. ", body: " .. raw_body
    end

    local response, decode_err = core.json.decode(raw_body)
    if not response then
        return nil, "failed to decode moderation response: " .. decode_err
    end

    local risk_level = response.Data and response.Data.RiskLevel
    if not risk_level then
        return nil, "missing risk level in response: " .. raw_body
    end

    local advice = response.Data.Advice
        and response.Data.Advice[1]
        and response.Data.Advice[1].Answer

    if _M.risk_level_to_int(risk_level)
        < _M.risk_level_to_int(conf.risk_level_bar or "high") then
        return false, nil, risk_level
    end

    return true, advice, risk_level
end


function _M.check_content(
    conf, session_id, content, length_limit, service_name
)
    if not content or #content == 0 then
        return false, nil, "none"
    end

    if not session_id then
        session_id = uuid.generate_v4()
    end

    if #content <= length_limit then
        return _M.check_single_content(
            conf, session_id, content, service_name
        )
    end

    local index = 1
    local content_len = #content
    while index <= content_len do
        local end_pos = utf8_safe_split(content, index + length_limit - 1)
        local segment = string_sub(content, index, end_pos)
        local hit, advice, risk_level = _M.check_single_content(
            conf, session_id, segment, service_name
        )
        if hit then
            return true, advice, risk_level
        end

        if hit == nil and advice then
            core.log.error("content moderation check failed: ", advice)
        end
        index = end_pos + 1
    end

    return false, nil, "none"
end


if _TEST then
    _M._RISK_LEVELS = RISK_LEVELS
    _M._SUB_DELIMS_RFC3986 = SUB_DELIMS_RFC3986
    _M._utf8_safe_split = utf8_safe_split
end

return _M
