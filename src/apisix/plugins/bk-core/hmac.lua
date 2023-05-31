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

local ngx = ngx -- luacheck: ignore
local hmac_sha1 = ngx.hmac_sha1
local ngx_encode_base64 = ngx.encode_base64
local hex_encode = require("resty.string").to_hex

local _M = {}

-- 计算字符串的 Hmac 加密值，并以 hex 转码
function _M.calc_hmac_sha1_with_hex(key, content)
    local digest = hmac_sha1(key, content)
    return hex_encode(digest)
end

function _M.calc_hmac_sha1_with_base64(key, content)
    local digest = hmac_sha1(key, content)
    return ngx_encode_base64(digest)
end

return _M
