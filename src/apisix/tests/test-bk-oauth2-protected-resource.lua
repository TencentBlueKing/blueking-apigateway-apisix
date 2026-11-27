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
local api_auth = require("apisix.plugins.bk-define.context-api-bkauth")
local resource_auth = require("apisix.plugins.bk-define.context-resource-bkauth")
local plugin = require("apisix.plugins.bk-oauth2-protected-resource")

-- matches the bearer_token_rules in tests/conf/config.yaml
local BKAUTH_TOKEN = "bkp_" .. string.rep("a1B2", 9)
local MISSING_HEADER_REASON = "no valid authentication header found"
local NON_BKAUTH_BEARER_REASON = "the Bearer token is not a BlueKing OAuth2 token"

describe(
    "bk-oauth2-protected-resource", function()
        local ctx
        local headers

        before_each(
            function()
                plugin.init()
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
                    bk_core.config, "get_bk_apigateway_api_tmpl", function()
                        return "https://bk-apigateway-api.example.com"
                    end
                )
            end
        )

        after_each(
            function()
                core.request.header:revert()
                bk_core.config.get_bk_apigateway_api_tmpl:revert()
            end
        )

        context(
            "check_schema", function()
                it(
                    "should accept empty config", function()
                        local conf = {}
                        local ok, err = plugin.check_schema(conf)
                        assert.is_true(ok)
                        assert.is_nil(err)
                        assert.is_true(conf.challenge_on_missing_credential)
                    end
                )

                it(
                    "should accept challenge_on_missing_credential", function()
                        local conf = { challenge_on_missing_credential = false }
                        local ok = plugin.check_schema(conf)
                        assert.is_true(ok)
                        assert.is_false(conf.challenge_on_missing_credential)
                    end
                )

                it(
                    "should reject non-boolean challenge_on_missing_credential", function()
                        local ok = plugin.check_schema({ challenge_on_missing_credential = "false" })
                        assert.is_false(ok)
                    end
                )
            end
        )

        context(
            "init", function()
                local rules
                local logged_rules

                before_each(
                    function()
                        stub(bk_core.config, "get_oauth2_bearer_token_rules", function() return rules end)
                        stub(core.log, "error")
                        stub(core.log, "warn", function(_, _, _, _, encoded_rules)
                            logged_rules = tostring(encoded_rules)
                        end)
                    end
                )

                after_each(
                    function()
                        bk_core.config.get_oauth2_bearer_token_rules:revert()
                        core.log.error:revert()
                        core.log.warn:revert()
                    end
                )

                it(
                    "should log the effective rules once after skipping invalid entries", function()
                        rules = { { prefix_pattern = "^bk[" }, { prefix_pattern = "^tai_pat_" } }
                        plugin.init()
                        assert.stub(core.log.error).was_called(1)
                        assert.stub(core.log.warn).was_called(1)
                        assert.same({ { prefix_pattern = "^tai_pat_" } }, core.json.decode(logged_rules))
                    end
                )

                it(
                    "should log a non-list configuration and match no prefixes", function()
                        rules = true
                        plugin.init()
                        assert.stub(core.log.error).was_called(1)
                        assert.stub(core.log.warn).was_called(1)
                        assert.same({}, core.json.decode(logged_rules))

                        headers["Authorization"] = "Bearer bkp_short"
                        assert.is_equal(401, plugin.rewrite({}, ctx))
                        assert.matches('^Bearer resource_metadata="[^"]+"$', ngx.header["WWW-Authenticate"])
                    end
                )

                it(
                    "should use only the configured prefix loaded at init", function()
                        rules = { { prefix_pattern = "^custom_" } }
                        plugin.init()
                        rules = {}

                        for _, token in ipairs({ "tai_pat_test", "bkp_test" }) do
                            headers["Authorization"] = "Bearer " .. token
                            assert.is_equal(401, plugin.rewrite({}, ctx))
                        end

                        headers["Authorization"] = "Bearer custom_test"
                        assert.is_nil(plugin.rewrite({}, ctx))
                        assert.is_true(ctx.var.is_bk_oauth2)
                        assert.stub(bk_core.config.get_oauth2_bearer_token_rules).was_called(1)
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
                    "should set is_bk_oauth2=true when a bkauth Bearer token is present", function()
                        headers["Authorization"] = "Bearer " .. BKAUTH_TOKEN

                        local result = plugin.rewrite({}, ctx)

                        assert.is_nil(result)
                        assert.is_true(ctx.var.is_bk_oauth2)
                    end
                )

                it(
                    "should handle Bearer with extra spaces", function()
                        headers["Authorization"] = "Bearer   " .. BKAUTH_TOKEN

                        plugin.rewrite({}, ctx)

                        assert.is_true(ctx.var.is_bk_oauth2)
                    end
                )

                it(
                    "should intercept tai_pat_ tokens", function()
                        headers["Authorization"] = "Bearer tai_pat_anything"

                        assert.is_nil(plugin.rewrite({}, ctx))
                        assert.is_true(ctx.var.is_bk_oauth2)
                    end
                )

                for _, conf in ipairs({ {}, { challenge_on_missing_credential = false } }) do
                    it(
                        "should send a short bkauth Bearer to the OAuth2 flow", function()
                            headers["Authorization"] = "Bearer bkp_short"

                            assert.is_nil(plugin.rewrite(conf, ctx))
                            assert.is_true(ctx.var.is_bk_oauth2)
                        end
                    )
                end

                for _, token in ipairs({ "test-token", "bkx_" .. string.rep("a1B2", 9), "bk_abc", "tai_abc" }) do
                    it(
                        "should treat a non-bkauth Bearer token as no credential: " .. token, function()
                            headers["Authorization"] = "Bearer " .. token

                            local status = plugin.rewrite({}, ctx)

                            assert.is_equal(401, status)
                            assert.is_nil(ctx.var.is_bk_oauth2)
                            assert.matches('^Bearer resource_metadata="[^"]+"$', ngx.header["WWW-Authenticate"])
                            local message = ctx.var.bk_apigw_error.error.message
                            assert.is_truthy(message:find(NON_BKAUTH_BEARER_REASON, 1, true))
                            assert.is_falsy(message:find(MISSING_HEADER_REASON, 1, true))
                            assert.is_falsy(message:find(token, 1, true))
                        end
                    )
                end

                it(
                    "should return 401 when no auth headers are present", function()
                        -- No headers set

                        local status = plugin.rewrite({}, ctx)

                        assert.is_equal(401, status)
                        local message = ctx.var.bk_apigw_error.error.message
                        assert.is_truthy(message:find(MISSING_HEADER_REASON, 1, true))
                    end
                )

                for _, authorization in ipairs({ "Basic dXNlcjpwYXNz", "Bearer   " }) do
                    it(
                        "should report a missing header for a non-Bearer or empty Bearer: " .. authorization,
                        function()
                            headers["Authorization"] = authorization

                            local status = plugin.rewrite({}, ctx)

                            assert.is_equal(401, status)
                            assert.is_nil(ctx.var.is_bk_oauth2)
                            local message = ctx.var.bk_apigw_error.error.message
                            assert.is_truthy(message:find(MISSING_HEADER_REASON, 1, true))
                        end
                    )
                end
            end
        )

        context(
            "challenge_on_missing_credential=false", function()
                local conf = { challenge_on_missing_credential = false }

                it(
                    "should use the legacy flow when no credential is present", function()
                        assert.is_nil(plugin.rewrite(conf, ctx))
                        assert.is_false(ctx.var.is_bk_oauth2)
                    end
                )

                for _, authorization in ipairs({ "Bearer test-token", "Bearer", "Basic dXNlcjpwYXNz" }) do
                    it(
                        "should use the legacy flow for a non-bkauth Authorization: " .. authorization, function()
                            headers["Authorization"] = authorization

                            assert.is_nil(plugin.rewrite(conf, ctx))
                            assert.is_false(ctx.var.is_bk_oauth2)
                        end
                    )
                end

                it(
                    "should still use the OAuth2 flow for a bkauth Bearer token", function()
                        headers["Authorization"] = "Bearer " .. BKAUTH_TOKEN

                        assert.is_nil(plugin.rewrite(conf, ctx))
                        assert.is_true(ctx.var.is_bk_oauth2)
                    end
                )

                it(
                    "should keep the legacy header precedence", function()
                        headers["X-Bkapi-Authorization"] = '{"bk_app_code": "test"}'
                        headers["Authorization"] = "Bearer " .. BKAUTH_TOKEN

                        assert.is_nil(plugin.rewrite(conf, ctx))
                        assert.is_false(ctx.var.is_bk_oauth2)
                    end
                )
            end
        )

        context(
            "default Bearer prefix rules", function()
                before_each(
                    function()
                        stub(core.config, "local_conf", function() return {} end)
                        plugin.init()
                        core.config.local_conf:revert()
                    end
                )

                for _, conf in ipairs({ {}, { challenge_on_missing_credential = false } }) do
                    for _, token in ipairs({ "bkp_short", "tai_pat_example" }) do
                        it("should route a default prefix to the OAuth2 flow", function()
                            headers["Authorization"] = "Bearer " .. token
                            assert.is_nil(plugin.rewrite(conf, ctx))
                            assert.is_true(ctx.var.is_bk_oauth2)
                        end)
                    end
                end

                it("should preserve the legacy flow for other Bearer tokens on app-only routes", function()
                    headers["Authorization"] = "Bearer backend-own-token"
                    assert.is_nil(plugin.rewrite({ challenge_on_missing_credential = false }, ctx))
                    assert.is_false(ctx.var.is_bk_oauth2)
                end)

                it("should challenge for other Bearer tokens on personal/public routes", function()
                    headers["Authorization"] = "Bearer backend-own-token"
                    assert.is_equal(401, plugin.rewrite({}, ctx))
                    assert.matches('^Bearer resource_metadata="[^"]+"$', ngx.header["WWW-Authenticate"])
                end)
            end
        )

        context(
            "configured user ticket cookies", function()
                local cookies

                before_each(function()
                    cookies = {}
                    ctx.var.bk_resource_auth = resource_auth.new({verified_user_required = true})
                    stub(bk_core.cookie, "get_value", function(name)
                        return cookies[name]
                    end)
                end)

                after_each(function()
                    bk_core.cookie.get_value:revert()
                end)

                for _, case in ipairs({
                    {cookie = "bk_token", conf = "user_conf", flag = "from_bk_token", user_type = "bkuser"},
                    {cookie = "bk_ticket", conf = "rtx_conf", flag = "from_bk_ticket", user_type = "rtx"},
                }) do
                    context(case.cookie, function()
                        before_each(function()
                            ctx.var.bk_api_auth = api_auth.new({
                                [case.conf] = {user_type = case.user_type, [case.flag] = true},
                            })
                            cookies[case.cookie] = "user-ticket"
                        end)

                        it("should defer configured cookies to legacy authentication", function()
                            assert.is_nil(plugin.rewrite({}, ctx))
                            assert.is_false(ctx.var.is_bk_oauth2)
                        end)

                        it("should reject cookies when user authentication is not required", function()
                            ctx.var.bk_resource_auth = resource_auth.new({verified_user_required = false})
                            assert.is_equal(401, plugin.rewrite({}, ctx))
                        end)

                        it("should retain the challenge when app authentication is also required", function()
                            ctx.var.bk_resource_auth = resource_auth.new({
                                verified_user_required = true,
                                verified_app_required = true,
                            })
                            local status = plugin.rewrite({}, ctx)
                            assert.is_equal(401, status)
                            assert.matches("^Bearer ", ngx.header["WWW-Authenticate"])
                            assert.matches("resource_metadata=", ngx.header["WWW-Authenticate"])
                        end)

                        it("should reject cookies when their authentication source is disabled", function()
                            ctx.var.bk_api_auth[case.conf][case.flag] = false
                            assert.is_equal(401, plugin.rewrite({}, ctx))
                        end)

                        it("should reject cookies when the user type is not configured", function()
                            ctx.var.bk_api_auth[case.conf].user_type = ""
                            assert.is_equal(401, plugin.rewrite({}, ctx))
                        end)

                        if case.cookie == "bk_ticket" then
                            it("should retain uin authentication precedence", function()
                                ctx.var.bk_api_auth = api_auth.new({
                                    uin_conf = {user_type = "uin", from_uin_skey = true},
                                    rtx_conf = {user_type = "rtx", from_bk_ticket = true},
                                })
                                assert.is_equal(401, plugin.rewrite({}, ctx))
                            end)
                        end

                        it("should reject missing cookies", function()
                            cookies[case.cookie] = nil
                            assert.is_equal(401, plugin.rewrite({}, ctx))
                        end)

                        it("should reject empty cookies", function()
                            cookies[case.cookie] = ""
                            assert.is_equal(401, plugin.rewrite({}, ctx))
                        end)

                        it("should reject cookies for a different authentication source", function()
                            cookies[case.cookie] = nil
                            cookies[case.cookie == "bk_token" and "bk_ticket" or "bk_token"] = "other-ticket"
                            assert.is_equal(401, plugin.rewrite({}, ctx))
                        end)

                        it("should preserve bkauth Bearer precedence over cookies", function()
                            headers["Authorization"] = "Bearer " .. BKAUTH_TOKEN
                            assert.is_nil(plugin.rewrite({}, ctx))
                            assert.is_true(ctx.var.is_bk_oauth2)
                            assert.stub(bk_core.cookie.get_value).was_not_called()
                        end)

                        it("should send a short bkauth Bearer to OAuth2 without cookie fallback", function()
                            headers["Authorization"] = "Bearer bkp_short"
                            assert.is_nil(plugin.rewrite({}, ctx))
                            assert.is_true(ctx.var.is_bk_oauth2)
                            assert.stub(bk_core.cookie.get_value).was_not_called()
                        end)

                        local non_bkauth = {"Bearer", "Bearer ", "bEaReR ", "Bearer\ttoken", "Bearer invalid-token"}
                        for _, authorization in ipairs(non_bkauth) do
                            it("should defer cookies with a non-bkauth Bearer: " .. authorization, function()
                                headers["Authorization"] = authorization
                                assert.is_nil(plugin.rewrite({}, ctx))
                                assert.is_false(ctx.var.is_bk_oauth2)
                                assert.is_equal(authorization, headers["Authorization"])
                            end)
                        end

                        it("should preserve legacy header precedence over Bearer and cookies", function()
                            headers["X-Bkapi-Authorization"] = '{"bk_app_code":"test"}'
                            headers["Authorization"] = "Bearer " .. BKAUTH_TOKEN
                            assert.is_nil(plugin.rewrite({}, ctx))
                            assert.is_false(ctx.var.is_bk_oauth2)
                            assert.stub(bk_core.cookie.get_value).was_not_called()
                        end)

                        it("should retain the challenge without gateway context", function()
                            ctx.var.bk_api_auth = nil
                            assert.is_equal(401, plugin.rewrite({}, ctx))
                        end)

                        it("should retain the challenge without resource context", function()
                            ctx.var.bk_resource_auth = nil
                            assert.is_equal(401, plugin.rewrite({}, ctx))
                        end)
                    end)
                end
            end
        )

        context(
            "legacy query credentials", function()
                local args

                before_each(function()
                    args = {}
                    ctx.var.bk_api_auth = api_auth.new({})
                    ctx.var.bk_resource_auth = resource_auth.new({
                        verified_app_required = true,
                        verified_user_required = true,
                    })
                    stub(core.request, "get_uri_args", function()
                        return args
                    end)
                end)

                after_each(function()
                    core.request.get_uri_args:revert()
                end)

                for _, case in ipairs({
                    {name = "application credentials", args = {bk_app_code = "app", bk_app_secret = "secret"}},
                    {name = "old application aliases", args = {app_code = "app", app_secret = "secret"}},
                    {name = "access_token", args = {access_token = "token"}},
                    {name = "access_token without a value", args = {access_token = true}},
                    {name = "access_token with an empty value", args = {access_token = ""}},
                    {name = "bk_token", args = {bk_token = "ticket"}},
                    {name = "bk_ticket", args = {bk_ticket = "ticket"}},
                }) do
                    it("should accept " .. case.name .. " when parameter auth defaults to allowed", function()
                        args = case.args
                        assert.is_nil(plugin.rewrite({}, ctx))
                        assert.is_false(ctx.var.is_bk_oauth2)
                        assert.is_equal("fallback_query", ctx.var.bk_auth_flow)
                    end)
                end

                it("should accept a repeated credential key with parameter auth enabled", function()
                    ctx.var.bk_api_auth.allow_auth_from_params = true
                    args.access_token = {"", "legacy-token"}
                    assert.is_nil(plugin.rewrite({}, ctx))
                    assert.is_false(ctx.var.is_bk_oauth2)
                end)

                it("should retain the challenge when parameter auth is disabled", function()
                    ctx.var.bk_api_auth.allow_auth_from_params = false
                    args.bk_token = "ticket"
                    assert.is_equal(401, plugin.rewrite({}, ctx))
                    assert.matches("^Bearer ", ngx.header["WWW-Authenticate"])
                    assert.stub(core.request.get_uri_args).was_not_called()
                end)

                it("should retain the challenge for an incomplete application credential pair", function()
                    args.bk_app_code = "app"
                    assert.is_equal(401, plugin.rewrite({}, ctx))
                end)

                it("should preserve bkauth Bearer precedence over query credentials", function()
                    headers["Authorization"] = "Bearer " .. BKAUTH_TOKEN
                    args.access_token = "legacy-token"
                    assert.is_nil(plugin.rewrite({}, ctx))
                    assert.is_true(ctx.var.is_bk_oauth2)
                    assert.stub(core.request.get_uri_args).was_not_called()
                end)

                for _, authorization in ipairs({"Bearer", "Bearer backend-token"}) do
                    it("should fall back for query credentials with " .. authorization, function()
                        headers["Authorization"] = authorization
                        args.access_token = "legacy-token"
                        assert.is_nil(plugin.rewrite({}, ctx))
                        assert.is_false(ctx.var.is_bk_oauth2)
                        assert.is_equal("fallback_query", ctx.var.bk_auth_flow)
                    end)
                end

                it("should preserve the app-only fallback without reading query credentials", function()
                    args.access_token = "legacy-token"
                    assert.is_nil(plugin.rewrite({challenge_on_missing_credential = false}, ctx))
                    assert.is_false(ctx.var.is_bk_oauth2)
                    assert.is_equal("fallback_no_credential", ctx.var.bk_auth_flow)
                    assert.stub(core.request.get_uri_args).was_not_called()
                end)
            end
        )

        context(
            "bk_auth_flow", function()
                it("should be legacy when X-Bkapi-Authorization is present", function()
                    headers["X-Bkapi-Authorization"] = '{"bk_app_code": "test"}'
                    headers["Authorization"] = "Bearer " .. BKAUTH_TOKEN
                    assert.is_nil(plugin.rewrite({}, ctx))
                    assert.is_equal("legacy", ctx.var.bk_auth_flow)
                end)

                it("should be oauth2 for a bkauth Bearer token", function()
                    headers["Authorization"] = "Bearer " .. BKAUTH_TOKEN
                    assert.is_nil(plugin.rewrite({}, ctx))
                    assert.is_equal("oauth2", ctx.var.bk_auth_flow)
                end)

                it("should be fallback_cookie for a configured user ticket cookie", function()
                    ctx.var.bk_resource_auth = resource_auth.new({verified_user_required = true})
                    ctx.var.bk_api_auth = api_auth.new({
                        user_conf = {user_type = "bkuser", from_bk_token = true},
                    })
                    stub(bk_core.cookie, "get_value", function(name)
                        return name == "bk_token" and "user-ticket" or nil
                    end)

                    assert.is_nil(plugin.rewrite({}, ctx))
                    assert.is_equal("fallback_cookie", ctx.var.bk_auth_flow)

                    bk_core.cookie.get_value:revert()
                end)

                it("should be fallback_no_credential when the challenge is disabled", function()
                    headers["Authorization"] = "Bearer backend-own-token"
                    assert.is_nil(plugin.rewrite({ challenge_on_missing_credential = false }, ctx))
                    assert.is_equal("fallback_no_credential", ctx.var.bk_auth_flow)
                end)

                it("should be oauth2_challenge when no credential is present", function()
                    assert.is_equal(401, plugin.rewrite({}, ctx))
                    assert.is_equal("oauth2_challenge", ctx.var.bk_auth_flow)
                end)
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

                it(
                    "should return nil for a whitespace-only Bearer token", function()
                        assert.is_nil(plugin._parse_bearer_token("Bearer   "))
                    end
                )
            end
        )

        context(
            "build_www_authenticate_header", function()
                it(
                    "should handle subpath template format", function()
                        bk_core.config.get_bk_apigateway_api_tmpl:revert()
                        stub(
                            bk_core.config, "get_bk_apigateway_api_tmpl", function()
                                return "http://bkapi.example.com/api/{api_name}"
                            end
                        )

                        local header = oauth2.build_www_authenticate_header(ctx)

                        assert.is_not_nil(header)
                        local expected = 'resource_metadata="http://bkapi.example.com/api/bk-apigateway/prod/'
                        assert.is_truthy(string.find(header, expected, 1, true))
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
                                header, 'resource_metadata="http://bk-apigateway.bkapi.example.com/prod/', 1, true
                            )
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
                    "should encode path correctly", function()
                        bk_core.config.get_bk_apigateway_api_tmpl:revert()
                        stub(
                            bk_core.config, "get_bk_apigateway_api_tmpl", function()
                                return "https://bkapi.example.com/api/{api_name}"
                            end
                        )
                        ctx.var.uri = "/api/v1/users?query=test"

                        local header = oauth2.build_www_authenticate_header(ctx)

                        -- The resource URL should be URL encoded
                        -- Use plain text matching to avoid pattern issues with %2F
                        local expected = "resource=https%3A%2F%2Fbkapi.example.com%2Fapi%2Fv1%2Fusers"
                        assert.is_truthy(string.find(header, expected, 1, true))
                    end
                )
            end
        )
    end
)
