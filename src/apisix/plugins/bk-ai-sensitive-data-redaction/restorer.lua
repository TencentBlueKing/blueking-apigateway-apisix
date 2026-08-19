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
local string_byte = string.byte
local string_find = string.find
local string_sub = string.sub
local table_concat = table.concat
local type = type

local _M = {}
local MAX_JSON_DEPTH = 128
local INVALID_JSON_ERROR = "invalid JSON"
local JSON_DEPTH_ERROR = "JSON nesting depth limit exceeded"
local JSON_LITERALS = {"true", "false", "null"}
local scan_json_text


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


local function find_token_candidate(value, namespace, search_from)
    while search_from <= #value do
        local start_pos = string_find(value, namespace, search_from, true)
        if not start_pos then
            return
        end

        local digit_pos = start_pos + #namespace
        local first_digit = string_byte(value, digit_pos)
        if first_digit and first_digit >= 49 and first_digit <= 57 then
            local end_pos = digit_pos + 1
            while true do
                local byte = string_byte(value, end_pos)
                if not byte or byte < 48 or byte > 57 then
                    break
                end
                end_pos = end_pos + 1
            end

            if string_sub(value, end_pos, end_pos + 1) == "__" then
                return start_pos, end_pos + 1,
                       string_sub(value, start_pos, end_pos + 1)
            end
        end

        search_from = start_pos + 1
    end
end


function _M.validate_mapping(namespace, body, replacements, max_entries, max_bytes)
    if type(replacements) ~= "table" or not is_dense_array(replacements) then
        return nil, "replacements must be an array"
    end

    if #replacements > max_entries then
        return nil, "mapping entry limit exceeded"
    end

    local raw_body = body
    if type(raw_body) ~= "string" then
        local encode_err
        raw_body, encode_err = core.json.encode(body)
        if not raw_body then
            return nil, "failed to encode masked body: " .. encode_err
        end
    end

    local mapping = {}
    local tokens = {}
    local bytes = 0
    local token_pattern = "^" .. namespace:gsub("([^%w])", "%%%1") .. "[1-9][0-9]*__$"
    for index, item in ipairs(replacements) do
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

        bytes = bytes + #item.placeholder + #item.original
        if bytes > max_bytes then
            return nil, "mapping byte limit exceeded"
        end

        mapping[item.placeholder] = item.original
        tokens[index] = item.placeholder
    end

    local present = {}
    local scanned, _, scan_err = scan_json_text(raw_body, mapping, namespace, 0, present)
    if not scanned then
        return nil, "failed to scan masked body: " .. scan_err
    end

    for _, token in ipairs(tokens) do
        if not present[token] then
            return nil, "placeholder is absent from masked body"
        end
    end

    return mapping
end


local function contains_known_token(value, mapping, namespace)
    local search_from = 1
    while true do
        local start_pos, end_pos, candidate = find_token_candidate(
            value, namespace, search_from
        )
        if not start_pos then
            return false
        end
        if mapping[candidate] ~= nil then
            return true
        end
        search_from = end_pos + 1
    end
end


local function restore_string(value, mapping, namespace, present)
    local out = {}
    local pos = 1
    local search_from = 1
    local count = 0
    while search_from <= #value do
        local start_pos, end_pos, candidate = find_token_candidate(
            value, namespace, search_from
        )
        if not start_pos then
            break
        end

        local original = mapping[candidate]
        if original ~= nil then
            if present then
                present[candidate] = true
            end
            out[#out + 1] = string_sub(value, pos, start_pos - 1)
            out[#out + 1] = original
            pos = end_pos + 1
            count = count + 1
        end
        search_from = end_pos + 1
    end

    if count == 0 then
        return value, 0
    end

    out[#out + 1] = string_sub(value, pos)
    return table_concat(out), count
end


local function append(scanner, value)
    scanner.output[#scanner.output + 1] = value
end


local function append_whitespace(scanner, pos)
    local start_pos = pos
    while pos <= scanner.length do
        local byte = string_byte(scanner.raw, pos)
        if byte ~= 32 and byte ~= 9 and byte ~= 10 and byte ~= 13 then
            break
        end
        pos = pos + 1
    end

    if pos > start_pos then
        append(scanner, string_sub(scanner.raw, start_pos, pos - 1))
    end

    return pos
end


local function hex_value(byte)
    if byte >= 48 and byte <= 57 then
        return byte - 48
    end
    if byte >= 65 and byte <= 70 then
        return byte - 55
    end
    if byte >= 97 and byte <= 102 then
        return byte - 87
    end
end


local function decode_hex_quad(raw, u_pos)
    local value = 0
    for offset = 1, 4 do
        local digit = hex_value(string_byte(raw, u_pos + offset) or 0)
        if not digit then
            return
        end
        value = value * 16 + digit
    end

    return value
end


local function valid_continuation(byte)
    return byte and byte >= 128 and byte <= 191
end


local function utf8_sequence_length(raw, pos)
    local first = string_byte(raw, pos)
    local second = string_byte(raw, pos + 1)
    if first >= 194 and first <= 223 then
        if valid_continuation(second) then
            return 2
        end
        return
    end

    local third = string_byte(raw, pos + 2)
    if first == 224 then
        if second and second >= 160 and second <= 191
                and valid_continuation(third) then
            return 3
        end
        return
    end
    if (first >= 225 and first <= 236) or (first >= 238 and first <= 239) then
        if valid_continuation(second) and valid_continuation(third) then
            return 3
        end
        return
    end
    if first == 237 then
        if second and second >= 128 and second <= 159
                and valid_continuation(third) then
            return 3
        end
        return
    end

    local fourth = string_byte(raw, pos + 3)
    if first == 240 then
        if second and second >= 144 and second <= 191
                and valid_continuation(third) and valid_continuation(fourth) then
            return 4
        end
        return
    end
    if first >= 241 and first <= 243 then
        if valid_continuation(second) and valid_continuation(third)
                and valid_continuation(fourth) then
            return 4
        end
        return
    end
    if first == 244 and second and second >= 128 and second <= 143
            and valid_continuation(third) and valid_continuation(fourth) then
        return 4
    end
end


local function find_string_end(raw, start_pos)
    local pos = start_pos + 1
    while pos <= #raw do
        local byte = string_byte(raw, pos)
        if byte == 34 then
            return pos
        end
        if byte < 32 then
            return nil
        end
        if byte == 92 then
            pos = pos + 1
            local escaped = string_byte(raw, pos)
            if not escaped then
                return nil
            end
            if escaped == 117 then
                local code_unit = decode_hex_quad(raw, pos)
                if not code_unit then
                    return nil
                end
                if code_unit >= 0xD800 and code_unit <= 0xDBFF then
                    if string_byte(raw, pos + 5) ~= 92
                            or string_byte(raw, pos + 6) ~= 117 then
                        return nil
                    end
                    local low_surrogate = decode_hex_quad(raw, pos + 6)
                    if not low_surrogate
                            or low_surrogate < 0xDC00 or low_surrogate > 0xDFFF then
                        return nil
                    end
                    pos = pos + 10

                elseif code_unit >= 0xDC00 and code_unit <= 0xDFFF then
                    return nil

                else
                    pos = pos + 4
                end

            elseif escaped ~= 34 and escaped ~= 47 and escaped ~= 92
                    and escaped ~= 98 and escaped ~= 102 and escaped ~= 110
                    and escaped ~= 114 and escaped ~= 116 then
                return nil
            end

        elseif byte >= 128 then
            local sequence_length = utf8_sequence_length(raw, pos)
            if not sequence_length then
                return nil
            end
            pos = pos + sequence_length - 1
        end
        pos = pos + 1
    end

    return nil
end


local function parse_string(scanner, pos, is_key, depth)
    local end_pos = find_string_end(scanner.raw, pos)
    if not end_pos then
        return nil, INVALID_JSON_ERROR
    end

    local raw_string = string_sub(scanner.raw, pos, end_pos)
    if is_key then
        append(scanner, raw_string)
        return end_pos + 1, 0
    end

    local decoded = core.json.decode(raw_string)
    if type(decoded) ~= "string" then
        return nil, INVALID_JSON_ERROR
    end
    if not contains_known_token(decoded, scanner.mapping, scanner.namespace) then
        append(scanner, raw_string)
        return end_pos + 1, 0
    end

    local first_non_space = decoded:match("^%s*(.)")
    if first_non_space == "{" or first_non_space == "[" then
        local embedded, embedded_count, embedded_err = scan_json_text(
            decoded, scanner.mapping, scanner.namespace, depth + 1, scanner.present
        )
        if embedded then
            if embedded_count == 0 then
                append(scanner, raw_string)
                return end_pos + 1, 0
            end

            local encoded = core.json.encode(embedded)
            if not encoded then
                return nil, INVALID_JSON_ERROR
            end
            append(scanner, encoded)
            return end_pos + 1, embedded_count
        end
        if embedded_err == JSON_DEPTH_ERROR then
            return nil, embedded_err
        end
    end

    local restored, count = restore_string(
        decoded, scanner.mapping, scanner.namespace, scanner.present
    )
    if count == 0 then
        append(scanner, raw_string)
        return end_pos + 1, 0
    end

    local encoded = core.json.encode(restored)
    if not encoded then
        return nil, INVALID_JSON_ERROR
    end
    append(scanner, encoded)
    return end_pos + 1, count
end


local function parse_number(scanner, pos)
    local start_pos = pos
    if string_byte(scanner.raw, pos) == 45 then
        pos = pos + 1
    end

    local byte = string_byte(scanner.raw, pos)
    if byte == 48 then
        pos = pos + 1

    elseif byte and byte >= 49 and byte <= 57 then
        repeat
            pos = pos + 1
            byte = string_byte(scanner.raw, pos)
        until not byte or byte < 48 or byte > 57

    else
        return nil, INVALID_JSON_ERROR
    end

    if string_byte(scanner.raw, pos) == 46 then
        pos = pos + 1
        byte = string_byte(scanner.raw, pos)
        if not byte or byte < 48 or byte > 57 then
            return nil, INVALID_JSON_ERROR
        end
        repeat
            pos = pos + 1
            byte = string_byte(scanner.raw, pos)
        until not byte or byte < 48 or byte > 57
    end

    byte = string_byte(scanner.raw, pos)
    if byte == 69 or byte == 101 then
        pos = pos + 1
        byte = string_byte(scanner.raw, pos)
        if byte == 43 or byte == 45 then
            pos = pos + 1
        end
        byte = string_byte(scanner.raw, pos)
        if not byte or byte < 48 or byte > 57 then
            return nil, INVALID_JSON_ERROR
        end
        repeat
            pos = pos + 1
            byte = string_byte(scanner.raw, pos)
        until not byte or byte < 48 or byte > 57
    end

    append(scanner, string_sub(scanner.raw, start_pos, pos - 1))
    return pos, 0
end


local parse_value

local function parse_array(scanner, pos, depth)
    if depth >= MAX_JSON_DEPTH then
        return nil, JSON_DEPTH_ERROR
    end

    append(scanner, "[")
    pos = append_whitespace(scanner, pos + 1)
    if string_byte(scanner.raw, pos) == 93 then
        append(scanner, "]")
        return pos + 1, 0
    end

    local count = 0
    while true do
        local next_pos, count_or_err = parse_value(scanner, pos, depth + 1)
        if not next_pos then
            return nil, count_or_err
        end
        pos = next_pos
        count = count + count_or_err
        pos = append_whitespace(scanner, pos)

        local byte = string_byte(scanner.raw, pos)
        if byte == 93 then
            append(scanner, "]")
            return pos + 1, count
        end
        if byte ~= 44 then
            return nil, INVALID_JSON_ERROR
        end
        append(scanner, ",")
        pos = append_whitespace(scanner, pos + 1)
    end
end


local function parse_object(scanner, pos, depth)
    if depth >= MAX_JSON_DEPTH then
        return nil, JSON_DEPTH_ERROR
    end

    append(scanner, "{")
    pos = append_whitespace(scanner, pos + 1)
    if string_byte(scanner.raw, pos) == 125 then
        append(scanner, "}")
        return pos + 1, 0
    end

    local count = 0
    while true do
        if string_byte(scanner.raw, pos) ~= 34 then
            return nil, INVALID_JSON_ERROR
        end
        local next_pos, count_or_err = parse_string(scanner, pos, true, depth)
        if not next_pos then
            return nil, count_or_err
        end
        pos = next_pos
        pos = append_whitespace(scanner, pos)
        if string_byte(scanner.raw, pos) ~= 58 then
            return nil, INVALID_JSON_ERROR
        end
        append(scanner, ":")
        pos = append_whitespace(scanner, pos + 1)

        next_pos, count_or_err = parse_value(scanner, pos, depth + 1)
        if not next_pos then
            return nil, count_or_err
        end
        pos = next_pos
        count = count + count_or_err
        pos = append_whitespace(scanner, pos)

        local byte = string_byte(scanner.raw, pos)
        if byte == 125 then
            append(scanner, "}")
            return pos + 1, count
        end
        if byte ~= 44 then
            return nil, INVALID_JSON_ERROR
        end
        append(scanner, ",")
        pos = append_whitespace(scanner, pos + 1)
    end
end


parse_value = function(scanner, pos, depth)
    pos = append_whitespace(scanner, pos)
    local byte = string_byte(scanner.raw, pos)
    if byte == 123 then
        return parse_object(scanner, pos, depth)
    end
    if byte == 91 then
        return parse_array(scanner, pos, depth)
    end
    if byte == 34 then
        local next_pos, count_or_err = parse_string(scanner, pos, false, depth)
        if not next_pos then
            return nil, count_or_err
        end
        return next_pos, count_or_err
    end
    if byte == 45 or (byte and byte >= 48 and byte <= 57) then
        local next_pos, count_or_err = parse_number(scanner, pos)
        if not next_pos then
            return nil, count_or_err
        end
        return next_pos, count_or_err
    end

    for _, literal in ipairs(JSON_LITERALS) do
        if string_sub(scanner.raw, pos, pos + #literal - 1) == literal then
            append(scanner, literal)
            return pos + #literal, 0
        end
    end

    return nil, INVALID_JSON_ERROR
end


scan_json_text = function(raw_json, mapping, namespace, initial_depth, present)
    local scanner = {
        raw = raw_json,
        length = #raw_json,
        mapping = mapping,
        namespace = namespace,
        present = present,
        output = {},
    }
    local pos, count_or_err = parse_value(scanner, 1, initial_depth or 0)
    if not pos then
        return nil, nil, count_or_err
    end

    pos = append_whitespace(scanner, pos)
    if pos <= scanner.length then
        return nil, nil, INVALID_JSON_ERROR
    end

    return table_concat(scanner.output), count_or_err
end


function _M.restore_json_text(raw_json, mapping, namespace)
    if type(raw_json) ~= "string" or type(mapping) ~= "table"
            or type(namespace) ~= "string" or namespace == "" then
        return nil, INVALID_JSON_ERROR
    end

    local restored, count, err = scan_json_text(raw_json, mapping, namespace, 0)
    if not restored then
        return nil, err
    end

    return restored, count
end


local StreamRestorer = {}
StreamRestorer.__index = StreamRestorer


local function is_known_token_prefix(restorer, value)
    local node = restorer.token_prefix_trie
    for index = 1, #value do
        node = node[string_byte(value, index)]
        if not node then
            return false
        end
    end

    return not node.complete
end


local function find_pending_length(restorer, candidate)
    if not restorer.has_tokens then
        return 0
    end

    local last_complete_end = 0
    local search_from = 1
    while true do
        local start_pos, end_pos, token = find_token_candidate(
            candidate, restorer.namespace, search_from
        )
        if not start_pos then
            break
        end
        if restorer.mapping[token] ~= nil then
            last_complete_end = end_pos
        end
        search_from = end_pos + 1
    end

    local namespace_start
    search_from = last_complete_end + 1
    while true do
        local start_pos = string_find(candidate, restorer.namespace, search_from, true)
        if not start_pos then
            break
        end
        namespace_start = start_pos
        search_from = start_pos + 1
    end
    if namespace_start then
        local suffix = string_sub(candidate, namespace_start)
        if is_known_token_prefix(restorer, suffix) then
            return #suffix
        end
    end

    local first_possible = math_max(
        last_complete_end + 1, #candidate - #restorer.namespace + 2, 1
    )
    for start_pos = first_possible, #candidate do
        local suffix = string_sub(candidate, start_pos)
        if string_sub(restorer.namespace, 1, #suffix) == suffix then
            return #suffix
        end
    end

    return 0
end


local function restore_incremental(restorer, candidate, mode, final)
    local pending = ""
    if not final and #candidate > 0 then
        local pending_length = find_pending_length(restorer, candidate)
        if pending_length > 0 then
            pending = string_sub(candidate, -pending_length)
            candidate = string_sub(candidate, 1, #candidate - pending_length)
        end
    end

    local mapping = restorer.mapping
    if mode == "json_fragment" then
        mapping = restorer.json_fragment_mapping
    end

    local output, count = restore_string(candidate, mapping, restorer.namespace)
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
    local token_prefix_trie = {}
    local has_tokens = false

    for token, original in pairs(mapping) do
        if type(token) == "string" and type(original) == "string"
                and token:match(token_pattern) then
            stream_mapping[token] = original

            local encoded_original = core.json.encode(original)
            json_fragment_mapping[token] = string_sub(encoded_original, 2, -2)

            local node = token_prefix_trie
            for index = 1, #token do
                local byte = string_byte(token, index)
                node[byte] = node[byte] or {}
                node = node[byte]
            end
            node.complete = true
            has_tokens = true
        end
    end

    return setmetatable(
        {
            mapping = stream_mapping,
            json_fragment_mapping = json_fragment_mapping,
            namespace = namespace,
            token_prefix_trie = token_prefix_trie,
            has_tokens = has_tokens,
            states = {},
        },
        StreamRestorer
    )
end


return _M
