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

=== TEST 1: sanity - schema validation
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-query-string-rewrite")
            local ok, err = plugin.check_schema({
                set = {version = "v2"},
                remove = {"debug"}
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

=== TEST 2: set route with set operation
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "bk-query-string-rewrite": {
                            "set": {
                                "version": "v2"
                            }
                        },
                        "mocking": {
                            "content_type": "text/plain",
                            "response_status": 200,
                            "response_example": "args:$args\n"
                        }
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1982": 1
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

=== TEST 3: set - adds new query param
--- request
GET /hello
--- response_body
args:version=v2

=== TEST 4: set - replaces existing query param
--- request
GET /hello?version=v1
--- response_body
args:version=v2

=== TEST 5: set - preserves other query params
--- request
GET /hello?existing=keep
--- response_body_like
args:(?=.*version=v2)(?=.*existing=keep).*

=== TEST 6: set route with add operation
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "bk-query-string-rewrite": {
                            "add": {
                                "version": "v2"
                            }
                        },
                        "mocking": {
                            "content_type": "text/plain",
                            "response_status": 200,
                            "response_example": "args:$args\n"
                        }
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1982": 1
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

=== TEST 7: add - adds param when not present
--- request
GET /hello
--- response_body
args:version=v2

=== TEST 8: add - skips param when already present
--- request
GET /hello?version=v1
--- response_body
args:version=v1

=== TEST 9: set route with remove operation
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "bk-query-string-rewrite": {
                            "remove": ["debug", "trace"]
                        },
                        "mocking": {
                            "content_type": "text/plain",
                            "response_status": 200,
                            "response_example": "args:$args\n"
                        }
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1982": 1
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

=== TEST 10: remove - removes existing param
--- request
GET /hello?debug=1&keep=value
--- response_body
args:keep=value

=== TEST 11: remove - removes multiple params
--- request
GET /hello?debug=1&trace=on&keep=value
--- response_body
args:keep=value

=== TEST 12: remove - no-op when param not present
--- request
GET /hello?keep=value
--- response_body
args:keep=value

=== TEST 13: set route with combined operations
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "bk-query-string-rewrite": {
                            "add": {
                                "added": "new"
                            },
                            "set": {
                                "forced": "value"
                            },
                            "remove": ["unwanted"]
                        },
                        "mocking": {
                            "content_type": "text/plain",
                            "response_status": 200,
                            "response_example": "args:$args\n"
                        }
                    },
                    "upstream": {
                        "nodes": {
                            "127.0.0.1:1982": 1
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

=== TEST 14: combined - add, set, and remove
--- request
GET /hello?unwanted=bye&existing=keep
--- response_body_like
args:(?=.*added=new)(?=.*forced=value)(?=.*existing=keep)(?!.*unwanted=).*

=== TEST 15: combined - add skips existing, set replaces
--- request
GET /hello?added=original&forced=old&unwanted=bye
--- response_body_like
args:(?=.*added=original)(?=.*forced=value)(?!.*unwanted=).*

=== TEST 16: disable plugin
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
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
