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
local bk_core = require("apisix.plugins.bk-core.init")

describe(
    "bk-core.config", function()
        after_each(
            function()
                if core.config.local_conf.revert then
                    core.config.local_conf:revert()
                end
            end
        )

        context(
            "should_strip_subpath_prefix", function()
                it(
                    "should return false when value is nil", function()
                        stub(
                            core.config, "local_conf", function()
                                return { bk_gateway = {} }
                            end
                        )
                        assert.is_false(bk_core.config.should_strip_subpath_prefix())
                    end
                )

                it(
                    "should return boolean true as-is", function()
                        stub(
                            core.config, "local_conf", function()
                                return { bk_gateway = { strip_subpath_prefix = true } }
                            end
                        )
                        assert.is_true(bk_core.config.should_strip_subpath_prefix())
                    end
                )

                it(
                    "should return boolean false as-is", function()
                        stub(
                            core.config, "local_conf", function()
                                return { bk_gateway = { strip_subpath_prefix = false } }
                            end
                        )
                        assert.is_false(bk_core.config.should_strip_subpath_prefix())
                    end
                )

                it(
                    "should parse lowercase true string", function()
                        stub(
                            core.config, "local_conf", function()
                                return { bk_gateway = { strip_subpath_prefix = "true" } }
                            end
                        )
                        assert.is_true(bk_core.config.should_strip_subpath_prefix())
                    end
                )

                it(
                    "should parse uppercase true string", function()
                        stub(
                            core.config, "local_conf", function()
                                return { bk_gateway = { strip_subpath_prefix = "TRUE" } }
                            end
                        )
                        assert.is_true(bk_core.config.should_strip_subpath_prefix())
                    end
                )

                it(
                    "should parse false string as false", function()
                        stub(
                            core.config, "local_conf", function()
                                return { bk_gateway = { strip_subpath_prefix = "false" } }
                            end
                        )
                        assert.is_false(bk_core.config.should_strip_subpath_prefix())
                    end
                )

                it(
                    "should return false for unexpected value types", function()
                        stub(
                            core.config, "local_conf", function()
                                return { bk_gateway = { strip_subpath_prefix = 1 } }
                            end
                        )
                        assert.is_false(bk_core.config.should_strip_subpath_prefix())
                    end
                )
            end
        )
    end
)
