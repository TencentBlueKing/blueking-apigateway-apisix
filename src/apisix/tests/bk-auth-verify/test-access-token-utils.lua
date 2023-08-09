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
local access_token_utils = require("apisix.plugins.bk-auth-verify.access-token-utils")
local access_token_define = require("apisix.plugins.bk-define.access-token")
local bk_cache = require("apisix.plugins.bk-cache.init")

describe(
    "access_token utils", function()

        local get_access_token_result
        local get_access_token_err

        before_each(
            function()
                get_access_token_result = nil
                get_access_token_err = nil

                stub(
                    bk_cache, "get_access_token", function()
                        return get_access_token_result, get_access_token_err
                    end
                )
            end
        )

        after_each(
            function()
                bk_cache.get_access_token:revert()
            end
        )

        context(
            "verify_access_token", function()
                it(
                    "access_token is empty", function()
                        local token, err, is_server_error = access_token_utils.verify_access_token("")
                        assert.is_nil(token)
                        assert.is_equal(err, "access_token cannot be empty")
                        assert.is_false(is_server_error)

                        token, err, is_server_error = access_token_utils.verify_access_token(nil)
                        assert.is_nil(token)
                        assert.is_equal(err, "access_token cannot be empty")
                        assert.is_false(is_server_error)
                    end
                )

                it(
                    "get token from cache fail", function()
                        get_access_token_result = nil
                        get_access_token_err = "error"

                        local result, err, is_server_error = access_token_utils.verify_access_token("fake-token")
                        assert.is_nil(result)
                        assert.is_equal(err, "error")
                        assert.is_true(is_server_error)
                    end
                )

                it(
                    "has error_message", function()
                        get_access_token_result = {
                            error_message = "error",
                        }
                        get_access_token_err = nil

                        local result, err, is_server_error = access_token_utils.verify_access_token("fake-token")
                        assert.is_nil(result)
                        assert.is_equal(err, "error")
                        assert.is_false(is_server_error)
                    end
                )

                it(
                    "token is expired, and it is a user token", function()
                        get_access_token_result = {
                            token = access_token_define.new("my-app", "admin", -10),
                        }
                        get_access_token_err = nil

                        local result, err, is_server_error = access_token_utils.verify_access_token("fake-token")
                        assert.is_nil(result)
                        assert.is_equal(err, "the access_token of the user(admin) has expired, please re-authorize")
                        assert.is_false(is_server_error)
                    end
                )

                it(
                    "token is expired, and it is not a user token", function()
                        get_access_token_result = {
                            token = access_token_define.new("my-app", "", -10),
                        }
                        get_access_token_err = nil

                        local result, err, is_server_error = access_token_utils.verify_access_token("fake-token")
                        assert.is_nil(result)
                        assert.is_equal(err, "access_token has expired")
                        assert.is_false(is_server_error)
                    end
                )

                it(
                    "ok", function()
                        get_access_token_result = {
                            token = access_token_define.new("my-app", "admin", 10),
                        }
                        get_access_token_err = nil

                        local result, err, is_server_error = access_token_utils.verify_access_token("fake-token")
                        assert.is_nil(err)
                        assert.is_same(
                            result, {
                                app_code = "my-app",
                                user_id = "admin",
                                expires_in = 10,
                            }
                        )
                        assert.is_nil(is_server_error)
                    end
                )
            end
        )
    end
)
