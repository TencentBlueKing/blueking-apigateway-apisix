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

local access_token_cache = require("apisix.plugins.bk-cache.access-token")
local app_account_cache = require("apisix.plugins.bk-cache.app-account")
local jwt_key_cache = require("apisix.plugins.bk-cache.jwt-key")
local bk_token_cache = require("apisix.plugins.bk-cache.bk-token")
local bk_app_tenant_cache = require("src.apisix.plugins.bk-cache.app-tenant-info")
local bk_user_tenant_cache = require("src.apisix.plugins.bk-cache.user-tenant-info")

return {
    get_access_token = access_token_cache.get_access_token,
    verify_app_secret = app_account_cache.verify_app_secret,
    list_app_secrets = app_account_cache.list_app_secrets,
    get_jwt_public_key = jwt_key_cache.get_jwt_public_key,
    get_username_by_bk_token = bk_token_cache.get_username_by_bk_token,
    get_user_tenant_info = bk_user_tenant_cache.get_user_info,
    get_app_tenant_info = bk_app_tenant_cache.get_app_tenant_info,
}
