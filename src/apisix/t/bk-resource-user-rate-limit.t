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

=== TEST 1: user quotas through OAuth2, resource context, access and error wrapping
--- config
    location /t {
        content_by_lua_block {
            local t = require("lib.test_admin").test
            local core = require("apisix.core")
            local mock_services = [[return function()
                local cache = require("apisix.plugins.bk-cache.oauth2-access-token")
                cache.get_oauth2_access_token = function(token)
                    local username = token
                    local app_code = "app-one"
                    if token == "alice-other-app" then
                        username, app_code = "alice", "app-two"
                    elseif token == "anonymous" then
                        username = ""
                    end
                    return {active = true, exp = ngx.time() + 60,
                        bk_app_code = app_code, bk_username = username, audience = {}}
                end
                local redis = require("apisix.plugins.bk-rate-limit.rate-limit-redis")
                if not redis.user_limit_test_initialized then
                    redis.user_limit_test_initialized = true
                    local counters = {}
                    redis.new = function(namespace)
                        return {incoming = function(_, key, limit, window)
                            if key:find("backend-error:", 1, true) then
                                return nil, "test backend unavailable", 0
                            end
                            key = namespace .. ":" .. key
                            counters[key] = (counters[key] or 0) + 1
                            if counters[key] > limit then
                                return nil, "rejected", window
                            end
                            return 0, limit - counters[key], window
                        end}
                    end
                end
            end]]
            local route = {
                uri = "/hello",
                plugins = {
                    ["bk-stage-context"] = {
                        bk_gateway_name = "test", bk_stage_name = "prod",
                        jwt_private_key = "dGVzdA==", bk_api_auth = {},
                    },
                    ["bk-resource-context"] = {bk_resource_name = "hello"},
                    ["serverless-pre-function"] = {
                        _meta = {priority = 18745}, phase = "rewrite",
                        functions = {mock_services},
                    },
                    ["bk-oauth2-protected-resource"] = {},
                    ["bk-oauth2-verify"] = {},
                    ["bk-resource-user-rate-limit"] = {
                        rates = {
                            __default = {{period = 60, tokens = 1}},
                            vip = {{period = 60, tokens = 2}},
                            exempt = {},
                            multi = {{period = 60, tokens = 3}, {period = 3600, tokens = 1}},
                        },
                    },
                    ["bk-error-wrapper"] = {},
                    ["proxy-rewrite"] = {uri = "/hello"},
                },
                upstream = {nodes = {["127.0.0.1:1980"] = 1}, type = "roundrobin"},
            }
            local code, body = t('/apisix/admin/routes/user-limit', ngx.HTTP_PUT,
                core.json.encode(route))
            assert(code < 300, body)
            route.uri = "/other-resource"
            route.plugins["bk-resource-context"].bk_resource_name = "other-resource"
            code, body = t('/apisix/admin/routes/user-limit-other', ngx.HTTP_PUT,
                core.json.encode(route))
            assert(code < 300, body)
            route.uri = "/no-degradation"
            route.plugins["bk-resource-user-rate-limit"].allow_degradation = false
            code, body = t('/apisix/admin/routes/user-limit-no-degradation', ngx.HTTP_PUT,
                core.json.encode(route))
            assert(code < 300, body)
            -- Keep requests in one Nginx instance so the fake Redis counters persist.
            local httpc = require("resty.http").new()
            local function request(token, uri, status, headers)
                local res, err = httpc:request_uri(
                    "http://127.0.0.1:" .. ngx.var.server_port .. (uri or "/hello"),
                    {headers = {Authorization = "Bearer " .. token}}
                )
                assert(res, err)
                assert(res.status == status, token .. ": " .. res.status .. " " .. res.body)
                for name, value in pairs(headers or {}) do
                    assert(tostring(res.headers[name]) == value, name .. ": " ..
                        tostring(res.headers[name]))
                end
                if status == 429 then
                    assert(core.json.decode(res.body).code == 1642903, res.body)
                end
                return res
            end

            request("alice", nil, 200, {
                ["X-Bkapi-RateLimit-Limit"] = "1",
                ["X-Bkapi-RateLimit-Remaining"] = "0",
                ["X-Bkapi-RateLimit-Plugin"] = "bk-resource-user-rate-limit",
            })
            request("alice-other-app", nil, 429, {
                ["X-Bkapi-RateLimit-Remaining"] = "0",
                ["X-Bkapi-RateLimit-Plugin"] = "bk-resource-user-rate-limit",
            })
            request("bob", nil, 200)
            ngx.say("default quotas are per user and shared across apps")

            request("vip", nil, 200, {["X-Bkapi-RateLimit-Remaining"] = "1"})
            request("vip", nil, 200)
            request("vip", nil, 429)
            request("exempt", nil, 200)
            request("exempt", nil, 200)
            ngx.say("user overrides replace defaults and empty rules exempt users")

            local res = request("anonymous", nil, 200)
            assert(res.headers["X-Bkapi-RateLimit-Plugin"] == nil)
            request("anonymous", nil, 200)
            request("alice", "/other-resource", 200)
            ngx.say("anonymous users are skipped and resources have separate counters")

            request("multi", nil, 200)
            request("multi", nil, 429, {
                ["X-Bkapi-RateLimit-Limit"] = "1",
                ["X-Bkapi-RateLimit-Remaining"] = "0",
                ["X-Bkapi-RateLimit-Reset"] = "3600",
            })
            ngx.say("all time windows are enforced")

            request("backend-error", nil, 200)
            request("backend-error", "/no-degradation", 429)
            ngx.say("backend failures follow allow_degradation")
        }
    }
--- response_body
default quotas are per user and shared across apps
user overrides replace defaults and empty rules exempt users
anonymous users are skipped and resources have separate counters
all time windows are enforced
backend failures follow allow_degradation
--- error_log
test backend unavailable
