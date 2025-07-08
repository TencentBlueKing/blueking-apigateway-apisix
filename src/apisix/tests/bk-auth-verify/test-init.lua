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

local bk_auth_verify_mod = require("apisix.plugins.bk-auth-verify.init")
local auth_params_mod = require("apisix.plugins.bk-auth-verify.auth-params")
local bk_core = require("apisix.plugins.bk-core.init")
local access_token_verifier = require("apisix.plugins.bk-auth-verify.access-token-verifier")
local jwt_verifier = require("apisix.plugins.bk-auth-verify.jwt-verifier")
local legacy_verifier = require("apisix.plugins.bk-auth-verify.legacy-verifier")
local bk_user_define = require("apisix.plugins.bk-define.user")
local bk_app_define = require("apisix.plugins.bk-define.app")
local context_api_bkauth = require("apisix.plugins.bk-define.context-api-bkauth")
local context_resource_bkauth = require("apisix.plugins.bk-define.context-resource-bkauth")

describe(
    "bk-auth-verify", function()

        local auth_params
        local bk_api_auth
        local bk_resource_auth
        local bk_app

        before_each(
            function()
                auth_params = auth_params_mod.new({})
                bk_api_auth = context_api_bkauth.new(
                    {
                        api_type = 10,
                        unfiltered_sensitive_keys = {"a", "b"},
                        rtx_conf = {},
                        uin_conf = {},
                        user_conf = {},
                    }
                )
                bk_resource_auth = context_resource_bkauth.new(
                    {
                        skip_user_verification = false,
                    }
                )
                bk_app = bk_app_define.new_app(
                    {
                        app_code = "my-app",
                        verified = true,
                    }
                )
                bk_auth_verify = bk_auth_verify_mod.new(auth_params, bk_api_auth, bk_resource_auth, bk_app)
            end
        )

        after_each(
            function()
            end
        )

        context(
            "verify_app", function()
                it(
                    "ok", function()
                        local verifier = access_token_verifier.new("fake-token", bk_app)
                        stub(bk_auth_verify, "get_real_verifier", verifier)
                        stub(verifier, "verify_app", bk_app)

                        local app = bk_auth_verify:verify_app()
                        assert.is_equal(app.app_code, "my-app")

                        bk_auth_verify.get_real_verifier:revert()
                        verifier.verify_app:revert()
                    end
                )
            end
        )

        context(
            "verify_user", function()
                it(
                    "skip user verification", function()
                        bk_resource_auth.skip_user_verification = true

                        local user, err = bk_auth_verify:verify_user()
                        assert.is_nil(err)
                        assert.is_equal(user.username, "")
                        assert.is_false(user.verified)
                        assert.is_equal(user.valid_error_message, "")
                    end
                )

                it(
                    "verify user error", function()
                        local verifier = access_token_verifier.new("fake-token", bk_app)
                        stub(bk_auth_verify, "get_real_verifier", verifier)
                        stub(
                            verifier, "verify_user", function()
                                return nil, "error"
                            end
                        )

                        local user, err = bk_auth_verify:verify_user()
                        assert.is_equal(err, "error")
                        assert.is_nil(user)

                        bk_auth_verify.get_real_verifier:revert()
                        verifier.verify_user:revert()
                    end
                )

                it(
                    "verify user ok", function()
                        local verifier = access_token_verifier.new("fake-token", bk_app)
                        stub(bk_auth_verify, "get_real_verifier", verifier)

                        local mock_user = bk_user_define.new_user(
                            {
                                username = "mock-admin",
                                verified = true,
                            }
                        )
                        stub(verifier, "verify_user", mock_user)

                        local user, err = bk_auth_verify:verify_user()
                        assert.is_nil(err)
                        assert.is_equal(user.username, "mock-admin")

                        bk_auth_verify.get_real_verifier:revert()
                        verifier.verify_user:revert()
                    end
                )
            end
        )

        context(
            "get_real_verifier", function()
                it(
                    "jwt verifier", function()
                        auth_params.jwt = "fake-jwt"

                        local verifier = bk_auth_verify:get_real_verifier()
                        assert.is_equal(verifier.name, "jwt")
                    end
                )

                it(
                    "access_token verifier", function()
                        auth_params.access_token = "fake-token"

                        local verifier = bk_auth_verify:get_real_verifier()
                        assert.is_equal(verifier.name, "access_token")
                    end
                )

                it(
                    "inner-jwt-verifier", function()
                        auth_params.inner_jwt = "fake-inner-jwt"

                        local verifier = bk_auth_verify:get_real_verifier()
                        assert.is_equal(verifier.name, "inner-jwt")
                    end
                )

                it(
                    "legacy verifier", function()
                        local verifier = bk_auth_verify:get_real_verifier()
                        assert.is_equal(verifier.name, "legacy")
                    end
                )
            end
        )
    end
)
