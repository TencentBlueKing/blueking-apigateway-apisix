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
local bk_token_cache = require("apisix.plugins.bk-cache.bk-token")
local bklogin_component = require("apisix.plugins.bk-components.bklogin")
local uuid = require("resty.jit-uuid")

describe(
    "bk-token cache", function()

        local get_username_by_bk_token_result
        local get_username_by_bk_token_err

        before_each(
            function()
                get_username_by_bk_token_result = nil
                get_username_by_bk_token_err = "error"

                stub(
                    bklogin_component, "get_username_by_bk_token", function()
                        return get_username_by_bk_token_result, get_username_by_bk_token_err
                    end
                )
            end
        )

        after_each(
            function()
                bklogin_component.get_username_by_bk_token:revert()
            end
        )

        context(
            "get_username_by_bk_token", function()
                it(
                    "get from cache, ok", function()
                        get_username_by_bk_token_result = {
                            username = "admin",
                        }
                        get_username_by_bk_token_err = nil

                        local bk_token = uuid.generate_v4()
                        local result, err = bk_token_cache.get_username_by_bk_token(bk_token)
                        assert.is_equal(result, "admin")
                        assert.is_nil(err)
                        assert.stub(bklogin_component.get_username_by_bk_token).was_called_with(bk_token)

                        -- get from cache
                        bk_token_cache.get_username_by_bk_token(bk_token)
                        assert.stub(bklogin_component.get_username_by_bk_token).was_called(1)

                        -- get from func
                        bk_token_cache.get_username_by_bk_token(uuid.generate_v4())
                        assert.stub(bklogin_component.get_username_by_bk_token).was_called(2)
                    end
                )

                it(
                    "get from cache, has err", function()
                        get_username_by_bk_token_result = nil
                        get_username_by_bk_token_err = "error"

                        local bk_token = uuid.generate_v4()
                        local result, err = bk_token_cache.get_username_by_bk_token(bk_token)
                        assert.is_nil(result)
                        assert.is_equal(err, "error")
                        assert.stub(bklogin_component.get_username_by_bk_token).was_called_with(bk_token)

                        -- has err, no cache
                        bk_token_cache.get_username_by_bk_token(bk_token)
                        assert.stub(bklogin_component.get_username_by_bk_token).was_called(2)

                        -- get from func
                        bk_token_cache.get_username_by_bk_token(uuid.generate_v4())
                        assert.stub(bklogin_component.get_username_by_bk_token).was_called(3)
                    end
                )
            end
        )
    end
)
