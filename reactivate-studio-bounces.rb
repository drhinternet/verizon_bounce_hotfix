#!/var/hvmail/ruby/bin/ruby

=begin

This tool is designed to re-enable subscribers that were disabled by a bounce.
It is designed to be used for when ISPs erroneously send bounce messages that
deactivate subscribers.

There are a number of options prefixed with `--require-` to whittle down the
bounces that are re-activated.

Run this script with `--help` to get a description of all available arguments.

When run, the following happens:
  For all matching bounce messages where:
    * the bounce record indicates that the subscriber status was changed
    * the bounce record matches all specified filters
    * the subscriber status is currently set to bounced
    * the subscriber's domain matches one of the specified domains
  The following is done:
    * The subscriber's status is updated to active
    * The bounce record and campaign statistics are updated to indicate that the subscriber was not removed due to this bounce
    * The count of subscriber changes over time for the mailing list is updated as if this subscriber was never removed due to the bounce

=end

require "rubygems"
require "optparse"
require "optparse/time"
require "pp"

options = {}

# Load options
OptionParser.new do |opts|
  opts.banner = "Usage: reactivate-bounced-subscribers [options]"

  opts.on(
    "--require-bounce-code [CODE]",
    OptionParser::DecimalInteger,
    "If provided, only matches bounces that have the provided bounce code"
  ) do |arg|
    options[:bounce_code] = Integer(arg)
  end

  opts.on(
    "--require-domain [DOMAINS]",
    String,
    "Require that the email address of the subscriber match the domain name provided. May be a comma separated list of multiple domain names."
  ) do |arg|
    options[:domains] = arg.to_s.split(",").map(&:strip).reject(&:empty?).map(&:downcase)
  end

  opts.on(
    "--require-bounce-text-sql-like [SQL]",
    String,
    "Require that bounce text (only available on version v4.26.0 and above) match the provided SQL LIKE (e.g. '%this%that%') statement"
  ) do |arg|
    options[:bounce_text_sql] = arg.to_s
  end

  opts.on(
    "--require-start-time [TIME]",
    Time,
    "Require that the bounce happened no earlier than the specified time (e.g. 'October 20, 2014 5:00pm cdt')"
  ) do |arg|
    options[:start_time] = arg
  end

  opts.on(
    "--require-end-time [TIME]",
    Time,
    "Require that the bounce happened no later than the specified time (e.g. 'October 22, 2014 5:00pm cdt')"
  ) do |arg|
    options[:end_time] = arg
  end

  opts.on(
    "--[no-]print-subscriber",
    "Print details about each affected subscriber (Default: false)"
  ) do |arg|
    options[:print_subscriber] = !!arg
  end

  opts.on(
    "--[no-]print-sql",
    "Print the SQL queries executed in this process (Default: false)"
  ) do |arg|
    options[:print_sql] = !!arg
  end

  opts.on(
    "--[no-]dry-run",
    "Don't actually update subscribers, just print the number of subscribers that would be updated"
  ) do |arg|
    options[:dry_run] = !!arg
  end
end.parse!

# Require the dry-run parameter, whether on or off
if options[:dry_run] == nil
  puts "Please specify either --dry-run or --no-dry-run"
  exit 1
end

# Don't proceed if we've specified a domains filter with none present
if options[:domains] != nil && options[:domains].length == 0
  puts "Domains argument was specified with no domains"
  exit 1
end

# Echo the calculated options.
puts "Input options:"
pp options
puts

# Helpers and datapoints
sql_exec               = -> sql { ActiveRecord::Base.connection.execute(sql) }
is_dry_run             = options[:dry_run] != false
commit_sql             = if is_dry_run then "ROLLBACK" else "COMMIT" end
transaction_started_at = Time.now
transaction_ready      = -> { transaction_started_at < 10.seconds.ago }
transaction_commit     = -> { sql_exec["#{ commit_sql }; BEGIN"]; transaction_started_at = Time.now }
subscribers_updated    = 0
stats_processed        = 0

# Verify that the version number is v4.26.0 or newer if we have requested a bounce text sql
if options[:bounce_text_sql] != nil
  version_filename = "/var/hvmail/studio/doc/VERSION.tag"

  if ! File.readable? version_filename
    puts "Cannot read version file #{ version_filename }"
    exit 1
  end

  version_number = File.read(version_filename).chomp.gsub(/^v/, "")

  if Gem::Version.new(version_number) < Gem::Version.new("4.26.0")
    puts "Studio version is #{ version_number }, but --require-bounce-text-sql can only be used in 4.26.0 and above"
    exit 1
  end
end

# Load Studio
require File.join(File.expand_path(File.dirname(__FILE__)), "..", "config", "environment")

# Wire ActiveRecord's logger to STDOUT if we're in verbose mode
if options[:print_sql] == true
  ActiveRecord::Base.logger = Logger.new(STDOUT)
end

ActiveRecord::Base.transaction do
  # Get the AREL object that contains affected bounces
  bounces = Stats::StatBounce
  bounces = bounces.where(status_updated: true)
  bounces = bounces.where("time >= ?", options[:start_time])               if options[:start_time] != nil
  bounces = bounces.where("time <= ?", options[:end_time])                 if options[:end_time]   != nil
  bounces = bounces.where(bounce_code: options[:bounce_code])              if options[:bounce_code] != nil
  bounces = bounces.where("bounce_text LIKE ?", options[:bounce_text_sql]) if options[:bounce_text_sql] != nil

  # Get the list of stats that have candidate bounces
  stat_ids = bounces.pluck("DISTINCT stat_id")
  puts "Found #{ stat_ids.count } affected stats"

  # Iterate over those stats, checking for invalid subscribers
  Stats::Stat.where(id: stat_ids).each do |stat|
    # Log progress
    stats_processed += 1
    puts if options[:print_subscriber] || options[:print_sql]
    puts "Processing stat_id=#{ stat.id } #{ stats_processed } / #{ stat_ids.length }"

    # Get the mailing list for that stat.
    mailing_list = stat.try(:entity).try(:mailing_list)
    next unless mailing_list

    # Get the bounces just for this stat
    stat_bounces = bounces.where(stat_id: stat.id)

    # Find the affected subscribers
    subscribers = mailing_list.subscribers
    subscribers = subscribers.where(status: "bounced")
    subscribers = subscribers.where("LOWER(SUBSTRING(email FROM (POSITION('@' IN email) + 1))) IN (?)", options[:domains]) if options[:domains].present?

    # Join with the bounce table
    subscribers = subscribers.joins("INNER JOIN (#{ stat_bounces.to_sql }) bb ON #{ subscribers.table_name }.id = bb.subscriber_id")
    subscribers = subscribers.select("#{ subscribers.table_name }.*, bb.time AS bounce_time, bb.id AS bounce_id, bb.stat_slice_id AS bounce_slice_id")

    # Iterate through the list of subscribers.
    subscribers.each do |subscriber|
      # Get details about the bounce
      bounce_hour     = ActiveSupport::TimeZone["UTC"].parse(subscriber.bounce_time).beginning_of_hour
      bounce_id       = subscriber.bounce_id
      bounce_slice_id = subscriber.bounce_slice_id

      # Give an extra newline between these blocks if we're logging SQLs
      if options[:print_sql]
        puts
      end

      # Log details about this subscriber
      if options[:print_subscriber]
        puts("Subscriber: #{ subscriber.email } mailing_list_id=#{ mailing_list.id } subscriber_id=#{ subscriber.id } bounce_id=#{ bounce_id }")
      end

      # Updating like this prevents the count callbacks from running
      mailing_list.subscribers.where(id: subscriber.id).update_all({
        :status      => "active" ,
        :remove_time => nil      ,
        :remove_ip   => nil      ,
      })

      # Manually update the counts at the time the bounce occurred
      MailingListStatDelta.create!({
        :mailing_list_id => mailing_list.id ,
        :hour            => bounce_hour     ,
        :count_active    => 1               ,
        :count_bounce    => -1              ,
      })

      # Update the bounce record to indicate it did not affect the subscriber's status
      Stats::StatBounce.where(id: bounce_id).update_all(status_updated: false)

      # Update the bounce statistics to indicate it didn't affect the subscriber's status
      Stats::StatSliceCountDelta.create!({
        :stat_slice_id          => bounce_slice_id ,
        :hour                   => bounce_hour     ,
        :bounces_status_updated => -1              ,
      })

      # Don't let a transaction live for longer than 10 seconds
      transaction_commit[] if transaction_ready[]

      # Update the subscriber count
      subscribers_updated += 1
    end
  end

  # Call our transaction_commit here because it handles the "Dry Run" logic.
  transaction_commit[]
end

puts
puts "Subscribers found = #{ subscribers_updated }"

if is_dry_run
  puts "This was just a dry run. Those subscribers were not updated."
else
  puts "This was a real run. Those subscribers were updated."
end
