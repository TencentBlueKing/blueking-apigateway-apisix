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

                it(
                    "finds a valid token overlapping a malformed namespace occurrence",
                    function()
                        local reviewer_value = namespace .. namespace:sub(2) .. "1__"

                        local mapping, err = restorer.validate_mapping(
                            namespace,
                            {content = reviewer_value},
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
            end
        )

        context(
            "restore_json_text", function()
                it(
                    "preserves numeric lexemes and unchanged JSON bytes", function()
                        local raw = '{ "large":9007199254740993, "negative_zero":-0, ' ..
                                    '"exponent":1.2300e+40, "content":"' .. token .. '" }'
                        local expected =
                            '{ "large":9007199254740993, "negative_zero":-0, ' ..
                            '"exponent":1.2300e+40, "content":"restored" }'

                        local restored, count = restorer.restore_json_text(
                            raw, {[token] = "restored"}, namespace
                        )

                        assert.is_equal(expected, restored)
                        assert.is_equal(1, count)
                    end
                )

                it(
                    "preserves numeric lexemes in embedded function arguments", function()
                        local arguments =
                            '{ "large":9007199254740993, "negative_zero":-0, ' ..
                            '"exponent":1.2300e+40, "phone":"' .. token .. '" }'
                        local restored_arguments =
                            '{ "large":9007199254740993, "negative_zero":-0, ' ..
                            '"exponent":1.2300e+40, "phone":"restored" }'
                        local raw = '{"arguments":' ..
                                    assert(core.json.encode(arguments)) .. ',"order":1}'
                        local expected = '{"arguments":' ..
                                         assert(core.json.encode(restored_arguments)) ..
                                         ',"order":1}'

                        local restored, count = restorer.restore_json_text(
                            raw, {[token] = "restored"}, namespace
                        )

                        assert.is_equal(expected, restored)
                        assert.is_equal(1, count)
                        local decoded = assert(core.json.decode(restored))
                        assert.is_table(core.json.decode(decoded.arguments))
                    end
                )

                it(
                    "restores string values but not object keys or unknown tokens", function()
                        local unknown = namespace .. "9__"
                        local malformed = namespace .. "01__"
                        local raw = '{"' .. token .. '":"' .. token ..
                                    '","unknown":"' .. unknown .. '","malformed":"' ..
                                    malformed .. '"}'
                        local expected = '{"' .. token ..
                                         '":"restored","unknown":"' .. unknown ..
                                         '","malformed":"' .. malformed .. '"}'

                        local restored, count = restorer.restore_json_text(
                            raw, {[token] = "restored"}, namespace
                        )

                        assert.is_equal(expected, restored)
                        assert.is_equal(1, count)
                    end
                )

                it(
                    "accepts a supplementary Unicode pair in keys and values", function()
                        local raw = '{"\\uD83D\\uDE00":"\\uD83D\\uDE00",' ..
                                    '"content":"' .. token .. '"}'
                        local expected = '{"\\uD83D\\uDE00":"\\uD83D\\uDE00",' ..
                                         '"content":"restored"}'

                        local restored, count = restorer.restore_json_text(
                            raw, {[token] = "restored"}, namespace
                        )

                        assert.is_equal(expected, restored)
                        assert.is_equal(1, count)
                    end
                )

                it(
                    "rejects invalid surrogate escapes in keys and values", function()
                        local cases = {
                            '{"\\uD800":"value"}',
                            '{"key":"\\uD800"}',
                            '{"key":"\\uDC00"}',
                            '{"key":"\\uD800\\u0041"}',
                        }

                        for _, raw in ipairs(cases) do
                            local restored, err = restorer.restore_json_text(
                                raw, {}, namespace
                            )

                            assert.is_nil(restored)
                            assert.is_equal("invalid JSON", err)
                        end
                    end
                )

                it(
                    "rejects invalid raw UTF-8 in keys and values", function()
                        local invalid = string.char(0x80)
                        local cases = {
                            '{"' .. invalid .. '":"value"}',
                            '{"key":"' .. invalid .. '"}',
                        }

                        for _, raw in ipairs(cases) do
                            local restored, err = restorer.restore_json_text(
                                raw, {}, namespace
                            )

                            assert.is_nil(restored)
                            assert.is_equal("invalid JSON", err)
                            assert.is_falsy(err:find(invalid, 1, true))
                        end
                    end
                )

                it(
                    "restores escaped tokens and preserves escaped unknown values", function()
                        local unknown = namespace .. "9__"
                        local escaped_token = "\\u005f" .. token:sub(2)
                        local escaped_unknown = "\\u005f" .. unknown:sub(2)
                        local raw = '{"known":"' .. escaped_token ..
                                    '","unknown":"' .. escaped_unknown .. '"}'
                        local expected = '{"known":"restored","unknown":"' ..
                                         escaped_unknown .. '"}'

                        local restored, count = restorer.restore_json_text(
                            raw, {[token] = "restored"}, namespace
                        )

                        assert.is_equal(expected, restored)
                        assert.is_equal(1, count)
                    end
                )

                it(
                    "restores a token overlapping a malformed namespace occurrence",
                    function()
                        local reviewer_value = namespace .. namespace:sub(2) .. "1__"
                        local raw = '{"value":"' .. reviewer_value .. '"}'
                        local expected = '{"value":"' .. namespace:sub(1, -2) ..
                                         'restored"}'

                        local restored, count = restorer.restore_json_text(
                            raw, {[token] = "restored"}, namespace
                        )

                        assert.is_equal(expected, restored)
                        assert.is_equal(1, count)
                    end
                )

                it(
                    "rejects malformed trailing and over-depth JSON without content errors",
                    function()
                        local cases = {
                            '{"content":"' .. token .. '"',
                            '{"content":"' .. token .. '"} trailing',
                            string.rep("[", 129) .. '"' .. token .. '"' ..
                                string.rep("]", 129),
                        }

                        for _, raw in ipairs(cases) do
                            local restored, err = restorer.restore_json_text(
                                raw, {[token] = "sensitive-original"}, namespace
                            )

                            assert.is_nil(restored)
                            assert.is_string(err)
                            assert.is_falsy(err:find(token, 1, true))
                            assert.is_falsy(err:find("sensitive-original", 1, true))
                        end
                    end
                )

                it(
                    "restores adjacent complex originals without rescanning output", function()
                        local next_token = namespace .. "2__"
                        local original =
                            "quote \" backslash \\ newline\nUnicode 中文 token " .. next_token
                        local raw = '{"value":' ..
                                    assert(core.json.encode(token .. token .. next_token)) .. '}'
                        local expected = '{"value":' ..
                                         assert(core.json.encode(
                                             original .. original .. "second"
                                         )) .. '}'

                        local restored, count = restorer.restore_json_text(
                            raw,
                            {
                                [token] = original,
                                [next_token] = "second",
                            },
                            namespace
                        )

                        assert.is_equal(expected, restored)
                        assert.is_equal(3, count)
                    end
                )

                it(
                    "restores the default 1000-entry mapping within a bounded time", function()
                        local replacements = {}
                        local masked_parts = {}
                        local restored_parts = {}
                        for index = 1, 1000 do
                            local current_token = namespace .. index .. "__"
                            local original = "value-" .. index
                            replacements[index] = {
                                placeholder = current_token,
                                original = original,
                            }
                            masked_parts[index] = current_token
                            restored_parts[index] = original
                        end
                        local masked_text = table.concat(masked_parts, ",")
                        local raw = assert(core.json.encode({content = masked_text}))
                        local started_at = os.clock()

                        local validated = assert(restorer.validate_mapping(
                            namespace,
                            {content = masked_text},
                            replacements,
                            1000,
                            1024 * 1024
                        ))
                        local restored, count = restorer.restore_json_text(
                            raw, validated, namespace
                        )
                        local elapsed = os.clock() - started_at

                        assert.is_true(
                            elapsed < 0.2,
                            "1000-entry restoration took " .. elapsed .. " seconds"
                        )
                        assert.is_equal(1000, count)
                        assert.is_equal(
                            table.concat(restored_parts, ","),
                            assert(core.json.decode(restored)).content
                        )
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

                it(
                    "restores overlapping tokens in text and JSON fragment modes", function()
                        local reviewer_value = namespace .. namespace:sub(2) .. "1__"
                        local expected_prefix = namespace:sub(1, -2)
                        local stream = restorer.new_stream({[token] = "a\"b"}, namespace)

                        local text, text_count = stream:feed(
                            "text", reviewer_value, "text", true
                        )
                        local fragment, fragment_count = stream:feed(
                            "fragment", reviewer_value, "json_fragment", true
                        )

                        assert.is_equal(expected_prefix .. "a\"b", text)
                        assert.is_equal(1, text_count)
                        assert.is_equal(expected_prefix .. "a\\\"b", fragment)
                        assert.is_equal(1, fragment_count)
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
                    "restores Chat content when nullable delta fields are JSON null",
                    function()
                        local processor = assert(sse.new(
                            "openai-chat", {[token] = "13800138000"}, namespace
                        ))
                        local frame = "data: " .. core.json.encode({
                            choices = {
                                {
                                    index = 0,
                                    delta = {
                                        content = token,
                                        refusal = core.json.null,
                                    },
                                },
                            },
                        }) .. "\n\n"

                        local output, restored_count = processor:feed(frame, false)
                        local data = core.json.decode(sse_codec.decode(output)[1].data)

                        assert.is_equal(
                            "13800138000", data.choices[1].delta.content
                        )
                        assert.is_equal(1, restored_count)
                        assert.is_equal(
                            core.json.null, data.choices[1].delta.refusal
                        )
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
                    "passes structurally invalid Chat data through and restores the next frame",
                    function()
                        local processor = assert(sse.new(
                            "openai-chat", {[token] = "13800138000"}, namespace
                        ))
                        local malformed_data =
                            '{"choices":[1],"masked":"' .. token .. '"}'
                        local malformed = "data: " .. malformed_data .. "\n\n"
                        local valid = "data: " .. core.json.encode({
                            choices = {
                                {
                                    index = 0,
                                    delta = {content = token},
                                },
                            },
                        }) .. "\n\n"

                        local ok, output, restored_count, unresolved_count =
                            pcall(processor.feed, processor, malformed .. valid, false)

                        assert.is_true(ok)
                        local events = sse_codec.decode(output)
                        assert.is_equal(malformed_data, events[1].data)
                        assert.is_truthy(events[1].data:find(token, 1, true))
                        assert.is_falsy(events[1].data:find("13800138000", 1, true))
                        local restored = core.json.decode(events[2].data)
                        assert.is_equal(
                            "13800138000", restored.choices[1].delta.content
                        )
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
