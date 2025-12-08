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

local plugin = require("apisix.plugins.bk-access-token-source")
local core = require("apisix.core")

describe(
    "bk-access-token-source",
    function()
        local ctx

        before_each(
            function()
                ctx = CTX()
                -- Mock core.request.header
                core.request.header = function(ctx, header_name)
                    return ctx.headers and ctx.headers[header_name]
                end
                -- Mock core.request.set_header
                core.request.set_header = function(ctx, header_name, value)
                    if not ctx.headers then
                        ctx.headers = {}
                    end
                    ctx.headers[header_name] = value
                end
            end
        )

        context(
            "check_schema",
            function()
                it(
                    "should accept valid bearer source",
                    function()
                        local conf = { source = "bearer", allow_fallback = true }
                        local ok = plugin.check_schema(conf)
                        assert.is_true(ok)
                    end
                )

                it(
                    "should accept valid api_key source",
                    function()
                        local conf = { source = "api_key", allow_fallback = true }
                        local ok = plugin.check_schema(conf)
                        assert.is_true(ok)
                    end
                )

                it(
                    "should use default bearer source when source is nil",
                    function()
                        local conf = {}
                        local ok = plugin.check_schema(conf)
                        assert.is_true(ok)
                        assert.is_equal(conf.source, "bearer")
                        assert.is_true(conf.allow_fallback)
                    end
                )

                it(
                    "should reject invalid source",
                    function()
                        local conf = { source = "invalid" }
                        local ok = plugin.check_schema(conf)
                        assert.is_false(ok)
                    end
                )

                it(
                    "should reject non-string source",
                    function()
                        local conf = { source = 123 }
                        local ok = plugin.check_schema(conf)
                        assert.is_false(ok)
                    end
                )

                it(
                    "should reject invalid allow_fallback",
                    function()
                        local conf = { source = "bearer", allow_fallback = "invalid" }
                        local ok = plugin.check_schema(conf)
                        assert.is_false(ok)
                    end
                )
            end
        )

        context(
            "get_bearer_token",
            function()
                it(
                    "should extract bearer token with uppercase Bearer",
                    function()
                        ctx.headers = { Authorization = "Bearer test-token-123" }
                        local token, err = plugin._get_bearer_token(ctx)
                        assert.is_equal(token, "test-token-123")
                        assert.is_nil(err)
                    end
                )

                it(
                    "should extract bearer token with lowercase bearer",
                    function()
                        ctx.headers = { Authorization = "bearer test-token-456" }
                        local token, err = plugin._get_bearer_token(ctx)
                        assert.is_equal(token, "test-token-456")
                        assert.is_nil(err)
                    end
                )

                it(
                    "should return error when Authorization header is missing",
                    function()
                        ctx.headers = {}
                        local token, err = plugin._get_bearer_token(ctx)
                        assert.is_nil(token)
                        assert.is_equal(err, "No `Authorization` header found in the request")
                    end
                )

                it(
                    "should return error when Authorization header is nil",
                    function()
                        ctx.headers = nil
                        local token, err = plugin._get_bearer_token(ctx)
                        assert.is_nil(token)
                        assert.is_equal(err, "No `Authorization` header found in the request")
                    end
                )

                it(
                    "should return error when Authorization header is not bearer token",
                    function()
                        ctx.headers = { Authorization = "Basic dGVzdDp0ZXN0" }
                        local token, err = plugin._get_bearer_token(ctx)
                        assert.is_nil(token)
                        assert.is_equal(err, "The `Authorization` header is not a bearer token")
                    end
                )

                it(
                    "should return error when Authorization header is too short",
                    function()
                        ctx.headers = { Authorization = "Bea" }
                        local token, err = plugin._get_bearer_token(ctx)
                        assert.is_nil(token)
                        assert.is_equal(err, "The `Authorization` header is not a bearer token")
                    end
                )

                it(
                    "should handle empty token after Bearer prefix",
                    function()
                        ctx.headers = { Authorization = "Bearer " }
                        local token, err = plugin._get_bearer_token(ctx)
                        assert.is_equal(token, "")
                        assert.is_nil(err)
                    end
                )
            end
        )

        context(
            "rewrite with bearer source",
            function()
                it(
                    "should handle bearer token successfully",
                    function()
                        local conf = { source = "bearer", allow_fallback = false }
                        ctx.headers = { Authorization = "Bearer test-token-123" }

                        plugin.rewrite(conf, ctx)

                        assert.is_equal(ctx.headers["X-Bkapi-Authorization"], '{"access_token":"test-token-123"}')
                        assert.is_nil(ctx.var.bk_apigw_error)
                        assert.is_nil(ctx.headers["Authorization"])
                    end
                )

                it(
                    "should return error when bearer token is missing",
                    function()
                        local conf = { source = "bearer", allow_fallback = false }
                        ctx.headers = {}

                        local status = plugin.rewrite(conf, ctx)

                        assert.is_not_nil(ctx.var.bk_apigw_error)
                        assert.is_equal(status, 400)
                    end
                )

                it(
                    "should return error when bearer token format is invalid",
                    function()
                        local conf = { source = "bearer", allow_fallback = false }
                        ctx.headers = { Authorization = "Basic dGVzdDp0ZXN0" }

                        local status = plugin.rewrite(conf, ctx)

                        assert.is_not_nil(ctx.var.bk_apigw_error)
                        assert.is_equal(status, 400)
                    end
                )
            end
        )

        context(
            "rewrite with api_key source",
            function()
                it(
                    "should handle X-API-KEY token successfully",
                    function()
                        local conf = { source = "api_key", allow_fallback = false }
                        ctx.headers = { ["X-API-KEY"] = "api-key-token-123" }

                        plugin.rewrite(conf, ctx)

                        assert.is_equal(ctx.headers["X-Bkapi-Authorization"], '{"access_token":"api-key-token-123"}')
                        assert.is_nil(ctx.var.bk_apigw_error)
                        assert.is_nil(ctx.headers["X-API-KEY"])
                    end
                )

                it(
                    "should return error when X-API-KEY header is missing",
                    function()
                        local conf = { source = "api_key", allow_fallback = false }
                        ctx.headers = {}

                        local status = plugin.rewrite(conf, ctx)

                        assert.is_not_nil(ctx.var.bk_apigw_error)
                        assert.is_equal(status, 400)
                    end
                )

                it(
                    "should return error when X-API-KEY header is empty",
                    function()
                        local conf = { source = "api_key", allow_fallback = false }
                        ctx.headers = { ["X-API-KEY"] = "" }

                        local status = plugin.rewrite(conf, ctx)

                        assert.is_not_nil(ctx.var.bk_apigw_error)
                        assert.is_equal(status, 400)
                    end
                )
            end
        )

        context(
            "rewrite with default source (bearer)",
            function()
                it(
                    "should use bearer source when source is not specified",
                    function()
                        local conf = { allow_fallback = false }
                        ctx.headers = { Authorization = "Bearer default-token-123" }

                        plugin.check_schema(conf)
                        plugin.rewrite(conf, ctx)

                        assert.is_nil(ctx.var.bk_apigw_error)
                        assert.is_equal(ctx.headers["X-Bkapi-Authorization"], '{"access_token":"default-token-123"}')
                    end
                )
            end
        )

        context(
            "plugin metadata",
            function()
                it(
                    "should have correct plugin metadata",
                    function()
                        assert.is_equal(plugin.name, "bk-access-token-source")
                        assert.is_equal(plugin.version, 0.1)
                        assert.is_equal(plugin.priority, 18735)
                        assert.is_not_nil(plugin.schema)
                    end
                )
            end
        )
    end
)
