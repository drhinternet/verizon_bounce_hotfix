#!/bin/bash

if [ "$UID" -ne 0 ]; then
  echo "this must be run as root"
  exit 1
fi

working_dir="/root/verizon_bounce_hotfix"
engine_script="$working_dir/reactivate-engine-bounces.sh"
studio_script="$working_dir/reactivate-studio-bounces.rb"

mkdir -p $working_dir

if [ -e "/var/hvmail" ]; then
  if [ -e "/var/hvmail/apache/htdocs/ss" ]; then
    echo "Processing GreenArrow Engine and GreenArrow Studio 3 ..."
  else
    echo "Processing GreenArrow Engine ..."
  fi

  curl -fsSL https://raw.githubusercontent.com/drhinternet/verizon_bounce_hotfix/master/reactivate-engine-bounces.sh > $engine_script
  chmod u+x $engine_script
  $engine_script
fi

if [ -e "/var/hvmail/studio" ]; then
  echo "Processing GreenArrow Studio 4 ..."

  curl -fsSL https://raw.githubusercontent.com/drhinternet/verizon_bounce_hotfix/master/reactivate-studio-bounces.rb > $studio_script
  chmod u+x $studio_script

  cd /var/hvmail/studio
  cp $studio_script script/reactivate-bounced-subscribers

  script/reactivate-bounced-subscribers          \
    --no-dry-run                                 \
    --require-start-time '2014-10-20 18:00 CDT'  \
    --require-end-time '2014-10-21 21:30 CDT'    \
    --require-bounce-text-sql-like '%550%alias%' \
    --require-domain 'verizon.net'               \
    &> /var/hvmail/log/verizon_reactivation_studio.log
fi

rm -rf $working_dir

echo "Processing complete! The bad bounces generated from this incident have been cleaned up."
