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

local jwt_verifier = require("apisix.plugins.bk-auth-verify.jwt-verifier")
local access_token_utils = require("apisix.plugins.bk-auth-verify.access-token-utils")
local access_token_define = require("apisix.plugins.bk-define.access-token")
local bk_app_define = require("apisix.plugins.bk-define.app")
local bk_user_define = require("apisix.plugins.bk-define.user")
local jwt_utils = require("apisix.plugins.bk-auth-verify.jwt-utils")

describe(
    "jwt verifier", function()

        context(
            "verify_app", function()

                local verify_result, verify_err

                before_each(
                    function()
                        stub(
                            access_token_utils, "verify_access_token", function()
                                return verify_result, verify_err
                            end
                        )
                    end
                )

                after_each(
                    function()
                        access_token_utils.verify_access_token:revert()
                    end
                )

                it(
                    "verify fail", function()
                        verify_result = nil
                        verify_err = "error"

                        local app, err = jwt_verifier.new("fake-jwt-token", "fake-token"):verify_app()
                        assert.is_equal(err, "error")
                        assert.is_nil(app)
                    end
                )

                it(
                    "verify ok", function()
                        verify_result = access_token_define.new("my-app", "admin", 10)
                        verify_err = nil

                        local app, err = jwt_verifier.new("fake-jwt-token", "fake-token"):verify_app()
                        assert.is_equal(app.app_code, "my-app")
                        assert.is_true(app.verified)
                        assert.is_equal(app.valid_error_message, "")
                    end
                )
            end
        )

        context(
            "verify_user", function()
                local parse_jwt_token_result
                local parse_jwt_token_err

                before_each(
                    function()
                        stub(
                            jwt_utils, "parse_bk_jwt_token", function()
                                return parse_jwt_token_result, parse_jwt_token_err
                            end
                        )
                    end
                )

                after_each(
                    function()
                        jwt_utils.parse_bk_jwt_token:revert()
                    end
                )

                it(
                    "parse jwt_token error", function()
                        parse_jwt_token_result = nil
                        parse_jwt_token_err = "error"

                        local user, err = jwt_verifier.new("fake-jwt-token", "fake-token"):verify_user()
                        assert.is_equal(err, "parameter jwt is invalid: error")
                        assert.is_nil(user)
                    end
                )

                it(
                    "user is nil", function()
                        parse_jwt_token_result = {
                            payload = {},
                        }
                        parse_jwt_token_err = nil

                        local user, err = jwt_verifier.new("fake-jwt-token", "fake-token"):verify_user()
                        assert.is_equal(err, "parameter jwt does not indicate user information")
                        assert.is_nil(user)
                    end
                )

                it(
                    "user is not verified", function()
                        parse_jwt_token_result = {
                            payload = {
                                user = {
                                    verified = false,
                                },
                            },
                        }
                        parse_jwt_token_err = nil

                        local user, err = jwt_verifier.new("fake-jwt-token", "fake-token"):verify_user()
                        assert.is_equal(err, "the user indicated by jwt is not verified")
                        assert.is_nil(user)
                    end
                )

                it(
                    "ok", function()
                        parse_jwt_token_result = {
                            payload = {
                                user = {
                                    username = "admin",
                                    verified = true,
                                },
                            },
                        }
                        parse_jwt_token_err = nil

                        local user, err = jwt_verifier.new("fake-jwt-token", "fake-token"):verify_user()
                        assert.is_nil(err)
                        assert.is_equal(user.username, "admin")
                        assert.is_true(user.verified)
                        assert.is_equal(user.valid_error_message, "")
                    end
                )
            end
        )
    end
)
