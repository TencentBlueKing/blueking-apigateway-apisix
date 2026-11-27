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

# Exercise OAuth2 and legacy authentication through APISIX routes.
# Mock external bkauth and permission responses, then inspect the headers the backend receives.

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

        local core = require("apisix.core")
        local bkauth_http = require("apisix.plugins.bk-components.utils")
        local permission = require("apisix.plugins.bk-components.bk-apigateway-core")

        local function claims(app_code, sub, client_id, username, audience)
            return {
                active = true,
                bk_app_code = app_code,
                sub = sub,
                client_id = client_id,
                username = username,
                aud = { audience or "gateway:demo/api:*" },
                exp = 4102444800,
            }
        end

        local results = {
            tai_pat_delegated = claims("real-app", "oauth-client", "oauth-client", "tom"),
            tai_pat_app = claims("real-app", "oauth-client", "oauth-client", ""),
            tai_pat_app_ungranted = claims("ungranted-app", "oauth-client", "oauth-client", ""),
            tai_pat_missing_username = claims("real-app", "oauth-client", "oauth-client", nil),
            tai_pat_null_username = claims("real-app", "oauth-client", "oauth-client", ngx.null),
            tai_pat_personal = claims("personal", "u-sub-1", "personal", "tom"),
            tai_pat_personal_wrong_audience_no_user =
                claims("personal", "", "personal", nil, "gateway:other/api:*"),
            tai_pat_public_no_user = claims("public", "", "public", nil),
            tai_pat_other_audience = claims("real-app", "u-sub-1", "oauth-client", "tom", "gateway:other/api:*"),
            bkp_short = {
                active = false,
                error = { code = "", message = "invalid token format" },
            },
            tai_pat_inactive = {
                active = false,
                error = { code = "EXPIRED", message = "bkauth expired detail" },
            },
        }

        bkauth_http.handle_request = function(url, params)
            local request = assert(core.json.decode(params.body))
            local result
            if url:match("/realms/blueking/oauth2/introspect$") then
                if request.token == "tai_pat_timeout" then
                    return nil, "bkauth request timeout"
                end
                result = assert(results[request.token], "unexpected introspection request")
            else
                assert(url:match("/api/v1/apps/legacy%-app/access%-keys/verify$"), "unexpected bkauth URL")
                result = { code = 0, data = { is_match = request.bk_app_secret == "legacy-test-secret" } }
            end
            return { status = 200, body = core.json.encode(result) }
        end

        permission.query_permission = function(gateway, stage, resource, app_code)
            assert(gateway == "demo" and stage == "prod", "unexpected permission lookup")
            if app_code == "real-app" or app_code == "legacy-app" then
                return { [gateway .. ":" .. resource .. ":" .. app_code] = ngx.time() + 60 }
            end
            return {}
        end
_EOC_

    $block->set_value("extra_init_by_lua", $extra_init_by_lua);
    $block->set_value("http_config", <<'_EOC_');
        lua_shared_dict plugin-bk-cache-fallback-lock 1m;
        lua_shared_dict plugin-bk-permission 1m;
_EOC_

    my $upstream_server_config = <<'_EOC_';
        location = /oauth2-chain-echo {
            content_by_lua_block {
                local jwt = require("resty.jwt")
                local headers = ngx.req.get_headers()
                local assertion = jwt:load_jwt(assert(headers["X-Bkapi-Jwt"], "missing gateway JWT"))
                assert(assertion.valid, "invalid gateway JWT")
                ngx.say("app=", assertion.payload.app.app_code)
                ngx.say("username=", assertion.payload.user.username)
                ngx.say("user_verified=", tostring(assertion.payload.user.verified))
                ngx.say("authorization=", headers["Authorization"] or "")
            }
        }
_EOC_

    $block->set_value("upstream_server_config", $upstream_server_config);

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
            local pkey = require("resty.openssl.pkey")
            local private_key = assert(pkey.new({ type = "RSA", bits = 2048 }))
            local encoded_key = ngx.encode_base64(assert(private_key:to_PEM("private")))

            local function route(name, user_required, support_app, builtin_client, exempt_user)
                return core.json.encode({
                    name = name,
                    uri = "/" .. name,
                    plugins = {
                        ["bk-stage-context"] = {
                            bk_gateway_name = "demo",
                            bk_stage_name = "prod",
                            jwt_private_key = encoded_key,
                            bk_api_auth = {
                                api_type = 10,
                                allow_auth_from_params = true,
                                user_conf = {user_type = "bkuser", from_bk_token = true, from_username = false},
                            },
                        },
                        ["bk-resource-context"] = {
                            bk_resource_id = 1,
                            bk_resource_name = name,
                            bk_resource_auth = {
                                verified_app_required = true,
                                verified_user_required = user_required,
                                skip_user_verification = exempt_user,
                                resource_perm_required = support_app,
                            },
                        },
                        ["bk-verified-user-exempted-apps"] = exempt_user and {
                            exempted_apps = {{ bk_app_code = "real-app", dimension = "api" }},
                        } or nil,
                        ["bk-oauth2-protected-resource"] = {
                            challenge_on_missing_credential = builtin_client ~= nil,
                        },
                        ["bk-oauth2-verify"] = {},
                        ["bk-auth-verify"] = {},
                        ["bk-auth-validate"] = {},
                        ["bk-oauth2-appcode-validate"] = {
                            support_app = support_app,
                            support_personal = builtin_client == "personal",
                            support_public = builtin_client == "public",
                        },
                        ["bk-oauth2-audience-validate"] = {},
                        ["bk-error-wrapper"] = {},
                        ["bk-jwt"] = {},
                        ["bk-permission"] = {},
                        ["proxy-rewrite"] = {uri = "/oauth2-chain-echo"},
                    },
                    upstream = {
                        nodes = {["127.0.0.1:1980"] = 1}, type = "roundrobin",
                    },
                })
            end

            for id, conf in pairs({
                ["chain-user"] = route("chain-user", true, true),
                ["chain-app"] = route("chain-app", false, true),
                ["chain-app-disabled"] = route("chain-app-disabled", true, false, "personal"),
                ["chain-public"] = route("chain-public", true, false, "public"),
                ["chain-user-exempt"] = route("chain-user-exempt", true, true, nil, true),
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

=== TEST 2: user-required resource allows a delegated token when sub equals client_id
--- request
GET /chain-user
--- more_headers
Authorization: Bearer tai_pat_delegated
--- response_body
app=real-app
username=oauth-client
user_verified=true
authorization=
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
app=real-app
username=
user_verified=false
authorization=
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

=== TEST 6: audience mismatch returns 401 invalid_token
--- request
GET /chain-user
--- more_headers
Authorization: Bearer tai_pat_other_audience
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer .*error="invalid_token".*
--- response_body_like: "code_name":"UNAUTHORIZED"
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

=== TEST 8: the app channel check rejects an app token on a disabled route
--- request
GET /chain-app-disabled
--- more_headers
Authorization: Bearer tai_pat_app
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer .*error="invalid_token".*the OAuth2 app channel is not enabled for this route.*
--- response_body_like: the OAuth2 app channel is not enabled for this route
--- no_error_log
[error]

=== TEST 9: a real app's delegated token is rejected when the app channel is disabled
--- request
GET /chain-app-disabled
--- more_headers
Authorization: Bearer tai_pat_delegated
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer .*error="invalid_token".*the OAuth2 app channel is not enabled for this route.*
--- response_body_like: the OAuth2 app channel is not enabled for this route
--- no_error_log
[error]

=== TEST 10: a personal client still works with the app channel disabled
--- request
GET /chain-app-disabled
--- more_headers
Authorization: Bearer tai_pat_personal
--- response_body
app=personal
username=u-sub-1
user_verified=true
authorization=
--- no_error_log
[error]

=== TEST 11: a request without credentials receives a discovery-only challenge
--- request
GET /chain-app-disabled
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer resource_metadata="[^"]+"
--- no_error_log
[error]

=== TEST 12: inactive introspection uses a standard code and includes the bkauth reason
--- request
GET /chain-app
--- more_headers
Authorization: Bearer tai_pat_inactive
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer .*error="invalid_token", error_description="the access token is inactive \[bkauth expired detail\]"
--- response_body_like: ^(?=.*the access token is inactive \[bkauth expired detail\]).*"code_name":"UNAUTHORIZED"
--- no_error_log
[error]

=== TEST 13: introspection timeout returns 503 without a Bearer challenge
--- request
GET /chain-app
--- more_headers
Authorization: Bearer tai_pat_timeout
--- error_code: 503
--- response_headers
WWW-Authenticate:
--- response_body_like: ^(?=.*bkauth request timeout).*"code_name":"SERVICE_UNAVAILABLE"
--- error_log
bkauth request timeout

=== TEST 14: an enabled public route sends a discovery challenge without credentials
--- request
GET /chain-public
--- error_code: 401
--- response_headers_like
WWW-Authenticate: ^Bearer resource_metadata="[^"]+"$
--- no_error_log
[error]

=== TEST 15: audience mismatch precedes the generic user check for an allowed personal client
--- request
GET /chain-app-disabled
--- more_headers
Authorization: Bearer tai_pat_personal_wrong_audience_no_user
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer resource_metadata="[^"]+", error="invalid_token".*gateway mismatch.*
--- no_error_log
[error]

=== TEST 16: a disabled personal client is rejected before the audience and generic user checks
--- request
GET /chain-public
--- more_headers
Authorization: Bearer tai_pat_personal_wrong_audience_no_user
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer resource_metadata="[^"]+", error="invalid_token".*OAuth2 token app code is not allowed.*
--- no_error_log
[error]

=== TEST 17: an allowed public client with matching audience still requires a user
--- request
GET /chain-public
--- more_headers
Authorization: Bearer tai_pat_public_no_user
--- error_code: 400
--- response_headers
WWW-Authenticate:
--- no_error_log
[error]

=== TEST 18: legacy user exemptions do not allow an app token on a user-required resource
--- request
GET /chain-user-exempt
--- more_headers
Authorization: Bearer tai_pat_app
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer .*error="invalid_token".*only OAuth2 delegated tokens are allowed.*
--- no_error_log
[error]

=== TEST 19: a short bkauth Bearer is rejected by introspection
--- request
GET /chain-app
--- more_headers
Authorization: Bearer bkp_short
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer .*error="invalid_token", error_description="the access token is inactive \[invalid token format\]"
--- response_body_like: "code_name":"UNAUTHORIZED"
--- no_error_log
[error]


=== TEST 20: an app token without resource permission receives 403
--- request
GET /chain-app
--- more_headers
Authorization: Bearer tai_pat_app_ungranted
--- error_code: 403
--- response_headers
WWW-Authenticate:
--- response_body_like: "code_name":"APP_NO_PERMISSION"

=== TEST 21: legacy app credentials in the header preserve a backend Bearer
--- request
GET /chain-app
--- more_headers
X-Bkapi-Authorization: {"bk_app_code":"legacy-app","bk_app_secret":"legacy-test-secret"}
Authorization: Bearer backend-token
--- response_body
app=legacy-app
username=
user_verified=false
authorization=Bearer backend-token
--- no_error_log
[error]

=== TEST 22: legacy app credentials in the query preserve a backend Bearer
--- request
GET /chain-app?bk_app_code=legacy-app&bk_app_secret=legacy-test-secret
--- more_headers
Authorization: Bearer backend-token
--- response_body
app=legacy-app
username=
user_verified=false
authorization=Bearer backend-token
--- no_error_log
[error]

=== TEST 23: legacy app credentials in the JSON body preserve a backend Bearer
--- request
POST /chain-app
{"bk_app_code":"legacy-app","bk_app_secret":"legacy-test-secret"}
--- more_headers
Content-Type: application/json
Authorization: Bearer backend-token
--- response_body
app=legacy-app
username=
user_verified=false
authorization=Bearer backend-token
--- no_error_log
[error]

=== TEST 24: a missing introspection username does not qualify as an app token
--- request
GET /chain-app
--- more_headers
Authorization: Bearer tai_pat_missing_username
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer .*error="invalid_token".*token_mode=unknown"
--- no_error_log
[error]

=== TEST 25: a null introspection username does not qualify as an app token
--- request
GET /chain-app
--- more_headers
Authorization: Bearer tai_pat_null_username
--- error_code: 401
--- response_headers_like
WWW-Authenticate: Bearer .*error="invalid_token".*token_mode=unknown"
--- no_error_log
[error]

=== TEST 26: query fallback with a backend Bearer still requires a verified user
--- request
GET /chain-app-disabled?bk_app_code=legacy-app&bk_app_secret=legacy-test-secret
--- more_headers
Authorization: Bearer backend-token
--- error_code: 400
--- response_headers
X-Bkapi-Auth-Flow: fallback_query
WWW-Authenticate:
--- response_body_like: "code_name":"INVALID_ARGS"
--- no_error_log
[error]

=== TEST 27: a rejected bkauth Bearer retains the OAuth2 flow with query credentials
--- request
GET /chain-app-disabled?bk_app_code=legacy-app&bk_app_secret=legacy-test-secret
--- more_headers
Authorization: Bearer bkp_short
--- error_code: 401
--- response_headers
X-Bkapi-Auth-Flow: oauth2
--- response_headers_like
WWW-Authenticate: Bearer .*error="invalid_token".*invalid token format.*
--- no_error_log
[error]
