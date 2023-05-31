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

local context_resource_bkauth = require("apisix.plugins.bk-define.context-resource-bkauth")

describe(
    "context resource bkauth", function()

        local bk_resource_auth

        before_each(
            function()
                bk_resource_auth = context_resource_bkauth.new(
                    {
                        verified_app_required = true,
                        verified_user_required = true,
                        resource_perm_required = true,
                        skip_user_verification = true,
                    }
                )
            end
        )

        context(
            "bk resource auth", function()
                it(
                    "ok", function()
                        assert.is_true(bk_resource_auth:get_verified_app_required())
                        assert.is_true(bk_resource_auth:get_verified_user_required())
                        assert.is_true(bk_resource_auth:get_resource_perm_required())
                        assert.is_true(bk_resource_auth:get_skip_user_verification())
                    end
                )

                it(
                    "new", function()
                        local auth = context_resource_bkauth.new({})
                        assert.is_same(
                            auth, {
                                verified_app_required = false,
                                verified_user_required = false,
                                resource_perm_required = false,
                                skip_user_verification = false,
                            }
                        )
                    end
                )
            end
        )
    end
)
