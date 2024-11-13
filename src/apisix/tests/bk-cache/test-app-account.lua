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
local app_account_cache = require("apisix.plugins.bk-cache.app-account")
local bkauth_component = require("apisix.plugins.bk-components.bkauth")
local uuid = require("resty.jit-uuid")

describe(
    "app-account cache", function()

        local verify_app_secret_result
        local verify_app_secret_err
        local list_app_secrets_result
        local list_app_secrets_err

        before_each(
            function()
                verify_app_secret_result = nil
                verify_app_secret_err = nil
                list_app_secrets_result = nil
                list_app_secrets_err = nil

                stub(
                    bkauth_component, "verify_app_secret", function()
                        return verify_app_secret_result, verify_app_secret_err
                    end
                )

                stub(
                    bkauth_component, "list_app_secrets", function()
                        return list_app_secrets_result, list_app_secrets_err
                    end
                )
            end
        )

        after_each(
            function()
                bkauth_component.verify_app_secret:revert()
                bkauth_component.list_app_secrets:revert()
            end
        )

        context(
            "verify_app_secret", function()
                it(
                    "get from cache, result ok", function()
                        verify_app_secret_result = {
                            existed = true,
                            verified = true,
                        }
                        verify_app_secret_err = nil

                        local app_code = uuid.generate_v4()
                        local result = app_account_cache.verify_app_secret(app_code, "fake-app-secret")
                        assert.is_same(
                            result, {
                                existed = true,
                                verified = true,
                            }
                        )
                        assert.stub(bkauth_component.verify_app_secret).was_called_with(app_code, "fake-app-secret")

                        -- get from cache
                        app_account_cache.verify_app_secret(app_code, "fake-app-secret")
                        assert.stub(bkauth_component.verify_app_secret).was_called(1)

                        -- get from func
                        app_account_cache.verify_app_secret(uuid.generate_v4(), "fake-app-secret")
                        assert.stub(bkauth_component.verify_app_secret).was_called(2)
                    end
                )

                it(
                    "get from cache, result has err", function()
                        verify_app_secret_result = nil
                        verify_app_secret_err = "error"

                        local app_code = uuid.generate_v4()
                        local result, err = app_account_cache.verify_app_secret(app_code, "fake-app-secret")
                        assert.is_nil(result)
                        assert.is_equal(err, "error")
                        assert.stub(bkauth_component.verify_app_secret).was_called_with(app_code, "fake-app-secret")

                        -- has err, no cache
                        app_account_cache.verify_app_secret(app_code, "fake-app-secret")
                        assert.stub(bkauth_component.verify_app_secret).was_called(2)

                        -- get from func
                        app_account_cache.verify_app_secret(uuid.generate_v4(), "fake-app-secret")
                        assert.stub(bkauth_component.verify_app_secret).was_called(3)
                    end
                )

                it(
                    'connection refused, miss in fallback cache', function()
                        verify_app_secret_result = nil
                        verify_app_secret_err = 'connection refused'

                        local app_code = uuid.generate_v4()
                        local result, err = app_account_cache.verify_app_secret(app_code, 'fake-app-secret')
                        assert.is_nil(result)
                        assert.is_equal(err, 'connection refused')
                        assert.stub(bkauth_component.verify_app_secret).was_called_with(app_code, 'fake-app-secret')
                    end
                )

                it(
                    'connection refused, hit in fallback cache', function()
                        local cached_verify_app_secret_result = {
                            existed = true,
                            verified = true,
                        }
                        verify_app_secret_result = nil
                        verify_app_secret_err = 'connection refused'

                        local app_code = uuid.generate_v4()
                        local key = table.concat({ app_code, 'fake-app-secret' }, ':')
                        app_account_cache._verify_app_secret_fallback_lrucache:set(key, cached_verify_app_secret_result, 60 * 60 * 24)

                        local result, err = app_account_cache.verify_app_secret(app_code, 'fake-app-secret')
                        assert.is_same(result, cached_verify_app_secret_result)
                        assert.is_nil(err)
                        assert.stub(bkauth_component.verify_app_secret).was_called_with(app_code, 'fake-app-secret')
                    end
                )

            end
        )

        context(
            "list_app_secrets", function()
                it(
                    "get from cache, result ok", function()
                        list_app_secrets_result = {
                            app_secrets = {
                                "valid-secret",
                            },
                        }
                        list_app_secrets_err = nil

                        local app_code = uuid.generate_v4()
                        local result, err = app_account_cache.list_app_secrets(app_code)
                        assert.is_same(
                            result, {
                                app_secrets = {
                                    "valid-secret",
                                },
                            }
                        )
                        assert.is_nil(err)
                        assert.stub(bkauth_component.list_app_secrets).was_called_with(app_code)

                        -- get from cache
                        app_account_cache.list_app_secrets(app_code)
                        assert.stub(bkauth_component.list_app_secrets).was_called(1)

                        -- get from func
                        app_account_cache.list_app_secrets(uuid.generate_v4())
                        assert.stub(bkauth_component.list_app_secrets).was_called(2)
                    end
                )

                it(
                    "get from cache, result has err", function()
                        list_app_secrets_result = nil
                        list_app_secrets_err = "error"

                        local app_code = uuid.generate_v4()
                        local result, err = app_account_cache.list_app_secrets(app_code)
                        assert.is_nil(result)
                        assert.is_equal(err, "error")
                        assert.stub(bkauth_component.list_app_secrets).was_called_with(app_code)

                        -- has err, no cache
                        app_account_cache.list_app_secrets(app_code)
                        assert.stub(bkauth_component.list_app_secrets).was_called(2)

                        -- get from func
                        app_account_cache.list_app_secrets(uuid.generate_v4())
                        assert.stub(bkauth_component.list_app_secrets).was_called(3)
                    end
                )
            end
        )
    end
)
