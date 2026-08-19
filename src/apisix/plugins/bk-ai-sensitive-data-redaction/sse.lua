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
local restorer = require("apisix.plugins.bk-ai-sensitive-data-redaction.restorer")
local sse_codec = require("apisix.plugins.ai-transport.sse")
local error = error
local ipairs = ipairs
local pairs = pairs
local pcall = pcall
local setmetatable = setmetatable
local table_concat = table.concat
local table_remove = table.remove
local tostring = tostring
local type = type

local _M = {}

local MAX_REMAINDER = 1024 * 1024
local MAX_STREAM_METADATA_BYTES = 64 * 1024

local CHAT_TEXT_FIELDS = {
    "content",
    "reasoning_content",
    "refusal",
}

local RESPONSE_MODES = {
    ["response.output_text.delta"] = {
        data_type = "response.output_text.delta",
        field = "delta",
        mode = "text",
        family = "output_text",
        part_index = "content_index",
    },
    ["response.output_text.done"] = {
        data_type = "response.output_text.done",
        field = "text",
        mode = "text",
        family = "output_text",
        part_index = "content_index",
        done = true,
    },
    ["response.reasoning_summary_text.delta"] = {
        data_type = "response.reasoning_summary_text.delta",
        field = "delta",
        mode = "text",
        family = "reasoning_summary_text",
        part_index = "summary_index",
    },
    ["response.reasoning_summary_text.done"] = {
        data_type = "response.reasoning_summary_text.done",
        field = "text",
        mode = "text",
        family = "reasoning_summary_text",
        part_index = "summary_index",
        done = true,
    },
    ["response.function_call_arguments.delta"] = {
        data_type = "response.function_call_arguments.delta",
        field = "delta",
        mode = "json_fragment",
        family = "function_call_arguments",
    },
    ["response.function_call_arguments.done"] = {
        data_type = "response.function_call_arguments.done",
        field = "arguments",
        mode = "json_fragment",
        family = "function_call_arguments",
        done = true,
    },
}

local ANTHROPIC_MODES = {
    text_delta = {field = "text", mode = "text", delta_type = "text_delta"},
    input_json_delta = {
        field = "partial_json",
        mode = "json_fragment",
        delta_type = "input_json_delta",
    },
}

local TERMINAL_EVENTS = {
    ["response.completed"] = true,
    ["response.failed"] = true,
    ["response.incomplete"] = true,
    error = true,
    message_stop = true,
}


local function next_boundary(buffer, start_pos)
    local lf_pos = buffer:find("\n\n", start_pos, true)
    local crlf_pos = buffer:find("\r\n\r\n", start_pos, true)
    if lf_pos and (not crlf_pos or lf_pos <= crlf_pos) then
        return lf_pos, 2
    end

    if crlf_pos then
        return crlf_pos, 4
    end
end


local function make_chat_final_event(meta, text)
    local delta = {}
    if meta.field == "function_call.arguments" then
        delta.function_call = {arguments = text}

    elseif meta.field == "tool_calls.function.arguments" then
        delta.tool_calls = {
            {
                index = meta.tool_index,
                ["function"] = {arguments = text},
            },
        }

    else
        delta[meta.field] = text
    end

    return {
        type = meta.event_type,
        data = core.json.encode({
            choices = {
                {
                    index = meta.choice_index,
                    delta = delta,
                },
            },
        }),
    }
end


local function make_response_final_event(meta, text)
    local data = {
        type = meta.data_type,
        delta = text,
    }
    if meta.item_id ~= nil then
        data.item_id = meta.item_id
    end
    if meta.output_index ~= nil then
        data.output_index = meta.output_index
    end
    if meta.content_index ~= nil then
        data.content_index = meta.content_index
    end
    if meta.summary_index ~= nil then
        data.summary_index = meta.summary_index
    end

    return {
        type = meta.event_type,
        data = core.json.encode(data),
    }
end


local function make_anthropic_final_event(meta, text)
    return {
        type = meta.event_type,
        data = core.json.encode({
            type = "content_block_delta",
            index = meta.index,
            delta = {
                type = meta.delta_type,
                [meta.field] = text,
            },
        }),
    }
end


local function make_final_event(meta, text)
    if meta.protocol_name == "openai-chat" then
        return make_chat_final_event(meta, text)
    end

    if meta.protocol_name == "openai-responses" then
        return make_response_final_event(meta, text)
    end

    return make_anthropic_final_event(meta, text)
end


local function is_optional_index(value)
    return value == nil or type(value) == "number"
end


local function is_optional_string(value)
    return value == nil or type(value) == "string"
end


local function is_absent_chat_value(value)
    return value == nil or value == core.json.null
end


local function is_optional_chat_index(value)
    return is_absent_chat_value(value) or type(value) == "number"
end


local function is_optional_chat_string(value)
    return is_absent_chat_value(value) or type(value) == "string"
end


local function is_valid_chat_value(value)
    if value.choices == nil then
        return true
    end
    if type(value.choices) ~= "table" then
        return false
    end

    for _, choice in ipairs(value.choices) do
        if type(choice) ~= "table" or not is_optional_chat_index(choice.index) then
            return false
        end

        local delta = choice.delta
        if not is_absent_chat_value(delta) then
            if type(delta) ~= "table" then
                return false
            end
            for _, field in ipairs(CHAT_TEXT_FIELDS) do
                if not is_optional_chat_string(delta[field]) then
                    return false
                end
            end

            local function_call = delta.function_call
            if not is_absent_chat_value(function_call) then
                if type(function_call) ~= "table"
                        or not is_optional_chat_string(function_call.arguments) then
                    return false
                end
            end

            local tool_calls = delta.tool_calls
            if not is_absent_chat_value(tool_calls) then
                if type(tool_calls) ~= "table" then
                    return false
                end
                for _, tool_call in ipairs(tool_calls) do
                    if type(tool_call) ~= "table"
                            or not is_optional_chat_index(tool_call.index) then
                        return false
                    end
                    local func = tool_call["function"]
                    if not is_absent_chat_value(func)
                            and (type(func) ~= "table"
                                 or not is_optional_chat_string(func.arguments)) then
                        return false
                    end
                end
            end
        end
    end

    return true
end


local function is_valid_response_value(event, value)
    if not is_optional_string(value.type) then
        return false
    end

    local field_config = RESPONSE_MODES[value.type or event.type]
    if not field_config then
        return true
    end

    return type(value[field_config.field]) == "string"
           and is_optional_string(value.item_id)
           and is_optional_index(value.output_index)
           and is_optional_index(value.content_index)
           and is_optional_index(value.summary_index)
end


local function is_valid_anthropic_value(value)
    if not is_optional_string(value.type) or not is_optional_index(value.index) then
        return false
    end
    if value.delta == nil then
        return true
    end
    if type(value.delta) ~= "table" or not is_optional_string(value.delta.type) then
        return false
    end

    local field_config = ANTHROPIC_MODES[value.delta.type]
    if not field_config then
        return true
    end

    return type(value.delta[field_config.field]) == "string"
end


local Processor = {}
Processor.__index = Processor


local function retained_metadata_bytes(key, meta)
    local bytes = #key
    if type(meta.event_type) == "string" then
        bytes = bytes + #meta.event_type
    end
    if type(meta.item_id) == "string" then
        bytes = bytes + #meta.item_id
    end
    return bytes
end


local function remove_key(processor, key)
    if processor.keys[key] == nil then
        return
    end

    processor.metadata_bytes =
        processor.metadata_bytes - processor.key_metadata_bytes[key]
    processor.key_metadata_bytes[key] = nil
    processor.keys[key] = nil
    for index, ordered_key in ipairs(processor.key_order) do
        if ordered_key == key then
            table_remove(processor.key_order, index)
            return
        end
    end
end


function Processor:restore_field(key, meta, value, mode)
    local output, count, stream_err = self.stream:feed(key, value, mode, false)
    if stream_err then
        error(stream_err, 0)
    end

    if self.stream.states[key] then
        local previous_bytes = self.key_metadata_bytes[key] or 0
        local metadata_bytes = retained_metadata_bytes(key, meta)
        local total_bytes = self.metadata_bytes - previous_bytes + metadata_bytes
        if total_bytes > MAX_STREAM_METADATA_BYTES then
            error("stream metadata byte limit exceeded", 0)
        end

        if self.keys[key] == nil then
            self.key_order[#self.key_order + 1] = key
        end
        self.keys[key] = meta
        self.key_metadata_bytes[key] = metadata_bytes
        self.metadata_bytes = total_bytes
    else
        remove_key(self, key)
    end

    return output, count
end


function Processor:finalize_key(key)
    local meta = self.keys[key]
    if not meta then
        return "", 0, 0
    end

    local pending, count, stream_err = self.stream:feed(key, "", meta.mode, true)
    if stream_err then
        error(stream_err, 0)
    end
    remove_key(self, key)
    if pending == "" then
        return "", count, 0
    end

    return sse_codec.encode(make_final_event(meta, pending)), count, 1
end


function Processor:finalize()
    local output = {}
    local restored_count = 0
    local unresolved_count = 0
    for _, key in ipairs(self.key_order) do
        local meta = self.keys[key]
        local pending, count, stream_err = self.stream:feed(key, "", meta.mode, true)
        if stream_err then
            error(stream_err, 0)
        end
        restored_count = restored_count + count
        if pending ~= "" then
            output[#output + 1] = sse_codec.encode(make_final_event(meta, pending))
            unresolved_count = unresolved_count + 1
        end
    end

    self.keys = {}
    self.key_order = {}
    self.key_metadata_bytes = {}
    self.metadata_bytes = 0
    self.stream.active_count = 0
    self.stream.pending_bytes = 0
    return table_concat(output), restored_count, unresolved_count
end


function Processor:fail_closed(buffered)
    local output = {}
    local unresolved_count = 0
    for _, key in ipairs(self.key_order) do
        local state = self.stream.states[key]
        if type(state) == "table" and type(state.pending) == "string"
                and state.pending ~= "" then
            output[#output + 1] = sse_codec.encode(
                make_final_event(self.keys[key], state.pending)
            )
            unresolved_count = unresolved_count + 1
        end
    end

    self.stream.states = {}
    self.stream.active_count = 0
    self.stream.pending_bytes = 0
    self.keys = {}
    self.key_order = {}
    self.key_metadata_bytes = {}
    self.metadata_bytes = 0
    self.remainder = ""
    output[#output + 1] = buffered or ""
    return table_concat(output), unresolved_count
end


function Processor:process_chat_event(event, value)
    local changed = false
    local restored_count = 0
    if not is_valid_chat_value(value) or type(value.choices) ~= "table" then
        return false, 0
    end

    for choice_pos, choice in ipairs(value.choices) do
        local delta = choice.delta
        if type(delta) == "table" then
            local choice_index = choice.index
            if is_absent_chat_value(choice_index) then
                choice_index = choice_pos - 1
            end

            for _, field in ipairs(CHAT_TEXT_FIELDS) do
                if type(delta[field]) == "string" then
                    local key = event.type .. ":choice:" .. choice_index .. ":" .. field
                    local restored, count = self:restore_field(
                        key,
                        {
                            event_type = event.type,
                            protocol_name = self.protocol_name,
                            choice_index = choice_index,
                            field = field,
                            mode = "text",
                        },
                        delta[field],
                        "text"
                    )
                    if restored ~= delta[field] then
                        delta[field] = restored
                        changed = true
                    end
                    restored_count = restored_count + count
                end
            end

            if type(delta.function_call) == "table"
                    and type(delta.function_call.arguments) == "string" then
                local key = event.type .. ":choice:" .. choice_index ..
                            ":function_call.arguments"
                local restored, count = self:restore_field(
                    key,
                    {
                        event_type = event.type,
                        protocol_name = self.protocol_name,
                        choice_index = choice_index,
                        field = "function_call.arguments",
                        mode = "json_fragment",
                    },
                    delta.function_call.arguments,
                    "json_fragment"
                )
                if restored ~= delta.function_call.arguments then
                    delta.function_call.arguments = restored
                    changed = true
                end
                restored_count = restored_count + count
            end

            if type(delta.tool_calls) == "table" then
                for tool_pos, tool_call in ipairs(delta.tool_calls) do
                    local tool_index = tool_call.index
                    if is_absent_chat_value(tool_index) then
                        tool_index = tool_pos - 1
                    end
                    local func = tool_call["function"]
                    if type(func) == "table" and type(func.arguments) == "string" then
                        local key = event.type .. ":choice:" .. choice_index .. ":tool:" ..
                                    tool_index .. ":function.arguments"
                        local restored, count = self:restore_field(
                            key,
                            {
                                event_type = event.type,
                                protocol_name = self.protocol_name,
                                choice_index = choice_index,
                                tool_index = tool_index,
                                field = "tool_calls.function.arguments",
                                mode = "json_fragment",
                            },
                            func.arguments,
                            "json_fragment"
                        )
                        if restored ~= func.arguments then
                            func.arguments = restored
                            changed = true
                        end
                        restored_count = restored_count + count
                    end
                end
            end
        end
    end

    return changed, restored_count
end


local function response_key_part(value)
    if type(value) == "string" then
        return "s" .. #value .. ":" .. value
    end
    if type(value) == "number" then
        return "n" .. tostring(value)
    end
    return "-"
end


local function response_key(field_config, value)
    local part_index
    if field_config.part_index then
        part_index = value[field_config.part_index]
    end
    return "response:" .. field_config.family .. ":" ..
           response_key_part(value.item_id) .. ":" ..
           response_key_part(value.output_index) .. ":" ..
           response_key_part(part_index)
end


function Processor:process_response_event(event, value)
    if not is_valid_response_value(event, value) then
        return false, 0, "", 0
    end

    local data_type = value.type or event.type
    local field_config = RESPONSE_MODES[data_type]
    if not field_config or type(value[field_config.field]) ~= "string" then
        return false, 0, "", 0
    end

    local key = response_key(field_config, value)
    local prefix = ""
    local prefix_count = 0
    local unresolved_count = 0
    if field_config.done then
        prefix, prefix_count, unresolved_count = self:finalize_key(key)
    end

    local meta = {
        event_type = event.type,
        protocol_name = self.protocol_name,
        data_type = field_config.data_type,
        field = field_config.field,
        mode = field_config.mode,
        item_id = value.item_id,
        output_index = value.output_index,
        content_index = value.content_index,
        summary_index = value.summary_index,
    }
    local restored
    local count
    if field_config.done then
        local stream_err
        restored, count, stream_err = self.stream:feed(
            key, value[field_config.field], field_config.mode, true
        )
        if stream_err then
            error(stream_err, 0)
        end
    else
        restored, count = self:restore_field(
            key, meta, value[field_config.field], field_config.mode
        )
    end
    count = count + prefix_count
    if restored == value[field_config.field] then
        return false, count, prefix, unresolved_count
    end

    value[field_config.field] = restored
    return true, count, prefix, unresolved_count
end


function Processor:process_anthropic_event(event, value)
    if not is_valid_anthropic_value(value) then
        return false, 0
    end

    local delta = value.delta
    if type(delta) ~= "table" then
        return false, 0
    end

    local field_config = ANTHROPIC_MODES[delta.type]
    if not field_config or type(delta[field_config.field]) ~= "string" then
        return false, 0
    end

    local key = event.type .. ":" .. tostring(value.index or "") .. ":" .. delta.type
    local restored, count = self:restore_field(
        key,
        {
            event_type = event.type,
            protocol_name = self.protocol_name,
            index = value.index,
            delta_type = field_config.delta_type,
            field = field_config.field,
            mode = field_config.mode,
        },
        delta[field_config.field],
        field_config.mode
    )
    if restored == delta[field_config.field] then
        return false, count
    end

    delta[field_config.field] = restored
    return true, count
end


function Processor:process_frame(frame)
    local events = sse_codec.decode(frame)
    if #events ~= 1 then
        return frame, 0, 0
    end

    local event = events[1]
    if event.data == "[DONE]" then
        local final_output, restored_count, unresolved_count = self:finalize()
        return final_output .. frame, restored_count, unresolved_count
    end

    if TERMINAL_EVENTS[event.type] then
        local final_output, restored_count, unresolved_count = self:finalize()
        return final_output .. frame, restored_count, unresolved_count
    end

    local value = core.json.decode(event.data)
    if type(value) ~= "table" then
        return frame, 0, 0
    end

    if TERMINAL_EVENTS[value.type] then
        local final_output, restored_count, unresolved_count = self:finalize()
        return final_output .. frame, restored_count, unresolved_count
    end

    local changed
    local restored_count
    local prefix = ""
    local unresolved_count = 0
    if self.protocol_name == "openai-chat" then
        changed, restored_count = self:process_chat_event(event, value)

    elseif self.protocol_name == "openai-responses" then
        changed, restored_count, prefix, unresolved_count =
            self:process_response_event(event, value)

    else
        changed, restored_count = self:process_anthropic_event(event, value)
    end
    if not changed then
        return prefix .. frame, restored_count, unresolved_count
    end

    event.data = core.json.encode(value)
    return prefix .. sse_codec.encode(event), restored_count, unresolved_count
end


local function feed_unsafe(self, chunk, eof)
    local buffer = self.remainder .. (chunk or "")
    local output = {}
    local restored_count = 0
    local unresolved_count = 0
    local start_pos = 1
    while true do
        local boundary_pos, boundary_length = next_boundary(buffer, start_pos)
        if not boundary_pos then
            break
        end

        local frame = buffer:sub(start_pos, boundary_pos + boundary_length - 1)
        local restored, frame_count, frame_unresolved = self:process_frame(frame)
        output[#output + 1] = restored
        restored_count = restored_count + frame_count
        unresolved_count = unresolved_count + frame_unresolved
        start_pos = boundary_pos + boundary_length
    end

    self.remainder = buffer:sub(start_pos)
    if not eof and #self.remainder > MAX_REMAINDER then
        output[#output + 1] = self.remainder
        self.remainder = ""
    end

    if eof then
        if self.remainder ~= "" then
            local restored, frame_count, frame_unresolved = self:process_frame(self.remainder)
            output[#output + 1] = restored
            restored_count = restored_count + frame_count
            unresolved_count = unresolved_count + frame_unresolved
            self.remainder = ""
        end

        local final_output, final_count, final_unresolved = self:finalize()
        output[#output + 1] = final_output
        restored_count = restored_count + final_count
        unresolved_count = unresolved_count + final_unresolved
    end

    return table_concat(output), restored_count, unresolved_count
end


local function snapshot_processor(processor)
    local states = {}
    for key, state in pairs(processor.stream.states) do
        states[key] = {pending = state.pending}
    end

    local keys = {}
    for key, meta in pairs(processor.keys) do
        keys[key] = meta
    end

    local key_order = {}
    for index, key in ipairs(processor.key_order) do
        key_order[index] = key
    end

    local key_metadata_bytes = {}
    for key, bytes in pairs(processor.key_metadata_bytes) do
        key_metadata_bytes[key] = bytes
    end

    return {
        remainder = processor.remainder,
        states = states,
        active_count = processor.stream.active_count,
        pending_bytes = processor.stream.pending_bytes,
        keys = keys,
        key_order = key_order,
        key_metadata_bytes = key_metadata_bytes,
        metadata_bytes = processor.metadata_bytes,
    }
end


function Processor:feed(chunk, eof)
    local snapshot = snapshot_processor(self)
    local ok, output, restored_count, unresolved_count = pcall(
        feed_unsafe, self, chunk, eof
    )
    if ok then
        return output, restored_count, unresolved_count
    end

    self.remainder = snapshot.remainder
    self.stream.states = snapshot.states
    self.stream.active_count = snapshot.active_count
    self.stream.pending_bytes = snapshot.pending_bytes
    self.keys = snapshot.keys
    self.key_order = snapshot.key_order
    self.key_metadata_bytes = snapshot.key_metadata_bytes
    self.metadata_bytes = snapshot.metadata_bytes
    error(output, 0)
end


function _M.new(protocol_name, mapping, namespace)
    if protocol_name == "bedrock-converse" then
        return nil, "raw AWS EventStream restoration is not supported"
    end

    if protocol_name ~= "openai-chat" and protocol_name ~= "openai-responses"
            and protocol_name ~= "anthropic-messages" then
        return nil, "streaming protocol passthrough is not supported"
    end

    return setmetatable(
        {
            protocol_name = protocol_name,
            remainder = "",
            stream = restorer.new_stream(mapping, namespace),
            keys = {},
            key_order = {},
            key_metadata_bytes = {},
            metadata_bytes = 0,
        },
        Processor
    )
end


return _M
