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
local apisix_plugin = require("apisix.plugin")
local bk_core = require("apisix.plugins.bk-core.init")
local plugin = require("apisix.plugins.bk-oauth2-appcode-validate")

describe(
    "bk-oauth2-appcode-validate", function()
        local plugin_attr
        local ctx

        before_each(
            function()
                plugin_attr = {}
                ctx = {
                    var = {
                        uri = "/api/test",
                        bk_gateway_name = "demo",
                        is_bk_oauth2 = true,
                        bk_app_code = "public",
                    },
                }

                stub(
                    apisix_plugin, "plugin_attr", function(name)
                        assert.is_equal("bk-oauth2-appcode-validate", name)
                        return plugin_attr
                    end
                )
                stub(
                    bk_core.config, "get_bk_apigateway_api_tmpl", function()
                        return "https://{api_name}.example.com"
                    end
                )
                stub(core.log, "info")
                stub(core.log, "error")

                plugin.init()
            end
        )

        after_each(
            function()
                apisix_plugin.plugin_attr:revert()
                bk_core.config.get_bk_apigateway_api_tmpl:revert()
                core.log.info:revert()
                core.log.error:revert()
                ngx.header["WWW-Authenticate"] = nil
            end
        )

        context(
            "schema", function()
                it(
                    "accepts empty route configuration", function()
                        local ok, err = plugin.check_schema({})

                        assert.is_true(ok)
                        assert.is_nil(err)
                    end
                )

                it(
                    "accepts boolean plugin attributes", function()
                        local ok, err = core.schema.check(
                            plugin.attr_schema,
                            {
                                support_public = true,
                                support_personal = false,
                            }
                        )

                        assert.is_true(ok)
                        assert.is_nil(err)
                    end
                )

                it(
                    "rejects non-boolean plugin attributes", function()
                        local ok = core.schema.check(
                            plugin.attr_schema,
                            {
                                support_public = "true",
                            }
                        )

                        assert.is_false(ok)
                    end
                )
            end
        )

        context(
            "initialization", function()
                it(
                    "defaults to an empty allowlist", function()
                        local state = plugin._get_validation_state()

                        assert.is_false(state.support_public)
                        assert.is_false(state.support_personal)
                        assert.is_nil(state.allowed_app_codes.public)
                        assert.is_nil(state.allowed_app_codes.personal)
                    end
                )

                it(
                    "allows public when configured", function()
                        plugin_attr = {
                            support_public = true,
                        }

                        plugin.init()
                        local state = plugin._get_validation_state()

                        assert.is_true(state.support_public)
                        assert.is_false(state.support_personal)
                        assert.is_true(state.allowed_app_codes.public)
                        assert.is_nil(state.allowed_app_codes.personal)
                    end
                )

                it(
                    "allows personal when configured", function()
                        plugin_attr = {
                            support_personal = true,
                        }

                        plugin.init()
                        local state = plugin._get_validation_state()

                        assert.is_false(state.support_public)
                        assert.is_true(state.support_personal)
                        assert.is_nil(state.allowed_app_codes.public)
                        assert.is_true(state.allowed_app_codes.personal)
                    end
                )

                it(
                    "allows both supported app codes", function()
                        plugin_attr = {
                            support_public = true,
                            support_personal = true,
                        }

                        plugin.init()
                        local state = plugin._get_validation_state()

                        assert.is_true(state.allowed_app_codes.public)
                        assert.is_true(state.allowed_app_codes.personal)
                    end
                )

                it(
                    "logs the effective initialization state", function()
                        plugin_attr = {
                            support_public = true,
                        }

                        plugin.init()

                        assert.stub(core.log.info).was_called_with(
                            "bk-oauth2-appcode-validate: initialized",
                            ", support_public=", true,
                            ", support_personal=", false,
                            ", allowed_app_codes=", '{"public":true}'
                        )
                    end
                )

                it(
                    "fails closed for invalid plugin attributes", function()
                        plugin_attr = {
                            support_public = "true",
                        }

                        plugin.init()
                        local state = plugin._get_validation_state()

                        assert.is_false(state.support_public)
                        assert.is_false(state.support_personal)
                        assert.is_nil(state.allowed_app_codes.public)
                        assert.is_nil(state.allowed_app_codes.personal)
                        assert.stub(core.log.error).was_called()
                    end
                )

                it(
                    "does not retain stale allowlist entries after reinitialization", function()
                        plugin_attr = {
                            support_public = true,
                        }
                        plugin.init()

                        plugin_attr = {
                            support_personal = true,
                        }
                        plugin.init()
                        local state = plugin._get_validation_state()

                        assert.is_nil(state.allowed_app_codes.public)
                        assert.is_true(state.allowed_app_codes.personal)
                    end
                )
            end
        )

        context(
            "rewrite", function()
                it(
                    "skips when is_bk_oauth2 is false", function()
                        ctx.var.is_bk_oauth2 = false

                        local result = plugin.rewrite({}, ctx)

                        assert.is_nil(result)
                    end
                )

                it(
                    "skips when is_bk_oauth2 is absent", function()
                        ctx.var.is_bk_oauth2 = nil

                        local result = plugin.rewrite({}, ctx)

                        assert.is_nil(result)
                    end
                )

                it(
                    "allows public when public support is enabled", function()
                        plugin_attr = {
                            support_public = true,
                        }
                        plugin.init()

                        local result = plugin.rewrite({}, ctx)

                        assert.is_nil(result)
                        assert.stub(core.log.info).was_called_with(
                            "bk-oauth2-appcode-validate: validation passed",
                            ", bk_app_code=", "public",
                            ", support_public=", true,
                            ", support_personal=", false
                        )
                    end
                )

                it(
                    "allows personal when personal support is enabled", function()
                        plugin_attr = {
                            support_personal = true,
                        }
                        plugin.init()
                        ctx.var.bk_app_code = "personal"

                        local result = plugin.rewrite({}, ctx)

                        assert.is_nil(result)
                    end
                )

                it(
                    "rejects a disabled supported app code", function()
                        local status = plugin.rewrite({}, ctx)

                        assert.is_equal(401, status)
                        assert.is_equal(
                            "UNAUTHORIZED",
                            ctx.var.bk_apigw_error.error.code_name
                        )
                    end
                )

                it(
                    "rejects an ordinary app code even when both flags are enabled", function()
                        plugin_attr = {
                            support_public = true,
                            support_personal = true,
                        }
                        plugin.init()
                        ctx.var.bk_app_code = "ordinary-app"

                        local status = plugin.rewrite({}, ctx)

                        assert.is_equal(401, status)
                    end
                )

                it(
                    "rejects a missing app code", function()
                        ctx.var.bk_app_code = nil

                        local status = plugin.rewrite({}, ctx)

                        assert.is_equal(401, status)
                    end
                )

                it(
                    "rejects an empty app code", function()
                        ctx.var.bk_app_code = ""

                        local status = plugin.rewrite({}, ctx)

                        assert.is_equal(401, status)
                    end
                )

                it(
                    "returns rich invalid_token details", function()
                        plugin_attr = {
                            support_personal = true,
                        }
                        plugin.init()
                        ctx.var.bk_app_code = "public"

                        local status = plugin.rewrite({}, ctx)
                        local message = ctx.var.bk_apigw_error.error.message
                        local www_auth = ngx.header["WWW-Authenticate"]

                        assert.is_equal(401, status)
                        assert.is_truthy(string.find(
                            message,
                            'reason="OAuth2 token app code is not allowed"',
                            1,
                            true
                        ))
                        assert.is_truthy(string.find(message, 'bk_app_code="public"', 1, true))
                        assert.is_truthy(string.find(message, 'support_public="false"', 1, true))
                        assert.is_truthy(string.find(message, 'support_personal="true"', 1, true))
                        assert.is_truthy(string.find(www_auth, 'error="invalid_token"', 1, true))
                        assert.is_truthy(string.find(www_auth, "bk_app_code=public", 1, true))
                        assert.is_truthy(string.find(www_auth, "support_public=false", 1, true))
                        assert.is_truthy(string.find(www_auth, "support_personal=true", 1, true))
                        assert.stub(core.log.info).was_called_with(
                            "bk-oauth2-appcode-validate: validation failed",
                            ", bk_app_code=", "public",
                            ", support_public=", false,
                            ", support_personal=", true
                        )
                    end
                )
            end
        )
    end
)
