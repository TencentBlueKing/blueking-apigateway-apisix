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
local ipairs = ipairs
local setmetatable = setmetatable
local table_concat = table.concat
local tostring = tostring
local type = type

local _M = {}

local CHAT_TEXT_FIELDS = {
    "content",
    "reasoning_content",
    "refusal",
}

local RESPONSE_MODES = {
    ["response.output_text.delta"] = {field = "delta", mode = "text"},
    ["response.reasoning_summary_text.delta"] = {field = "delta", mode = "text"},
    ["response.function_call_arguments.delta"] = {
        field = "delta",
        mode = "json_fragment",
    },
}

local ANTHROPIC_MODES = {
    text_delta = {field = "text", mode = "text"},
    input_json_delta = {field = "partial_json", mode = "json_fragment"},
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


local Processor = {}
Processor.__index = Processor


function Processor:restore_field(key, meta, value, mode)
    local output, count = self.stream:feed(key, value, mode, false)
    if self.keys[key] == nil then
        self.key_order[#self.key_order + 1] = key
    end
    self.keys[key] = meta
    return output, count
end


function Processor:finalize()
    local output = {}
    local restored_count = 0
    local unresolved_count = 0
    for _, key in ipairs(self.key_order) do
        local meta = self.keys[key]
        local pending, count = self.stream:feed(key, "", meta.mode, true)
        restored_count = restored_count + count
        if pending ~= "" then
            output[#output + 1] = sse_codec.encode(make_final_event(meta, pending))
            unresolved_count = unresolved_count + 1
        end
    end

    self.keys = {}
    self.key_order = {}
    return table_concat(output), restored_count, unresolved_count
end


function Processor:process_chat_event(event, value)
    local changed = false
    local restored_count = 0
    if type(value.choices) ~= "table" then
        return false, 0
    end

    for choice_pos, choice in ipairs(value.choices) do
        local delta = choice.delta
        if type(delta) == "table" then
            local choice_index = choice.index
            if choice_index == nil then
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
                    if tool_index == nil then
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


function Processor:process_response_event(event, value)
    local data_type = value.type or event.type
    local field_config = RESPONSE_MODES[data_type]
    if not field_config or type(value[field_config.field]) ~= "string" then
        return false, 0
    end

    local logical_id = value.item_id
    if logical_id == nil then
        logical_id = value.output_index
    end
    local key = data_type .. ":" .. tostring(logical_id or "") .. ":" .. field_config.field
    local restored, count = self:restore_field(
        key,
        {
            event_type = event.type,
            protocol_name = self.protocol_name,
            data_type = data_type,
            field = field_config.field,
            mode = field_config.mode,
            item_id = value.item_id,
            output_index = value.output_index,
        },
        value[field_config.field],
        field_config.mode
    )
    if restored == value[field_config.field] then
        return false, count
    end

    value[field_config.field] = restored
    return true, count
end


function Processor:process_anthropic_event(event, value)
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
            delta_type = delta.type,
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


local function is_terminal_event(event, value)
    return TERMINAL_EVENTS[event.type] or TERMINAL_EVENTS[value.type]
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

    local value = core.json.decode(event.data)
    if type(value) ~= "table" then
        return frame, 0, 0
    end

    if is_terminal_event(event, value) then
        local final_output, restored_count, unresolved_count = self:finalize()
        return final_output .. frame, restored_count, unresolved_count
    end

    local changed
    local restored_count
    if self.protocol_name == "openai-chat" then
        changed, restored_count = self:process_chat_event(event, value)

    elseif self.protocol_name == "openai-responses" then
        changed, restored_count = self:process_response_event(event, value)

    else
        changed, restored_count = self:process_anthropic_event(event, value)
    end
    if not changed then
        return frame, restored_count, 0
    end

    event.data = core.json.encode(value)
    return sse_codec.encode(event), restored_count, 0
end


function Processor:feed(chunk, eof)
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
        },
        Processor
    )
end


return _M
