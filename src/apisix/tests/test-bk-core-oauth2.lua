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

                stub(
                    bk_core.config, "should_strip_subpath_prefix", function()
                        return false
                    end
                )
            end
        )

        after_each(
            function()
                bk_core.config.get_bk_apigateway_api_tmpl:revert()
                bk_core.config.should_strip_subpath_prefix:revert()
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
            "strip_subpath_prefix", function()
                it(
                    "should strip /api/{gateway_name} prefix from path", function()
                        local result = oauth2._strip_subpath_prefix("/api/demo/prod/api/v2/users", "demo")
                        assert.is_equal("/prod/api/v2/users", result)
                    end
                )

                it(
                    "should return / when path equals the prefix exactly", function()
                        local result = oauth2._strip_subpath_prefix("/api/demo", "demo")
                        assert.is_equal("/", result)
                    end
                )

                it(
                    "should not strip when path does not start with prefix", function()
                        local result = oauth2._strip_subpath_prefix("/prod/api/v2/users", "demo")
                        assert.is_equal("/prod/api/v2/users", result)
                    end
                )

                it(
                    "should not strip partial gateway name match", function()
                        local result = oauth2._strip_subpath_prefix("/api/demo-extra/prod", "demo")
                        assert.is_equal("/api/demo-extra/prod", result)
                    end
                )

                it(
                    "should handle path with only slash after prefix", function()
                        local result = oauth2._strip_subpath_prefix("/api/demo/", "demo")
                        assert.is_equal("/", result)
                    end
                )

                it(
                    "should handle gateway name with hyphens", function()
                        local result = oauth2._strip_subpath_prefix(
                            "/api/bk-apigateway/prod/api/v2/mcp-servers", "bk-apigateway"
                        )
                        assert.is_equal("/prod/api/v2/mcp-servers", result)
                    end
                )

                it(
                    "should return path unchanged when prefix is for different gateway", function()
                        local result = oauth2._strip_subpath_prefix("/api/other-gw/prod", "demo")
                        assert.is_equal("/api/other-gw/prod", result)
                    end
                )
            end
        )

        context(
            "build_www_authenticate_header - tmpl validation", function()
                it(
                    "should return a realm-only challenge when tmpl is nil", function()
                        bk_core.config.get_bk_apigateway_api_tmpl:revert()
                        stub(
                            bk_core.config, "get_bk_apigateway_api_tmpl", function()
                                return nil
                            end
                        )

                        local header = oauth2.build_www_authenticate_header(ctx)

                        assert.is_equal(
                            'Bearer realm="bk-apigateway"',
                            header
                        )
                    end
                )

                it(
                    "should return a realm-only challenge when tmpl is empty", function()
                        bk_core.config.get_bk_apigateway_api_tmpl:revert()
                        stub(
                            bk_core.config, "get_bk_apigateway_api_tmpl", function()
                                return ""
                            end
                        )

                        local header = oauth2.build_www_authenticate_header(ctx)

                        assert.is_equal(
                            'Bearer realm="bk-apigateway"',
                            header
                        )
                    end
                )

                it(
                    "should return a realm-only challenge for invalid tmpl format", function()
                        bk_core.config.get_bk_apigateway_api_tmpl:revert()
                        stub(
                            bk_core.config, "get_bk_apigateway_api_tmpl", function()
                                return "not-a-valid-url"
                            end
                        )

                        local header = oauth2.build_www_authenticate_header(ctx)

                        assert.is_equal(
                            'Bearer realm="bk-apigateway"',
                            header
                        )
                    end
                )

                it(
                    "should keep the caller's error when the tmpl has no host", function()
                        bk_core.config.get_bk_apigateway_api_tmpl:revert()
                        stub(
                            bk_core.config, "get_bk_apigateway_api_tmpl", function()
                                return "https://"
                            end
                        )

                        local header = oauth2.build_www_authenticate_header(ctx, "invalid_token", "token expired")

                        assert.is_equal(
                            'Bearer realm="bk-apigateway", error="invalid_token", error_description="token expired"',
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

        context(
            "build_www_authenticate_header - subpath prefix stripping", function()
                it(
                    "should strip /api/{gateway_name} from path when enabled", function()
                        bk_core.config.should_strip_subpath_prefix:revert()
                        stub(
                            bk_core.config, "should_strip_subpath_prefix", function()
                                return true
                            end
                        )
                        bk_core.config.get_bk_apigateway_api_tmpl:revert()
                        stub(
                            bk_core.config, "get_bk_apigateway_api_tmpl", function()
                                return "http://{api_name}.bkapi.example.com"
                            end
                        )
                        ctx.var.bk_gateway_name = "bk-apigateway"
                        ctx.var.uri = "/api/bk-apigateway/prod/api/v2/mcp-servers"

                        local header = oauth2.build_www_authenticate_header(ctx)

                        -- The resource URL should NOT contain /api/bk-apigateway prefix
                        assert.is_truthy(
                            string.find(
                                header,
                                "bk-apigateway.bkapi.example.com%2Fprod%2Fapi%2Fv2%2Fmcp-servers",
                                1, true
                            )
                        )
                    end
                )

                it(
                    "should not strip when config is disabled", function()
                        ctx.var.bk_gateway_name = "demo"
                        ctx.var.uri = "/api/demo/prod/api/v2/users"

                        local header = oauth2.build_www_authenticate_header(ctx)

                        -- The resource URL should still contain /api/demo
                        assert.is_truthy(
                            string.find(
                                header,
                                "%2Fapi%2Fdemo%2Fprod%2Fapi%2Fv2%2Fusers",
                                1, true
                            )
                        )
                    end
                )

                it(
                    "should not strip when path does not match gateway prefix", function()
                        bk_core.config.should_strip_subpath_prefix:revert()
                        stub(
                            bk_core.config, "should_strip_subpath_prefix", function()
                                return true
                            end
                        )
                        ctx.var.bk_gateway_name = "demo"
                        ctx.var.uri = "/other/path/prod"

                        local header = oauth2.build_www_authenticate_header(ctx)

                        -- Path should remain unchanged
                        assert.is_truthy(
                            string.find(
                                header,
                                "%2Fother%2Fpath%2Fprod",
                                1, true
                            )
                        )
                    end
                )
            end
        )

        context(
            "is_real_app_code", function()
                it(
                    "should accept real app codes", function()
                        assert.is_true(oauth2.is_real_app_code("my-app"))
                    end
                )

                it(
                    "should reject builtin clients and empty values", function()
                        assert.is_false(oauth2.is_real_app_code("public"))
                        assert.is_false(oauth2.is_real_app_code("personal"))
                        assert.is_false(oauth2.is_real_app_code(""))
                        assert.is_false(oauth2.is_real_app_code(nil))
                    end
                )
            end
        )

        context(
            "classify_bearer_token", function()
                local rules
                local valid_bk_token = "bkp_" .. string.rep("a1B2", 9)

                before_each(
                    function()
                        rules = {
                            { prefix_pattern = "^bk[oprs]_", format_pattern = "^bk[oprs]_[0-9A-Za-z]{36}$" },
                            { prefix_pattern = "^tai_pat_" },
                        }
                        stub(
                            bk_core.config, "get_oauth2_bearer_token_rules", function()
                                return rules
                            end
                        )
                    end
                )

                after_each(
                    function()
                        bk_core.config.get_oauth2_bearer_token_rules:revert()
                    end
                )

                it(
                    "should return nil when rules are not configured", function()
                        rules = nil
                        assert.is_nil(oauth2.classify_bearer_token("anything"))
                    end
                )

                it(
                    "should treat non-list rules as not configured", function()
                        for _, value in ipairs({ true, false, "^bkp_", 1, { a = 1 } }) do
                            rules = value
                            assert.is_nil(oauth2.classify_bearer_token("anything"))
                            assert.is_false(oauth2.has_bkauth_bearer_token_rules())
                        end
                    end
                )

                it(
                    "should treat a non-string format_pattern as no format check", function()
                        rules = { { prefix_pattern = "^bkp_", format_pattern = 1 } }
                        assert.is_equal("bkauth", oauth2.classify_bearer_token("bkp_short"))
                    end
                )

                it(
                    "should match prefix and full format", function()
                        for _, prefix in ipairs({ "bko_", "bkp_", "bkr_", "bks_" }) do
                            assert.is_equal("bkauth", oauth2.classify_bearer_token(prefix .. string.rep("a1B2", 9)))
                        end
                    end
                )

                it(
                    "should report bad format when prefix matches but format does not", function()
                        for _, token in ipairs({
                            "bkp_short",
                            valid_bk_token .. "x",
                            "bkp_" .. string.rep("a1B2", 8) .. "a1-2",
                        }) do
                            assert.is_equal("malformed", oauth2.classify_bearer_token(token))
                        end
                    end
                )

                it(
                    "should accept any suffix when format_pattern is absent", function()
                        assert.is_equal("bkauth", oauth2.classify_bearer_token("tai_pat_any.thing-123"))
                    end
                )

                it(
                    "should not match similar but different prefixes", function()
                        local tokens = { "bkx_" .. string.rep("a1B2", 9), "bk_abc", "tai_abc", "xbkp_abc" }
                        for _, token in ipairs(tokens) do
                            assert.is_equal("other", oauth2.classify_bearer_token(token))
                        end
                    end
                )

                it(
                    "should skip invalid rules", function()
                        rules = { "invalid", { format_pattern = "^bkp_" }, { prefix_pattern = "^tai_pat_" } }
                        assert.is_equal("other", oauth2.classify_bearer_token("bkp_abc"))
                        assert.is_equal("bkauth", oauth2.classify_bearer_token("tai_pat_abc"))
                    end
                )

                it(
                    "should treat an invalid prefix pattern as not matched", function()
                        rules = { { prefix_pattern = "^bk[" } }
                        assert.is_equal("other", oauth2.classify_bearer_token("bkp_abc"))
                    end
                )

                it(
                    "should log an invalid prefix pattern and continue with the next rule", function()
                        stub(core.log, "error")
                        rules = { { prefix_pattern = "^bk[" }, { prefix_pattern = "^bkp_" } }

                        assert.is_equal("bkauth", oauth2.classify_bearer_token("bkp_abc"))
                        assert.stub(core.log.error).was_called()
                        core.log.error:revert()
                    end
                )

                it(
                    "should reject the token when the format pattern is invalid", function()
                        stub(core.log, "error")
                        rules = { { prefix_pattern = "^bkp_", format_pattern = "^bkp_[0-9a-z{36}$" } }

                        -- the prefix decides it is a bkauth token; an invalid format fails closed (401)
                        assert.is_equal("malformed", oauth2.classify_bearer_token(valid_bk_token))
                        assert.stub(core.log.error).was_called()
                        core.log.error:revert()
                    end
                )

                it(
                    "should report no problem for valid or missing rules", function()
                        assert.are.same({}, oauth2.validate_bkauth_bearer_token_rules())
                        rules = nil
                        assert.are.same({}, oauth2.validate_bkauth_bearer_token_rules())
                    end
                )

                it(
                    "should report invalid rules without changing matching", function()
                        rules = {
                            "invalid",
                            { format_pattern = "^bkp_" },
                            { prefix_pattern = "^bk[" },
                            { prefix_pattern = "^bkp_", format_pattern = "^bkp_[0-9a-z{36}$" },
                            { prefix_pattern = "^tai_pat_", format_pattern = 1 },
                        }

                        local problems = oauth2.validate_bkauth_bearer_token_rules()

                        assert.is_equal(5, #problems)
                        assert.matches("bearer_token_rules%[1%] must be an object", problems[1])
                        assert.matches("bearer_token_rules%[2%]%.prefix_pattern must be a string", problems[2])
                        assert.matches("bearer_token_rules%[3%]%.prefix_pattern=%^bk%[ is invalid", problems[3])
                        assert.matches("bearer_token_rules%[4%]%.format_pattern=.* is invalid", problems[4])
                        assert.matches("bearer_token_rules%[5%]%.format_pattern must be a string", problems[5])

                        for _, value in ipairs({ 1, false, "x", { a = 1 } }) do
                            rules = value
                            assert.are.same(
                                { "bearer_token_rules must be a list, treated as not configured" },
                                oauth2.validate_bkauth_bearer_token_rules()
                            )
                        end
                    end
                )

                it(
                    "should report whether the rules are configured", function()
                        assert.is_true(oauth2.has_bkauth_bearer_token_rules())
                        rules = {}
                        assert.is_true(oauth2.has_bkauth_bearer_token_rules())
                        rules = nil
                        assert.is_false(oauth2.has_bkauth_bearer_token_rules())
                    end
                )
            end
        )
    end
)
