# 插件单元测试

apisix 原生测试，是基于 test-nginx 的接口测试，偏向于功能测试。为更好地测试插件内部逻辑，推荐为每个插件开发单元测试。

## 单元测试框架

蓝鲸插件单元测试，采用 [busted 框架](https://olivinelabs.com/busted/)，引入 [busted_resty](https://github.com/Triple-Z/busted_resty/blob/main/src/busted_resty.lua) 对 ngx 进行 mock。

busted 框架使用 [luassert libary](https://github.com/Olivine-Labs/luassert) 提供 assertions，其支持多种断言写法，推荐采用其中一组简洁的断言方案，如：

```lua
assert.is_nil(err)
assert.is_true(ok)
assert.is_false(ok)
assert.is_equal(1, 1)
assert.is_same({bk_app_code = "my-app"}, {bk_app_code = "my-app"})

assert.stub(s).was_called_with("derp")
assert.stub(s).was_called()
assert.stub(s).was_called(2) -- twice!
assert.stub(s).was_not_called()
s:clear()
s:revert()
```

## 开发单元测试

单元测试用例统一放在 apisix/tests/ 目录下，测试文件以 "test-" 开头，例如：apisix/tests/test-example.lua。编写完测试用例后，第一次执行 `make apisix-test-image` 构建本地测试镜像后，每次只要执行 `make test` 即可。

### 目录结构

```text
- apisix
    - plugins: 蓝鲸自定义插件
    - tests: 单元测试
        - *.lua: 单元测试用例
        - **/*.lua: 单元测试用例
        - conf: 测试配置
            - config.yaml: apisix config.yaml 配置
            - nginx.conf: resty http-include 配置文件，用于启动测试时，设置 apisix 缓存、错误日志等 nginx 配置
        - Dockerfile.apisix-unittest: 测试镜像 apisix-test-image 的 Dockerfile
        - run-test.sh: 执行单元测试的脚本
    - logs: nginx error_log 日志
```

## 执行单元测试

在目录 apisix 下，

1. `make apisix-test-image`，构建本地测试镜像（Dockerfile.apisix-unittest 未变动时，执行一次即可）
2. `make test`，执行单元测试用例

## 常用测试方案

### stub

使用 stub 来模拟接口的返回值，具体样例参考 apisix/tests/test-bk-jwt.lua。

1. stub 时，被替换的方法不会真正执行
2. 可通过设置 stub 第 3 个参数为回调方法，设置 stub 的返回值，具体参考：[luassert stub](https://github.com/Olivine-Labs/luassert/blob/master/src/stub.lua)
3. 在 before_each 中 stub，在 after_each 中 revert 该 stub

### 自定义插件中的 local function 如何测试

在单元测试中，如何测试自定义插件中的 local function 私有方法。

可采用以下方案：

```lua
local _M = {}

local function get_access_token(access_token)
    return {bk_app_code = "my-app"}, nil
end

-- export locals for test
-- 在 busted_runner.lua 中，已设置 _G._TEST 为 true
if _TEST then
    -- setup test alias for private elements using a modified name
    _M._get_access_token = get_access_token
end

return _M
```

在单元测试文件中

```lua
local my_plugin = require("apisix.plugins.my-plugin")

describe("Going to test a private element", function()
    it("tests the private function", function()
        local token, err = my_plugin._get_access_token("fake-token")
        assert.is_nil(err)
        assert.is_equal(token, {bk_app_code = "my-app"})
    end)
end)
```

### apisix lrucache

直接使用 apisix lrucache 缓存，将报错："failed to create lock: dictionary not found"。

原因：apisix lrucache 依赖 ngx.shared，ngx.shared 中需存在对应的缓存 key lrucache-lock，如果没有，则会报错。

解决方案：通过 resty 参数 --http-include 指定 nginx http 配置文件，在其中添加配置：`lua_shared_dict lrucache-lock 1m;` 即可设置 apisix lrucache 所需 lrucache-lock 缓存。具体配置参考：apisix/conf/nginx-test.conf。

## Reference

- https://github.com/Olivine-Labs/luassert/blob/master/spec/assertions_spec.lua
- https://github.com/Triple-Z/busted_resty/blob/main/src/busted_resty.lua
- https://github.com/slembcke/debugger.lua#debugger-commands
