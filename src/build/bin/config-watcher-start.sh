if [ x"${bkgatewayBaseDir}" == x"" ]
then
    bkgatewayBaseDir="/data/bkgateway/bin"
fi
pidfile="${bkgatewayBaseDir}/watcher.$RANDOM.pid"
echo "pid file $pidfile, for config-watcher $1"

while true
do
    if [ ! -f ${pidfile} ]
    then
        ${bkgatewayBaseDir}/config-watcher $1 &
        echo $! > ${pidfile}
        continue
    fi
    sleep 5
    pid=`cat ${pidfile}`
    if [ x"${pid}" == x"" ]
    then
        rm ${pidfile}
    fi
    pscontent=`ps -p ${pid} --no-headers`
    if [ x"$pscontent" == x"" ]
    then
        rm ${pidfile}
    fi
done
