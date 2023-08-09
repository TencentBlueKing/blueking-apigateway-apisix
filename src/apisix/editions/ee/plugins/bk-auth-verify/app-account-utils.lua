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
local signature_mod = require("apisix.plugins.bk-auth-verify.signature")

local _M = {}

---@param auth_params table Auth params from request
---@return table|nil signature_verifier
function _M.get_signature_verifier(auth_params)
    local req_uri_args = core.request.get_uri_args()
    if (not pl_types.is_empty(bk_core.url.get_value(req_uri_args, "bk_signature")) or
        not pl_types.is_empty(bk_core.url.get_value(req_uri_args, "signature"))) then
        return signature_mod.signature_verifier_v1
    end

    return nil
end

return _M
