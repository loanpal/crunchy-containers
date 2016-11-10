#!/bin/bash -x

# Copyright 2016 Crunchy Data Solutions, Inc.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#
# start the backup job
#
# the service looks for the following env vars to be set by
# the cpm-admin that provisioned us
#
# /pgdata is a volume that gets mapped into this container
# $BACKUP_HOST host we are connecting to
# $BACKUP_USER pg user we are connecting with
# $BACKUP_PASS pg user password we are connecting with
# $BACKUP_PORT pg port we are connecting to
#

ls -l /
ls -l /pgdata

env

echo "Setting up email client for notifications"
sed -i "s/{{EMAIL_AUTH_USER}}/${EMAIL_AUTH_USER}/g;" /etc/ssmtp/ssmtp.conf
sed -i "s/{{EMAIL_AUTH_PASS}}/${EMAIL_AUTH_PASS}/g;" /etc/ssmtp/ssmtp.conf
sed -i "s/{{EMAIL_DOMAIN}}/${EMAIL_DOMAIN}/g;" /etc/ssmtp/ssmtp.conf
sed -i "s/{{EMAIL_SERVER}}/${EMAIL_SERVER}/g;" /etc/ssmtp/ssmtp.conf

function ose_hack() {
        export USER_ID=$(id -u)
        export GROUP_ID=$(id -g)
        envsubst < /opt/cpm/conf/passwd.template > /tmp/passwd
        export LD_PRELOAD=/usr/lib64/libnss_wrapper.so
        export NSS_WRAPPER_PASSWD=/tmp/passwd
        export NSS_WRAPPER_GROUP=/etc/group
}


ose_hack

export BACKUP_HOST=$MASTER_DC_SERVICE_HOST

BACKUPBASE=/pgdata/$BACKUP_HOST
if [ ! -d "$BACKUPBASE" ]; then
	echo "creating BACKUPBASE directory..."
	mkdir -p $BACKUPBASE
fi

if [[ ! -v "BACKUP_LABEL" ]]; then
	BACKUP_LABEL="crunchybackup"
fi
echo "BACKUP_LABEL is set to " $BACKUP_LABEL

TS=`date +%Y-%m-%d-%H-%M-%S`
BACKUP_PATH=$BACKUPBASE/$TS
mkdir $BACKUP_PATH
BACKUP_LOG=${BACKUP_PATH}/log
mkdir $BACKUP_LOG


export PGPASSFILE=/tmp/pgpass

echo "*:*:*:"$BACKUP_USER":"$BACKUP_PASS  >> $PGPASSFILE

chmod 600 $PGPASSFILE

chown $UID:$UID $PGPASSFILE

cat $PGPASSFILE

echo "Starting backup!" >> ${BACKUP_LOG}/backup.log
pg_basebackup --label=$BACKUP_LABEL --xlog --pgdata $BACKUP_PATH --host=$BACKUP_HOST --port=$BACKUP_PORT -U $BACKUP_USER &>> ${BACKUP_LOG}/backup.log 

chown -R $UID:$UID $BACKUP_PATH
# 
# open up permissions for the OSE Dedicated random UID scenario
#
chmod -R o+rx $BACKUP_PATH

echo "Backup has ended, pruning old backups at ${PRUNE_AGE} days" >> ${BACKUP_LOG}/backup.log
find ${BACKUPBASE} -mtime +${PRUNE_AGE} -delete &>> /var/log/backup.log

echo "Querying disk space usage of backups" >> ${BACKUP_LOG}/backup.log
du -sh /pgdata/*/* &>> ${BACKUP_LOG}/backup.log

echo "Backup and pruning complete!"
echo /var/log/backup.log | sendmail -s "DB Backup in Environment ${ENVIRONMENT} Complete" ${EMAIL_TARGET}
