#!/bin/bash

echo "start etcd"
nohup etcd >/tmp/etcd.log 2>&1 &

sleep 1

echo "copy the plugins/*"
cp -r /bkgateway/apisix/plugins/* /usr/local/apisix/apisix/plugins/
# cp --verbose -r /bkgateway/apisix/plugins/* /usr/local/apisix/apisix/plugins/

echo "copy the t/*"
# cp --verbose -r /bkgateway/t/* /usr/local/apisix/t/
cp -r /bkgateway/t/* /usr/local/apisix/t/

echo "register the bk-* plugins"
ls /usr/local/apisix/apisix/plugins |
    egrep "bk-.*.lua" | awk -F '.' '{print "  - "$1}' |
    sed '1i\temp:' |
    yq ea -iPM '. as $item ireduce({}; . * $item) | .plugins += .temp | del(.temp)' /usr/local/apisix/conf/config-default.yaml -

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
      addr: "http://login.example"
    ssm:
      addr: "http://ssm.example.com"
    bkcore:
      addr: "http://bkcore.example.com"
_EOC_
EOF

# cat /usr/local/apisix/t/APISIX.pm

echo "run test"

export PATH=/usr/local/openresty/nginx/sbin:$PATH

prove t/bk-*.t
