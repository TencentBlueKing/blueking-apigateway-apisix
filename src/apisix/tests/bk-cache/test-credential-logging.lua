--
-- TencentBlueKing is pleased to support the open source community by making
-- 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
-- Copyright (C) Tencent. All rights reserved.
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
local core = require("apisix.core")
local bkauth = require("apisix.plugins.bk-components.bkauth")
local bklogin = require("apisix.plugins.bk-components.bklogin")
local ssm = require("apisix.plugins.bk-components.ssm")
local app_account = require("apisix.plugins.bk-cache.app-account")
local oauth2 = require("apisix.plugins.bk-cache.oauth2-access-token")
local bk_token = require("apisix.plugins.bk-cache.bk-token")
local access_token = require("apisix.plugins.bk-cache.access-token")
local access_token_define = require("apisix.plugins.bk-define.access-token")

local cases = {
    {
        name = "app secret",
        component = bkauth,
        method = "verify_app_secret",
        call = app_account.verify_app_secret,
        cache = app_account._verify_app_secret_fallback_lrucache,
        result = { existed = true, verified = true },
        app_code = "my_application",
    },
    {
        name = "OAuth2 token",
        component = bkauth,
        method = "verify_oauth2_access_token",
        call = oauth2.get_oauth2_access_token,
        cache = oauth2._oauth2_access_token_fallback_lrucache,
        result = { token = { active = true, bk_app_code = "my_application", exp = 2000000000 } },
    },
    {
        name = "BK token",
        component = bklogin,
        method = "get_username_by_bk_token",
        call = bk_token.get_username_by_bk_token,
        cache = bk_token._bk_token_fallback_lrucache,
        result = { username = "test_user" },
    },
    {
        name = "SSM token",
        component = ssm,
        method = "verify_access_token",
        call = access_token.get_access_token,
        cache = access_token._access_token_fallback_lrucache,
        result = { token = access_token_define.new("my_application", "test_user", 3600) },
    },
}

local credentials = {
    { value = "x", hint = "******" },
    { value = "abcdefghijkl", hint = "******" },
    { value = "abcdefghijklm", hint = "abcd******jklm" },
    { value = "abcd-private-credential-wxyz", hint = "abcd******wxyz" },
}

describe("fallback cache credential logs", function()
    for _, case in ipairs(cases) do
        describe(case.name, function()
            local logs
            local key

            before_each(function()
                logs = {}
                stub(core.log, "error", function(...)
                    local parts = { ... }
                    for i, part in ipairs(parts) do
                        parts[i] = tostring(part)
                    end
                    logs[#logs + 1] = table.concat(parts)
                end)
                stub(case.component, case.method, function()
                    return nil, "connection refused"
                end)
                stub(ssm, "is_configured", function()
                    return true
                end)
            end)

            after_each(function()
                core.log.error:revert()
                case.component[case.method]:revert()
                ssm.is_configured:revert()
                case.cache:delete(key)
            end)

            for _, credential in ipairs(credentials) do
                it("masks a credential of length " .. #credential.value, function()
                    local prefix = case.app_code and case.app_code .. ":" or ""
                    key = prefix .. credential.value
                    case.cache:set(key, case.result, 60)

                    local result, err
                    if case.app_code then
                        result, err = case.call(case.app_code, credential.value)
                    else
                        result, err = case.call(credential.value)
                    end

                    -- The original key still finds the original fallback result.
                    assert.is_nil(err)
                    assert.is_same(case.result.token or case.result.username or case.result, result)
                    assert.is_equal(1, #logs)
                    assert.is_truthy(string.find(logs[1], "key=" .. prefix .. credential.hint ..
                                                " result=", 1, true))
                    assert.is_nil(string.find(logs[1], "key=" .. key .. " result=", 1, true))
                    assert.is_truthy(string.find(logs[1], core.json.encode(case.result), 1, true))
                end)
            end
        end)
    end
end)
