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

local user_tenant_info_cache = require("apisix.plugins.bk-cache.user-tenant-info")
local bkauth_component = require("apisix.plugins.bk-components.bkauth")
local uuid = require("resty.jit-uuid")

describe(
    "user-tenant-info cache", function()

        local get_user_tenant_info_result
        local get_user_tenant_info_err

        before_each(
            function()
                get_user_tenant_info_result = nil
                get_user_tenant_info_err = nil

                stub(
                    bkauth_component, "get_user_tenant_info", function()
                        return get_user_tenant_info_result, get_user_tenant_info_err
                    end
                )
            end
        )

        after_each(
            function()
                bkauth_component.get_user_tenant_info:revert()
            end
        )

        context(
            "get_user_tenant_info", function()
                it(
                    "get from cache, result ok", function()
                        get_user_tenant_info_result = {
                            tenant_id = "tenant-123",
                        }
                        get_user_tenant_info_err = nil

                        local username = uuid.generate_v4()
                        local result = user_tenant_info_cache.get_user_tenant_info(username)
                        assert.is_same(
                            result, {
                                tenant_id = "tenant-123",
                            }
                        )
                        assert.stub(bkauth_component.get_user_tenant_info).was_called_with(username)

                        -- get from cache
                        user_tenant_info_cache.get_user_tenant_info(username)
                        assert.stub(bkauth_component.get_user_tenant_info).was_called(1)

                        -- get from func
                        user_tenant_info_cache.get_user_tenant_info(uuid.generate_v4())
                        assert.stub(bkauth_component.get_user_tenant_info).was_called(2)
                    end
                )

                it(
                    "get from cache, result has err", function()
                        get_user_tenant_info_result = nil
                        get_user_tenant_info_err = "error"

                        local username = uuid.generate_v4()
                        local result, err = user_tenant_info_cache.get_user_tenant_info(username)
                        assert.is_nil(result)
                        assert.is_equal(err, "error")
                        assert.stub(bkauth_component.get_user_tenant_info).was_called_with(username)

                        -- has err, no cache
                        user_tenant_info_cache.get_user_tenant_info(username)
                        assert.stub(bkauth_component.get_user_tenant_info).was_called(2)

                        -- get from func
                        user_tenant_info_cache.get_user_tenant_info(uuid.generate_v4())
                        assert.stub(bkauth_component.get_user_tenant_info).was_called(3)
                    end
                )

                it(
                    'connection refused, miss in fallback cache', function()
                        get_user_tenant_info_result = nil
                        get_user_tenant_info_err = 'connection refused'

                        local username = uuid.generate_v4()
                        local result, err = user_tenant_info_cache.get_user_tenant_info(username)
                        assert.is_nil(result)
                        assert.is_equal(err, 'get_user_tenant_info failed, error: connection refused')
                        assert.stub(bkauth_component.get_user_tenant_info).was_called_with(username)
                    end
                )

                it(
                    'connection refused, hit in fallback cache', function()
                        local cached_get_user_tenant_info_result = {
                            tenant_id = "tenant-123",
                        }
                        get_user_tenant_info_result = nil
                        get_user_tenant_info_err = 'connection refused'

                        local username = uuid.generate_v4()
                        user_tenant_info_cache._user_tenant_id_fallback_lrucache:set(username, cached_get_user_tenant_info_result, 60 * 60 * 24)

                        local result, err = user_tenant_info_cache.get_user_tenant_info(username)
                        assert.is_same(result, cached_get_user_tenant_info_result)
                        assert.is_nil(err)
                        assert.stub(bkauth_component.get_user_tenant_info).was_called_with(username)
                    end
                )
            end
        )
    end
)