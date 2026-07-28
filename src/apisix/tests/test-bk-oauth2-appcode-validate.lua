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
local plugin = require("apisix.plugins.bk-oauth2-appcode-validate")

describe(
    "bk-oauth2-appcode-validate", function()
        local ctx

        before_each(
            function()
                ctx = {
                    var = {
                        uri = "/api/test",
                        bk_gateway_name = "demo",
                        bk_resource_name = "test-resource",
                        is_bk_oauth2 = true,
                        bk_app_code = "public",
                    },
                }

                stub(
                    bk_core.config, "get_bk_apigateway_api_tmpl", function()
                        return "https://{api_name}.example.com"
                    end
                )
                stub(core.log, "info")
                stub(core.log, "error")
            end
        )

        after_each(
            function()
                bk_core.config.get_bk_apigateway_api_tmpl:revert()
                core.log.info:revert()
                core.log.error:revert()
                ngx.header["WWW-Authenticate"] = nil
            end
        )

        local function check_conf(conf)
            local ok, err = plugin.check_schema(conf)
            assert.is_true(ok)
            assert.is_nil(err)
            return conf
        end

        context(
            "schema", function()
                it(
                    "defines support flags on the route schema", function()
                        assert.is_nil(plugin.attr_schema)
                        assert.is_nil(plugin.init)
                        assert.is_same(
                            {
                                type = "boolean",
                                default = false,
                            },
                            plugin.schema.properties.support_public
                        )
                        assert.is_same(
                            {
                                type = "boolean",
                                default = false,
                            },
                            plugin.schema.properties.support_personal
                        )
                    end
                )

                it(
                    "applies false defaults to empty route configuration", function()
                        local conf = {}
                        local ok, err = plugin.check_schema(conf)

                        assert.is_true(ok)
                        assert.is_nil(err)
                        assert.is_false(conf.support_public)
                        assert.is_false(conf.support_personal)
                    end
                )

                it(
                    "accepts boolean route configuration", function()
                        local ok, err = plugin.check_schema(
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
                    "rejects non-boolean route configuration", function()
                        local ok = plugin.check_schema(
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
            "rewrite", function()
                it(
                    "skips when is_bk_oauth2 is false", function()
                        ctx.var.is_bk_oauth2 = false

                        local result = plugin.rewrite(check_conf({}), ctx)

                        assert.is_nil(result)
                        assert.stub(core.log.info).was_called_with(
                            "bk-oauth2-appcode-validate: skipping",
                            ", is_bk_oauth2=", false,
                            ", gateway=", "demo",
                            ", resource=", "test-resource"
                        )
                    end
                )

                it(
                    "skips when is_bk_oauth2 is absent", function()
                        ctx.var.is_bk_oauth2 = nil

                        local result = plugin.rewrite(check_conf({}), ctx)

                        assert.is_nil(result)
                    end
                )

                it(
                    "allows public when public support is enabled", function()
                        local conf = check_conf({
                            support_public = true,
                        })

                        local result = plugin.rewrite(conf, ctx)

                        assert.is_nil(result)
                        assert.stub(core.log.info).was_called_with(
                            "bk-oauth2-appcode-validate: checking",
                            ", bk_app_code=", "public",
                            ", support_public=", true,
                            ", support_personal=", false,
                            ", gateway=", "demo",
                            ", resource=", "test-resource"
                        )
                        assert.stub(core.log.info).was_called_with(
                            "bk-oauth2-appcode-validate: validation passed",
                            ", bk_app_code=", "public",
                            ", support_public=", true,
                            ", support_personal=", false,
                            ", gateway=", "demo",
                            ", resource=", "test-resource"
                        )
                    end
                )

                it(
                    "allows personal when personal support is enabled", function()
                        local conf = check_conf({
                            support_personal = true,
                        })
                        ctx.var.bk_app_code = "personal"

                        local result = plugin.rewrite(conf, ctx)

                        assert.is_nil(result)
                    end
                )

                it(
                    "rejects a disabled supported app code", function()
                        local status = plugin.rewrite(check_conf({}), ctx)

                        assert.is_equal(401, status)
                        assert.is_equal(
                            "UNAUTHORIZED",
                            ctx.var.bk_apigw_error.error.code_name
                        )
                    end
                )

                it(
                    "rejects an ordinary app code even when both flags are enabled", function()
                        local conf = check_conf({
                            support_public = true,
                            support_personal = true,
                        })
                        ctx.var.bk_app_code = "ordinary-app"

                        local status = plugin.rewrite(conf, ctx)

                        assert.is_equal(401, status)
                    end
                )

                it(
                    "rejects a missing app code", function()
                        ctx.var.bk_app_code = nil

                        local status = plugin.rewrite(check_conf({}), ctx)

                        assert.is_equal(401, status)
                    end
                )

                it(
                    "rejects an empty app code", function()
                        ctx.var.bk_app_code = ""

                        local status = plugin.rewrite(check_conf({}), ctx)

                        assert.is_equal(401, status)
                    end
                )

                it(
                    "returns rich invalid_token details", function()
                        local conf = check_conf({
                            support_personal = true,
                        })
                        ctx.var.bk_app_code = "public"

                        local status = plugin.rewrite(conf, ctx)
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
                        assert.is_truthy(string.find(message, 'gateway="demo"', 1, true))
                        assert.is_truthy(string.find(message, 'resource="test-resource"', 1, true))
                        assert.is_truthy(string.find(www_auth, 'error="invalid_token"', 1, true))
                        assert.is_truthy(string.find(www_auth, "bk_app_code=public", 1, true))
                        assert.is_truthy(string.find(www_auth, "support_public=false", 1, true))
                        assert.is_truthy(string.find(www_auth, "support_personal=true", 1, true))
                        assert.stub(core.log.info).was_called_with(
                            "bk-oauth2-appcode-validate: validation failed",
                            ", bk_app_code=", "public",
                            ", support_public=", false,
                            ", support_personal=", true,
                            ", gateway=", "demo",
                            ", resource=", "test-resource"
                        )
                    end
                )
            end
        )
    end
)
