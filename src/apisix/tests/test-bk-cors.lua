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

local plugin = require("apisix.plugins.bk-cors")

describe(
    "cors", function()
        local conf

        before_each(
            function()
                conf = {
                    allow_origins = "*",
                    allow_methods = "*",
                    allow_headers = "*",
                    expose_headers = "*",
                    max_age = 5,
                    allow_credential = false,
                }
            end
        )

        context(
            "check_schema", function()
                it(
                    "allow_origins", function()
                        -- nil
                        conf.allow_origins = nil
                        local ok = plugin.check_schema(conf)
                        assert.is_true(ok)
                        assert.is_equal(conf.allow_origins, "*")

                        -- null
                        conf.allow_origins = "null"
                        ok = plugin.check_schema(conf)
                        assert.is_true(ok)
                        assert.is_equal(conf.allow_origins, "null")

                        -- invalid
                        conf.allow_origins = ""
                        ok = plugin.check_schema(conf)
                        assert.is_false(ok)
                    end
                )

                it(
                    "expose_headers", function()
                        -- nil
                        conf.expose_headers = nil
                        local ok = plugin.check_schema(conf)
                        assert.is_true(ok)
                        assert.is_equal(conf.expose_headers, "*")

                        -- empty
                        conf.expose_headers = ""
                        ok = plugin.check_schema(conf)
                        assert.is_true(ok)
                        assert.is_equal(conf.expose_headers, "")
                    end
                )
            end
        )
    end
)
