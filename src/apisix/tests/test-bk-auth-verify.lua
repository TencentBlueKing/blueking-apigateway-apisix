--
-- TencentBlueKing is pleased to support the open source community by making
-- 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
-- Copyright (C) 2017 THL A29 Limited, a Tencent company. All rights reserved.
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
local bk_auth_verify_init = require("apisix.plugins.bk-auth-verify.init")
local context_api_bkauth = require("apisix.plugins.bk-define.context-api-bkauth")
local context_resource_bkauth = require("apisix.plugins.bk-define.context-resource-bkauth")
local plugin = require("apisix.plugins.bk-auth-verify")

local ngx = ngx

describe(
    "bk-auth-verify", function()
        local authorization_keys = {
            "bk_app_code",
            "bk_app_secret",
            "bk_username",
            "access_token",
        }
        local method
        local uri_args
        local json_body
        local form_data
        local mutipart_form_data

        before_each(
            function()
                method = "GET"
                uri_args = nil
                json_body = nil
                form_data = nil
                mutipart_form_data = nil

                stub(
                    ngx.req, "get_method", function()
                        return method
                    end
                )
                stub(
                    core.request, "get_uri_args", function()
                        return uri_args
                    end
                )
                stub(
                    bk_core.request, "get_json_body", function()
                        return json_body
                    end
                )
                stub(
                    bk_core.request, "parse_multipart_form", function()
                        return mutipart_form_data
                    end
                )
                stub(
                    bk_core.request, "get_form_data", function()
                        return form_data
                    end
                )
            end
        )

        after_each(
            function()
                ngx.req.get_method:revert()
                core.request.get_uri_args:revert()
                bk_core.request.parse_multipart_form:revert()
                bk_core.request.get_json_body:revert()
                bk_core.request.get_form_data:revert()
            end
        )

        context(
            "get_auth_params_from_header", function()
                local authorization

                before_each(
                    function()
                        stub(
                            core.request, "header", function()
                                return authorization
                            end
                        )
                    end
                )

                after_each(
                    function()
                        core.request.header:revert()
                    end
                )

                it(
                    "authorization not exist", function()
                        authorization = nil

                        local auth_params, err = plugin._get_auth_params_from_header({})
                        assert.is_nil(auth_params)
                        assert.is_nil(err)
                    end
                )

                it(
                    "authorization is not value json", function()
                        authorization = "not valid json"

                        local auth_params, err = plugin._get_auth_params_from_header({})
                        assert.is_equal(err, "request header X-Bkapi-Authorization is not a valid JSON")
                        assert.is_nil(auth_params)
                    end
                )

                it(
                    "ok", function()
                        authorization = core.json.encode(
                            {
                                a = "b",
                            }
                        )

                        local auth_params, err = plugin._get_auth_params_from_header({})
                        assert.is_nil(err)
                        assert.is_same(
                            auth_params, {
                                a = "b",
                            }
                        )
                    end
                )
            end
        )

        context(
            "get_auth_params_from_parameters", function()
                it(
                    "get params from 4 data source", function()
                        method = "POST"
                        uri_args = {
                            bk_app_code = "my-app",
                        }
                        form_data = {
                            bk_app_secret = "my-secret",
                        }
                        json_body = {
                            bk_username = "admin",
                        }
                        mutipart_form_data = {
                            access_token = "my-token",
                        }

                        local auth_params = plugin._get_auth_params_from_parameters({}, authorization_keys)
                        assert.is_same(
                            auth_params, {
                                bk_app_code = "my-app",
                                bk_app_secret = "my-secret",
                                bk_username = "admin",
                                access_token = "my-token",
                            }
                        )
                    end
                )

                it(
                    "some data is nil, or empty", function()
                        method = "POST"
                        uri_args = {
                            bk_app_code = "my-app",
                        }
                        form_data = nil
                        json_body = {}
                        mutipart_form_data = nil

                        local auth_params = plugin._get_auth_params_from_parameters({}, authorization_keys)
                        assert.is_same(
                            auth_params, {
                                bk_app_code = "my-app",
                            }
                        )

                        uri_args = {}
                        auth_params = plugin._get_auth_params_from_parameters({}, authorization_keys)
                        assert.is_same(auth_params, {})
                    end
                )

                it(
                    "data override", function()
                        uri_args = {
                            bk_app_code = "my-app1",
                            bk_app_secret = "my-secret1",
                            bk_username = "admin",
                        }
                        json_body = {
                            bk_app_code = "my-app2",
                            bk_app_secret = "my-secret2",
                            bk_username = "",
                        }

                        local auth_params = plugin._get_auth_params_from_parameters({}, authorization_keys)
                        assert.is_same(
                            auth_params, {
                                bk_app_code = "my-app2",
                                bk_app_secret = "my-secret2",
                                bk_username = "admin",
                            }
                        )
                    end
                )

                it(
                    "has mutiple values", function()
                        uri_args = {
                            bk_app_code = {
                                "my-app",
                                "test",
                            },
                        }
                        local auth_params = plugin._get_auth_params_from_parameters({}, authorization_keys)
                        assert.is_same(
                            auth_params, {
                                bk_app_code = "my-app",
                            }
                        )
                    end
                )

                it(
                    "not include keys not in authorization_keys", function()
                        uri_args = {
                            bk_app_code = "my-app",
                            a = "b",
                        }
                        local auth_params = plugin._get_auth_params_from_parameters({}, authorization_keys)
                        assert.is_same(
                            auth_params, {
                                bk_app_code = "my-app",
                            }
                        )
                    end
                )
            end
        )

        context(
            "get_auth_params_from_request", function()
                it(
                    "from header", function()
                        stub(
                            core.request, "header", core.json.encode(
                                {
                                    bk_app_code = "my-app",
                                    a = "b",
                                }
                            )
                        )

                        local auth_params = plugin._get_auth_params_from_request({}, authorization_keys)
                        assert.is_same(
                            auth_params, {
                                bk_app_code = "my-app",
                                a = "b",
                            }
                        )

                        core.request.header:revert()
                    end
                )

                it(
                    "from parameters", function()
                        stub(
                            core.request, "get_uri_args", {
                                bk_app_code = "my-app",
                                a = "b",
                            }
                        )
                        local auth_params = plugin._get_auth_params_from_request({}, authorization_keys)
                        assert.is_same(
                            auth_params, {
                                bk_app_code = "my-app",
                            }
                        )

                        core.request.get_uri_args:revert()
                    end
                )

                it(
                    "provide no valid inputs", function()
                        local auth_params, err = plugin._get_auth_params_from_request({}, authorization_keys)
                        assert.are_same(auth_params, {})
                        assert.is_nil(err)
                    end
                )
            end
        )

        context(
            "verify", function()
                local bk_api_auth = context_api_bkauth.new({})
                local bk_resource_auth = context_resource_bkauth.new({})

                it(
                    "with no auth params", function()
                        local app, user = plugin.verify({
                            var = {
                                bk_api_auth = bk_api_auth,
                                bk_resource_auth = bk_resource_auth,
                            },
                        })
                        assert.is_equal(app.app_code, "")
                        assert.is_false(app.verified)
                        -- The legacy verifier was triggered by default.
                        assert.is_equal(
                            app.valid_error_message,
                            "the gateway configuration error, please contact the API Gateway developer to handle"
                        )
                        assert.is_equal(user.username, "")
                        assert.is_false(user.verified)
                        assert.is_equal(
                            user.valid_error_message,
                            "the gateway configuration error, please contact the API Gateway developer to handle"
                        )
                    end
                )

                it(
                    "with invalid JSON auth_params in header", function()
                        stub(core.request, "header", "not valid json")

                        local app, user = plugin.verify({
                            var = {
                                bk_api_auth = bk_api_auth,
                                bk_resource_auth = bk_resource_auth,
                            },
                        })
                        assert.is_equal(app.app_code, "")
                        assert.is_false(app.verified)
                        assert.is_equal(
                            app.valid_error_message, "request header X-Bkapi-Authorization is not a valid JSON"
                        )
                        assert.is_equal(user.username, "")
                        assert.is_false(user.verified)
                        assert.is_equal(
                            user.valid_error_message, "request header X-Bkapi-Authorization is not a valid JSON"
                        )

                        core.request.header:revert()
                    end
                )

                it(
                    "verify app ok", function()
                        stub(
                            bk_auth_verify_init, "verify_app", {
                                app_code = "my-app",
                                verified = true,
                            }
                        )

                        local app, _ = plugin.verify(
                            {
                                var = {
                                    bk_api_auth = bk_api_auth,
                                    bk_resource_auth = bk_resource_auth,
                                },
                            }
                        )
                        assert.is_equal(app.app_code, "my-app")
                        assert.is_true(app.verified)

                        bk_auth_verify_init.verify_app:revert()
                    end
                )

                it(
                    "verify app error", function()
                        stub(
                            bk_auth_verify_init, "verify_app", function()
                                return nil, "error"
                            end
                        )

                        local app, _ = plugin.verify(
                            {
                                var = {
                                    bk_api_auth = bk_api_auth,
                                    bk_resource_auth = bk_resource_auth,
                                },
                            }
                        )
                        assert.is_equal(app.app_code, "")
                        assert.is_false(app.verified)
                        assert.is_equal(app.valid_error_message, "error")

                        bk_auth_verify_init.verify_app:revert()
                    end
                )

                it(
                    "verify user ok", function()
                        stub(
                            bk_auth_verify_init, "verify_user", {
                                username = "admin",
                                verified = true,
                            }
                        )

                        local _, user = plugin.verify(
                            {
                                var = {
                                    bk_api_auth = bk_api_auth,
                                    bk_resource_auth = bk_resource_auth,
                                },
                            }
                        )
                        assert.is_equal(user.username, "admin")
                        assert.is_true(user.verified)

                        bk_auth_verify_init.verify_user:revert()
                    end
                )

                it(
                    "verify user error", function()
                        stub(
                            bk_auth_verify_init, "verify_user", function()
                                return nil, "error"
                            end
                        )

                        local _, user = plugin.verify(
                            {
                                var = {
                                    bk_api_auth = bk_api_auth,
                                    bk_resource_auth = bk_resource_auth,
                                },
                            }
                        )
                        assert.is_equal(user.username, "")
                        assert.is_false(user.verified)
                        assert.is_equal(user.valid_error_message, "error")

                        bk_auth_verify_init.verify_user:revert()
                    end
                )
            end
        )

        context(
            "rewrite", function()
                local ctx

                before_each(
                    function()
                        ctx = {
                            var = {
                                bk_gateway_name = "my-gateway",
                                bk_stage_name = "my-stage",
                            },
                        }
                    end
                )

                it(
                    "ok", function()
                        stub(
                            plugin, "verify", function()
                                return {
                                    app_code = "my-app",
                                }, {
                                    username = "admin",
                                }
                            end
                        )

                        plugin.rewrite({}, ctx)
                        assert.is_same(
                            ctx.var.bk_app, {
                                app_code = "my-app",
                            }
                        )
                        assert.is_same(
                            ctx.var.bk_user, {
                                username = "admin",
                            }
                        )
                        assert.is_same(ctx.var.bk_app_code, "my-app")
                        assert.is_same(ctx.var.bk_username, "admin")

                        plugin.verify:revert()
                    end
                )
            end
        )
    end
)
