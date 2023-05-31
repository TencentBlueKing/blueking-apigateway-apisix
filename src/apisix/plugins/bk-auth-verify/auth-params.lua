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

local table_concat = table.concat
local string_format = string.format
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local setmetatable = setmetatable

local _M = {}

local mt = {
    __index = _M,
}

function _M.new(auth_params)
    return setmetatable(auth_params or {}, mt)
end

function _M.get(self, key)
    return self[key]
end

function _M.get_string(self, key)
    local value = self[key]
    if value == nil then
        return "", string_format("key %s not exists in auth parameters", key)
    end

    if type(value) ~= "string" then
        return "", string_format("value of key %s is not a string", key)
    end

    return value, nil
end

-- function _M.get_first_exist_string(self, ...)
--     local keys = {
--         ...,
--     }
--     for _, key in ipairs(keys) do
--         local value = self[key]
--         if value ~= nil then
--             return tostring(value), nil
--         end
--     end

--     return "", string_format("keys [%s] are not found in auth parameters", table_concat(keys, ", "))
-- end

function _M.get_first_no_nil_string_from_two_keys(self, key1, key2)
    -- replace get_first_exist_string, for better performance
    local value1 = self[key1]
    if value1 ~= nil then
        return tostring(value1), nil
    end

    local value2 = self[key2]
    if value2 ~= nil then
        return tostring(value2), nil
    end

    return "", string_format("keys [%s] are not found in auth parameters", key1 ..", " .. key2)
end

function _M.to_url_values(self)
    local values = {}
    for key, value in pairs(self) do
        values[key] = {
            tostring(value),
        }
    end

    return values
end

return _M
