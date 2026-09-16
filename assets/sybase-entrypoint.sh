#!/bin/bash

export SYBASE=/opt/sybase
source /opt/sybase/SYBASE.sh

# Invoke the RUN files directly — the `startserver` wrapper was
# dropped in newer SPs. Both servers run in background so we can poll
# the log and run init SQL once the dataserver is up.
sh ${SYBASE}/${SYBASE_ASE}/install/RUN_MYSYBASE_BS > /dev/null &
sh ${SYBASE}/${SYBASE_ASE}/install/RUN_MYSYBASE    > /dev/null &

export STATUS=0
i=1
echo ===============  WAITING FOR master.dat SPACE ALLOCATION ==========================
while (( $i < 60 )); do
	sleep 1
	i=$((i+1))
	STATUS=$(grep "Performing space allocation for device '/opt/sybase/data/master.dat'" ${SYBASE}/${SYBASE_ASE}/install/MYSYBASE.log | wc -c)
	if (( $STATUS > 300 )); then
	  break
	fi
done

echo ===============  WAITING FOR INITIALIZATION ==========================
export STATUS2=0
j=1
while (( $j < 30 )); do
  sleep 1
  j=$((j+1))
  STATUS2=$(grep "Finished initialization." ${SYBASE}/${SYBASE_ASE}/install/MYSYBASE.log | wc -c)
  if (( $STATUS2 > 350 )); then
    break
  fi
done

echo =============== SYBASE STARTED ==========================
cd /opt/sybase

if [ ! -z $SYBASE_USER ]; then
	echo "SYBASE_USER: $SYBASE_USER"
else
	SYBASE_USER=tester
	echo "SYBASE_USER: $SYBASE_USER"
fi

if [ ! -z $SYBASE_PASSWORD ]; then
	echo "SYBASE_PASSWORD: $SYBASE_PASSWORD"
else
	SYBASE_PASSWORD=guest1234
	echo "SYBASE_PASSWORD: $SYBASE_PASSWORD"
fi

if [ ! -z $SYBASE_DB ]; then
	echo "SYBASE_DB: $SYBASE_DB"
else
	SYBASE_DB=testdb
	echo "SYBASE_DB: $SYBASE_DB"
fi

if [ ! -z $SYBASE_DB_SIZE ]; then
	echo "SYBASE_DB_SIZE: $SYBASE_DB_SIZE"
else
	SYBASE_DB_SIZE=48
	echo "SYBASE_DB_SIZE: $SYBASE_DB_SIZE"
fi

if [ ! -z $SYBASE_TEMPDB_SIZE ]; then
	echo "SYBASE_TEMPDB_SIZE: $SYBASE_TEMPDB_SIZE"
else
	SYBASE_TEMPDB_SIZE=80
	echo "SYBASE_TEMPDB_SIZE: $SYBASE_TEMPDB_SIZE"
fi

# "Finished initialization." in MYSYBASE.log is necessary but not
# sufficient — there is a window before the TCP listener accepts
# connections, during which `isql` fails with ct_connect(). Probe the
# listener with a real round-trip; without it, init1.sql / init2.sql
# silently fail and we'd still log "SYBASE INITIALIZED" at the end.
echo ===============  WAITING FOR LISTENER ==========================
k=0
while (( k < 60 )); do
	if printf 'select 1\ngo\n' | ${SYBASE}/${SYBASE_OCS}/bin/isql -Usa -PmyPassword -SMYSYBASE -l5 >/dev/null 2>&1; then
		break
	fi
	sleep 1
	k=$((k+1))
done
if (( k >= 60 )); then
	echo "ERROR: ASE did not accept connections within 60s, aborting init"
	exit 1
fi

# This entrypoint runs on every container start, `disk resize` takes an
# *additional* size rather than an absolute one, and nothing here ever
# shrinks a device. Resizing unconditionally therefore grew master.dat and
# tempdbdev.dat on every restart of a persistent volume. Ask the running
# server what is already allocated and request only the shortfall.
ase_scalar() {
	printf 'set nocount on\n%s\ngo\n' "$1" \
		| ${SYBASE}/${SYBASE_OCS}/bin/isql -Usa -PmyPassword -SMYSYBASE -w20000 2>/dev/null \
		| grep -E '^[[:space:]]*-?[0-9]+[[:space:]]*$' | head -1 | tr -d '[:space:]'
}
# Megabytes a device still has free: its size, minus every database extent
# already carved out of it.
device_free_mb() {
	ase_scalar "select ((d.high - d.low + 1) - sum(u.size)) / (1048576 / @@maxpagesize)
		from master..sysdevices d, master..sysusages u
		where d.cntrltype = 0 and d.name = '$1' and u.vdevno = d.vdevno
		group by d.high, d.low"
}
# An unreadable answer must not silently skip a growth that is needed.
as_number() { case "$1" in '' | *[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }

# tempdb ships at 80 MB on a 100 MB device (see assets/sybase-ase.rs); grow it
# at runtime so the published image is not gated on a fat tempdb.
TEMPDB_SQL=""
TEMPDB_CURRENT=$(as_number "$(ase_scalar "select sum(size) / (1048576 / @@maxpagesize) from master..sysusages where dbid = db_id('tempdb')")")
if (( SYBASE_TEMPDB_SIZE > TEMPDB_CURRENT )); then
	TEMPDB_DELTA=$((SYBASE_TEMPDB_SIZE - TEMPDB_CURRENT))
	TEMPDB_FREE=$(as_number "$(device_free_mb tempdbdev)")
	if (( TEMPDB_DELTA > TEMPDB_FREE )); then
		TEMPDB_SQL="disk resize name='tempdbdev', size='$((TEMPDB_DELTA - TEMPDB_FREE))m'
go
"
	fi
	TEMPDB_SQL="${TEMPDB_SQL}alter database tempdb on tempdbdev = '${TEMPDB_DELTA}m'
go"
fi

# The user database is carved out of the master device. Skip both the growth
# and the creation when it is already there, so a restart is a no-op.
CREATE_DB_SQL=""
if [ "$(as_number "$(ase_scalar "select count(*) from master..sysdatabases where name = '$SYBASE_DB'")")" = "0" ]; then
	MASTER_FREE=$(as_number "$(device_free_mb master)")
	if (( SYBASE_DB_SIZE > MASTER_FREE )); then
		CREATE_DB_SQL="disk resize name='master', size='$((SYBASE_DB_SIZE - MASTER_FREE))m'
go
"
	fi
	CREATE_DB_SQL="${CREATE_DB_SQL}create database $SYBASE_DB on master = '${SYBASE_DB_SIZE}m'
go
exec sp_extendsegment logsegment, $SYBASE_DB, master
go"
fi

echo =============== CREATING LOGIN/PWD ==========================
cat <<-EOSQL > init1.sql
use master
go
-- Default 'minimum password length' is 8, which silently breaks the
-- create login below for any short SYBASE_PASSWORD override.
sp_configure 'minimum password length', 0
go
${TEMPDB_SQL}
${CREATE_DB_SQL}
create login $SYBASE_USER with password $SYBASE_PASSWORD
go
exec sp_dboption $SYBASE_DB, 'abort tran on log full', true
go
exec sp_dboption $SYBASE_DB, 'allow nulls by default', true
go
exec sp_dboption $SYBASE_DB, 'ddl in tran', true
go
exec sp_dboption $SYBASE_DB, 'trunc log on chkpt', true
go
exec sp_dboption $SYBASE_DB, 'full logging for select into', true
go
exec sp_dboption $SYBASE_DB, 'full logging for alter table', true
go
sp_dboption $SYBASE_DB, "select into", true
go

EOSQL

${SYBASE}/${SYBASE_OCS}/bin/isql -Usa -PmyPassword -SMYSYBASE -i"./init1.sql" || {
	echo "ERROR: init1.sql failed (isql exit non-zero), aborting"
	exit 1
}

echo =============== CREATING DB ==========================
cat <<-EOSQL > init2.sql
use $SYBASE_DB
go

sp_adduser '$SYBASE_USER', '$SYBASE_USER', null
go

grant create default to $SYBASE_USER
go
grant create table to $SYBASE_USER
go
grant create view to $SYBASE_USER
go
grant create rule to $SYBASE_USER
go
grant create function to $SYBASE_USER
go
grant create procedure to $SYBASE_USER
go
commit
go

EOSQL

${SYBASE}/${SYBASE_OCS}/bin/isql -Usa -PmyPassword -SMYSYBASE -i"./init2.sql" || {
	echo "ERROR: init2.sql failed (isql exit non-zero), aborting"
	exit 1
}

echo =============== SYBASE INITIALIZED ==========================

while [ "$END" == '' ]; do
	sleep 1
	trap "/etc/init.d/sybase stop && END=1" INT TERM
done
