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

local function parse_response(res, err, raise_for_status)
    if not (res and res.body) then
        return nil, err
    end

    if raise_for_status and res.status ~= 200 then
        return nil, "status code is " .. res.status
    end

    local result, _err = core.json.decode(res.body)
    if _err ~= nil then
        return nil, "response is not valid json"
    end

    return result
end

return {
    parse_response = parse_response,
}
