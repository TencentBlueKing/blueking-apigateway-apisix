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
local app_account_verifier = require("apisix.plugins.bk-auth-verify.app-account-verifier")
local access_token_verifier = require("apisix.plugins.bk-auth-verify.access-token-verifier")
local access_token_utils = require("apisix.plugins.bk-auth-verify.access-token-utils")
local auth_params_mod = require("apisix.plugins.bk-auth-verify.auth-params")
local access_token_define = require("apisix.plugins.bk-define.access-token")
local bk_app_define = require("apisix.plugins.bk-define.app")

describe(
    "access_token_verifier", function()
        before_each(require("busted_resty").clear)

        local verify_result, verify_err, verify_is_server_error

        before_each(
            function()
                verify_result = nil
                verify_err = nil
                verify_is_server_error = nil

                stub(
                    access_token_utils, "verify_access_token", function()
                        return verify_result, verify_err, verify_is_server_error
                    end
                )
            end
        )

        after_each(
            function()
                access_token_utils.verify_access_token:revert()
            end
        )

        context(
            "verify_app", function()
                it(
                    "verify ok", function()
                        verify_result = access_token_define.new("my-app", "admin", 10)
                        verify_err = nil
                        verify_is_server_error = nil

                        local app, has_server_error = access_token_verifier.new("fake-token", nil):verify_app()
                        assert.is_equal(app.app_code, "my-app")
                        assert.is_true(app.verified)
                        assert.is_equal(app.valid_error_message, "")
                        assert.is_false(has_server_error)
                    end
                )

                it(
                    "bkapp is verified", function()
                        verify_result = nil
                        verify_err = "error"
                        verify_is_server_error = false

                        stub(
                            app_account_verifier, "verify_app", function()
                                return bk_app_define.new_app(
                                    {
                                        app_code = "my-app",
                                        verified = true,
                                        valid_error_message = "ok",
                                    }
                                )
                            end
                        )

                        local verifier = access_token_verifier.new("fake-token", auth_params_mod.new({}))
                        local app, has_server_error = verifier:verify_app()
                        assert.is_equal(app.app_code, "my-app")
                        assert.is_true(app.verified)
                        assert.is_equal(app.valid_error_message, "ok")
                        assert.is_false(has_server_error)

                        app_account_verifier.verify_app:revert()
                    end
                )

                it(
                    "bkapp is not verified", function()
                        verify_result = nil
                        verify_err = "error"
                        verify_is_server_error = false

                        stub(
                            app_account_verifier, "verify_app", function()
                                return bk_app_define.new_app(
                                    {
                                        app_code = "my-app",
                                        verified = false,
                                        valid_error_message = "fail",
                                    }
                                )
                            end
                        )
                        local verifier = access_token_verifier.new("fake-token", auth_params_mod.new({}))
                        local app, has_server_error = verifier:verify_app()
                        assert.is_equal(app.app_code, "")
                        assert.is_false(app.verified)
                        assert.is_equal(app.valid_error_message, "error")
                        assert.is_false(has_server_error)

                        verify_is_server_error = true
                        app, has_server_error = verifier:verify_app()
                        assert.is_equal(app.app_code, "")
                        assert.is_false(app.verified)
                        assert.is_equal(app.valid_error_message, "error")
                        assert.is_true(has_server_error)

                        app_account_verifier.verify_app:revert()
                    end
                )
            end
        )

        context(
            "verify_user", function()
                it(
                    "verify fail", function()
                        verify_result = nil
                        verify_err = "error"
                        verify_is_server_error = false

                        local user, has_server_error = access_token_verifier.new("fake-token", {}):verify_user()
                        assert.is_equal(user.username, "")
                        assert.is_false(user.verified)
                        assert.is_equal(user.valid_error_message, "error")
                        assert.is_false(has_server_error)

                        verify_is_server_error = true
                        user, has_server_error = access_token_verifier.new("fake-token", {}):verify_user()
                        assert.is_equal(user.username, "")
                        assert.is_false(user.verified)
                        assert.is_equal(user.valid_error_message, "error")
                        assert.is_true(has_server_error)
                    end
                )

                it(
                    "is not user token", function()
                        verify_result = access_token_define.new("my-app", "", 10)
                        verify_err = nil
                        verify_is_server_error = nil

                        local user, has_server_error = access_token_verifier.new("fake-token", {}):verify_user()
                        assert.is_equal(user.username, "")
                        assert.is_false(user.verified)
                        assert.is_equal(
                            user.valid_error_message,
                            "the access_token is the application type and cannot indicate the user"
                        )
                        assert.is_false(has_server_error)
                    end
                )

                it(
                    "ok", function()
                        verify_result = access_token_define.new("my-app", "admin", 10)
                        verify_err = nil
                        verify_is_server_error = nil

                        local user, has_server_error = access_token_verifier.new("fake-token", {}):verify_user()
                        assert.is_equal(user.username, "admin")
                        assert.is_true(user.verified)
                        assert.is_equal(user.valid_error_message, "")
                        assert.is_false(has_server_error)
                    end
                )
            end
        )
    end
)
