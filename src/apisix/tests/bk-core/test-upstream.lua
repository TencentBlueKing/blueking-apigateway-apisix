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

local bk_upstream = require("apisix.plugins.bk-core.upstream")

describe(
    "bk_upstream", function()

        context(
            "get_last_item", function()
                it(
                    "empty string", function()
                        assert.is_nil(bk_upstream._get_last_item(""))
                    end
                )

                it(
                    "does not have seperator", function()
                        assert.is_equal("asd", bk_upstream._get_last_item("asd"))
                    end
                )

                it(
                    "have seperator", function()
                        assert.is_equal("asd", bk_upstream._get_last_item("aa, bb, cc, asd"))
                    end
                )
            end
        )

        it(
            "get_last_upstream_bytes_received", function()
                assert.is_equal(
                    0, bk_upstream.get_last_upstream_bytes_received(
                        CTX(
                            {
                                upstream_bytes_received = "-, 0",
                            }
                        )
                    )
                )

                assert.is_nil(
                    bk_upstream.get_last_upstream_bytes_received(
                        CTX(
                            {
                                upstream_bytes_received = "0, -",
                            }
                        )
                    )
                )
            end
        )

    end
)
