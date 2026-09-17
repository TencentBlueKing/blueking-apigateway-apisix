#
# TencentBlueKing is pleased to support the open source community by making
# 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
# Copyright (C) Tencent. All rights reserved.
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

=== TEST 1: configure CORS with OAuth2 authentication
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local core = require("apisix.core")
            local mock_token_verification = [[return function()
                local cache = require("apisix.plugins.bk-cache.oauth2-access-token")
                cache.get_oauth2_access_token = function(token)
                    if token == "valid-token" then
                        return {active = true, exp = ngx.time() + 60,
                            bk_app_code = "personal", bk_username = "test-user", audience = {}}
                    end
                    return {active = false, error = {code = "invalid_token", message = "invalid token"}}
                end
            end]]
            local code, body = t('/apisix/admin/routes/cors-auth', ngx.HTTP_PUT,
                core.json.encode({
                    uri = "/hello",
                    plugins = {
                        ["bk-request-id"] = {},
                        ["bk-stage-context"] = {
                            bk_gateway_name = "test", bk_stage_name = "prod",
                            jwt_private_key = "dGVzdA==", bk_api_auth = {},
                        },
                        ["bk-resource-context"] = {
                            bk_resource_auth = {verified_app_required = true, verified_user_required = true},
                        },
                        ["bk-log-context"] = {},
                        ["bk-cors"] = {
                            allow_origins = "https://allowed.example.com,https://other.example.com",
                            allow_methods = "GET,OPTIONS",
                            allow_headers = "Authorization",
                            expose_headers = "WWW-Authenticate,X-Bkapi-Request-Id",
                            allow_credential = true,
                        },
                        -- Mock only the identity service; run the real OAuth2 verification plugin.
                        ["serverless-pre-function"] = {
                            _meta = {priority = 18745}, phase = "rewrite",
                            functions = {mock_token_verification},
                        },
                        ["bk-oauth2-protected-resource"] = {},
                        ["bk-oauth2-verify"] = {},
                        ["bk-auth-validate"] = {},
                        ["bk-error-wrapper"] = {},
                    },
                    upstream = {nodes = {["127.0.0.1:1980"] = 1}, type = "roundrobin"},
                }))
            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed

=== TEST 2: preflight succeeds without authentication
--- request
OPTIONS /hello
--- more_headers
Origin: https://allowed.example.com
Access-Control-Request-Method: GET
Access-Control-Request-Headers: authorization
--- response_headers
Access-Control-Allow-Origin: https://allowed.example.com
Access-Control-Allow-Credentials: true
Access-Control-Allow-Methods: GET,OPTIONS
Access-Control-Allow-Headers: Authorization
--- response_headers_like
X-Bkapi-Request-Id: .+
--- no_error_log
[error]

=== TEST 3: missing credentials remain unauthorized with readable CORS response
--- request
GET /hello
--- more_headers
Origin: https://allowed.example.com
--- error_code: 401
--- response_headers
Access-Control-Allow-Origin: https://allowed.example.com
Access-Control-Allow-Credentials: true
--- response_headers_like
WWW-Authenticate: Bearer .*
--- no_error_log
[error]

=== TEST 4: invalid Bearer remains unauthorized with readable CORS response
--- request
GET /hello
--- more_headers
Origin: https://allowed.example.com
Authorization: Bearer invalid-token
--- error_code: 401
--- response_headers
Access-Control-Allow-Origin: https://allowed.example.com
Access-Control-Allow-Credentials: true
--- response_headers_like
WWW-Authenticate: Bearer .*
--- no_error_log
[error]

=== TEST 5: valid Bearer continues through authentication
--- request
GET /hello
--- more_headers
Origin: https://allowed.example.com
Authorization: Bearer valid-token
--- response_body
hello world
--- response_headers
Access-Control-Allow-Origin: https://allowed.example.com
Access-Control-Allow-Credentials: true
--- no_error_log
[error]

=== TEST 6: disallowed origin does not get CORS permission on preflight
--- request
OPTIONS /hello
--- more_headers
Origin: https://denied.example.com
Access-Control-Request-Method: GET
Access-Control-Request-Headers: authorization
--- response_headers
Access-Control-Allow-Origin:
Access-Control-Allow-Credentials:
--- no_error_log
[error]

=== TEST 7: disallowed origin does not get CORS permission on authentication failure
--- request
GET /hello
--- more_headers
Origin: https://denied.example.com
--- error_code: 401
--- response_headers
Access-Control-Allow-Origin:
Access-Control-Allow-Credentials:
--- no_error_log
[error]
