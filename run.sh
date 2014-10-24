#!/bin/bash

if [ "$UID" -ne 0 ]; then
  echo "this must be run as root"
  exit 1
fi

working_dir="/root/verizon_bounce_hotfix"
engine_script="$working_dir/reactivate-engine-bounces.sh"
studio_script="$working_dir/reactivate-studio-bounces.rb"

mkdir -p $working_dir

if [ -d "/var/hvmail" ]; then
  curl https://raw.githubusercontent.com/drhinternet/verizon_bounce_hotfix/master/reactivate-engine-bounces.sh > $engine_script
  chmod u+x $engine_script
  $engine_script
fi

if [ -d "/var/hvmail/studio" ]; then
  curl https://raw.githubusercontent.com/drhinternet/verizon_bounce_hotfix/master/reactivate-studio-bounces.rb > $studio_script
  chmod u+x $studio_script

  cd /var/hvmail/studio
  cp $studio_script script/reactivate-bounced-subscribers

  script/reactivate-bounced-subscribers          \
    --no-dry-run                                 \
    --require-start-time '2014-10-20 18:00 CDT'  \
    --require-end-time '2014-10-21 21:30 CDT'    \
    --require-bounce-text-sql-like '%550%alias%' \
    --require-domain 'verizon.net'
fi

rm -rf $working_dir
