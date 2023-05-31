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
local plugin = require("apisix.plugin")
local real_ip = require("apisix.plugins.bk-real-ip")
local base = require("apisix.plugins.real-ip")

describe(
    "bk-real-ip", function()
        context(
            "check_schema", function()
                it(
                    "should check metadata by schema", function()
                        assert.is_true(
                            real_ip.check_schema(
                                {
                                    source = "http_x_forwarded_for",
                                }, core.schema.TYPE_METADATA
                            )
                        )
                    end
                )

                it(
                    "should always return true", function()
                        assert.is_true(real_ip.check_schema({}))
                    end
                )
            end
        )

        context(
            "rewrite", function()
                local metadata, actual_conf

                before_each(
                    function()
                        metadata = {}

                        stub(
                            plugin, "plugin_metadata", function()
                                return metadata
                            end
                        )
                        stub(
                            base, "rewrite", function(conf)
                                actual_conf = conf
                            end
                        )
                    end
                )

                after_each(
                    function()
                        plugin.plugin_metadata:revert()
                        base.rewrite:revert()
                    end
                )

                it(
                    "should use default config when metadata is missing", function()
                        metadata = nil

                        real_ip.rewrite({}, {})

                        assert.same(
                            {
                                source = "http_x_forwarded_for",
                                recursive = false,
                            }, actual_conf
                        )
                    end
                )

                it(
                    "should use metadata", function()
                        metadata = {
                            value = {
                                source = "http_x_forwarded_for",
                                recursive = true,
                            },
                        }

                        real_ip.rewrite({}, {})

                        assert.same(metadata.value, actual_conf)
                    end
                )
            end
        )
    end
)
