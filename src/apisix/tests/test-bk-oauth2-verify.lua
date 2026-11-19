--
-- TencentBlueKing is pleased to support the open source community by making
-- 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
-- Copyright (C) Tencent. All rights reserved.
-- Licensed under the MIT License (the "License"); you may not use this file except
-- in compliance with the License. You may obtain a copy of the License at
--
--     http://opensource.org/licenses/MIT
--
-- Unless required by applicable law or agreed to in writing, software distributed under
-- the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
-- either express or implied. See the License for the specific language governing permissions and
-- limitations under the License.
--
-- We undertake not to change the open source license (MIT license) applicable
-- to the current version of the project delivered to anyone in the future.
--
local core = require("apisix.core")
local bk_core = require("apisix.plugins.bk-core.init")
local oauth2_cache = require("apisix.plugins.bk-cache.oauth2-access-token")
local plugin = require("apisix.plugins.bk-oauth2-verify")

describe(
    "bk-oauth2-verify", function()
        local ctx
        local cached_result
        local authorization_header
        local www_authenticate_header

        before_each(
            function()
                ctx = {
                    var = {
                        bk_gateway_name = "demo",
                        uri = "/api/v1/users",
                    },
                }
                cached_result = nil
                authorization_header = nil
                www_authenticate_header = nil

                stub(
                    core.request, "header", function(_, name)
                        if name == "Authorization" then
                            return authorization_header
                        end
                        return nil
                    end
                )

                stub(
                    core.request, "set_header", function(_, name, value)
                        if string.lower(name) == "authorization" then
                            authorization_header = value
                        end
                    end
                )

                ngx.header = {}
                setmetatable(ngx.header, {
                    __newindex = function(tbl, key, value)
                        rawset(tbl, key, value)
                        if key == "WWW-Authenticate" then
                            www_authenticate_header = value
                        end
                    end,
                })

                stub(
                    oauth2_cache, "get_oauth2_access_token", function(token)
                        if cached_result then
                            return cached_result, nil
                        end
                        return nil, "token verification failed"
                    end
                )

                stub(
                    bk_core.config, "get_bk_apigateway_api_tmpl", function()
                        return "https://bk-apigateway-api.example.com"
                    end
                )
            end
        )

        after_each(
            function()
                core.request.header:revert()
                core.request.set_header:revert()
                oauth2_cache.get_oauth2_access_token:revert()
                bk_core.config.get_bk_apigateway_api_tmpl:revert()
            end
        )

        context(
            "check_schema", function()
                it(
                    "should accept empty config", function()
                        local ok, err = plugin.check_schema({})
                        assert.is_true(ok)
                        assert.is_nil(err)
                    end
                )
            end
        )

        context(
            "rewrite phase", function()
                it(
                    "should skip when is_bk_oauth2 is false", function()
                        ctx.var.is_bk_oauth2 = false
                        authorization_header = "Bearer backend-token"

                        local result = plugin.rewrite({}, ctx)

                        assert.is_nil(result)
                        assert.is_nil(ctx.var.bk_app)
                        assert.is_equal("Bearer backend-token", authorization_header)
                    end
                )

                it(
                    "should skip when is_bk_oauth2 is nil", function()
                        ctx.var.is_bk_oauth2 = nil
                        authorization_header = "Basic backend-credentials"

                        local result = plugin.rewrite({}, ctx)

                        assert.is_nil(result)
                        assert.is_nil(ctx.var.bk_app)
                        assert.is_equal("Basic backend-credentials", authorization_header)
                    end
                )

                it(
                    "should authenticate and remove the Bearer Authorization header", function()
                        ctx.var.is_bk_oauth2 = true
                        authorization_header = "Bearer valid-token"
                        cached_result = {
                            active = true,
                            exp = 4102444800,
                            bk_app_code = "test-app",
                            bk_username = "test-user",
                            audience = {"gateway:demo/api:test"},
                        }

                        local result = plugin.rewrite({}, ctx)

                        assert.is_nil(result)
                        assert.is_not_nil(ctx.var.bk_app)
                        assert.is_not_nil(ctx.var.bk_user)
                        assert.is_equal("test-app", ctx.var.bk_app_code)
                        assert.is_equal("header", ctx.var.auth_params_location)
                        assert.stub(oauth2_cache.get_oauth2_access_token).was_called_with("valid-token")
                        assert.is_nil(authorization_header)
                    end
                )

                it(
                    "should set audience from verification result", function()
                        ctx.var.is_bk_oauth2 = true
                        authorization_header = "Bearer valid-token"
                        cached_result = {
                            active = true,
                            exp = 4102444800,
                            bk_app_code = "test-app",
                            bk_username = "test-user",
                            audience = {"mcp_server:my-server", "gateway:demo/api:*"},
                        }

                        plugin.rewrite({}, ctx)

                        assert.is_not_nil(ctx.var.audience)
                        assert.is_equal(2, #ctx.var.audience)
                    end
                )

                it(
                    "should return 503 without a challenge when introspection fails", function()
                        ctx.var.is_bk_oauth2 = true
                        authorization_header = "Bearer example-token"

                        local status = plugin.rewrite({}, ctx)

                        assert.is_equal(503, status)
                        assert.is_nil(www_authenticate_header)
                    end
                )

                it(
                    "should reject an introspection result without active", function()
                        ctx.var.is_bk_oauth2 = true
                        authorization_header = "Bearer example-token"
                        cached_result = {
                            exp = 4102444800,
                            bk_app_code = "test-app",
                            error = {},
                        }

                        local status = plugin.rewrite({}, ctx)

                        assert.is_equal(401, status)
                        assert.is_nil(ctx.var.bk_app)
                        assert.matches(
                            'error="invalid_token", error_description="the access token is inactive"$',
                            www_authenticate_header
                        )
                    end
                )

                it(
                    "should return 401 when no token is present", function()
                        ctx.var.is_bk_oauth2 = true
                        authorization_header = nil

                        local status = plugin.rewrite({}, ctx)

                        assert.is_equal(401, status)
                        assert.is_truthy(www_authenticate_header)
                        assert.is_true(
                            string.find(
                                www_authenticate_header,
                                "resource=https%3A%2F%2Fbk-apigateway-api.example.com%2Fapi%2Fv1%2Fusers",
                                1,
                                true
                            ) ~= nil
                        )
                    end
                )
            end
        )

        context(
            "token extraction", function()
                it(
                    "should extract token from Authorization header", function()
                        ctx.var.is_bk_oauth2 = true
                        authorization_header = "Bearer my-token-123"
                        cached_result = {
                            active = true,
                            exp = 4102444800,
                            bk_app_code = "app",
                            bk_username = "user",
                            audience = {},
                        }

                        plugin.rewrite({}, ctx)

                        assert.stub(oauth2_cache.get_oauth2_access_token).was_called_with("my-token-123")
                    end
                )

                it(
                    "should handle case-insensitive Bearer prefix", function()
                        ctx.var.is_bk_oauth2 = true
                        authorization_header = "bearer lowercase-token"
                        cached_result = {
                            active = true,
                            exp = 4102444800,
                            bk_app_code = "app",
                            bk_username = "user",
                            audience = {},
                        }

                        plugin.rewrite({}, ctx)

                        assert.stub(oauth2_cache.get_oauth2_access_token).was_called_with("lowercase-token")
                    end
                )

                it(
                    "should return 401 for non-Bearer authorization", function()
                        ctx.var.is_bk_oauth2 = true
                        authorization_header = "Basic dXNlcjpwYXNz"

                        local status = plugin.rewrite({}, ctx)

                        assert.is_equal(401, status)
                    end
                )
            end
        )

        context(
            "token mode", function()
                it(
                    "should detect token modes from sub, client_id and username", function()
                        local cases = {
                            { { bk_username = "u1", client_id = "app1", bk_login_name = "tom" }, "delegated" },
                            { { bk_username = "app1", client_id = "app1", bk_login_name = "" }, "app" },
                            { { bk_username = "app1", client_id = "app1", bk_login_name = "tom" }, "unknown" },
                            { { bk_username = "u1", client_id = "app1", bk_login_name = "" }, "unknown" },
                            { { bk_username = "u1", client_id = "", bk_login_name = "tom" }, "unknown" },
                            { { bk_username = "", client_id = "app1", bk_login_name = "" }, "unknown" },
                            { {}, "unknown" },
                        }
                        for _, case in ipairs(cases) do
                            assert.is_equal(case[2], plugin._detect_token_mode(case[1]))
                        end
                    end
                )

                it(
                    "should treat null or non-string introspection fields as unknown", function()
                        local null = require("cjson.safe").null
                        local cases = {
                            { bk_username = "app1", client_id = null, bk_login_name = "" },
                            { bk_username = null, client_id = null, bk_login_name = "" },
                            { bk_username = 123, client_id = 123, bk_login_name = "" },
                            { bk_username = "u1", client_id = { "app1" }, bk_login_name = "tom" },
                            { bk_username = "u1", client_id = "app1", bk_login_name = null },
                            { bk_username = "u1", client_id = "app1", bk_login_name = true },
                        }
                        for _, case in ipairs(cases) do
                            assert.is_equal("unknown", plugin._detect_token_mode(case))
                        end
                    end
                )

                it(
                    "should not mark a null sub as a verified user", function()
                        local user = plugin._create_user_from_result(
                            { bk_username = require("cjson.safe").null }, "unknown"
                        )

                        assert.is_false(user.verified)
                        assert.is_equal("", user.username)
                    end
                )

                it(
                    "should set the user for a delegated token", function()
                        ctx.var.is_bk_oauth2 = true
                        authorization_header = "Bearer valid-token"
                        cached_result = {
                            active = true,
                            exp = 4102444800,
                            bk_app_code = "real-app",
                            bk_username = "u-sub-1",
                            bk_login_name = "tom",
                            client_id = "real-app",
                            audience = {},
                        }

                        plugin.rewrite({}, ctx)

                        assert.is_equal("delegated", ctx.var.bk_oauth2_token_mode)
                        assert.is_true(ctx.var.bk_user.verified)
                        assert.is_equal("u-sub-1", ctx.var.bk_user.username)
                        assert.is_equal("u-sub-1", ctx.var.bk_username)
                        assert.is_equal("real-app", ctx.var.bk_app_code)
                    end
                )

                it(
                    "should not use sub as the username for an app token", function()
                        ctx.var.is_bk_oauth2 = true
                        authorization_header = "Bearer valid-token"
                        cached_result = {
                            active = true,
                            exp = 4102444800,
                            bk_app_code = "real-app",
                            bk_username = "real-app",
                            bk_login_name = "",
                            client_id = "real-app",
                            audience = {"gateway:demo/api:test"},
                        }

                        local result = plugin.rewrite({}, ctx)

                        assert.is_nil(result)
                        assert.is_equal("app", ctx.var.bk_oauth2_token_mode)
                        assert.is_false(ctx.var.bk_user.verified)
                        assert.is_equal("", ctx.var.bk_user.username)
                        assert.is_equal("", ctx.var.bk_username)
                        assert.is_true(ctx.var.bk_app.verified)
                        assert.is_equal("real-app", ctx.var.bk_app_code)
                        assert.is_nil(authorization_header)
                    end
                )

                it(
                    "should keep the previous user handling when the mode is unknown", function()
                        ctx.var.is_bk_oauth2 = true
                        authorization_header = "Bearer valid-token"
                        cached_result = {
                            active = true,
                            exp = 4102444800,
                            bk_app_code = "personal",
                            bk_username = "test-user",
                            audience = {},
                        }

                        plugin.rewrite({}, ctx)

                        assert.is_equal("unknown", ctx.var.bk_oauth2_token_mode)
                        assert.is_true(ctx.var.bk_user.verified)
                        assert.is_equal("test-user", ctx.var.bk_username)
                    end
                )
            end
        )

        context(
            "mask_token helper", function()
                it(
                    "should mask long tokens", function()
                        local masked = plugin._mask_token("abcd1234efgh5678")
                        assert.is_equal("abcd******5678", masked)
                    end
                )

                it(
                    "should return *** for short tokens", function()
                        local masked = plugin._mask_token("short")
                        assert.is_equal("***", masked)
                    end
                )

                it(
                    "should return *** for nil", function()
                        local masked = plugin._mask_token(nil)
                        assert.is_equal("***", masked)
                    end
                )
            end
        )
    end
)
