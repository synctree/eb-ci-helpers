#!/bin/bash
info() {
  echo "[`date +'%Y-%m-%d %T'`] $@"
}

infon() {
  echo -n "[`date +'%Y-%m-%d %T'`] $@"
}

die() {
  echo "[`date +'%Y-%m-%d %T'`] $@" >&2
  exit 1
}

application_name="$1"
shift

[[ -z "$application_name" ]] && die "Please specify an application"

branch_name="$CIRCLE_BRANCH"
if [[ -z "$branch_name" ]] ; then
  branch_name="$(git symbolic-ref --short -q HEAD)"
fi

clean_branch="$(echo $branch_name | sed -e 's/\//-/g')"
s3_bucket="$S3_BUCKET"
if [[ -z "$s3_bucket" ]] ; then
  # defaults to the github username that owns the repo
  s3_bucket="$(dirname `git config --get remote.origin.url` | cut -d':' -f2)-deployments"
fi

version="$CIRCLE_SHA1"
if [[ -z "$version" ]] ; then
  version="$(git rev-parse HEAD)"
fi

build_dir="${CIRCLE_ARTIFACTS:-"/tmp"}"
version_label="$clean_branch-$version"
info "Application: $application_name"

create_archive() {
  git archive HEAD --format=zip > $build_dir/$version_label.zip
}

upload_archive() {
  aws s3 cp $build_dir/$version_label.zip s3://$s3_bucket/$application_name/$version_label.zip
}

create_version() {
  aws elasticbeanstalk create-application-version  \
    --application-name $application_name  \
    --version-label $version_label  \
    --source-bundle S3Bucket=$s3_bucket,S3Key=$application_name/$version_label.zip  \
    --region us-east-1
}

deploy_version() {
  aws elasticbeanstalk update-environment \
    --environment-name $environment_name \
    --version-label $version_label \
    --region us-east-1
}

describe_environment() {
  aws elasticbeanstalk describe-environments \
    --region us-east-1 \
    --application $application_name \
    --environment-names $environment_name
}

get_status() {
  describe_environment | jq -r '.Environments[0].Status'
}

get_health() {
  describe_environment | jq -r '.Environments[0].Health'
}

is_healthy() {
  [[ "$(get_health)" == "Green" ]] && return 0
  return 1
}

is_updating() {
  [[ "$(get_status)" == "Updating" ]] && return 0
  return 1
}

last_event_time=$(date -u +%s)
get_new_events() {
  aws elasticbeanstalk describe-events \
    --region us-east-1 \
    --application-name $application_name \
    --environment-name $environment_name \
    --start-time $last_event_time \
    | jq -r '.Events[].Message'
}

print_new_events() {
  local events="$(get_new_events)"
  if [[ -z $events ]] ; then
    return
  fi

  echo " "
  echo "$events" | while read event ; do info "$event" ; done
  infon "Still waiting..."
}

create_archive
upload_archive
create_version || true

while [[ -n "$1" ]] ; do
  environment_name="$1"
  info "Deploying to $environment_name"
  deploy_version || true

  infon "Waiting for update to complete."

  start=$(date -u +%s)
  deadline=$((start + 900))
  while is_updating && [[ $(date -u +%s) -le $deadline ]] ; do
    echo -n .
    now=$(date -u +%s)
    print_new_events
    last_event_time="$now"
    sleep 15
  done
  echo " "

  if is_updating ; then
    die "Update timed out"
  fi

  info "Update complete!"

  infon "Waiting for environment to become healthy"
  start=$(date -u +%s)
  deadline=$((start + 60))
  while [[ $(date -u +%s) -le $deadline ]] && ! is_healthy ; do
    echo -n .
    now=$(date -u +%s)
    sleep 15
  done

  health="$(get_health)"
  info "Environment health: $health"
  if [[ "$health" != "Green" ]] ; then
    die "$environment_name is unhealthy after deployment"
  fi

  shift
done
