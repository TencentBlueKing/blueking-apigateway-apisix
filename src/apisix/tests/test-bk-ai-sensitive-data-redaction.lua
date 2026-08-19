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
local proxy_base = require("apisix.plugins.ai-proxy.base")
local restorer = require("apisix.plugins.bk-ai-sensitive-data-redaction.restorer")
local sse_restorer = require("apisix.plugins.bk-ai-sensitive-data-redaction.sse")


describe(
    "bk-ai-sensitive-data-redaction", function()
        local behavior
        local observed
        local request_body
        local raw_request_body
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
            ctx.ai_target_protocol = "openai-chat"
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
            local token = payload.placeholder_namespace .. "1__"
            return {
                body = payload.body:gsub("13800138000", token, 1),
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

        local function mutate_success_response(payload, mutate)
            local value = success_value(payload)
            local body = assert(core.json.decode(value.body))
            mutate(body, value)
            value.body = assert(core.json.encode(body))
            return assert(core.json.encode(value))
        end

        local function assert_no_request_mutation()
            assert.is_nil(installed_body)
            assert.stub(ngx.req.set_body_data).was_not_called()
        end

        local function run_filter(ctx, conf, body)
            local code, err = plugin.access(conf or config(), ctx)
            if code then
                return code, err
            end
            return ctx.ai_final_request_body_filter(body or raw_request_body)
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
                raw_request_body = assert(core.json.encode(request_body))
                installed_body = nil
                behavior = {
                    connect_ok = true,
                    response_headers = {},
                    response_status = 200,
                    response_builder = success_response,
                }
                observed = {
                    new_count = 0,
                    connect_count = 0,
                    request_count = 0,
                    read_count = 0,
                    body_reader_count = 0,
                    body_reader_sizes = {},
                    read_body_count = 0,
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
                    core.request, "get_body", function(max_size)
                        observed.body_limit = max_size
                        if behavior.body_error then
                            return nil, behavior.body_error.message or behavior.body_error
                        end
                        if max_size and #raw_request_body > max_size then
                            return nil, "request size " .. #raw_request_body ..
                                        " is greater than the maximum size " .. max_size ..
                                        " allowed"
                        end
                        return raw_request_body
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
                                local response_body = behavior.response_body or raw
                                local response_offset = 1
                                return {
                                    status = behavior.response_status,
                                    headers = behavior.response_headers,
                                    body_reader = function(max_bytes)
                                        observed.body_reader_count =
                                            observed.body_reader_count + 1
                                        observed.body_reader_sizes[
                                            #observed.body_reader_sizes + 1
                                        ] = max_bytes or false
                                        if behavior.read_error then
                                            observed.read_count = observed.read_count + 1
                                            return nil, behavior.read_error
                                        end

                                        if response_offset > #response_body then
                                            return nil
                                        end

                                        local remaining = #response_body - response_offset + 1
                                        local read_size = math.min(max_bytes or remaining, remaining)
                                        if behavior.one_byte_chunks then
                                            read_size = 1
                                        end
                                        local chunk = response_body:sub(
                                            response_offset,
                                            response_offset + read_size - 1
                                        )
                                        response_offset = response_offset + #chunk
                                        observed.read_count = observed.read_count + 1
                                        return chunk
                                    end,
                                    read_body = function()
                                        observed.read_body_count = observed.read_body_count + 1
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
                core.request.get_body:revert()
                core.request.header:revert()
                ngx.req.set_body_data:revert()
                http.new:revert()
            end
        )

        context(
            "final request body callback contract", function()
                local function register_filter(ctx, conf)
                    local code, err = plugin.access(conf or config(), ctx)
                    assert.is_nil(code)
                    assert.is_nil(err)
                    assert.is_function(ctx.ai_final_request_body_filter)
                    return ctx.ai_final_request_body_filter
                end

                it(
                    "registers request identity without I/O or request-body mutation",
                    function()
                        local request_id = "da584df5-7bd5-4590-98e0-8f92a89f9494"
                        local ctx = request_context({
                            var = {apisix_request_id = request_id},
                        })

                        register_filter(ctx)

                        assert.is_equal(0, observed.new_count)
                        assert.is_equal(0, observed.request_count)
                        assert.is_equal(request_id, ctx._ai_redaction_request_id)
                        assert.is_equal(
                            "__BK_REDACT_da584df57bd5459098e08f92a89f9494_",
                            ctx._ai_redaction_namespace
                        )
                        assert.is_equal(
                            "phone: 13800138000", request_body.messages[1].content
                        )
                        assert_no_request_mutation()
                    end
                )

                for _, case in ipairs({
                    {
                        name = "Anthropic Messages to OpenAI Chat",
                        converter = "anthropic-messages-to-openai-chat",
                        uri = "/v1/messages",
                        client_protocol = "anthropic-messages",
                        target_protocol = "openai-chat",
                        body = {
                            model = "gpt-4o",
                            stream = false,
                            max_tokens = 128,
                            messages = {{
                                role = "user",
                                content = "phone: 13800138000",
                            }},
                        },
                    },
                    {
                        name = "OpenAI Embeddings to Vertex Predict",
                        converter = "openai-embeddings-to-vertex-predict",
                        uri = "/v1/embeddings",
                        client_protocol = "openai-embeddings",
                        target_protocol = "vertex-predict",
                        body = {
                            model = "text-embedding-004",
                            input = "phone: 13800138000",
                        },
                    },
                }) do
                    it(
                        "accepts the real " .. case.name .. " converter output",
                        function()
                            request_body = case.body
                            raw_request_body = assert(core.json.encode(request_body))
                            local ctx = request_context({
                                var = {uri = case.uri},
                                ai_client_protocol = case.client_protocol,
                                ai_target_protocol = case.target_protocol,
                            })
                            local converter = require(
                                "apisix.plugins.ai-protocols.converters." ..
                                case.converter
                            )
                            local converted = assert(converter.convert_request(
                                request_body, ctx
                            ))

                            local filter = register_filter(ctx)
                            local masked_body, err, code = filter(
                                assert(core.json.encode(converted))
                            )

                            assert.is_nil(err)
                            assert.is_nil(code)
                            assert.is_string(masked_body)
                            assert.is_nil(masked_body:find("13800138000", 1, true))
                            assert.is_equal(1, observed.request_count)
                        end
                    )
                end

                it(
                    "clears rewritten payload logs before a lower-priority rejection",
                    function()
                        local ctx = request_context({
                            var = {
                                llm_request_body = {
                                    messages = {{
                                        role = "user",
                                        content = "rewrite-residue-secret",
                                    }},
                                },
                            },
                        })

                        register_filter(ctx)

                        assert.is_same({}, ctx.var.llm_request_body)
                        proxy_base.set_logging(ctx, false, true)
                        local payload_log = assert(core.json.encode(ctx.llm_request))
                        assert.is_nil(payload_log:find(
                            "rewrite-residue-secret", 1, true
                        ))
                        assert.is_equal(0, observed.request_count)
                    end
                )

                it(
                    "clears rewritten payload logs before early access failures",
                    function()
                        for _, case in ipairs({
                            {
                                ctx = request_context({
                                    picked_ai_instance = false,
                                    var = {
                                        llm_request_body = {
                                            secret = "missing-context-secret",
                                        },
                                    },
                                }),
                                conf = config(),
                                status = 500,
                            },
                            {
                                ctx = request_context({
                                    var = {
                                        llm_request_body = {
                                            secret = "oversize-secret",
                                        },
                                    },
                                }),
                                conf = config({max_request_body_bytes = 1}),
                                status = 413,
                            },
                        }) do
                            local code = plugin.access(case.conf, case.ctx)

                            assert.is_equal(case.status, code)
                            assert.is_same({}, case.ctx.var.llm_request_body)
                            proxy_base.set_logging(case.ctx, false, true)
                            local payload_log = assert(core.json.encode(
                                case.ctx.llm_request
                            ))
                            assert.is_nil(payload_log:find("-secret", 1, true))
                        end
                        assert.is_equal(0, observed.request_count)
                    end
                )

                it(
                    "rejects an existing final-body callback instead of replacing it",
                    function()
                        local existing = function(body)
                            return body
                        end
                        local ctx = request_context({
                            ai_final_request_body_filter = existing,
                        })

                        local code, err = plugin.access(config(), ctx)

                        assert.is_equal(500, code)
                        assert.is_equal(
                            "AI final request body filter is already registered", err
                        )
                        assert.is_equal(existing, ctx.ai_final_request_body_filter)
                        assert.is_equal(0, observed.request_count)
                    end
                )

                it(
                    "sends and returns raw JSON strings while preserving numeric lexemes",
                    function()
                        local ctx = request_context({
                            ai_target_protocol = "openai-chat",
                            var = {
                                apisix_request_id =
                                    "da584df5-7bd5-4590-98e0-8f92a89f9494",
                            },
                        })
                        local namespace =
                            "__BK_REDACT_da584df57bd5459098e08f92a89f9494_"
                        local token = namespace .. "1__"
                        local final_body =
                            '{"model":"gpt-4o","stream":false,' ..
                            '"large":9007199254740993,' ..
                            '"long":123456789012345678901234567890,' ..
                            '"negative_zero":-0,"exponent":1.2300e+40,' ..
                            '"messages":[{"role":"user",' ..
                            '"content":"phone: 13800138000"}]}'
                        behavior.response_builder = function(payload)
                            assert.is_equal(final_body, payload.body)
                            return assert(core.json.encode({
                                body = final_body:gsub("13800138000", token, 1),
                                replacements = {{
                                    placeholder = token,
                                    original = "13800138000",
                                }},
                            }))
                        end

                        local filter = register_filter(ctx)
                        local masked, err, status = filter(final_body)

                        assert.is_nil(err)
                        assert.is_nil(status)
                        assert.is_string(observed.payload.body)
                        assert.is_equal(
                            final_body:gsub("13800138000", token, 1), masked
                        )
                        assert.is_truthy(masked:find("9007199254740993", 1, true))
                        assert.is_truthy(masked:find(
                            "123456789012345678901234567890", 1, true
                        ))
                        assert.is_truthy(masked:find("-0", 1, true))
                        assert.is_truthy(masked:find("1.2300e+40", 1, true))
                        assert.is_same({[token] = "13800138000"},
                                       ctx._ai_redaction_mapping)
                        assert_no_request_mutation()
                    end
                )

                it(
                    "finds escaped placeholder spellings in the raw masked JSON",
                    function()
                        local ctx = request_context({
                            ai_target_protocol = "openai-chat",
                            var = {
                                apisix_request_id =
                                    "da584df5-7bd5-4590-98e0-8f92a89f9494",
                            },
                        })
                        local namespace =
                            "__BK_REDACT_da584df57bd5459098e08f92a89f9494_"
                        local token = namespace .. "1__"
                        behavior.response_builder = function()
                            local masked = raw_request_body:gsub(
                                "13800138000", token, 1
                            ):gsub(token, "\\u005f" .. token:sub(2), 1)
                            return assert(core.json.encode({
                                body = masked,
                                replacements = {{
                                    placeholder = token,
                                    original = "13800138000",
                                }},
                            }))
                        end

                        local masked, err = register_filter(ctx)(raw_request_body)

                        assert.is_nil(err)
                        assert.is_string(masked)
                        assert.is_equal("13800138000", ctx._ai_redaction_mapping[token])
                    end
                )

                it(
                    "clears an earlier attempt before replacing it only after validation",
                    function()
                        local ctx = request_context({
                            ai_target_protocol = "openai-chat",
                            var = {
                                apisix_request_id =
                                    "da584df5-7bd5-4590-98e0-8f92a89f9494",
                            },
                        })
                        local filter = register_filter(ctx)
                        local namespace = ctx._ai_redaction_namespace
                        local first = namespace .. "1__"
                        local second = namespace .. "2__"
                        behavior.response_builder = function(payload)
                            local token = observed.request_count == 1 and first or second
                            return assert(core.json.encode({
                                body = payload.body:gsub("13800138000", token, 1),
                                replacements = {{
                                    placeholder = token,
                                    original = "13800138000",
                                }},
                            }))
                        end

                        assert.is_string(filter(raw_request_body))
                        ctx._ai_redaction_sse_restorer = {stale = true}
                        ctx._ai_redaction_stream_passthrough = true
                        assert.is_string(filter(raw_request_body))

                        assert.is_nil(ctx._ai_redaction_mapping[first])
                        assert.is_equal("13800138000", ctx._ai_redaction_mapping[second])
                        assert.is_nil(ctx._ai_redaction_sse_restorer)
                        assert.is_nil(ctx._ai_redaction_stream_passthrough)

                        behavior.response_builder = function()
                            return '{"body":"not-json","replacements":[]}'
                        end
                        local masked, err, status = filter(raw_request_body)
                        assert.is_nil(masked)
                        assert.is_same({
                            message = "redaction service body must be valid JSON",
                        }, err)
                        assert.is_equal(502, status)
                        assert.is_nil(ctx._ai_redaction_mapping)
                    end
                )

                it(
                    "clears the original logging body and attempt state at callback entry",
                    function()
                        local ctx = request_context({
                            var = {
                                llm_request_body = {
                                    messages = {{
                                        role = "user",
                                        content = "client-log-secret",
                                    }},
                                },
                            },
                            _ai_redaction_mapping = {stale = "override-log-secret"},
                            _ai_redaction_sse_restorer = {stale = true},
                            _ai_redaction_stream_passthrough = true,
                        })

                        local masked, err, status = register_filter(ctx)({})

                        assert.is_nil(masked)
                        assert.is_same({
                            message = "final AI request body must be a JSON object string",
                        }, err)
                        assert.is_equal(400, status)
                        assert.is_same({}, ctx.var.llm_request_body)
                        assert.is_nil(ctx._ai_redaction_mapping)
                        assert.is_nil(ctx._ai_redaction_sse_restorer)
                        assert.is_nil(ctx._ai_redaction_stream_passthrough)
                    end
                )

                for _, case in ipairs({
                    {
                        name = "a non-string input",
                        body = {},
                        status = 400,
                        message = "final AI request body must be a JSON object string",
                    },
                    {
                        name = "malformed input JSON",
                        body = "{",
                        status = 400,
                        message = "final AI request body must be valid JSON",
                    },
                    {
                        name = "a non-object input",
                        body = "[]",
                        status = 400,
                        message = "final AI request body must be a JSON object string",
                    },
                }) do
                    it(
                        "rejects " .. case.name .. " without a service call", function()
                            local ctx = request_context({
                                ai_target_protocol = "openai-chat",
                            })

                            local masked, err, status = register_filter(ctx)(case.body)

                            assert.is_nil(masked)
                            assert.is_same({message = case.message}, err)
                            assert.is_equal(case.status, status)
                            assert.is_equal(0, observed.request_count)
                        end
                    )
                end

                it(
                    "uses the raw-string response envelope cap including its quotes",
                    function()
                        local ctx = request_context({
                            ai_target_protocol = "openai-chat",
                        })
                        -- 29 fixed bytes + 6*200 body + 6*20 mapping + 33*2 = 1415.
                        behavior.response_headers["Content-Length"] = "1416"
                        behavior.response_builder = function()
                            return "{}"
                        end

                        local masked, err, status = register_filter(ctx, config({
                            max_request_body_bytes = 200,
                            max_mapping_bytes = 20,
                            max_mapping_entries = 2,
                        }))(raw_request_body)

                        assert.is_nil(masked)
                        assert.is_same({
                            message = "redaction service response size limit exceeded",
                        }, err)
                        assert.is_equal(502, status)
                        assert.is_equal(0, observed.body_reader_count)
                    end
                )

                it(
                    "clamps a worst-case escaped response at the 64 MiB ceiling",
                    function()
                        local ctx = request_context({
                            ai_target_protocol = "openai-chat",
                        })
                        behavior.response_headers["Content-Length"] = "67108865"
                        behavior.response_builder = function()
                            return "{}"
                        end

                        local masked, err, status = register_filter(ctx, config({
                            max_request_body_bytes = 67108864,
                            max_mapping_bytes = 67108864,
                            max_mapping_entries = 1000000,
                        }))(raw_request_body)

                        assert.is_nil(masked)
                        assert.is_same({
                            message = "redaction service response size limit exceeded",
                        }, err)
                        assert.is_equal(502, status)
                        assert.is_equal(0, observed.body_reader_count)
                    end
                )

                it(
                    "rejects an oversized masked body before mapping or integrity work",
                    function()
                        local ctx = request_context({
                            ai_target_protocol = "openai-chat",
                        })
                        behavior.response_builder = function(payload)
                            local value = success_value(payload)
                            local body = assert(core.json.decode(value.body))
                            body.padding = string.rep("x", 256)
                            value.body = assert(core.json.encode(body))
                            return assert(core.json.encode(value))
                        end
                        local mapping_validation_called = false
                        stub(restorer, "validate_mapping", function()
                            mapping_validation_called = true
                            return {}
                        end)

                        local masked, err, status = register_filter(ctx, config({
                            max_request_body_bytes = 200,
                        }))(raw_request_body)
                        restorer.validate_mapping:revert()

                        assert.is_nil(masked)
                        assert.is_same({message = "masked body size limit exceeded"}, err)
                        assert.is_equal(502, status)
                        assert.is_false(mapping_validation_called)
                    end
                )
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
                        name = "a literal authentication value containing CRLF",
                        conf = {auth_value = "secret\r\nInjected: true"},
                    },
                    {
                        name = "a literal authentication value containing NUL",
                        conf = {auth_value = "secret\0tail"},
                    },
                    {
                        name = "a literal authentication value containing DEL",
                        conf = {auth_value = "secret\127tail"},
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

                for _, header_name in ipairs({
                    "Content-Length",
                    "transfer-encoding",
                    "CONNECTION",
                    "Keep-Alive",
                    "Proxy-Authenticate",
                    "proxy-authorization",
                    "TE",
                    "Trailer",
                    "Upgrade",
                    "Host",
                    "content-type",
                }) do
                    it(
                        "rejects forbidden authentication header " .. header_name,
                        function()
                            local ok = plugin.check_schema(config({
                                auth_header = header_name,
                            }))

                            assert.is_false(ok)
                        end
                    )
                end

                it(
                    "accepts Authorization, X-* headers, and secret references", function()
                        local authorization_ok = plugin.check_schema(config({
                            auth_header = "Authorization",
                        }))
                        local custom_ok = plugin.check_schema(config({
                            auth_header = "X-Redaction-Token",
                            auth_value = "$secret://vault/redaction/token",
                        }))

                        assert.is_true(authorization_ok)
                        assert.is_true(custom_ok)
                    end
                )
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

                        local masked, err, code = run_filter(ctx)

                        assert.is_string(masked)
                        assert.is_nil(err)
                        assert.is_nil(code)
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
                        }, assert(core.json.decode(observed.payload.body)))
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

                        local masked = run_filter(ctx)

                        assert.is_string(masked)
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

                        local masked = run_filter(ctx)

                        assert.is_string(masked)
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

                        local masked = run_filter(ctx)

                        assert.is_string(masked)
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

                        local masked = run_filter(ctx)

                        assert.is_string(masked)
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

                        local masked = run_filter(ctx, conf)

                        assert.is_string(masked)
                        assert.is_equal(1, observed.request_count)
                        assert.is_equal(0, observed.keepalive_count)
                        assert.is_equal(1, observed.close_count)
                        assert.is_nil(observed.connect_options.pool_size)
                        assert.is_nil(
                            observed.request_options.headers["X-Redaction-Token"]
                        )
                    end
                )

                it(
                    "closes safely when returning a connection to the pool fails", function()
                        local ctx = request_context({
                            var = {
                                apisix_request_id =
                                    "da584df5-7bd5-4590-98e0-8f92a89f9494",
                            },
                        })
                        behavior.keepalive_ok = false
                        behavior.keepalive_error = "pool rejected connection"

                        local masked, err, code = run_filter(ctx)

                        assert.is_string(masked)
                        assert.is_nil(err)
                        assert.is_nil(code)
                        assert.is_equal(1, observed.keepalive_count)
                        assert.is_equal(1, observed.close_count)
                        assert_no_request_mutation()
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
                    "registers supported SSE client protocol without service I/O", function()
                        local ctx = request_context({
                            picked_ai_instance = {provider = "bedrock"},
                            ai_client_protocol = "openai-chat",
                            var = {request_type = "ai_stream"},
                        })
                        request_body.stream = true

                        local code = plugin.access(config(), ctx)

                        assert.is_nil(code)
                        assert.is_function(ctx.ai_final_request_body_filter)
                        assert.is_equal(0, observed.request_count)
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
                    "checks the original raw JSON body against the configured limit", function()
                        local ctx = request_context()
                        raw_request_body = '{"messages":[{"role":"user","content":"' ..
                                           string.rep("x", 128) .. '"}]}'

                        local code, err = plugin.access(
                            config({max_request_body_bytes = 64}), ctx
                        )

                        assert.is_equal(413, code)
                        assert.is_truthy(err.message:find(
                            "is greater than the maximum size 64", 1, true
                        ))
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

                it(
                    "rejects a resolved authentication value containing CRLF", function()
                        local ctx = request_context()
                        local conf = config({
                            auth_value = "resolved-secret\r\nInjected: true",
                        })

                        local code, err = plugin.access(conf, ctx)

                        assert.is_equal(500, code)
                        assert.is_equal(
                            "invalid redaction service authentication configuration",
                            err
                        )
                        assert.is_equal(0, observed.new_count)
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

                    local _, err, code = run_filter(ctx)

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

                for _, case in ipairs({
                    {
                        name = "a non-string response body",
                        response = function(payload)
                            local value = success_value(payload)
                            value.body = assert(core.json.decode(value.body))
                            return assert(core.json.encode(value))
                        end,
                        message = "redaction service body must be a raw JSON string",
                    },
                    {
                        name = "malformed response body text",
                        response = function()
                            return '{"body":"{","replacements":[]}'
                        end,
                        message = "redaction service body must be valid JSON",
                    },
                    {
                        name = "non-object response body text",
                        response = function()
                            return '{"body":"[]","replacements":[]}'
                        end,
                        message = "redaction service body must be an object",
                    },
                }) do
                    it(
                        "rejects " .. case.name, function()
                            behavior.response_builder = case.response

                            assert_502_without_mutation(case.message)
                        end
                    )
                end

                it(
                    "rejects an oversized declared response before reading it", function()
                        local ctx = request_context()
                        -- Wire cap = 29 + 6*200 body bytes + 6*20 mapping bytes
                        --            + 33*2 mapping entries = 1415 bytes.
                        behavior.response_headers["Content-Length"] = "1416"

                        local _, err, code = run_filter(ctx, config({
                            max_request_body_bytes = 200,
                            max_mapping_bytes = 20,
                            max_mapping_entries = 2,
                        }))

                        assert.is_equal(502, code)
                        assert.is_same({
                            message = "redaction service response size limit exceeded",
                        }, err)
                        assert.is_equal(0, observed.body_reader_count)
                        assert.is_equal(0, observed.read_body_count)
                        assert.is_equal(0, observed.keepalive_count)
                        assert.is_equal(1, observed.close_count)
                        assert.is_not_nil(ctx._ai_redaction_request_id)
                        assert.is_not_nil(ctx._ai_redaction_namespace)
                        assert.is_nil(ctx._ai_redaction_mapping)
                        assert.is_nil(ctx.ai_request_body_changed)
                        assert_no_request_mutation()
                    end
                )

                it(
                    "does not reject a declared response at the exact derived cap",
                    function()
                        local ctx = request_context()
                        behavior.response_headers["Content-Length"] = "1415"

                        local _, err, code = run_filter(ctx, config({
                            max_request_body_bytes = 200,
                            max_mapping_bytes = 20,
                            max_mapping_entries = 2,
                        }))

                        assert.is_equal(502, code)
                        assert.is_same({
                            message = "mapping byte limit exceeded",
                        }, err)
                        assert.is_equal(2, observed.body_reader_count)
                        assert.is_equal(0, observed.read_body_count)
                        assert.is_equal(1, observed.keepalive_count)
                        assert.is_equal(0, observed.close_count)
                        assert.is_not_nil(ctx._ai_redaction_request_id)
                        assert.is_not_nil(ctx._ai_redaction_namespace)
                        assert.is_nil(ctx._ai_redaction_mapping)
                        assert.is_nil(ctx.ai_request_body_changed)
                        assert_no_request_mutation()
                    end
                )

                it(
                    "bounds reader allocations when one wire chunk exceeds the cap",
                    function()
                        local ctx = request_context()
                        -- Wire cap = 29 + 6*1400 body bytes + 6*1 mapping byte
                        --            + 33*1 mapping entry = 8468 bytes.
                        behavior.response_body = string.rep("a", 8469)

                        local _, err, code = run_filter(ctx, config({
                            max_request_body_bytes = 1400,
                            max_mapping_bytes = 1,
                            max_mapping_entries = 1,
                        }))

                        assert.is_equal(502, code)
                        assert.is_same({
                            message = "redaction service response size limit exceeded",
                        }, err)
                        assert.is_same({8192, 277}, observed.body_reader_sizes)
                        for _, read_size in ipairs(observed.body_reader_sizes) do
                            assert.is_true(read_size > 0)
                            assert.is_true(read_size <= 8192)
                        end
                        assert.is_equal(2, observed.read_count)
                        assert.is_equal(2, observed.body_reader_count)
                        assert.is_equal(0, observed.read_body_count)
                        assert.is_equal(0, observed.keepalive_count)
                        assert.is_equal(1, observed.close_count)
                        assert.is_not_nil(ctx._ai_redaction_request_id)
                        assert.is_not_nil(ctx._ai_redaction_namespace)
                        assert.is_nil(ctx._ai_redaction_mapping)
                        assert.is_nil(ctx.ai_request_body_changed)
                        assert_no_request_mutation()
                    end
                )

                it(
                    "coalesces adversarial one-byte response chunks", function()
                        local module_name =
                            "apisix.plugins.bk-ai-sensitive-data-redaction"
                        local original_module = package.loaded[module_name]
                        local original_concat = table.concat
                        local concat_entry_counts = {}
                        table.concat = function(values, ...)
                            concat_entry_counts[#concat_entry_counts + 1] = #values
                            return original_concat(values, ...)
                        end
                        package.loaded[module_name] = nil
                        local fresh_plugin = require(module_name)
                        package.loaded[module_name] = original_module
                        table.concat = original_concat

                        behavior.one_byte_chunks = true
                        behavior.response_builder = function(payload)
                            local value = success_value(payload)
                            value.padding = string.rep("x", 20000)
                            return assert(core.json.encode(value))
                        end
                        local ctx = request_context()
                        local access_code, access_err = fresh_plugin.access(config(), ctx)
                        assert.is_nil(access_code)
                        assert.is_nil(access_err)

                        local masked_body, err, code =
                            ctx.ai_final_request_body_filter(raw_request_body)

                        assert.is_nil(err)
                        assert.is_nil(code)
                        assert.is_string(masked_body)
                        assert.is_true(observed.body_reader_count > 20000)
                        assert.is_true(#concat_entry_counts > 0)
                        assert.is_true(math.max(unpack(concat_entry_counts)) <= 8192)
                    end
                )

                it(
                    "rejects a decoded masked body above the request-body limit", function()
                        local ctx = request_context()
                        behavior.response_builder = function(payload)
                            return mutate_success_response(payload, function(body)
                                body.padding = string.rep("x", 256)
                            end)
                        end

                        local _, err, code = run_filter(ctx, config({
                            max_request_body_bytes = 200,
                        }))

                        assert.is_equal(502, code)
                        assert.is_same({message = "masked body size limit exceeded"}, err)
                        assert.is_not_nil(ctx._ai_redaction_request_id)
                        assert.is_not_nil(ctx._ai_redaction_namespace)
                        assert.is_nil(ctx._ai_redaction_mapping)
                        assert.is_nil(ctx.ai_request_body_changed)
                        assert_no_request_mutation()
                    end
                )

                it(
                    "rejects a masked body with another protocol", function()
                        behavior.response_builder = function(payload)
                            return mutate_success_response(payload, function(body)
                                body.messages = nil
                                body.input = "phone: " ..
                                             payload.placeholder_namespace .. "1__"
                            end)
                        end

                        assert_502_without_mutation(
                            "redaction service changed the AI protocol"
                        )
                    end
                )

                it(
                    "rejects a changed model", function()
                        behavior.response_builder = function(payload)
                            return mutate_success_response(payload, function(body)
                                body.model = "other-model"
                            end)
                        end

                        assert_502_without_mutation(
                            "redaction service changed model"
                        )
                    end
                )

                it(
                    "rejects a changed stream flag", function()
                        behavior.response_builder = function(payload)
                            return mutate_success_response(payload, function(body)
                                body.stream = true
                            end)
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
                            value.replacements[1].placeholder = foreign
                            local body = assert(core.json.decode(value.body))
                            body.messages[1].content = foreign
                            value.body = assert(core.json.encode(body))
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
                            return mutate_success_response(payload, function(body)
                                body.messages[1].content = "no placeholder"
                            end)
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
                            local body = assert(core.json.decode(value.body))
                            body.messages[1].content =
                                body.messages[1].content .. " " .. second
                            value.body = assert(core.json.encode(body))
                            value.replacements[2] = {
                                placeholder = second,
                                original = "second-secret",
                            }
                            return assert(core.json.encode(value))
                        end
                        local ctx = request_context()

                        local _, err, code = run_filter(
                            ctx, config({max_mapping_entries = 1})
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

                        local _, err, code = run_filter(
                            ctx, config({max_mapping_bytes = 1})
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
                    "keeps request payload logging empty after successful filtering", function()
                        local request_id = "da584df5-7bd5-4590-98e0-8f92a89f9494"
                        local ctx = request_context({
                            var = {apisix_request_id = request_id},
                        })
                        local namespace =
                            "__BK_REDACT_da584df57bd5459098e08f92a89f9494_"
                        local token = namespace .. "1__"

                        local masked_body, err, code = run_filter(ctx)

                        assert.is_nil(err)
                        assert.is_nil(code)
                        assert.is_string(masked_body)
                        assert.is_equal(1, observed.request_count)
                        local masked = assert(core.json.decode(masked_body))
                        assert.is_equal("phone: " .. token, masked.messages[1].content)
                        assert.is_equal(
                            "phone: 13800138000", request_body.messages[1].content
                        )
                        assert.is_equal("gpt-4o", masked.model)
                        assert.is_false(masked.stream)
                        assert.is_equal(request_id, ctx._ai_redaction_request_id)
                        assert.is_equal(namespace, ctx._ai_redaction_namespace)
                        assert.is_same({[token] = "13800138000"}, ctx._ai_redaction_mapping)
                        assert.is_same({}, ctx.var.llm_request_body)
                        proxy_base.set_logging(ctx, false, true)
                        local payload_log = assert(core.json.encode(ctx.llm_request))
                        assert.is_nil(payload_log:find("13800138000", 1, true))
                        assert.is_nil(payload_log:find(token, 1, true))
                        assert.is_nil(ctx.ai_request_body_changed)
                        assert.is_nil(ctx._ai_redaction_sse_restorer)
                        assert_no_request_mutation()
                    end
                )
            end
        )

        context(
            "request redaction integrity", function()
                local namespace = "__BK_REDACT_da584df57bd5459098e08f92a89f9494_"
                local token = namespace .. "1__"

                local function verify(original, masked, mapping)
                    assert.is_function(restorer.verify_redaction)
                    return restorer.verify_redaction(
                        original, masked, mapping or {}, namespace
                    )
                end

                it(
                    "accepts semantic string escapes and insignificant JSON whitespace",
                    function()
                        local original =
                            '{"messages":[{"role":"user","content":' ..
                            '"line\\nsecret"}],"tool":{"name":"lookup"},' ..
                            '"number":1.2300e+40}'
                        local masked =
                            '{ "messages" : [ { "role" : "u\\u0073er", ' ..
                            '"content" : "line\\u000a' .. token .. '" } ], ' ..
                            '"tool" : { "name" : "lookup" }, ' ..
                            '"number" : 1.2300e+40 }'

                        local ok, err = verify(original, masked, {
                            [token] = "secret",
                        })

                        assert.is_true(ok)
                        assert.is_nil(err)
                    end
                )

                it(
                    "allows an empty mapping when only whitespace and escapes differ",
                    function()
                        local ok, err = verify(
                            '{"message":"slash /","values":[true,null,-0]}',
                            '{ "message" : "slash \\/", "values" : [ true, null, -0 ] }'
                        )

                        assert.is_true(ok)
                        assert.is_nil(err)
                    end
                )

                for _, case in ipairs({
                    {
                        name = "prompt content changes",
                        original = '{"prompt":"secret","role":"user"}',
                        masked = '{"prompt":"other","role":"user"}',
                        mapping = {},
                    },
                    {
                        name = "role changes",
                        original = '{"prompt":"secret","role":"user"}',
                        masked = '{"prompt":"secret","role":"assistant"}',
                        mapping = {},
                    },
                    {
                        name = "tool content changes",
                        original = '{"tool":{"name":"lookup","strict":true}}',
                        masked = '{"tool":{"name":"delete","strict":true}}',
                        mapping = {},
                    },
                    {
                        name = "numeric lexemes change",
                        original = '{"number":1.2300e+40}',
                        masked = '{"number":1.23e40}',
                        mapping = {},
                    },
                    {
                        name = "non-string values change",
                        original = '{"enabled":true,"value":null}',
                        masked = '{"enabled":false,"value":null}',
                        mapping = {},
                    },
                    {
                        name = "object key order changes",
                        original = '{"first":1,"second":2}',
                        masked = '{"second":2,"first":1}',
                        mapping = {},
                    },
                    {
                        name = "array shape changes",
                        original = '{"values":[1,2]}',
                        masked = '{"values":[1,2,3]}',
                        mapping = {},
                    },
                    {
                        name = "mapping originals disagree with the finalized body",
                        original = '{"prompt":"secret"}',
                        masked = '{"prompt":"' .. token .. '"}',
                        mapping = {[token] = "different-secret"},
                    },
                }) do
                    it(
                        "rejects when " .. case.name, function()
                            local ok, err = verify(
                                case.original, case.masked, case.mapping
                            )

                            assert.is_nil(ok)
                            assert.is_equal(
                                "redaction service changed non-sensitive request content",
                                err
                            )
                        end
                    )
                end
            end
        )

        context(
            "stream adapter safety", function()
                local namespace = "__BK_REDACT_da584df57bd5459098e08f92a89f9494_"
                local token = namespace .. "1__"

                local function frame(event_type, value)
                    local event = ""
                    if event_type then
                        event = "event: " .. event_type .. "\n"
                    end
                    return event .. "data: " .. assert(core.json.encode(value)) .. "\n\n"
                end

                local function response_frame(event_type, overrides)
                    local value = {
                        type = event_type,
                        item_id = "msg_1",
                        output_index = 0,
                    }
                    for key, item in pairs(overrides or {}) do
                        value[key] = item
                    end
                    return frame(event_type, value)
                end

                local function decoded_events(output)
                    local events = require("apisix.plugins.ai-transport.sse").decode(output)
                    for _, event in ipairs(events) do
                        event.value = assert(core.json.decode(event.data))
                    end
                    return events
                end

                it(
                    "does not retain complete logical fields", function()
                        local processor = assert(sse_restorer.new(
                            "openai-chat", {[token] = "secret"}, namespace
                        ))

                        for index = 1, 10000 do
                            local output = processor:feed(frame(nil, {
                                choices = {{
                                    index = index,
                                    delta = {content = "ordinary text"},
                                }},
                            }), false)
                            assert.is_string(output)
                        end

                        assert.is_nil(next(processor.stream.states))
                        assert.is_nil(next(processor.keys))
                        assert.is_same({}, processor.key_order)
                        assert.is_equal(0, processor.metadata_bytes)
                        assert.is_nil(next(processor.key_metadata_bytes))
                    end
                )

                it(
                    "fails closed before repeated placeholders expand past the stream limit",
                    function()
                        local original = string.rep("s", 200)
                        local processor = assert(sse_restorer.new(
                            "openai-chat", {[token] = original}, namespace, 256
                        ))
                        local input =
                            'data: {"choices":[{"index":0,"delta":{"content":"' ..
                            token .. token .. '"}}]}\n\n'

                        local ok, err = pcall(
                            processor.feed, processor, input, false
                        )
                        local masked_fallback = processor:fail_closed(input)

                        assert.is_false(ok)
                        assert.is_truthy(err:find(
                            "restored output size limit exceeded", 1, true
                        ))
                        assert.is_equal(input, masked_fallback)
                        assert.is_nil(masked_fallback:find(original, 1, true))
                    end
                )

                it(
                    "preserves numeric lexemes in restored streaming events", function()
                        local processor = assert(sse_restorer.new(
                            "openai-chat", {[token] = "13800138000"}, namespace
                        ))
                        local input =
                            'data: {"large":9007199254740993,"negative_zero":-0,' ..
                            '"exponent":1.2300e+40,"choices":[{"index":0,' ..
                            '"delta":{"content":"' .. token .. '"}}]}\n\n'
                        local expected =
                            'data: {"large":9007199254740993,"negative_zero":-0,' ..
                            '"exponent":1.2300e+40,"choices":[{"index":0,' ..
                            '"delta":{"content":"13800138000"}}]}\n\n'

                        local output, restored_count = processor:feed(input, false)

                        assert.is_equal(expected, output)
                        assert.is_equal(1, restored_count)
                    end
                )

                it(
                    "bounds aggregate response item metadata", function()
                        local processor = assert(sse_restorer.new(
                            "openai-responses", {[token] = "secret"}, namespace
                        ))
                        local prefix = token:sub(1, -2)
                        local first = response_frame("response.output_text.delta", {
                            item_id = string.rep("a", 18000),
                            content_index = 0,
                            delta = prefix,
                        })
                        local second = response_frame("response.output_text.delta", {
                            item_id = string.rep("b", 18000),
                            content_index = 0,
                            delta = prefix,
                        })

                        assert.is_string(processor:feed(first, false))
                        local ok = pcall(processor.feed, processor, second, false)

                        assert.is_false(ok)
                        assert.is_equal(1, processor.stream.active_count)
                        assert.is_true(processor.metadata_bytes <= 64 * 1024)
                        processor:fail_closed("")
                        assert.is_equal(0, processor.metadata_bytes)
                        assert.is_nil(next(processor.key_metadata_bytes))
                    end
                )

                for _, case in ipairs({
                    {
                        name = "OpenAI Chat event names",
                        protocol = "openai-chat",
                        value = {
                            choices = {{index = 0, delta = {content = token:sub(1, -2)}}},
                        },
                    },
                    {
                        name = "Anthropic event names",
                        protocol = "anthropic-messages",
                        value = {
                            type = "content_block_delta",
                            index = 0,
                            delta = {
                                type = "text_delta",
                                text = token:sub(1, -2),
                            },
                        },
                    },
                }) do
                    it(
                        "bounds long " .. case.name, function()
                            local processor = assert(sse_restorer.new(
                                case.protocol, {[token] = "secret"}, namespace
                            ))
                            local input = frame(string.rep("e", 33000), case.value)

                            local ok = pcall(processor.feed, processor, input, false)

                            assert.is_false(ok)
                            assert.is_equal(0, processor.stream.active_count)
                            assert.is_equal(0, processor.metadata_bytes)
                            assert.is_nil(next(processor.key_metadata_bytes))
                        end
                    )
                end

                it(
                    "rejects more than 1024 active logical fields", function()
                        local processor = assert(sse_restorer.new(
                            "openai-chat", {[token] = "secret"}, namespace
                        ))
                        local prefix = token:sub(1, -2)

                        for index = 1, 1024 do
                            local output = processor:feed(frame(nil, {
                                choices = {{
                                    index = index,
                                    delta = {content = prefix},
                                }},
                            }), false)
                            assert.is_string(output)
                        end

                        local ok = pcall(processor.feed, processor, frame(nil, {
                            choices = {{
                                index = 1025,
                                delta = {content = prefix},
                            }},
                        }), false)

                        assert.is_false(ok)
                    end
                )

                it(
                    "rejects more than 64 KiB of aggregate pending bytes", function()
                        local huge_token = namespace .. string.rep("1", 65536) .. "__"
                        local stream = restorer.new_stream(
                            {[huge_token] = "secret"}, namespace
                        )

                        local output, _, err = stream:feed(
                            "field", huge_token:sub(1, -2), "text", false
                        )

                        assert.is_nil(output)
                        assert.is_equal("stream pending byte limit exceeded", err)
                        assert.is_nil(next(stream.states))
                    end
                )

                it(
                    "keeps interleaved response content parts independent", function()
                        local token2 = namespace .. "2__"
                        local processor = assert(sse_restorer.new(
                            "openai-responses",
                            {[token] = "first", [token2] = "second"},
                            namespace
                        ))
                        local split1 = math.floor(#token / 2)
                        local split2 = math.floor(#token2 / 2)
                        local output = {}
                        local inputs = {
                            response_frame("response.output_text.delta", {
                                content_index = 0,
                                delta = token:sub(1, split1),
                            }),
                            response_frame("response.output_text.delta", {
                                content_index = 1,
                                delta = token2:sub(1, split2),
                            }),
                            response_frame("response.output_text.delta", {
                                content_index = 0,
                                delta = token:sub(split1 + 1),
                            }),
                            response_frame("response.output_text.delta", {
                                content_index = 1,
                                delta = token2:sub(split2 + 1),
                            }),
                        }
                        for _, input in ipairs(inputs) do
                            output[#output + 1] = processor:feed(input, false)
                        end

                        local text = {[0] = "", [1] = ""}
                        for _, event in ipairs(decoded_events(table.concat(output))) do
                            local value = event.value
                            text[value.content_index] = text[value.content_index] .. value.delta
                        end

                        assert.is_equal("first", text[0])
                        assert.is_equal("second", text[1])
                        assert.is_nil(next(processor.stream.states))
                        assert.is_nil(next(processor.keys))
                        assert.is_same({}, processor.key_order)
                    end
                )

                it(
                    "flushes only the matching response content part before done",
                    function()
                        local processor = assert(sse_restorer.new(
                            "openai-responses", {[token] = "secret"}, namespace
                        ))
                        local prefix = token:sub(1, -2)
                        assert.is_string(processor:feed(response_frame(
                            "response.output_text.delta",
                            {content_index = 0, delta = prefix}
                        ), false))
                        assert.is_string(processor:feed(response_frame(
                            "response.output_text.delta",
                            {content_index = 1, delta = prefix}
                        ), false))

                        local output = processor:feed(response_frame(
                            "response.output_text.done",
                            {content_index = 0, text = token}
                        ), false)
                        local events = decoded_events(output)

                        assert.is_equal(2, #events)
                        assert.is_equal("response.output_text.delta", events[1].value.type)
                        assert.is_equal(0, events[1].value.content_index)
                        assert.is_equal(prefix, events[1].value.delta)
                        assert.is_equal("response.output_text.done", events[2].value.type)
                        assert.is_equal(0, events[2].value.content_index)
                        assert.is_equal("secret", events[2].value.text)
                        assert.is_not_nil(next(processor.stream.states))

                        local remaining = decoded_events(processor:feed(
                            response_frame("response.output_text.done", {
                                content_index = 1,
                                text = token,
                            }),
                            false
                        ))
                        assert.is_equal(2, #remaining)
                        assert.is_equal(1, remaining[1].value.content_index)
                        assert.is_equal(prefix, remaining[1].value.delta)
                        assert.is_equal("secret", remaining[2].value.text)
                        assert.is_nil(next(processor.stream.states))
                    end
                )

                it(
                    "keeps reasoning summary parts independent through done events",
                    function()
                        local token2 = namespace .. "2__"
                        local processor = assert(sse_restorer.new(
                            "openai-responses",
                            {[token] = "first", [token2] = "second"},
                            namespace
                        ))
                        local split1 = math.floor(#token / 2)
                        local split2 = math.floor(#token2 / 2)
                        local output = {}
                        local inputs = {
                            response_frame("response.reasoning_summary_text.delta", {
                                summary_index = 0,
                                delta = token:sub(1, split1),
                            }),
                            response_frame("response.reasoning_summary_text.delta", {
                                summary_index = 1,
                                delta = token2:sub(1, split2),
                            }),
                            response_frame("response.reasoning_summary_text.delta", {
                                summary_index = 0,
                                delta = token:sub(split1 + 1),
                            }),
                            response_frame("response.reasoning_summary_text.done", {
                                summary_index = 0,
                                text = token,
                            }),
                            response_frame("response.reasoning_summary_text.delta", {
                                summary_index = 1,
                                delta = token2:sub(split2 + 1),
                            }),
                            response_frame("response.reasoning_summary_text.done", {
                                summary_index = 1,
                                text = token2,
                            }),
                        }
                        for _, input in ipairs(inputs) do
                            output[#output + 1] = processor:feed(input, false)
                        end

                        local delta_text = {[0] = "", [1] = ""}
                        local done_text = {}
                        for _, event in ipairs(decoded_events(table.concat(output))) do
                            local value = event.value
                            if value.type == "response.reasoning_summary_text.delta" then
                                delta_text[value.summary_index] =
                                    delta_text[value.summary_index] .. value.delta
                            elseif value.type == "response.reasoning_summary_text.done" then
                                done_text[value.summary_index] = value.text
                            end
                        end

                        assert.is_equal("first", delta_text[0])
                        assert.is_equal("second", delta_text[1])
                        assert.is_equal("first", done_text[0])
                        assert.is_equal("second", done_text[1])
                    end
                )

                it(
                    "flushes function arguments before their done event", function()
                        local processor = assert(sse_restorer.new(
                            "openai-responses", {[token] = "secret"}, namespace
                        ))
                        local prefix = token:sub(1, -2)
                        assert.is_string(processor:feed(response_frame(
                            "response.function_call_arguments.delta",
                            {item_id = "call_1", delta = prefix}
                        ), false))

                        local events = decoded_events(processor:feed(response_frame(
                            "response.function_call_arguments.done",
                            {item_id = "call_1", arguments = token}
                        ), false))

                        assert.is_equal(2, #events)
                        assert.is_equal(
                            "response.function_call_arguments.delta",
                            events[1].value.type
                        )
                        assert.is_equal(prefix, events[1].value.delta)
                        assert.is_equal(
                            "response.function_call_arguments.done",
                            events[2].value.type
                        )
                        assert.is_equal("secret", events[2].value.arguments)
                    end
                )

                it(
                    "preserves response frames with non-numeric part indices", function()
                        local processor = assert(sse_restorer.new(
                            "openai-responses", {[token] = "secret"}, namespace
                        ))
                        local invalid = response_frame(
                            "response.output_text.delta",
                            {content_index = "0", delta = token}
                        )

                        local output = processor:feed(invalid, false)

                        assert.is_equal(invalid, output)
                        assert.is_nil(output:find("secret", 1, true))
                    end
                )

                it(
                    "restores all supported OpenAI Chat delta fields", function()
                        local processor = assert(sse_restorer.new(
                            "openai-chat", {[token] = "secret"}, namespace
                        ))
                        local input = frame(nil, {
                            choices = {{
                                index = 0,
                                delta = {
                                    reasoning_content = token,
                                    refusal = token,
                                    function_call = {arguments = token},
                                    tool_calls = {{
                                        index = 0,
                                        ["function"] = {arguments = token},
                                    }},
                                },
                            }},
                        })

                        local events = decoded_events(processor:feed(input, false))
                        local delta = events[1].value.choices[1].delta

                        assert.is_equal("secret", delta.reasoning_content)
                        assert.is_equal("secret", delta.refusal)
                        assert.is_equal("secret", delta.function_call.arguments)
                        assert.is_equal(
                            "secret", delta.tool_calls[1]["function"].arguments
                        )
                    end
                )
            end
        )

        context(
            "stream response restoration", function()
                it(
                    "restores split SSE placeholders and clears state only at EOF",
                    function()
                        local request_id = "da584df5-7bd5-4590-98e0-8f92a89f9494"
                        local namespace =
                            "__BK_REDACT_da584df57bd5459098e08f92a89f9494_"
                        local known = namespace .. "1__"
                        local split_at = math.floor(#known / 2)
                        local ctx = request_context({
                            var = {request_type = "ai_stream"},
                            _ai_redaction_request_id = request_id,
                            _ai_redaction_session_id =
                                "24395b38-bf3f-426c-a632-10df20ec69c8",
                            _ai_redaction_namespace = namespace,
                            _ai_redaction_mapping = {[known] = "13800138000"},
                        })
                        local event1 = "data: " .. assert(core.json.encode({
                            choices = {
                                {
                                    index = 0,
                                    delta = {content = "phone: " .. known:sub(1, split_at)},
                                },
                            },
                        })) .. "\n\n"
                        local event2 = "data: " .. assert(core.json.encode({
                            choices = {
                                {
                                    index = 0,
                                    delta = {content = known:sub(split_at + 1)},
                                },
                            },
                        })) .. "\n\ndata: [DONE]\n\n"

                        local code1, output1 = plugin.lua_body_filter(
                            config(), ctx, {}, event1, false
                        )
                        local processor = ctx._ai_redaction_sse_restorer
                        local code2, output2 = plugin.lua_body_filter(
                            config(), ctx, {}, event2, false
                        )

                        assert.is_nil(code1)
                        assert.is_nil(code2)
                        assert.is_not_nil(processor)
                        assert.is_equal(processor, ctx._ai_redaction_sse_restorer)
                        assert.is_falsy(output1:find(known, 1, true))
                        assert.is_truthy(output2:find("13800138000", 1, true))
                        assert.is_truthy(output2:find("data: [DONE]", 1, true))
                        assert.is_same({[known] = "13800138000"}, ctx._ai_redaction_mapping)
                        assert.is_equal(1, ctx._ai_redaction_restored_count)
                        assert.is_equal(0, ctx._ai_redaction_unresolved_count)

                        local code3, output3 = plugin.lua_body_filter(
                            config(), ctx, {}, "", true
                        )

                        assert.is_nil(code3)
                        assert.is_equal("", output3)
                        assert.is_equal(request_id, ctx._ai_redaction_request_id)
                        assert.is_nil(ctx._ai_redaction_session_id)
                        assert.is_nil(ctx._ai_redaction_namespace)
                        assert.is_nil(ctx._ai_redaction_mapping)
                        assert.is_nil(ctx._ai_redaction_sse_restorer)
                        assert.is_equal(1, ctx._ai_redaction_restored_count)
                        assert.is_equal(0, ctx._ai_redaction_unresolved_count)
                    end
                )
            end
        )

        context(
            "stream failure fallback", function()
                before_each(
                    function()
                        stub(core.log, "error")
                    end
                )

                after_each(
                    function()
                        core.log.error:revert()
                    end
                )

                it(
                    "latches masked passthrough when processor construction fails",
                    function()
                        local request_id = "cfb5b639-d51b-42d6-b62c-f1083007376a"
                        local namespace =
                            "__BK_REDACT_cfb5b639d51b42d6b62cf1083007376a_"
                        local token = namespace .. "1__"
                        local frame = "data: {\"masked\":\"" .. token .. "\"}\n\n"
                        local ctx = request_context({
                            var = {request_type = "ai_stream"},
                            _ai_redaction_request_id = request_id,
                            _ai_redaction_session_id =
                                "24395b38-bf3f-426c-a632-10df20ec69c8",
                            _ai_redaction_namespace = namespace,
                            _ai_redaction_mapping = nil,
                        })

                        local code1, output1 = plugin.lua_body_filter(
                            config(), ctx, {}, frame, false
                        )
                        local code2, output2 = plugin.lua_body_filter(
                            config(), ctx, {}, frame, true
                        )

                        assert.is_nil(code1)
                        assert.is_nil(code2)
                        assert.is_equal(frame, output1)
                        assert.is_equal(frame, output2)
                        assert.is_falsy(output1:find("13800138000", 1, true))
                        assert.is_true(ctx._ai_redaction_stream_passthrough)
                        assert.is_equal(0, ctx._ai_redaction_restored_count)
                        assert.is_equal(0, ctx._ai_redaction_unresolved_count)
                        assert.is_nil(ctx._ai_redaction_session_id)
                        assert.is_nil(ctx._ai_redaction_namespace)
                        assert.is_nil(ctx._ai_redaction_mapping)
                        assert.is_nil(ctx._ai_redaction_sse_restorer)
                        assert.stub(core.log.error).was_called(1)
                        assert.stub(core.log.error).was_called_with(
                            "failed to create SSE restorer",
                            ", request_id: ",
                            request_id
                        )
                    end
                )

                it(
                    "preserves buffered masked bytes and latches after feed failure",
                    function()
                        local request_id = "157240cf-4f4b-412d-8240-9f904123aa0d"
                        local namespace =
                            "__BK_REDACT_157240cf4f4b412d82409f904123aa0d_"
                        local token = namespace .. "1__"
                        local processor = assert(sse_restorer.new(
                            "openai-chat", {[token] = "13800138000"}, namespace
                        ))
                        local buffered = "data: {\"choices\":["
                        assert.is_equal("", processor:feed(buffered, false))
                        local feed_count = 0
                        processor.feed = function()
                            feed_count = feed_count + 1
                            error("unexpected feed failure with sensitive values")
                        end
                        local ctx = request_context({
                            var = {request_type = "ai_stream"},
                            _ai_redaction_request_id = request_id,
                            _ai_redaction_session_id =
                                "24395b38-bf3f-426c-a632-10df20ec69c8",
                            _ai_redaction_namespace = namespace,
                            _ai_redaction_mapping = {[token] = "13800138000"},
                            _ai_redaction_sse_restorer = processor,
                            _ai_redaction_restored_count = 3,
                            _ai_redaction_unresolved_count = 4,
                        })
                        local remainder = "1]}\n\n"
                        local valid = "data: {\"choices\":[{\"delta\":{\"content\":\"" ..
                                      token .. "\"}}]}\n\n"

                        local code1, output1 = plugin.lua_body_filter(
                            config(), ctx, {}, remainder, false
                        )
                        local code2, output2 = plugin.lua_body_filter(
                            config(), ctx, {}, valid, true
                        )

                        assert.is_nil(code1)
                        assert.is_nil(code2)
                        assert.is_equal(buffered .. remainder, output1)
                        assert.is_equal(valid, output2)
                        assert.is_falsy(output1:find("13800138000", 1, true))
                        assert.is_falsy(output2:find("13800138000", 1, true))
                        assert.is_equal(1, feed_count)
                        assert.is_true(ctx._ai_redaction_stream_passthrough)
                        assert.is_equal(3, ctx._ai_redaction_restored_count)
                        assert.is_equal(4, ctx._ai_redaction_unresolved_count)
                        assert.is_nil(ctx._ai_redaction_session_id)
                        assert.is_nil(ctx._ai_redaction_namespace)
                        assert.is_nil(ctx._ai_redaction_mapping)
                        assert.is_nil(ctx._ai_redaction_sse_restorer)
                        assert.stub(core.log.error).was_called(1)
                        assert.stub(core.log.error).was_called_with(
                            "failed to restore masked SSE response",
                            ", request_id: ",
                            request_id
                        )
                    end
                )

                it(
                    "preserves masked prefixes exactly once when active state overflows",
                    function()
                        local request_id = "e7c1ca39-a99e-4934-af01-babb28956d47"
                        local namespace =
                            "__BK_REDACT_e7c1ca39a99e4934af01babb28956d47_"
                        local token = namespace .. "1__"
                        local prefix = token:sub(1, -2)
                        local ctx = request_context({
                            var = {request_type = "ai_stream"},
                            _ai_redaction_request_id = request_id,
                            _ai_redaction_namespace = namespace,
                            _ai_redaction_mapping = {[token] = "sensitive-original"},
                        })
                        local function chat_frame(index)
                            return "data: " .. assert(core.json.encode({
                                choices = {{
                                    index = index,
                                    delta = {content = prefix},
                                }},
                            })) .. "\n\n"
                        end

                        local first = chat_frame(0)
                        local code1, output1 = plugin.lua_body_filter(
                            config(), ctx, {}, first, false
                        )
                        local overflow = {}
                        for index = 1, 1024 do
                            overflow[index] = chat_frame(index)
                        end
                        local raw_overflow = table.concat(overflow)
                        local code2, output2 = plugin.lua_body_filter(
                            config(), ctx, {}, raw_overflow, false
                        )

                        local combined = output1 .. output2
                        local occurrences = 0
                        local position = 1
                        while true do
                            local found = combined:find(prefix, position, true)
                            if not found then
                                break
                            end
                            occurrences = occurrences + 1
                            position = found + #prefix
                        end
                        assert.is_nil(code1)
                        assert.is_nil(code2)
                        assert.is_equal(1025, occurrences)
                        assert.is_nil(combined:find("sensitive-original", 1, true))
                        assert.is_true(ctx._ai_redaction_stream_passthrough)
                        assert.is_nil(ctx._ai_redaction_mapping)
                        assert.is_nil(ctx._ai_redaction_sse_restorer)
                        assert.stub(core.log.error).was_called(1)
                    end
                )

                it(
                    "rolls back and clears metadata overflow without duplicating its chunk",
                    function()
                        local request_id = "8a2fa378-5002-4035-88e5-82b637117490"
                        local namespace =
                            "__BK_REDACT_8a2fa3785002403588e582b637117490_"
                        local token = namespace .. "1__"
                        local prefix = token:sub(1, -2)
                        local ctx = request_context({
                            var = {request_type = "ai_stream"},
                            ai_client_protocol = "openai-responses",
                            _ai_redaction_request_id = request_id,
                            _ai_redaction_namespace = namespace,
                            _ai_redaction_mapping = {[token] = "sensitive-original"},
                        })
                        local function response_delta(item_id, delta)
                            local event_type = "response.output_text.delta"
                            return "event: " .. event_type .. "\ndata: " ..
                                   assert(core.json.encode({
                                       type = event_type,
                                       item_id = item_id,
                                       output_index = 0,
                                       content_index = 0,
                                       delta = delta,
                                   })) .. "\n\n"
                        end

                        local first = response_delta(string.rep("a", 18000), prefix)
                        local code1, output1 = plugin.lua_body_filter(
                            config(), ctx, {}, first, false
                        )
                        local processor = ctx._ai_redaction_sse_restorer
                        local complete = response_delta(
                            string.rep("c", 40000), "ordinary text"
                        )
                        local overflowing = response_delta(
                            string.rep("b", 18000), prefix
                        )
                        local current_chunk = complete .. overflowing
                        local code2, output2 = plugin.lua_body_filter(
                            config(), ctx, {}, current_chunk, false
                        )

                        local combined = output1 .. output2
                        local occurrences = 0
                        local position = 1
                        while true do
                            local found = combined:find(prefix, position, true)
                            if not found then
                                break
                            end
                            occurrences = occurrences + 1
                            position = found + #prefix
                        end
                        assert.is_nil(code1)
                        assert.is_nil(code2)
                        assert.is_equal(current_chunk, output2:sub(-#current_chunk))
                        assert.is_equal(2, occurrences)
                        assert.is_nil(combined:find("sensitive-original", 1, true))
                        assert.is_true(ctx._ai_redaction_stream_passthrough)
                        assert.is_nil(ctx._ai_redaction_mapping)
                        assert.is_nil(ctx._ai_redaction_sse_restorer)
                        assert.is_equal(0, processor.stream.active_count)
                        assert.is_equal(0, processor.stream.pending_bytes)
                        assert.is_equal(0, processor.metadata_bytes)
                        assert.is_nil(next(processor.stream.states))
                        assert.is_nil(next(processor.keys))
                        assert.is_nil(next(processor.key_metadata_bytes))
                        assert.is_same({}, processor.key_order)
                        assert.stub(core.log.error).was_called(1)
                    end
                )
            end
        )

        context(
            "non-stream response restoration", function()
                before_each(
                    function()
                        stub(core.log, "error")
                    end
                )

                after_each(
                    function()
                        core.log.error:revert()
                    end
                )

                it(
                    "restores nested JSON strings and clears request-sensitive state",
                    function()
                        local request_id = "da584df5-7bd5-4590-98e0-8f92a89f9494"
                        local namespace =
                            "__BK_REDACT_da584df57bd5459098e08f92a89f9494_"
                        local known = namespace .. "1__"
                        local unknown = namespace .. "9__"
                        local original = "line one\n\"line two\""
                        local ctx = request_context({
                            var = {request_type = "ai_chat"},
                            _ai_redaction_request_id = request_id,
                            _ai_redaction_session_id =
                                "24395b38-bf3f-426c-a632-10df20ec69c8",
                            _ai_redaction_namespace = namespace,
                            _ai_redaction_mapping = {[known] = original},
                            _ai_redaction_sse_restorer = {},
                        })
                        local response = {
                            choices = {
                                {
                                    message = {
                                        content = "echo: " .. known .. ":" .. unknown,
                                        tool_calls = {
                                            {
                                                id = "call_1",
                                                type = "function",
                                                ["function"] = {
                                                    name = "save_contact",
                                                    arguments = core.json.encode({phone = known}),
                                                },
                                            },
                                        },
                                    },
                                },
                            },
                        }

                        local code, restored_body = plugin.lua_body_filter(
                            config(), ctx, {}, assert(core.json.encode(response)), true
                        )

                        assert.is_nil(code)
                        local restored = assert(core.json.decode(restored_body))
                        assert.is_equal(
                            "echo: " .. original .. ":" .. unknown,
                            restored.choices[1].message.content
                        )
                        local arguments = assert(core.json.decode(
                            restored.choices[1].message.tool_calls[1]["function"].arguments
                        ))
                        assert.is_equal(original, arguments.phone)
                        assert.is_equal(2, ctx._ai_redaction_restored_count)
                        assert.is_equal(request_id, ctx._ai_redaction_request_id)
                        assert.is_nil(ctx._ai_redaction_session_id)
                        assert.is_nil(ctx._ai_redaction_namespace)
                        assert.is_nil(ctx._ai_redaction_mapping)
                        assert.is_nil(ctx._ai_redaction_sse_restorer)
                    end
                )

                it(
                    "preserves response numeric lexemes while restoring string values",
                    function()
                        local request_id = "da584df5-7bd5-4590-98e0-8f92a89f9494"
                        local namespace =
                            "__BK_REDACT_da584df57bd5459098e08f92a89f9494_"
                        local known = namespace .. "1__"
                        local ctx = request_context({
                            var = {request_type = "ai_chat"},
                            _ai_redaction_request_id = request_id,
                            _ai_redaction_namespace = namespace,
                            _ai_redaction_mapping = {[known] = "13800138000"},
                        })
                        local masked_body =
                            '{ "large":9007199254740993, "negative_zero":-0, ' ..
                            '"exponent":1.2300e+40, "content":"' .. known .. '" }'
                        local expected =
                            '{ "large":9007199254740993, "negative_zero":-0, ' ..
                            '"exponent":1.2300e+40, "content":"13800138000" }'

                        local code, restored_body = plugin.lua_body_filter(
                            config(), ctx, {}, masked_body, true
                        )

                        assert.is_nil(code)
                        assert.is_equal(expected, restored_body)
                        assert.is_equal(1, ctx._ai_redaction_restored_count)
                        assert.is_nil(ctx._ai_redaction_namespace)
                        assert.is_nil(ctx._ai_redaction_mapping)
                    end
                )

                it(
                    "rejects repeated-placeholder expansion before concatenation",
                    function()
                        local namespace =
                            "__BK_REDACT_da584df57bd5459098e08f92a89f9494_"
                        local known = namespace .. "1__"
                        local masked_body = '{"content":"' .. known .. known .. '"}'

                        local restored, err = restorer.restore_json_text(
                            masked_body,
                            {[known] = string.rep("s", 100)},
                            namespace,
                            128
                        )

                        assert.is_nil(restored)
                        assert.is_equal("restored output size limit exceeded", err)
                    end
                )

                it(
                    "passes the masked response through when expansion exceeds the route bound",
                    function()
                        local request_id = "da584df5-7bd5-4590-98e0-8f92a89f9494"
                        local namespace =
                            "__BK_REDACT_da584df57bd5459098e08f92a89f9494_"
                        local known = namespace .. "1__"
                        local masked_body =
                            '{"content":"' .. string.rep(known, 70) .. '"}'
                        local ctx = request_context({
                            var = {request_type = "ai_chat"},
                            _ai_redaction_request_id = request_id,
                            _ai_redaction_namespace = namespace,
                            _ai_redaction_mapping = {
                                [known] = string.rep("s", 4000),
                            },
                        })

                        local code, restored_body = plugin.lua_body_filter(
                            config({
                                max_request_body_bytes = 4096,
                                max_mapping_bytes = 4096,
                                max_mapping_entries = 1,
                            }),
                            ctx,
                            {},
                            masked_body,
                            true
                        )

                        assert.is_nil(code)
                        assert.is_nil(restored_body)
                        assert.is_nil(masked_body:find(string.rep("s", 4000), 1, true))
                        assert.is_nil(ctx._ai_redaction_mapping)
                        assert.stub(core.log.error).was_called_with(
                            "failed to restore masked AI response",
                            ", request_id: ",
                            request_id
                        )
                    end
                )

                it(
                    "passes invalid upstream JSON through masked and clears state",
                    function()
                        local request_id = "da584df5-7bd5-4590-98e0-8f92a89f9494"
                        local namespace =
                            "__BK_REDACT_da584df57bd5459098e08f92a89f9494_"
                        local known = namespace .. "1__"
                        local cases = {
                            '{"content":"' .. known .. '"',
                            '{"content":"' .. known .. '"} trailing',
                            string.rep("[", 129) .. '"' .. known .. '"' ..
                                string.rep("]", 129),
                            '{"content":"\\uD800"}',
                            '{"' .. string.char(0x80) .. '":"value"}',
                        }

                        for _, masked_body in ipairs(cases) do
                            local ctx = request_context({
                                var = {request_type = "ai_chat"},
                                _ai_redaction_request_id = request_id,
                                _ai_redaction_session_id =
                                    "24395b38-bf3f-426c-a632-10df20ec69c8",
                                _ai_redaction_namespace = namespace,
                                _ai_redaction_mapping = {[known] = "13800138000"},
                                _ai_redaction_sse_restorer = {},
                                _ai_redaction_restored_count = 7,
                            })

                            local code, restored_body = plugin.lua_body_filter(
                                config(), ctx, {}, masked_body, true
                            )

                            assert.is_nil(code)
                            assert.is_nil(restored_body)
                            assert.is_equal(request_id, ctx._ai_redaction_request_id)
                            assert.is_equal(7, ctx._ai_redaction_restored_count)
                            assert.is_nil(ctx._ai_redaction_session_id)
                            assert.is_nil(ctx._ai_redaction_namespace)
                            assert.is_nil(ctx._ai_redaction_mapping)
                            assert.is_nil(ctx._ai_redaction_sse_restorer)
                        end

                        assert.stub(core.log.error).was_called(5)
                        assert.stub(core.log.error).was_called_with(
                            "failed to restore masked AI response",
                            ", request_id: ",
                            request_id
                        )
                    end
                )
            end
        )
    end
)
