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
local bk_core = require("apisix.plugins.bk-core.init")
local legacy_verifier = require("apisix.plugins.bk-auth-verify.legacy-verifier")
local legacy_utils = require("apisix.plugins.bk-auth-verify.legacy-utils")
local auth_params_mod = require("apisix.plugins.bk-auth-verify.auth-params")
local app_account_verifier = require("apisix.plugins.bk-auth-verify.app-account-verifier")
local bk_app_define = require("apisix.plugins.bk-define.app")
local bk_user_define = require("apisix.plugins.bk-define.user")
local context_api_bkauth = require("apisix.plugins.bk-define.context-api-bkauth")

describe(
    "legacy verifier", function()

        local bk_api_auth
        local auth_params
        local verifier
        local mock_user

        before_each(
            function()
                bk_api_auth = context_api_bkauth.new(
                    {
                        api_type = 10,
                        unfiltered_sensitive_keys = {
                            "a",
                            "b",
                        },
                        rtx_conf = {},
                        uin_conf = {},
                        user_conf = {
                            user_type = "bkuser",
                            from_bk_token = true,
                            from_username = true,
                        },
                    }
                )
                auth_params = auth_params_mod.new({})
                verifier = legacy_verifier.new(bk_api_auth, auth_params)
                mock_user = bk_user_define.new_user(
                    {
                        username = "mock-admin",
                        verified = true,
                    }
                )
            end
        )

        context(
            "verify_app", function()
                it(
                    "no user type", function()
                        bk_api_auth.user_conf.user_type = ""

                        local app, has_server_error = verifier:verify_app()
                        assert.is_equal(app.app_code, "")
                        assert.is_false(app.verified)
                        assert.is_equal(
                            app.valid_error_message,
                            "the gateway configuration error, please contact the API Gateway developer to handle"
                        )
                        assert.is_true(has_server_error)
                    end
                )

                it(
                    "verify app ok", function()
                        stub(
                            app_account_verifier, "new", {
                                verify_app = function()
                                    return bk_app_define.new_app(
                                        {
                                            app_code = "test",
                                            verified = true,
                                        }
                                    ), false
                                end,
                            }
                        )
                        local app, has_server_error = verifier:verify_app()
                        assert.is_equal(app.app_code, "test")
                        assert.is_true(app.verified)
                        assert.is_equal(app.valid_error_message, "")
                        assert.is_false(has_server_error)

                        app_account_verifier.new:revert()
                    end
                )
            end
        )

        context(
            "verify_user", function()
                it(
                    "no_user_type", function()
                        bk_api_auth.user_conf.user_type = ""

                        local user, has_server_error = verifier:verify_user()
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
                    "verify user", function()
                        stub(
                            verifier, "verify_bk_user", function()
                                return mock_user, false
                            end
                        )

                        local user, has_server_error = verifier:verify_user()
                        assert.is_equal(user.username, "mock-admin")
                        assert.is_true(user.verified)
                        assert.is_equal(user.valid_error_message, "")
                        assert.is_false(has_server_error)

                        verifier.verify_bk_user:revert()
                    end
                )
            end
        )

        context(
            "verify_bk_user", function()
                it(
                    "from_bk_token is true, bk_token in auth_params is not empty", function()
                        bk_api_auth.user_conf.from_bk_token = true
                        auth_params.bk_token = "fake-token"

                        stub(
                            legacy_utils, "verify_by_bk_token", function()
                                return mock_user, false
                            end
                        )

                        local user, has_server_error = verifier:verify_bk_user(bk_api_auth.user_conf)
                        assert.is_equal(user.username, "mock-admin")
                        assert.is_true(user.verified)
                        assert.is_false(has_server_error)

                        legacy_utils.verify_by_bk_token:revert()
                    end
                )

                it(
                    "from_bk_token is true, bk_token in cookie", function()
                        bk_api_auth.user_conf.from_bk_token = true
                        auth_params.bk_token = ""

                        stub(bk_core.cookie, "get_value", "fake-token")
                        stub(
                            legacy_utils, "verify_by_bk_token", function()
                                return mock_user, false
                            end
                        )

                        local user, has_server_error = verifier:verify_bk_user(bk_api_auth.user_conf)
                        assert.is_equal(user.username, "mock-admin")
                        assert.is_true(user.verified)
                        assert.is_false(has_server_error)

                        bk_core.cookie.get_value:revert()
                        legacy_utils.verify_by_bk_token:revert()
                    end
                )

                it(
                    "from_username is true", function()
                        bk_api_auth.user_conf.from_username = true
                        auth_params.bk_username = "admin"

                        local user, has_server_error = verifier:verify_bk_user(bk_api_auth.user_conf)
                        assert.is_equal(user.username, "admin")
                        assert.is_false(user.verified)
                        assert.is_false(has_server_error)
                    end
                )

                it(
                    "no user check", function()
                        local user, has_server_error = verifier:verify_bk_user(bk_api_auth.user_conf)
                        assert.is_equal(user.username, "")
                        assert.is_false(user.verified)
                        assert.is_equal(
                            user.valid_error_message,
                            "user authentication failed, please provide a valid user identity, such as bk_username, bk_token, access_token"
                        )
                        assert.is_false(has_server_error)
                    end
                )
            end
        )
    end
)
