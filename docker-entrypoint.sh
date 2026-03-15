#!/bin/sh
# Set timezone to Asia/Shanghai
export TZ=Asia/Shanghai
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime 2>/dev/null || true

# Clear Chrome profile locks before starting
rm -f /data/chrome-profile/SingletonLock 2>/dev/null
rm -f /data/chrome-profile/SingletonCookie 2>/dev/null
rm -f /data/chrome-profile/SingletonSocket 2>/dev/null

# Start supervisord
exec /usr/bin/supervisord -c /app/config/supervisord.conf "$@"
