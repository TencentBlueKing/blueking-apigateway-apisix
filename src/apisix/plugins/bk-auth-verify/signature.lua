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

local pl_types = require("pl.types")
local core = require("apisix.core")
local bk_core = require("apisix.plugins.bk-core.init")

local ngx = ngx -- luacheck: ignore
local ngx_time = ngx.time
local ngx_update_time = ngx.update_time
local table_insert = table.insert
local table_concat = table.concat
local ipairs = ipairs
local tonumber = tonumber

local SignatureVerifierV1 = {
    version = "v1",
}

local SignatureVerifierV2 = {
    version = "v2",
}

local function check_nonce(bk_nonce)
    if bk_nonce == nil then
        return nil, "parameter bk_nonce required"
    end

    local nonce = tonumber(bk_nonce)
    if nonce == nil then
        return nil, "parameter bk_nonce is invalid, it should be a positive integer"
    end

    if nonce <= 0 then
        return nil, "parameter bk_nonce is invalid, it should be a positive integer"
    end

    return nonce
end

local function check_timestamp(bk_timestamp)
    if bk_timestamp == nil then
        return nil, "parameter bk_timestamp required"
    end

    local timestamp = tonumber(bk_timestamp)
    if timestamp == nil then
        return nil, "parameter bk_timestamp is invalid, it should be in time format"
    end

    ngx_update_time()
    if ngx_time() - timestamp > 300 then
        return nil, "parameter bk_timestamp has expired"
    end

    return timestamp
end

local function pop_signature(query)
    local signature = bk_core.url.get_value(query, "bk_signature")
    query["bk_signature"] = nil
    if not pl_types.is_empty(signature) then
        return signature
    end

    signature = bk_core.url.get_value(query, "signature")
    query["signature"] = nil
    return signature
end

local function validate_params(bk_nonce, bk_timestamp)
    local _, err = check_nonce(bk_nonce)
    if err ~= nil then
        return err
    end

    _, err = check_timestamp(bk_timestamp)
    if err ~= nil then
        return err
    end

    return nil
end

function SignatureVerifierV1.verify(self, app_secrets, auth_params) -- luacheck: no unused
    local query = core.request.get_uri_args()
    local bk_nonce = bk_core.url.get_value(query, "bk_nonce")
    local bk_timestamp = bk_core.url.get_value(query, "bk_timestamp")

    local err = validate_params(bk_nonce, bk_timestamp)
    if err ~= nil then
        return false, err
    end

    return self.validate_signature(app_secrets)
end

function SignatureVerifierV1.validate_signature(app_secrets)
    local buf = {}

    -- add method
    table_insert(buf, ngx.req.get_method())

    -- add path
    table_insert(buf, bk_core.request.get_request_path())

    -- add ?
    table_insert(buf, "?")

    -- add query, and get signature
    -- core.request 中 uri_args 为共享数据，pop_signature 会修改数据，因此先将数据 copy 一份
    local query = core.table.deepcopy(core.request.get_uri_args())
    local signature = pop_signature(query)
    if ngx.req.get_method() == "POST" then
        query["data"] = {
            core.request.get_body(),
        }
    end
    table_insert(buf, bk_core.url.encode_url_values(query))

    -- calculate and compare signature
    local content = table_concat(buf)
    for _, app_secret in ipairs(app_secrets) do
        local expected_signature = bk_core.hmac.calc_hmac_sha1_with_base64(app_secret, content)
        if expected_signature == signature then
            return true
        end
    end

    return false
end

function SignatureVerifierV2.verify(self, app_secrets, auth_params)
    local bk_nonce = auth_params:get("bk_nonce")
    local bk_timestamp = auth_params:get("bk_timestamp")

    local err = validate_params(bk_nonce, bk_timestamp)
    if err ~= nil then
        return false, err
    end

    return self.validate_signature(app_secrets, auth_params)
end

function SignatureVerifierV2.validate_signature(app_secrets, auth_params)
    local buf = {}

    -- add method
    table_insert(buf, ngx.req.get_method())
    table_insert(buf, "\n")

    -- add path
    table_insert(buf, bk_core.request.get_request_path())
    table_insert(buf, "\n")

    -- add query
    local query = core.request.get_uri_args()
    table_insert(buf, bk_core.url.encode_url_values(query))
    table_insert(buf, "\n")

    -- add body
    ngx.req.read_body()
    table_insert(buf, core.request.get_body())
    table_insert(buf, "\n")

    -- add auth params, and get signature
    local values = auth_params:to_url_values()
    local signature = pop_signature(values)
    table_insert(buf, bk_core.url.encode_url_values(values))

    -- calculate and compare signature
    local content = table_concat(buf)
    for _, app_secret in ipairs(app_secrets) do
        local expected_signature = bk_core.hmac.calc_hmac_sha1_with_hex(app_secret, content)
        if expected_signature == signature then
            return true
        end
    end

    return false
end

if _TEST then -- luacheck: ignore
    return {
        _check_nonce = check_nonce,
        _check_timestamp = check_timestamp,
        _pop_signature = pop_signature,
        _validate_params = validate_params,
        signature_verifier_v1 = SignatureVerifierV1,
        signature_verifier_v2 = SignatureVerifierV2,
    }
end

return {
    signature_verifier_v1 = SignatureVerifierV1,
    signature_verifier_v2 = SignatureVerifierV2,
}
