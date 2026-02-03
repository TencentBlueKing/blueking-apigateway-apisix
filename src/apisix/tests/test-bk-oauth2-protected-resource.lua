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
local bk_core = require("apisix.plugins.bk-core.init")
local plugin = require("apisix.plugins.bk-oauth2-protected-resource")

describe(
    "bk-oauth2-protected-resource", function()
        local ctx
        local headers

        before_each(
            function()
                ctx = {
                    var = {
                        uri = "/api/test/resource",
                    },
                }
                headers = {}

                stub(
                    core.request, "header", function(_, name)
                        return headers[name]
                    end
                )
                stub(
                    bk_core.config, "get_bkauth_origin", function()
                        return "https://bkauth.example.com"
                    end
                )
            end
        )

        after_each(
            function()
                core.request.header:revert()
                bk_core.config.get_bkauth_origin:revert()
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
                    "should set is_bk_oauth2=false when X-Bkapi-Authorization header is present", function()
                        headers["X-Bkapi-Authorization"] = '{"bk_app_code": "test"}'

                        local result = plugin.rewrite({}, ctx)

                        assert.is_nil(result)
                        assert.is_false(ctx.var.is_bk_oauth2)
                    end
                )

                it(
                    "should prioritize X-Bkapi-Authorization over Authorization Bearer", function()
                        headers["X-Bkapi-Authorization"] = '{"bk_app_code": "test"}'
                        headers["Authorization"] = "Bearer test-token"

                        local result = plugin.rewrite({}, ctx)

                        assert.is_nil(result)
                        assert.is_false(ctx.var.is_bk_oauth2)
                    end
                )

                it(
                    "should set is_bk_oauth2=true when Authorization Bearer header is present", function()
                        headers["Authorization"] = "Bearer test-token-12345"

                        local result = plugin.rewrite({}, ctx)

                        assert.is_nil(result)
                        assert.is_true(ctx.var.is_bk_oauth2)
                    end
                )

                it(
                    "should extract bearer token correctly", function()
                        headers["Authorization"] = "Bearer my-access-token"

                        plugin.rewrite({}, ctx)

                        assert.is_true(ctx.var.is_bk_oauth2)
                        assert.is_equal("my-access-token", ctx.var.oauth2_access_token)
                    end
                )

                it(
                    "should handle Bearer with extra spaces", function()
                        headers["Authorization"] = "Bearer   token-with-spaces"

                        plugin.rewrite({}, ctx)

                        assert.is_true(ctx.var.is_bk_oauth2)
                    end
                )

                it(
                    "should return 401 when no auth headers are present", function()
                        -- No headers set

                        local status = plugin.rewrite({}, ctx)

                        assert.is_equal(401, status)
                    end
                )

                it(
                    "should not set is_bk_oauth2 when Authorization is not Bearer type", function()
                        headers["Authorization"] = "Basic dXNlcjpwYXNz"

                        local status = plugin.rewrite({}, ctx)

                        -- Should return 401 as it's not a valid OAuth2 or legacy auth
                        assert.is_equal(401, status)
                    end
                )
            end
        )

        context(
            "WWW-Authenticate header", function()
                it(
                    "should include resource_metadata URL", function()
                        ctx.var.uri = "/api/v1/users"

                        -- The actual header setting is tested in functional tests
                        -- Here we just verify the plugin returns 401
                        local status = plugin.rewrite({}, ctx)

                        assert.is_equal(401, status)
                    end
                )
            end
        )

        context(
            "helper functions", function()
                it(
                    "should parse Bearer token correctly", function()
                        local token = plugin._parse_bearer_token("Bearer abc123")
                        assert.is_equal("abc123", token)
                    end
                )

                it(
                    "should return nil for non-Bearer auth", function()
                        local token = plugin._parse_bearer_token("Basic abc123")
                        assert.is_nil(token)
                    end
                )

                it(
                    "should return nil for empty string", function()
                        local token = plugin._parse_bearer_token("")
                        assert.is_nil(token)
                    end
                )

                it(
                    "should return nil for nil input", function()
                        local token = plugin._parse_bearer_token(nil)
                        assert.is_nil(token)
                    end
                )
            end
        )
    end
)
