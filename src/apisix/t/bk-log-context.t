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
            local plugin = require("apisix.plugins.bk-log-context")
            local ok, err = plugin.check_schema({
                log_2xx_response_body = false
            })
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
                            "bk-log-context": {
                                "log_2xx_response_body": true
                            },
                            "serverless-post-function": {
                                "phase": "header_filter",
                                "functions" : ["return function(conf, ctx) ngx.log(ngx.ERR, string.format(\"should_log_response_body: %s\", ctx.var.should_log_response_body)); end"]
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



=== TEST 3: check ctx var should_log_response_body
--- request
GET /hello HTTP/1.1
--- error_log
should_log_response_body: true



=== TEST 4: add route
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                        "plugins": {
                            "bk-log-context": {
                                "log_2xx_response_body": true
                            },
                            "serverless-post-function": {
                                "phase": "body_filter",
                                "functions" : ["return function(conf, ctx) ngx.log(ngx.ERR, string.format(\"backend_part_response_body: %s\", ctx.var._backend_part_response_body)); end"]
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



=== TEST 5: check ctx var backend_part_response_body
--- request
GET /hello HTTP/1.1
--- response_body
hello world
--- error_log
backend_part_response_body: hello world



=== TEST 6: add route
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                        "plugins": {
                            "bk-log-context": {
                                "log_2xx_response_body": false
                            },
                            "serverless-post-function": {
                                "phase": "body_filter",
                                "functions" : ["return function(conf, ctx) ngx.log(ngx.ERR, string.format(\"backend_part_response_body: %s\", ctx.var._backend_part_response_body)); end"]
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



=== TEST 7: check ctx var backend_part_response_body empty
--- request
GET /hello HTTP/1.1
--- response_body
hello world
--- error_log
backend_part_response_body:
