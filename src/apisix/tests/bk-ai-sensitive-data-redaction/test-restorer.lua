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
local sse = require("apisix.plugins.bk-ai-sensitive-data-redaction.sse")
local sse_codec = require("apisix.plugins.ai-transport.sse")

describe(
    "bk-ai-sensitive-data-redaction restorer", function()
        local namespace = "__BK_REDACT_da584df57bd5459098e08f92a89f9494_"
        local token = namespace .. "1__"
        local body = {
            messages = {
                {
                    role = "user",
                    content = "phone: " .. token,
                },
            },
        }

        context(
            "validate_mapping", function()
                it(
                    "accepts a valid request-scoped mapping", function()
                        local mapping, err = restorer.validate_mapping(
                            namespace,
                            body,
                            {
                                {
                                    placeholder = token,
                                    original = "13800138000",
                                },
                            },
                            10,
                            1024
                        )

                        assert.is_nil(err)
                        assert.is_equal("13800138000", mapping[token])
                    end
                )

                local invalid_cases = {
                    {
                        name = "rejects duplicate placeholders",
                        replacements = {
                            {
                                placeholder = token,
                                original = "13800138000",
                            },
                            {
                                placeholder = token,
                                original = "13900139000",
                            },
                        },
                        expected_err = "duplicate placeholder",
                    },
                    {
                        name = "rejects placeholders from another request namespace",
                        replacements = {
                            {
                                placeholder = "__BK_REDACT_other_1__",
                                original = "13800138000",
                            },
                        },
                        expected_err = "placeholder is outside request namespace",
                    },
                    {
                        name = "rejects placeholders absent from the masked body",
                        replacements = {
                            {
                                placeholder = namespace .. "2__",
                                original = "not-present",
                            },
                        },
                        expected_err = "placeholder is absent from masked body",
                    },
                    {
                        name = "rejects non-string original values",
                        replacements = {
                            {
                                placeholder = token,
                                original = {},
                            },
                        },
                        expected_err = "invalid mapping entry",
                    },
                }

                for _, case in ipairs(invalid_cases) do
                    it(
                        case.name, function()
                            local mapping, err = restorer.validate_mapping(
                                namespace, body, case.replacements, 10, 1024
                            )

                            assert.is_nil(mapping)
                            assert.is_equal(case.expected_err, err)
                        end
                    )
                end

                it(
                    "rejects an object-shaped replacements table", function()
                        local mapping, err = restorer.validate_mapping(
                            namespace,
                            body,
                            {
                                placeholder = token,
                                original = "13800138000",
                            },
                            10,
                            1024
                        )

                        assert.is_nil(mapping)
                        assert.is_equal("replacements must be an array", err)
                    end
                )

                it(
                    "rejects a sparse replacements table", function()
                        local mapping, err = restorer.validate_mapping(
                            namespace,
                            body,
                            {
                                [1] = {
                                    placeholder = token,
                                    original = "13800138000",
                                },
                                [3] = {
                                    placeholder = namespace .. "2__",
                                    original = "13900139000",
                                },
                            },
                            10,
                            1024
                        )

                        assert.is_nil(mapping)
                        assert.is_equal("replacements must be an array", err)
                    end
                )

                it(
                    "rejects mappings above the entry limit", function()
                        local mapping, err = restorer.validate_mapping(
                            namespace,
                            body,
                            {
                                {
                                    placeholder = token,
                                    original = "13800138000",
                                },
                            },
                            0,
                            1024
                        )

                        assert.is_nil(mapping)
                        assert.is_equal("mapping entry limit exceeded", err)
                    end
                )

                it(
                    "rejects mappings above the byte limit", function()
                        local mapping, err = restorer.validate_mapping(
                            namespace,
                            body,
                            {
                                {
                                    placeholder = token,
                                    original = "13800138000",
                                },
                            },
                            10,
                            #token
                        )

                        assert.is_nil(mapping)
                        assert.is_equal("mapping byte limit exceeded", err)
                    end
                )
            end
        )

        context(
            "restore_json", function()
                it(
                    "restores repeated placeholders in nested response strings", function()
                        local unknown = namespace .. "9__"
                        local response = {
                            choices = {
                                {
                                    message = {
                                        content = "phone=" .. token .. ", again=" .. token,
                                        tool_calls = {
                                            {
                                                type = "function",
                                                ["function"] = {
                                                    name = "save_contact",
                                                    arguments = core.json.encode({
                                                        name = "a\"b",
                                                        phone = token,
                                                    }),
                                                },
                                            },
                                        },
                                    },
                                },
                            },
                            untouched = unknown,
                        }

                        local restored, count = restorer.restore_json(
                            response, {[token] = "13800138000"}
                        )

                        assert.is_equal(3, count)
                        assert.is_equal(
                            "phone=13800138000, again=13800138000",
                            restored.choices[1].message.content
                        )
                        local arguments = core.json.decode(
                            restored.choices[1].message.tool_calls[1]["function"].arguments
                        )
                        assert.is_equal("a\"b", arguments.name)
                        assert.is_equal("13800138000", arguments.phone)
                        assert.is_equal(unknown, restored.untouched)
                    end
                )

                it(
                    "preserves quotes and newlines in nested JSON originals", function()
                        local original = "first line\n\"quoted\""
                        local value = core.json.encode({value = token})

                        local restored, count = restorer.restore_json(value, {[token] = original})

                        assert.is_equal(1, count)
                        assert.is_equal(original, core.json.decode(restored).value)
                    end
                )

                it(
                    "does not rescan replacement output", function()
                        local next_token = namespace .. "2__"
                        local restored, count = restorer.restore_json(
                            token,
                            {
                                [token] = next_token,
                                [next_token] = "must-not-be-used",
                            }
                        )

                        assert.is_equal(1, count)
                        assert.is_equal(next_token, restored)
                    end
                )
            end
        )

        context(
            "stream restoration", function()
                it(
                    "restores split text and JSON-fragment placeholders", function()
                        local stream = restorer.new_stream({[token] = "a\"b"}, namespace)

                        local out1, count1 = stream:feed(
                            "choice:0:content", "phone: " .. token:sub(1, 28), "text", false
                        )
                        local out2, count2 = stream:feed(
                            "choice:0:content", token:sub(29), "text", false
                        )
                        local arg1, arg_count1 = stream:feed(
                            "choice:0:tool:0",
                            "{\"name\":\"" .. token:sub(1, 31),
                            "json_fragment",
                            false
                        )
                        local arg2, arg_count2 = stream:feed(
                            "choice:0:tool:0",
                            token:sub(32) .. "\"}",
                            "json_fragment",
                            false
                        )

                        assert.is_equal("phone: ", out1)
                        assert.is_equal(0, count1)
                        assert.is_equal("a\"b", out2)
                        assert.is_equal(1, count2)
                        assert.is_equal("{\"name\":\"", arg1)
                        assert.is_equal(0, arg_count1)
                        assert.is_equal("a\\\"b\"}", arg2)
                        assert.is_equal(1, arg_count2)
                    end
                )

                it(
                    "keeps pending placeholder prefixes isolated by logical key", function()
                        local stream = restorer.new_stream({[token] = "restored"}, namespace)
                        local split_at = #token - 3

                        local first_a = stream:feed(
                            "choice:0:content", "a=" .. token:sub(1, split_at), "text", false
                        )
                        local first_b, count_b = stream:feed(
                            "choice:1:content", "b=" .. token, "text", false
                        )
                        local second_a, count_a = stream:feed(
                            "choice:0:content", token:sub(split_at + 1), "text", false
                        )

                        assert.is_equal("a=", first_a)
                        assert.is_equal("b=restored", first_b)
                        assert.is_equal(1, count_b)
                        assert.is_equal("restored", second_a)
                        assert.is_equal(1, count_a)
                    end
                )

                it(
                    "flushes an incomplete namespace prefix unchanged on final input", function()
                        local stream = restorer.new_stream({[token] = "restored"}, namespace)
                        local prefix = namespace:sub(1, #namespace - 4)

                        local first = stream:feed(
                            "choice:1:content", prefix, "text", false
                        )
                        local final_out, count = stream:feed(
                            "choice:1:content", "", "text", true
                        )

                        assert.is_equal("", first)
                        assert.is_equal(prefix, final_out)
                        assert.is_equal(0, count)
                    end
                )
            end
        )

        context(
            "SSE restoration", function()
                it(
                    "restores an OpenAI Chat placeholder split across events", function()
                        local processor = assert(sse.new(
                            "openai-chat", {[token] = "13800138000"}, namespace
                        ))
                        local event1 =
                            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"phone " ..
                            token:sub(1, 30) .. "\"}}]}\n\n"
                        local event2 =
                            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"" ..
                            token:sub(31) .. "\"}}]}\n\n"

                        local out1 = processor:feed(event1 .. event2:sub(1, 20), false)
                        local out2 = processor:feed(
                            event2:sub(21) .. "data: [DONE]\n\n", false
                        )

                        assert.is_truthy(out1:find("phone ", 1, true))
                        assert.is_falsy(out1:find("13800138000", 1, true))
                        assert.is_truthy(out2:find("13800138000", 1, true))
                        assert.is_truthy(out2:find("data: [DONE]", 1, true))
                    end
                )

                it(
                    "preserves keepalive comments byte-for-byte", function()
                        local processor = assert(sse.new("openai-chat", {}, namespace))

                        local output = processor:feed(": keepalive\n\n", false)

                        assert.is_equal(": keepalive\n\n", output)
                    end
                )

                it(
                    "preserves unmodified CRLF frames byte-for-byte", function()
                        local processor = assert(sse.new(
                            "openai-chat", {[token] = "13800138000"}, namespace
                        ))
                        local frame =
                            "data: {\"choices\":[{\"index\":0," ..
                            "\"delta\":{\"content\":\"hello\"}}]}\r\n\r\n"

                        local output = processor:feed(frame, false)

                        assert.is_equal(frame, output)
                    end
                )

                it(
                    "restores OpenAI Chat tool arguments as JSON fragments", function()
                        local original = "a\"b"
                        local processor = assert(sse.new(
                            "openai-chat", {[token] = original}, namespace
                        ))
                        local first_arguments = "{\"phone\":\"" .. token:sub(1, 30)
                        local second_arguments = token:sub(31) .. "\"}"
                        local event1 = "data: " .. core.json.encode({
                            choices = {
                                {
                                    index = 0,
                                    delta = {
                                        tool_calls = {
                                            {
                                                index = 3,
                                                ["function"] = {arguments = first_arguments},
                                            },
                                        },
                                    },
                                },
                            },
                        }) .. "\n\n"
                        local event2 = "data: " .. core.json.encode({
                            choices = {
                                {
                                    index = 0,
                                    delta = {
                                        tool_calls = {
                                            {
                                                index = 3,
                                                ["function"] = {arguments = second_arguments},
                                            },
                                        },
                                    },
                                },
                            },
                        }) .. "\n\n"

                        local output = processor:feed(event1 .. event2, false)
                        local events = sse_codec.decode(output)
                        local first = core.json.decode(events[1].data)
                        local second = core.json.decode(events[2].data)
                        local arguments =
                            first.choices[1].delta.tool_calls[1]["function"].arguments ..
                            second.choices[1].delta.tool_calls[1]["function"].arguments

                        assert.is_equal(original, core.json.decode(arguments).phone)
                    end
                )

                it(
                    "restores OpenAI Responses text and function arguments", function()
                        local original = "a\"b"
                        local processor = assert(sse.new(
                            "openai-responses", {[token] = original}, namespace
                        ))
                        local text_event =
                            "event: response.output_text.delta\n" ..
                            "data: " .. core.json.encode({
                                type = "response.output_text.delta",
                                item_id = "msg_1",
                                delta = token,
                            }) .. "\n\n"
                        local arguments_event =
                            "event: response.function_call_arguments.delta\n" ..
                            "data: " .. core.json.encode({
                                type = "response.function_call_arguments.delta",
                                item_id = "call_1",
                                delta = "{\"phone\":\"" .. token .. "\"}",
                            }) .. "\n\n"

                        local output = processor:feed(text_event .. arguments_event, false)
                        local events = sse_codec.decode(output)
                        local text_data = core.json.decode(events[1].data)
                        local arguments_data = core.json.decode(events[2].data)

                        assert.is_equal(original, text_data.delta)
                        assert.is_equal(original, core.json.decode(arguments_data.delta).phone)
                    end
                )

                it(
                    "restores Anthropic text and input JSON deltas", function()
                        local original = "a\"b"
                        local processor = assert(sse.new(
                            "anthropic-messages", {[token] = original}, namespace
                        ))
                        local text_event =
                            "event: content_block_delta\n" ..
                            "data: " .. core.json.encode({
                                type = "content_block_delta",
                                index = 0,
                                delta = {type = "text_delta", text = token},
                            }) .. "\n\n"
                        local input_event =
                            "event: content_block_delta\n" ..
                            "data: " .. core.json.encode({
                                type = "content_block_delta",
                                index = 1,
                                delta = {
                                    type = "input_json_delta",
                                    partial_json = "{\"phone\":\"" .. token .. "\"}",
                                },
                            }) .. "\n\n"

                        local output = processor:feed(text_event .. input_event, false)
                        local events = sse_codec.decode(output)
                        local text_data = core.json.decode(events[1].data)
                        local input_data = core.json.decode(events[2].data)

                        assert.is_equal(original, text_data.delta.text)
                        assert.is_equal(
                            original, core.json.decode(input_data.delta.partial_json).phone
                        )
                    end
                )

                it(
                    "flushes unresolved OpenAI Responses text before a terminal event", function()
                        local processor = assert(sse.new(
                            "openai-responses", {[token] = "13800138000"}, namespace
                        ))
                        local prefix = token:sub(1, 30)
                        local delta_event =
                            "event: response.output_text.delta\n" ..
                            "data: " .. core.json.encode({
                                type = "response.output_text.delta",
                                item_id = "msg_1",
                                delta = prefix,
                            }) .. "\n\n"
                        local terminal_event =
                            "data: {\"type\":\"response.completed\"}\n\n"

                        local first = processor:feed(delta_event, false)
                        local output, restored_count, unresolved_count =
                            processor:feed(terminal_event, false)
                        local events = sse_codec.decode(output)
                        local flushed = core.json.decode(events[1].data)

                        assert.is_falsy(first:find(prefix, 1, true))
                        assert.is_equal(prefix, flushed.delta)
                        assert.is_equal("response.output_text.delta", flushed.type)
                        assert.is_equal("msg_1", flushed.item_id)
                        assert.is_equal(
                            "response.completed", core.json.decode(events[2].data).type
                        )
                        assert.is_equal(0, restored_count)
                        assert.is_equal(1, unresolved_count)
                    end
                )

                it(
                    "flushes pending text before a plain-text named terminal frame", function()
                        local processor = assert(sse.new(
                            "openai-responses", {[token] = "13800138000"}, namespace
                        ))
                        local prefix = token:sub(1, 30)
                        local delta_event =
                            "event: response.output_text.delta\n" ..
                            "data: " .. core.json.encode({
                                type = "response.output_text.delta",
                                item_id = "msg_1",
                                delta = prefix,
                            }) .. "\n\n"
                        local terminal_event =
                            "event: response.failed\n" ..
                            "data: upstream failed\n\n"
                        processor:feed(delta_event, false)

                        local output, restored_count, unresolved_count =
                            processor:feed(terminal_event, false)
                        local events = sse_codec.decode(output)
                        local flushed = core.json.decode(events[1].data)

                        assert.is_equal(prefix, flushed.delta)
                        assert.is_equal("response.output_text.delta", flushed.type)
                        assert.is_equal("response.failed", events[2].type)
                        assert.is_equal("upstream failed", events[2].data)
                        assert.is_equal(terminal_event, output:sub(-#terminal_event))
                        assert.is_equal(0, restored_count)
                        assert.is_equal(1, unresolved_count)
                    end
                )

                it(
                    "flushes pending text before an empty named terminal frame", function()
                        local processor = assert(sse.new(
                            "anthropic-messages", {[token] = "13800138000"}, namespace
                        ))
                        local prefix = token:sub(1, 30)
                        local delta_event =
                            "event: content_block_delta\n" ..
                            "data: " .. core.json.encode({
                                type = "content_block_delta",
                                index = 0,
                                delta = {type = "text_delta", text = prefix},
                            }) .. "\n\n"
                        local terminal_event = "event: message_stop\ndata:\n\n"
                        processor:feed(delta_event, false)

                        local output, _, unresolved_count =
                            processor:feed(terminal_event, false)
                        local events = sse_codec.decode(output)
                        local flushed = core.json.decode(events[1].data)

                        assert.is_equal(prefix, flushed.delta.text)
                        assert.is_equal("message_stop", events[2].type)
                        assert.is_equal("", events[2].data)
                        assert.is_equal(terminal_event, output:sub(-#terminal_event))
                        assert.is_equal(1, unresolved_count)
                    end
                )

                it(
                    "flushes pending logical outputs in their arrival order", function()
                        local processor = assert(sse.new(
                            "openai-chat", {[token] = "13800138000"}, namespace
                        ))
                        local frames = {}
                        for index = 0, 5 do
                            frames[#frames + 1] = "data: " .. core.json.encode({
                                choices = {
                                    {
                                        index = index,
                                        delta = {content = token:sub(1, 30)},
                                    },
                                },
                            }) .. "\n\n"
                        end
                        processor:feed(table.concat(frames), false)

                        local output = processor:feed("data: [DONE]\n\n", false)
                        local events = sse_codec.decode(output)

                        for index = 0, 5 do
                            local data = core.json.decode(events[index + 1].data)
                            assert.is_equal(index, data.choices[1].index)
                        end
                        assert.is_equal("[DONE]", events[7].data)
                    end
                )

                it(
                    "processes a final unterminated frame at transport EOF", function()
                        local processor = assert(sse.new(
                            "anthropic-messages", {[token] = "13800138000"}, namespace
                        ))
                        local event =
                            "event: content_block_delta\n" ..
                            "data: " .. core.json.encode({
                                type = "content_block_delta",
                                index = 0,
                                delta = {type = "text_delta", text = token},
                            })

                        local output, restored_count, unresolved_count =
                            processor:feed(event, true)
                        local data = core.json.decode(sse_codec.decode(output)[1].data)

                        assert.is_equal("13800138000", data.delta.text)
                        assert.is_equal(1, restored_count)
                        assert.is_equal(0, unresolved_count)
                    end
                )

                it(
                    "restores a placeholder when a complete frame ends at EOF",
                    function()
                        local processor = assert(sse.new(
                            "openai-chat", {[token] = "13800138000"}, namespace
                        ))
                        local frame = "data: " .. core.json.encode({
                            choices = {
                                {
                                    index = 0,
                                    delta = {content = "answer=" .. token},
                                },
                            },
                        }) .. "\n\n"

                        local first = processor:feed(
                            frame:sub(1, #frame - 1), false
                        )
                        local final, restored_count, unresolved_count =
                            processor:feed(frame:sub(#frame), true)

                        assert.is_equal("", first)
                        assert.is_truthy(final:find("answer=13800138000", 1, true))
                        assert.is_equal(1, restored_count)
                        assert.is_equal(0, unresolved_count)
                    end
                )

                it(
                    "keeps an incomplete placeholder prefix masked at EOF", function()
                        local processor = assert(sse.new(
                            "openai-chat", {[token] = "13800138000"}, namespace
                        ))
                        local prefix = namespace:sub(1, #namespace - 1)
                        local frame = "data: " .. core.json.encode({
                            choices = {
                                {
                                    index = 0,
                                    delta = {content = prefix},
                                },
                            },
                        }) .. "\n\n"

                        local output, restored_count, unresolved_count =
                            processor:feed(frame, true)

                        assert.is_falsy(output:find("13800138000", 1, true))
                        assert.is_truthy(output:find(prefix, 1, true))
                        assert.is_equal(0, restored_count)
                        assert.is_equal(1, unresolved_count)
                    end
                )

                it(
                    "passes malformed data through masked and restores the next frame",
                    function()
                        local processor = assert(sse.new(
                            "openai-chat", {[token] = "13800138000"}, namespace
                        ))
                        local malformed = "data: {\"masked\":\"" .. token .. "\"\n\n"
                        local valid = "data: " .. core.json.encode({
                            choices = {
                                {
                                    index = 0,
                                    delta = {content = token},
                                },
                            },
                        }) .. "\n\n"

                        local output, restored_count, unresolved_count =
                            processor:feed(malformed .. valid, false)

                        assert.is_equal(malformed, output:sub(1, #malformed))
                        assert.is_truthy(output:find(token, 1, true))
                        assert.is_truthy(output:find("13800138000", 1, true))
                        assert.is_equal(1, restored_count)
                        assert.is_equal(0, unresolved_count)
                    end
                )

                it(
                    "bounds incomplete frame buffering at one MiB", function()
                        local limit = 1024 * 1024
                        local at_limit = string.rep("x", limit)
                        local at_limit_processor = assert(sse.new(
                            "openai-chat", {[token] = "13800138000"}, namespace
                        ))

                        local held = at_limit_processor:feed(at_limit, false)
                        local completed = at_limit_processor:feed("\n\n", false)

                        assert.is_equal("", held)
                        assert.is_equal(at_limit .. "\n\n", completed)

                        local above_limit = string.rep("x", limit + 1)
                        local processor = assert(sse.new(
                            "openai-chat", {[token] = "13800138000"}, namespace
                        ))

                        local emitted, restored_count, unresolved_count =
                            processor:feed(above_limit, false)

                        assert.is_equal(above_limit, emitted)
                        assert.is_equal(0, restored_count)
                        assert.is_equal(0, unresolved_count)

                        local valid_event = "data: " .. core.json.encode({
                            choices = {
                                {
                                    index = 0,
                                    delta = {content = token},
                                },
                            },
                        }) .. "\n\n"
                        local output, later_count = processor:feed(valid_event, false)
                        local data = core.json.decode(sse_codec.decode(output)[1].data)

                        assert.is_equal("13800138000", data.choices[1].delta.content)
                        assert.is_equal(1, later_count)
                    end
                )

                it(
                    "returns exact errors for unsupported streaming protocols", function()
                        local processor, err = sse.new("bedrock-converse", {}, namespace)
                        local unknown, unknown_err = sse.new("passthrough", {}, namespace)

                        assert.is_nil(processor)
                        assert.is_equal(
                            "raw AWS EventStream restoration is not supported", err
                        )
                        assert.is_nil(unknown)
                        assert.is_equal(
                            "streaming protocol passthrough is not supported", unknown_err
                        )
                    end
                )
            end
        )
    end
)
