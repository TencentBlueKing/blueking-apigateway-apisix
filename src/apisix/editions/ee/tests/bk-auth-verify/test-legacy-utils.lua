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

local legacy_utils = require("apisix.plugins.bk-auth-verify.legacy-utils")
local access_token_utils = require("apisix.plugins.bk-auth-verify.access-token-utils")
local access_token_define = require("apisix.plugins.bk-define.access-token")
local bk_cache = require("apisix.plugins.bk-cache.init")

describe(
    "legacy utils", function()

        context(
            "verify_by_bk_token", function()
                local get_username_result, get_username_err
                before_each(
                    function()
                        stub(
                            bk_cache, "get_username_by_bk_token", function()
                                return get_username_result, get_username_err
                            end
                        )
                    end
                )

                after_each(
                    function()
                        bk_cache.get_username_by_bk_token:revert()
                    end
                )

                it(
                    "fail", function()
                        get_username_result = nil
                        get_username_err = "error"

                        local user, err = legacy_utils.verify_by_bk_token("fake-token")
                        assert.is_equal(err, "error")
                        assert.is_nil(user)
                    end
                )

                it(
                    "ok", function()
                        get_username_result = "admin"
                        get_username_err = nil

                        local user, err = legacy_utils.verify_by_bk_token("fake-token")
                        assert.is_nil(err)
                        assert.is_equal(user.username, "admin")
                        assert.is_true(user.verified)
                    end
                )
            end
        )

        context(
            "verify_by_username", function()
                it(
                    "ok", function()
                        local user, err = legacy_utils.verify_by_username("admin")
                        assert.is_nil(err)
                        assert.is_equal(user.username, "admin")
                        assert.is_false(user.verified)
                        assert.is_equal(
                            user.valid_error_message,
                            "user authentication failed, the user indicated by bk_username is not verified"
                        )
                    end
                )
            end
        )
    end
)
