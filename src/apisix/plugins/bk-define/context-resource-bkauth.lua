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

local setmetatable = setmetatable

local _M = {}

local mt = {
    __index = _M,
}

function _M.new(bk_resource_auth)
    return setmetatable(
        {
            verified_app_required = bk_resource_auth.verified_app_required or false,
            verified_user_required = bk_resource_auth.verified_user_required or false,
            resource_perm_required = bk_resource_auth.resource_perm_required or false,
            skip_user_verification = bk_resource_auth.skip_user_verification or false,
        }, mt
    )
end

function _M.get_verified_app_required(self)
    return self.verified_app_required
end

function _M.get_verified_user_required(self)
    return self.verified_user_required
end

function _M.get_resource_perm_required(self)
    return self.resource_perm_required
end

function _M.get_skip_user_verification(self)
    return self.skip_user_verification
end

return _M
