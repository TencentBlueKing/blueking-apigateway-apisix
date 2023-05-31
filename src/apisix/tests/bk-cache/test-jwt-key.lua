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

local jwt_key_lrucache = require("apisix.plugins.bk-cache.jwt-key")
local bk_apigateway_core_component = require("apisix.plugins.bk-components.bk-apigateway-core")
local uuid = require("resty.jit-uuid")

describe(
    "jwt-key cache", function()

        local get_apigw_public_key_result

        before_each(
            function()
                get_apigw_public_key_result = nil

                stub(
                    bk_apigateway_core_component, "get_apigw_public_key", function()
                        return get_apigw_public_key_result
                    end
                )
            end
        )

        after_each(
            function()
                bk_apigateway_core_component.get_apigw_public_key:revert()
            end
        )

        context(
            "get_jwt_public_key", function()
                it(
                    "get from cache, result ok", function()
                        get_apigw_public_key_result = {
                            public_key = "jwt-public-key",
                        }

                        local gateway_name = uuid.generate_v4()
                        local result, err = jwt_key_lrucache.get_jwt_public_key(gateway_name)
                        assert.is_same(result, "jwt-public-key")
                        assert.is_nil(err)
                        assert.stub(bk_apigateway_core_component.get_apigw_public_key).was_called_with(gateway_name)

                        -- get from cache
                        jwt_key_lrucache.get_jwt_public_key(gateway_name)
                        assert.stub(bk_apigateway_core_component.get_apigw_public_key).was_called(1)

                        -- get from func
                        jwt_key_lrucache.get_jwt_public_key(uuid.generate_v4())
                        assert.stub(bk_apigateway_core_component.get_apigw_public_key).was_called(2)
                    end
                )

                it(
                    "get from cache, result has err", function()
                        get_apigw_public_key_result = {
                            err = "error",
                        }

                        local gateway_name = uuid.generate_v4()
                        local result, err = jwt_key_lrucache.get_jwt_public_key(gateway_name)
                        assert.is_nil(result)
                        assert.is_equal(err, "error")
                        assert.stub(bk_apigateway_core_component.get_apigw_public_key).was_called_with(gateway_name)

                        -- get from cache
                        jwt_key_lrucache.get_jwt_public_key(gateway_name)
                        assert.stub(bk_apigateway_core_component.get_apigw_public_key).was_called(1)

                        -- get from func
                        jwt_key_lrucache.get_jwt_public_key(uuid.generate_v4())
                        assert.stub(bk_apigateway_core_component.get_apigw_public_key).was_called(2)
                    end
                )
            end
        )
    end
)
