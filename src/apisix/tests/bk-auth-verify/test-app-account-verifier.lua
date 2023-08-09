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
local auth_params_mod = require("apisix.plugins.bk-auth-verify.auth-params")
local app_account_verifier_mod = require("apisix.plugins.bk-auth-verify.app-account-verifier")
local app_account_utils = require("apisix.plugins.bk-auth-verify.app-account-utils")
local bk_app_define = require("apisix.plugins.bk-define.app")
local bk_cache = require("apisix.plugins.bk-cache.init")

describe(
    "app account verifier", function()

        local mock_signature_verifier

        before_each(
            function()
                mock_signature_verifier = nil
                stub(
                    app_account_utils, "get_signature_verifier", function()
                        return mock_signature_verifier
                    end
                )
            end
        )

        after_each(
            function()
                app_account_utils.get_signature_verifier:revert()
            end
        )

        context(
            "new", function()
                it(
                    "new", function()
                        local auth_params = auth_params_mod.new(
                            {
                                bk_app_code = "my-app",
                                bk_app_secret = "my-secret",
                            }
                        )
                        local verifier = app_account_verifier_mod.new(auth_params)
                        assert.is_same(
                            verifier, {
                                app_code = "my-app",
                                app_secret = "my-secret",
                                auth_params = {
                                    bk_app_code = "my-app",
                                    bk_app_secret = "my-secret",
                                },
                            }
                        )
                    end
                )
            end
        )

        context(
            "verify_app", function()
                it(
                    "app_code is empty", function()
                        local auth_params = auth_params_mod.new({})
                        local verifier = app_account_verifier_mod.new(auth_params)

                        local app, has_server_error = verifier:verify_app()
                        assert.is_equal(app.app_code, "")
                        assert.is_false(app.verified)
                        assert.is_equal(app.valid_error_message, "app code cannot be empty")
                        assert.is_false(has_server_error)
                    end
                )

                it(
                    "app secret is not empty", function()
                        local auth_params = auth_params_mod.new(
                            {
                                bk_app_code = "my-app",
                                bk_app_secret = "my-secret",
                            }
                        )
                        local verifier = app_account_verifier_mod.new(auth_params)

                        local mock_app = bk_app_define.new_app(
                            {
                                app_code = "mock-app",
                                verified = false,
                                valid_error_message = "foo",
                            }
                        )
                        stub(
                            verifier, "verify_by_app_secret", function()
                                return mock_app, false
                            end
                        )

                        local app, has_server_error = verifier:verify_app()
                        assert.is_equal(app.app_code, "mock-app")
                        assert.is_false(app.verified)
                        assert.is_equal(app.valid_error_message, "foo")
                        assert.is_false(has_server_error)
                    end
                )

                it(
                    "signature verifier exist", function()
                        mock_signature_verifier = {}

                        local auth_params = auth_params_mod.new(
                            {
                                bk_app_code = "my-app",
                            }
                        )
                        local verifier = app_account_verifier_mod.new(auth_params)

                        local mock_app = bk_app_define.new_app(
                            {
                                app_code = "mock-app",
                                verified = false,
                                valid_error_message = "foo",
                            }
                        )
                        stub(
                            verifier, "verify_by_signature", function()
                                return mock_app, false
                            end
                        )

                        local app, has_server_error = verifier:verify_app()
                        assert.is_equal(app.app_code, "mock-app")
                        assert.is_false(app.verified)
                        assert.is_equal(app.valid_error_message, "foo")
                        assert.is_false(has_server_error)
                    end
                )

                it(
                    "no bk_app_secret, no signature", function()
                        mock_signature_verifier = nil

                        local auth_params = auth_params_mod.new(
                            {
                                bk_app_code = "my-app",
                            }
                        )
                        local verifier = app_account_verifier_mod.new(auth_params)
                        local app, has_server_error = verifier:verify_app()
                        assert.is_equal(app.app_code, "my-app")
                        assert.is_false(app.verified)
                        assert.is_equal(
                            app.valid_error_message, "please provide bk_app_secret or bk_signature to verify app"
                        )
                        assert.is_false(has_server_error)
                    end
                )
            end
        )

        context(
            "verify_by_signature", function()
                local list_app_secrets_result, list_app_secrets_err
                local verifier

                before_each(
                    function()
                        stub(
                            bk_cache, "list_app_secrets", function()
                                return list_app_secrets_result, list_app_secrets_err
                            end
                        )

                        local auth_params = auth_params_mod.new(
                            {
                                bk_app_code = "my-app",
                            }
                        )
                        verifier = app_account_verifier_mod.new(auth_params)
                    end
                )

                after_each(
                    function()
                        bk_cache.list_app_secrets:revert()
                    end
                )

                it(
                    "list app secrets error", function()
                        list_app_secrets_result = nil
                        list_app_secrets_err = "error"

                        local app, has_server_error = verifier:verify_by_signature({})
                        assert.is_equal(app.app_code, "my-app")
                        assert.is_false(app.verified)
                        assert.is_equal(app.valid_error_message, "error")
                        assert.is_true(has_server_error)
                    end
                )

                it(
                    "has error_message", function()
                        list_app_secrets_result = {
                            error_message = "error",
                        }
                        list_app_secrets_err = nil

                        local app, has_server_error = verifier:verify_by_signature({})
                        assert.is_equal(app.app_code, "my-app")
                        assert.is_false(app.verified)
                        assert.is_equal(app.valid_error_message, "error")
                        assert.is_false(has_server_error)
                    end
                )

                it(
                    "app not exist", function()
                        list_app_secrets_result = {
                            app_secrets = {},
                        }
                        list_app_secrets_err = nil

                        local app, has_server_error = verifier:verify_by_signature({})
                        assert.is_equal(app.app_code, "my-app")
                        assert.is_false(app.verified)
                        assert.is_equal(app.valid_error_message, "app not found")
                        assert.is_false(has_server_error)
                    end
                )

                it(
                    "signature verify error", function()
                        list_app_secrets_result = {
                            app_secrets = {
                                "secret",
                            },
                        }
                        list_app_secrets_err = nil

                        local app, has_server_error = verifier:verify_by_signature(
                            {
                                verify = function(self)
                                    return false, "verify error"
                                end,
                            }
                        )
                        assert.is_equal(app.app_code, "my-app")
                        assert.is_false(app.verified)
                        assert.is_equal(app.valid_error_message, "verify error")
                        assert.is_false(has_server_error)
                    end
                )

                it(
                    "signature verify error", function()
                        list_app_secrets_result = {
                            app_secrets = {
                                "secret",
                            },
                        }
                        list_app_secrets_err = nil

                        local app, has_server_error = verifier:verify_by_signature(
                            {
                                verify = function(self)
                                    return false
                                end,
                            }
                        )
                        assert.is_equal(app.app_code, "my-app")
                        assert.is_false(app.verified)
                        assert.is_equal(
                            app.valid_error_message,
                            "signature [bk_signature] verification failed, please provide valid bk_signature"
                        )
                        assert.is_false(has_server_error)
                    end
                )

                it(
                    "ok", function()
                        list_app_secrets_result = {
                            app_secrets = {
                                "secret",
                            },
                        }
                        list_app_secrets_err = nil

                        local app, has_server_error = verifier:verify_by_signature(
                            {
                                verify = function(self)
                                    return true
                                end,
                            }
                        )
                        assert.is_equal(app.app_code, "my-app")
                        assert.is_true(app.verified)
                        assert.is_equal(app.valid_error_message, "")
                        assert.is_false(has_server_error)
                    end
                )
            end
        )

        context(
            "verify_by_app_secret", function()
                local verify_app_secret_result
                local verify_app_secret_err
                local verifier

                before_each(
                    function()
                        stub(
                            bk_cache, "verify_app_secret", function()
                                return verify_app_secret_result, verify_app_secret_err
                            end
                        )

                        local auth_params = auth_params_mod.new(
                            {
                                bk_app_code = "my-app",
                                bk_app_secret = "my-secret",
                            }
                        )
                        verifier = app_account_verifier_mod.new(auth_params)
                    end
                )

                after_each(
                    function()
                        bk_cache.verify_app_secret:revert()
                    end
                )

                it(
                    "verify app secret error", function()
                        verify_app_secret_result = nil
                        verify_app_secret_err = "error"

                        local app, has_server_error = verifier:verify_by_app_secret()
                        assert.is_equal(app.app_code, "my-app")
                        assert.is_false(app.verified)
                        assert.is_equal(app.valid_error_message, "error")
                        assert.is_true(has_server_error)
                    end
                )

                it(
                    "has error_message", function()
                        verify_app_secret_result = {
                            error_message = "error",
                        }
                        verify_app_secret_err = nil

                        local app, has_server_error = verifier:verify_by_app_secret()
                        assert.is_equal(app.app_code, "my-app")
                        assert.is_false(app.verified)
                        assert.is_equal(app.valid_error_message, "error")
                        assert.is_false(has_server_error)
                    end
                )

                it(
                    "app not exist", function()
                        verify_app_secret_result = {
                            existed = false,
                            verified = false,
                        }
                        verify_app_secret_err = nil

                        local app, has_server_error = verifier:verify_by_app_secret()
                        assert.is_equal(app.app_code, "my-app")
                        assert.is_false(app.verified)
                        assert.is_equal(app.valid_error_message, "app not found")
                        assert.is_false(has_server_error)
                    end
                )

                it(
                    "verify false", function()
                        verify_app_secret_result = {
                            existed = true,
                            verified = false,
                        }
                        verify_app_secret_err = nil

                        local app, has_server_error = verifier:verify_by_app_secret()
                        assert.is_equal(app.app_code, "my-app")
                        assert.is_false(app.verified)
                        assert.is_equal(app.valid_error_message, "bk_app_code or bk_app_secret is incorrect")
                        assert.is_false(has_server_error)
                    end
                )

                it(
                    "ok", function()
                        verify_app_secret_result = {
                            existed = true,
                            verified = true,
                        }
                        verify_app_secret_err = nil

                        local app, has_server_error = verifier:verify_by_app_secret()
                        assert.is_equal(app.app_code, "my-app")
                        assert.is_true(app.verified)
                        assert.is_equal(app.valid_error_message, "")
                        assert.is_false(has_server_error)
                    end
                )
            end
        )
    end
)
