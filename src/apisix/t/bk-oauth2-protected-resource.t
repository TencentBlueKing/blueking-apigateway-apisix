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

=== TEST 4: request with a bkauth Bearer token should set is_bk_oauth2=true
--- request
GET /hello
--- more_headers
Authorization: Bearer bkp_a1B2a1B2a1B2a1B2a1B2a1B2a1B2a1B2a1B2
--- response_body
hello world
--- no_error_log
[error]

=== TEST 5: malformed bkauth Bearer token should return 401 invalid_token
--- request
GET /hello
--- more_headers
Authorization: Bearer bkp_short
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer .*
--- error_log
malformed bkauth Bearer token, returning 401

=== TEST 6: non-bkauth Bearer token is treated as no credential
--- request
GET /hello
--- more_headers
Authorization: Bearer bkx_a1B2a1B2a1B2a1B2a1B2a1B2a1B2a1B2a1B2
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer .*
--- error_log
non-bkauth Bearer, treated as no credential

=== TEST 7: request without auth headers should return 401 with WWW-Authenticate
--- request
GET /hello
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer .*

=== TEST 8: X-Bkapi-Authorization takes precedence over Authorization Bearer
--- request
GET /hello
--- more_headers
X-Bkapi-Authorization: {"bk_app_code": "test"}
Authorization: Bearer test-token
--- response_body
hello world
--- no_error_log
[error]

=== TEST 9: non-Bearer Authorization should return 401
--- request
GET /hello
--- more_headers
Authorization: Basic dXNlcjpwYXNz
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer .*

=== TEST 10: should strip /api/{gateway_name} prefix when enabled
--- config
    location /t {
        content_by_lua_block {
            local bk_core = require("apisix.plugins.bk-core.init")
            local oauth2 = require("apisix.plugins.bk-core.oauth2")
            local old_get_tmpl = bk_core.config.get_bk_apigateway_api_tmpl
            local old_should_strip = bk_core.config.should_strip_subpath_prefix

            bk_core.config.get_bk_apigateway_api_tmpl = function()
                return "http://{api_name}.bkapi.example.com"
            end
            bk_core.config.should_strip_subpath_prefix = function()
                return true
            end

            local header = oauth2.build_www_authenticate_header({
                var = {
                    bk_gateway_name = "bk-apigateway",
                    uri = "/api/bk-apigateway/prod/api/v2/mcp-servers/bk-apigateway-prod-debugger/mcp/",
                },
            })

            bk_core.config.get_bk_apigateway_api_tmpl = old_get_tmpl
            bk_core.config.should_strip_subpath_prefix = old_should_strip

            ngx.say(header)
        }
    }
--- request
GET /t
--- response_body_like
resource=http%3A%2F%2Fbk-apigateway.bkapi.example.com%2Fprod%2Fapi%2Fv2%2Fmcp-servers%2Fbk-apigateway-prod-debugger%2Fmcp%2F.*

=== TEST 11: should not strip prefix when disabled
--- config
    location /t {
        content_by_lua_block {
            local bk_core = require("apisix.plugins.bk-core.init")
            local oauth2 = require("apisix.plugins.bk-core.oauth2")
            local old_get_tmpl = bk_core.config.get_bk_apigateway_api_tmpl
            local old_should_strip = bk_core.config.should_strip_subpath_prefix

            bk_core.config.get_bk_apigateway_api_tmpl = function()
                return "http://{api_name}.bkapi.example.com"
            end
            bk_core.config.should_strip_subpath_prefix = function()
                return false
            end

            local header = oauth2.build_www_authenticate_header({
                var = {
                    bk_gateway_name = "bk-apigateway",
                    uri = "/api/bk-apigateway/prod/api/v2/mcp-servers/bk-apigateway-prod-debugger/mcp/",
                },
            })

            bk_core.config.get_bk_apigateway_api_tmpl = old_get_tmpl
            bk_core.config.should_strip_subpath_prefix = old_should_strip

            ngx.say(header)
        }
    }
--- request
GET /t
--- response_body_like
resource=http%3A%2F%2Fbk-apigateway.bkapi.example.com%2Fapi%2Fbk-apigateway%2Fprod%2Fapi%2Fv2%2Fmcp-servers%2Fbk-apigateway-prod-debugger%2Fmcp%2F.*

=== TEST 12: should not strip partial gateway name prefix
--- config
    location /t {
        content_by_lua_block {
            local bk_core = require("apisix.plugins.bk-core.init")
            local oauth2 = require("apisix.plugins.bk-core.oauth2")
            local old_get_tmpl = bk_core.config.get_bk_apigateway_api_tmpl
            local old_should_strip = bk_core.config.should_strip_subpath_prefix

            bk_core.config.get_bk_apigateway_api_tmpl = function()
                return "http://{api_name}.bkapi.example.com"
            end
            bk_core.config.should_strip_subpath_prefix = function()
                return true
            end

            local header = oauth2.build_www_authenticate_header({
                var = {
                    bk_gateway_name = "bk-apigateway",
                    uri = "/api/bk-apigateway-extra/prod/api/v2/mcp-servers",
                },
            })

            bk_core.config.get_bk_apigateway_api_tmpl = old_get_tmpl
            bk_core.config.should_strip_subpath_prefix = old_should_strip

            ngx.say(header)
        }
    }
--- request
GET /t
--- response_body_like
resource=http%3A%2F%2Fbk-apigateway.bkapi.example.com%2Fapi%2Fbk-apigateway-extra%2Fprod%2Fapi%2Fv2%2Fmcp-servers.*

=== TEST 13: configure cookie authentication entrypoint routes
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local core = require("apisix.core")
            for _, cookie in ipairs({"bk_token", "bk_ticket"}) do
                local auth = cookie == "bk_token"
                    and {user_conf = {user_type = "bkuser", from_bk_token = true}}
                    or {rtx_conf = {user_type = "rtx", from_bk_ticket = true}}
                local code, body = t("/apisix/admin/routes/cookie-" .. cookie,
                    ngx.HTTP_PUT, core.json.encode({
                        uri = "/cookie-" .. cookie,
                        plugins = {
                            ["bk-stage-context"] = {
                                bk_gateway_name = "test", bk_stage_name = "prod",
                                jwt_private_key = "dGVzdA==", bk_api_auth = auth,
                            },
                            ["bk-resource-context"] = {
                                bk_resource_auth = {
                                    verified_user_required = true,
                                    verified_app_required = false,
                                },
                            },
                            ["bk-oauth2-protected-resource"] = {},
                            ["proxy-rewrite"] = {uri = "/hello"},
                            ["serverless-post-function"] = {
                                phase = "rewrite",
                                functions = {
                                    "return function(conf, ctx) ngx.header['X-Auth-Flow'] = ctx.var.is_bk_oauth2 and 'oauth2' or 'legacy' end"
                                },
                            },
                        },
                        upstream = {
                            nodes = {["127.0.0.1:1980"] = 1}, type = "roundrobin",
                        },
                    }))
                if code >= 300 then
                    ngx.status = code
                    ngx.say(body)
                    return
                end
            end
            ngx.say("passed")
        }
    }
--- response_body
passed

=== TEST 14: configured bk_token cookie selects legacy authentication
--- request
GET /cookie-bk_token
--- more_headers
Cookie: bk_token=user-ticket
--- response_headers
X-Auth-Flow: legacy
--- no_error_log
[error]

=== TEST 15: configured bk_ticket cookie selects legacy authentication
--- request
GET /cookie-bk_ticket
--- more_headers
Cookie: bk_ticket=user-ticket
--- response_headers
X-Auth-Flow: legacy
--- no_error_log
[error]

=== TEST 16: missing cookie retains OAuth2 challenge
--- request
GET /cookie-bk_token
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer .*

=== TEST 17: bkauth Bearer takes precedence over configured cookie
--- request
GET /cookie-bk_token
--- more_headers
Cookie: bk_token=user-ticket
Authorization: Bearer bkp_a1B2a1B2a1B2a1B2a1B2a1B2a1B2a1B2a1B2
--- response_headers
X-Auth-Flow: oauth2
--- no_error_log
[error]

=== TEST 18: malformed bkauth Bearer does not fall back to configured cookie
--- request
GET /cookie-bk_token
--- more_headers
Cookie: bk_token=user-ticket
Authorization: Bearer bkp_short
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer .*
--- error_log
malformed bkauth Bearer token, returning 401

=== TEST 19: non-bkauth Bearer does not block configured cookie
--- request
GET /cookie-bk_token
--- more_headers
Cookie: bk_token=user-ticket
Authorization: Bearer backend-own-token
--- response_headers
X-Auth-Flow: legacy
--- no_error_log
[error]

=== TEST 20: require app authentication on cookie entrypoint routes
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local core = require("apisix.core")
            for _, cookie in ipairs({"bk_token", "bk_ticket"}) do
                local code, body = t("/apisix/admin/routes/cookie-" .. cookie,
                    ngx.HTTP_PATCH, core.json.encode({
                        plugins = {
                            ["bk-resource-context"] = {
                                bk_resource_auth = {
                                    verified_user_required = true,
                                    verified_app_required = true,
                                },
                            },
                        },
                    }))
                if code >= 300 then
                    ngx.status = code
                    ngx.say(body)
                    return
                end
            end
            ngx.say("passed")
        }
    }
--- response_body
passed

=== TEST 21: bk_token retains OAuth2 challenge when app authentication is required
--- extra_yaml_config
bk_gateway:
  hosts:
    bk-apigateway-api:
      tmpl: "http://{api_name}.bkapi.example.com"
--- request
GET /cookie-bk_token
--- more_headers
Cookie: bk_token=user-ticket
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer .*resource_metadata=.*

=== TEST 22: bk_ticket retains OAuth2 challenge when app authentication is required
--- extra_yaml_config
bk_gateway:
  hosts:
    bk-apigateway-api:
      tmpl: "http://{api_name}.bkapi.example.com"
--- request
GET /cookie-bk_ticket
--- more_headers
Cookie: bk_ticket=user-ticket
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer .*resource_metadata=.*

=== TEST 23: configure a route with only the app channel enabled
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local core = require("apisix.core")
            local code, body = t("/apisix/admin/routes/app-channel-only",
                ngx.HTTP_PUT, core.json.encode({
                    uri = "/app-channel-only",
                    plugins = {
                        ["bk-oauth2-protected-resource"] = {challenge_on_missing_credential = false},
                        ["proxy-rewrite"] = {uri = "/hello"},
                        ["serverless-post-function"] = {
                            phase = "rewrite",
                            functions = {
                                "return function(conf, ctx) ngx.header['X-Auth-Flow'] = ctx.var.is_bk_oauth2 and 'oauth2' or 'legacy' end"
                            },
                        },
                    },
                    upstream = {
                        nodes = {["127.0.0.1:1980"] = 1}, type = "roundrobin",
                    },
                }))
            if code >= 300 then
                ngx.status = code
            end
            ngx.say(body)
        }
    }
--- response_body
passed

=== TEST 24: app channel only, no credential uses legacy authentication
--- request
GET /app-channel-only
--- response_headers
X-Auth-Flow: legacy
--- no_error_log
[error]

=== TEST 25: app channel only, non-bkauth Bearer uses legacy authentication
--- request
GET /app-channel-only
--- more_headers
Authorization: Bearer backend-own-token
--- response_headers
X-Auth-Flow: legacy
--- no_error_log
[error]

=== TEST 26: app channel only, bkauth Bearer uses OAuth2 authentication
--- request
GET /app-channel-only
--- more_headers
Authorization: Bearer tai_pat_anything
--- response_headers
X-Auth-Flow: oauth2
--- no_error_log
[error]

=== TEST 27: app channel only, malformed bkauth Bearer returns 401
--- request
GET /app-channel-only
--- more_headers
Authorization: Bearer bko_short
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer .*
--- error_log
malformed bkauth Bearer token, returning 401
