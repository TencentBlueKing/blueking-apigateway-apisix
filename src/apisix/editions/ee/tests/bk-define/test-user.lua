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
local bk_user_define = require("apisix.plugins.bk-define.user")

describe(
    "user", function()

        local bk_user

        before_each(
            function()
                bk_user = bk_user_define.new_user(
                    {
                        username = "admin",
                        verified = true,
                        valid_error_message = "",
                    }
                )
            end
        )

        context(
            "user", function()
                it(
                    "new user", function()
                        assert.is_same(
                            bk_user, {
                                version = 1,
                                username = "admin",
                                verified = true,
                                valid_error_message = "",
                            }
                        )

                        local user = bk_user_define.new_user({})
                        assert.is_same(
                            user, {
                                version = 1,
                                username = "",
                                verified = false,
                                valid_error_message = "",
                            }
                        )
                    end
                )

                it(
                    "new anonymous user", function()
                        local user = bk_user_define.new_anonymous_user("error")
                        assert.is_same(
                            user, {
                                version = 1,
                                username = "",
                                verified = false,
                                valid_error_message = "error",
                            }
                        )
                    end
                )

                it(
                    "uid", function()
                        local id1 = bk_user:uid()
                        local id2 = bk_user:uid()

                        assert.is_equal(id1, "16f662fd0e0528543ea773816c33879a")
                        assert.is_equal(id1, id2)

                        bk_user.verified = false
                        local id3 = bk_user:uid()
                        assert.is_not_equal(id1, id3)
                    end
                )

                it(
                    "get_username", function()
                        assert.is_equal(bk_user:get_username(), "admin")

                        bk_user.username = ""
                        assert.is_equal(bk_user:get_username(), "")
                    end
                )

                it(
                    "is_verified", function()
                        assert.is_true(bk_user:is_verified())

                        bk_user.verified = false
                        assert.is_false(bk_user:is_verified())
                    end
                )

                it(
                    "encode json", function()
                        local user_json = core.json.encode(bk_user)
                        assert.is_not_nil(user_json)

                        local user = core.json.decode(user_json)
                        assert.is_same(
                            user, {
                                version = 1,
                                username = "admin",
                                verified = true,
                                valid_error_message = "",
                            }
                        )
                    end
                )
            end
        )
    end
)
