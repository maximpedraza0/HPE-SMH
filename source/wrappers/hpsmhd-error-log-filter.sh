#!/bin/sh
# hpe-mgmt: filter wrapper for /opt/hp/hpsmh/bin/rotatelogs.
#
# hpsmhd's smhpd.conf hard-pipes its ErrorLog into rotatelogs:
#   ErrorLog "|/opt/hp/hpsmh/bin/rotatelogs <path> 5M"
# and smhpd.conf is regenerated from a baked-in template by smhstart on
# every restart, so the directive itself is not user-overridable.
#
# install.sh swaps the vendor rotatelogs aside as rotatelogs.real and
# installs this script in its place.  We keep the same command-line
# interface (Apache passes the rotation args through "$@") and just drop
# known-cosmetic noise lines from the stream before they hit disk.
#
# Patterns silenced (all benign on the unRAID stack — see TASKS.md #7):
#   - mod_smh_config session-DBM open/read errors (the session DBM file
#     is never created on this stack; the warning fires per request).
#   - "hpsmhd PID->%d is running now!" status traces from /etc/init.d.
#   - AH00558 ServerName-not-set (smhpd.conf is regenerated, so we can't
#     fix the underlying directive — just suppress the noise).
#   - "/etc/hosts/<ip>.conf: Not a directory" legacy cma probe noise.
exec grep --line-buffered -vE \
  "mod_smh_config: unable to (open|read) (session information from DBM|DBM)|hpsmhd PID->[0-9]+ is (running|not running) now!|AH00558: hpsmhd: Could not reliably determine the server.s fully qualified domain name|/etc/hosts/[0-9.]+\.conf: Not a directory" \
  | exec /opt/hp/hpsmh/bin/rotatelogs.real "$@"
