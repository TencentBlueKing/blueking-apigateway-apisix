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

=== TEST 1: sanity - schema and priority
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-appcode-validate")
            local ok, err = plugin.check_schema({
                support_public = true,
                support_personal = false
            })
            if not ok then
                ngx.say(err)
                return
            end

            ngx.say("priority: " .. plugin.priority)
        }
    }
--- response_body
priority: 17677

=== TEST 2: non-OAuth2 requests are skipped
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-appcode-validate")
            local ctx = {
                var = {
                    is_bk_oauth2 = false,
                    bk_app_code = "public"
                }
            }

            local result = plugin.rewrite({
                support_public = false,
                support_personal = false
            }, ctx)
            ngx.say(result == nil and "skipped" or "processed")
        }
    }
--- response_body
skipped

=== TEST 3: public-only configuration allows public
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-appcode-validate")
            local ctx = {
                var = {
                    uri = "/api/test",
                    bk_gateway_name = "demo",
                    is_bk_oauth2 = true,
                    bk_app_code = "public"
                }
            }

            local result = plugin.rewrite({
                support_public = true,
                support_personal = false
            }, ctx)
            ngx.say(result == nil and "pass" or "fail")
        }
    }
--- response_body
pass

=== TEST 4: public-only configuration rejects personal
--- extra_yaml_config
bk_gateway:
  hosts:
    bk-apigateway-api:
      tmpl: "http://{api_name}.bkapi.example.com"
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-appcode-validate")
            local ctx = {
                var = {
                    uri = "/api/test",
                    bk_gateway_name = "demo",
                    is_bk_oauth2 = true,
                    bk_app_code = "personal"
                }
            }

            local status = plugin.rewrite({
                support_public = true,
                support_personal = false
            }, ctx)
            ngx.status = 200
            ngx.say("status: " .. tostring(status))
            ngx.say("code_name: " .. ctx.var.bk_apigw_error.error.code_name)
            ngx.say("message: " .. ctx.var.bk_apigw_error.error.message)
        }
    }
--- response_body_like eval
qr/status: 401\ncode_name: UNAUTHORIZED\nmessage: Unauthorized .*OAuth2 token app code is not allowed.*/
--- response_headers_like
WWW-Authenticate: Bearer .*error="invalid_token".*bk_app_code=personal.*support_public=true.*support_personal=false"

=== TEST 5: personal-only configuration allows personal
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-appcode-validate")
            local ctx = {
                var = {
                    uri = "/api/test",
                    bk_gateway_name = "demo",
                    is_bk_oauth2 = true,
                    bk_app_code = "personal"
                }
            }

            local result = plugin.rewrite({
                support_public = false,
                support_personal = true
            }, ctx)
            ngx.say(result == nil and "pass" or "fail")
        }
    }
--- response_body
pass

=== TEST 6: personal-only configuration rejects public
--- extra_yaml_config
bk_gateway:
  hosts:
    bk-apigateway-api:
      tmpl: "http://{api_name}.bkapi.example.com"
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-appcode-validate")
            local ctx = {
                var = {
                    uri = "/api/test",
                    bk_gateway_name = "demo",
                    is_bk_oauth2 = true,
                    bk_app_code = "public"
                }
            }

            local status = plugin.rewrite({
                support_public = false,
                support_personal = true
            }, ctx)
            ngx.status = 200
            ngx.say("status: " .. tostring(status))
        }
    }
--- response_body
status: 401
--- response_headers_like
WWW-Authenticate: Bearer .*error="invalid_token".*support_public=false.*support_personal=true"

=== TEST 7: both-enabled configuration allows both app codes
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-appcode-validate")
            local ctx = {
                var = {
                    uri = "/api/test",
                    bk_gateway_name = "demo",
                    is_bk_oauth2 = true,
                    bk_app_code = "public"
                }
            }

            local conf = {
                support_public = true,
                support_personal = true
            }
            local public_result = plugin.rewrite(conf, ctx)
            ctx.var.bk_app_code = "personal"
            local personal_result = plugin.rewrite(conf, ctx)

            ngx.say(public_result == nil and "public: pass" or "public: fail")
            ngx.say(personal_result == nil and "personal: pass" or "personal: fail")
        }
    }
--- response_body
public: pass
personal: pass

=== TEST 8: default configuration rejects every OAuth2 app code
--- extra_yaml_config
bk_gateway:
  hosts:
    bk-apigateway-api:
      tmpl: "http://{api_name}.bkapi.example.com"
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-appcode-validate")
            local ctx = {
                var = {
                    uri = "/api/test",
                    bk_gateway_name = "demo",
                    is_bk_oauth2 = true,
                    bk_app_code = "public"
                }
            }

            local status = plugin.rewrite({
                support_public = false,
                support_personal = false
            }, ctx)
            ngx.status = 200
            ngx.say("status: " .. tostring(status))
        }
    }
--- response_body
status: 401
--- response_headers_like
WWW-Authenticate: Bearer .*error="invalid_token".*support_public=false.*support_personal=false"

=== TEST 9: ordinary app code stays unsupported when both flags are enabled
--- extra_yaml_config
bk_gateway:
  hosts:
    bk-apigateway-api:
      tmpl: "http://{api_name}.bkapi.example.com"
--- config
    location /t {
        content_by_lua_block {
            local plugin = require("apisix.plugins.bk-oauth2-appcode-validate")
            local ctx = {
                var = {
                    uri = "/api/test",
                    bk_gateway_name = "demo",
                    is_bk_oauth2 = true,
                    bk_app_code = "ordinary-app"
                }
            }

            local status = plugin.rewrite({
                support_public = true,
                support_personal = true
            }, ctx)
            ngx.status = 200
            ngx.say("status: " .. tostring(status))
        }
    }
--- response_body
status: 401
--- response_headers_like
WWW-Authenticate: Bearer .*error="invalid_token".*bk_app_code=ordinary-app.*support_public=true.*support_personal=true"
