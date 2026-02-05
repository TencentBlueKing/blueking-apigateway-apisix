--
-- TencentBlueKing is pleased to support the open source community by making
-- 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
-- Copyright (C) 2025 Tencent. All rights reserved.
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
                    var = {},
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
                    core.response, "set_header", function(...)
                        local args = {...}
                        local name = args[1]
                        local value = args[2]
                        if name == "WWW-Authenticate" then
                            www_authenticate_header = value
                        end
                    end
                )

                stub(
                    oauth2_cache, "get_oauth2_access_token", function(token)
                        if cached_result then
                            return cached_result, nil
                        end
                        return nil, "token verification failed"
                    end
                )
            end
        )

        after_each(
            function()
                core.request.header:revert()
                core.response.set_header:revert()
                oauth2_cache.get_oauth2_access_token:revert()
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

                        local result = plugin.rewrite({}, ctx)

                        assert.is_nil(result)
                        assert.is_nil(ctx.var.bk_app)
                    end
                )

                it(
                    "should skip when is_bk_oauth2 is nil", function()
                        ctx.var.is_bk_oauth2 = nil

                        local result = plugin.rewrite({}, ctx)

                        assert.is_nil(result)
                        assert.is_nil(ctx.var.bk_app)
                    end
                )

                it(
                    "should process when is_bk_oauth2 is true", function()
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
                    "should return 401 when token verification fails", function()
                        ctx.var.is_bk_oauth2 = true
                        authorization_header = "Bearer invalid-token"
                        cached_result = nil  -- Verification fails

                        local status = plugin.rewrite({}, ctx)

                        assert.is_equal(401, status)
                        assert.is_truthy(www_authenticate_header)
                        assert.is_true(
                            string.find(www_authenticate_header, 'error="invalid_token"') ~= nil
                        )
                        assert.is_true(
                            string.find(www_authenticate_header, 'error_description="call bkauth api to verify token failed') ~= nil
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
                                'error_description="Bearer token not found in Authorization header"'
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
