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
local response = require("apisix.core.response")
local bk_core = require("apisix.plugins.bk-core.init")
local bk_auth_verify_init = require("apisix.plugins.bk-auth-verify.init")
local context_api_bkauth = require("apisix.plugins.bk-define.context-api-bkauth")
local context_resource_bkauth = require("apisix.plugins.bk-define.context-resource-bkauth")
local bk_app_define = require("apisix.plugins.bk-define.app")
local bk_user_define = require("apisix.plugins.bk-define.user")
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
        local multipart_form_data

        before_each(
            function()
                method = "GET"
                uri_args = nil
                json_body = nil
                form_data = nil
                multipart_form_data = nil

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
                        return multipart_form_data
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
                    "header not exists", function()
                        authorization = nil

                        local auth_params, err = plugin._get_auth_params_from_header({})
                        assert.is_nil(auth_params)
                        assert.is_nil(err)
                    end
                )

                it(
                    "data is not valid json", function()
                        authorization = "not valid json"

                        local auth_params, err = plugin._get_auth_params_from_header({})
                        assert.is_equal(err, "request header X-Bkapi-Authorization is not a valid JSON")
                        assert.is_nil(auth_params)
                    end
                )

                it(
                    "normal", function()
                        authorization = core.json.encode(
                            {
                                foo = "bar",
                            }
                        )

                        local auth_params, err = plugin._get_auth_params_from_header({})
                        assert.is_nil(err)
                        assert.is_same(
                            auth_params, {
                                foo = "bar",
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
                        multipart_form_data = {
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
                    "some data sources is nil or empty", function()
                        method = "POST"
                        uri_args = {
                            bk_app_code = "my-app",
                        }
                        form_data = nil
                        json_body = {}
                        multipart_form_data = nil

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
                    "value in request body overwrites the one in uri args", function()
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
                    "multiple values exists for the same param", function()
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
                    "provide unrelated keys", function()
                        uri_args = {
                            bk_app_code = "my-app",
                            -- This key is unrelated with "authorization_keys"
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

                        local auth_params_func = plugin._get_auth_params_from_request({}, authorization_keys)
                        local auth_params = auth_params_func()
                        assert.is_same(
                            auth_params, {
                                bk_app_code = "my-app",
                                -- The unrelated key is preserved when using header as data source
                                a = "b",
                            }
                        )

                        -- execute the func only once
                        auth_params_func()
                        auth_params = auth_params_func()
                        assert.is_same(
                            auth_params, {
                                bk_app_code = "my-app",
                                a = "b",
                            }
                        )
                        assert.stub(core.request.header).was_called(1)

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
                        local auth_params_func = plugin._get_auth_params_from_request({}, authorization_keys)
                        local auth_params = auth_params_func()
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
                        local auth_params_func = plugin._get_auth_params_from_request({}, authorization_keys)
                        local auth_params, err = auth_params_func()
                        assert.are_same(auth_params, {})
                        assert.is_nil(err)
                    end
                )
            end
        )

        context(
            "is_app_exempted_from_verified_user", function()
                local cases = {
                    -- whitelist config is absent
                    {
                        app_code = "test",
                        resource_id = 100,
                        verified_user_exempted_apps = nil,
                        expected = false,
                    },
                    -- app code is empty
                    {
                        app_code = "",
                        resource_id = 100,
                        verified_user_exempted_apps = {
                            by_gateway = {
                                test1 = true,
                                test2 = true,
                            },
                            by_resource = {},
                        },
                        expected = false,
                    },
                    -- app matches whitelist, by_gateway
                    {
                        app_code = "test1",
                        resource_id = 100,
                        verified_user_exempted_apps = {
                            by_gateway = {
                                test1 = true,
                                test2 = true,
                            },
                            by_resource = {},
                        },
                        expected = true,
                    },
                    -- app matches whitelist, by_resource
                    {
                        app_code = "test1",
                        resource_id = 100,
                        verified_user_exempted_apps = {
                            by_gateway = {
                                test2 = true,
                            },
                            by_resource = {
                                test1 = {
                                    ["100"] = true,
                                },
                            },
                        },
                        expected = true,
                    },
                    -- app not in whitelist
                    {
                        app_code = "test",
                        resource_id = 100,
                        verified_user_exempted_apps = {
                            by_gateway = {
                                test1 = true,
                                test2 = true,
                            },
                            by_resource = {},
                        },
                        expected = false,
                    },
                }

                for _, test in pairs(cases) do
                    local result = plugin._is_app_exempted_from_verified_user(
                        test.app_code, test.resource_id, test.verified_user_exempted_apps
                    )
                    assert.is_equal(result, test.expected)
                end
            end
        )

        context(
            "verify_app", function()
                local bk_api_auth = context_api_bkauth.new({})
                local bk_resource_auth = context_resource_bkauth.new({})

                it(
                    "bk_resource_auth nil", function()
                        local app, has_server_errror = plugin._verify_app(
                            {
                                var = {},
                            }, function()
                            end
                        )

                        assert.is_equal(app.app_code, "")
                        assert.is_false(app.verified)
                        assert.is_equal(
                            app.valid_error_message,
                            'verify skipped, the "bk-resource-context" plugin is not configured'
                        )
                        assert.is_true(has_server_errror)
                    end
                )

                it(
                    "auth_params nil", function()
                        local app, has_server_errror = plugin._verify_app(
                            {
                                var = {
                                    bk_resource_auth = {},
                                },
                            }, function()
                                return nil, "error"
                            end
                        )
                        assert.is_equal(app.app_code, "")
                        assert.is_false(app.verified)
                        assert.is_equal(app.valid_error_message, "error")
                        assert.is_false(has_server_errror)
                    end
                )

                it(
                    "with no auth params", function()
                        local app, has_server_error = plugin._verify_app(
                            {
                                var = {
                                    bk_api_auth = bk_api_auth,
                                    bk_resource_auth = bk_resource_auth,
                                },
                            }, function()
                                return {}, nil
                            end
                        )
                        assert.is_equal(app.app_code, "")
                        assert.is_false(app.verified)
                        -- The legacy verifier was triggered by default.
                        assert.is_equal(
                            app.valid_error_message,
                            "the gateway configuration error, please contact the API Gateway developer to handle"
                        )
                        assert.is_true(has_server_error)
                    end
                )

                it(
                    "with invalid JSON auth_params in header", function()
                        stub(core.request, "header", "not valid json")

                        local app, has_server_error = plugin._verify_app(
                            {
                                var = {
                                    bk_api_auth = bk_api_auth,
                                    bk_resource_auth = bk_resource_auth,
                                },
                            }, plugin._get_auth_params_from_request(
                                {
                                    var = {},
                                }, bk_core.config.get_authorization_keys()
                            )
                        )
                        assert.is_equal(app.app_code, "")
                        assert.is_false(app.verified)
                        assert.is_equal(
                            app.valid_error_message, "request header X-Bkapi-Authorization is not a valid JSON"
                        )
                        assert.is_false(has_server_error)

                        core.request.header:revert()
                    end
                )

                it(
                    "verify app ok", function()
                        stub(
                            bk_auth_verify_init, "verify_app", function()
                                return {
                                    app_code = "my-app",
                                    verified = true,
                                }, false
                            end
                        )

                        local app, has_server_error = plugin._verify_app(
                            {
                                var = {
                                    bk_api_auth = bk_api_auth,
                                    bk_resource_auth = bk_resource_auth,
                                },
                            }, function()
                                return {}, nil
                            end
                        )
                        assert.is_equal(app.app_code, "my-app")
                        assert.is_true(app.verified)
                        assert.is_false(has_server_error)

                        bk_auth_verify_init.verify_app:revert()
                    end
                )

                it(
                    "verify app error", function()
                        stub(
                            bk_auth_verify_init, "verify_app", function()
                                return bk_app_define.new_anonymous_app("error"), true
                            end
                        )

                        local app, has_server_error = plugin._verify_app(
                            {
                                var = {
                                    bk_api_auth = bk_api_auth,
                                    bk_resource_auth = bk_resource_auth,
                                },
                            }, function()
                                return {}, nil
                            end
                        )
                        assert.is_equal(app.app_code, "")
                        assert.is_false(app.verified)
                        assert.is_equal(app.valid_error_message, "error")
                        assert.is_true(has_server_error)

                        bk_auth_verify_init.verify_app:revert()
                    end
                )
            end
        )

        context(
            "validate_app", function()
                context(
                    "ok", function()
                        it(
                            "app verification not required", function()
                                local bk_resource_auth = context_resource_bkauth.new(
                                    {
                                        verified_app_required = false,
                                    }
                                )
                                local app = bk_app_define.new_app(
                                    {
                                        verified = false,
                                        valid_error_message = "error",
                                    }
                                )

                                local apigwerr = plugin._validate_app(bk_resource_auth, app, false)
                                assert.is_nil(apigwerr)
                            end
                        )

                        it(
                            "verification required with verified app", function()
                                local bk_resource_auth = context_resource_bkauth.new(
                                    {
                                        verified_app_required = true,
                                    }
                                )
                                local app = bk_app_define.new_app(
                                    {
                                        verified = true,
                                        valid_error_message = "",
                                    }
                                )

                                local apigwerr = plugin._validate_app(bk_resource_auth, app, false)
                                assert.is_nil(apigwerr)
                            end
                        )
                    end
                )

                context(
                    "validate fail", function()
                        it(
                            "verification required with unverified app", function()
                                local bk_resource_auth = context_resource_bkauth.new(
                                    {
                                        verified_app_required = true,
                                    }
                                )
                                local app = bk_app_define.new_app(
                                    {
                                        verified = false,
                                        valid_error_message = "error",
                                    }
                                )

                                local apigwerr = plugin._validate_app(bk_resource_auth, app, false)
                                assert.is_equal(apigwerr.status, 400)

                                apigwerr = plugin._validate_app(bk_resource_auth, app, true)
                                assert.is_equal(apigwerr.status, 500)
                            end
                        )
                    end
                )
            end
        )

        context(
            "verify_user", function()
                local bk_api_auth = context_api_bkauth.new({})
                local bk_resource_auth = context_resource_bkauth.new({})

                it(
                    "bk_resource_auth nil", function()
                        local user, has_server_errror = plugin._verify_user(
                            {
                                var = {},
                            }, function()
                            end
                        )

                        assert.is_equal(user.username, "")
                        assert.is_false(user.verified)
                        assert.is_equal(
                            user.valid_error_message,
                            'verify skipped, the "bk-resource-context" plugin is not configured'
                        )
                        assert.is_true(has_server_errror)
                    end
                )

                it(
                    "auth_params nil", function()
                        local user, has_server_errror = plugin._verify_user(
                            {
                                var = {
                                    bk_resource_auth = {},
                                },
                            }, function()
                                return nil, "error"
                            end
                        )
                        assert.is_equal(user.username, "")
                        assert.is_false(user.verified)
                        assert.is_equal(user.valid_error_message, "error")
                        assert.is_false(has_server_errror)
                    end
                )

                it(
                    "with no auth params", function()
                        local user, has_server_error = plugin._verify_user(
                            {
                                var = {
                                    bk_api_auth = bk_api_auth,
                                    bk_resource_auth = bk_resource_auth,
                                },
                            }, function()
                                return {}, nil
                            end
                        )
                        assert.is_equal(user.username, "")
                        assert.is_false(user.verified)
                        assert.is_equal(
                            user.valid_error_message,
                            "the gateway configuration error, please contact the API Gateway developer to handle"
                        )
                        assert.is_true(has_server_error)
                    end
                )

                it(
                    "with invalid JSON auth_params in header", function()
                        stub(core.request, "header", "not valid json")

                        local user, has_server_error = plugin._verify_user(
                            {
                                var = {
                                    bk_api_auth = bk_api_auth,
                                    bk_resource_auth = bk_resource_auth,
                                },
                            }, plugin._get_auth_params_from_request(
                                {
                                    var = {},
                                }, bk_core.config.get_authorization_keys()
                            )
                        )
                        assert.is_equal(user.username, "")
                        assert.is_false(user.verified)
                        assert.is_equal(
                            user.valid_error_message, "request header X-Bkapi-Authorization is not a valid JSON"
                        )
                        assert.is_false(has_server_error)

                        core.request.header:revert()
                    end
                )

                it(
                    "verify user ok", function()
                        stub(
                            bk_auth_verify_init, "verify_user", function()
                                return {
                                    username = "admin",
                                    verified = true,
                                }, false
                            end
                        )

                        local user, has_server_error = plugin._verify_user(
                            {
                                var = {
                                    bk_api_auth = bk_api_auth,
                                    bk_resource_auth = bk_resource_auth,
                                },
                            }, function()
                                return {}, nil
                            end
                        )
                        assert.is_equal(user.username, "admin")
                        assert.is_true(user.verified)
                        assert.is_false(has_server_error)

                        bk_auth_verify_init.verify_user:revert()
                    end
                )

                it(
                    "verify user error", function()
                        stub(
                            bk_auth_verify_init, "verify_user", function()
                                return bk_user_define.new_anonymous_user("error"), true
                            end
                        )

                        local user, has_server_error = plugin._verify_user(
                            {
                                var = {
                                    bk_api_auth = bk_api_auth,
                                    bk_resource_auth = bk_resource_auth,
                                },
                            }, function()
                                return {}, nil
                            end
                        )
                        assert.is_equal(user.username, "")
                        assert.is_false(user.verified)
                        assert.is_equal(user.valid_error_message, "error")
                        assert.is_true(has_server_error)

                        bk_auth_verify_init.verify_user:revert()
                    end
                )
            end
        )

        context(
            "validate user", function()
                context(
                    "ok", function()
                        it(
                            "user verification is skipped", function()
                                local bk_resource_auth = context_resource_bkauth.new(
                                    {
                                        skip_user_verification = true,
                                        verified_user_required = true,
                                    }
                                )
                                local user = bk_user_define.new_user(
                                    {
                                        verified = false,
                                        valid_error_message = "error",
                                    }
                                )
                                local app = bk_app_define.new_app(
                                    {
                                        verified = false,
                                        valid_error_message = "error",
                                    }
                                )
                                local apigwerr = plugin._validate_user(100, bk_resource_auth, user, app, nil, false)
                                assert.is_nil(apigwerr)
                            end
                        )

                        it(
                            "user verification not required", function()
                                local bk_resource_auth = context_resource_bkauth.new(
                                    {
                                        skip_user_verification = false,
                                        verified_user_required = false,
                                    }
                                )
                                local user = bk_user_define.new_user(
                                    {
                                        verified = false,
                                        valid_error_message = "error",
                                    }
                                )
                                local app = bk_app_define.new_app(
                                    {
                                        app_code = "foo",
                                        verified = false,
                                        valid_error_message = "error",
                                    }
                                )

                                local apigwerr = plugin._validate_user(100, bk_resource_auth, user, app, nil, false)
                                assert.is_nil(apigwerr)
                            end
                        )

                        it(
                            "user verification required with unverified user, while app is exempted", function()
                                local bk_resource_auth = context_resource_bkauth.new(
                                    {
                                        skip_user_verification = false,
                                        verified_user_required = true,
                                    }
                                )
                                local user = bk_user_define.new_user(
                                    {
                                        verified = false,
                                        valid_error_message = "error",
                                    }
                                )
                                local app = bk_app_define.new_app(
                                    {
                                        app_code = "foo",
                                        verified = false,
                                        valid_error_message = "error",
                                    }
                                )
                                local apigwerr = plugin._validate_user(
                                    100, bk_resource_auth, user, app, {
                                        by_gateway = {
                                            foo = true,
                                        },
                                        bk_resource = {},
                                    }, false
                                )
                                assert.is_nil(apigwerr)
                            end
                        )

                        it(
                            "user verification required with verified user", function()
                                local bk_resource_auth = context_resource_bkauth.new(
                                    {
                                        skip_user_verification = false,
                                        verified_user_required = true,
                                    }
                                )
                                local user = bk_user_define.new_user(
                                    {
                                        verified = true,
                                    }
                                )
                                local app = bk_app_define.new_app(
                                    {
                                        app_code = "foo",
                                    }
                                )

                                local apigwerr = plugin._validate_user(100, bk_resource_auth, user, app, nil, false)
                                assert.is_nil(apigwerr)
                            end
                        )
                    end
                )

                context(
                    "validate fail", function()
                        it(
                            "user verification required with unverified user", function()
                                local bk_resource_auth = context_resource_bkauth.new(
                                    {
                                        skip_user_verification = false,
                                        verified_user_required = true,
                                    }
                                )
                                local user = bk_user_define.new_user(
                                    {
                                        verified = false,
                                        valid_error_message = "error",
                                    }
                                )
                                local app = bk_app_define.new_app(
                                    {
                                        app_code = "foo",
                                    }
                                )

                                local apigwerr = plugin._validate_user(100, bk_resource_auth, user, app, nil, false)
                                assert.is_equal(apigwerr.status, 400)

                                apigwerr = plugin._validate_user(100, bk_resource_auth, user, app, nil, true)
                                assert.is_equal(apigwerr.status, 500)
                            end
                        )
                    end
                )
            end
        )

        context(
            "rewrite", function()
                local ctx
                local bk_app
                local bk_user

                before_each(
                    function()
                        ctx = {
                            var = {
                                bk_gateway_name = "my-gateway",
                                bk_stage_name = "my-stage",
                                bk_resource_auth = context_resource_bkauth.new(
                                    {
                                        verified_app_required = true,
                                        verified_user_required = true,
                                    }
                                ),
                            },
                        }
                        bk_app = bk_app_define.new_app(
                            {
                                app_code = "my-app",
                                verified = true,
                            }
                        )
                        bk_user = bk_user_define.new_user(
                            {
                                username = "admin",
                                verified = true,
                            }
                        )

                        stub(
                            bk_auth_verify_init, "verify_app", function()
                                return bk_app, false
                            end
                        )
                        stub(
                            bk_auth_verify_init, "verify_user", function()
                                return bk_user, false
                            end
                        )

                        stub(response, "set_header")
                    end
                )

                after_each(
                    function()
                        response.set_header:revert()
                        bk_auth_verify_init.verify_app:revert()
                        bk_auth_verify_init.verify_user:revert()
                    end
                )

                it(
                    "validate app fail", function()
                        bk_app = bk_app_define.new_anonymous_app("error")

                        local status = plugin.rewrite({}, ctx)
                        assert.is_equal(status, 400)
                        assert.is_equal(ctx.var.bk_apigw_error.error.code, 1640001)
                    end
                )

                it(
                    "validate user fail", function()
                        bk_user = bk_user_define.new_anonymous_user("error")

                        local status = plugin.rewrite({}, ctx)
                        assert.is_equal(status, 400)
                        assert.is_equal(ctx.var.bk_apigw_error.error.code, 1640001)
                    end
                )

                it(
                    "ok", function()
                        plugin.rewrite({}, ctx)
                        assert.is_same(ctx.var.bk_app["app_code"], "my-app")
                        assert.is_same(ctx.var.bk_user["username"], "admin")
                        assert.is_same(ctx.var.bk_app_code, "my-app")
                        assert.is_same(ctx.var.bk_username, "admin")
                    end
                )

                it(
                    "dependencies not provided", function()
                        -- Given an empty context object, the function should still works
                        assert.is_nil(
                            plugin.rewrite(
                                {}, {
                                    var = {},
                                }
                            )
                        )
                    end
                )
            end
        )
    end
)
