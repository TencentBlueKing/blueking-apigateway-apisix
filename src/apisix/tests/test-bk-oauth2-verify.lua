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

        before_each(
            function()
                ctx = {
                    var = {},
                }
                cached_result = nil

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
                        ctx.var.oauth2_access_token = "valid-token"
                        cached_result = {
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
                        ctx.var.oauth2_access_token = "valid-token"
                        cached_result = {
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
                        ctx.var.oauth2_access_token = "invalid-token"
                        cached_result = nil  -- Verification fails

                        local status = plugin.rewrite({}, ctx)

                        assert.is_equal(401, status)
                    end
                )

                it(
                    "should return 401 when no token is present", function()
                        ctx.var.is_bk_oauth2 = true
                        ctx.var.oauth2_access_token = nil

                        local status = plugin.rewrite({}, ctx)

                        assert.is_equal(401, status)
                    end
                )
            end
        )

        context(
            "token extraction", function()
                it(
                    "should use oauth2_access_token from context", function()
                        ctx.var.is_bk_oauth2 = true
                        ctx.var.oauth2_access_token = "my-token-123"
                        cached_result = {
                            bk_app_code = "app",
                            bk_username = "user",
                            audience = {},
                        }

                        plugin.rewrite({}, ctx)

                        assert.stub(oauth2_cache.get_oauth2_access_token).was_called_with("my-token-123")
                    end
                )
            end
        )
    end
)
