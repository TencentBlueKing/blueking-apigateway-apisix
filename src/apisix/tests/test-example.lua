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

describe(
    "some assertions", function()
        it(
            "tests positive assertions", function()
                assert.is_true(true)
            end
        )

        it(
            "tests negative assertions", function()
                assert.is_false(false)
            end
        )

        it(
            "tests equal assertions", function()
                assert.is_equal(1, 1)
                assert.is_equal("hello", "hello")

                assert.is_not_equal(
                    {
                        foo = "bar",
                    }, {
                        foo = "bar",
                    }
                )

                local foo = {
                    foo = "bar",
                }
                local bar = foo
                assert.is_equal(foo, bar)
            end
        )

        it(
            "tests same assertions", function()
                assert.is_same(1, 1)
                assert.is_same("hello", "hello")
                assert.is_same(
                    {
                        foo = "bar",
                    }, {
                        foo = "bar",
                    }
                )

                local foo = {
                    foo = "bar",
                }
                local bar = foo
                assert.is_same(foo, bar)
            end
        )

        it(
            "test table", function()
                local result = {
                    "hi",
                    nil,
                }
                assert.is_equal(result[1], "hi")
                assert.is_equal(result[2], nil)

                result = {
                    {
                        "foo",
                    },
                    "error",
                }
                assert.is_same(
                    result[1], {
                        "foo",
                    }
                )
                assert.is_equal(result[2], "error")
            end
        )

        it(
            "table concat", function()
                assert.is_equal(
                    table.concat(
                        {
                            "foo",
                            "bar",
                            123,
                        }, ":"
                    ), "foo:bar:123"
                )

                assert.is_equal(
                    table.concat(
                        {
                            tostring(false),
                            tostring(true),
                            tostring(nil),
                            123,
                            "foo",
                        }, ":"
                    ), "false:true:nil:123:foo"
                )
            end
        )
    end
)
