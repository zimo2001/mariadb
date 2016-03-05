#!/bin/bash
set -e

tempSqlFile='/tmp/mysql-first-time.sql'

# read DATADIR from the MySQL config - REMARKED.    DATADIR is '/data/mysql'
#DATADIR="$(mysqld --verbose --help 2>/dev/null | awk '$1 == "datadir" { print $2; exit }')"
DATADIR=/data/mysql

if [ ! -d "$DATADIR/mysql" ]; then
    if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" ]; then
        echo >&2 'error: database is uninitialized and MYSQL_ROOT_PASSWORD not set'
        echo >&2 '  Did you forget to add -e MYSQL_ROOT_PASSWORD=... ?'
        exit 1
    fi

    echo 'Running mysql_install_db ...'
            mysql_install_db --datadir="$DATADIR"
            echo 'Finished mysql_install_db'


    # These statements _must_ be on individual lines, and _must_ end with
    # semicolons (no line breaks or comments are permitted).
    # TODO proper SQL escaping on ALL the things D:

    cat > "$tempSqlFile" <<-EOSQL
DELETE FROM mysql.user;
GRANT ALL ON *.* TO 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' WITH GRANT OPTION;
GRANT PROCESS ON *.* TO 'clustercheckuser'@'localhost' IDENTIFIED BY 'clustercheckpassword!';
DROP DATABASE IF EXISTS test;
EOSQL

    if [ "$MYSQL_DATABASE" ]; then
        echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" >> "$tempSqlFile"
    fi

    if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
        echo "CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;" >> "$tempSqlFile"

        if [ "$MYSQL_DATABASE" ]; then
            echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%' ;" >> "$tempSqlFile"
        fi
    fi
fi



if [ -n "$GALERA_CLUSTER" -a "$GALERA_CLUSTER" = true ]; then
    if [ ! -e "$DATADIR/../my.cnf" ]
    then
	cp /tmp/my.cnf $DATADIR/../my.cnf
    fi

    sed -i -e "s|^#wsrep_on.*$|wsrep_on = ON|" $DATADIR/../my.cnf

    WSREP_SST_USER=${WSREP_SST_USER:-"sst"}
    if [ -z "$WSREP_SST_PASSWORD" ]; then
        echo >&2 'error: database is uninitialized and WSREP_SST_PASSWORD not set'
        echo >&2 '  Did you forget to add -e WSREP_SST_PASSWORD=xxx ?'
        exit 1
    fi

    sed -i -e "s|wsrep_sst_auth[\s]*\=[\s]*\"sstuser:changethis\"|wsrep_sst_auth=${WSREP_SST_USER}:${WSREP_SST_PASSWORD}|" $DATADIR/../my.cnf

    if [ -n "$CLUSTER_NAME" ]; then
       sed -i -e "s|^wsrep_cluster_name[\s]*\=[\s]*.*$|wsrep_cluster_name=${CLUSTER_NAME}|" $DATADIR/../my.cnf
    fi

    if [ -n "$NODE_NAME" ]; then
       sed -i -e "s|^#wsrep_node_name[\s]*\=[\s]*.*$|wsrep_node_name=${NODE_NAME}|" $DATADIR/../my.cnf
    else
       sed -i -e "s|^#wsrep_node_name[\s]*\=[\s]*.*$|wsrep_node_name=$(hostname)|" $DATADIR/../my.cnf
    fi
	
    WSREP_NODE_ADDRESS=`ip addr show | grep -E '^[ ]*inet' | grep -m1 global | awk '{ print $2 }' | sed -e 's/\/.*//'`
    if [ -n "$WSREP_NODE_ADDRESS" ]; then
        sed -i -e "s|^#wsrep_node_address[\s]*\=[\s]*.*$|wsrep_node_address=${WSREP_NODE_ADDRESS}|" $DATADIR/../my.cnf
        if [ -n "$WSREP_CLUSTER_ADDRESS"  -a "$WSREP_CLUSTER_ADDRESS" != "gcomm://" ]; then
            WSREP_CLUSTER_ADDRESS="${WSREP_CLUSTER_ADDRESS},${WSREP_NODE_ADDRESS}"
        fi
    fi

    # CoreOS, using fleet
    if [ -n "$FLEETCTL_ENDPOINT" -a -e './etcdctl' -a -z "$WSREP_CLUSTER_ADDRESS" ]; then
        WSREP_CLUSTER_ADDRESS=""


        # if there is a file named "BOOTSTRAP_ME" in $DATADIR, bootstrap the cluster from this node
        if [ -e "${DATADIR}/BOOTSTRAP_ME" ]; then
           WSREP_CLUSTER_ADDRESS='gcomm://'
        else
           # wait for all the expected nodes to be registered in etcd	    
           if [ -n $MIN_NODES ]; then
              while [ $MIN_NODES -gt $(./etcdctl --peers=${FLEETCTL_ENDPOINT} ls /galera | wc -l) ]; do
                 sleep 45
              done
           fi

           for key in $(./etcdctl --peers=${FLEETCTL_ENDPOINT} ls /galera/|| true); do
               NODE=$(./etcdctl --peers=${FLEETCTL_ENDPOINT} get ${key} || true)

               if [ "$WSREP_CLUSTER_ADDRESS" != '' ]; then
                  WSREP_CLUSTER_ADDRESS=$WSREP_CLUSTER_ADDRESS,${NODE}
               else
                   WSREP_CLUSTER_ADDRESS=${NODE}
               fi
           done

           WSREP_CLUSTER_ADDRESS=gcomm://${WSREP_CLUSTER_ADDRESS}
       fi
    fi



    # Kubernetes
    # if kubernetes, take advantage of the metadata, unless of course already set
    if [ -n "$KUBERNETES_RO_SERVICE_HOST" -a -e './kubectl' -a -z "$WSREP_CLUSTER_ADDRESS" ]; then
        WSREP_CLUSTER_ADDRESS=gcomm://
        for node in 1 2 3; do
            WSREP_NODE=`./kubectl --server=${KUBERNETES_RO_SERVICE_HOST}:${KUBERNETES_RO_SERVICE_PORT} get pods| grep "^pxc-node${node}" | tr -d '\n' | awk '{ print $2 }'`
            if [ ! -z $WSREP_NODE ]; then
                if [ $node -gt 1 -a $node != "" ]; then
                    WSREP_NODE=",${WSREP_NODE}"
                fi
                WSREP_CLUSTER_ADDRESS="${WSREP_CLUSTER_ADDRESS}${WSREP_NODE}"
            fi
        done
    fi

    if [ -n "$WSREP_CLUSTER_ADDRESS" -a "$WSREP_CLUSTER_ADDRESS" != "gcomm://" ]; then
        sed -i -e "s|^[#]*wsrep_cluster_address[\s]*\=[\s]*[\"]*.*[\"]*|wsrep_cluster_address=${WSREP_CLUSTER_ADDRESS}|" $DATADIR/../my.cnf
    fi

    echo "GRANT RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO '${WSREP_SST_USER}'@'localhost' IDENTIFIED BY '${WSREP_SST_PASSWORD}';" >> "$tempSqlFile"
fi

echo 'FLUSH PRIVILEGES ;' >> "$tempSqlFile"
chown -R mysql:mysql "$DATADIR"

#symlink the my.cnf file
ln -s $DATADIR/../my.cnf /etc/mysql/my.cnf


exec /usr/sbin/mysqld --init-file=${tempSqlFile}

