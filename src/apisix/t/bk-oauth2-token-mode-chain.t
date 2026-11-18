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

# The whole OAuth2 plugin chain of a real app route (support_app=true), with the bkauth
# introspection stubbed: token mode mismatches return 401 with WWW-Authenticate in both
# directions, an audience mismatch still returns 403, and the legacy entry is unchanged.

use t::APISIX 'no_plan';

repeat_each(1);
no_long_string();
no_root_location();
no_shuffle();

add_block_preprocessor(sub {
    my ($block) = @_;

    my $extra_init_by_lua = <<'_EOC_';
        require("apisix.plugins.bk-core.init").config.get_bk_apigateway_api_tmpl = function()
            return "http://{api_name}.example.com"
        end

        local oauth2_cache = require("apisix.plugins.bk-cache.oauth2-access-token")
        local results = {
            tai_pat_delegated = {
                bk_username = "u-sub-1", bk_login_name = "tom", client_id = "real-app",
                audience = { "gateway:demo/api:*" },
            },
            tai_pat_app = {
                bk_username = "real-app", bk_login_name = "", client_id = "real-app",
                audience = { "gateway:demo/api:*" },
            },
            tai_pat_other_audience = {
                bk_username = "u-sub-1", bk_login_name = "tom", client_id = "real-app",
                audience = { "gateway:other/api:*" },
            },
        }
        oauth2_cache.get_oauth2_access_token = function(token)
            local result = results[token]
            if not result then
                return nil, "unexpected token"
            end
            result.active = true
            result.exp = 4102444800
            result.bk_app_code = "real-app"
            return result, nil
        end
_EOC_

    $block->set_value("extra_init_by_lua", $extra_init_by_lua);

    if (!defined $block->request) {
        $block->set_value("request", "GET /t");
    }
});

run_tests;

__DATA__

=== TEST 1: configure a user-required route and an app-only route with the app channel
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local core = require("apisix.core")

            local function route(name, user_required)
                return core.json.encode({
                    name = name,
                    uri = "/" .. name,
                    plugins = {
                        ["bk-stage-context"] = {
                            bk_gateway_name = "demo",
                            bk_stage_name = "prod",
                            jwt_private_key = "dGhpcyBpcyBhIGZha2Ugand0IHByaXZhdGUga2V5",
                            bk_api_auth = {
                                api_type = 10,
                                user_conf = {user_type = "bkuser", from_bk_token = true, from_username = false},
                            },
                        },
                        ["bk-resource-context"] = {
                            bk_resource_id = 1,
                            bk_resource_name = name,
                            bk_resource_auth = {
                                verified_app_required = true,
                                verified_user_required = user_required,
                                resource_perm_required = false,
                            },
                        },
                        ["bk-oauth2-protected-resource"] = {challenge_on_missing_credential = false},
                        ["bk-oauth2-verify"] = {},
                        ["bk-auth-verify"] = {},
                        ["bk-auth-validate"] = {},
                        ["bk-oauth2-appcode-validate"] = {support_app = true},
                        ["bk-oauth2-audience-validate"] = {},
                        ["proxy-rewrite"] = {uri = "/hello"},
                    },
                    upstream = {
                        nodes = {["127.0.0.1:1980"] = 1}, type = "roundrobin",
                    },
                })
            end

            for id, conf in pairs({
                ["chain-user"] = route("chain-user", true),
                ["chain-app"] = route("chain-app", false),
            }) do
                local code, body = t("/apisix/admin/routes/" .. id, ngx.HTTP_PUT, conf)
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

=== TEST 2: user-required resource allows a delegated token
--- request
GET /chain-user
--- more_headers
Authorization: Bearer tai_pat_delegated
--- response_body
hello world
--- no_error_log
[error]

=== TEST 3: user-required resource rejects an app token with 401
--- request
GET /chain-user
--- more_headers
Authorization: Bearer tai_pat_app
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer .*error="invalid_token".*only OAuth2 delegated tokens are allowed.*token_mode=app.*
--- no_error_log
[error]

=== TEST 4: app-only resource allows an app token
--- request
GET /chain-app
--- more_headers
Authorization: Bearer tai_pat_app
--- response_body
hello world
--- no_error_log
[error]

=== TEST 5: app-only resource rejects a delegated token with 401
--- request
GET /chain-app
--- more_headers
Authorization: Bearer tai_pat_delegated
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer .*error="invalid_token".*only OAuth2 app tokens are allowed.*token_mode=delegated.*
--- no_error_log
[error]

=== TEST 6: audience mismatch still returns 403
--- request
GET /chain-user
--- more_headers
Authorization: Bearer tai_pat_other_audience
--- error_code: 403
--- response_headers_like
WWW-Authenticate: Bearer .*error="invalid_audience".*
--- no_error_log
[error]

=== TEST 7: legacy entry without credential keeps the legacy 400 and no challenge
--- request
GET /chain-user
--- error_code: 400
--- response_headers
WWW-Authenticate:
--- no_error_log
[error]
