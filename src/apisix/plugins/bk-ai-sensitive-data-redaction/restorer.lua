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
local ipairs = ipairs
local math_max = math.max
local pairs = pairs
local rawget = rawget
local setmetatable = setmetatable
local table_concat = table.concat
local type = type

local _M = {}


local function is_dense_array(value)
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return false
        end

        count = count + 1
    end

    for index = 1, count do
        if rawget(value, index) == nil then
            return false
        end
    end

    return true
end


function _M.validate_mapping(namespace, body, replacements, max_entries, max_bytes)
    if type(replacements) ~= "table" or not is_dense_array(replacements) then
        return nil, "replacements must be an array"
    end

    if #replacements > max_entries then
        return nil, "mapping entry limit exceeded"
    end

    local encoded_body, encode_err = core.json.encode(body)
    if not encoded_body then
        return nil, "failed to encode masked body: " .. encode_err
    end

    local mapping = {}
    local bytes = 0
    local token_pattern = "^" .. namespace:gsub("([^%w])", "%%%1") .. "[1-9][0-9]*__$"
    for _, item in ipairs(replacements) do
        if type(item) ~= "table" or type(item.placeholder) ~= "string"
                or type(item.original) ~= "string" then
            return nil, "invalid mapping entry"
        end

        if not item.placeholder:match(token_pattern) then
            return nil, "placeholder is outside request namespace"
        end

        if mapping[item.placeholder] ~= nil then
            return nil, "duplicate placeholder"
        end

        if not encoded_body:find(item.placeholder, 1, true) then
            return nil, "placeholder is absent from masked body"
        end

        bytes = bytes + #item.placeholder + #item.original
        if bytes > max_bytes then
            return nil, "mapping byte limit exceeded"
        end

        mapping[item.placeholder] = item.original
    end

    return mapping
end


local function contains_known_token(value, mapping)
    for token in pairs(mapping) do
        if value:find(token, 1, true) then
            return true
        end
    end

    return false
end


local function restore_string(value, mapping)
    local out = {}
    local pos = 1
    local count = 0
    while pos <= #value do
        local nearest_start
        local nearest_token
        for token in pairs(mapping) do
            local start_pos = value:find(token, pos, true)
            if start_pos and (not nearest_start or start_pos < nearest_start) then
                nearest_start = start_pos
                nearest_token = token
            end
        end

        if not nearest_start then
            out[#out + 1] = value:sub(pos)
            break
        end

        out[#out + 1] = value:sub(pos, nearest_start - 1)
        out[#out + 1] = mapping[nearest_token]
        count = count + 1
        pos = nearest_start + #nearest_token
    end

    return table_concat(out), count
end


local restore_value

restore_value = function(value, mapping)
    if type(value) == "table" then
        local count = 0
        for key, item in pairs(value) do
            local restored_item, restored_count = restore_value(item, mapping)
            value[key] = restored_item
            count = count + restored_count
        end

        return value, count
    end

    if type(value) ~= "string" or not contains_known_token(value, mapping) then
        return value, 0
    end

    local first_non_space = value:match("^%s*(.)")
    if first_non_space == "{" or first_non_space == "[" then
        local decoded = core.json.decode(value)
        if type(decoded) == "table" then
            local restored_decoded, count = restore_value(decoded, mapping)
            local encoded = core.json.encode(restored_decoded)
            if encoded then
                return encoded, count
            end
        end
    end

    return restore_string(value, mapping)
end


function _M.restore_json(value, mapping)
    return restore_value(value, mapping)
end


local StreamRestorer = {}
StreamRestorer.__index = StreamRestorer


local function find_pending_length(candidate, tokens, max_token_length)
    local last_complete_end = 0
    for _, token in ipairs(tokens) do
        local search_from = 1
        while search_from <= #candidate do
            local start_pos = candidate:find(token, search_from, true)
            if not start_pos then
                break
            end

            last_complete_end = math_max(last_complete_end, start_pos + #token - 1)
            search_from = start_pos + #token
        end
    end

    local first_possible = math_max(
        last_complete_end + 1, #candidate - max_token_length + 2, 1
    )
    for start_pos = first_possible, #candidate do
        local suffix = candidate:sub(start_pos)
        for _, token in ipairs(tokens) do
            if #suffix < #token and token:sub(1, #suffix) == suffix then
                return #suffix
            end
        end
    end

    return 0
end


local function restore_incremental(restorer, candidate, mode, final)
    local pending = ""
    if not final and #candidate > 0 then
        local pending_length = find_pending_length(
            candidate, restorer.tokens, restorer.max_token_length
        )
        if pending_length > 0 then
            pending = candidate:sub(-pending_length)
            candidate = candidate:sub(1, #candidate - pending_length)
        end
    end

    local mapping = restorer.mapping
    if mode == "json_fragment" then
        mapping = restorer.json_fragment_mapping
    end

    local output, count = restore_string(candidate, mapping)
    return output, pending, count
end


function StreamRestorer:feed(key, text, mode, final)
    local state = self.states[key] or {pending = ""}
    self.states[key] = state
    local candidate = state.pending .. (text or "")
    local output, pending, count = restore_incremental(self, candidate, mode, final)
    state.pending = pending
    if final then
        self.states[key] = nil
    end

    return output, count
end


function _M.new_stream(mapping, namespace)
    local token_pattern = "^" .. namespace:gsub("([^%w])", "%%%1") .. "[1-9][0-9]*__$"
    local stream_mapping = {}
    local json_fragment_mapping = {}
    local tokens = {}
    local max_token_length = 0

    for token, original in pairs(mapping) do
        if type(token) == "string" and type(original) == "string"
                and token:match(token_pattern) then
            stream_mapping[token] = original

            local encoded_original = core.json.encode(original)
            json_fragment_mapping[token] = encoded_original:sub(2, -2)

            tokens[#tokens + 1] = token
            max_token_length = math_max(max_token_length, #token)
        end
    end

    return setmetatable(
        {
            mapping = stream_mapping,
            json_fragment_mapping = json_fragment_mapping,
            tokens = tokens,
            max_token_length = max_token_length,
            states = {},
        },
        StreamRestorer
    )
end


return _M
