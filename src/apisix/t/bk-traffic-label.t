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
            local plugin = require("apisix.plugins.bk-traffic-label")
            local ok, err = plugin.check_schema({
                rules = {
                    {
                        match = {{"arg_env", "==", "prod"}},
                        actions = {
                            {set_headers = {["X-Test-Header"] = "test"}}
                        }
                    }
                }
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

=== TEST 2: match hit set_headers
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "plugins": {
                        "bk-proxy-rewrite": {
                            "uri": "/uri/plugin_proxy_rewrite"
                        },
                        "bk-traffic-label": {
                            "rules": [
                                {
                                    "match": [
                                      ["arg_env", "==", "prod"]
                                    ],
                                    "actions": [
                                        {"set_headers": {"X-Test-Header": "test"}}
                                    ]
                                }
                            ]
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
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed

=== TEST 3: match hit set_headers
--- request
GET /hello?env=prod
--- response_body
uri: /uri/plugin_proxy_rewrite
host: localhost
x-real-ip: 127.0.0.1
x-test-header: test


=== TEST 4: match miss do nothing
--- request
GET /hello?env=dev
--- response_body
uri: /uri/plugin_proxy_rewrite
host: localhost
x-real-ip: 127.0.0.1

=== TEST 5: multiple-actions with weight
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "plugins": {
                        "bk-proxy-rewrite": {
                            "uri": "/uri/plugin_proxy_rewrite"
                        },
                        "bk-traffic-label": {
                            "rules": [
                                {
                                    "match": [
                                      ["arg_env", "==", "prod"]
                                    ],
                                    "actions": [
                                        {"set_headers": {"X-Test-Header": "test"}, "weight": 1},
                                        {"set_headers": {"X-Test-Header": "test"}, "weight": 1}
                                    ]
                                }
                            ]
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
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed

=== TEST 6: match hit set_headers
--- request
GET /hello?env=prod
--- response_body
uri: /uri/plugin_proxy_rewrite
host: localhost
x-real-ip: 127.0.0.1
x-test-header: test

=== TEST 7: only the action with non-zero weight is applied
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "plugins": {
                        "bk-proxy-rewrite": {
                            "uri": "/uri/plugin_proxy_rewrite"
                        },
                        "bk-traffic-label": {
                            "rules": [
                                {
                                    "match": [
                                      ["arg_env", "==", "prod"]
                                    ],
                                    "actions": [
                                        {"set_headers": {"X-Test-Header": "test1"}, "weight": 0},
                                        {"set_headers": {"X-Test-Header": "test2"}, "weight": 1}
                                    ]
                                }
                            ]
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
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed

=== TEST 6: match hit set_headers
--- request
GET /hello?env=prod
--- response_body
uri: /uri/plugin_proxy_rewrite
host: localhost
x-real-ip: 127.0.0.1
x-test-header: test2

=== TEST 7: only the action with non-zero weight is applied, but do nothing
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "plugins": {
                        "bk-proxy-rewrite": {
                            "uri": "/uri/plugin_proxy_rewrite"
                        },
                        "bk-traffic-label": {
                            "rules": [
                                {
                                    "match": [
                                      ["arg_env", "==", "prod"]
                                    ],
                                    "actions": [
                                        {"set_headers": {"X-Test-Header-1": "test1"}, "weight": 0},
                                        {"weight": 1}
                                    ]
                                }
                            ]
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
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed

=== TEST 8: match hit set_headers
--- request
GET /hello?env=prod
--- response_body
uri: /uri/plugin_proxy_rewrite
host: localhost
x-real-ip: 127.0.0.1

=== TEST 9: multiple matches, all hit
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "plugins": {
                        "bk-proxy-rewrite": {
                            "uri": "/uri/plugin_proxy_rewrite"
                        },
                        "bk-traffic-label": {
                            "rules": [
                                {
                                    "match": [
                                      ["arg_env", "==", "prod"]
                                    ],
                                    "actions": [
                                        {"set_headers": {"X-Test-Header-1": "test1"}}
                                    ]
                                },
                                {
                                    "match": [
                                      ["arg_type", "==", "foo"]
                                    ],
                                    "actions": [
                                        {"set_headers": {"X-Test-Header-2": "test2"}}
                                    ]
                                }
                            ]
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
            ngx.say(body)
        }
    }
--- request
GET /t
--- response_body
passed

=== TEST 10: multiple matches, only hit one
--- request
GET /hello?env=dev&type=foo
--- response_body
uri: /uri/plugin_proxy_rewrite
host: localhost
x-real-ip: 127.0.0.1
x-test-header-2: test2

=== TEST 10: multiple matches, hit both
--- request
GET /hello?env=prod&type=foo
--- response_body
uri: /uri/plugin_proxy_rewrite
host: localhost
x-real-ip: 127.0.0.1
x-test-header-1: test1
x-test-header-2: test2
