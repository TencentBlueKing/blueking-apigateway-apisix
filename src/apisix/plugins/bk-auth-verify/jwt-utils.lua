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

-- https://github.com/SkyLothar/lua-resty-jwt
local pl_types = require("pl.types")
local jwt = require("resty.jwt")
local jwt_validators = require("resty.jwt-validators")
local core = require("apisix.core")
local bk_core = require("apisix.plugins.bk-core.init")
local bk_cache = require("apisix.plugins.bk-cache.init")
local ngx = ngx -- luacheck: ignore
local ngx_time = ngx.time
local ngx_update_time = ngx.update_time
local pcall = pcall
local string_format = string.format

local DEFAULT_JWT_ISSUER = "APIGW"

local jwt_issuer = bk_core.config.get_jwt_issuer()

local _M = {}

function _M.generate_bk_jwt_token(kid, private_key, data, expiration)
    ngx_update_time()
    local now = ngx_time()

    local header = {
        kid = kid,
        typ = "JWT",
        alg = "RS512",
        iat = now,
    }

    -- iss in header and claims should be the same,
    -- if iss is empty, just set the default iss in claims to be consistent with legacy,
    -- apigw-manager sdk may use iss in header to handle gateway public key
    local issuer = DEFAULT_JWT_ISSUER
    if not pl_types.is_empty(jwt_issuer) then
        header.iss = jwt_issuer
        issuer = jwt_issuer
    end

    local payload = {
        iss = issuer,
        nbf = now - 300,
        exp = now + expiration,
    }
    payload = core.table.merge(payload, data)

    local ok, jwt_token = pcall(
        jwt.sign, _M, private_key, {
            header = header,
            payload = payload,
        }
    )
    if not ok then
        core.log.error("failed to sign jwt, err: ", jwt_token.reason)
        -- don't cache error
        return nil, "failed to sign jwt, " .. jwt_token.reason
    end
    return jwt_token
end

function _M.parse_bk_jwt_token(jwt_token)
    local jwt_obj = jwt:load_jwt(jwt_token)
    if not jwt_obj.valid then
        return nil, "JWT Token invalid"
    end

    local kid = jwt_obj.header and jwt_obj.header.kid
    if not kid then
        return nil, "missing kid in JWT token"
    end

    local public_key, err = bk_cache.get_jwt_public_key(kid)
    if pl_types.is_empty(public_key) then
        return nil, string_format("failed to get public_key of gateway %s, %s", kid, err)
    end

    local verified_jwt_obj = jwt:verify_jwt_obj(
        public_key, jwt_obj, {
            nbf = jwt_validators.is_not_before(),
            exp = jwt_validators.is_not_expired(),
        }
    )

    if not verified_jwt_obj.verified then
        return nil, "failed to verify jwt, " .. jwt_obj.reason
    end

    return verified_jwt_obj
end

return _M
