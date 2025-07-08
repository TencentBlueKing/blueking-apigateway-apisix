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

local access_token_define = require("apisix.plugins.bk-define.access-token")

describe(
    "access-token define", function()
        before_each(require("busted_resty").clear)

        context(
            "access_token", function()
                it(
                    "new", function()
                        local token = access_token_define.new("my-app", "admin", 10)
                        assert.is_same(
                            token, {
                                app_code = "my-app",
                                user_id = "admin",
                                expires_in = 10,
                            }
                        )

                        token = access_token_define.new(nil, nil, 10)
                        assert.is_same(
                            token, {
                                app_code = "",
                                user_id = "",
                                expires_in = 10,
                            }
                        )
                    end
                )

                it(
                    "get_app_code", function()
                        local token = access_token_define.new("my-app", "admin", 10)
                        assert.is_equal(token:get_app_code(), "my-app")

                        token = access_token_define.new(nil, "admin", 10)
                        assert.is_equal(token:get_app_code(), "")
                    end
                )

                it(
                    "get_user_id", function()
                        local token = access_token_define.new("my-app", "admin", 10)
                        assert.is_equal(token:get_user_id(), "admin")

                        token = access_token_define.new("my-app", nil, 10)
                        assert.is_equal(token:get_user_id(), "")
                    end
                )

                it(
                    "has_expired", function()
                        local token = access_token_define.new("my-app", "admin", 10)
                        assert.is_false(token:has_expired())

                        token = access_token_define.new("my-app", "admin", 0)
                        assert.is_true(token:has_expired())

                        token = access_token_define.new("my-app", "admin", -10)
                        assert.is_true(token:has_expired())
                    end
                )

                it(
                    "is_user_type", function()
                        local token = access_token_define.new("my-app", "", 10)
                        assert.is_false(token:is_user_token())

                        token = access_token_define.new("my-app", nil, 10)
                        assert.is_false(token:is_user_token())

                        token = access_token_define.new("my-app", "admin", 10)
                        assert.is_true(token:is_user_token())
                    end
                )
            end
        )
    end
)
