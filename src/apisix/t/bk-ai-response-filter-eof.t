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

=== TEST 1: existing four-argument response filter remains compatible
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugin")
            local fake = {
                name = "test-four-argument-filter",
                lua_body_filter = function(_, _, _, body)
                    return nil, body .. ":legacy"
                end,
            }
            local api_ctx = {plugins = {fake, {}}, var = {}}
            local ok, err = plugin.lua_response_filter(
                api_ctx, {}, "payload", true, false)
            if not ok then
                ngx.say(err)
            end
        }
    }
--- response_body: payload:legacy



=== TEST 2: response filter receives EOF marker
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugin")
            local fake = {
                name = "test-eof-filter",
                lua_body_filter = function(_, _, _, body, eof)
                    return nil, body .. ":eof=" .. tostring(eof)
                end,
            }
            local api_ctx = {plugins = {fake, {}}, var = {}}
            local ok, err, emitted = plugin.lua_response_filter(
                api_ctx, {}, "payload", true, false, true)
            if not ok then
                ngx.say(err)
            end
            ngx.say(":emitted=", emitted)
        }
    }
--- response_body
payload:eof=true:emitted=true



=== TEST 3: converter no-output error still finalizes response filters
--- config
    location /t {
        content_by_lua_block {
            local base = require("apisix.plugins.ai-providers.base")
            local eof_calls = 0
            local ctx_abort_reason
            local fake = {
                name = "test-converter-eof-filter",
                lua_body_filter = function(_, _, _, body, eof, abort_reason)
                    if eof then
                        eof_calls = eof_calls + 1
                        ctx_abort_reason = abort_reason
                    end
                    return nil, body
                end,
            }
            local ctx = {
                plugins = {fake, {}},
                var = {},
                llm_request_start_time = ngx.now(),
            }
            local chunks = {"data: {}\n\n"}
            local chunk_index = 0
            local res = {
                headers = {},
                body_reader = function()
                    chunk_index = chunk_index + 1
                    return chunks[chunk_index]
                end,
            }
            local target_proto = {
                parse_sse_event = function()
                    return {type = "data"}
                end,
            }
            local converter = {
                convert_sse_events = function()
                    return nil
                end,
            }

            local code = base.parse_streaming_response(
                base, ctx, res, target_proto, converter,
                {streaming_flush_interval_ms = 0})
            local headers_sent = ngx.headers_sent
            if code and not headers_sent then
                ngx.status = code
            end
            ngx.say("code:", code, ", eof_calls:", eof_calls,
                    ", reason:", ctx_abort_reason,
                    ", headers_sent:", headers_sent)
        }
    }
--- response_body
code:502, eof_calls:1, reason:converter_no_output, headers_sent:false
--- error_code: 502
--- error_log
streaming response completed without producing any output



=== TEST 4: legacy stateful response filter sees empty per-chunk content at EOF
--- config
    location /t {
        content_by_lua_block {
            local base = require("apisix.plugins.ai-providers.base")
            local seen = {}
            local fake = {
                name = "test-stateful-four-argument-filter",
                lua_body_filter = function(_, ctx, _, _)
                    seen[#seen + 1] = table.concat(
                        ctx.llm_response_contents_in_chunk or {}, "")
                    return nil, ""
                end,
            }
            local ctx = {
                plugins = {fake, {}},
                var = {},
                llm_request_start_time = ngx.now(),
            }
            local chunks = {"data: {}\n\n"}
            local chunk_index = 0
            local res = {
                headers = {},
                body_reader = function()
                    chunk_index = chunk_index + 1
                    return chunks[chunk_index]
                end,
            }
            local target_proto = {
                parse_sse_event = function()
                    return {type = "data", texts = {"chunk"}}
                end,
            }

            base.parse_streaming_response(
                base, ctx, res, target_proto, nil,
                {streaming_flush_interval_ms = 0})
            ngx.say("calls:", #seen, ", seen:", table.concat(seen, "|"))
        }
    }
--- response_body
calls:2, seen:chunk|



=== TEST 5: response byte limit finalizes real redaction filter state
--- config
    location /t {
        content_by_lua_block {
            local base = require("apisix.plugins.ai-providers.base")
            local core = require("apisix.core")
            local redaction = require("apisix.plugins.bk-ai-sensitive-data-redaction")
            local request_id = "dd9a210e-0296-445f-a2c6-335d8d45ceda"
            local namespace = "__BK_REDACT_dd9a210e0296445fa2c6335d8d45ceda_"
            local token = namespace .. "1__"
            local prefix = token:sub(1, -2)
            local captured = {}
            local sink = {
                name = "test-capture-redaction-output",
                lua_body_filter = function(_, _, _, body)
                    captured[#captured + 1] = body
                    return nil, body
                end,
            }
            local ctx = {
                plugins = {redaction, {}, sink, {}},
                var = {request_type = "ai_stream", route_id = "test-route"},
                ai_client_protocol = "openai-chat",
                llm_request_start_time = ngx.now(),
                _ai_redaction_request_id = request_id,
                _ai_redaction_session_id = "test-session",
                _ai_redaction_namespace = namespace,
                _ai_redaction_mapping = {[token] = "sensitive-original"},
            }
            local chunk = "data: " .. assert(core.json.encode({
                choices = {{
                    index = 0,
                    delta = {content = prefix},
                }},
            })) .. "\n\n"
            local read_count = 0
            local res = {
                headers = {},
                body_reader = function()
                    read_count = read_count + 1
                    if read_count == 1 then
                        return chunk
                    end
                end,
            }
            local target_proto = {
                parse_sse_event = function()
                    return {type = "data"}
                end,
            }

            local code = base.parse_streaming_response(
                base, ctx, res, target_proto, nil,
                {
                    streaming_flush_interval_ms = 0,
                    max_response_bytes = #chunk - 1,
                })

            local output = table.concat(captured)
            local occurrences = 0
            local position = 1
            while true do
                local found = output:find(prefix, position, true)
                if not found then
                    break
                end
                occurrences = occurrences + 1
                position = found + #prefix
            end
            local cleared = ctx._ai_redaction_mapping == nil
                            and ctx._ai_redaction_session_id == nil
                            and ctx._ai_redaction_namespace == nil
                            and ctx._ai_redaction_sse_restorer == nil
            ngx.say("occurrences:", occurrences, ", cleared:", cleared,
                    ", unresolved:", ctx._ai_redaction_unresolved_count,
                    ", code:", code or "nil")
        }
    }
--- response_body_like eval
qr/occurrences:1, cleared:true, unresolved:1, code:nil/
--- error_code: 200
--- error_log
aborting AI stream: max_response_bytes exceeded



=== TEST 6: stream duration limit finalizes real redaction filter state
--- config
    location /t {
        content_by_lua_block {
            local base = require("apisix.plugins.ai-providers.base")
            local core = require("apisix.core")
            local redaction = require("apisix.plugins.bk-ai-sensitive-data-redaction")
            local request_id = "a9d58e99-86bf-4165-a621-640db1df1671"
            local namespace = "__BK_REDACT_a9d58e9986bf4165a621640db1df1671_"
            local token = namespace .. "1__"
            local prefix = token:sub(1, -2)
            local captured = {}
            local sink = {
                name = "test-capture-redaction-output",
                lua_body_filter = function(_, _, _, body)
                    captured[#captured + 1] = body
                    return nil, body
                end,
            }
            local ctx = {
                plugins = {redaction, {}, sink, {}},
                var = {request_type = "ai_stream", route_id = "test-route"},
                ai_client_protocol = "openai-chat",
                llm_request_start_time = ngx.now() - 1,
                _ai_redaction_request_id = request_id,
                _ai_redaction_session_id = "test-session",
                _ai_redaction_namespace = namespace,
                _ai_redaction_mapping = {[token] = "sensitive-original"},
            }
            local chunk = "data: " .. assert(core.json.encode({
                choices = {{
                    index = 0,
                    delta = {content = prefix},
                }},
            })) .. "\n\n"
            local read_count = 0
            local res = {
                headers = {},
                body_reader = function()
                    read_count = read_count + 1
                    if read_count == 1 then
                        return chunk
                    end
                end,
            }
            local target_proto = {
                parse_sse_event = function()
                    return {type = "data"}
                end,
            }

            local code = base.parse_streaming_response(
                base, ctx, res, target_proto, nil,
                {
                    streaming_flush_interval_ms = 0,
                    max_stream_duration_ms = 1,
                })

            local output = table.concat(captured)
            local occurrences = 0
            local position = 1
            while true do
                local found = output:find(prefix, position, true)
                if not found then
                    break
                end
                occurrences = occurrences + 1
                position = found + #prefix
            end
            local cleared = ctx._ai_redaction_mapping == nil
                            and ctx._ai_redaction_session_id == nil
                            and ctx._ai_redaction_namespace == nil
                            and ctx._ai_redaction_sse_restorer == nil
            ngx.say("occurrences:", occurrences, ", cleared:", cleared,
                    ", unresolved:", ctx._ai_redaction_unresolved_count,
                    ", code:", code or "nil")
        }
    }
--- response_body_like eval
qr/occurrences:1, cleared:true, unresolved:1, code:nil/
--- error_code: 200
--- error_log
aborting AI stream: max_stream_duration_ms exceeded



=== TEST 7: empty EOF leaves headers uncommitted and reports no emitted bytes
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugin")
            local fake = {
                name = "test-empty-eof-filter",
                lua_body_filter = function(_, _, _, body)
                    return ngx.OK, body
                end,
            }
            local api_ctx = {plugins = {fake, {}}, var = {}}
            local before = ngx.headers_sent
            local ok, err, emitted = plugin.lua_response_filter(
                api_ctx, {}, "", true, false, true, "stream_limit")
            local after = ngx.headers_sent
            ngx.status = 502
            ngx.say("ok:", ok, ", err:", err or "nil",
                    ", emitted:", emitted,
                    ", before:", before, ", after:", after)
        }
    }
--- response_body
ok:true, err:nil, emitted:false, before:false, after:false
--- error_code: 502



=== TEST 8: emitted limit EOF converts no-output error into partial output
--- config
    location /t {
        content_by_lua_block {
            local base = require("apisix.plugins.ai-providers.base")
            local eof_calls = 0
            local abort_reason
            local fake = {
                name = "test-emitted-limit-eof-filter",
                lua_body_filter = function(_, _, _, body, eof, reason)
                    if eof then
                        eof_calls = eof_calls + 1
                        abort_reason = reason
                        return nil, "pending-eof"
                    end
                    return nil, body
                end,
            }
            local ctx = {
                plugins = {fake, {}},
                var = {route_id = "test-route"},
                llm_request_start_time = ngx.now(),
            }
            local read_count = 0
            local res = {
                headers = {},
                body_reader = function()
                    read_count = read_count + 1
                    if read_count == 1 then
                        return "data: {}\n\n"
                    end
                end,
            }
            local target_proto = {
                parse_sse_event = function()
                    return {type = "data"}
                end,
            }
            local converter = {
                convert_sse_events = function()
                    return nil
                end,
            }

            local code = base.parse_streaming_response(
                base, ctx, res, target_proto, converter,
                {streaming_flush_interval_ms = 0, max_response_bytes = 1})
            ngx.say("|code:", code or "nil",
                    ", eof_calls:", eof_calls,
                    ", reason:", abort_reason,
                    ", headers_sent:", ngx.headers_sent)
        }
    }
--- response_body
pending-eof|code:nil, eof_calls:1, reason:stream_limit, headers_sent:true
--- error_code: 200
--- error_log
aborting AI stream: max_response_bytes exceeded



=== TEST 9: upstream read error finalizes with an abnormal reason
--- config
    location /t {
        content_by_lua_block {
            local base = require("apisix.plugins.ai-providers.base")
            local eof_calls = 0
            local abort_reason
            local fake = {
                name = "test-upstream-error-eof-filter",
                lua_body_filter = function(_, _, _, body, eof, reason)
                    if eof then
                        eof_calls = eof_calls + 1
                        abort_reason = reason
                    end
                    return nil, body
                end,
            }
            local ctx = {
                plugins = {fake, {}},
                var = {},
                llm_request_start_time = ngx.now(),
            }
            local res = {
                headers = {},
                body_reader = function()
                    return nil, "timeout"
                end,
            }
            local target_proto = {
                parse_sse_event = function()
                    return {type = "data"}
                end,
            }

            local code = base.parse_streaming_response(
                base, ctx, res, target_proto, nil,
                {streaming_flush_interval_ms = 0})
            local headers_sent = ngx.headers_sent
            if code and not headers_sent then
                ngx.status = code
            end
            ngx.say("code:", code, ", eof_calls:", eof_calls,
                    ", reason:", abort_reason,
                    ", headers_sent:", headers_sent)
        }
    }
--- response_body
code:504, eof_calls:1, reason:upstream_read_error, headers_sent:false
--- error_code: 504
--- error_log
failed to read response chunk: timeout



=== TEST 10: downstream disconnect does not invoke EOF finalization
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugin")
            local base = require("apisix.plugins.ai-providers.base")
            local original_filter = plugin.lua_response_filter
            local calls = 0
            local eof_calls = 0
            plugin.lua_response_filter = function(_, _, _, _, _, eof)
                calls = calls + 1
                if eof then
                    eof_calls = eof_calls + 1
                end
                return false, "closed"
            end
            local closed = 0
            local read_count = 0
            local res = {
                headers = {},
                _httpc = {
                    close = function()
                        closed = closed + 1
                    end,
                },
                body_reader = function()
                    read_count = read_count + 1
                    if read_count == 1 then
                        return "data: {}\n\n"
                    end
                end,
            }
            local ctx = {
                plugins = {},
                var = {},
                llm_request_start_time = ngx.now(),
            }
            local target_proto = {
                parse_sse_event = function()
                    return {type = "data"}
                end,
            }

            local code = base.parse_streaming_response(
                base, ctx, res, target_proto, nil,
                {streaming_flush_interval_ms = 0})
            plugin.lua_response_filter = original_filter
            ngx.say("code:", code or "nil", ", calls:", calls,
                    ", eof_calls:", eof_calls, ", closed:", closed,
                    ", done:", ctx.var.llm_request_done)
        }
    }
--- response_body
code:nil, calls:1, eof_calls:0, closed:1, done:true
--- error_log
client disconnected during AI streaming



=== TEST 11: aborted moderation EOF neither calls service nor fabricates terminator
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugin")
            local moderation = require("apisix.plugins.ai-aliyun-content-moderation")
            local http = require("resty.http")
            local original_new = http.new
            local service_calls = 0
            http.new = function()
                service_calls = service_calls + 1
                return {
                    set_timeout = function() end,
                    connect = function()
                        return true
                    end,
                    request = function()
                        return {
                            status = 200,
                            headers = {},
                            read_body = function()
                                return '{"Data":{"RiskLevel":"none"}}'
                            end,
                        }
                    end,
                    close = function() end,
                }
            end
            local conf = {
                endpoint = "https://moderation.example.com",
                region_id = "cn-test",
                access_key_id = "test-id",
                access_key_secret = "test-secret",
                check_response = true,
                stream_check_mode = "final_packet",
                response_check_length_limit = 5000,
                response_check_service = "llm_response_moderation",
                risk_level_bar = "high",
                deny_code = 200,
                timeout = 1000,
                keepalive = false,
                ssl_verify = false,
            }
            local ctx = {
                var = {
                    request_type = "ai_stream",
                    llm_response_text = "safe response",
                },
                ai_client_protocol = "openai-chat",
            }
            local adapter = {
                name = "test-real-moderation-adapter",
                lua_body_filter = function(inner_conf, inner_ctx, headers,
                                           body, eof, abort_reason)
                    local _, new_body = moderation.lua_body_filter(
                        inner_conf, inner_ctx, headers, body, eof, abort_reason)
                    return nil, new_body or body
                end,
            }
            ctx.plugins = {adapter, conf}

            local ok, err, emitted = plugin.lua_response_filter(
                ctx, {}, "", true, false, true, "stream_limit")
            local aborted_headers_sent = ngx.headers_sent
            local normal_code, normal_body = moderation.lua_body_filter(
                conf, ctx, {}, "", true)
            http.new = original_new
            local normal_done = normal_body
                                and normal_body:find("[DONE]", 1, true) ~= nil
            ngx.say("ok:", ok, ", err:", err or "nil",
                    ", aborted_emitted:", emitted,
                    ", aborted_headers_sent:", aborted_headers_sent,
                    ", service_calls:", service_calls,
                    ", normal_code:", normal_code,
                    ", normal_done:", normal_done)
        }
    }
--- response_body
ok:true, err:nil, aborted_emitted:false, aborted_headers_sent:false, service_calls:1, normal_code:0, normal_done:true



=== TEST 12: response byte limit without output returns 502 after one EOF
--- config
    location /t {
        content_by_lua_block {
            local base = require("apisix.plugins.ai-providers.base")
            local eof_calls = 0
            local abort_reason
            local fake = {
                name = "test-size-limit-eof-filter",
                lua_body_filter = function(_, _, _, body, eof, reason)
                    if eof then
                        eof_calls = eof_calls + 1
                        abort_reason = reason
                    end
                    return nil, body
                end,
            }
            local ctx = {
                plugins = {fake, {}},
                var = {route_id = "test-route"},
                llm_request_start_time = ngx.now(),
            }
            local read_count = 0
            local res = {
                headers = {},
                body_reader = function()
                    read_count = read_count + 1
                    if read_count == 1 then
                        return "data: {}\n\n"
                    end
                end,
            }
            local target_proto = {
                parse_sse_event = function()
                    return {type = "data"}
                end,
            }
            local converter = {
                convert_sse_events = function()
                    return nil
                end,
            }

            local code = base.parse_streaming_response(
                base, ctx, res, target_proto, converter,
                {streaming_flush_interval_ms = 0, max_response_bytes = 1})
            local headers_sent = ngx.headers_sent
            local fallback_calls = 0
            if code and not headers_sent then
                fallback_calls = fallback_calls + 1
                ngx.status = code
            end
            ngx.say("code:", code, ", eof_calls:", eof_calls,
                    ", reason:", abort_reason,
                    ", headers_sent:", headers_sent,
                    ", fallback_calls:", fallback_calls)
        }
    }
--- response_body
code:502, eof_calls:1, reason:stream_limit, headers_sent:false, fallback_calls:1
--- error_code: 502
--- error_log
aborting AI stream: max_response_bytes exceeded



=== TEST 13: stream duration limit without output returns 504 after one EOF
--- config
    location /t {
        content_by_lua_block {
            local base = require("apisix.plugins.ai-providers.base")
            local eof_calls = 0
            local abort_reason
            local fake = {
                name = "test-duration-limit-eof-filter",
                lua_body_filter = function(_, _, _, body, eof, reason)
                    if eof then
                        eof_calls = eof_calls + 1
                        abort_reason = reason
                    end
                    return nil, body
                end,
            }
            local ctx = {
                plugins = {fake, {}},
                var = {route_id = "test-route"},
                llm_request_start_time = ngx.now() - 1,
            }
            local read_count = 0
            local res = {
                headers = {},
                body_reader = function()
                    read_count = read_count + 1
                    if read_count == 1 then
                        return "data: {}\n\n"
                    end
                end,
            }
            local target_proto = {
                parse_sse_event = function()
                    return {type = "data"}
                end,
            }
            local converter = {
                convert_sse_events = function()
                    return nil
                end,
            }

            local code = base.parse_streaming_response(
                base, ctx, res, target_proto, converter,
                {streaming_flush_interval_ms = 0, max_stream_duration_ms = 1})
            local headers_sent = ngx.headers_sent
            local fallback_calls = 0
            if code and not headers_sent then
                fallback_calls = fallback_calls + 1
                ngx.status = code
            end
            ngx.say("code:", code, ", eof_calls:", eof_calls,
                    ", reason:", abort_reason,
                    ", headers_sent:", headers_sent,
                    ", fallback_calls:", fallback_calls)
        }
    }
--- response_body
code:504, eof_calls:1, reason:stream_limit, headers_sent:false, fallback_calls:1
--- error_code: 504
--- error_log
aborting AI stream: max_stream_duration_ms exceeded
