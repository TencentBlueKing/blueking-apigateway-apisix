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

local core = require("apisix.core")

local string_lower = string.lower

local _M = {}

function _M.get_authorization_keys()
    local conf = core.config.local_conf()
    return core.table.try_read_attr(conf, "bk_gateway", "bkauth", "authorization_keys")
end

function _M.get_sensitive_keys()
    local conf = core.config.local_conf()
    return core.table.try_read_attr(conf, "bk_gateway", "bkauth", "sensitive_keys")
end

function _M.get_bkapp()
    local conf = core.config.local_conf()
    return core.table.try_read_attr(conf, "bk_gateway", "bkapp")
end

function _M.get_instance_id()
    local conf = core.config.local_conf()
    return core.table.try_read_attr(conf, "bk_gateway", "instance", "id")
end

function _M.get_instance_secret()
    local conf = core.config.local_conf()
    return core.table.try_read_attr(conf, "bk_gateway", "instance", "secret")
end

function _M.get_iam_addr()
    local conf = core.config.local_conf()
    return core.table.try_read_attr(conf, "bk_gateway", "hosts", "iam", "addr")
end

function _M.get_login_addr()
    local conf = core.config.local_conf()
    return core.table.try_read_attr(conf, "bk_gateway", "hosts", "login", "addr")
end

function _M.get_login_tencent_addr()
    local conf = core.config.local_conf()
    return core.table.try_read_attr(conf, "bk_gateway", "hosts", "login-tencent", "addr")
end

function _M.get_esb_addr()
    local conf = core.config.local_conf()
    return core.table.try_read_attr(conf, "bk_gateway", "hosts", "esb", "addr")
end

function _M.get_authapi_addr()
    local conf = core.config.local_conf()
    return core.table.try_read_attr(conf, "bk_gateway", "hosts", "authapi", "addr")
end

function _M.get_bkauth_addr()
    local conf = core.config.local_conf()
    return core.table.try_read_attr(conf, "bk_gateway", "hosts", "bkauth", "addr")
end

function _M.get_bkauth_legacy_addr()
    local conf = core.config.local_conf()
    return core.table.try_read_attr(conf, "bk_gateway", "hosts", "bkauth-legacy", "addr")
end

function _M.get_ssm_addr()
    local conf = core.config.local_conf()
    return core.table.try_read_attr(conf, "bk_gateway", "hosts", "ssm", "addr")
end


function _M.get_bk_apigateway_core_addr()
    local conf = core.config.local_conf()
    return core.table.try_read_attr(conf, "bk_gateway", "hosts", "bk-apigateway-core-api", "addr")
end

function _M.get_jwt_issuer()
    local conf = core.config.local_conf()
    return core.table.try_read_attr(conf, "bk_gateway", "jwt_issuer")
end


function _M.is_cache_disabled()
    local conf = core.config.local_conf()
    local cache_disabled = core.table.try_read_attr(conf, "bk_gateway", "cache", "disabled")
    return string_lower(cache_disabled or "false") == "true"
end

return _M
