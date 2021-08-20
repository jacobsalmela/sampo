#!/usr/bin/env bash
echo "Backing up database..."
ssh -F /dev/null -i ~/.ssh/id_rsa-slaughterbeast root@jacobsalmela.com "/root/backup.sh"
echo "Syncing content to dropbox..."
rsync -rltd \
  -e 'ssh -F /dev/null -i ~/.ssh/id_rsa-slaughterbeast' \
  --no-i-r \
  --info=progress2 \
  --links \
  --keep-dirlinks \
  --hard-links \
  --delete-during \
  --exclude='versions/' \
  --exclude='logs/' \
  root@jacobsalmela.com:/var/www/ghost/ \
  ~/Dropbox/Sites/jacobsalmela.com/bakups/

# shellcheck disable=SC2061
find ~/Dropbox/Sites/jacobsalmela.com/bakups \
  -name ghost_prod_* \
  -type f \
  -mmin -60
