# config-watcher

watch the source config file, and sync changes to the dest file

used in container for watching apisix config file update

example: in standalone mode, we need to watch the source config file generate by operator, and sync to apisix

```bash
/data/bkgateway/bin/config-watcher -sourcePath /data/bkgateway/apisix-config -destPath /usr/local/apisix/conf -files apisix.yaml
```
