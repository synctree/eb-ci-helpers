#!/bin/bash
tmp_dir="$(mktemp --directory)"
bin_dir="$tmp_dir/eb-ci-helpers-master/bin/"
install_dir="/usr/local/bin"

cd $tmp_dir

wget https://github.com/synctree/eb-ci-helpers/archive/master.zip
unzip master.zip

cd $install_dir
for file in $(ls -1 $tmp_dir/eb-ci-helpers-master/bin/) ; do
  echo "installing $install_dir/$file"
  sudo rm "$install_dir/$file" &>/dev/null
  sudo ln -s "$bin_dir/$file"
done