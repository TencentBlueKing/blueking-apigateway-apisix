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

local inner_jwt_verifier = require("apisix.plugins.bk-auth-verify.inner-jwt-verifier")
local jwt_utils = require("apisix.plugins.bk-auth-verify.jwt-utils")

describe(
    "inner jwt verifier", function()
        context(
            "verify_app", function()
                local parse_jwt_token_result
                local parse_jwt_token_err

                before_each(
                    function()
                        stub(
                            jwt_utils, "parse_bk_jwt_token", function()
                                return parse_jwt_token_result, parse_jwt_token_err
                            end
                        )
                    end
                )

                after_each(
                    function()
                        jwt_utils.parse_bk_jwt_token:revert()
                    end
                )

                it(
                    "parse jwt_token error", function()
                        parse_jwt_token_result = nil
                        parse_jwt_token_err = "error"

                        local app, err = inner_jwt_verifier.new("fake-jwt-token"):verify_app()
                        assert.is_equal(err, "parameter jwt is invalid: error")
                        assert.is_nil(app)
                    end
                )

                it(
                    "invalid kid", function()
                        parse_jwt_token_result = {
                            header = {
                                kid = "invalid-kid"
                            },
                            payload = {}
                        }
                        parse_jwt_token_err = nil

                        local app, err = inner_jwt_verifier.new("fake-jwt-token"):verify_app()
                        assert.is_equal(err, "invalid kid, only bk-apigateway is supported")
                        assert.is_nil(app)
                    end
                )

                it(
                    "app is nil", function()
                        parse_jwt_token_result = {
                            header = {
                                kid = "bk-apigateway"
                            },
                            payload = {}
                        }
                        parse_jwt_token_err = nil

                        local app, err = inner_jwt_verifier.new("fake-jwt-token"):verify_app()
                        assert.is_equal(err, "parameter jwt does not indicate app information")
                        assert.is_nil(app)
                    end
                )

                it(
                    "app is not verified", function()
                        parse_jwt_token_result = {
                            header = {
                                kid = "bk-apigateway"
                            },
                            payload = {
                                app = {
                                    app_code = "my-app",
                                    verified = false
                                }
                            }
                        }
                        parse_jwt_token_err = nil

                        local app, err = inner_jwt_verifier.new("fake-jwt-token"):verify_app()
                        assert.is_equal(err, "the app indicated by jwt is not verified")
                        assert.is_nil(app)
                    end
                )

                it(
                    "ok", function()
                        parse_jwt_token_result = {
                            header = {
                                kid = "bk-apigateway"
                            },
                            payload = {
                                app = {
                                    app_code = "my-app",
                                    verified = true
                                }
                            }
                        }
                        parse_jwt_token_err = nil

                        local app, err = inner_jwt_verifier.new("fake-jwt-token"):verify_app()
                        assert.is_nil(err)
                        assert.is_equal(app.app_code, "my-app")
                        assert.is_true(app.verified)
                    end
                )
            end
        )

        context(
            "verify_user", function()
                local parse_jwt_token_result
                local parse_jwt_token_err

                before_each(
                    function()
                        stub(
                            jwt_utils, "parse_bk_jwt_token", function()
                                return parse_jwt_token_result, parse_jwt_token_err
                            end
                        )
                    end
                )

                after_each(
                    function()
                        jwt_utils.parse_bk_jwt_token:revert()
                    end
                )

                it(
                    "parse jwt_token error", function()
                        parse_jwt_token_result = nil
                        parse_jwt_token_err = "error"

                        local user, err = inner_jwt_verifier.new("fake-jwt-token"):verify_user()
                        assert.is_equal(err, "parameter jwt is invalid: error")
                        assert.is_nil(user)
                    end
                )

                it(
                    "invalid kid", function()
                        parse_jwt_token_result = {
                            header = {
                                kid = "invalid-kid"
                            },
                            payload = {}
                        }
                        parse_jwt_token_err = nil

                        local user, err = inner_jwt_verifier.new("fake-jwt-token"):verify_user()
                        assert.is_equal(err, "invalid kid, only bk-apigateway is supported")
                        assert.is_nil(user)
                    end
                )

                it(
                    "user is nil", function()
                        parse_jwt_token_result = {
                            header = {
                                kid = "bk-apigateway"
                            },
                            payload = {}
                        }
                        parse_jwt_token_err = nil

                        local user, err = inner_jwt_verifier.new("fake-jwt-token"):verify_user()
                        assert.is_equal(err, "parameter jwt does not indicate user information")
                        assert.is_nil(user)
                    end
                )

                it(
                    "user is not verified", function()
                        parse_jwt_token_result = {
                            header = {
                                kid = "bk-apigateway"
                            },
                            payload = {
                                user = {
                                    username = "admin",
                                    verified = false
                                }
                            }
                        }
                        parse_jwt_token_err = nil

                        local user, err = inner_jwt_verifier.new("fake-jwt-token"):verify_user()
                        assert.is_equal(err, "the user indicated by jwt is not verified")
                        assert.is_nil(user)
                    end
                )

                it(
                    "ok", function()
                        parse_jwt_token_result = {
                            header = {
                                kid = "bk-apigateway"
                            },
                            payload = {
                                user = {
                                    username = "admin",
                                    verified = true
                                }
                            }
                        }
                        parse_jwt_token_err = nil

                        local user, err = inner_jwt_verifier.new("fake-jwt-token"):verify_user()
                        assert.is_nil(err)
                        assert.is_equal(user.username, "admin")
                        assert.is_true(user.verified)
                        -- 1:admin:true:
                        assert.is_equal(user:uid(), "16f662fd0e0528543ea773816c33879a")
                    end
                )
            end
        )
    end
)
