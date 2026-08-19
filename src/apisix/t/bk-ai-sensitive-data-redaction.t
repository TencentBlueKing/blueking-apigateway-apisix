#
# TencentBlueKing is pleased to support the open source community by making
# 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
# Copyright (C) Tencent. All rights reserved.
# Licensed under the MIT License (the "License"); you may not use this file except
# in compliance with the License. You may obtain a copy of the License at
#
#     http://opensource.org/licenses/MIT
#
# Unless required by applicable law or agreed to in writing, software distributed under
# the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
# either express or implied. See the License for the specific language governing permissions and
# limitations under the License.
#
# We undertake not to change the open source license (MIT license) applicable
# to the current version of the project delivered to anyone in the future.
#

use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_root_location();
no_shuffle();

add_block_preprocessor(sub {
    my ($block) = @_;

    if (!defined $block->request) {
        $block->set_value("request", "GET /t");
    }

    my $http_config = $block->http_config // <<'_EOC_';
        server {
            listen 6725;

            location /redact {
                content_by_lua_block {
                    local core = require("apisix.core")

                    ngx.req.read_body()
                    local payload = assert(core.json.decode(ngx.req.get_body_data()))
                    assert(type(payload.body) == "string")
                    local raw = payload.body
                    local body = assert(core.json.decode(payload.body))
                    local content
                    if type(body.input) == "string" then
                        content = body.input
                    else
                        content = body.messages[1].content
                    end

                    local original = assert(content:match("1%d%d%d%d%d%d%d%d%d%d"))
                    local token = payload.placeholder_namespace .. "1__"
                    raw = raw:gsub(original, token, 1)

                    local state = ngx.shared["plugin-limit-conn"]
                    state:incr("ai-redaction-call-count", 1, 0)
                    state:set("session-" .. payload.request_id, payload.session_id or "")
                    state:set("namespace-" .. payload.request_id,
                              payload.placeholder_namespace)

                    ngx.header.content_type = "application/json"
                    ngx.print(assert(core.json.encode({
                        body = raw,
                        replacements = {
                            {
                                placeholder = token,
                                original = original,
                            },
                        },
                    })))
                }
            }
        }

        server {
            listen 6726;

            location /chat {
                content_by_lua_block {
                    local core = require("apisix.core")

                    ngx.req.read_body()
                    local request = assert(core.json.decode(ngx.req.get_body_data()))
                    local content = request.messages[1].content
                    assert(not content:match("1%d%d%d%d%d%d%d%d%d%d"))
                    local token = assert(content:match(
                        "(__BK_REDACT_[0-9a-f]+_%d+__)"
                    ))
                    local overlap_role
                    if content:find("overlap-first", 1, true) then
                        overlap_role = "first"
                    elseif content:find("overlap-second", 1, true) then
                        overlap_role = "second"
                    end
                    local state = ngx.shared["plugin-limit-conn"]
                    if overlap_role then
                        state:incr("ai-redaction-overlap-arrived", 1, 0)
                        if overlap_role == "second" then
                            state:set("ai-redaction-overlap-second-waiting", 1)
                        end

                        local deadline = ngx.now() + 3
                        while state:get("ai-redaction-overlap-arrived") < 2
                                or (overlap_role == "first" and
                                    state:get(
                                        "ai-redaction-overlap-second-waiting"
                                    ) ~= 1) do
                            assert(ngx.now() < deadline, "overlap arrival timed out")
                            ngx.sleep(0.001)
                        end
                        if overlap_role == "second" then
                            while state:get(
                                    "ai-redaction-overlap-release-second"
                                  ) ~= 1 do
                                assert(
                                    ngx.now() < deadline,
                                    "overlap release timed out"
                                )
                                ngx.sleep(0.001)
                            end
                        end
                    end
                    local split_at = math.floor(#token / 2)
                    local function emit(frame, transport_split)
                        ngx.print(frame:sub(1, transport_split))
                        ngx.flush(true)
                        ngx.print(frame:sub(transport_split + 1))
                        ngx.flush(true)
                    end

                    ngx.header.content_type = "text/event-stream"
                    emit("data: " .. core.json.encode({
                        choices = {{index = 0, delta = {
                            content = "echo: " .. token:sub(1, split_at),
                        }}},
                    }) .. "\n\n", 23)
                    emit("data: " .. core.json.encode({
                        choices = {{index = 0, delta = {
                            content = token:sub(split_at + 1),
                        }}},
                    }) .. "\n\n", 29)
                    emit("data: " .. core.json.encode({
                        choices = {{index = 0, delta = {tool_calls = {{
                            index = 0,
                            ["function"] = {arguments =
                                "{\"phone\":\"" .. token:sub(1, split_at)},
                        }}}}},
                    }) .. "\n\n", 41)
                    emit("data: " .. core.json.encode({
                        choices = {{index = 0, delta = {tool_calls = {{
                            index = 0,
                            ["function"] = {arguments =
                                token:sub(split_at + 1) .. "\"}"},
                        }}}}},
                    }) .. "\n\n", 37)
                    ngx.print("data: [DONE]\n\n")
                    ngx.flush(true)
                    if overlap_role then
                        state:set(
                            "ai-redaction-overlap-" .. overlap_role .. "-finished",
                            1
                        )
                    end
                }
            }

            location /responses {
                content_by_lua_block {
                    local core = require("apisix.core")

                    ngx.req.read_body()
                    local request = assert(core.json.decode(ngx.req.get_body_data()))
                    assert(not request.input:match("1%d%d%d%d%d%d%d%d%d%d"))
                    local token = assert(request.input:match(
                        "(__BK_REDACT_[0-9a-f]+_%d+__)"
                    ))
                    local split_at = math.floor(#token / 2)
                    local function emit(frame, transport_split)
                        ngx.print(frame:sub(1, transport_split))
                        ngx.flush(true)
                        ngx.print(frame:sub(transport_split + 1))
                        ngx.flush(true)
                    end

                    ngx.header.content_type = "text/event-stream"
                    emit("event: response.output_text.delta\ndata: " ..
                         core.json.encode({
                             type = "response.output_text.delta",
                             item_id = "msg_1",
                             output_index = 0,
                             content_index = 0,
                             delta = token:sub(1, split_at),
                         }) .. "\n\n", 23)
                    emit("event: response.output_text.delta\ndata: " ..
                         core.json.encode({
                             type = "response.output_text.delta",
                             item_id = "msg_1",
                             output_index = 0,
                             content_index = 1,
                             delta = token:sub(1, split_at),
                         }) .. "\n\n", 29)
                    emit("event: response.output_text.delta\ndata: " ..
                         core.json.encode({
                             type = "response.output_text.delta",
                             item_id = "msg_1",
                             output_index = 0,
                             content_index = 0,
                             delta = token:sub(split_at + 1),
                         }) .. "\n\n", 31)
                    emit("event: response.output_text.delta\ndata: " ..
                         core.json.encode({
                             type = "response.output_text.delta",
                             item_id = "msg_1",
                             output_index = 0,
                             content_index = 1,
                             delta = token:sub(split_at + 1),
                         }) .. "\n\n", 33)
                    emit("event: response.function_call_arguments.delta\ndata: " ..
                         core.json.encode({
                             type = "response.function_call_arguments.delta",
                             item_id = "call_1",
                             output_index = 1,
                             delta = "{\"phone\":\"" .. token .. "\"}",
                         }) .. "\n\n", 41)
                    emit("event: response.completed\ndata: " ..
                         core.json.encode({type = "response.completed"}) ..
                         "\n\n", 19)
                }
            }

            location /chat-overflow {
                content_by_lua_block {
                    local core = require("apisix.core")

                    ngx.req.read_body()
                    local request = assert(core.json.decode(ngx.req.get_body_data()))
                    local token = assert(request.messages[1].content:match(
                        "(__BK_REDACT_[0-9a-f]+_%d+__)"
                    ))
                    local prefix = token:sub(1, #token - 1)
                    ngx.header.content_type = "text/event-stream"
                    for index = 0, 1024 do
                        ngx.print("data: " .. core.json.encode({
                            choices = {{
                                index = index,
                                delta = {content = prefix},
                            }},
                        }) .. "\n\n")
                        ngx.flush(true)
                    end
                }
            }

            location /chat-metadata-overflow {
                content_by_lua_block {
                    local core = require("apisix.core")

                    ngx.req.read_body()
                    local request = assert(core.json.decode(ngx.req.get_body_data()))
                    local token = assert(request.messages[1].content:match(
                        "(__BK_REDACT_[0-9a-f]+_%d+__)"
                    ))
                    local prefix = token:sub(1, #token - 1)
                    ngx.header.content_type = "text/event-stream"
                    ngx.print("event: " .. string.rep("e", 33000) .. "\ndata: " ..
                              core.json.encode({
                                  choices = {{
                                      index = 0,
                                      delta = {content = prefix},
                                  }},
                              }) .. "\n\n")
                    ngx.flush(true)
                }
            }

            location /anthropic {
                content_by_lua_block {
                    local core = require("apisix.core")

                    ngx.req.read_body()
                    local request = assert(core.json.decode(ngx.req.get_body_data()))
                    local content = request.messages[1].content
                    assert(not content:match("1%d%d%d%d%d%d%d%d%d%d"))
                    local token = assert(content:match(
                        "(__BK_REDACT_[0-9a-f]+_%d+__)"
                    ))
                    local split_at = math.floor(#token / 2)
                    local function emit(frame, transport_split)
                        ngx.print(frame:sub(1, transport_split))
                        ngx.flush(true)
                        ngx.print(frame:sub(transport_split + 1))
                        ngx.flush(true)
                    end

                    ngx.header.content_type = "text/event-stream"
                    emit("event: content_block_delta\ndata: " .. core.json.encode({
                        type = "content_block_delta",
                        index = 0,
                        delta = {
                            type = "text_delta",
                            text = token:sub(1, split_at),
                        },
                    }) .. "\n\n", 17)
                    emit("event: content_block_delta\ndata: " .. core.json.encode({
                        type = "content_block_delta",
                        index = 0,
                        delta = {
                            type = "text_delta",
                            text = token:sub(split_at + 1),
                        },
                    }) .. "\n\n", 31)
                    emit("event: content_block_delta\ndata: " .. core.json.encode({
                        type = "content_block_delta",
                        index = 1,
                        delta = {
                            type = "input_json_delta",
                            partial_json = "{\"phone\":\"" .. token .. "\"}",
                        },
                    }) .. "\n\n", 37)
                    emit("event: message_stop\ndata: " ..
                         core.json.encode({type = "message_stop"}) .. "\n\n", 13)
                }
            }

            location /chat-no-terminal {
                content_by_lua_block {
                    local core = require("apisix.core")

                    ngx.req.read_body()
                    local request = assert(core.json.decode(ngx.req.get_body_data()))
                    local token = assert(request.messages[1].content:match(
                        "(__BK_REDACT_[0-9a-f]+_%d+__)"
                    ))
                    ngx.header.content_type = "text/event-stream"
                    ngx.print("data: " .. core.json.encode({
                        choices = {{index = 0, delta = {content = token}}},
                    }) .. "\n\n")
                    ngx.flush(true)
                }
            }

            location /chat-incomplete {
                content_by_lua_block {
                    local core = require("apisix.core")

                    ngx.req.read_body()
                    local request = assert(core.json.decode(ngx.req.get_body_data()))
                    local token = assert(request.messages[1].content:match(
                        "(__BK_REDACT_[0-9a-f]+_%d+__)"
                    ))
                    ngx.header.content_type = "text/event-stream"
                    ngx.print("data: " .. core.json.encode({
                        choices = {{index = 0, delta = {
                            content = token:sub(1, #token - 2),
                        }}},
                    }) .. "\n\n")
                    ngx.flush(true)
                }
            }

            location /chat-malformed {
                content_by_lua_block {
                    local core = require("apisix.core")

                    ngx.req.read_body()
                    local request = assert(core.json.decode(ngx.req.get_body_data()))
                    local token = assert(request.messages[1].content:match(
                        "(__BK_REDACT_[0-9a-f]+_%d+__)"
                    ))
                    ngx.header.content_type = "text/event-stream"
                    ngx.print("data: {\"broken\":\"" .. token .. "\"\n\n")
                    ngx.flush(true)
                    ngx.print("data: " .. core.json.encode({
                        choices = {{index = 0, delta = {content = token}}},
                    }) .. "\n\ndata: [DONE]\n\n")
                    ngx.flush(true)
                }
            }

            location /should-not-call {
                content_by_lua_block {
                    ngx.shared["plugin-limit-conn"]:incr(
                        "ai-llm-rejected-call-count", 1, 0
                    )
                    ngx.status = 500
                }
            }
        }
_EOC_

    $block->set_value("http_config", $http_config);
});

run_tests;

__DATA__

=== TEST 1: configure ai-proxy with request redaction and response restoration
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local t = require("lib.test_admin").test

            ngx.shared["plugin-limit-conn"]:delete("ai-redaction-e2e-state")
            local route = {
                uri = "/redaction-chat",
                plugins = {
                    ["ai-proxy"] = {
                        provider = "openai",
                        auth = {
                            header = {Authorization = "Bearer test-token"},
                        },
                        options = {model = "gpt-4o"},
                        override = {endpoint = "http://127.0.0.1:6726"},
                        ssl_verify = false,
                    },
                    ["bk-ai-sensitive-data-redaction"] = {
                        endpoint = "http://127.0.0.1:6725/redact",
                        ssl_verify = false,
                        keepalive = false,
                    },
                    ["serverless-post-function"] = {
                        phase = "body_filter",
                        functions = {
                            [[return function(_, ctx)
                                local cleared =
                                    ctx._ai_redaction_session_id == nil and
                                    ctx._ai_redaction_namespace == nil and
                                    ctx._ai_redaction_mapping == nil and
                                    ctx._ai_redaction_sse_restorer == nil and
                                    ctx._ai_redaction_request_id ~= nil and
                                    ctx._ai_redaction_restored_count == 2
                                ngx.shared["plugin-limit-conn"]:set(
                                    "ai-redaction-e2e-state",
                                    cleared and "cleared" or "retained"
                                )
                            end]],
                        },
                    },
                },
            }
            local code, body = t(
                "/apisix/admin/routes/1",
                ngx.HTTP_PUT,
                assert(core.json.encode(route))
            )
            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed



=== TEST 2: raw value reaches redactor, LLM sees only token, and caller gets original
--- http_config
    server {
        listen 6725;

        location /redact {
            content_by_lua_block {
                local core = require("apisix.core")

                ngx.req.read_body()
                local payload = assert(core.json.decode(ngx.req.get_body_data()))
                assert(type(payload.body) == "string")
                local raw = payload.body
                local body = assert(core.json.decode(payload.body))
                assert(body.messages[1].content == "phone: 13800138000")
                local token = payload.placeholder_namespace .. "1__"
                raw = raw:gsub("13800138000", token, 1)
                ngx.header.content_type = "application/json"
                ngx.print(assert(core.json.encode({
                    body = raw,
                    replacements = {
                        {
                            placeholder = token,
                            original = "13800138000",
                        },
                    },
                })))
            }
        }
    }

    server {
        listen 6726;

        location / {
            content_by_lua_block {
                local core = require("apisix.core")

                ngx.req.read_body()
                local request = assert(core.json.decode(ngx.req.get_body_data()))
                local masked = request.messages[1].content
                assert(not masked:find("13800138000", 1, true))
                assert(masked:find("__BK_REDACT_", 1, true))
                local response = {
                    id = "chatcmpl-redaction",
                    object = "chat.completion",
                    choices = {
                        {
                            index = 0,
                            message = {
                                role = "assistant",
                                content = "echo: " .. masked,
                                tool_calls = {
                                    {
                                        id = "call_1",
                                        type = "function",
                                        ["function"] = {
                                            name = "save_contact",
                                            arguments = core.json.encode({phone = masked}),
                                        },
                                    },
                                },
                            },
                            finish_reason = "stop",
                        },
                    },
                    usage = {
                        prompt_tokens = 1,
                        completion_tokens = 1,
                        total_tokens = 2,
                    },
                }
                ngx.header.content_type = "application/json"
                ngx.print(assert(core.json.encode(response)))
            }
        }
    }
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local http = require("resty.http")

            local httpc = http.new()
            assert(httpc:connect({
                scheme = "http",
                host = "127.0.0.1",
                port = 1984,
            }))
            local res = assert(httpc:request({
                method = "POST",
                path = "/redaction-chat",
                headers = {
                    ["Content-Type"] = "application/json",
                    ["Connection"] = "close",
                },
                body = assert(core.json.encode({
                    model = "gpt-4o",
                    stream = false,
                    messages = {
                        {role = "user", content = "phone: 13800138000"},
                    },
                })),
            }))
            local response_body = assert(res:read_body())
            assert(res.status == 200, response_body)
            local response = assert(core.json.decode(response_body))
            assert(
                response.choices[1].message.content ==
                "echo: phone: 13800138000"
            )
            local arguments = assert(core.json.decode(
                response.choices[1].message.tool_calls[1]["function"].arguments
            ))
            assert(arguments.phone == "phone: 13800138000")
            assert(not response_body:find("__BK_REDACT_", 1, true))

            local state
            for _ = 1, 20 do
                state = ngx.shared["plugin-limit-conn"]:get(
                    "ai-redaction-e2e-state"
                )
                if state then
                    break
                end
                ngx.sleep(0.001)
            end
            ngx.say("response-restored")
            ngx.say("state-", state or "missing")
        }
    }
--- response_body
response-restored
state-cleared
--- no_error_log
[error]



=== TEST 3: configure supported streaming and fail-closed routes
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local t = require("lib.test_admin").test

            local state = ngx.shared["plugin-limit-conn"]
            state:set("ai-redaction-call-count", 0)
            state:set("ai-llm-rejected-call-count", 0)
            local post_filter = [[return function(_, ctx)
                if ctx._ai_redaction_request_id ~= nil and
                        ctx.var.request_type == "ai_stream" and
                        ctx._ai_redaction_mapping == nil and
                        ctx._ai_redaction_session_id == nil and
                        ctx._ai_redaction_namespace == nil and
                        ctx._ai_redaction_sse_restorer == nil then
                    ngx.shared["plugin-limit-conn"]:set(
                        "cleanup-" .. ctx._ai_redaction_request_id,
                        tostring(ctx._ai_redaction_restored_count or 0) .. ":" ..
                        tostring(ctx._ai_redaction_unresolved_count or 0)
                    )
                end
            end]]

            local function stream_plugins(provider, endpoint, model)
                return {
                    ["request-id"] = {
                        header_name = "X-Request-ID",
                        include_in_response = false,
                        algorithm = "uuid",
                    },
                    ["ai-proxy"] = {
                        provider = provider,
                        auth = {
                            header = {Authorization = "Bearer test-token"},
                        },
                        options = {model = model},
                        override = {endpoint = endpoint},
                        ssl_verify = false,
                        streaming_flush_interval_ms = 0,
                    },
                    ["bk-ai-sensitive-data-redaction"] = {
                        endpoint = "http://127.0.0.1:6725/redact",
                        ssl_verify = false,
                        keepalive = false,
                    },
                    ["serverless-post-function"] = {
                        phase = "body_filter",
                        functions = {post_filter},
                    },
                }
            end

            local routes = {
                {
                    id = 2,
                    value = {
                        uri = "/redact-stream",
                        plugins = stream_plugins(
                            "openai", "http://127.0.0.1:6726/chat", "gpt-4o"
                        ),
                    },
                },
                {
                    id = 3,
                    value = {
                        uri = "/redact/v1/responses",
                        plugins = stream_plugins(
                            "openai", "http://127.0.0.1:6726/responses", "gpt-4o"
                        ),
                    },
                },
                {
                    id = 4,
                    value = {
                        uri = "/redact/v1/messages",
                        plugins = stream_plugins(
                            "anthropic",
                            "http://127.0.0.1:6726/anthropic",
                            "claude-3-5-sonnet-20241022"
                        ),
                    },
                },
                {
                    id = 5,
                    value = {
                        uri = "/redact-stream-no-terminal",
                        plugins = stream_plugins(
                            "openai",
                            "http://127.0.0.1:6726/chat-no-terminal",
                            "gpt-4o"
                        ),
                    },
                },
                {
                    id = 6,
                    value = {
                        uri = "/redact-stream-incomplete",
                        plugins = stream_plugins(
                            "openai",
                            "http://127.0.0.1:6726/chat-incomplete",
                            "gpt-4o"
                        ),
                    },
                },
                {
                    id = 7,
                    value = {
                        uri = "/redact-stream-malformed",
                        plugins = stream_plugins(
                            "openai",
                            "http://127.0.0.1:6726/chat-malformed",
                            "gpt-4o"
                        ),
                    },
                },
                {
                    id = 8,
                    value = {
                        uri = "/raw/converse",
                        plugins = {
                            ["request-id"] = {
                                header_name = "X-Request-ID",
                                include_in_response = false,
                                algorithm = "uuid",
                            },
                            ["ai-proxy"] = {
                                provider = "bedrock",
                                auth = {aws = {
                                    access_key_id = "test-access-key",
                                    secret_access_key = "test-secret-key",
                                }},
                                provider_conf = {region = "us-east-1"},
                                options = {
                                    model =
                                        "anthropic.claude-3-5-sonnet-20241022-v2:0",
                                },
                                override = {
                                    endpoint =
                                        "http://127.0.0.1:6726/should-not-call",
                                },
                                ssl_verify = false,
                            },
                            ["bk-ai-sensitive-data-redaction"] = {
                                endpoint = "http://127.0.0.1:6725/redact",
                                ssl_verify = false,
                                keepalive = false,
                            },
                        },
                    },
                },
                {
                    id = 9,
                    value = {
                        uri = "/passthrough-stream",
                        plugins = stream_plugins(
                            "openai",
                            "http://127.0.0.1:6726/should-not-call",
                            "gpt-4o"
                        ),
                    },
                },
                {
                    id = 10,
                    value = {
                        uri = "/redact-stream-overflow",
                        plugins = stream_plugins(
                            "openai",
                            "http://127.0.0.1:6726/chat-overflow",
                            "gpt-4o"
                        ),
                    },
                },
                {
                    id = 11,
                    value = {
                        uri = "/redact-stream-metadata-overflow",
                        plugins = stream_plugins(
                            "openai",
                            "http://127.0.0.1:6726/chat-metadata-overflow",
                            "gpt-4o"
                        ),
                    },
                },
            }

            for _, route in ipairs(routes) do
                local code, body = t(
                    "/apisix/admin/routes/" .. route.id,
                    ngx.HTTP_PUT,
                    assert(core.json.encode(route.value))
                )
                assert(code < 300, "failed to configure streaming route")
            end
            ngx.say("passed")
        }
    }
--- response_body
passed



=== TEST 4: OpenAI Chat restores text and tool JSON across events and chunks
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local http = require("resty.http")
            local sse = require("apisix.plugins.ai-transport.sse")
            local request_id = "da584df5-7bd5-4590-98e0-8f92a89f9494"
            local phone = "13800138000"
            local response = assert(http.new():request_uri(
                "http://127.0.0.1:" .. ngx.var.server_port .. "/redact-stream", {
                    method = "POST",
                    keepalive = false,
                    headers = {
                        ["Content-Type"] = "application/json",
                        ["X-Request-ID"] = request_id,
                    },
                    body = assert(core.json.encode({
                        model = "gpt-4o",
                        stream = true,
                        messages = {{role = "user", content = "phone: " .. phone}},
                    })),
                }
            ))
            assert(response.status == 200, "unexpected response status")
            assert(
                not response.body:find("__BK_REDACT_", 1, true),
                "placeholder leaked"
            )

            local events = sse.decode(response.body)
            local text = ""
            local arguments = ""
            for _, event in ipairs(events) do
                if event.data ~= "[DONE]" then
                    local data = assert(core.json.decode(event.data))
                    local delta = data.choices[1].delta
                    text = text .. (delta.content or "")
                    local tool_calls = delta.tool_calls
                    if tool_calls then
                        arguments = arguments ..
                            tool_calls[1]["function"].arguments
                    end
                end
            end
            assert(text == "echo: " .. phone)
            assert(assert(core.json.decode(arguments)).phone == phone)
            assert(events[#events].data == "[DONE]")
            assert(
                ngx.shared["plugin-limit-conn"]:get("cleanup-" .. request_id) ==
                "2:0"
            )
            ngx.say("openai-chat-restored")
        }
    }
--- response_body
openai-chat-restored
--- no_error_log
13800138000
__BK_REDACT_



=== TEST 5: OpenAI Responses preserves metadata and restores function arguments
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local http = require("resty.http")
            local sse = require("apisix.plugins.ai-transport.sse")
            local request_id = "dddf9a86-4c1f-4a0b-99f5-76c667daf174"
            local phone = "13900139000"
            local response = assert(http.new():request_uri(
                "http://127.0.0.1:" .. ngx.var.server_port ..
                "/redact/v1/responses", {
                    method = "POST",
                    keepalive = false,
                    headers = {
                        ["Content-Type"] = "application/json",
                        ["X-Request-ID"] = request_id,
                    },
                    body = assert(core.json.encode({
                        model = "gpt-4o",
                        stream = true,
                        input = "phone: " .. phone,
                    })),
                }
            ))
            assert(response.status == 200, "unexpected response status")
            assert(not response.body:find("__BK_REDACT_", 1, true))

            local events = sse.decode(response.body)
            local text = {[0] = "", [1] = ""}
            for index = 1, 4 do
                assert(
                    events[index].type == "response.output_text.delta",
                    "unexpected text event type at " .. index
                )
                local data = assert(core.json.decode(events[index].data))
                assert(data.type == "response.output_text.delta", "data type changed")
                assert(data.item_id == "msg_1", "item ID changed")
                assert(data.output_index == 0, "output index changed")
                assert(
                    data.content_index == 0 or data.content_index == 1,
                    "content index changed"
                )
                text[data.content_index] = text[data.content_index] .. data.delta
            end
            local arguments_event = events[5]
            assert(
                arguments_event.type == "response.function_call_arguments.delta",
                "function event type changed"
            )
            local arguments_data = assert(core.json.decode(arguments_event.data))
            assert(arguments_data.item_id == "call_1", "function item ID changed")
            assert(arguments_data.output_index == 1, "function output index changed")
            assert(
                assert(core.json.decode(arguments_data.delta)).phone == phone,
                "function arguments were not restored"
            )
            assert(text[0] == phone, "first response part was not restored")
            assert(text[1] == phone, "second response part was not restored")
            assert(events[6].type == "response.completed", "terminal event changed")
            assert(
                assert(core.json.decode(events[6].data)).type == "response.completed",
                "terminal data changed"
            )
            local cleanup = ngx.shared["plugin-limit-conn"]:get(
                "cleanup-" .. request_id
            )
            assert(cleanup == "3:0", "unexpected cleanup counts: " .. tostring(cleanup))
            ngx.say("openai-responses-restored")
        }
    }
--- response_body
openai-responses-restored
--- no_error_log
13900139000
__BK_REDACT_



=== TEST 6: Anthropic Messages preserves event names and restores input JSON
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local http = require("resty.http")
            local sse = require("apisix.plugins.ai-transport.sse")
            local request_id = "12186e3f-5e09-4f89-b8d3-998976151c96"
            local phone = "13700137000"
            local response = assert(http.new():request_uri(
                "http://127.0.0.1:" .. ngx.var.server_port ..
                "/redact/v1/messages", {
                    method = "POST",
                    keepalive = false,
                    headers = {
                        ["Content-Type"] = "application/json",
                        ["X-Request-ID"] = request_id,
                    },
                    body = assert(core.json.encode({
                        model = "claude-3-5-sonnet-20241022",
                        max_tokens = 64,
                        stream = true,
                        messages = {{role = "user", content = "phone: " .. phone}},
                    })),
                }
            ))
            assert(response.status == 200, "unexpected response status")
            assert(
                not response.body:find("__BK_REDACT_", 1, true),
                "placeholder leaked"
            )

            local events = sse.decode(response.body)
            local text = ""
            for index = 1, 2 do
                assert(
                    events[index].type == "content_block_delta",
                    "unexpected text event type at " .. index
                )
                local data = assert(core.json.decode(events[index].data))
                assert(data.type == "content_block_delta", "data type changed")
                assert(data.index == 0, "content index changed")
                text = text .. data.delta.text
            end
            local input_event = assert(core.json.decode(events[3].data))
            assert(events[3].type == "content_block_delta", "input event type changed")
            assert(input_event.index == 1, "input index changed")
            assert(input_event.delta.type == "input_json_delta", "delta type changed")
            assert(
                assert(core.json.decode(input_event.delta.partial_json)).phone == phone,
                "input JSON was not restored"
            )
            assert(text == phone, "anthropic text was not restored")
            assert(events[4].type == "message_stop", "terminal event changed")
            assert(
                assert(core.json.decode(events[4].data)).type == "message_stop",
                "terminal data changed"
            )
            local cleanup = ngx.shared["plugin-limit-conn"]:get(
                "cleanup-" .. request_id
            )
            assert(cleanup == "2:0", "unexpected cleanup counts: " .. tostring(cleanup))
            ngx.say("anthropic-restored")
        }
    }
--- response_body
anthropic-restored
--- no_error_log
13700137000
__BK_REDACT_



=== TEST 7: concurrent and sequential requests keep request mappings isolated
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local http = require("resty.http")
            local state = ngx.shared["plugin-limit-conn"]
            local session_id = "24395b38-bf3f-426c-a632-10df20ec69c8"
            local request_id_1 = "b49d62d7-f3dc-4c9b-b08e-0a15325b30f2"
            local request_id_2 = "454380f9-3786-43e9-81ea-fdd320dceae1"
            local request_id_3 = "b02cb0e9-44ef-43c6-a9c6-feb7ed231865"
            local phone_1 = "13600136000"
            local phone_2 = "13500135000"
            local phone_3 = "13400134000"
            local before_calls = state:get("ai-redaction-call-count") or 0
            state:delete("ai-redaction-overlap-arrived")
            state:delete("ai-redaction-overlap-second-waiting")
            state:delete("ai-redaction-overlap-release-second")
            state:delete("ai-redaction-overlap-first-finished")
            state:delete("ai-redaction-overlap-second-finished")
            state:delete("cleanup-" .. request_id_1)
            state:delete("cleanup-" .. request_id_2)

            local function invoke(request_id, phone, overlap_role)
                local content = phone
                if overlap_role then
                    content = overlap_role .. " " .. content
                end
                return assert(http.new():request_uri(
                    "http://127.0.0.1:" .. ngx.var.server_port ..
                    "/redact-stream", {
                        method = "POST",
                        keepalive = false,
                        headers = {
                            ["Content-Type"] = "application/json",
                            ["X-Request-ID"] = request_id,
                            ["X-AI-Session-ID"] = session_id,
                        },
                        body = assert(core.json.encode({
                            model = "gpt-4o",
                            stream = true,
                            messages = {{role = "user", content = content}},
                        })),
                    }
                ))
            end

            local thread1 = ngx.thread.spawn(
                invoke, request_id_1, phone_1, "overlap-first"
            )
            local thread2 = ngx.thread.spawn(
                invoke, request_id_2, phone_2, "overlap-second"
            )
            local ok1, response1 = ngx.thread.wait(thread1)
            assert(ok1)
            assert(state:get("ai-redaction-overlap-arrived") == 2)
            assert(state:get("ai-redaction-overlap-second-waiting") == 1)
            assert(state:get("ai-redaction-overlap-first-finished") == 1)
            assert(state:get("ai-redaction-overlap-second-finished") == nil)
            assert(state:get("session-" .. request_id_1) == session_id)
            assert(state:get("session-" .. request_id_2) == session_id)
            assert(
                state:get("namespace-" .. request_id_1) ~=
                state:get("namespace-" .. request_id_2)
            )
            assert(state:get("cleanup-" .. request_id_1) == "2:0")
            assert(state:get("cleanup-" .. request_id_2) == nil)
            state:set("ai-redaction-overlap-release-second", 1)
            local ok2, response2 = ngx.thread.wait(thread2)
            assert(ok2)
            assert(state:get("ai-redaction-overlap-second-finished") == 1)
            assert(response1.status == 200, "first concurrent request failed")
            assert(response2.status == 200, "second concurrent request failed")
            assert(response1.body:find(phone_1, 1, true))
            assert(not response1.body:find(phone_2, 1, true))
            assert(response2.body:find(phone_2, 1, true))
            assert(not response2.body:find(phone_1, 1, true))
            assert(not response1.body:find("__BK_REDACT_", 1, true))
            assert(not response2.body:find("__BK_REDACT_", 1, true))

            local response3 = invoke(request_id_3, phone_3)
            assert(response3.status == 200, "sequential request failed")
            assert(response3.body:find(phone_3, 1, true))
            assert(not response3.body:find(phone_1, 1, true))
            assert(not response3.body:find(phone_2, 1, true))
            assert(not response3.body:find("__BK_REDACT_", 1, true))

            assert(state:get("session-" .. request_id_1) == session_id)
            assert(state:get("session-" .. request_id_2) == session_id)
            assert(state:get("session-" .. request_id_3) == session_id)
            local namespace1 = state:get("namespace-" .. request_id_1)
            local namespace2 = state:get("namespace-" .. request_id_2)
            local namespace3 = state:get("namespace-" .. request_id_3)
            assert(namespace1 ~= namespace2)
            assert(namespace1 ~= namespace3)
            assert(namespace2 ~= namespace3)
            assert(state:get("ai-redaction-call-count") == before_calls + 3)
            assert(state:get("cleanup-" .. request_id_1) == "2:0")
            assert(state:get("cleanup-" .. request_id_2) == "2:0")
            assert(state:get("cleanup-" .. request_id_3) == "2:0")
            ngx.say("request-isolation-preserved")
        }
    }
--- response_body
request-isolation-preserved
--- no_error_log
13600136000
13500135000
13400134000
__BK_REDACT_



=== TEST 8: EOF finalizes state and malformed frames recover fail-closed
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local http = require("resty.http")
            local state = ngx.shared["plugin-limit-conn"]

            local function invoke(path, request_id, phone)
                return assert(http.new():request_uri(
                    "http://127.0.0.1:" .. ngx.var.server_port .. path, {
                        method = "POST",
                        keepalive = false,
                        headers = {
                            ["Content-Type"] = "application/json",
                            ["X-Request-ID"] = request_id,
                        },
                        body = assert(core.json.encode({
                            model = "gpt-4o",
                            stream = true,
                            messages = {{role = "user", content = phone}},
                        })),
                    }
                ))
            end

            local no_terminal_id = "0deff9d6-48fc-46dc-a95c-28c18376986f"
            local no_terminal_phone = "13300133000"
            local no_terminal = invoke(
                "/redact-stream-no-terminal",
                no_terminal_id,
                no_terminal_phone
            )
            assert(no_terminal.status == 200, "no-terminal request failed")
            assert(no_terminal.body:find(no_terminal_phone, 1, true))
            assert(not no_terminal.body:find("[DONE]", 1, true))
            assert(not no_terminal.body:find("__BK_REDACT_", 1, true))
            assert(state:get("cleanup-" .. no_terminal_id) == "1:0")

            local incomplete_id = "f84e0370-339b-4bd4-90ef-1e08ceee1482"
            local incomplete_phone = "13200132000"
            local incomplete = invoke(
                "/redact-stream-incomplete", incomplete_id, incomplete_phone
            )
            assert(incomplete.status == 200, "incomplete-prefix request failed")
            local incomplete_namespace = state:get("namespace-" .. incomplete_id)
            assert(incomplete.body:find(incomplete_namespace .. "1", 1, true))
            assert(not incomplete.body:find(incomplete_phone, 1, true))
            assert(state:get("cleanup-" .. incomplete_id) == "0:1")

            local malformed_id = "518e2cd5-1e70-47f8-b0be-713614ca4df8"
            local malformed_phone = "13100131000"
            local malformed = invoke(
                "/redact-stream-malformed", malformed_id, malformed_phone
            )
            assert(malformed.status == 200, "malformed-frame request failed")
            local malformed_token = state:get("namespace-" .. malformed_id) .. "1__"
            assert(malformed.body:find(
                "data: {\"broken\":\"" .. malformed_token .. "\"\n\n",
                1,
                true
            ))
            assert(malformed.body:find(malformed_phone, 1, true))
            assert(state:get("cleanup-" .. malformed_id) == "1:0")
            ngx.say("eof-and-malformed-safe")
        }
    }
--- response_body
eof-and-malformed-safe
--- no_error_log
13300133000
13200132000
13100131000



=== TEST 9: raw EventStream and passthrough streaming reject before calls
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local http = require("resty.http")
            local state = ngx.shared["plugin-limit-conn"]
            local bedrock_id = "ae2208a5-4341-486f-a3f5-f894a22cf499"
            local passthrough_id = "79f5595e-1405-4287-91cc-085a55293b2e"
            state:delete("namespace-" .. bedrock_id)
            state:delete("namespace-" .. passthrough_id)
            state:set("ai-llm-rejected-call-count", 0)

            local bedrock = assert(http.new():request_uri(
                "http://127.0.0.1:" .. ngx.var.server_port .. "/raw/converse", {
                    method = "POST",
                    keepalive = false,
                    headers = {
                        ["Content-Type"] = "application/json",
                        ["X-Request-ID"] = bedrock_id,
                    },
                    body = assert(core.json.encode({
                        model = "anthropic.claude-3-5-sonnet-20241022-v2:0",
                        stream = true,
                        messages = {{
                            role = "user",
                            content = {{text = "phone: 13000130000"}},
                        }},
                    })),
                }
            ))
            assert(bedrock.status == 400, "raw EventStream request was not rejected")
            assert(bedrock.body:find("bedrock-converse", 1, true))

            local passthrough = assert(http.new():request_uri(
                "http://127.0.0.1:" .. ngx.var.server_port ..
                "/passthrough-stream", {
                    method = "POST",
                    keepalive = false,
                    headers = {
                        ["Content-Type"] = "application/json",
                        ["X-Request-ID"] = passthrough_id,
                    },
                    body = assert(core.json.encode({
                        model = "custom-model",
                        stream = true,
                        prompt = "phone: 12900129000",
                    })),
                }
            ))
            assert(
                passthrough.status == 400,
                "passthrough streaming request was not rejected"
            )
            assert(passthrough.body:find("passthrough", 1, true))
            assert(state:get("namespace-" .. bedrock_id) == nil)
            assert(state:get("namespace-" .. passthrough_id) == nil)
            assert(state:get("ai-llm-rejected-call-count") == 0)
            ngx.say("unsupported-streams-rejected")
        }
    }
--- response_body
unsupported-streams-rejected
--- no_error_log
13000130000
12900129000
__BK_REDACT_



=== TEST 10: streaming state overflow latches masked passthrough
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local http = require("resty.http")
            local state = ngx.shared["plugin-limit-conn"]
            local request_id = "21739770-bcc7-44c4-94ee-d3932c16d80b"
            local phone = "12800128000"
            local response = assert(http.new():request_uri(
                "http://127.0.0.1:" .. ngx.var.server_port ..
                "/redact-stream-overflow", {
                    method = "POST",
                    keepalive = false,
                    headers = {
                        ["Content-Type"] = "application/json",
                        ["X-Request-ID"] = request_id,
                    },
                    body = assert(core.json.encode({
                        model = "gpt-4o",
                        stream = true,
                        messages = {{role = "user", content = "phone: " .. phone}},
                    })),
                }
            ))
            assert(response.status == 200, "overflow request failed")
            assert(not response.body:find(phone, 1, true), "original leaked")
            local namespace = state:get("namespace-" .. request_id)
            assert(namespace, "missing request namespace")
            assert(
                response.body:find(namespace .. "1_", 1, true),
                "masked prefix was not preserved"
            )
            local cleanup = state:get("cleanup-" .. request_id)
            assert(cleanup, "overflow state was not cleared")
            assert(cleanup ~= "0:1025", "overflow was deferred until EOF")
            ngx.say("stream-overflow-masked")
        }
    }
--- response_body
stream-overflow-masked
--- error_log
failed to restore masked SSE response
--- no_error_log
12800128000



=== TEST 11: streaming metadata overflow latches masked passthrough
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local http = require("resty.http")
            local state = ngx.shared["plugin-limit-conn"]
            local request_id = "61e064bd-398c-4770-83da-f2e2c76ef619"
            local phone = "12700127000"
            local response = assert(http.new():request_uri(
                "http://127.0.0.1:" .. ngx.var.server_port ..
                "/redact-stream-metadata-overflow", {
                    method = "POST",
                    keepalive = false,
                    headers = {
                        ["Content-Type"] = "application/json",
                        ["X-Request-ID"] = request_id,
                    },
                    body = assert(core.json.encode({
                        model = "gpt-4o",
                        stream = true,
                        messages = {{role = "user", content = "phone: " .. phone}},
                    })),
                }
            ))
            assert(response.status == 200, "metadata overflow request failed")
            assert(not response.body:find(phone, 1, true), "original leaked")
            local namespace = state:get("namespace-" .. request_id)
            assert(namespace, "missing request namespace")
            assert(
                response.body:find(namespace .. "1_", 1, true),
                "masked prefix was not preserved"
            )
            assert(state:get("cleanup-" .. request_id), "overflow state was not cleared")
            ngx.say("stream-metadata-overflow-masked")
        }
    }
--- response_body
stream-metadata-overflow-masked
--- error_log
failed to restore masked SSE response
--- no_error_log
12700127000
