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
    end
)
