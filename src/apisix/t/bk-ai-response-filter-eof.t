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
                api_ctx, {}, "payload", true, false, true)
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
            local ok, err = plugin.lua_response_filter(
                api_ctx, {}, "payload", true, false, true)
            if not ok then
                ngx.say(err)
            end
        }
    }
--- response_body: payload:eof=true



=== TEST 3: converter no-output error still finalizes response filters
--- config
    location /t {
        content_by_lua_block {
            local base = require("apisix.plugins.ai-providers.base")
            local eof_calls = 0
            local fake = {
                name = "test-converter-eof-filter",
                lua_body_filter = function(_, _, _, body, eof)
                    if eof then
                        eof_calls = eof_calls + 1
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
            ngx.say("code:", code, ", eof_calls:", eof_calls)
        }
    }
--- response_body
code:502, eof_calls:1
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
                    return nil, ""
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

            base.parse_streaming_response(
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
                    ", unresolved:", ctx._ai_redaction_unresolved_count)
        }
    }
--- response_body
occurrences:1, cleared:true, unresolved:1
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
                    return nil, ""
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

            base.parse_streaming_response(
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
                    ", unresolved:", ctx._ai_redaction_unresolved_count)
        }
    }
--- response_body
occurrences:1, cleared:true, unresolved:1
--- error_log
aborting AI stream: max_stream_duration_ms exceeded



=== TEST 7: response byte limit without output returns 502 after one EOF
--- config
    location /t {
        content_by_lua_block {
            local base = require("apisix.plugins.ai-providers.base")
            local eof_calls = 0
            local fake = {
                name = "test-size-limit-eof-filter",
                lua_body_filter = function(_, _, _, body, eof)
                    if eof then
                        eof_calls = eof_calls + 1
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
            ngx.say("code:", code, ", eof_calls:", eof_calls)
        }
    }
--- response_body
code:502, eof_calls:1
--- error_log
aborting AI stream: max_response_bytes exceeded



=== TEST 8: stream duration limit without output returns 504 after one EOF
--- config
    location /t {
        content_by_lua_block {
            local base = require("apisix.plugins.ai-providers.base")
            local eof_calls = 0
            local fake = {
                name = "test-duration-limit-eof-filter",
                lua_body_filter = function(_, _, _, body, eof)
                    if eof then
                        eof_calls = eof_calls + 1
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
            ngx.say("code:", code, ", eof_calls:", eof_calls)
        }
    }
--- response_body
code:504, eof_calls:1
--- error_log
aborting AI stream: max_stream_duration_ms exceeded
