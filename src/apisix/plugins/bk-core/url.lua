--
-- TencentBlueKing is pleased to support the open source community by making
-- 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
-- Copyright (C) 2025 Tencent. All rights reserved.
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
local string_sub = string.sub
local pairs = pairs
local ipairs = ipairs
local table_insert = table.insert
local table_sort = table.sort
local table_concat = table.concat

local _M = {}

-- join two path, with only 1 slash between them
-- 'a' 'b' | 'a/' 'b' | 'a' '/b' | 'a/' '/b' -> 'a/b'
function _M.url_single_joining_slash(a, b)
    local a_slash = core.string.has_suffix(a, "/")
    local b_slash = core.string.has_prefix(b, "/")

    if a_slash and b_slash then
        return a .. string_sub(b, 2)

    elseif not a_slash and not b_slash then
        return a .. "/" .. b

    else
        return a .. b

    end
end

-- sort the key and do encode
-- No query escape for key and value before encode
function _M.encode_url_values(data)
    if pl_types.is_empty(data) then
        return ""
    end

    local keys = {}
    for key, _ in pairs(data) do
        table_insert(keys, key)
    end

    table_sort(keys)

    local buf = {}
    for _, key in ipairs(keys) do
        local vs = data[key]
        if type(vs) ~= "table" then
            vs = {
                vs,
            }
        end

        for _, v in ipairs(vs) do
            if not pl_types.is_empty(buf) then
                table_insert(buf, "&")
            end
            table_insert(buf, key)
            table_insert(buf, "=")
            table_insert(buf, v)
        end
    end

    return table_concat(buf)
end

-- Get the first value associated with the given key.
-- If there are no values associated with the key, Get returns the empty string.
-- Reference: https://github.com/golang/go/blob/master/src/net/url/url.go
function _M.get_value(values, key)
    if not values then
        return nil
    end

    local vs = values[key]
    if type(vs) == "table" then
        return vs[1]
    end

    return vs
end

return _M
