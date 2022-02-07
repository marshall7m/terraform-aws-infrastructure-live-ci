#!/bin/bash

if [ -n "$ADDITIONAL_PATH" ]; then
    echo "Adding to PATH: $ADDITIONAL_PATH"
    export PATH="$ADDITIONAL_PATH:$PATH"
fi

source $VIRTUAL_ENV/bin/activate

if [ -z "$SSH_PUBLIC_KEY" ]; then
  echo "SSH_PUBLIC_KEY is not set"
  exit 1
fi

ssh_dir=~/.ssh
[ ! -d "$ssh_dir" ] && mkdir -p $ssh_dir

echo "Adding SSH public key to authorized keys"
echo "$SSH_PUBLIC_KEY" > ${ssh_dir}/authorized_keys

echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
echo "PermitRootLogin yes" >> /etc/ssh/sshd_config

openrc
rc-update add sshd
touch /run/openrc/softlevel
rc-service sshd start
rc-status

echo "Starting sshd daemon"
/usr/sbin/sshd -D

chown root:root -R ~/.ssh/
chmod 600 ~/.ssh/authorized_keys
chmod 700 ~/.ssh
chmod 700 ~
# Keeps container idly running
tail -f /dev/null 