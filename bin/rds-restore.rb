require 'ostruct'
require 'optparse'
require 'json'

def opts
  @opts ||= OpenStruct.new(
                           basename:            nil,
                           source:              nil,
                           region:              'us-east-1',
                           db_class:            nil,
                           environment:         'dev',
                           parameter_group:     nil,
                           db_subnet_group:     nil,
                           vpc_sg_ids:          nil,
                           hosted_zone_id:      nil,
                           dns_record:          nil,
                           aws_account_id:      nil,
                           remove_old_instance: false,
                           debug:               false,
                           dryrun:              false
                          )
end

def option_parser
  @option_parser ||= OptionParser.new do |o|
    o.banner = "USAGE: #{$0} [options]"

    o.on("-i", "--instance-basename [BASENAME]", "REQUIRED: The base name of the new instance to be creared.") do |h|
      opts.basename = h
    end

    o.on("-s", "--source-instance [SOURCE]", "REQUIRED: The name of the source instance to restore from.") do |h|
      opts.source = h
    end
    
    o.on("-d", "--db-class [NAME]", "REQUIRED: The RDS instnace class to create.") do |h|
      opts.db_class = h
    end
    
    o.on("-r", "--region [AWS_REGION]", "AWS Region where Application resides. DEFAULT: #{opts.region}") do |h|
      opts.region = h
    end

    o.on("-e", "--environment [TAG]", "The environment to taf the instance with. DEFAULT: #{opts.environment}") do |h|
      opts.environment = h
    end

    o.on("--parameter-group [NAME]", "A parameter group name to attach to the instance.") do |h|
      opts.parameter_group = h
    end

    o.on("--db-subnet-group [NAME]", "The subnet group to associate the instance with. DEFAULT: #{opts.db_subnet_group}") do |h|
      opts.db_subnet_group = h
    end
    
    o.on("--vpc-sg-ids [CSV_STRING]", "List of Security Group IDs to attach to the instance. Example: sg-15143mk14,sg-4514bxu13") do |csv|
      sgs = csv.split(',')
      opts.vpc_sg_ids = sgs
    end

    o.on("--hosted-zone-id [ID]", "The Route 53 Hosted Zone ID. Required if you want to updated DNS.") do |h|
      opts.hosted_zone_id = h
    end

    o.on("--dns-record [RECORD]", "The Route 53 DNS record to update. Required if you want to updated DNS.") do |h|
      opts.dns_record = h
    end

    o.on("--aws-account-id [ID]", "AWS Account ID. Required to set tags and terminate old instnaces.") do |h|
      opts.aws_account_id = h
    end

    o.on("--remove-old-instance [BOOLEAN]", "Terminate the old instance that is stored in the Instance Tag on RDS Source.") do |h|
      opts.remove_old_instance = h
    end

    o.on("--dry-run", "Run all generation commands, but do NOT execute any API calls.") do |h|
      opts.dryrun = h
    end
    
    o.on("--[no-]debug", "Print debug") do |h|
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

die('Instance Basename required. Use -i flag') unless opts.basename
die('Source instance name required. Use -s flag') unless opts.source
die('Environment tag not set. Use -e flag') unless opts.environment
die('DB Class not set. Use -d flag') unless opts.db_class

# Setting some useful values
opts.instance_name       = "#{opts.basename}-#{`date +'%Y-%m-%d-%H%M%S'`.chomp}"
opts.vpc_security_groups = opts.vpc_sg_ids.map {|s| "\"#{s}\""}.join(' ') if opts.vpc_sg_ids
opts.arn                 = "arn:aws:rds:#{opts.region}:#{opts.aws_account_id}:db:#{opts.source}" if opts.aws_account_id
opts.finder_key          = "current-#{opts.environment}"
opts.finder_value_base   = "rds-restore::#{opts.environment}::"

info "Instance Name: #{opts.instance_name}"
info "VPC SG IDs: #{opts.vpc_security_groups}"

def get_status
  data = exec_cli "aws rds describe-db-instances --db-instance-identifier #{opts.instance_name} --region #{opts.region}"
  json = JSON.parse(data)
  json['DBInstances'][0]['DBInstanceStatus']
end

def get_endpoint
  data = exec_cli "aws rds describe-db-instances --db-instance-identifier #{opts.instance_name} --region #{opts.region}"
  json = JSON.parse(data)
  opts.endpoint = json['DBInstances'][0]['Endpoint']['Address']
end

# Select Latest Snapshot
def get_snapshot
  data = exec_cli "aws rds describe-db-snapshots --db-instance-identifier #{opts.source} --region #{opts.region}"
  json = JSON.parse(data)
  opts.snapshot = json['DBSnapshots'].last['DBSnapshotIdentifier']
end

def get_old_instance_name
  data = exec_cli "aws rds list-tags-for-resource --resource-name #{opts.arn} --region #{opts.region}"
  json = JSON.parse(data)
  json['TagList'].each do |i|
    if i['Key'] == opts.finder_key
      opts.old_instance_name = i['Value'].gsub(opts.finder_value_base, '')
    end
  end
end

get_snapshot()
info "Snapshot: #{opts.snapshot}"

if opts.aws_account_id
  get_old_instance_name()
  info "Old Instance Name: #{opts.old_instance_name}"
end

def set_new_instance_tag
  tag_value = "rds-restore::#{opts.environment}::#{opts.instance_name}"
  exec_cli "aws rds add-tags-to-resource \
    --resource-name #{opts.arn} \
    --region #{opts.region} \
    --tags Key=#{opts.finder_key},Value=#{tag_value}"
end

def delete_old_instance
  exec_cli "aws rds delete-db-instance \
    --db-instance-identifier #{opts.old_instance_name} \
    --skip-final-snapshot \
    --region #{opts.region}"
end

def create_instance
    args = [ "aws rds restore-db-instance-from-db-snapshot",
            '--db-instance-identifier', opts.instance_name,
            '--db-snapshot-identifier', opts.snapshot,
            '--db-instance-class', opts.db_class,
            '--no-multi-az',
            '--publicly-accessible',
            '--no-auto-minor-version-upgrade',
            "--tags Key=env,Value=#{opts.environment}",
            '--region', opts.region
           ]
    args.push('--db-subnet-group-name', opts.db_subnet_group) if opts.db_subnet_group
    exec_cli args.join(' ')
end

def update_instance_settings
  args = [ "aws rds modify-db-instance",
          '--db-instance-identifier', opts.instance_name,
          '--apply-immediately',
          '--backup-retention-period 0',
          '--region', opts.region
          ]
  args.push('--db-parameter-group-name', opts.parameter_group) if opts.parameter_group
  args.push('--vpc-security-group-ids', opts.vpc_security_groups) if opts.vpc_security_groups
  exec_cli args.join(' ')
end

def reboot_instance
  exec_cli "aws rds reboot-db-instance --db-instance-identifier #{opts.instance_name} --region #{opts.region}"
end

def gen_update_dns_file
  data = {
    "Comment" => "Automated update of #{opts.dns_record} to #{opts.endpoint}",
    "Changes" => [
      {
        "Action" => "UPSERT",
        "ResourceRecordSet" => {
                                "Name" => "#{opts.dns_record}",
          "Type" => "CNAME",
          "TTL" => 60,
          "ResourceRecords" => [
            {
             "Value" => "#{opts.endpoint}"
            }
          ]
        }
      }
    ]
  }
  opts.file_path = "/tmp/#{opts.hosted_zone_id}-#{opts.dns_record}.json"
  File.write(opts.file_path, data.to_json)
end

def update_dns
  exec_cli "aws route53 change-resource-record-sets \
    --region #{opts.region} \
    --hosted-zone-id #{opts.hosted_zone_id} \
    --change-batch file://#{opts.file_path}"
end

def is_updating?
  get_status() == "available" ? false : true
end
 
def is_available?
  get_status() == "available" ? true : false
end

def poll_status
  start= `date -u +%s`.chomp.to_i
  deadline= start + 3600
  print "[#{Time.now.strftime('%Y-%m-%d %T')}] Polling..."
  while is_updating? && `date -u +%s`.chomp.to_i < deadline do
    print '.'
    sleep 15
  end
  puts " "
  info "Update complete"
end

if opts.dryrun
  puts "Dry Run. Will not execute API calls."
  puts "#{opts}"
  exit
end

# Create
info "Creating Instance: #{opts.instance_name}"
create_instance()

# Status
info "Polling for status 'available' status."
poll_status()

info "Sleeping for 10 seconds..."
sleep 10

# Update Parameter Group
info "Updating instnace settings on #{opts.instance_name}"
update_instance_settings()

# Status
info "Polling for status 'available' status."
poll_status

info "Sleeping for 30 seconds..."
sleep 30

# Reboot
info "Rebooting instance: #{opts.instance_name}"
reboot_instance()

# Check Status
info "Polling for status 'available' status."
poll_status

info "Sleeping for 10 seconds..."
sleep 10

# Get DNS Name
get_endpoint()
info "Ready to update DNS records with: #{opts.endpoint}"

if opts.dns_record
  info "Updating DNS for $dns_record"
  gen_update_dns_file()
  update_dns()
end

if opts.remove_old_instance
  info "Old Instance: #{opts.old_instance_name}"
  delete_old_instance()
  info "Sent API call to AWS to terminate RDS instance #{opts.old_instance_name}"
else
  info "Will not remove old instance. Value was not 'true'."
end

# Update Tags
info "Setting new tags for restored instance on master host."
set_new_instance_tag()

info "Process complete!"
