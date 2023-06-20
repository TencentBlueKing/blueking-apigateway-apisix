#!/bin/bash

echo "start etcd"
nohup etcd >/tmp/etcd.log 2>&1 &

sleep 2

echo "copy the plugins/*"
cp -r /bkgateway/apisix/plugins/* /usr/local/apisix/apisix/plugins/

echo "copy the t/*"
cp -r /bkgateway/t/* /usr/local/apisix/t/

echo "run test"

export PATH=/usr/local/openresty/nginx/sbin:$PATH

prove t/bk_*.t
