# 基于 test-nginx 单元测试

基于 test-nginx 的接口测试，偏向于功能测试。

## 目录结构

```text
- apisix
    - ci: ci 相关脚本
        - Dockerfile.apisix-test-busted: 测试镜像 apisix-test-busted 的 Dockerfile
        - run-test-busted.sh: 执行 busted 单元测试的脚本
        - Dockerfile.apisix-test-nginx: 测试镜像 apisix-test-nginx 的 Dockerfile
        - run-test-nginx.sh: 执行 test-nginx 单元测试的脚本
    - plugins: 蓝鲸自定义插件
    - t: test-nginx 测试用例
    - tests: busted 单元测试
        - *.lua: 单元测试用例
        - **/*.lua: 单元测试用例
        - conf: 测试配置
            - config.yaml: apisix config.yaml 配置
            - nginx.conf: resty http-include 配置文件，用于启动测试时，设置 apisix 缓存、错误日志等 nginx 配置
    - logs: nginx error_log 日志
```

## 编写单元测试

- 新建 `t/插件名称.t` 文件，编写测试用例
- 执行 `make test`，执行单元测试用例

## Reference

- [apisix plugin develop](https://apisix.apache.org/docs/apisix/plugin-develop/)
- [apisix source code : t](https://github.com/apache/apisix/tree/master/t)
- [test-nginx](https://github.com/openresty/test-nginx)
- [test-nginx doc: user guide](https://openresty.gitbooks.io/programming-openresty/content/testing/index.html)

