#! /usr/bin/ruby

require 'ostruct'
require 'optparse'

def opts
  @opts ||= OpenStruct.new(
                           application: nil,
                           environment: nil,
                           region: 'us-east-1',
                           s3_bucket: nil,
                           extra_zip: nil,
                           debug: false
                          )
end

def option_parser
  @option_parser ||= OptionParser.new do |o|
    o.banner = "USAGE: #{$0} [options]"

    o.on("-a", "--app [EB_APPLICATION]", "REQUIRED: The EB Application Name.") do |h|
      opts.application = h
    end

    o.on("-e", "--env [EB_ENVIRONMNT]", "REQUIRED: The EB Environment Name.") do |h|
      opts.environment = h
    end

    o.on("-r", "--region [AWS_REGION]", "AWS Region where Application resides. DEFAULT: #{opts.region}") do |h|
      opts.region = h
    end

    o.on("--extra-zip [CSV_STRING]", "List of paths to add to the zip git archive. Example: public,scripts/special") do |csv|
      to_zip = csv.split(',')
      opts.extra_zip = to_zip
    end

    o.on("--s3-bucket [BUCKET]", "The S3 Bucket Name if you want to use a custome name. DEFAULT: {Basename of the Repo Owner}-deployments.") do |h|
      opts.s3_bucket = h
    end
    
    o.on("-d", "--[no-]debug", "Print debug") do |h|
      opts.debug = h
    end
    
    o.on("-h", "--help", "Show help documentation") do |h|
      STDERR.puts o
      exit
    end
  end
end

option_parser.parse!

def info str
  $stdout.puts "[#{Time.now.strftime('%Y-%m-%d %T')}] #{str}"
end

def infon str
  $stdout.print "[#{Time.now.strftime('%Y-%m-%d %T')}] #{str}"
end

def die str
  $stderr.puts "[#{Time.now.strftime('%Y-%m-%d %T')}] #{str}"
  exit 1
end

die('EB Application Name required. Use -a flag') unless opts.application
die('EB Environment Name required. Use -e flag') unless opts.environment

branch_name = ENV['CIRCLE_BRANCH']
if branch_name.nil?
  branch_name = `git symbolic-ref --short -q HEAD`.chomp
end
info "Branch Name: #{branch_name}"

clean_branch = branch_name.gsub('/', '-')
info "Clean Branch Name: #{clean_branch}"

unless opts.s3_bucket
  git_remote = `git config --get remote.origin.url | cut -d':' -f2`
  path = git_remote.split('/')
  opts.s3_bucket = "#{path[0]}-deployments"
end
info "S3 Bucket: #{opts.s3_bucket}"

version = ENV['CIRCLE_SHA1']
if version.nil?
  version = `git rev-parse HEAD`.chomp
end
info "Commit: #{version}"

build_dir = ENV['CIRCLE_ARTIFACTS'].nil? ? '/tmp' : ENV['CIRCLE_ARTIFACTS']
info "Build Dir: #{build_dir}"

version_label = "#{clean_branch}-#{version}"
info "EB Application: #{opts.application}"
info "EB Environment: #{opts.environment}"
info "EB Version Label: #{version_label}"

def create_archive
  `git archive HEAD --format=zip > #{build_dir}/#{version_label}.zip`.chomp
end

def add_to_archive
  `zip -r #{build_dir}/#{version_label}.zip #{opts.extra_zip.join(' ')}`.chomp
end

def upload_archive
  `aws s3 cp #{build_dir}/#{version_label}.zip s3://#{opts.s3_bucket}/#{opts.application}/#{version_label}.zip`.chomp
end

def create_version
  `aws elasticbeanstalk create-application-version  \
    --application-name #{opts.application}  \
    --version-label #{version_label}  \
    --source-bundle S3Bucket=#{opts.s3_bucket},S3Key=#{opts.application}/#{version_label}.zip  \
    --region us-west-2`.chomp
end

def deploy_version
  `aws elasticbeanstalk update-environment \
    --environment-name #{opts.environment} \
    --version-label #{version_label} \
    --region #{opts.region}`.chomp
end

def describe_environment
  `aws elasticbeanstalk describe-environments \
    --region #{opts.region} \
    --application #{opts.application} \
    --environment-names #{opts.environment}`.chomp
end

def get_status
  `#{describe_environment()} | jq -r '.Environments[0].Status'`.chomp
end

def get_health
  `#{describe_environment()} | jq -r '.Environments[0].Health'`.chomp
end

def is_healthy
  "#{get_health()}" == "Green" ? true : false
end

def is_updating
  "#{get_status()}" == "Updating" ? true : false
end

last_event_time = `date -u +%s`.chomp

def get_new_events
  `aws elasticbeanstalk describe-events \
    --region us-west-2 \
    --application-name $application_name \
    --environment-name $environment_name \
    --start-time $last_event_time \
    | jq -r '.Events[].Message'`.chomp
end

def print_new_events
  events = "#{get_new_events()}"
  if events
    puts " "
    events.each {|e| info "#{e}"}
    infon "Still waiting..."
  end
end

info "Creating archive..."
res = create_archive()
info "#{res}"

info "Uploading archive..."
res = upload_archive()
info "#{res}"

info "Creating version..."
res = create_version()
info "#{res}"

info "Deploying to #{opts.environment}"
res = deploy_versoin()
info "#{res}"
infon "Waiting for update to complete."

start= `date -u +%s`.chomp.to_i
deadline = start + 900

while is_updating() && `date -u +%s`.chomp.to_i < deadline do
  $stdout.print '.'
  now = `date -u +%s`.chomp.to_i
  print_new_events()
  last_event_time = now
  sleep 15
end

info "Checking state of Environment..."
die("Update timed out.") if is_updating()
info "Update Complete!"

infon "Waiting for environment to become healthy"

start= `date -u +%s`.chomp.to_i
deadline = start + 60

while `date -u +%s`.chomp.to_i < deadline && ! is_healthy()  do
  $stdout.print '.'
  sleep 15
end

health = get_health()
info "Environment health: #{health}"
unless "#{health}" == "Green"
  die "#{opts.environment} is unhealthy after deployment."
else
  info "Environment successfully updated."
end
