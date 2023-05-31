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

local jwt = require("resty.jwt")
local jwt_utils = require("apisix.plugins.bk-auth-verify.jwt-utils")
local core = require("apisix.core")
local bk_cache = require("apisix.plugins.bk-cache.init")

local ngx = ngx

local jwt_private_key = [[
-----BEGIN RSA PRIVATE KEY-----
MIIEogIBAAKCAQEAnzyis1ZjfNB0bBgKFMSvvkTtwlvBsaJq7S5wA+kzeVOVpVWw
kWdVha4s38XM/pa/yr47av7+z3VTmvDRyAHcaT92whREFpLv9cj5lTeJSibyr/Mr
m/YtjCZVWgaOYIhwrXwKLqPr/11inWsAkfIytvHWTxZYEcXLgAXFuUuaS3uF9gEi
NQwzGTU1v0FqkqTBr4B8nW3HCN47XUu0t8Y0e+lf4s4OxQawWD79J9/5d3Ry0vbV
3Am1FtGJiJvOwRsIfVChDpYStTcHTCMqtvWbV6L11BWkpzGXSW4Hv43qa+GSYOD2
QU68Mb59oSk2OB+BtOLpJofmbGEGgvmwyCI9MwIDAQABAoIBACiARq2wkltjtcjs
kFvZ7w1JAORHbEufEO1Eu27zOIlqbgyAcAl7q+/1bip4Z/x1IVES84/yTaM8p0go
amMhvgry/mS8vNi1BN2SAZEnb/7xSxbflb70bX9RHLJqKnp5GZe2jexw+wyXlwaM
+bclUCrh9e1ltH7IvUrRrQnFJfh+is1fRon9Co9Li0GwoN0x0byrrngU8Ak3Y6D9
D8GjQA4Elm94ST3izJv8iCOLSDBmzsPsXfcCUZfmTfZ5DbUDMbMxRnSo3nQeoKGC
0Lj9FkWcfmLcpGlSXTO+Ww1L7EGq+PT3NtRae1FZPwjddQ1/4V905kyQFLamAA5Y
lSpE2wkCgYEAy1OPLQcZt4NQnQzPz2SBJqQN2P5u3vXl+zNVKP8w4eBv0vWuJJF+
hkGNnSxXQrTkvDOIUddSKOzHHgSg4nY6K02ecyT0PPm/UZvtRpWrnBjcEVtHEJNp
bU9pLD5iZ0J9sbzPU/LxPmuAP2Bs8JmTn6aFRspFrP7W0s1Nmk2jsm0CgYEAyH0X
+jpoqxj4efZfkUrg5GbSEhf+dZglf0tTOA5bVg8IYwtmNk/pniLG/zI7c+GlTc9B
BwfMr59EzBq/eFMI7+LgXaVUsM/sS4Ry+yeK6SJx/otIMWtDfqxsLD8CPMCRvecC
2Pip4uSgrl0MOebl9XKp57GoaUWRWRHqwV4Y6h8CgYAZhI4mh4qZtnhKjY4TKDjx
QYufXSdLAi9v3FxmvchDwOgn4L+PRVdMwDNms2bsL0m5uPn104EzM6w1vzz1zwKz
5pTpPI0OjgWN13Tq8+PKvm/4Ga2MjgOgPWQkslulO/oMcXbPwWC3hcRdr9tcQtn9
Imf9n2spL/6EDFId+Hp/7QKBgAqlWdiXsWckdE1Fn91/NGHsc8syKvjjk1onDcw0
NvVi5vcba9oGdElJX3e9mxqUKMrw7msJJv1MX8LWyMQC5L6YNYHDfbPF1q5L4i8j
8mRex97UVokJQRRA452V2vCO6S5ETgpnad36de3MUxHgCOX3qL382Qx9/THVmbma
3YfRAoGAUxL/Eu5yvMK8SAt/dJK6FedngcM3JEFNplmtLYVLWhkIlNRGDwkg3I5K
y18Ae9n7dHVueyslrb6weq7dTkYDi3iOYRW8HRkIQh06wEdbxt0shTzAJvvCQfrB
jg/3747WSsf/zBTcHihTRBdAv6OmdhV4/dD5YBfLAkLrd+mX7iE=
-----END RSA PRIVATE KEY-----
]]

local jwt_public_key = [[
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAnzyis1ZjfNB0bBgKFMSv
vkTtwlvBsaJq7S5wA+kzeVOVpVWwkWdVha4s38XM/pa/yr47av7+z3VTmvDRyAHc
aT92whREFpLv9cj5lTeJSibyr/Mrm/YtjCZVWgaOYIhwrXwKLqPr/11inWsAkfIy
tvHWTxZYEcXLgAXFuUuaS3uF9gEiNQwzGTU1v0FqkqTBr4B8nW3HCN47XUu0t8Y0
e+lf4s4OxQawWD79J9/5d3Ry0vbV3Am1FtGJiJvOwRsIfVChDpYStTcHTCMqtvWb
V6L11BWkpzGXSW4Hv43qa+GSYOD2QU68Mb59oSk2OB+BtOLpJofmbGEGgvmwyCI9
MwIDAQAB
-----END PUBLIC KEY-----
]]

describe(
    "jwt-utils", function()

        context(
            "genetate_bk_jwt_token", function()
                it(
                    "private_key is invalid", function()
                        local private_key = "invalid"
                        local jwt_token, err = jwt_utils.generate_bk_jwt_token(
                            "my-gateway", private_key, {
                                app = {
                                    app_code = "my-app",
                                    verified = true,
                                },
                            }, 900
                        )
                        assert.is_nil(jwt_token)
                        assert.is_true(core.string.has_prefix(err, "failed to sign jwt"))
                    end
                )

                it(
                    "ok", function()
                        local jwt_token, err = jwt_utils.generate_bk_jwt_token(
                            "my-gateway", jwt_private_key, {
                                app = {
                                    app_code = "my-app",
                                    verified = true,
                                },
                            }, 900
                        )

                        assert.is_not_nil(jwt_token)
                        assert.is_nil(err)

                        local jwt_obj = jwt:verify(jwt_public_key, jwt_token)
                        assert.is_equal(jwt_obj.header.kid, "my-gateway")
                        assert.is_equal(jwt_obj.header.typ, "JWT")
                        assert.is_equal(jwt_obj.header.alg, "RS512")
                        assert.is_nil(jwt_obj.header.iss)
                        assert.is_same(
                            jwt_obj.payload.app, {
                                app_code = "my-app",
                                verified = true,
                            }
                        )
                        assert.is_equal(jwt_obj.payload.iss, "APIGW")
                    end
                )

                -- it(
                --     "ok, now update",
                --     function()
                --         local jwt_token = jwt_utils.generate_bk_jwt_token(
                --             "my-gateway",
                --             jwt_private_key,
                --             {app = {app_code = "my-app", verified = true}},
                --             900
                --         )

                --         ngx.sleep(1)

                --         local jwt_token2 = jwt_utils.generate_bk_jwt_token(
                --             "my-gateway",
                --             jwt_private_key,
                --             {app = {app_code = "my-app", verified = true}},
                --             900
                --         )

                --         assert.is_not_equal(jwt_token, jwt_token2)
                --     end
                -- )
            end
        )

        context(
            "parse_bk_jwt_token", function()
                local get_public_key_result
                local get_public_key_err

                before_each(
                    function()
                        -- set default value
                        get_public_key_result = jwt_public_key
                        get_public_key_err = nil

                        stub(
                            bk_cache, "get_jwt_public_key", function()
                                return get_public_key_result, get_public_key_err
                            end
                        )
                    end
                )

                after_each(
                    function()
                        bk_cache.get_jwt_public_key:revert()
                    end
                )

                it(
                    "jwt token invalid", function()
                        local jwt_token = "invalid"
                        local jwt_obj, err = jwt_utils.parse_bk_jwt_token(jwt_token)
                        assert.is_nil(jwt_obj)
                        assert.is_equal(err, "JWT Token invalid")
                    end
                )

                it(
                    "jwt header without kid", function()
                        local jwt_token = "eyJhbGciOiJSUzUxMiIsInR5cCI6IkpXVCIsImlhdCI6MTU2MDQ4MzA5NH0.eyJpc3MiOiJBUElHVyIsIm" ..
                                              "FwcCI6eyJhcHBfY29kZSI6ImFwaWd3LXRlc3QifSwidXNlciI6eyJ1c2VybmFtZSI6ImFkbWluIn0sImV4c" ..
                                              "CI6MTg3Mjc2ODI3OSwibmJmIjoxNTYwNDgzMDk0fQ.Sy5CyTO5mBoINnMkhQ0ZqM-Zcsp1kv-wnEmEmhZOY" ..
                                              "W-KDl_qipIHekNWqkuMkfZWB9I5O1kEPWA3ApY9SUwfosaTE2ZEahH9fM1WNgHlB_sd_cOxYXJ0CATPI_aY" ..
                                              "D96cdbRXiRIEr57J_OmnQhI4Xk4nmIuP7NZb1lOmy2Qm711fhFAcIpp_U1gu98f5IBvoDxl9XfgJCa_-ZPl" ..
                                              "5zOPdwfnKN29fUiXDkmJmTwcf6verC53OhJN3liRx-myjHgZ8JIKRkkUwbp8L1gkapIvY_WMjwBiMJ7feGa" ..
                                              "61BNvnOYsPzG-CnnAFpZT8H5Cgy-Raq4I8afhbsT-yPq71N0QD9A"

                        local jwt_obj, err = jwt_utils.parse_bk_jwt_token(jwt_token)
                        assert.is_nil(jwt_obj)
                        assert.is_equal(err, "missing kid in JWT token")
                    end
                )

                it(
                    "failed to get public_key", function()
                        local jwt_token = "eyJhbGciOiJSUzUxMiIsImtpZCI6InRlc3QiLCJ0eXAiOiJKV1QiLCJpYXQiOjE1NjA0ODMxMTZ9.eyJpc3M" ..
                                              "iOiJBUElHVyIsImFwcCI6eyJhcHBfY29kZSI6ImFwaWd3LXRlc3QifSwidXNlciI6eyJ1c2VybmFtZSI6ImFk" ..
                                              "bWluIn0sImV4cCI6MTg3Mjc2ODI3OSwibmJmIjoxNTYwNDgzMTE2fQ.ask_dn8tdpjbEi_WELTVwHYWGPr8TF" ..
                                              "aAtGnZcxPwLlieMvCkSMMjrT1bmCIoOBqpL0XiMxkd_7XwQqOtI4fNol-PyGUV60Bfe8sABt59KpNNFGvpe1L" ..
                                              "-uSmPw2r6r-GD4gnO_NJnSHn-BKtz2CKc451HWIBa1iHBEbj3wJX8XXjGj8SR4TVAuljUQASnH4RC2EUz7Sqg" ..
                                              "uWDYqNyPHRkwERwq1aO6e9tCdIxrQaRh3CKNG5_OBkeH5IGC9avBNKy-j-Tp_l6HwFvXHWxq86bu84lujvaMn" ..
                                              "HBLvBtbFID2dxIcdF6VTltfV69vpd3Zyc91A8Co0vMQgW4Sdjym7s3nUw"

                        get_public_key_result = nil
                        get_public_key_err = "error"

                        local jwt_obj, err = jwt_utils.parse_bk_jwt_token(jwt_token)
                        assert.is_nil(jwt_obj)
                        assert.is_equal(err, "failed to get public_key of gateway test, error")
                    end
                )

                it(
                    "invalid public_key", function()
                        local jwt_token = "eyJhbGciOiJSUzUxMiIsImtpZCI6InRlc3QiLCJ0eXAiOiJKV1QiLCJpYXQiOjE1NjA0ODMxMTZ9.eyJpc3MiO" ..
                                              "iJBUElHVyIsImFwcCI6eyJhcHBfY29kZSI6ImFwaWd3LXRlc3QifSwidXNlciI6eyJ1c2VybmFtZSI6ImFkbWlu" ..
                                              "In0sImV4cCI6MTg3Mjc2ODI3OSwibmJmIjoxNTYwNDgzMTE2fQ.ask_dn8tdpjbEi_WELTVwHYWGPr8TFaAtGnZ" ..
                                              "cxPwLlieMvCkSMMjrT1bmCIoOBqpL0XiMxkd_7XwQqOtI4fNol-PyGUV60Bfe8sABt59KpNNFGvpe1L-uSmPw2r" ..
                                              "6r-GD4gnO_NJnSHn-BKtz2CKc451HWIBa1iHBEbj3wJX8XXjGj8SR4TVAuljUQASnH4RC2EUz7SqguWDYqNyPHR" ..
                                              "kwERwq1aO6e9tCdIxrQaRh3CKNG5_OBkeH5IGC9avBNKy-j-Tp_l6HwFvXHWxq86bu84lujvaMnHBLvBtbFID2d" ..
                                              "xIcdF6VTltfV69vpd3Zyc91A8Co0vMQgW4Sdjym7s3nUw"

                        get_public_key_result = "invalid"
                        get_public_key_err = nil

                        local jwt_obj, err = jwt_utils.parse_bk_jwt_token(jwt_token)
                        assert.is_nil(jwt_obj)
                        assert.is_equal(err, "failed to verify jwt, Decode secret is not a valid cert/public key")
                    end
                )

                it(
                    "invalid public key, format correct", function()
                        local jwt_token = "eyJhbGciOiJSUzUxMiIsImtpZCI6InRlc3QiLCJ0eXAiOiJKV1QiLCJpYXQiOjE1NjA0ODMxMTZ9.eyJpc3MiOiJ" ..
                                              "BUElHVyIsImFwcCI6eyJhcHBfY29kZSI6ImFwaWd3LXRlc3QifSwidXNlciI6eyJ1c2VybmFtZSI6ImFkbWluIn0s" ..
                                              "ImV4cCI6MTg3Mjc2ODI3OSwibmJmIjoxNTYwNDgzMTE2fQ.ask_dn8tdpjbEi_WELTVwHYWGPr8TFaAtGnZcxPwLl" ..
                                              "ieMvCkSMMjrT1bmCIoOBqpL0XiMxkd_7XwQqOtI4fNol-PyGUV60Bfe8sABt59KpNNFGvpe1L-uSmPw2r6r-GD4gn" ..
                                              "O_NJnSHn-BKtz2CKc451HWIBa1iHBEbj3wJX8XXjGj8SR4TVAuljUQASnH4RC2EUz7SqguWDYqNyPHRkwERwq1aO6" ..
                                              "e9tCdIxrQaRh3CKNG5_OBkeH5IGC9avBNKy-j-Tp_l6HwFvXHWxq86bu84lujvaMnHBLvBtbFID2dxIcdF6VTltfV" ..
                                              "69vpd3Zyc91A8Co0vMQgW4Sdjym7s3nUw"

                        get_public_key_result = string.gsub(jwt_public_key, "9", "8", 1)
                        get_public_key_err = nil

                        local jwt_obj, err = jwt_utils.parse_bk_jwt_token(jwt_token)
                        assert.is_nil(jwt_obj)
                        assert.is_equal(err, "failed to verify jwt, Decode secret is not a valid cert/public key")
                    end
                )

                it(
                    "exp expired", function()
                        local jwt_token = "eyJhbGciOiJSUzUxMiIsImtpZCI6InRlc3QiLCJ0eXAiOiJKV1QiLCJpYXQiOjE1NjA0ODMyMDd9.eyJpc3MiOiJBUE" ..
                                              "lHVyIsImFwcCI6eyJhcHBfY29kZSI6ImFwaWd3LXRlc3QifSwidXNlciI6eyJ1c2VybmFtZSI6ImFkbWluIn0sImV4cC" ..
                                              "I6MTU2MDQ4MzIwNywibmJmIjoxNTYwNDgzMjA3fQ.XpfknmZUPGiG6qUloMRdZ_aBmazbMxJtMtMYXNiWYaUG7X4E09e" ..
                                              "HKYaJilTLp0tVmiet1YxUnEYPW0gzbeZKP46sEt5qcbBtrov0VjCkH14PgjNGo2Rx6-S443Jz_LBRUw8R8XcmOMnA4_X" ..
                                              "lqIQVFqEB5M36suSeFucmLLgBoYdVNT_7TyYNe-A0RtFIFXkDDiMWWesHqxqP1aSfOa_TRnd7Fq_i3krPXO5IBuYtMdn" ..
                                              "xh7Dbz29bNCEeithKyx8KrzHQ3NnSMouG6eiw1XCVyETkausEEa5s9siDWDFkHPByXfSuMiYzvUnaFNnCB4H7fwpv6tg" ..
                                              "WPoeOE8BQGaKwMQ"

                        local jwt_obj, err = jwt_utils.parse_bk_jwt_token(jwt_token)
                        assert.is_nil(jwt_obj)
                        assert.is_equal(
                            err, "failed to verify jwt, 'exp' claim expired at Fri, 14 Jun 2019 03:33:27 GMT"
                        )
                    end
                )

                it(
                    "nbf invaild", function()
                        local jwt_token = "eyJhbGciOiJSUzUxMiIsImtpZCI6InRlc3QiLCJ0eXAiOiJKV1QiLCJpYXQiOjE1NjA0ODMyNDZ9.eyJpc3MiOiJBUE" ..
                                              "lHVyIsImFwcCI6eyJhcHBfY29kZSI6ImFwaWd3LXRlc3QifSwidXNlciI6eyJ1c2VybmFtZSI6ImFkbWluIn0sImV4cC" ..
                                              "I6MTg3Mjc2ODI3OSwibmJmIjoxODcyNzY4Mjc5fQ.JbL1-0K4wU26yzho-WotHLNnx6bkqR27Yi_up6L5VP_PvRklPZQ" ..
                                              "648fmphpPK5OeBNKpZ1pYVaO9KgTZaVDToZ1f0YRO_Pali6Mt7Q8SIaRmbeM4N9pVnyeSBVdS4I8c3baZYQSgBGgrgt8" ..
                                              "pwLPDe_FJ8Baz_Ftwb5uJQkQYPikjw60-GAuvAhtDyS5FbIwNXFY1KQDLOeVIbWlIwxgSQZwx6CiJXiawhqMJ-7ssAK4" ..
                                              "RXnlBoNI_A9KlIpNu0motRezmn1r0XwE-sTt1eBxgU9HveZYqj9uuU2H1nMlAMtrDzswuQJPZJrmfp6DlWWd0tlwr-4d" ..
                                              "tR3o4qQlDW5Hzrw"

                        local jwt_obj, err = jwt_utils.parse_bk_jwt_token(jwt_token)
                        assert.is_nil(jwt_obj)
                        assert.is_equal(
                            err, "failed to verify jwt, 'nbf' claim not valid until Sun, 06 May 2029 13:24:39 GMT"
                        )
                    end
                )

                it(
                    "ok", function()
                        local jwt_token = "eyJhbGciOiJSUzUxMiIsImtpZCI6InRlc3QiLCJ0eXAiOiJKV1QiLCJpYXQiOjE1NjA0ODMxMTZ9.eyJpc3MiOiJBU" ..
                                              "ElHVyIsImFwcCI6eyJhcHBfY29kZSI6ImFwaWd3LXRlc3QifSwidXNlciI6eyJ1c2VybmFtZSI6ImFkbWluIn0sImV4cCI6" ..
                                              "MTg3Mjc2ODI3OSwibmJmIjoxNTYwNDgzMTE2fQ.ask_dn8tdpjbEi_WELTVwHYWGPr8TFaAtGnZcxPwLlieMvCkSMMjrT1b" ..
                                              "mCIoOBqpL0XiMxkd_7XwQqOtI4fNol-PyGUV60Bfe8sABt59KpNNFGvpe1L-uSmPw2r6r-GD4gnO_NJnSHn-BKtz2CKc451" ..
                                              "HWIBa1iHBEbj3wJX8XXjGj8SR4TVAuljUQASnH4RC2EUz7SqguWDYqNyPHRkwERwq1aO6e9tCdIxrQaRh3CKNG5_OBkeH5I" ..
                                              "GC9avBNKy-j-Tp_l6HwFvXHWxq86bu84lujvaMnHBLvBtbFID2dxIcdF6VTltfV69vpd3Zyc91A8Co0vMQgW4Sdjym7s3nUw"

                        local jwt_obj, err = jwt_utils.parse_bk_jwt_token(jwt_token)
                        assert.is_nil(err)

                        local jwt_header = jwt_obj.header
                        local jwt_payload = jwt_obj.payload
                        jwt_header["iat"] = nil
                        jwt_payload["nbf"] = nil
                        jwt_payload["exp"] = nil

                        assert.is_same(
                            jwt_header, {
                                kid = "test",
                                typ = "JWT",
                                alg = "RS512",
                            }
                        )
                        assert.is_same(
                            jwt_payload, {
                                iss = "APIGW",
                                app = {
                                    app_code = "apigw-test",
                                },
                                user = {
                                    username = "admin",
                                },
                            }
                        )
                    end
                )
            end
        )
    end
)
