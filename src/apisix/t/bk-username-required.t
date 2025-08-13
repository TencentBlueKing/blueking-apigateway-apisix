#
# TencentBlueKing is pleased to support the open source community by making
# 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
# Copyright (C) 2025 Tencent. All rights reserved.
# Licensed under the MIT License (the "License") you may not use this file except
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

# NOTE: while the priority of serverless-pre-function is 10000, and the priority of bk-username-required is 18725. so we should set the priority of serverless-pre-function to 20000 to make sure the bk-username-required plugin can be executed after the serverless-pre-function plugin.


__DATA__



=== TEST 1: sanity check schema
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-username-required")
            local ok, err = plugin.check_schema({})
            if not ok then
                ngx.say(err)
            end

            ngx.say("done")
        }
    }
--- response_body
done

=== TEST 2: add route with bk-username-required plugin
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "bk-username-required": {},
                        "bk-error-wrapper": {}
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    },
                    "uri": "/echo"
                }]]
                )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed

=== TEST 3: case 1 - X-Bk-Username not empty, should pass
--- request
GET /echo
--- more_headers
X-Bk-Username: test-user
--- response_headers
X-Bk-Username: test-user

=== TEST 4: case 2 - X-Bk-Username empty, should return 400/INVALID_ARGS
--- request
GET /echo
--- more_headers
X-Bk-Username:
--- error_code: 400
--- response_body_like: "INVALID_ARGS"

=== TEST 5: case 3 - no X-Bk-Username but ctx.var.bk_username is not empty, should pass
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "bk-username-required": {},
                        "bk-error-wrapper": {},
                        "serverless-pre-function": {
                            "_meta": {
                                "priority": 20000
                            },
                            "phase": "rewrite",
                            "functions" : ["return function(conf, ctx) ctx.var.bk_username = 'context-user'; end"]
                        }
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    },
                    "uri": "/echo"
                }]]
                )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed

=== TEST 6: test case 3 - no X-Bk-Username but ctx.var.bk_username is set
--- request
GET /echo
--- response_headers
X-Bk-Username: context-user

=== TEST 7: case 4 - no X-Bk-Username and ctx.var.bk_username is empty, should return 400/INVALID_ARGS
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "bk-username-required": {},
                        "bk-error-wrapper": {},
                        "serverless-pre-function": {
                            "_meta": {
                                "priority": 20000
                            },
                            "phase": "rewrite",
                            "functions" : ["return function(conf, ctx) ctx.var.bk_username = ''; end"]
                        }
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    },
                    "uri": "/echo"
                }]]
                )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed

=== TEST 8: test case 4 - no X-Bk-Username and ctx.var.bk_username is empty
--- request
GET /echo
--- error_code: 400
--- response_body_like: "INVALID_ARGS"

=== TEST 9: test case 4 - no X-Bk-Username and ctx.var.bk_username is nil
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "bk-username-required": {},
                        "bk-error-wrapper": {},
                        "serverless-pre-function": {
                            "_meta": {
                                "priority": 20000
                            },
                            "phase": "rewrite",
                            "functions" : ["return function(conf, ctx) ctx.var.bk_username = nil; end"]
                        }
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    },
                    "uri": "/echo"
                }]]
                )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed

=== TEST 10: test case 4 - no X-Bk-Username and ctx.var.bk_username is nil
--- request
GET /echo
--- error_code: 400
--- response_body_like: "INVALID_ARGS"

=== TEST 11: test priority - X-Bk-Username header should take precedence over ctx.var.bk_username
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "bk-username-required": {},
                        "bk-error-wrapper": {},
                        "serverless-pre-function": {
                            "_meta": {
                                "priority": 20000
                            },
                            "phase": "rewrite",
                            "functions" : ["return function(conf, ctx) ctx.var.bk_username = 'context-user'; end"]
                        }
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1980": 1
                        },
                        "type": "roundrobin"
                    },
                    "uri": "/echo"
                }]]
                )

            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed

=== TEST 12: test priority - header takes precedence
--- request
GET /echo
--- more_headers
X-Bk-Username: header-user
--- response_headers
X-Bk-Username: header-user

