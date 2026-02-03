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
local plugin = require("apisix.plugins.bk-oauth2-audience-validate")

describe(
    "bk-oauth2-audience-validate", function()
        local ctx

        before_each(
            function()
                ctx = {
                    var = {
                        uri = "/api/test",
                        bk_gateway_name = "demo",
                        bk_resource_name = "test-api",
                    },
                }
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
            "rewrite phase - skip conditions", function()
                it(
                    "should skip when is_bk_oauth2 is false", function()
                        ctx.var.is_bk_oauth2 = false

                        local result = plugin.rewrite({}, ctx)

                        assert.is_nil(result)
                    end
                )

                it(
                    "should skip when is_bk_oauth2 is nil", function()
                        ctx.var.is_bk_oauth2 = nil

                        local result = plugin.rewrite({}, ctx)

                        assert.is_nil(result)
                    end
                )
            end
        )

        context(
            "rewrite phase - empty audience", function()
                it(
                    "should return 403 when audience is nil", function()
                        ctx.var.is_bk_oauth2 = true
                        ctx.var.audience = nil

                        local status = plugin.rewrite({}, ctx)

                        assert.is_equal(403, status)
                    end
                )

                it(
                    "should return 403 when audience is empty array", function()
                        ctx.var.is_bk_oauth2 = true
                        ctx.var.audience = {}

                        local status = plugin.rewrite({}, ctx)

                        assert.is_equal(403, status)
                    end
                )
            end
        )

        context(
            "audience parsing", function()
                it(
                    "should parse mcp_server format correctly", function()
                        local result = plugin._parse_audience("mcp_server:my-server")

                        assert.is_equal("mcp_server", result.type)
                        assert.is_equal("my-server", result.name)
                    end
                )

                it(
                    "should parse gateway_api format correctly", function()
                        local result = plugin._parse_audience("gateway:demo/api:test-api")

                        assert.is_equal("gateway_api", result.type)
                        assert.is_equal("demo", result.gateway)
                        assert.is_equal("test-api", result.api)
                    end
                )

                it(
                    "should parse gateway_api wildcard format", function()
                        local result = plugin._parse_audience("gateway:demo/api:*")

                        assert.is_equal("gateway_api", result.type)
                        assert.is_equal("demo", result.gateway)
                        assert.is_equal("*", result.api)
                    end
                )

                it(
                    "should return nil for unknown format", function()
                        local result = plugin._parse_audience("unknown:value")

                        assert.is_nil(result)
                    end
                )
            end
        )

        context(
            "MCP server path parsing", function()
                it(
                    "should extract mcp_server_name from path", function()
                        local name = plugin._extract_mcp_server_from_path("/prod/api/v2/mcp-servers/my-server/resources")

                        assert.is_equal("my-server", name)
                    end
                )

                it(
                    "should return nil for non-matching path", function()
                        local name = plugin._extract_mcp_server_from_path("/api/other/path")

                        assert.is_nil(name)
                    end
                )
            end
        )

        context(
            "MCP server validation", function()
                it(
                    "should allow access when mcp_server matches", function()
                        ctx.var.is_bk_oauth2 = true
                        ctx.var.bk_gateway_name = "bk-apigateway"
                        ctx.var.uri = "/prod/api/v2/mcp-servers/my-server/resources"
                        ctx.var.audience = {"mcp_server:my-server"}

                        local result = plugin.rewrite({}, ctx)

                        assert.is_nil(result)  -- nil means allowed
                    end
                )

                it(
                    "should deny access when mcp_server does not match", function()
                        ctx.var.is_bk_oauth2 = true
                        ctx.var.bk_gateway_name = "bk-apigateway"
                        ctx.var.uri = "/prod/api/v2/mcp-servers/other-server/resources"
                        ctx.var.audience = {"mcp_server:my-server"}

                        local status = plugin.rewrite({}, ctx)

                        assert.is_equal(403, status)
                    end
                )

                it(
                    "should deny access when gateway is not bk-apigateway", function()
                        ctx.var.is_bk_oauth2 = true
                        ctx.var.bk_gateway_name = "other-gateway"
                        ctx.var.uri = "/prod/api/v2/mcp-servers/my-server/resources"
                        ctx.var.audience = {"mcp_server:my-server"}

                        local status = plugin.rewrite({}, ctx)

                        assert.is_equal(403, status)
                    end
                )
            end
        )

        context(
            "gateway API validation", function()
                it(
                    "should allow access when gateway and api match", function()
                        ctx.var.is_bk_oauth2 = true
                        ctx.var.bk_gateway_name = "demo"
                        ctx.var.bk_resource_name = "test-api"
                        ctx.var.audience = {"gateway:demo/api:test-api"}

                        local result = plugin.rewrite({}, ctx)

                        assert.is_nil(result)  -- nil means allowed
                    end
                )

                it(
                    "should allow access with wildcard api", function()
                        ctx.var.is_bk_oauth2 = true
                        ctx.var.bk_gateway_name = "demo"
                        ctx.var.bk_resource_name = "any-api"
                        ctx.var.audience = {"gateway:demo/api:*"}

                        local result = plugin.rewrite({}, ctx)

                        assert.is_nil(result)
                    end
                )

                it(
                    "should deny access when gateway does not match", function()
                        ctx.var.is_bk_oauth2 = true
                        ctx.var.bk_gateway_name = "other-gateway"
                        ctx.var.bk_resource_name = "test-api"
                        ctx.var.audience = {"gateway:demo/api:test-api"}

                        local status = plugin.rewrite({}, ctx)

                        assert.is_equal(403, status)
                    end
                )

                it(
                    "should deny access when api does not match", function()
                        ctx.var.is_bk_oauth2 = true
                        ctx.var.bk_gateway_name = "demo"
                        ctx.var.bk_resource_name = "other-api"
                        ctx.var.audience = {"gateway:demo/api:test-api"}

                        local status = plugin.rewrite({}, ctx)

                        assert.is_equal(403, status)
                    end
                )
            end
        )

        context(
            "multiple audiences", function()
                it(
                    "should allow if any audience matches", function()
                        ctx.var.is_bk_oauth2 = true
                        ctx.var.bk_gateway_name = "demo"
                        ctx.var.bk_resource_name = "test-api"
                        ctx.var.audience = {
                            "gateway:other/api:other",
                            "gateway:demo/api:test-api",
                        }

                        local result = plugin.rewrite({}, ctx)

                        assert.is_nil(result)
                    end
                )

                it(
                    "should deny if no audience matches", function()
                        ctx.var.is_bk_oauth2 = true
                        ctx.var.bk_gateway_name = "demo"
                        ctx.var.bk_resource_name = "test-api"
                        ctx.var.audience = {
                            "gateway:other/api:other",
                            "mcp_server:my-server",
                        }

                        local status = plugin.rewrite({}, ctx)

                        assert.is_equal(403, status)
                    end
                )
            end
        )
    end
)
