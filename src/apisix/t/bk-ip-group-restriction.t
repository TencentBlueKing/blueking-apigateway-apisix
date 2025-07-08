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

run_tests;

__DATA__
=== TEST 1: sanity
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-ip-group-restriction")
            local ok, err = plugin.check_schema({
                allow = {{
                    id = 1,
                    name = "1",
                    content = "1.1.1.1\n# test\n1.1.1.2",
                    comment = "test allow"
                }},
                deny = {{
                    id = 2,
                    name = "2",
                    content = "192.168.1.1\n# test\n192.168.1.2",
                    comment = "test deny"
                }}
            })
            if not ok then
                ngx.say(err)
            end
            ngx.say("done")
        }
    }
--- request
GET /t
--- response_body
done



=== TEST 2: add plugin allow ip group
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                        "plugins": {
                            "bk-ip-group-restriction": {
                                "allow": [{
                                    "id": 1,
                                    "name": "1",
                                    "content": "127.0.0.0/24\n# test\n1.1.1.1",
                                    "comment": "test allow"
                                }]
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



=== TEST 3: hit route and ip cidr in the whitelist
--- request
GET /hello
--- response_body
hello world



=== TEST 4: add plugin deny ip group
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                        "plugins": {
                            "bk-ip-group-restriction": {
                                "deny": [{
                                    "id": 1,
                                    "name": "1",
                                    "content": "127.0.0.0/24\n# test\n1.1.1.1",
                                    "comment": "test allow"
                                }]
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



=== TEST 5: hit route and ip cidr in the denylist
--- request
GET /hello
--- error_code: 403



=== TEST 6: add plugin error ip
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                        "plugins": {
                            "bk-ip-group-restriction": {
                                "allow": [{
                                    "id": 1,
                                    "name": "1",
                                    "content": "test error",
                                    "comment": "test allow"
                                }]
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



=== TEST 7: ignore error ip match
--- request
GET /hello
--- error_code: 403
