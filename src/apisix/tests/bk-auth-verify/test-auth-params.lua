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

local auth_params_mod = require("apisix.plugins.bk-auth-verify.auth-params")
local table_unpack = table.unpack

describe(
    "auth-params", function()

        local auth_params

        before_each(
            function()
                auth_params = auth_params_mod.new(
                    {
                        a = "1",
                        b = 2,
                    }
                )
            end
        )

        context(
            "get", it(
                "ok", function()
                    assert.is_equal(auth_params:get("a"), "1")
                    assert.is_equal(auth_params:get("b"), 2)
                    assert.is_nil(auth_params:get("c"))
                end
            )
        )

        context(
            "get_string", function()
                it(
                    "not exists", function()
                        local result, err = auth_params:get_string("c")
                        assert.is_equal(err, "key c not exists in auth parameters")
                        assert.is_equal(result, "")
                    end
                )

                it(
                    "not string", function()
                        local result, err = auth_params:get_string("b")
                        assert.is_equal(err, "value of key b is not a string")
                        assert.is_equal(result, "")
                    end
                )

                it(
                    "ok", function()
                        local result, err = auth_params:get_string("a")
                        assert.is_nil(err)
                        assert.is_equal(result, "1")
                    end
                )
            end
        )

        context(
            "get_first_no_nil_string_from_two_keys", function()
                it(
                    "will error", function()
                        local result, err = auth_params:get_first_no_nil_string_from_two_keys("c", "d")
                        assert.is_equal(err, "keys [c, d] are not found in auth parameters")
                    end
                )

                it(
                    "ok", function()
                        local data = {
                            {
                                keys = {
                                    "a",
                                },
                                expected = "1",
                            },
                            {
                                keys = {
                                    "a",
                                    "b",
                                },
                                expected = "1",
                            },
                            {
                                keys = {
                                    "b",
                                    "a",
                                },
                                expected = "2",
                            },
                            {
                                keys = {
                                    "a",
                                    "c",
                                },
                                expected = "1",
                            },
                            {
                                keys = {
                                    "c",
                                    "b",
                                },
                                expected = "2",
                            },
                            {
                                keys = {
                                    "b",
                                    "c",
                                },
                                expected = "2",
                            },
                        }

                        for _, item in pairs(data) do
                            local result, err = auth_params:get_first_no_nil_string_from_two_keys(
                                table_unpack(item.keys)
                            )
                            assert.is_nil(err)
                            assert.is_equal(result, item.expected)
                        end
                    end
                )
            end
        )

        it(
            "to_url_values", function()
                local result = auth_params:to_url_values()
                assert.is_same(
                    result, {
                        a = {
                            "1",
                        },
                        b = {
                            "2",
                        },
                    }
                )
            end
        )
    end
)
