# APISIX 相关

## 插件开发

请参考文档 [plugins/README.md](./plugins/README.md)


## 插件测试

- 基于 busted 框架的单元测试：请参考文档 [tests/README.md](./tests/README.md)
- 基于 test-nginx 的功能测试：请参考文档 [t/README.md](./t/README.md)

```bash
# 构建单元测试镜像
make apisix-test-images

# 执行单元测试
make test
```

如果只是新增或变更了 `tests`或`t`目录下的文件，也可以分别执行 (加快测试速度)

```bash
# 基于test-nginx的测试
make test-nginx

# 基于busted的测试
make test-busted
```


## 版本切换

步骤一：python 环境安装 blue-krill

```bash
pip install blue-krill
```

步骤二：本地编辑切换版本

```bash
# 切换到ee
make edition-ee
```
