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
local bk_core = require("apisix.plugins.bk-core.init")
local oauth2 = require("apisix.plugins.bk-core.oauth2")

describe(
    "bk-core.oauth2", function()
        local ctx

        before_each(
            function()
                ctx = {
                    var = {
                        bk_gateway_name = "demo",
                        uri = "/api/v1/users",
                    },
                }

                stub(
                    bk_core.config, "get_bk_apigateway_api_tmpl", function()
                        return "http://bkapi.example.com/api/{api_name}"
                    end
                )
            end
        )

        after_each(
            function()
                bk_core.config.get_bk_apigateway_api_tmpl:revert()
            end
        )

        context(
            "escape_auth_header_value", function()
                it(
                    "should return empty string for nil", function()
                        local result = oauth2._escape_auth_header_value(nil)
                        assert.is_equal("", result)
                    end
                )

                it(
                    "should return empty string for empty input", function()
                        local result = oauth2._escape_auth_header_value("")
                        assert.is_equal("", result)
                    end
                )

                it(
                    "should return value as-is when no special characters", function()
                        local result = oauth2._escape_auth_header_value("hello world")
                        assert.is_equal("hello world", result)
                    end
                )

                it(
                    "should escape double quotes", function()
                        local result = oauth2._escape_auth_header_value('say "hello"')
                        assert.is_equal('say \\"hello\\"', result)
                    end
                )

                it(
                    "should escape backslashes", function()
                        local result = oauth2._escape_auth_header_value("path\\to\\file")
                        assert.is_equal("path\\\\to\\\\file", result)
                    end
                )

                it(
                    "should escape both backslashes and double quotes", function()
                        local result = oauth2._escape_auth_header_value('a\\"b')
                        assert.is_equal('a\\\\\\"b', result)
                    end
                )
            end
        )

        context(
            "build_www_authenticate_header - tmpl validation", function()
                it(
                    "should return realm error when tmpl is nil", function()
                        bk_core.config.get_bk_apigateway_api_tmpl:revert()
                        stub(
                            bk_core.config, "get_bk_apigateway_api_tmpl", function()
                                return nil
                            end
                        )

                        local header = oauth2.build_www_authenticate_header(ctx)

                        assert.is_equal(
                            'Bearer realm="bk-apigateway", error="invalid_request",'
                                .. ' error_description="api tmpl is not configured"',
                            header
                        )
                    end
                )

                it(
                    "should return realm error when tmpl is empty", function()
                        bk_core.config.get_bk_apigateway_api_tmpl:revert()
                        stub(
                            bk_core.config, "get_bk_apigateway_api_tmpl", function()
                                return ""
                            end
                        )

                        local header = oauth2.build_www_authenticate_header(ctx)

                        assert.is_equal(
                            'Bearer realm="bk-apigateway", error="invalid_request",'
                                .. ' error_description="api tmpl is not configured"',
                            header
                        )
                    end
                )

                it(
                    "should return realm error for invalid tmpl format", function()
                        bk_core.config.get_bk_apigateway_api_tmpl:revert()
                        stub(
                            bk_core.config, "get_bk_apigateway_api_tmpl", function()
                                return "not-a-valid-url"
                            end
                        )

                        local header = oauth2.build_www_authenticate_header(ctx)

                        assert.is_equal(
                            'Bearer realm="bk-apigateway", error="invalid_request",'
                                .. ' error_description="invalid api tmpl format"',
                            header
                        )
                    end
                )
            end
        )

        context(
            "build_www_authenticate_header - without error params", function()
                it(
                    "should handle subpath template format", function()
                        local header = oauth2.build_www_authenticate_header(ctx)

                        assert.is_not_nil(header)
                        assert.is_truthy(
                            string.find(
                                header,
                                'Bearer resource_metadata="http://bkapi.example.com/api/bk-apigateway/prod/',
                                1, true
                            )
                        )
                        -- Should NOT contain error= fields
                        assert.is_nil(string.find(header, 'error=', 1, true))
                    end
                )

                it(
                    "should handle subdomain template format", function()
                        bk_core.config.get_bk_apigateway_api_tmpl:revert()
                        stub(
                            bk_core.config, "get_bk_apigateway_api_tmpl", function()
                                return "http://{api_name}.bkapi.example.com"
                            end
                        )

                        local header = oauth2.build_www_authenticate_header(ctx)

                        assert.is_not_nil(header)
                        assert.is_truthy(
                            string.find(
                                header,
                                'resource_metadata="http://bk-apigateway.bkapi.example.com/prod/',
                                1, true
                            )
                        )
                    end
                )

                it(
                    "should use gateway_name in resource URL for subdomain template", function()
                        bk_core.config.get_bk_apigateway_api_tmpl:revert()
                        stub(
                            bk_core.config, "get_bk_apigateway_api_tmpl", function()
                                return "http://{api_name}.bkapi.example.com"
                            end
                        )
                        ctx.var.bk_gateway_name = "my-gateway"

                        local header = oauth2.build_www_authenticate_header(ctx)

                        -- The resource URL origin should contain the gateway name
                        assert.is_truthy(
                            string.find(header, "my-gateway.bkapi.example.com", 1, true)
                        )
                    end
                )

                it(
                    "should URL-encode the resource path", function()
                        ctx.var.uri = "/api/v1/users?query=test&page=1"

                        local header = oauth2.build_www_authenticate_header(ctx)

                        -- The resource URL should be URL encoded
                        local expected = "resource=http%3A%2F%2Fbkapi.example.com%2Fapi%2Fv1%2Fusers"
                        assert.is_truthy(string.find(header, expected, 1, true))
                    end
                )
            end
        )

        context(
            "build_www_authenticate_header - with error params", function()
                it(
                    "should include error and error_description", function()
                        local header = oauth2.build_www_authenticate_header(
                            ctx, "invalid_token", "token has expired"
                        )

                        assert.is_truthy(
                            string.find(header, 'error="invalid_token"', 1, true)
                        )
                        assert.is_truthy(
                            string.find(header, 'error_description="token has expired"', 1, true)
                        )
                        -- Should also include resource_metadata
                        assert.is_truthy(
                            string.find(header, "resource_metadata=", 1, true)
                        )
                    end
                )

                it(
                    "should escape special characters in error_code", function()
                        local header = oauth2.build_www_authenticate_header(
                            ctx, 'invalid"token', "some error"
                        )

                        assert.is_truthy(
                            string.find(header, 'error="invalid\\"token"', 1, true)
                        )
                    end
                )

                it(
                    "should escape special characters in error_description", function()
                        local header = oauth2.build_www_authenticate_header(
                            ctx, "invalid_token", 'token "abc\\def" expired'
                        )

                        assert.is_truthy(
                            string.find(header, 'error_description="token \\"abc\\\\def\\" expired"', 1, true)
                        )
                    end
                )

                it(
                    "should not include error fields when only error_code is provided", function()
                        local header = oauth2.build_www_authenticate_header(ctx, "invalid_token", nil)

                        -- Should fall back to no-error path
                        assert.is_nil(string.find(header, 'error=', 1, true))
                    end
                )

                it(
                    "should not include error fields when only error_description is provided", function()
                        local header = oauth2.build_www_authenticate_header(ctx, nil, "some description")

                        -- Should fall back to no-error path
                        assert.is_nil(string.find(header, 'error=', 1, true))
                    end
                )
            end
        )

        context(
            "build_www_authenticate_header - defensive nil handling", function()
                it(
                    "should handle nil ctx gracefully", function()
                        local header = oauth2.build_www_authenticate_header(nil)

                        assert.is_not_nil(header)
                        -- Should use "unknown" as gateway name and "/" as path
                        assert.is_truthy(
                            string.find(header, "resource_metadata=", 1, true)
                        )
                    end
                )

                it(
                    "should handle nil ctx.var gracefully", function()
                        local header = oauth2.build_www_authenticate_header({ var = nil })

                        assert.is_not_nil(header)
                        assert.is_truthy(
                            string.find(header, "resource_metadata=", 1, true)
                        )
                    end
                )

                it(
                    "should default gateway_name to unknown when missing", function()
                        bk_core.config.get_bk_apigateway_api_tmpl:revert()
                        stub(
                            bk_core.config, "get_bk_apigateway_api_tmpl", function()
                                return "http://{api_name}.bkapi.example.com"
                            end
                        )
                        ctx.var.bk_gateway_name = nil

                        local header = oauth2.build_www_authenticate_header(ctx)

                        assert.is_not_nil(header)
                        -- Should use "unknown" as the gateway name in subdomain
                        assert.is_truthy(
                            string.find(header, "unknown.bkapi.example.com", 1, true)
                        )
                    end
                )

                it(
                    "should default uri to / when missing", function()
                        ctx.var.uri = nil

                        local header = oauth2.build_www_authenticate_header(ctx)

                        assert.is_not_nil(header)
                        -- The resource URL should end with just the origin + "/"
                        assert.is_truthy(
                            string.find(header, "resource_metadata=", 1, true)
                        )
                    end
                )
            end
        )
    end
)
