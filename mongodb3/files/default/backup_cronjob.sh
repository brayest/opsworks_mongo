#!/usr/bin/env bash

BUCKET=$1
FOLDER=$2
TYPE=$3

STATUS=$(echo "rs.status()" | mongo | grep "myState" | awk -F ":" '{print $2}' | sed -e 's/ //g' | sed -e 's/,//g')

if [ $STATUS = "1" ]; then
  DIR=$(hostname)-$(date +'%d%m%y')-$TYPE
  /usr/bin/mongodump -o /data/BACKUPS/$DIR
  tar cvfz /data/BACKUPS/$DIR.tar.gz /data/BACKUPS/$DIR
  { # try

    /usr/bin/aws s3 cp /data/BACKUPS/$DIR.tar.gz s3://$BUCKET/$FOLDER/

  } || { # catch
    /usr/bin/aws cloudwatch set-alarm-state --alarm-name "Backup Failed" --state-value ALARM --state-reason "BackUp Failed on $DIR" --region us-west-2
  }
  rm /data/BACKUPS/$DIR* -R
else
  echo "Not PRIMARY"
fi
