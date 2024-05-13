#
# TencentBlueKing is pleased to support the open source community by making
# 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
# Copyright (C) 2017 THL A29 Limited, a Tencent company. All rights reserved.
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

add_block_preprocessor(sub {
    my ($block) = @_;

    if (!$block->extra_yaml_config) {
        my $extra_yaml_config = <<_EOC_;
plugins:
    - opentelemetry
    - bk-opentelemetry
    - bk-stage-context
plugin_attr:
    bk-opentelemetry:
        enabled: true
    opentelemetry:
        batch_span_processor:
            max_export_batch_size: 1
            inactive_timeout: 0.5
_EOC_
        $block->set_value("extra_yaml_config", $extra_yaml_config);
    }


    if (!$block->extra_init_by_lua) {
        my $extra_init_by_lua = <<_EOC_;
-- mock exporter http client
local client = require("opentelemetry.trace.exporter.http_client")
client.do_request = function()
    ngx.log(ngx.INFO, "opentelemetry export span")
    return "ok"
end
_EOC_

        $block->set_value("extra_init_by_lua", $extra_init_by_lua);
    }

    if (!$block->request) {
        $block->set_value("request", "GET /t");
    }

    if (!defined $block->response_body) {
        $block->set_value("response_body", "passed\n");
    }

    $block;
});

repeat_each(1);
no_long_string();
no_root_location();
log_level("debug");

run_tests;

__DATA__

=== TEST 1: set plugin meta data
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/plugin_metadata/bk-opentelemetry',
                ngx.HTTP_PUT,
                [[{
                    "sampler": {
                        "name": "always_on"
                    }
                }]]
            )
            if code >= 300 then
                ngx.status = code
            end
            -- code is 201, body is passed
            ngx.say(body)
        }
    }



=== TEST 2: add plugin route
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "bk-stage-context": {
                            "bk_gateway_name": "demo",
                            "bk_gateway_id": 1,
                            "bk_stage_name": "prod",
                            "jwt_private_key": "dGhpcyBpcyBhIGZha2Ugand0IHByaXZhdGUga2V5",
                            "bk_api_auth": {
                                "api_type": 10
                            }
                        },
                        "bk-opentelemetry": {}
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    },
                    "uri": "/opentracing"
                }]]
            )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }



=== TEST 3: trigger opentelemetry
--- request
GET /opentracing
--- response_body
opentracing
--- wait: 1
--- grep_error_log eval
qr/opentelemetry export span/
--- grep_error_log_out
opentelemetry export span



=== TEST 4: check inject span
--- extra_init_by_lua
    local core = require("apisix.core")
    local otlp = require("opentelemetry.trace.exporter.otlp")
    local span_kind = require("opentelemetry.trace.span_kind")
    otlp.export_spans = function(self, spans)
        if (#spans ~= 1) then
            ngx.log(ngx.ERR, "unexpected spans length: ", #spans)
            return
        end

        local span = spans[1]

        local current_span_kind = span:plain().kind
        if current_span_kind ~= span_kind.server then
            ngx.log(ngx.ERR, "expected span.kind to be server but got ", current_span_kind)
            return
        end

        if span.name ~= "/opentracing" then
            ngx.log(ngx.ERR, "expect span name: /opentracing, but got ", span.name)
            return
        end

        -- bk-opentelemetry inject 8 attributes + service and route
        if #span.attributes ~= 10 then
            ngx.log(ngx.ERR, "expect len(span.attributes) = 10, but got ", #span.attributes)
            return
        end

        ngx.log(ngx.INFO, "opentelemetry export span")
    end
--- request
GET /opentracing?foo=bar&a=b
--- response_body
opentracing
--- wait: 1
--- grep_error_log eval
qr/opentelemetry export span/
--- grep_error_log_out
opentelemetry export span
