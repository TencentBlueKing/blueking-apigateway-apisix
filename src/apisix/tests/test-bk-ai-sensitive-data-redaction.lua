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
local http = require("resty.http")
local plugin = require("apisix.plugins.bk-ai-sensitive-data-redaction")


describe(
    "bk-ai-sensitive-data-redaction", function()
        local behavior
        local observed
        local request_body
        local request_headers
        local installed_body

        local function config(overrides)
            local conf = {
                endpoint = "https://redaction.example.com/v1/redact?tenant=blueking",
                auth_header = "X-Redaction-Token",
                auth_value = "secret-token",
                session_id_header = "X-AI-Session-Id",
                timeout = 3000,
                ssl_verify = true,
                keepalive = true,
                keepalive_pool = 30,
                keepalive_timeout = 60000,
                max_request_body_bytes = 1048576,
                max_mapping_entries = 1000,
                max_mapping_bytes = 1048576,
            }
            for key, value in pairs(overrides or {}) do
                conf[key] = value
            end
            return conf
        end

        local function request_context(overrides)
            local ctx = CTX({
                uri = "/v1/chat/completions",
                request_type = "ai_chat",
            })
            ctx.picked_ai_instance = {provider = "openai"}
            ctx.ai_client_protocol = "openai-chat"
            for key, value in pairs(overrides or {}) do
                if key == "var" then
                    for var_name, var_value in pairs(value) do
                        ctx.var[var_name] = var_value
                    end
                else
                    ctx[key] = value
                end
            end
            return ctx
        end

        local function success_value(payload)
            local masked_body = assert(core.json.decode(assert(core.json.encode(payload.body))))
            local token = payload.placeholder_namespace .. "1__"
            masked_body.messages[1].content = "phone: " .. token
            return {
                body = masked_body,
                replacements = {
                    {
                        placeholder = token,
                        original = "13800138000",
                    },
                },
            }
        end

        local function success_response(payload)
            return assert(core.json.encode(success_value(payload)))
        end

        local function assert_no_request_mutation()
            assert.is_nil(installed_body)
            assert.stub(ngx.req.set_body_data).was_not_called()
        end

        before_each(
            function()
                request_body = {
                    model = "gpt-4o",
                    stream = false,
                    messages = {
                        {
                            role = "user",
                            content = "phone: 13800138000",
                        },
                    },
                    metadata = {source = "final-client-body"},
                }
                request_headers = {}
                installed_body = nil
                behavior = {
                    connect_ok = true,
                    response_status = 200,
                    response_builder = success_response,
                }
                observed = {
                    new_count = 0,
                    connect_count = 0,
                    request_count = 0,
                    read_count = 0,
                    keepalive_count = 0,
                    close_count = 0,
                }

                stub(
                    core.request, "get_json_request_body_table", function(max_size)
                        observed.body_limit = max_size
                        if behavior.body_error then
                            return nil, behavior.body_error
                        end
                        return request_body
                    end
                )
                stub(
                    core.request, "header", function(_, name)
                        return request_headers[name]
                    end
                )
                stub(
                    ngx.req, "set_body_data", function(body)
                        installed_body = body
                    end
                )
                stub(
                    http, "new", function()
                        observed.new_count = observed.new_count + 1
                        return {
                            set_timeout = function(_, timeout)
                                observed.timeout = timeout
                            end,
                            connect = function(_, options)
                                observed.connect_count = observed.connect_count + 1
                                observed.connect_options = options
                                return behavior.connect_ok, behavior.connect_error
                            end,
                            request = function(_, options)
                                observed.request_count = observed.request_count + 1
                                observed.request_options = options
                                if behavior.request_error then
                                    return nil, behavior.request_error
                                end

                                observed.payload = assert(core.json.decode(options.body))
                                local raw = behavior.response_builder(observed.payload)
                                return {
                                    status = behavior.response_status,
                                    read_body = function()
                                        observed.read_count = observed.read_count + 1
                                        if behavior.read_error then
                                            return nil, behavior.read_error
                                        end
                                        return raw
                                    end,
                                }
                            end,
                            set_keepalive = function(_, timeout, pool)
                                observed.keepalive_count = observed.keepalive_count + 1
                                observed.keepalive_timeout = timeout
                                observed.keepalive_pool = pool
                                return behavior.keepalive_ok ~= false,
                                       behavior.keepalive_error
                            end,
                            close = function()
                                observed.close_count = observed.close_count + 1
                            end,
                        }
                    end
                )
            end
        )

        after_each(
            function()
                core.request.get_json_request_body_table:revert()
                core.request.header:revert()
                ngx.req.set_body_data:revert()
                http.new:revert()
            end
        )

        context(
            "schema", function()
                it(
                    "accepts the complete safe configuration", function()
                        local ok, err = plugin.check_schema(config())

                        assert.is_true(ok)
                        assert.is_nil(err)
                        assert.is_equal("bk-ai-sensitive-data-redaction", plugin.name)
                        assert.is_equal(1039, plugin.priority)
                        assert.is_same({"auth_value"}, plugin.schema.encrypt_fields)
                    end
                )

                for _, case in ipairs({
                    {
                        name = "a non-HTTP endpoint",
                        conf = {endpoint = "ftp://redaction.example.com/v1/redact"},
                    },
                    {
                        name = "an endpoint without a host",
                        conf = {endpoint = "https:///v1/redact"},
                    },
                    {
                        name = "an endpoint with raw control characters",
                        conf = {
                            endpoint = "https://redaction.example.com/v1/redact\r\nInjected",
                        },
                    },
                    {
                        name = "a zero timeout",
                        conf = {timeout = 0},
                    },
                    {
                        name = "a zero mapping entry limit",
                        conf = {max_mapping_entries = 0},
                    },
                    {
                        name = "an unsafe authentication header name",
                        conf = {auth_header = "X-Token\r\nInjected"},
                    },
                    {
                        name = "an unsafe session header name",
                        conf = {session_id_header = "Bad Header"},
                    },
                }) do
                    it(
                        "rejects " .. case.name, function()
                            local conf = config(case.conf)

                            local ok = plugin.check_schema(conf)

                            assert.is_false(ok)
                        end
                    )
                end
            end
        )

        context(
            "identity and outbound request", function()
                it(
                    "prefers the canonical APISIX request ID and forwards the session ID",
                    function()
                        local apisix_request_id = "da584df5-7bd5-4590-98e0-8f92a89f9494"
                        local bk_request_id = "00f6a0f8-a757-4d68-aa2d-5cf890802496"
                        local session_id = "24395b38-bf3f-426c-a632-10df20ec69c8"
                        local ctx = request_context({
                            var = {
                                apisix_request_id = apisix_request_id,
                                bk_request_id = bk_request_id,
                            },
                        })
                        request_headers["X-AI-Session-Id"] = session_id

                        local code, err = plugin.access(config(), ctx)

                        assert.is_nil(code)
                        assert.is_nil(err)
                        assert.is_equal(1, observed.request_count)
                        assert.is_equal(apisix_request_id, observed.payload.request_id)
                        assert.is_equal(session_id, observed.payload.session_id)
                        assert.is_equal(
                            "__BK_REDACT_da584df57bd5459098e08f92a89f9494_",
                            observed.payload.placeholder_namespace
                        )
                        assert.is_same({
                            model = "gpt-4o",
                            stream = false,
                            messages = {
                                {
                                    role = "user",
                                    content = "phone: 13800138000",
                                },
                            },
                            metadata = {source = "final-client-body"},
                        }, observed.payload.body)
                        assert.is_equal(apisix_request_id, ctx._ai_redaction_request_id)
                        assert.is_equal(session_id, ctx._ai_redaction_session_id)
                    end
                )

                it(
                    "falls back to the canonical BlueKing request ID", function()
                        local bk_request_id = "00f6a0f8-a757-4d68-aa2d-5cf890802496"
                        local ctx = request_context({
                            var = {
                                apisix_request_id = "not-a-uuid",
                                bk_request_id = bk_request_id,
                            },
                        })

                        local code = plugin.access(config(), ctx)

                        assert.is_nil(code)
                        assert.is_equal(1, observed.request_count)
                        assert.is_equal(bk_request_id, observed.payload.request_id)
                    end
                )

                it(
                    "generates a UUID v4 when neither request ID is canonical", function()
                        local ctx = request_context({
                            var = {
                                apisix_request_id = "bad-apisix-id",
                                bk_request_id = "bad-bk-id",
                            },
                        })

                        local code = plugin.access(config(), ctx)

                        assert.is_nil(code)
                        assert.is_equal(1, observed.request_count)
                        local uuid_v4_pattern =
                            [[^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-]] ..
                            [[[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$]]
                        assert.is_truthy(ngx.re.match(
                            observed.payload.request_id, uuid_v4_pattern, "jo"
                        ))
                        assert.is_equal(
                            "__BK_REDACT_" ..
                            observed.payload.request_id:gsub("-", ""):lower() .. "_",
                            observed.payload.placeholder_namespace
                        )
                    end
                )

                it(
                    "omits an absent session ID", function()
                        local ctx = request_context({
                            var = {
                                apisix_request_id = "da584df5-7bd5-4590-98e0-8f92a89f9494",
                            },
                        })

                        local code = plugin.access(config(), ctx)

                        assert.is_nil(code)
                        assert.is_equal(1, observed.request_count)
                        assert.is_nil(observed.payload.session_id)
                        assert.is_nil(ctx._ai_redaction_session_id)
                    end
                )

                it(
                    "rejects a non-empty invalid session ID before the service call", function()
                        local ctx = request_context()
                        request_headers["X-AI-Session-Id"] = "not-a-session-uuid"

                        local code, err = plugin.access(config(), ctx)

                        assert.is_equal(400, code)
                        assert.is_equal("invalid AI session ID", err)
                        assert.is_equal(0, observed.new_count)
                        assert.is_equal(0, observed.request_count)
                        assert_no_request_mutation()
                    end
                )

                it(
                    "sends authentication and connection settings once", function()
                        local ctx = request_context()

                        local code = plugin.access(config(), ctx)

                        assert.is_nil(code)
                        assert.is_equal(1, observed.new_count)
                        assert.is_equal(1, observed.connect_count)
                        assert.is_equal(1, observed.request_count)
                        assert.is_equal(1, observed.read_count)
                        assert.is_equal(1, observed.keepalive_count)
                        assert.is_equal(0, observed.close_count)
                        assert.is_equal(3000, observed.timeout)
                        assert.is_same({
                            scheme = "https",
                            host = "redaction.example.com",
                            port = nil,
                            ssl_verify = true,
                            ssl_server_name = "redaction.example.com",
                            pool_size = 30,
                        }, observed.connect_options)
                        assert.is_equal("POST", observed.request_options.method)
                        assert.is_equal(
                            "/v1/redact?tenant=blueking", observed.request_options.path
                        )
                        assert.is_equal(
                            "application/json",
                            observed.request_options.headers["Content-Type"]
                        )
                        assert.is_equal(
                            "secret-token",
                            observed.request_options.headers["X-Redaction-Token"]
                        )
                        assert.is_equal(60000, observed.keepalive_timeout)
                        assert.is_equal(30, observed.keepalive_pool)
                    end
                )

                it(
                    "closes non-keepalive connections and omits absent authentication", function()
                        local ctx = request_context()
                        local conf = config({keepalive = false})
                        conf.auth_value = nil

                        local code = plugin.access(conf, ctx)

                        assert.is_nil(code)
                        assert.is_equal(1, observed.request_count)
                        assert.is_equal(0, observed.keepalive_count)
                        assert.is_equal(1, observed.close_count)
                        assert.is_false(observed.connect_options.pool_size)
                        assert.is_nil(
                            observed.request_options.headers["X-Redaction-Token"]
                        )
                    end
                )
            end
        )

        context(
            "early request rejection", function()
                for _, protocol in ipairs({"bedrock-converse", "passthrough"}) do
                    it(
                        "rejects streaming " .. protocol .. " before external calls",
                        function()
                            local ctx = request_context({
                                ai_client_protocol = protocol,
                                var = {request_type = "ai_stream"},
                            })

                            local code, err = plugin.access(config(), ctx)

                            assert.is_equal(400, code)
                            assert.is_equal(
                                "streaming protocol " .. protocol ..
                                " is not supported for response restoration",
                                err
                            )
                            assert.is_equal(0, observed.new_count)
                            assert.is_equal(0, observed.request_count)
                            assert_no_request_mutation()
                        end
                    )
                end

                it(
                    "allows supported SSE client protocol with a Bedrock provider", function()
                        local ctx = request_context({
                            picked_ai_instance = {provider = "bedrock"},
                            ai_client_protocol = "openai-chat",
                            var = {request_type = "ai_stream"},
                        })
                        request_body.stream = true

                        local code = plugin.access(config(), ctx)

                        assert.is_nil(code)
                        assert.is_equal(1, observed.request_count)
                    end
                )

                it(
                    "requires an AI proxy selection before the service call", function()
                        local ctx = request_context({picked_ai_instance = false})

                        local code, err = plugin.access(config(), ctx)

                        assert.is_equal(500, code)
                        assert.is_equal(
                            "bk-ai-sensitive-data-redaction must be used with " ..
                            "ai-proxy or ai-proxy-multi",
                            err
                        )
                        assert.is_equal(0, observed.request_count)
                        assert_no_request_mutation()
                    end
                )

                it(
                    "maps an oversized request body to 413 before the service call", function()
                        local ctx = request_context()
                        behavior.body_error = {
                            message = "request size 2048 is greater than the maximum size 1024",
                        }

                        local code, err = plugin.access(config(), ctx)

                        assert.is_equal(413, code)
                        assert.is_same(behavior.body_error, err)
                        assert.is_equal(1048576, observed.body_limit)
                        assert.is_equal(0, observed.request_count)
                        assert_no_request_mutation()
                    end
                )

                it(
                    "rechecks the final cached JSON body against the configured limit", function()
                        local ctx = request_context()
                        request_body.messages[1].content = string.rep("x", 128)

                        local code, err = plugin.access(
                            config({max_request_body_bytes = 64}), ctx
                        )

                        assert.is_equal(413, code)
                        assert.is_same({
                            message = "request body is greater than the maximum size",
                        }, err)
                        assert.is_equal(64, observed.body_limit)
                        assert.is_equal(0, observed.request_count)
                        assert_no_request_mutation()
                    end
                )

                it(
                    "maps malformed JSON input to 400 before the service call", function()
                        local ctx = request_context()
                        behavior.body_error = {message = "failed to decode request body"}

                        local code, err = plugin.access(config(), ctx)

                        assert.is_equal(400, code)
                        assert.is_same(behavior.body_error, err)
                        assert.is_equal(0, observed.request_count)
                        assert_no_request_mutation()
                    end
                )
            end
        )

        context(
            "third-party and contract failures", function()
                local function assert_502_without_mutation(
                    expected_message, expected_request_count
                )
                    local ctx = request_context()
                    local original = assert(core.json.encode(request_body))

                    local code, err = plugin.access(config(), ctx)

                    assert.is_equal(502, code)
                    assert.is_same({message = expected_message}, err)
                    assert.is_equal(expected_request_count or 1, observed.request_count)
                    assert.is_equal(original, assert(core.json.encode(request_body)))
                    assert.is_nil(ctx._ai_redaction_mapping)
                    assert_no_request_mutation()
                end

                it(
                    "fails closed on a connection timeout", function()
                        behavior.connect_ok = nil
                        behavior.connect_error = "timeout"

                        assert_502_without_mutation(
                            "redaction service connect failed: timeout", 0
                        )

                        assert.is_equal(1, observed.connect_count)
                        assert.is_equal(0, observed.request_count)
                    end
                )

                it(
                    "fails closed on a request error", function()
                        behavior.request_error = "closed"

                        assert_502_without_mutation(
                            "redaction service request failed: closed"
                        )

                        assert.is_equal(1, observed.request_count)
                        assert.is_equal(1, observed.close_count)
                    end
                )

                it(
                    "fails closed on a response read error", function()
                        behavior.read_error = "timeout"

                        assert_502_without_mutation(
                            "redaction service read failed: timeout"
                        )

                        assert.is_equal(1, observed.request_count)
                        assert.is_equal(1, observed.read_count)
                        assert.is_equal(1, observed.close_count)
                    end
                )

                it(
                    "fails closed on a non-200 response after one call", function()
                        behavior.response_status = 500

                        assert_502_without_mutation(
                            "redaction service returned status 500"
                        )

                        assert.is_equal(1, observed.request_count)
                    end
                )

                it(
                    "fails closed on malformed response JSON", function()
                        behavior.response_builder = function()
                            return "{"
                        end

                        assert_502_without_mutation(
                            "redaction service returned invalid JSON"
                        )

                        assert.is_equal(1, observed.request_count)
                    end
                )

                it(
                    "rejects a masked body with another protocol", function()
                        behavior.response_builder = function(payload)
                            local value = success_value(payload)
                            value.body.messages = nil
                            value.body.input = "phone: " ..
                                               payload.placeholder_namespace .. "1__"
                            return assert(core.json.encode(value))
                        end

                        assert_502_without_mutation(
                            "redaction service changed the AI protocol"
                        )
                    end
                )

                it(
                    "rejects a changed model", function()
                        behavior.response_builder = function(payload)
                            local value = success_value(payload)
                            value.body.model = "other-model"
                            return assert(core.json.encode(value))
                        end

                        assert_502_without_mutation(
                            "redaction service changed model"
                        )
                    end
                )

                it(
                    "rejects a changed stream flag", function()
                        behavior.response_builder = function(payload)
                            local value = success_value(payload)
                            value.body.stream = true
                            return assert(core.json.encode(value))
                        end

                        assert_502_without_mutation(
                            "redaction service changed stream"
                        )
                    end
                )

                it(
                    "rejects placeholders from another request namespace", function()
                        behavior.response_builder = function(payload)
                            local value = success_value(payload)
                            local foreign = "__BK_REDACT_" .. string.rep("0", 32) .. "_1__"
                            value.body.messages[1].content = foreign
                            value.replacements[1].placeholder = foreign
                            return assert(core.json.encode(value))
                        end

                        assert_502_without_mutation(
                            "placeholder is outside request namespace"
                        )
                    end
                )

                it(
                    "rejects a declared placeholder absent from the masked body", function()
                        behavior.response_builder = function(payload)
                            local value = success_value(payload)
                            value.body.messages[1].content = "no placeholder"
                            return assert(core.json.encode(value))
                        end

                        assert_502_without_mutation(
                            "placeholder is absent from masked body"
                        )
                    end
                )

                it(
                    "rejects mappings above the entry limit", function()
                        behavior.response_builder = function(payload)
                            local value = success_value(payload)
                            local second = payload.placeholder_namespace .. "2__"
                            value.body.messages[1].content =
                                value.body.messages[1].content .. " " .. second
                            value.replacements[2] = {
                                placeholder = second,
                                original = "second-secret",
                            }
                            return assert(core.json.encode(value))
                        end
                        local ctx = request_context()

                        local code, err = plugin.access(
                            config({max_mapping_entries = 1}), ctx
                        )

                        assert.is_equal(502, code)
                        assert.is_same({message = "mapping entry limit exceeded"}, err)
                        assert.is_equal(1, observed.request_count)
                        assert_no_request_mutation()
                    end
                )

                it(
                    "rejects mappings above the byte limit", function()
                        local ctx = request_context()

                        local code, err = plugin.access(
                            config({max_mapping_bytes = 1}), ctx
                        )

                        assert.is_equal(502, code)
                        assert.is_same({message = "mapping byte limit exceeded"}, err)
                        assert.is_equal(1, observed.request_count)
                        assert_no_request_mutation()
                    end
                )

                it(
                    "rejects an object masquerading as an empty replacements array", function()
                        behavior.response_builder = function(payload)
                            local value = success_value(payload)
                            return "{\"body\":" .. assert(core.json.encode(value.body)) ..
                                   ",\"replacements\":{}}"
                        end

                        assert_502_without_mutation(
                            "replacements must be a JSON array"
                        )
                    end
                )
            end
        )

        context(
            "successful mutation", function()
                it(
                    "installs only the validated masked body and request-local mapping", function()
                        local request_id = "da584df5-7bd5-4590-98e0-8f92a89f9494"
                        local ctx = request_context({
                            var = {apisix_request_id = request_id},
                        })
                        local namespace =
                            "__BK_REDACT_da584df57bd5459098e08f92a89f9494_"
                        local token = namespace .. "1__"

                        local code, err = plugin.access(config(), ctx)

                        assert.is_nil(code)
                        assert.is_nil(err)
                        assert.is_equal(1, observed.request_count)
                        local masked = assert(core.json.decode(installed_body))
                        assert.is_equal("phone: " .. token, masked.messages[1].content)
                        assert.is_equal(
                            "phone: " .. token, request_body.messages[1].content
                        )
                        assert.is_equal("gpt-4o", masked.model)
                        assert.is_false(masked.stream)
                        assert.is_equal(request_id, ctx._ai_redaction_request_id)
                        assert.is_equal(namespace, ctx._ai_redaction_namespace)
                        assert.is_same({[token] = "13800138000"}, ctx._ai_redaction_mapping)
                        assert.is_true(ctx.ai_request_body_changed)
                        assert.is_nil(ctx._ai_redaction_sse_restorer)
                    end
                )
            end
        )
    end
)
