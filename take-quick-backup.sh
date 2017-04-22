#!/bin/bash
## Sean Horn - Support Team - Chef
## Minimal downtime incremental filesystem backup
##
## To run chmod 0700 && ./take-quick-backup.sh
##

DESTINATION="/chef-server-backup"

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
      [ $? -eq 0 ] && echo Assigned DESTINATION of $DESTINATION || echo "######"; echo !!!Your DESTINATION string contains the root filesystem. Please correct and try again!!!; run_preflight=false; echo "#####"; exit 1
      
      ;;
    h)
cat << END
  --Usage--
    Options
     -h Help!
     -r Delete an existing rsync -av /var/opt/opscode /chef-server-backup
     -d Destination for backup. Default to a fully qualified path of "/chef-server-backup"
END
      exit 0
      ;;
    :)
      echo "Invalid option: -$OPTARG requires an argument" >&2
      ;;
  esac
  echo 
done

getout () {
echo in getout
  exit 1
}

if [ "$run_preflight" = "true" ]; then
echo ---Running preflight---
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


ACTIVE_COMMAND="echo \"SELECT CURRENT_TIMESTAMP; SELECT \"\*\" FROM pg_stat_activity;\" | chef-server-ctl psql oc_erchef --as-admin --options -tA | grep -v [p]ong | tail -1 | grep -v [p]g_stat_activity | tr -d '\n'"
WAIT_QUIESCE_TIME=1

echo ---First rsync chef server to /chef-server-backup---
rsync -av /var/opt/opscode /chef-server-backup

start_downtime=`date +%s%N | cut -b1-13`
echo ---Start downtime at $start_downtime ---

echo "---Set 503 mode---"
/opt/opscode/embedded/bin/redis-cli -a 8f5d8b95cc084c324740f33c6d18d617c630c1bb08cdb1fe8b119350e5b38342f1078127629e123baa3ba3f6c92c805090e0 -p 16379 HSET dl_default 503_mode true

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

echo ---Second rsync to backup area---
rsync -av /var/opt/opscode /chef-server-backup

echo ---Start chef server---
chef-server-ctl start

echo "---Unset 503 mode---"
/opt/opscode/embedded/bin/redis-cli -a 8f5d8b95cc084c324740f33c6d18d617c630c1bb08cdb1fe8b119350e5b38342f1078127629e123baa3ba3f6c92c805090e0 -p 16379 HSET dl_default 503_mode false

end_downtime=`date +%s%N | cut -b1-13`
echo ---End downtime at $start_downtime ---
echo ---Elapsed Time: $(($end_downtime-$start_downtime))ms ---
