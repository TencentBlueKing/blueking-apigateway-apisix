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
local plugin = require("apisix.plugins.bk-stage-context")

describe(
    "bk-stage-context", function()

        local conf

        before_each(
            function()
                conf = {
                    bk_gateway_name = "bk-color",
                    bk_stage_name = "prod",
                    jwt_private_key = "dGVzdA==",
                    bk_api_auth = {
                        api_type = 10,
                        unfiltered_sensitive_keys = {},
                        include_system_headers = {},
                        uin_conf = {},
                        rtx_conf = {},
                        user_conf = {
                            user_type = "default",
                            from_bk_token = true,
                            from_username = true,
                        },
                    },
                }
            end
        )

        context(
            "check_schema", function()
                it(
                    "should fail when config is incorrect", function()
                        assert.is_false(plugin.check_schema({}))
                        assert.is_false(
                            plugin.check_schema(
                                {
                                    bk_gateway_name = "echo",
                                }
                            )
                        )
                    end
                )

                it(
                    "jwt_private_key is not base64", function()
                        conf.jwt_private_key = "invalid-base64"

                        assert.is_false(plugin.check_schema(conf))
                    end
                )

                it(
                    "should sucess when config is correct", function()
                        assert.is_true(plugin.check_schema(conf))
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
                            route_name = "route_name",
                            service_name = "service_name",
                        }
                    end
                )

                it(
                    "should inject context variables", function()
                        plugin.check_schema(conf)
                        plugin.rewrite(conf, ctx)

                        assert.is_equal(ctx.var.instance_id, "2c4562899afc453f85bb9c228ed6febd")
                        assert.is_equal(ctx.var.bk_gateway_name, conf.bk_gateway_name)
                        assert.is_equal(ctx.var.bk_stage_name, conf.bk_stage_name)
                        assert.is_equal(ctx.var.jwt_private_key, "test")
                        assert.is_equal(ctx.var.bk_resource_name, ctx.route_name)
                        assert.is_equal(ctx.var.bk_service_name, ctx.service_name)
                        assert.is_true(ctx.var.bk_api_auth.allow_auth_from_params)
                    end
                )
            end
        )
    end
)
