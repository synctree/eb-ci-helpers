require 'ostruct'
require 'optparse'
require 'json'

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

def exec_cli cmd
  if opts.debug
    $stdout.print "\n\n"
    info "Executing Command: #{cmd}"
    $stdout.print "\n"
  end
  `#{cmd}`.chomp
end

die('EB Application Name required. Use -a flag') unless opts.application
die('EB Environment Name required. Use -e flag') unless opts.environment

opts.branch_name = ENV['CIRCLE_BRANCH']
if opts.branch_name.nil?
  opts.branch_name = `git symbolic-ref --short -q HEAD`.chomp
end
info "Branch Name: #{opts.branch_name}"

opts.clean_branch = opts.branch_name.gsub('/', '-')
info "Clean Branch Name: #{opts.clean_branch}"

unless opts.s3_bucket
  git_remote = `git config --get remote.origin.url | cut -d':' -f2`
  path = git_remote.split('/')
  opts.s3_bucket = "#{path[0]}-deployments"
end
info "S3 Bucket: #{opts.s3_bucket}"

opts.version = ENV['CIRCLE_SHA1']
if opts.version.nil?
  opts.version = `git rev-parse HEAD`.chomp
end
info "Commit: #{opts.version}"

opts.build_dir = ENV['CIRCLE_ARTIFACTS'].nil? ? '/tmp' : ENV['CIRCLE_ARTIFACTS']
info "Build Dir: #{opts.build_dir}"

opts.version_label = "#{opts.clean_branch}-#{opts.version}"
info "EB Application: #{opts.application}"
info "EB Environment: #{opts.environment}"
info "EB Version Label: #{opts.version_label}"

def create_archive
  exec_cli "git archive HEAD --format=zip > #{opts.build_dir}/#{opts.version_label}.zip"
end

def add_to_archive
  exec_cli "zip -r #{opts.build_dir}/#{opts.version_label}.zip #{opts.extra_zip.join(' ')}"
end

def upload_archive
  exec_cli "aws s3 cp #{opts.build_dir}/#{opts.version_label}.zip s3://#{opts.s3_bucket}/#{opts.application}/#{opts.version_label}.zip"
end

def create_version
  exec_cli "aws elasticbeanstalk create-application-version  \
    --application-name #{opts.application}  \
    --version-label #{opts.version_label}  \
    --source-bundle S3Bucket=#{opts.s3_bucket},S3Key=#{opts.application}/#{opts.version_label}.zip  \
    --region us-west-2"
end

def deploy_version
  exec_cli "aws elasticbeanstalk update-environment \
    --environment-name #{opts.environment} \
    --version-label #{opts.version_label} \
    --region #{opts.region}"
end

def describe_environment
  exec_cli "aws elasticbeanstalk describe-environments \
    --region #{opts.region} \
    --application #{opts.application} \
    --environment-names #{opts.environment}"
end

def get_status
  json = JSON.parse(describe_environment())
  json['Environments'][0]['Status']
end

def get_health
  json = JSON.parse(describe_environment())
  json['Environments'][0]['Health']
end

def is_healthy
  "#{get_health()}" == "Green" ? true : false
end

def is_updating
  "#{get_status()}" == "Updating" ? true : false
end

last_event_time = `date -u +%s`.chomp

def get_new_events
  json = JSON.parse(exec_cli("aws elasticbeanstalk describe-events \
    --region us-west-2 \
    --application-name #{opts.application} \
    --environment-name #{opts.environment} \
    --start-time #{opts.last_event_time}"))
  json['Events']
end

def print_new_events
  events = get_new_events()
  if events
    puts " "
    events.each {|e| info "EB Message: #{e['Message']}"}
    infon "Still waiting..."
  end
end

info "Creating archive..."
create_archive()

if opts.extra_zip
  info "Extending archive with: #{opts.extra_zip.join(' ')}"
  add_to_archive()
end

info "Uploading archive..."
upload_archive()

info "Creating version..."
create_version()

info "Deploying to #{opts.environment}"
deploy_version()
infon "Waiting for update to complete."

start = `date -u +%s`.chomp.to_i
deadline = start + 900

opts.last_event_time = `date -u +%s`.chomp.to_i
while is_updating() && `date -u +%s`.chomp.to_i < deadline do
  $stdout.print '.'
  now = `date -u +%s`.chomp.to_i
  print_new_events()
  opts.last_event_time = now
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
