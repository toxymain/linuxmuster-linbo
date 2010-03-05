#!/bin/sh
# init.sh - System setup and hardware detection
# This is a busybox 1.1.3 init script
# (C) Klaus Knopper 2007
# License: GPL V2

# If you don't have a "standalone shell" busybox, enable this:
# /bin/busybox --install

# Ignore signals
trap "" 1 2 11 15

# Reset fb color mode
RESET="]R"
# ANSI COLORS
# Erase to end of line
CRE="[K"
# Clear and reset Screen
CLEAR="c"
# Normal color
NORMAL="[0;39m"
# RED: Failure or error message
RED="[1;31m"
# GREEN: Success message
GREEN="[1;32m"
# YELLOW: Descriptions
YELLOW="[1;33m"
# BLUE: System mesages
BLUE="[1;34m"
# MAGENTA: Found devices or drivers
MAGENTA="[1;35m"
# CYAN: Questions
CYAN="[1;36m"
# BOLD WHITE: Hint
WHITE="[1;37m"

CMDLINE=""
REMOTE_TAG="### LINBO REMOTE ###"

# Utilities

# test if variable is an integer
isinteger () {
 [ $# -eq 1 ] || return 1
 case $1 in
 *[!0-9]*|"") return 1;;
           *) return 0;;
 esac
}

# DMA
enable_dma(){
 case "$CMDLINE" in *\ nodma*) return 0 ;; esac
 for d in $(cd /proc/ide 2>/dev/null && echo hd[a-z]); do
  if test -d /proc/ide/$d; then
   MODEL="$(cat /proc/ide/$d/model 2>/dev/null)"
   test -z "$MODEL" && MODEL="[GENERIC IDE DEVICE]"
   echo "${BLUE}Enabling DMA acceleration for: ${MAGENTA}$d      ${YELLOW}[${MODEL}]${NORMAL}"
   echo "using_dma:1" >/proc/ide/$d/settings
  fi
 done
}

# create device nodes
udev_extra_nodes() {
  grep '^[^#]' /etc/udev/links.conf | \
  while read type name arg1; do
    [ "$type" -a "$name" -a ! -e "/dev/$name" -a ! -L "/dev/$name" ] ||continue
    case "$type" in
      L) ln -s $arg1 /dev/$name ;;
      D) mkdir -p /dev/$name ;;
      M) mknod -m 600 /dev/$name $arg1 ;;
      *) echo "links.conf: unparseable line ($type $name $arg1)" ;;
    esac
  done
}

# Setup
init_setup(){
 mount -t proc /proc /proc
 echo 0 >/proc/sys/kernel/printk

 # parse kernel cmdline
 CMDLINE="$(cat /proc/cmdline)"
 case "$CMDLINE" in *\ useide*) useide=yes;; esac
 case "$CMDLINE" in *\ debug*) debug=yes;; esac
 case "$CMDLINE" in *\ nonetwork*|*\ localmode*) localmode=yes;; esac

 # process parameters given on kernel command line
 for i in $CMDLINE; do

  case "$i" in

   # evalutate sata_nv options
   sata_nv.swnc=*)
    value="$(echo $i | awk -F\= '{ print $2 }')"
    echo "options sata_nv swnc=$value" > /etc/modprobe.d/sata_nv.conf
   ;;

   *=*)
    eval "$i"
   ;;

  esac

 done # cmdline

 # get optionally given start.conf location
 if [ -n "$conf" ]; then
  confpart="$(echo $conf | awk -F\: '{ print $1 }')"
  extraconf="$(echo $conf | awk -F\: '{ print $2 }')"
 fi

 mount -t sysfs /sys /sys
 mount -n -o mode=0755 -t tmpfs tmpfs /dev
 if [ -e /etc/udev/links.conf ]; then
  udev_extra_nodes
 fi

 loadkmap < /etc/german.kbd
 ifconfig lo 127.0.0.1 up
 hostname linbo
 klogd >/dev/null 2>&1
 syslogd -C 64k >/dev/null 2>&1

 # Enable CPU frequency scaling
 for i in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  [ -f "$i" ] && echo "ondemand" > "$i" 2>/dev/null
 done
}

# trycopyfromdevice device filename
trycopyfromdevice(){
 local RC=1
 local device=""
 case "$1" in /dev/*) device="$1" ;; *) device="/dev/$1" ;; esac
 if [ -b "$device" ] && mount -r "$device" /cache >/dev/null 2>&1; then
  if [ -e /cache/"$2" ]; then
   rm -f "$2"
   cp -f /cache/"$2" "$2" >/dev/null 2>&1
   RC="$?"
  fi
  umount /cache
 fi
 return "$RC"
}

# copyfromcache file - copies a file from cache to current dir
copyfromcache(){
 local major="" minor="" blocks="" device="" relax=""
 [ -b "$cache" ] && trycopyfromdevice "$cache" "$1" && return 0
 while read major minor blocks device relax; do
   [ -n "$device" ] && trycopyfromdevice "$device" "$1" && return 0
 done < /proc/partitions
 return 1
}

# modify cache entry in start.conf
modify_cache(){
 [ -s "$1" ] || return 1
 if grep -qi ^cache "$1"; then
  sed -e "s|^[Cc][Aa][Cc][Hh][Ee].*|Cache = $cache|g" -i "$1"
 else
		sed -e "/^\[LINBO\]/a\
Cache = $cache" -i "$1"
 fi
}

# print cache partition
printcache(){
 local cachedev=""
 if [ -n "$cache" ]; then
  cachedev="$cache"
 else
  cachedev="$(grep -i ^cache /start.conf | tail -1 | awk -F\= '{ print $2 }' | awk '{ print $1 }')"
 fi
 [ -b "$cachedev" ] && echo "$cachedev"
}

# copytocache file - copies start.conf to local cache
copytocache(){
 # do not copy start.conf in remote control mode
 grep "$REMOTE_TAG" /start.conf && return 0
 local cachedev="$(printcache)"
 case "$cachedev" in
  /dev/*) # local cache
   mount "$cachedev" /cache || return 1
   cp -a /start.conf /cache
   [ "$cachedev" = "$cache" ] && modify_cache /cache/start.conf
   umount /cache || umount -l /cache
   ;;
  *)
   echo "No local cache partition found!"
   return 1
   ;;
 esac
}

# copy extra start.conf given on cmdline
copyextra(){
 [ -z "$confpart" ] && return 1
 [ -z "$extraconf" ] && return 1
 mkdir -p /extra
 mount "$confpart" /extra || return 1
 local RC=1
 if [ -s "/extra$extraconf" ]; then
  cp "/extra$extraconf" /start.conf ; RC="$?"
  umount /extra || umount -l /extra
 else
  RC=1
 fi
 return "$RC"
}

# Try to read the first valid ip address from all up network interfaces
get_ipaddr(){
 local ip=""
 while read line; do
  case "$line" in *inet\ addr:*)
   ip="${line##*inet addr:}"
   ip="${ip%% *}"
   case "$ip" in 127.0.0.1) continue;; esac
   [ -n "$ip" ] && { echo "$ip"; return 0; }
   ;;
  esac
 done <<.
$(ifconfig)
.
 return 1
}

# Utilities
# get_hostname ip
get_hostname(){
 local NAME=""
 local key=""
 local value=""
 # Try dhcp info first.
 if [ -f "/tmp/dhcp.log" ]; then
  NAME="`grep ^hostname /tmp/dhcp.log | tail -1 | cut -f2 -d"'"`"
  [ -n "$NAME" ] && { echo "$NAME"; return 0; }
 fi
 # Then DNS
 if [ -n "$1" ] && grep -q ^nameserver /etc/resolv.conf; then
  while read key value relax; do
   case "$key" in
    Name:) NAME="${value%%.*}" ; break ;;
   esac
  done <<.
$(nslookup "$1" 2>/dev/null)
.
 [ -n "$NAME" ] && { echo "$NAME"; return 0; }
 fi
 return 1
}

# Get server address.
get_server(){
 local ip=""
 local a=""
 local b=""
 # First try servername from dhcp.log:siaddr.
 if [ -f "/tmp/dhcp.log" ]; then
  ip="`grep ^siaddr /tmp/dhcp.log | tail -1 | cut -f2 -d"'"`"
  [ -n "$ip" ] && { echo "$ip"; return 0; }
 fi
 # Second guess from route.
 while read a b relax; do
  case "$a" in 0.0.0.0)
   ip="$b"
   [ -n "$ip" ] && { echo "$ip"; return 0; }
   ;;
  esac
 done <<.
$(route -n)
.
 return 1
}

# check if reboot is set in start.conf
isreboot(){
 if [ -s /start.conf ]; then
  grep -i ^kernel /start.conf | awk -F= '{ print $2 }' | awk '{ print $1 }' | tr A-Z a-z | grep -q reboot && return 0
 fi
 return 1
}

# remove linbo reboot flag
rmlinboreboot(){
 isreboot || return 0
 local device="" properties="" cachedev="$(printcache)"
 sfdisk -l | grep ^/dev | grep -v Extended | grep -v "Linux swap" | while read device properties; do
  [ "$cachedev" = "$device" ] && continue
  if mount "$device" /mnt; then
   [ -e /mnt/.linbo.reboot ] && rm -f /mnt/.linbo.reboot
   [ -e /mnt/.grub.reboot ] && rm -f /mnt/.grub.reboot
   umount /mnt
  fi
 done
}

# get DownloadType from start.conf
downloadtype(){
 local RET=""
 if [ -s /start.conf ]; then
  RET="$(grep -i ^downloadtype /start.conf | tail -1 | awk -F= '{ print $2 }' | awk '{ print $1 }' | tr A-Z a-z)"
  # get old option for compatibility issue
  if [ -z "$RET" ]; then
   RET="$(grep -i ^usemulticast /start.conf | tail -1 | awk -F= '{ print $2 }' | awk '{ print $1 }' | tr A-Z a-z)"
   [ "$RET" = "yes" ] && RET="multicast"
  fi
 fi
 echo "$RET"
}

# handle autostart from cmdline
set_autostart() {
 # do set autostart in remote control mode
 grep "$REMOTE_TAG" /start.conf && return 0
 # count [OS] entries
 local counts="$(grep -ci ^"\[OS\]" /start.conf)"
 # return if autostart value is greater than number of OS entries
 [ $autostart -gt $counts -o $autostart -lt 0 ] && return
 # return if autostart shall be suppressed generally
 if [ "$autostart" = "0" ]; then
  # set all autostart parameters to no
  sed -e 's|^[Aa][Uu][Tt][Oo][Ss][Tt][Aa][Rr][Tt].*|Autostart = no|g' -i /start.conf
  return
 fi
 # autostart OS at start.conf position given by autostart parameter
 local c=0
 local found=0
 local line=""
 while read -r line; do
  if echo "$line" | grep -qi ^"\[OS\]"; then
   let c=+1
   [ "$autostart" = "$c" ] && found=1
  fi
  # suppress autostart for other OS entries
  echo "$line" | grep -qi ^autostart || echo "$line" >> /start.conf.new
  # write autostart line for specific OS
  if [ "$found" = "1" ]; then
   echo "Autostart = yes" >> /start.conf.new
   found=0
  fi
 done </start.conf
 mv /start.conf.new /start.conf
}

network(){
 [ -n "$localmode" ] && { touch /tmp/linbo-network.done; return 0; }
 rm -f /tmp/linbo-network.done
 if [ -n "$ipaddr" ]; then
  [ -n "$netmask" ] && nm="netmask $netmask" || nm=""
  ifconfig ${netdevice:-eth0} $ipaddr $nm
 else
  for i in /sys/class/net/*; do
   [ -d "$i" ] || continue
   dev="${i##*/}"
   case "$dev" in lo*|br*) continue;; esac
   ifconfig "$dev" up >/dev/null 2>&1
   udhcpc -n -i "$dev" >/dev/null 2>&1
  done
 fi
 # Network is up now, fetch a new start.conf
 # If server, ipaddr and cache are not set on cmdline, try to guess.
 [ -n "$ipaddr" ] || ipaddr="`get_ipaddr`"
 [ -n "$hostname" ] || hostname="`get_hostname $ipaddr`"
 [ -n "$hostname" ] && hostname "$hostname"
 [ -n "$server" ] || server="`get_server`"
 # Move away old start.conf and look for updates
 mv -f start.conf start.conf.dist
 if [ -n "$server" ]; then
  echo "linbo_server='$server'" >> /tmp/dhcp.log
  echo "mailhub=$server:25" > /etc/ssmtp/ssmtp.conf
  for i in "start.conf-$ipaddr" "start.conf"; do
   rsync -L "$server::linbo/$i" "start.conf" >/dev/null 2>&1 && break
  done
  # also look for other needed files
  for i in "torrent-client.conf" "multicast.list"; do
   rsync -L "$server::linbo/$i" "/$i" >/dev/null 2>&1
  done
 fi
 # copy start.conf optionally given on cmdline
 copyextra && local extra=yes
 if [ ! -s start.conf ]; then
  # No new version / no network available, look for a cached copy.
  copyfromcache start.conf
 else
  # flag for network connection
  echo > /tmp/network.ok
  # copy start.conf to cache if no extra start.conf was given on cmdline
  [ -z "$extra" ] && copytocache
 fi
 # Still nothing new, revert to old version.
 [ -s start.conf ] || mv -f start.conf.dist start.conf
 # modify cache in start.conf if cache was given and no extra start.conf was defined
 [ -z "$extra" -a -b "$cache" ] && modify_cache /start.conf
 # set autostart if given on cmdline
 isinteger "$autostart" && set_autostart
 # remove reboot flag
 rmlinboreboot
 # activate wol
 for i in `ifconfig | grep ^eth | cut -f1 -d" "`; do
  echo "Activating wol on $i ..."
  ethtool -s $i wol g
 done
 echo > /tmp/linbo-network.done 
}

# HW Detection
hwsetup(){
 rm -f /tmp/linbo-cache.done
 echo "## Hardware-Setup - Begin ##" >> /tmp/linbo.log

 if [ -n "$useide" ]; then
  echo "Using ide modules ..."
  rm -rf /lib/modules/`uname -r`/kernel/drivers/ata
 else
  echo "Using pata/sata modules ..."
  rm -rf /lib/modules/`uname -r`/kernel/drivers/ide
 fi
 depmod -a

 #
 # Udev starten
 echo > /sys/kernel/uevent_helper
 udevd --daemon
 mkdir -p /dev/.udev/db/ /dev/.udev/queue/
 udevadm trigger
 mount /dev/pts
 udevadm settle || true

 #
 # Load acpi fan and thermal modules if available, to avoid machine
 # overheating.
 modprobe fan >/dev/null 2>&1 || true
 modprobe thermal >/dev/null 2>&1 || true

 export TERM_TYPE=pts
 
 dmesg >> /tmp/linbo.log
 echo "## Hardware-Setup - End ##" >> /tmp/linbo.log

 sleep 2
 echo > /tmp/linbo-cache.done 
}

# Main
#clear
echo
echo 'Welcome to'
echo ' _        _   __     _   ____      _____'
echo '| |      | | |  \   | | |  _ \    / ___ \'
echo '| |      | | |   \  | | | | | |  / /   \ \'
echo '| |      | | | |\ \ | | | |/ /  | |     | |'
echo '| |      | | | | \ \| | | |\ \  | |     | |'
echo '| |____  | | | |  \   | | |_| |  \ \___/ /'
echo '|______| |_| |_|   \__| |____/    \_____/'
echo

# Initial setup
if [ -n "$debug" ]; then
 init_setup
else
 init_setup >/dev/null 2>&1
fi

# BG processes (HD and Network detection can run in parallel)
if [ -n "$debug" ]; then
 hwsetup
 network &
else
 hwsetup >/dev/null 2>&1
 network >/dev/null 2>&1 &
fi

# start dropbear
/sbin/dropbear -s -g -E -p 2222

