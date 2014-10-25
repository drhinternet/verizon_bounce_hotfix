#!/bin/bash

# reactivate-verizon-accounts - Reactivate accounts that Verizon generated
#   false hard bounces for in October 2014.

# Exit on any failure
set -o errexit

# Variables
temp_table="verizon__bounce_bad_addresses"
temp_table_s3_subscribers="verizon__studio3_subscribers"
export_dir="/var/hvmail/apache/htdocs/exports"
psql="/var/hvmail/postgres/8.3/bin/psql -v ON_ERROR_STOP=1 -U greenarrow greenarrow"
start_time="1413846000" # Mon, 20 Oct 2014 23:00:00 GMT / 18:00 CDT (1 hour before the first observed instance)
end_time="1413945000" # Wed, 22 Oct 2014 02:30:00 GMT / 21:30 CDT (8 hours after the last observed instance)
logfile="/var/hvmail/log/verizon_reactivation_engine.log"

# Redirect output to the log file, unless the user has specified not to
if [ "$SKIP_REDIRECTION" != "1" ]; then
  exec >> $logfile 2>&1
fi
function log() { echo "`date` $1"; }
log "----------------------"
log "Starting Verizon reactivation process"

# Create $temp_table, and insert the addresses to reactivate into it
log "Selecting bounces into temporary table"
echo "
  CREATE TABLE $temp_table AS
  SELECT *
  FROM   bounce_bad_addresses
  WHERE  type = 'h'
  AND    bouncetime >= $start_time
  AND    bouncetime <= $end_time
  AND    text ILIKE '%550%alias%'
  AND    email ILIKE '%@verizon.net'
" | $psql

# Create $export_dir
log "Creating export directory in Apache"
mkdir -p $export_dir
chown hvpostgres:hvpostgres $export_dir

# Password protect $export_dir if it's not already
if [ `cat /var/hvmail/control/httpd.custom.conf | grep '<Location /exports/>' | wc -l` = 0 ]; then
  cat << EOT >> /var/hvmail/control/httpd.custom.conf

### Begin Exports ###
<Location /exports/>
    AuthType Basic
    AuthName Restricted
    AuthUserFile /var/hvmail/control/htpasswd
    Require valid-user
</Location>
### End Exports ###
EOT

  # Restart Apache to activate password protection of the exports directory
  svc -t /service/hvmail-httpd
  sleep 15
  # If Apache doesn't sty up for at least 5 seconds, print an error, and notify DRH
  if [ `svstat /service/hvmail-httpd | /var/hvmail/libexec/perl -ne ' m/ (\d+) seconds/ && $1 < 4 && print ' | wc -l` != 0 ]; then
    echo
    echo "ERROR: GreenArrow's web server has not come back up yet. Please contact DRH Technical Support if it does not come back up within a few minutes:"
    echo "https://wiki.drh.net/confluence/display/ENGINEDOCS/Technical+Support+Contact+Info"
    echo "Username: docs"
    echo "Password: bacon"
    echo
    date | /var/hvmail/bin/mailsubj "Error: GreenArrow's Web Server did not come back up" notifications-to@drh.net
  fi
fi

# Export $temp_table to $export_dir
export_filename="$export_dir/$temp_table-`date +'%y%m%d%H%M%S'`.csv"
log "Writing contents of temporary table into $export_filename"
echo "COPY (SELECT * FROM $temp_table) TO STDOUT WITH DELIMITER ',' CSV HEADER" | $psql > $export_filename

# Delete matching rows from the bounce_bad_addresses table
log "Deleting bounces from bounce_bad_addresses table"
echo "DELETE FROM bounce_bad_addresses WHERE id IN (SELECT id FROM $temp_table)" | $psql

# Re-build SimpleMH's Bad Address Suppression database
log "Rebuilding SimpleMH's bad address suppression database"
/var/hvmail/bin/simplemh-get-bad-addresses || echo "SimpleMH bad address suppression database did not return success"

# Export matching events table rows to $export_dir
export_events_filename="$export_dir/$temp_table-events-`date +'%y%m%d%H%M%S'`.csv"
log "Exporting matching event table rows into $export_events_filename"
echo "
  BEGIN;

  CREATE TEMPORARY TABLE verizon__events AS
  SELECT *
  FROM   events
  WHERE  event_type = 'bounce_bad_address'
  AND    bounce_type = 'h'
  AND    event_time >= $start_time
  AND    event_time <= $end_time
  AND    bounce_text ILIKE '%550%alias%'
  AND    email ILIKE '%@verizon.net';

  \\COPY verizon__events TO '$export_events_filename' WITH DELIMITER ',' CSV HEADER
  DELETE FROM events WHERE id IN ( SELECT id FROM verizon__events );

  COMMIT;
" | $psql

# Reactivate Studio 3 subscribers
if [ -e /var/hvmail/apache/htdocs/ss ]; then
  # Create a temporary table containing the subscribers that we're going to update.
  log "Copying affected Studio 3 subscribers to a temporary table"
  echo "
    CREATE TABLE $temp_table_s3_subscribers AS
    SELECT ss_list_subscribers.subscriberid AS subscriberid,
           ss_list_subscribers.listid AS listid
    FROM   ss_list_subscribers, $temp_table
    WHERE  ss_list_subscribers.bounced != 0
    AND    LOWER($temp_table.email) = LOWER(ss_list_subscribers.emailaddress)
    AND    $temp_table.listid = ss_list_subscribers.listid::varchar
  " | $psql

  # Update the subscribers to not be bounced.
  log "Reactivating bounced subscribers"
  count_subquery="
    SELECT COUNT(1)
    FROM   ss_list_subscribers
    WHERE  bounced != 0
    AND    subscriberid IN ( SELECT subscriberid FROM $temp_table_s3_subscribers )
    AND    listid = ss_lists.listid
  "
  echo "
    BEGIN;

    UPDATE ss_lists
    SET    bouncecount    = bouncecount    - ( $count_subquery ),
           subscribecount = subscribecount + ( $count_subquery )
    WHERE  ss_lists.listid IN ( SELECT listid FROM $temp_table_s3_subscribers );

    UPDATE ss_list_subscribers
    SET    bounced = 0
    WHERE  bounced != 0
    AND    subscriberid IN ( SELECT subscriberid FROM $temp_table_s3_subscribers );

    COMMIT;
  " | $psql

  # Drop the subscribers temporary table.
  log "Dropping temporary subscribers table"
  echo "
    DROP TABLE $temp_table_s3_subscribers
  " | $psql
fi

# Update the 'removed' column in bounce_stats
log "Fixing 'bounce_stats.removed' value for the reactivated bounces"
echo "
  UPDATE bounce_stats
  SET    removed = removed - aa.count
  FROM (
    SELECT
      COUNT(1) AS count,
      LOWER(SUBSTRING($temp_table.email FROM (POSITION('@' IN email) + 1))) AS domain,
      $temp_table.listid AS listid,
      $temp_table.sendid AS sendid,
      $temp_table.code AS code,
      $temp_table.type AS type
    FROM
      $temp_table
    GROUP BY
      LOWER(SUBSTRING($temp_table.email FROM (POSITION('@' IN email) + 1))),
      $temp_table.listid,
      $temp_table.sendid,
      $temp_table.code,
      $temp_table.type
  ) aa
  WHERE
    aa.domain = bounce_stats.domain AND
    aa.listid = bounce_stats.listid AND
    aa.sendid = bounce_stats.sendid AND
    aa.code   = bounce_stats.code   AND
    aa.type   = bounce_stats.type
" | $psql

# Drop $temp_table
log "Dropping temporary bounce table"
echo "DROP TABLE $temp_table" | $psql
