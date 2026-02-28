#!/bin/sh
# Clear Chrome profile locks before starting
rm -f /data/chrome-profile/SingletonLock 2>/dev/null
rm -f /data/chrome-profile/SingletonCookie 2>/dev/null
rm -f /data/chrome-profile/SingletonSocket 2>/dev/null

# Start supervisord
exec /usr/bin/supervisord -c /app/config/supervisord.conf "$@"
