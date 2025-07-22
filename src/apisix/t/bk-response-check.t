#
# TencentBlueKing is pleased to support the open source community by making
# 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
# Copyright (C) 2025 Tencent. All rights reserved.
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

BEGIN {
    if ($ENV{TEST_NGINX_CHECK_LEAK}) {
        $SkipReason = "unavailable for the hup tests";

    } else {
        $ENV{TEST_NGINX_USE_HUP} = 1;
        undef $ENV{TEST_NGINX_USE_STAP};
    }
}

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
});

run_tests;

__DATA__

=== TEST 1: sanity
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-response-check")
            local ok, err = plugin.check_schema({})
            if not ok then
                ngx.say(err)
            end

            ngx.say("done")
        }
    }
--- response_body
done



=== TEST 2: add route
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
                            "prometheus": {},
                            "bk-response-check": {},
                            "bk-log-context": {
                                "log_2xx_response_body": false
                            },
                            "serverless-post-function": {
                                "phase": "rewrite",
                                "functions" : ["return function(conf, ctx) ctx.var.bk_app_code = \"demo\" end"]
                            }
                        },
                        "upstream": {
                            "nodes": {
                                "127.0.0.1:1980": 1
                            },
                            "type": "roundrobin"
                        },
                        "uri": "/hello"
                }]]
                )
            if code >= 300 then
                ngx.status = code
            end
            -- code is 201, body is passed
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 3: add route metrics
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/metrics',
                 ngx.HTTP_PUT,
                 [[{
                        "plugins": {
                            "public-api": {}
                        },
                        "uri": "/apisix/prometheus/metrics"
                }]]
                )
            if code >= 300 then
                ngx.status = code
            end
            -- code is 201, body is passed
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed



=== TEST 4: request from client (all hit)
--- pipelined_requests eval
["GET /hello", "GET /hello", "GET /hello", "GET /hello"]
--- error_code eval
[200, 200, 200, 200]



=== TEST 5: fetch the prometheus metric data apisix_apigateway_api_requests_total
--- request
GET /apisix/prometheus/metrics
--- response_body eval
qr/apisix_apigateway_api_requests_total\{api_name="demo",stage_name="prod",resource_name="",status="200",proxy_phase="",proxy_error="0"\} 4/



=== TEST 6: fetch the prometheus metric data apisix_apigateway_api_request_duration_milliseconds_bucket
--- request
GET /apisix/prometheus/metrics
--- response_body eval
qr/apisix_apigateway_api_request_duration_milliseconds_bucket\{api_name="demo",stage_name="prod",resource_name="",le="5000"\} \d+/



=== TEST 7: fetch the prometheus metric data apisix_apigateway_app_requests_total
--- request
GET /apisix/prometheus/metrics
--- response_body eval
qr/apisix_apigateway_app_requests_total\{app_code="demo",api_name="demo",stage_name="prod",resource_name=""\} 4/
