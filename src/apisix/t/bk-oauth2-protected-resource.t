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

=== TEST 1: sanity - check_schema
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-protected-resource")
            local ok, err = plugin.check_schema({})
            if not ok then
                ngx.say(err)
                return
            end

            ngx.say("done")
        }
    }
--- response_body
done

=== TEST 2: setup route with bk-oauth2-protected-resource plugin
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local code, body = t('/apisix/admin/routes/1',
                ngx.HTTP_PUT,
                [[{
                    "plugins": {
                        "bk-oauth2-protected-resource": {}
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
--- response_body
passed

=== TEST 3: request with X-Bkapi-Authorization header should set is_bk_oauth2=false
--- request
GET /hello
--- more_headers
X-Bkapi-Authorization: {"bk_app_code": "test"}
--- response_body
hello world
--- no_error_log
[error]

=== TEST 4: request with Authorization Bearer header should set is_bk_oauth2=true
--- request
GET /hello
--- more_headers
Authorization: Bearer test-token-12345
--- response_body
hello world
--- no_error_log
[error]

=== TEST 5: request without auth headers should return 401 with WWW-Authenticate
--- request
GET /hello
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer .*

=== TEST 6: X-Bkapi-Authorization takes precedence over Authorization Bearer
--- request
GET /hello
--- more_headers
X-Bkapi-Authorization: {"bk_app_code": "test"}
Authorization: Bearer test-token
--- response_body
hello world
--- no_error_log
[error]

=== TEST 7: non-Bearer Authorization should return 401
--- request
GET /hello
--- more_headers
Authorization: Basic dXNlcjpwYXNz
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer .*
