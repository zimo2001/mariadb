#!/bin/sh
# xinetd for my_init.d
exec /usr/sbin/xinetd -pidfile /run/xinetd.pid -f /etc/xinetd.conf -inetd_compat -filelog /var/log/xinetd.log
