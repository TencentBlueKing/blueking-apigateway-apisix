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
                assert(payload.body.messages[1].content == "phone: 13800138000")
                local token = payload.placeholder_namespace .. "1__"
                payload.body.messages[1].content = "phone: " .. token
                ngx.header.content_type = "application/json"
                ngx.print(assert(core.json.encode({
                    body = payload.body,
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
