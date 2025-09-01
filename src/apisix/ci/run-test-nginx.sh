#!/bin/bash

echo "start etcd"
nohup etcd >/tmp/etcd.log 2>&1 &

sleep 1

echo "copy the plugins/*"
# cp --verbose -r /bkgateway/apisix/plugins/* /usr/local/apisix/apisix/plugins/
cp -r /bkgateway/apisix/plugins/* /usr/local/apisix/apisix/plugins/

echo "copy the t/*"
# cp --verbose -r /bkgateway/t/* /usr/local/apisix/t/
cp -r /bkgateway/t/* /usr/local/apisix/t/

echo "register the bk-* plugins"
# append the bk plugins into the plugin list
ls /bkgateway/apisix/plugins/ | egrep "bk-.*.lua" | awk -F '.' '{print "    \""$1"\","}' | sed -i -e '265r /dev/stdin' /usr/local/apisix/apisix/cli/config.lua
# cat /usr/local/apisix/apisix/cli/config.lua


# cat /usr/local/apisix/conf/config.yaml

# why: bk-components/*.lua will error if the settings below is absent
echo "append the bk-apigateway config into user_yaml_config"
cat << EOF | sed -i '/my $profile = $ENV{"APISIX_PROFILE"};/r /dev/stdin' /usr/local/apisix/t/APISIX.pm
\$user_yaml_config = <<_EOC_;
bk_gateway:
  bkauth:
    authorization_keys:
      - "access_token"
      - "bk_app_code"
      - "bk_app_secret"
      - "bk_username"
    sensitive_keys:
      - "access_token"
      - "bk_app_secret"
  bkapp:
    bk_app_code: "bk-apigateway"
    bk_app_secret: "fake-secret"
  instance:
    id: "2c4562899afc453f85bb9c228ed6febd"
    secret: "fake-secret"
  hosts:
    apigw-dashboard:
      addr: "http://apigw-dashboard.example.com"
    authapi:
      addr: "http://authapi.example.com"
    bkauth-legacy:
      addr: "http://bkauth-legacy.example.com"
    bkauth:
      addr: "http://bkauth.example.com"
    login-tencent:
      addr: "http://login-tencent.example.com"
    login:
      addr: "http://login.example.com"
    ssm:
      addr: "http://ssm.example.com"
    bkcore:
      addr: "http://bkcore.example.com"
_EOC_
EOF

# cat /usr/local/apisix/t/APISIX.pm

echo "run test"


export OPENRESTY_PREFIX="/usr/local/openresty"

export PATH=$OPENRESTY_PREFIX/nginx/sbin:$OPENRESTY_PREFIX/luajit/bin:$OPENRESTY_PREFIX/bin:$PATH
export OPENSSL_PREFIX=$OPENRESTY_PREFIX/openssl3
export OPENSSL_BIN=$OPENSSL_PREFIX/bin/openssl


if [ -n "$1" ]; then
    CASE_FILE=$1
    FLUSH_ETCD=1 prove --timer -Itest-nginx/lib -I./ t/bk-00.t t/$CASE_FILE
else
    FLUSH_ETCD=1 prove --timer -Itest-nginx/lib -I./ t/bk-*.t
fi

