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

local core = require("apisix.core")
local bk_app_define = require("apisix.plugins.bk-define.app")

describe(
    "app define", function()

        local bk_app

        before_each(
            function()
                bk_app = bk_app_define.new_base_app(
                    {
                        app_code = "test",
                        verified = true,
                        valid_error_message = "",
                    }
                )
            end
        )

        context(
            "app", function()
                it(
                    "new app", function()
                        assert.is_same(
                            bk_app, {
                                version = 1,
                                app_code = "test",
                                verified = true,
                                valid_error_message = "",
                            }
                        )

                        -- new app, with some app info
                        local app = bk_app_define.new_app(
                            {
                                app_code = "test",
                                verified = false,
                            }
                        )
                        assert.is_same(
                            app, {
                                version = 1,
                                app_code = "test",
                                verified = false,
                                valid_error_message = "",
                            }
                        )
                    end
                )

                it(
                    "new anonymous app", function()
                        local app = bk_app_define.new_anonymous_app("error")
                        assert.is_same(
                            app, {
                                version = 1,
                                app_code = "",
                                verified = false,
                                valid_error_message = "error",
                            }
                        )

                        app = bk_app_define.new_anonymous_app()
                        assert.is_same(
                            app, {
                                version = 1,
                                app_code = "",
                                verified = false,
                                valid_error_message = "",
                            }
                        )
                    end
                )

                it(
                    "uid", function()
                        local id1 = bk_app:uid()
                        local id2 = bk_app:uid()

                        assert.is_equal(id1, "4021ba887b41f616525e3d01b41f8167")
                        assert.is_equal(id1, id2)

                        bk_app.verified = false
                        local id3 = bk_app:uid()
                        assert.is_not_equal(id1, id3)
                    end
                )

                it(
                    "get_app_code", function()
                        assert.is_equal(bk_app:get_app_code(), "test")

                        bk_app.app_code = ""
                        assert.is_equal(bk_app:get_app_code(), "")
                    end
                )

                it(
                    "get_real_app_code", function()
                        assert.is_equal(bk_app:get_real_app_code(), "test")

                        bk_app.app_code = "v_mcp_123_real_app"
                        assert.is_equal(bk_app:get_real_app_code(), "real_app")

                        bk_app.app_code = "v_mcp_bad"
                        assert.is_equal(bk_app:get_real_app_code(), "v_mcp_bad")
                    end
                )

                it(
                    "is_verified", function()
                        assert.is_true(bk_app:is_verified())

                        bk_app.verified = false
                        assert.is_false(bk_app:is_verified())
                    end
                )

                it(
                    "encode to json", function()
                        local app_json = core.json.encode(bk_app)
                        assert.is_not_nil(app_json)

                        local app = core.json.decode(app_json)
                        assert.is_same(
                            app, {
                                version = 1,
                                app_code = "test",
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
