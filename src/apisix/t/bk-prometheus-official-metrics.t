#
# TencentBlueKing is pleased to support the open source community by making
# 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
# Copyright (C) Tencent. All rights reserved.
# Licensed under the MIT License (the "License"); you may not use this file except
# in compliance with the License. You may obtain a copy of the License at
#
# http://opensource.org/licenses/MIT
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
no_shuffle();
no_root_location();

add_block_preprocessor(sub {
    my ($block) = @_;

    if (!defined $block->request) {
        $block->set_value("request", "GET /t");
    }

    $block->set_value("extra_yaml_config", <<'EOF');
plugin_attr:
    prometheus:
        official:
            enable_status: false
            enable_latency: false
            enable_bandwidth: false
            enable_llm: false
EOF
});

run_tests;

__DATA__

=== TEST 1: status metrics obey the official metric gate
--- config
    location /t {
        content_by_lua_block {
            local exporter = require("apisix.plugins.prometheus.exporter")
            local plugin = require("apisix.plugin")
            local attr = plugin.plugin_attr("prometheus")
            attr.official.enable_status = false
            attr.official.enable_latency = false
            attr.official.enable_bandwidth = false
            attr.official.enable_llm = false

            local custom = exporter.get_prometheus():counter(
                "bk_gate_status_total", "BlueKing custom status gate metric", {})
            custom:inc(1)

            local function record(route_id)
                exporter.http_log({}, {
                    matched_route = {value = {id = route_id}},
                    curr_req_matched = {_path = "/t", _host = ""},
                    var = {
                        status = "200",
                        request_length = 10,
                        bytes_sent = 20,
                        upstream_response_time = 0.001,
                        request_type = "",
                        request_llm_model = "",
                        llm_model = "",
                    },
                })
            end

            record("status-disabled")
            attr.official.enable_status = true
            record("status-enabled")

            local data = table.concat(exporter.metric_data())
            ngx.say("custom=", data:find("apisix_bk_gate_status_total", 1, true) ~= nil)
            ngx.say("disabled=", data:find('route="status-disabled"', 1, true) ~= nil)
            ngx.say("enabled=", data:find('route="status-enabled"', 1, true) ~= nil)
        }
    }
--- response_body
custom=true
disabled=false
enabled=true



=== TEST 2: latency metrics obey the official metric gate
--- config
    location /t {
        content_by_lua_block {
            local exporter = require("apisix.plugins.prometheus.exporter")
            local plugin = require("apisix.plugin")
            local attr = plugin.plugin_attr("prometheus")
            attr.official.enable_status = false
            attr.official.enable_latency = false
            attr.official.enable_bandwidth = false
            attr.official.enable_llm = false

            local custom = exporter.get_prometheus():counter(
                "bk_gate_latency_total", "BlueKing custom latency gate metric", {})
            custom:inc(1)

            local function record(route_id)
                exporter.http_log({}, {
                    matched_route = {value = {id = route_id}},
                    curr_req_matched = {_path = "/t", _host = ""},
                    var = {
                        status = "200",
                        request_length = 10,
                        bytes_sent = 20,
                        upstream_response_time = 0.001,
                        request_type = "",
                        request_llm_model = "",
                        llm_model = "",
                    },
                })
            end

            record("latency-disabled")
            attr.official.enable_latency = true
            record("latency-enabled")

            local data = table.concat(exporter.metric_data())
            ngx.say("custom=", data:find("apisix_bk_gate_latency_total", 1, true) ~= nil)
            ngx.say("disabled=", data:find('route="latency-disabled"', 1, true) ~= nil)
            ngx.say("enabled=", data:find('route="latency-enabled"', 1, true) ~= nil)
        }
    }
--- response_body
custom=true
disabled=false
enabled=true



=== TEST 3: bandwidth metrics obey the official metric gate
--- config
    location /t {
        content_by_lua_block {
            local exporter = require("apisix.plugins.prometheus.exporter")
            local plugin = require("apisix.plugin")
            local attr = plugin.plugin_attr("prometheus")
            attr.official.enable_status = false
            attr.official.enable_latency = false
            attr.official.enable_bandwidth = false
            attr.official.enable_llm = false

            local custom = exporter.get_prometheus():counter(
                "bk_gate_bandwidth_total", "BlueKing custom bandwidth gate metric", {})
            custom:inc(1)

            local function record(route_id)
                exporter.http_log({}, {
                    matched_route = {value = {id = route_id}},
                    curr_req_matched = {_path = "/t", _host = ""},
                    var = {
                        status = "200",
                        request_length = 10,
                        bytes_sent = 20,
                        upstream_response_time = 0.001,
                        request_type = "",
                        request_llm_model = "",
                        llm_model = "",
                    },
                })
            end

            record("bandwidth-disabled")
            attr.official.enable_bandwidth = true
            record("bandwidth-enabled")

            local data = table.concat(exporter.metric_data())
            ngx.say("custom=", data:find("apisix_bk_gate_bandwidth_total", 1, true) ~= nil)
            ngx.say("disabled=", data:find('route="bandwidth-disabled"', 1, true) ~= nil)
            ngx.say("enabled=", data:find('route="bandwidth-enabled"', 1, true) ~= nil)
        }
    }
--- response_body
custom=true
disabled=false
enabled=true



=== TEST 4: LLM metrics obey the official metric gate and preserve latency types
--- config
    location /t {
        content_by_lua_block {
            local exporter = require("apisix.plugins.prometheus.exporter")
            local plugin = require("apisix.plugin")
            local attr = plugin.plugin_attr("prometheus")
            attr.official.enable_status = false
            attr.official.enable_latency = false
            attr.official.enable_bandwidth = false
            attr.official.enable_llm = false

            local custom = exporter.get_prometheus():counter(
                "bk_gate_llm_total", "BlueKing custom LLM gate metric", {})
            custom:inc(1)

            local function record(route_id, request_type)
                exporter.http_log({}, {
                    matched_route = {value = {id = route_id}},
                    curr_req_matched = {_path = "/t", _host = ""},
                    var = {
                        status = "200",
                        request_length = 10,
                        bytes_sent = 20,
                        upstream_response_time = 0.001,
                        apisix_upstream_response_time = "2",
                        request_type = request_type,
                        request_llm_model = "gpt-3",
                        llm_model = "gpt-4",
                        llm_time_to_first_token = "1",
                        llm_prompt_tokens = "8",
                        llm_completion_tokens = "5",
                    },
                })
            end

            record("llm-disabled", "ai_stream")
            attr.official.enable_llm = true
            record("llm-chat-enabled", "ai_chat")
            record("llm-stream-enabled", "ai_stream")

            local data = table.concat(exporter.metric_data())
            ngx.say("custom=", data:find("apisix_bk_gate_llm_total", 1, true) ~= nil)
            ngx.say("disabled=", data:find('route_id="llm-disabled"', 1, true) ~= nil)
            ngx.say("chat_total=", data:find(
                'apisix_llm_latency_count{type="total",route_id="llm-chat-enabled",' ..
                'service_id="",consumer="",node="",request_type="ai_chat"', 1, true) ~= nil)
            ngx.say("stream_total=", data:find(
                'apisix_llm_latency_count{type="total",route_id="llm-stream-enabled",' ..
                'service_id="",consumer="",node="",request_type="ai_stream"', 1, true) ~= nil)
            ngx.say("stream_ttft=", data:find(
                'apisix_llm_latency_count{type="ttft",route_id="llm-stream-enabled",' ..
                'service_id="",consumer="",node="",request_type="ai_stream"', 1, true) ~= nil)
        }
    }
--- response_body
custom=true
disabled=false
chat_total=true
stream_total=true
stream_ttft=true
