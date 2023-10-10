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
local access_token_cache = require("apisix.plugins.bk-cache.access-token")
local ssm_component = require("apisix.plugins.bk-components.ssm")
local uuid = require("resty.jit-uuid")

describe(
    "access_token cache", function()

        local ssm_verify_access_token_result
        local ssm_verify_access_token_err
        local ssm_is_configured

        before_each(
            function()
                ssm_verify_access_token_result = nil
                ssm_verify_access_token_err = nil
                ssm_is_configured = false

                stub(
                    ssm_component, "verify_access_token", function()
                        return ssm_verify_access_token_result, ssm_verify_access_token_err
                    end
                )

                stub(
                    ssm_component, "is_configured", function()
                        return ssm_is_configured
                    end
                )
            end
        )

        after_each(
            function()
                ssm_component.verify_access_token:revert()
                ssm_component.is_configured:revert()
            end
        )

        context(
            "local get_access_token", function()
                it(
                    "ssm verify ok", function()
                        ssm_verify_access_token_result = {
                            bk_app_code = "my-foo",
                            username = "kitty",
                            expires_in = 30,
                        }
                        ssm_verify_access_token_err = nil
                        ssm_is_configured = true

                        local result = access_token_cache._get_access_token("fake-access-token")
                        assert.is_same(
                            result.token, {
                                app_code = "my-foo",
                                user_id = "kitty",
                                expires_in = 30,
                            }
                        )
                        assert.is_nil(result.err)
                    end
                )

                it(
                    "ssm verify fail, and is configured", function()
                        ssm_verify_access_token_result = nil
                        ssm_verify_access_token_err = "ssm error"
                        ssm_is_configured = true

                        local result = access_token_cache._get_access_token("fake-access-token")
                        assert.is_nil(result.token)
                        assert.is_equal(result.err, "ssm error")
                    end
                )

                it(
                    "ssm verify fail, but not configured", function()
                        ssm_verify_access_token_result = nil
                        ssm_verify_access_token_err = "ssm error"
                        ssm_is_configured = nil

                        local result = access_token_cache._get_access_token("fake-access-token")
                        assert.is_nil(result.token)
                        assert.is_equal(result.err, "authentication based on access_token is not supported")
                    end
                )

                it(
                    "ssm verify ok, but not configured", function()
                        ssm_verify_access_token_result = {
                            bk_app_code = "my-foo",
                            username = "kitty",
                            expires_in = 30,
                        }
                        ssm_verify_access_token_err = nil
                        ssm_is_configured = nil

                        local result = access_token_cache._get_access_token("fake-access-token")
                        assert.is_nil(result.token)
                        assert.is_equal(result.err, "authentication based on access_token is not supported")
                    end
                )
            end
        )

        context(
            "get_access_token", function()
                it(
                    "get access_token from cache, ok", function()
                        ssm_is_configured = true
                        ssm_verify_access_token_result = {
                            bk_app_code = "my-app",
                            username = "admin",
                            expires_in = 100,
                        }

                        local access_token = uuid.generate_v4()
                        local result, err = access_token_cache.get_access_token(access_token)
                        assert.is_same(
                            result, {
                                app_code = "my-app",
                                user_id = "admin",
                                expires_in = 100,
                            }
                        )
                        assert.is_nil(err)
                        assert.stub(ssm_component.verify_access_token).was_called_with(access_token)

                        -- get from cache
                        access_token_cache.get_access_token(access_token)
                        assert.stub(ssm_component.verify_access_token).was_called(1)

                        -- get from func
                        access_token_cache.get_access_token(uuid.generate_v4())
                        assert.stub(ssm_component.verify_access_token).was_called(2)
                    end
                )

                it(
                    "get access_cache from cache, result has err", function()
                        bkauth_verify_access_token_result = nil
                        bkauth_verify_access_token_err = "bkauth error"
                        ssm_verify_access_token_result = nil
                        ssm_verify_access_token_err = "ssm error"
                        ssm_is_configured = true

                        local access_token = uuid.generate_v4()
                        local result, err = access_token_cache.get_access_token(access_token)
                        assert.is_nil(result)
                        assert.is_not_nil(err)

                        -- get from cache
                        access_token_cache.get_access_token(access_token)
                        assert.stub(ssm_component.verify_access_token).was_called(1)

                        -- get from func
                        access_token_cache.get_access_token(uuid.generate_v4())
                        assert.stub(ssm_component.verify_access_token).was_called(2)
                    end
                )
            end
        )
    end
)
