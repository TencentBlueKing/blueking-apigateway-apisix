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
            listen 6727;

            location /redact {
                content_by_lua_block {
                    local core = require("apisix.core")
                    ngx.req.read_body()
                    local payload = assert(core.json.decode(ngx.req.get_body_data()))
                    assert(type(payload.body) == "string")
                    local raw = payload.body
                    local body = assert(core.json.decode(raw))
                    local content = body.messages[1].content
                    local namespace = payload.placeholder_namespace
                    local replacements = {}
                    local state = ngx.shared["plugin-limit-conn"]
                    state:incr("final-redactor-calls", 1, 0)

                    if content == "override-secret" then
                        assert(body.model == "options-model")
                        assert(body.max_completion_tokens == 111)
                        assert(body.metadata.source == "override-secret")
                        local message_token = namespace .. "1__"
                        body.messages[1].content = message_token
                        body.metadata.source = message_token
                        raw = assert(core.json.encode(body))
                        replacements = {
                            {placeholder = message_token, original = "override-secret"},
                        }

                    elseif content == "numeric-control" then
                        state:set("numeric-redactor-raw", raw)

                    elseif content == "first-secret" then
                        assert(body.model == "first-model")
                        local token = namespace .. "1__"
                        body.messages[1].content = token
                        raw = assert(core.json.encode(body))
                        replacements = {{placeholder = token, original = content}}

                    elseif content == "second-secret" then
                        assert(body.model == "second-model")
                        local token = namespace .. "2__"
                        body.messages[1].content = token
                        raw = assert(core.json.encode(body))
                        replacements = {{placeholder = token, original = content}}

                    else
                        error("unexpected finalized content")
                    end

                    if #replacements == 0 then
                        setmetatable(replacements, core.json.array_mt)
                    end
                    ngx.header.content_type = "application/json"
                    ngx.print(assert(core.json.encode({
                        body = raw,
                        replacements = replacements,
                    })))
                }
            }

            location /fail {
                content_by_lua_block {
                    ngx.shared["plugin-limit-conn"]:incr(
                        "failed-redactor-calls", 1, 0
                    )
                    ngx.status = 500
                    ngx.say("redactor unavailable")
                }
            }
        }

        server {
            listen 6728;

            location / {
                content_by_lua_block {
                    local core = require("apisix.core")
                    ngx.req.read_body()
                    local raw = ngx.req.get_body_data()
                    local body = assert(core.json.decode(raw))
                    local content = body.messages[1].content
                    assert(body.model == "first-model")
                    assert(content:find("__BK_REDACT_", 1, true))
                    assert(not raw:find("first-secret", 1, true))
                    ngx.shared["plugin-limit-conn"]:incr("first-llm-calls", 1, 0)
                    ngx.status = 500
                    ngx.header.content_type = "application/json"
                    ngx.say('{"error":{"message":"retryable"}}')
                }
            }
        }

        server {
            listen 6729;

            location / {
                content_by_lua_block {
                    local core = require("apisix.core")
                    ngx.req.read_body()
                    local raw = ngx.req.get_body_data()
                    local body = assert(core.json.decode(raw))
                    local content = body.messages[1].content
                    local response_content

                    if body.model == "options-model" then
                        assert(body.max_completion_tokens == 111)
                        assert(not raw:find("client-secret", 1, true))
                        assert(not raw:find("override-secret", 1, true))
                        assert(content:find("__BK_REDACT_", 1, true))
                        assert(body.metadata.source:find("__BK_REDACT_", 1, true))
                        response_content = content .. ":" .. body.metadata.source

                    elseif body.model == "numeric-model" then
                        ngx.shared["plugin-limit-conn"]:set("numeric-llm-raw", raw)
                        response_content = "numeric-ok"

                    elseif body.model == "second-model" then
                        assert(content:find("_2__", 1, true))
                        assert(not raw:find("first-secret", 1, true))
                        assert(not raw:find("second-secret", 1, true))
                        ngx.shared["plugin-limit-conn"]:incr("second-llm-calls", 1, 0)
                        response_content = content

                    else
                        error("unexpected LLM model")
                    end

                    ngx.header.content_type = "application/json"
                    ngx.print(assert(core.json.encode({
                        id = "chatcmpl-final-filter",
                        object = "chat.completion",
                        choices = {{
                            index = 0,
                            message = {role = "assistant", content = response_content},
                            finish_reason = "stop",
                        }},
                        usage = {
                            prompt_tokens = 1,
                            completion_tokens = 1,
                            total_tokens = 2,
                        },
                    })))
                }
            }
        }

        server {
            listen 6730;

            location / {
                content_by_lua_block {
                    ngx.shared["plugin-limit-conn"]:incr("forbidden-llm-calls", 1, 0)
                    ngx.status = 500
                }
            }
        }
_EOC_
    $block->set_value("http_config", $http_config);
});

run_tests;

__DATA__

=== TEST 1: final-body filter observes all provider overrides and isolates attempts
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local base = require("apisix.plugins.ai-providers.base")
            local provider = base.new({
                capabilities = {
                    ["openai-chat"] = {
                        path = "/v1/chat/completions",
                        host = "localhost",
                        rewrite_request_body = function(body, override)
                            for key, value in pairs(override) do
                                body[key] = value
                            end
                        end,
                    },
                },
            })
            local request_body = {
                model = "client-model",
                stream = false,
                messages = {{role = "user", content = "client-secret"}},
            }
            local seen = {}
            local ctx = {
                ai_target_protocol = "openai-chat",
                var = {},
                ai_final_request_body_filter = function(raw_body)
                    seen[#seen + 1] = raw_body
                    local body = assert(core.json.decode(raw_body))
                    body.messages[1].content = "masked"
                    return assert(core.json.encode(body))
                end,
            }
            local opts = {
                auth = {},
                conf = {},
                target_path = "/v1/chat/completions",
                model_options = {
                    model = "options-model",
                    option_secret = "option-secret",
                },
                override_llm_options = {llm_secret = "llm-secret"},
                request_body_override_map = {
                    ["openai-chat"] = {
                        request_secret = "request-secret",
                        messages = {{role = "user", content = "override-secret"}},
                    },
                },
                request_body_force_override = true,
            }

            local params = assert(provider:build_request(
                ctx, {ssl_verify = false}, request_body, opts
            ))
            local finalized = assert(core.json.decode(seen[1]))
            assert(finalized.model == "options-model")
            assert(finalized.option_secret == "option-secret")
            assert(finalized.llm_secret == "llm-secret")
            assert(finalized.request_secret == "request-secret")
            assert(finalized.messages[1].content == "override-secret")
            assert(assert(core.json.decode(params.body)).messages[1].content == "masked")
            assert(request_body.model == "client-model")
            assert(request_body.messages[1].content == "client-secret")

            opts.model_options.model = "second-model"
            opts.request_body_override_map["openai-chat"].messages[1].content =
                "second-secret"
            assert(provider:build_request(ctx, {ssl_verify = false}, request_body, opts))
            local second = assert(core.json.decode(seen[2]))
            assert(second.model == "second-model")
            assert(second.messages[1].content == "second-secret")
            assert(request_body.model == "client-model")
            assert(request_body.messages[1].content == "client-secret")
            ngx.say("final-overrides-isolated")
        }
    }
--- response_body
final-overrides-isolated



=== TEST 2: untouched raw JSON numeric lexemes reach the filter and transport unchanged
--- config
    location /t {
        content_by_lua_block {
            local base = require("apisix.plugins.ai-providers.base")
            local provider = base.new({capabilities = {}})
            local raw = '{"model":"gpt-4o","large":9007199254740993,' ..
                        '"long":123456789012345678901234567890,' ..
                        '"negative_zero":-0,"exponent":1.2300e+40,' ..
                        '"messages":[{"role":"user","content":"secret"}]}'
            local seen
            local ctx = {
                ai_target_protocol = "openai-chat",
                ai_raw_request_body = raw,
                var = {},
                ai_final_request_body_filter = function(body)
                    seen = body
                    local masked = body:gsub("secret", "masked", 1)
                    return masked
                end,
            }
            local params = assert(provider:build_request(
                ctx,
                {ssl_verify = false},
                {model = "gpt-4o", messages = {{role = "user", content = "secret"}}},
                {auth = {}, conf = {}, target_path = "/v1/chat/completions"}
            ))

            assert(seen == raw)
            assert(params.body == raw:gsub("secret", "masked", 1))
            assert(params.body:find("9007199254740993", 1, true))
            assert(params.body:find("123456789012345678901234567890", 1, true))
            assert(params.body:find("-0", 1, true))
            assert(params.body:find("1.2300e+40", 1, true))
            ngx.say("numeric-lexemes-preserved")
        }
    }
--- response_body
numeric-lexemes-preserved



=== TEST 3: SigV4 signs the filtered AWS serialization
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local base = require("apisix.plugins.ai-providers.base")
            local old_auth_aws = package.loaded["apisix.plugins.ai-transport.auth-aws"]
            local signed_body
            package.loaded["apisix.plugins.ai-transport.auth-aws"] = {
                sign_request = function(params)
                    signed_body = params.body
                end,
            }

            local ok, err = xpcall(function()
                local provider = base.new({
                    aws_sigv4 = true,
                    remove_model = true,
                    capabilities = {},
                })
                local filtered = '{"messages":[{"content":[{"text":"masked"}],' ..
                                 '"role":"user"}]}'
                local seen
                local ctx = {
                    ai_target_protocol = "bedrock-converse",
                    var = {},
                    ai_final_request_body_filter = function(body)
                        seen = body
                        return filtered
                    end,
                }
                local params = assert(provider:build_request(
                    ctx,
                    {ssl_verify = false},
                    {
                        model = "bedrock-model",
                        messages = {{
                            role = "user",
                            content = {{text = "secret"}},
                        }},
                    },
                    {
                        auth = {aws = {
                            access_key_id = "test",
                            secret_access_key = "test",
                        }},
                        conf = {region = "us-east-1"},
                        target_path = "/model/bedrock-model/converse",
                    }
                ))

                local serialized = assert(core.json.decode(seen))
                assert(serialized.model == nil)
                assert(serialized.messages[1].content[1].text == "secret")
                assert(signed_body == filtered)
                assert(params.body == filtered)
            end, debug.traceback)

            package.loaded["apisix.plugins.ai-transport.auth-aws"] = old_auth_aws
            assert(ok, err)
            ngx.say("filtered-body-signed")
        }
    }
--- response_body
filtered-body-signed



=== TEST 4: callback exceptions and invalid returns fail generically and non-retryably
--- config
    location /t {
        content_by_lua_block {
            local base = require("apisix.plugins.ai-providers.base")
            local provider = base.new({capabilities = {}})

            local function build(callback)
                local picker = {}
                local ctx = {
                    ai_target_protocol = "openai-chat",
                    ai_request_body_changed = true,
                    ai_final_request_body_filter = callback,
                    server_picker = picker,
                    var = {},
                }
                local params, err, status = provider:build_request(
                    ctx,
                    {ssl_verify = false},
                    {messages = {{role = "user", content = "secret"}}},
                    {auth = {}, conf = {}, target_path = "/v1/chat/completions"}
                )
                assert(params == nil)
                assert(type(err) == "table")
                assert(err.message == "failed to filter final AI request body")
                assert(status == 500)
                assert(ctx.server_picker == nil)
            end

            build(function()
                error("secret must not be copied to an error")
            end)
            build(function()
                return {}
            end)
            ngx.say("callback-failures-contained")
        }
    }
--- response_body
callback-failures-contained
--- no_error_log
secret must not be copied to an error



=== TEST 5: routes without a callback retain table transport behavior
--- config
    location /t {
        content_by_lua_block {
            local base = require("apisix.plugins.ai-providers.base")
            local provider = base.new({capabilities = {}})
            local request_body = {
                model = "gpt-4o",
                messages = {{role = "user", content = "unchanged"}},
            }
            local params = assert(provider:build_request(
                {ai_target_protocol = "openai-chat", var = {}},
                {ssl_verify = false},
                request_body,
                {
                    auth = {},
                    conf = {},
                    target_path = "/v1/chat/completions",
                    model_options = {temperature = 0.5},
                }
            ))
            assert(type(params.body) == "table")
            assert(params.body == request_body)
            ngx.say("legacy-route-unchanged")
        }
    }
--- response_body
legacy-route-unchanged



=== TEST 6: configure finalized-body integration routes
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local t = require("lib.test_admin").test
            local state = ngx.shared["plugin-limit-conn"]
            for _, key in ipairs({
                "final-redactor-calls",
                "numeric-redactor-raw",
                "numeric-llm-raw",
                "first-llm-calls",
                "second-llm-calls",
                "failed-redactor-calls",
                "forbidden-llm-calls",
            }) do
                state:delete(key)
            end

            local redaction = {
                endpoint = "http://127.0.0.1:6727/redact",
                ssl_verify = false,
                keepalive = false,
            }
            local routes = {
                {
                    id = 20,
                    value = {
                        uri = "/final-overrides",
                        plugins = {
                            ["ai-proxy"] = {
                                provider = "openai",
                                auth = {header = {Authorization = "Bearer test"}},
                                options = {model = "options-model"},
                                override = {
                                    endpoint = "http://127.0.0.1:6729",
                                    llm_options = {max_tokens = 111},
                                    request_body = {
                                        ["openai-chat"] = {
                                            messages = {{
                                                role = "user",
                                                content = "override-secret",
                                            }},
                                            metadata = {source = "override-secret"},
                                        },
                                    },
                                    request_body_force_override = true,
                                },
                                ssl_verify = false,
                            },
                            ["bk-ai-sensitive-data-redaction"] = redaction,
                        },
                    },
                },
                {
                    id = 21,
                    value = {
                        uri = "/numeric-lexemes",
                        plugins = {
                            ["ai-proxy"] = {
                                provider = "openai",
                                auth = {header = {Authorization = "Bearer test"}},
                                override = {endpoint = "http://127.0.0.1:6729"},
                                ssl_verify = false,
                            },
                            ["bk-ai-sensitive-data-redaction"] = redaction,
                        },
                    },
                },
                {
                    id = 22,
                    value = {
                        uri = "/multi-fallback",
                        plugins = {
                            ["ai-proxy-multi"] = {
                                fallback_strategy = {"http_5xx"},
                                balancer = {algorithm = "roundrobin"},
                                instances = {
                                    {
                                        name = "first",
                                        provider = "openai",
                                        priority = 10,
                                        weight = 1,
                                        auth = {header = {Authorization = "Bearer test"}},
                                        options = {model = "first-model"},
                                        override = {
                                            endpoint = "http://127.0.0.1:6728",
                                            request_body = {[
                                                "openai-chat"
                                            ] = {messages = {{
                                                role = "user",
                                                content = "first-secret",
                                            }}}},
                                            request_body_force_override = true,
                                        },
                                    },
                                    {
                                        name = "second",
                                        provider = "openai",
                                        priority = 0,
                                        weight = 1,
                                        auth = {header = {Authorization = "Bearer test"}},
                                        options = {model = "second-model"},
                                        override = {
                                            endpoint = "http://127.0.0.1:6729",
                                            request_body = {[
                                                "openai-chat"
                                            ] = {messages = {{
                                                role = "user",
                                                content = "second-secret",
                                            }}}},
                                            request_body_force_override = true,
                                        },
                                    },
                                },
                                ssl_verify = false,
                            },
                            ["bk-ai-sensitive-data-redaction"] = redaction,
                        },
                    },
                },
                {
                    id = 23,
                    value = {
                        uri = "/multi-redactor-failure",
                        plugins = {
                            ["ai-proxy-multi"] = {
                                fallback_strategy = {"http_5xx"},
                                balancer = {algorithm = "roundrobin"},
                                instances = {
                                    {
                                        name = "forbidden-first",
                                        provider = "openai",
                                        priority = 10,
                                        weight = 1,
                                        auth = {header = {Authorization = "Bearer test"}},
                                        options = {model = "first-model"},
                                        override = {endpoint = "http://127.0.0.1:6730"},
                                    },
                                    {
                                        name = "forbidden-second",
                                        provider = "openai",
                                        priority = 0,
                                        weight = 1,
                                        auth = {header = {Authorization = "Bearer test"}},
                                        options = {model = "second-model"},
                                        override = {endpoint = "http://127.0.0.1:6730"},
                                    },
                                },
                                ssl_verify = false,
                            },
                            ["bk-ai-sensitive-data-redaction"] = {
                                endpoint = "http://127.0.0.1:6727/fail",
                                ssl_verify = false,
                                keepalive = false,
                            },
                        },
                    },
                },
            }

            for _, route in ipairs(routes) do
                local code, body = t(
                    "/apisix/admin/routes/" .. route.id,
                    ngx.HTTP_PUT,
                    assert(core.json.encode(route.value))
                )
                assert(code < 300, body)
            end
            ngx.say("routes-configured")
        }
    }
--- response_body
routes-configured



=== TEST 7: redactor and LLM observe finalized overrides and identical numeric lexemes
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local http = require("resty.http")
            local base_url = "http://127.0.0.1:" .. ngx.var.server_port
            local final = assert(http.new():request_uri(base_url .. "/final-overrides", {
                method = "POST",
                keepalive = false,
                headers = {["Content-Type"] = "application/json"},
                body = assert(core.json.encode({
                    model = "client-model",
                    stream = false,
                    messages = {{role = "user", content = "client-secret"}},
                })),
            }))
            assert(final.status == 200, final.body)
            local final_body = assert(core.json.decode(final.body))
            assert(
                final_body.choices[1].message.content ==
                "override-secret:override-secret"
            )
            assert(not final.body:find("__BK_REDACT_", 1, true))

            local numeric_raw =
                '{"model":"numeric-model","stream":false,' ..
                '"large":9007199254740993,' ..
                '"long":123456789012345678901234567890,' ..
                '"negative_zero":-0,"exponent":1.2300e+40,' ..
                '"messages":[{"role":"user","content":"numeric-control"}]}'
            local numeric = assert(http.new():request_uri(base_url .. "/numeric-lexemes", {
                method = "POST",
                keepalive = false,
                headers = {["Content-Type"] = "application/json"},
                body = numeric_raw,
            }))
            assert(numeric.status == 200, numeric.body)
            local state = ngx.shared["plugin-limit-conn"]
            local redactor_raw = state:get("numeric-redactor-raw")
            local llm_raw = state:get("numeric-llm-raw")
            assert(redactor_raw == numeric_raw)
            assert(llm_raw == numeric_raw)
            for _, lexeme in ipairs({
                "9007199254740993",
                "123456789012345678901234567890",
                "-0",
                "1.2300e+40",
            }) do
                assert(redactor_raw:find(lexeme, 1, true))
                assert(llm_raw:find(lexeme, 1, true))
            end
            ngx.say("final-and-numeric-observed")
        }
    }
--- response_body
final-and-numeric-observed



=== TEST 8: retryable LLM failure re-filters second attempt and restores newest mapping
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local response = assert(require("resty.http").new():request_uri(
                "http://127.0.0.1:" .. ngx.var.server_port .. "/multi-fallback", {
                    method = "POST",
                    keepalive = false,
                    headers = {["Content-Type"] = "application/json"},
                    body = assert(core.json.encode({
                        model = "client-model",
                        stream = false,
                        messages = {{role = "user", content = "client-secret"}},
                    })),
                }
            ))
            assert(
                response.status == 200,
                "unexpected multi status " .. response.status .. ": " .. response.body
            )
            local body = assert(core.json.decode(response.body))
            assert(body.choices[1].message.content == "second-secret")
            assert(not response.body:find("first-secret", 1, true))
            assert(not response.body:find("__BK_REDACT_", 1, true))
            local state = ngx.shared["plugin-limit-conn"]
            assert(state:get("first-llm-calls") == 1)
            assert(state:get("second-llm-calls") == 1)
            assert(state:get("final-redactor-calls") == 2)
            ngx.say("multi-fallback-restored")
        }
    }
--- response_body
multi-fallback-restored



=== TEST 9: redactor 502 is returned without an LLM call or fallback
--- config
    location /t {
        content_by_lua_block {
            local core = require("apisix.core")
            local response = assert(require("resty.http").new():request_uri(
                "http://127.0.0.1:" .. ngx.var.server_port ..
                "/multi-redactor-failure", {
                    method = "POST",
                    keepalive = false,
                    headers = {["Content-Type"] = "application/json"},
                    body = assert(core.json.encode({
                        model = "client-model",
                        stream = false,
                        messages = {{role = "user", content = "secret"}},
                    })),
                }
            ))
            assert(response.status == 502, response.body)
            local state = ngx.shared["plugin-limit-conn"]
            assert(state:get("failed-redactor-calls") == 1)
            assert((state:get("forbidden-llm-calls") or 0) == 0)
            ngx.say("redactor-failure-not-retried")
        }
    }
--- response_body
redactor-failure-not-retried
