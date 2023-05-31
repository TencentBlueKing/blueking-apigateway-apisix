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

local plugin = require("apisix.plugins.bk-resource-context")

describe(
    "bk-resource-context", function()

        local conf

        before_each(
            function()
                conf = {
                    bk_resource_id = 12,
                    bk_resource_name = "demo",
                    bk_resource_auth = {
                        verified_app_required = true,
                        verified_user_required = true,
                        resource_perm_required = true,
                        skip_user_verification = false,
                    },
                }
            end
        )

        context(
            "check_schema", function()
                it(
                    "should fail when config is incorrect", function()
                        assert.is_false(
                            plugin.check_schema(
                                {
                                    bk_resource_id = "color",
                                }
                            )
                        )
                    end
                )

                it(
                    "should sucess when config is correct", function()
                        assert.is_true(plugin.check_schema({}))

                        assert.is_true(plugin.check_schema(conf))
                    end
                )

                it(
                    "inject bk_resource_auth", function()
                        plugin.check_schema(conf)
                        assert.is_same(
                            conf.bk_resource_auth_obj, {
                                verified_app_required = true,
                                verified_user_required = true,
                                resource_perm_required = true,
                                skip_user_verification = false,
                            }
                        )
                    end
                )
            end
        )

        context(
            "rewrite", function()
                local ctx

                before_each(
                    function()
                        ctx = {
                            var = {},
                        }
                    end
                )

                it(
                    "should inject context variables", function()
                        conf.bk_resource_auth_obj = {
                            verified_app_required = false,
                            verified_user_required = false,
                            resource_perm_required = false,
                            skip_user_verification = true,
                        }

                        plugin.rewrite(conf, ctx)

                        assert.is_equal(ctx.var.bk_resource_id, 12)
                        assert.is_equal(ctx.var.bk_resource_name, "demo")
                        assert.is_same(
                            ctx.var.bk_resource_auth, {
                                verified_app_required = false,
                                verified_user_required = false,
                                resource_perm_required = false,
                                skip_user_verification = true,
                            }
                        )
                    end
                )
            end
        )
    end
)
