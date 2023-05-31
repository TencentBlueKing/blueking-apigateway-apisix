#!/bin/sh
echo "starting......"

# start
echo "start apisix"
apisix start
echo "apisix started"
# sleep 5秒以规避apisix启动时空的apisix.yaml会使init_worker阶段失败的问题
sleep 5

# start nginx error to sentry
if [ x"${BK_APIGW_NGINX_ERROR_LOG_SENTRY_DSN}" != x"" ]
then
    echo "start sentrylogs to ship nginx error log to sentry"
    SENTRY_DSN="${BK_APIGW_NGINX_ERROR_LOG_SENTRY_DSN}" NGINX_ERROR_PATH="/usr/local/apisix/logs/error.log" sentrylogs --daemonize
fi
# if standaloneConfigPath not empty, watch the path
if [ x"${standaloneConfigPath}" != x"" ]
then
    echo "start config-watcher for ${standaloneConfigPath}"
    sh /data/bkgateway/bin/config-watcher-start.sh "-sourcePath ${standaloneConfigPath} -destPath /usr/local/apisix/conf -files apisix.yaml" &
    echo "config-watcher for ${standaloneConfigPath} started"
fi

echo "start config-watcher for ${apisixDebugConfigPath}(note: will wait until the container quit)"
# note the shell will wait here, so, YOU SHOULD NOT PUT ANY COMMANDS AFTER HERE
sh /data/bkgateway/bin/config-watcher-start.sh "-sourcePath ${apisixDebugConfigPath} -destPath /usr/local/apisix/conf -files debug.yaml -isConfigMap"


echo "done"

