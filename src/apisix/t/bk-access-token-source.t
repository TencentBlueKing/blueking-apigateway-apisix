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
# We undertake not to change the open source license (MIT License) applicable
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

=== TEST 1: sanity check schema
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-access-token-source")
            local ok, err = plugin.check_schema({})
            if not ok then
                ngx.say(err)
            end

            ngx.say("done")
        }
    }
--- response_body
done

=== TEST 2: check schema with valid source
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-access-token-source")
            local ok, err = plugin.check_schema({source = "bearer"})
            if not ok then
                ngx.say(err)
            end

            local ok2, err2 = plugin.check_schema({source = "api_key"})
            if not ok2 then
                ngx.say(err2)
            end

            ngx.say("done")
        }
    }
--- response_body
done

=== TEST 3: check schema with invalid source
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-access-token-source")
            local ok, err = plugin.check_schema({source = "invalid"})
            if not ok then
                ngx.say("invalid source error: ", err)
            end

            ngx.say("done")
        }
    }
--- response_body
invalid source error: property "source" validation failed: matches none of the enum values
done

=== TEST 4: add plugin with bearer source
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "bk-access-token-source": {
                            "source": "bearer"
                        },
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

=== TEST 5: test bearer token processing - valid bearer token
--- request
GET /echo
--- more_headers
Authorization: Bearer test-token-123
--- response_headers
X-Bkapi-Authorization: {"access_token":"test-token-123"}

=== TEST 6: test bearer token processing - case insensitive bearer
--- request
GET /echo
--- more_headers
Authorization: bearer test-token-456
--- response_headers
X-Bkapi-Authorization: {"access_token":"test-token-456"}

=== TEST 7: test bearer token processing - missing authorization header
--- request
GET /echo
--- error_code: 400
--- response_body_like: "INVALID_ARGS"


=== TEST 8: test bearer token processing - invalid authorization format
--- request
GET /echo
--- more_headers
Authorization: Basic dGVzdDp0ZXN0
--- error_code: 400
--- response_body_like: "INVALID_ARGS"

=== TEST 9: update plugin to use api_key source
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "bk-access-token-source": {
                            "source": "api_key"
                        },
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

=== TEST 10: test api_key processing - valid api key
--- request
GET /echo
--- more_headers
X-API-KEY: api-key-123
--- response_headers
X-Bkapi-Authorization: {"access_token":"api-key-123"}

=== TEST 11: test api_key processing - missing api key header
--- request
GET /echo
--- error_code: 400
--- response_body_like: "INVALID_ARGS"

=== TEST 12: test header overwrite behavior
--- request
GET /echo
--- more_headers
X-API-KEY: new-api-key-456
X-Bkapi-Authorization: {"access_token":"old-token"}
--- response_headers
X-Bkapi-Authorization: {"access_token":"new-api-key-456"}

=== TEST 13: test default source (bearer) when no source specified
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                 ngx.HTTP_PUT,
                 [[{
                    "plugins": {
                        "bk-access-token-source": {},
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

=== TEST 14: test default bearer source with valid token
--- request
GET /echo
--- more_headers
Authorization: Bearer default-token-789
--- response_headers
X-Bkapi-Authorization: {"access_token":"default-token-789"}

=== TEST 15: test bearer token with empty token
--- request
GET /echo
--- more_headers
Authorization: Bearer
--- error_code: 400
--- response_body_like: "INVALID_ARGS"

=== TEST 16: update plugin to use api_key source for empty key test
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "bk-access-token-source": {
                            "source": "api_key"
                        },
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

=== TEST 17: test api_key with empty value
--- request
GET /echo
--- more_headers
X-API-KEY:
--- error_code: 400
--- response_body_like: "INVALID_ARGS"
