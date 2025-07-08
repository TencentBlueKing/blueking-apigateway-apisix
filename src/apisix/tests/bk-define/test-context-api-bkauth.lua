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
local context_api_bkauth = require("apisix.plugins.bk-define.context-api-bkauth")

describe(
    "context api bkauth", function()

        local bk_api_auth

        before_each(
            function()
                bk_api_auth = context_api_bkauth.new(
                    {
                        api_type = 10,
                        unfiltered_sensitive_keys = {
                            "a",
                            "b",
                        },
                        include_system_headers = {
                            "X-Bkapi-App",
                        },
                        rtx_conf = {
                            user_type = "rtx",
                            from_operator = true,
                            from_bk_ticket = true,
                            from_auth_token = true,
                        },
                        uin_conf = {
                            user_type = "uin",
                            from_uin_skey = true,
                            skey_type = 1,
                            domain_id = 1,
                            search_rtx = true,
                            search_rtx_source = 0,
                            from_auth_token = true,
                        },
                        user_conf = {
                            user_type = "bkuser",
                            from_bk_token = true,
                            from_username = true,
                        },
                    }
                )
            end
        )

        context(
            "UinConf", function()
                local uin_conf

                before_each(
                    function()
                        uin_conf = bk_api_auth.uin_conf
                    end
                )

                it(
                    "is_empty", function()
                        assert.is_false(uin_conf:is_empty())

                        uin_conf.user_type = ""
                        assert.is_true(uin_conf:is_empty())
                    end
                )

                it(
                    "use_p_skey", function()
                        assert.is_true(uin_conf:use_p_skey())

                        uin_conf.skey_type = 0
                        assert.is_false(uin_conf:use_p_skey())
                    end
                )
            end
        )

        context(
            "RtxConf", function()
                local rtx_conf

                before_each(
                    function()
                        rtx_conf = bk_api_auth.rtx_conf
                    end
                )

                it(
                    "is_empty", function()
                        assert.is_false(rtx_conf:is_empty())

                        rtx_conf.user_type = ""
                        assert.is_true(rtx_conf:is_empty())
                    end
                )
            end
        )

        context(
            "UserConf", function()
                local user_conf

                before_each(
                    function()
                        user_conf = bk_api_auth.user_conf
                    end
                )

                it(
                    "is_empty", function()
                        assert.is_false(user_conf:is_empty())

                        user_conf.user_type = ""
                        assert.is_true(user_conf:is_empty())
                    end
                )
            end
        )

        context(
            "ContextApiBkAuth", function()
                it(
                    "get_api_type", function()
                        assert.is_equal(bk_api_auth:get_api_type(), 10)
                    end
                )

                it(
                    "get_unfiltered_sensitive_keys", function()
                        assert.is_same(
                            bk_api_auth:get_unfiltered_sensitive_keys(), {
                                "a",
                                "b",
                            }
                        )
                    end
                )

                it(
                    "allow_get_auth_params_from_parameters", function()
                        bk_api_auth.allow_auth_from_params = nil
                        assert.is_true(bk_api_auth:allow_get_auth_params_from_parameters())

                        bk_api_auth.allow_auth_from_params = true
                        assert.is_true(bk_api_auth:allow_get_auth_params_from_parameters())

                        bk_api_auth.allow_auth_from_params = false
                        assert.is_false(bk_api_auth:allow_get_auth_params_from_parameters())
                    end
                )

                it(
                    "get_uin_conf", function()
                        assert.is_same(
                            bk_api_auth:get_uin_conf(), {
                                user_type = "uin",
                                from_uin_skey = true,
                                skey_type = 1,
                                domain_id = 1,
                                search_rtx = true,
                                search_rtx_source = 0,
                                from_auth_token = true,
                            }
                        )
                    end
                )

                it(
                    "get_rtx_conf", function()
                        assert.is_same(
                            bk_api_auth:get_rtx_conf(), {
                                user_type = "rtx",
                                from_operator = true,
                                from_bk_ticket = true,
                                from_auth_token = true,
                            }
                        )
                    end
                )

                it(
                    "get_user_conf", function()
                        assert.is_same(
                            bk_api_auth:get_user_conf(), {
                                user_type = "bkuser",
                                from_bk_token = true,
                                from_username = true,
                            }
                        )
                    end
                )

                it(
                    "is_esb_api", function()
                        assert.is_false(bk_api_auth:is_esb_api())

                        bk_api_auth.api_type = 0
                        assert.is_true(bk_api_auth:is_esb_api())
                    end
                )

                it(
                    "should_delete_sensitive_params", function()
                        local data = {
                            -- esb
                            {
                                params = {
                                    api_type = 0,
                                    allow_delete_sensitive_params = nil,
                                },
                                expected = false,
                            },
                            {
                                params = {
                                    api_type = 0,
                                    allow_delete_sensitive_params = true,
                                },
                                expected = false,
                            },
                            {
                                params = {
                                    api_type = 0,
                                    allow_delete_sensitive_params = false,
                                },
                                expected = false,
                            },
                            -- normal
                            {
                                params = {
                                    api_type = 10,
                                    allow_delete_sensitive_params = nil,
                                },
                                expected = true,
                            },
                            {
                                params = {
                                    api_type = 10,
                                    allow_delete_sensitive_params = true,
                                },
                                expected = true,
                            },
                            {
                                params = {
                                    api_type = 10,
                                    allow_delete_sensitive_params = false,
                                },
                                expected = false,
                            },
                        }
                        for _, item in ipairs(data) do
                            bk_api_auth.api_type = item.params.api_type
                            bk_api_auth.allow_delete_sensitive_params = item.params.allow_delete_sensitive_params

                            assert.is_equal(bk_api_auth:should_delete_sensitive_params(), item.expected)
                        end
                    end
                )

                it(
                    "is_user_type_uin", function()
                        assert.is_true(bk_api_auth:is_user_type_uin())

                        bk_api_auth.uin_conf.user_type = ""
                        assert.is_false(bk_api_auth:is_user_type_uin())

                    end
                )

                it(
                    "from_auth_token", function()
                        assert.is_true(bk_api_auth:from_auth_token())

                        bk_api_auth.uin_conf.from_auth_token = false
                        assert.is_false(bk_api_auth:from_auth_token())

                        bk_api_auth.uin_conf.user_type = ""
                        bk_api_auth.rtx_conf.from_auth_token = false
                        assert.is_false(bk_api_auth:from_auth_token())
                    end
                )

                it(
                    "no_user_type", function()
                        assert.is_false(bk_api_auth:no_user_type())

                        bk_api_auth.uin_conf.user_type = ""
                        assert.is_false(bk_api_auth:no_user_type())

                        bk_api_auth.rtx_conf.user_type = ""
                        assert.is_false(bk_api_auth:no_user_type())

                        bk_api_auth.user_conf.user_type = ""
                        assert.is_true(bk_api_auth:no_user_type())
                    end
                )

                it(
                    "contain_system_header", function()
                        assert.is_true(bk_api_auth:contain_system_header("X-Bkapi-App"))
                        assert.is_false(bk_api_auth:contain_system_header("X-Token"))
                    end
                )
            end
        )
    end
)
