#!/bin/bash
## Sean Horn - Support Team - Chef
## Minimal downtime incremental filesystem backup for Chef Server
##
## To run chmod 0700 && ./take-quick-backup.sh
##
## Options -h, -r, -d listed below

DESTINATION="/chef-server-backup"
ACTIVE_COMMAND="echo \"SELECT CURRENT_TIMESTAMP; SELECT \"\*\" FROM pg_stat_activity;\" | chef-server-ctl psql oc_erchef --as-admin --options -tA | grep -v [p]ong | tail -1 | grep -v [p]g_stat_activity | tr -d '\n'"
WAIT_QUIESCE_TIME=1

run_preflight=true

while getopts ":rpd:h" opt; do
  case $opt in
    p) 
      echo "Toggled preflight tests off"
      run_preflight=false
      ;;
    r)
      echo "Deleting postgres pre-backup at $DESTINATION!" >&2
      rm -fr $DESTINATION
      ;;
    d) 
      DESTINATION=$OPTARG
      ## Regex protects against deleting the root filesystem :(
      echo "$DESTINATION" | grep -q -v -E '(^\/ +| +\/ +|\/$)'
      if [ $? -eq 0 ] ; then 
        echo Assigned DESTINATION of $DESTINATION
      else 
        echo "######"; echo !!!Your DESTINATION string contains the root filesystem. Please correct and try again!!!; run_preflight=false; echo "#####"; exit 1
      fi
      
      ;;
    h)
cat << END
  --Usage--
    Options
     -h Help!
     -r Delete an existing rsync -a /var/opt/opscode $DESTINATION
     -d Destination for backup. Default to a fully qualified path of "$DESTINATION"
END
      exit 0
      ;;
    :)
      echo "Invalid option: -$OPTARG requires an argument" >&2
      ;;
  esac
  echo 
done


if [ "$run_preflight" = "true" ]; then
echo ---Running preflight---
  echo -checking bzip2
  which bzip2 &> /dev/null
  [ $? -eq 1 ] && echo $? Please install the bzip2 command and try another run && exit 1 && false

  echo -checking rsync
  which rsync &> /dev/null
  [ $? -eq 1 ] && echo $? Please install the rsync command and try another run && exit 1 && false

  echo -checking date
  which date &> /dev/null
  [ $? -eq 1 ] && echo $? Please install the date command and try another run && exit 1 && false

  echo -checking chef-server-ctl
  which chef-server-ctl &> /dev/null
  [ $? -eq 1 ] && echo chef-server-ctl not found. This is not a chef server. Use this only to backup Chef Servers && exit 1 && false
 
  echo -checking redis-cli
  [ -e /opt/opscode/embedded/bin/redis-cli ]
  [ $? -eq 1 ] && echo Embedded chef server redis-cli not found. Something may be wrong with this Chef Server install && exit 1 && false

  echo -checking UID
  if [ `id -u` -ne 0 ]; then 
    echo Not UID 0, please become root and try another run && exit 1
  fi
fi


echo ---First rsync chef server to $DESTINATION---
echo "    .....Syncing....."
bad_run=true
while [ "$bad_run" = "true"  ]; do
  start_sync_time=`date +%s%N | cut -b1-13`
  start_total_time=$start_sync_time
  bad_run=false

  mkdir -p ${DESTINATION}/var/opt
  rsync -a /var/opt/opscode ${DESTINATION}/var/opt/ || bad_run=true

  mkdir -p ${DESTINATION}/etc/opscode
  rsync -a /etc/opscode/ ${DESTINATION}/etc/opscode/ || bad_run=true

  end_sync_time=`date +%s%N | cut -b1-13`
  echo ---Elapsed first sync time: $(($end_sync_time-$start_sync_time))ms ---
  echo First sync size: `du -sh $DESTINATION`
done

start_downtime=`date +%s%N | cut -b1-13`
echo ---Start downtime at $start_downtime ---

echo "---Set 503 mode---"
/opt/opscode/embedded/bin/redis-cli -a 8f5d8b95cc084c324740f33c6d18d617c630c1bb08cdb1fe8b119350e5b38342f1078127629e123baa3ba3f6c92c805090e0 -p 16379 HSET dl_default 503_mode true &> /dev/null

echo "---Wait for system to settle---"
while [ -n "`eval env $ACTIVE_COMMAND`" ];
do
 echo ---Waiting for ${WAIT_QUIESCE_TIME}s for system to settle 
 sleep $WAIT_QUIESCE_TIME
done

echo ---Chef Server quiesce stage. sleep 5---
sleep 3

echo ---Stop chef server---
chef-server-ctl stop

echo ---Sync data to disk---
sync

echo ---Second rsync chef server to $DESTINATION---
echo "    .....Syncing....."
start_sync_time=`date +%s%N | cut -b1-13`

rsync -a /var/opt/opscode ${DESTINATION}/var/opt/
rsync -a /etc/opscode/ ${DESTINATION}/etc/opscode/

end_sync_time=`date +%s%N | cut -b1-13`
echo ---Elapsed second sync time: $(($end_sync_time-$start_sync_time))ms ---
echo ---Final sync size: `du -sh $DESTINATION`---

echo ---Start chef server---
chef-server-ctl start

echo "---Unset 503 mode---"
/opt/opscode/embedded/bin/redis-cli -a 8f5d8b95cc084c324740f33c6d18d617c630c1bb08cdb1fe8b119350e5b38342f1078127629e123baa3ba3f6c92c805090e0 -p 16379 HSET dl_default 503_mode false &> /dev/null

end_downtime=`date +%s%N | cut -b1-13`
echo ---End downtime at $end_downtime ---
echo

echo ---Start compressed tarball---
echo

echo ".....Compressing....."
tar -zcf ${DESTINATION}.tar.gz $DESTINATION

end_total_time=`date +%s%N | cut -b1-13`
echo ---Elapsed Total Downtime: $(($end_downtime-$start_downtime))ms ---
echo ---Elapsed Compression Time: $(($end_total_time-$end_downtime))ms ---
echo ---Elapsed Total Backup Time: $(($end_total_time-$start_total_time))ms ---
