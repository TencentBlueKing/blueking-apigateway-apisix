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
            local plugin = require("apisix.plugins.bk-stage-context")
            local ok, err = plugin.check_schema({
                bk_gateway_name = "demo",
                bk_stage_name = "prod",
                jwt_private_key = "dGhpcyBpcyBhIGZha2Ugand0IHByaXZhdGUga2V5",
                bk_api_auth = {
                    api_type = 10
                }
            })
            if not ok then
                ngx.say(err)
            end

            ngx.say("done")
        }
    }
--- response_body
done



=== TEST 2: with allow_auth_from_params/allow_delete_sensitive_params
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-stage-context")
            local ok, err = plugin.check_schema({
                bk_gateway_name = "demo",
                bk_stage_name = "prod",
                jwt_private_key = "dGhpcyBpcyBhIGZha2Ugand0IHByaXZhdGUga2V5",
                bk_api_auth = {
                    api_type = 10,
                    allow_auth_from_params = false,
                    allow_delete_sensitive_params = false,
                }
            })
            if not ok then
                ngx.say(err)
            end

            ngx.say("done")
        }
    }
--- response_body
done



=== TEST 3: add route
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
                                    "api_type": 10,
                                    "unfiltered_sensitive_keys": ["a", "b"],
                                    "include_system_headers": ["c", "d"],
                                    "allow_auth_from_params": true,
                                    "allow_delete_sensitive_params": false,
                                    "uin_conf": {
                                        "user_type": "uin",
                                        "from_uin_skey": true,
                                        "skey_type": 1,
                                        "domain_id": 1,
                                        "search_rtx": true,
                                        "search_rtx_source": 1,
                                        "from_auth_token": false
                                    },
                                    "rtx_conf": {
                                        "user_type": "rtx",
                                        "from_operator": true,
                                        "from_bk_ticket": true,
                                        "from_auth_token": true
                                    },
                                    "user_conf": {
                                        "user_type": "user",
                                        "from_bk_token": true,
                                        "from_username": true
                                    }
                                }
                            },
                            "serverless-post-function": {
                                "phase": "rewrite",
                                "functions" : ["return function(conf, ctx) ngx.say(string.format(\"instance_id: %s, bk_gateway_name: %s, bk_gateway_id: %s, bk_stage_name: %s, jwt_private_key: %s\", ctx.var.instance_id, ctx.var.bk_gateway_name, ctx.var.bk_gateway_id, ctx.var.bk_stage_name, ctx.var.jwt_private_key)); ngx.exit(200); end"]
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



=== TEST 4: check ctx var part one
--- request
GET /hello HTTP/1.1
--- response_body
instance_id: 2c4562899afc453f85bb9c228ed6febd, bk_gateway_name: demo, bk_gateway_id: 1, bk_stage_name: prod, jwt_private_key: this is a fake jwt private key



=== TEST 5: add route check
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
                                    "api_type": 10,
                                    "unfiltered_sensitive_keys": ["a", "b"],
                                    "include_system_headers": ["c", "d"],
                                    "allow_auth_from_params": true,
                                    "allow_delete_sensitive_params": false,
                                    "uin_conf": {
                                        "user_type": "uin",
                                        "from_uin_skey": true,
                                        "skey_type": 1,
                                        "domain_id": 1,
                                        "search_rtx": true,
                                        "search_rtx_source": 1,
                                        "from_auth_token": false
                                    },
                                    "rtx_conf": {
                                        "user_type": "rtx",
                                        "from_operator": true,
                                        "from_bk_ticket": true,
                                        "from_auth_token": true
                                    },
                                    "user_conf": {
                                        "user_type": "user",
                                        "from_bk_token": true,
                                        "from_username": true
                                    }
                                }
                            },
                            "serverless-post-function": {
                                "phase": "rewrite",
                                "functions" : ["return function(conf, ctx) ngx.say(string.format(\"bk_api_auth: %s, bk_resource_name: %s, bk_service_name: %s\", require(\"toolkit.json\").encode(ctx.var.bk_api_auth), ctx.var.bk_resource_name, ctx.var.bk_service_name)); ngx.exit(200); end"]
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



=== TEST 6: check ctx var part two
--- request
GET /hello HTTP/1.1
--- response_body
bk_api_auth: {"allow_auth_from_params":true,"allow_delete_sensitive_params":false,"api_type":10,"include_system_headers_mapping":{"c":true,"d":true},"rtx_conf":{"from_auth_token":true,"from_bk_ticket":true,"from_operator":true,"user_type":"rtx"},"uin_conf":{"domain_id":1,"from_auth_token":false,"from_uin_skey":true,"search_rtx":true,"search_rtx_source":1,"skey_type":1,"user_type":"uin"},"unfiltered_sensitive_keys":["a","b"],"user_conf":{"from_bk_token":true,"from_username":true,"user_type":"user"}}, bk_resource_name: nil, bk_service_name: nil
