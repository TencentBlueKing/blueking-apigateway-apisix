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

local context_api_bkauth = require("apisix.plugins.bk-define.context-api-bkauth")
local request = require("apisix.core.request")
local plugin = require("apisix.plugins.bk-jwt")
local bk_app_define = require("apisix.plugins.bk-define.app")
local bk_user_define = require("apisix.plugins.bk-define.user")

local jwt_private_key = [[
-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEAxMAPEcUclK+Sn7kCI7jd8IUP92YXEjrBruo/qFBA/esKKHIL
lgFdlVa68lAFkfhDFh1Awp46FoMAp8WqlJYBCX8klZv9UZadY+hDHcmEnTFIyV+q
qZr5CjEEyVSO2X2yhwNpHwoRX/Z4H3/DfBLpgvIBEgJnkV+2ZkbI51YHr4ZOeH7G
a+Z91g9FG+2WQ5TpM2uHdkA2Jw6KJiGIGSsJuw1Yd77Ea3he02884xOaJ2OEhets
w/lo53nLPOL7Qs2AF+zQt79Ll4xEP87gjd6ZRluIIj7Tmax+C+vo25P4C2kkDZ3j
ryV7n7RW3kg1AymbcvPy/IC4gFA1ffLQzeptoQIDAQABAoIBACg4LpxuU9JdNbbq
5fIRd2UUflgPiYXTdwZfolWw2ihN5Myxy4aFjvDZQuwHyau2OViK8FMYbz1s2DRz
ptQq+dlMIVloAter1062CwpKyI4tpfhsUwHKyT/5F0Zkv7LcDCOnYdTThQu94X5m
6roxT4TSHb/lt/AyxaGQtL79iiKqEQssCgU7PEKfi665M+AqSX++lvmD5T4WMNeF
ZaD3oeZEwi2um5dEULny8vmQSSDHM/FNI5DZ42/Jx17eDlhOnUsW4DiiNffaxtiQ
jj42cI8NDqrE8L1/8Mr0+G973AVLW0j9DSZSlf3jBKZe4DbhuUOvd5+C4+QpSoCK
RxiyZqUCgYEA6VC3yPFllRzlhW0Civrha0Z0tfUBDKYDjkuvg2OtEpJECF8NK+Rs
6kJsSSl30bnlRroCJj6aaE+xsv3cmOhJsJzzLjRHuNcM2Gz0u6VrSHn1MtFSjjGm
hdbmEftHmn/mDMIrYc6GRO8NYY+qhyg5hZhGZWCPqTIhWCA85ZObzSMCgYEA1+E5
6BJRVoZgLwtA+9svjWczfnmuoMzleYSasrTReSh30xkA6TnnjNRbY4ooEPG4KlWM
z4zQmS63skT/cZOJQ5wlC0IMr70Z69OgvsHMrCrJBCoe3IKNaCXucVe47oUpJ3RB
1a5ov2d3KC+wG57ccFOLw1MDSCco1TDUD3B4kGsCgYBoVoyZ9Do1YOLTtFg6xs8g
JjXzWUnK2kMk03v+CglQENET3U4KnvCGIoZCgaTvyW5bHrvvVne+xkT1gsmwJ9Es
hkPKGd8pLiK0dqVLdUJw+vlIbIu6w0FxARWKXRE8ao36jqrP5oftM+qMAq+EGdz/
fYWduH0GcUCwJFqXYFeAeQKBgQDA529ZItUv3g+gugutgmTxlCB9iboz0iPT/FxI
CC+Odkzsg1E/FxED1NZ9Ef1Pds+8dInJBOl5mDdpwyIHmXB0y9iGQNUZTH8XLhpb
ms2LowfRAtpk7Pvy7sIs4dhMuwzVRpt1l83eC1R8wnA5njEY5m7jcRBjrypbprA3
w6bYVQKBgCxkrErIMO2JiZfEvMfWvdzHXQoT3STq0nOWQV/tSHneMf09RuiadBsN
Vg1LTLD3EUVme7gQtMXQppAQlI5eqfIvERgjbA6RcMH4p3Peq13GPuJentkr9hj6
QYqNcPN8UtLIaOHf/OPbqUqwylhpmk2LHNi0gK0+IZr95iGGtsyg
-----END RSA PRIVATE KEY-----
]]

local jwt_public_key = [[
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAxMAPEcUclK+Sn7kCI7jd
8IUP92YXEjrBruo/qFBA/esKKHILlgFdlVa68lAFkfhDFh1Awp46FoMAp8WqlJYB
CX8klZv9UZadY+hDHcmEnTFIyV+qqZr5CjEEyVSO2X2yhwNpHwoRX/Z4H3/DfBLp
gvIBEgJnkV+2ZkbI51YHr4ZOeH7Ga+Z91g9FG+2WQ5TpM2uHdkA2Jw6KJiGIGSsJ
uw1Yd77Ea3he02884xOaJ2OEhetsw/lo53nLPOL7Qs2AF+zQt79Ll4xEP87gjd6Z
RluIIj7Tmax+C+vo25P4C2kkDZ3jryV7n7RW3kg1AymbcvPy/IC4gFA1ffLQzept
oQIDAQAB
-----END PUBLIC KEY-----
]]

describe(
    "bk-jwt", function()

        context(
            "generate_bkapi_jwt_header", function()
                context(
                    "ok", function()
                        it(
                            "ok", function()
                                local app = bk_app_define.new_app(
                                    {
                                        app_code = "my-app",
                                        verified = true,
                                    }
                                )
                                local user = bk_user_define.new_user(
                                    {
                                        username = "admin",
                                        verified = true,
                                    }
                                )

                                local bk_gateway_name = "my-gateway-for-ok"

                                local header, err = plugin._generate_bkapi_jwt_header(
                                    app, user, bk_gateway_name, jwt_private_key
                                )
                                assert.is_string(header)
                                assert.is_nil(err)
                            end
                        )

                        it(
                            "error", function()
                                local app = bk_app_define.new_app(
                                    {
                                        app_code = "my-app",
                                        verified = true,
                                    }
                                )
                                local user = bk_user_define.new_user(
                                    {
                                        username = "admin",
                                        verified = true,
                                    }
                                )

                                local bk_gateway_name = "my-gateway-for-error"

                                local header, err = plugin._generate_bkapi_jwt_header(
                                    app, user, bk_gateway_name, "not-valid-jwt-private-key"
                                )
                                assert.is_nil(header)
                                assert.is_equal(
                                    err,
                                    "sign jwt failed, please try again later, or contact API Gateway administrator to handle"
                                )
                            end
                        )
                    end
                )
            end
        )

        context(
            "rewrite", function()
                before_each(
                    function()
                        stub(request, "set_header")
                    end
                )

                after_each(
                    function()
                        request.set_header:revert()
                    end
                )

                it(
                    "ok", function()
                        local ctx = {
                            var = {
                                bk_app = bk_app_define.new_app(
                                    {
                                        app_code = "my-app",
                                        verified = true,
                                    }
                                ),
                                bk_user = bk_user_define.new_user(
                                    {
                                        username = "admin",
                                        verified = true,
                                    }
                                ),
                                bk_gateway_name = "my-gateway-for-rewrite-ok",
                                jwt_private_key = jwt_private_key,
                                bk_api_auth = context_api_bkauth.new(
                                    {
                                        include_system_headers = {
                                            "X-Bkapi-App",
                                        },
                                    }
                                ),
                            },
                        }

                        local status = plugin.rewrite({}, ctx)
                        assert.is_nil(status)
                        assert.is_nil(ctx.var.bk_apigw_error)
                        assert.stub(request.set_header).was_called()
                    end
                )

                it(
                    "error", function()
                        local ctx = {
                            var = {
                                bk_app = bk_app_define.new_app(
                                    {
                                        app_code = "my-app",
                                        verified = true,
                                    }
                                ),
                                bk_user = bk_user_define.new_user(
                                    {
                                        username = "admin",
                                        verified = true,
                                    }
                                ),
                                bk_gateway_name = "my-gateway-for-rewrite-error",
                                jwt_private_key = "not-valid-jwt-private-key",
                            },
                        }

                        local status = plugin.rewrite({}, ctx)
                        assert.is_equal(status, 400)
                        assert.is_equal(ctx.var.bk_apigw_error.error.code, 1640001)
                    end
                )
            end
        )
    end
)
