#!/bin/bash
<<Header
Script:   nc-backup.sh
Date:     05.06.2020
Author:   Nathanael Liechti
Version:  1.0
History   User    Date        Change
          technat 05.06.2020  Initial Version 1.0
Description: a "simple" backup script that saves all important config directorys, databases and data directory of nextcloud
Cronjob: 0 22 */1 * * /vault/scripts/nc-backup.sh
Dependency: rsync, mailutils

© Nathanael Liechti

Header

#############################################################################
################################# Variables #################################
#############################################################################

# general
currentDate=$(date +%Y-%m-%d)
yesterday=$(date --date="yesterday" +%Y-%m-%d)
startTime=$(date +%H:%M)
dayNr=$(date +%u)

# nc server information
sshIP="192.168.123.3"
sshPort="26127"
sshUser="ncbkp"
sshKey="/home/technat/.ssh/id_rsa"
sshSyntax="ssh -oStrictHostKeyChecking=no -i $sshKey -p $sshPort $sshUser@$sshIP"
dbName="ncdb"

# directory paths
webserverPath="/etc/apache2"
phpPath="/etc/php"
ncPath="/var/www/cloud.technat.ch"
ncDataPath="/nc-data/nc"
dbDumpFile="/tmp/"$dbName"_"$currentDate".sql"

# foldernames (just the last folder)
webserverFolder=$(echo $webserverPath | egrep -o "/[a-zA-Z0-9\.\-\_]{1,}/?$")
phpFolder=$(echo $phpPath | egrep -o "/[a-zA-Z0-9\.\-\_]{1,}/?$")
ncFolder=$(echo $ncPath | egrep -o "/[a-zA-Z0-9\.\-\_]{1,}/?$")
ncDataFolder=$(echo $ncDataPath | egrep -o "/[a-zA-Z0-9\.\-\_]{1,}/?$")

# backup vars
backupRootDir="/vault/backups/"
backupName="nc-backup_"
backupDir=$backupRootDir$backupName$currentDate
lastBackupDir=$backupRootDir$backupName$yesterday

# backup compress rotaton
compressOlderThan=8 #compress folders older than 8 days (has to be a number bigger than your last full backup you use to compare)
olderThanDate=$(date --date="$compressOlderThan days ago" +%Y-%m-%d)
backupFile=$backupRootDir"nc-backup_"$olderThanDate".bz2"
folderOlderThanLastFull=$backupRootDir$backupName$olderThanDate

# logFile Settings
logFileSuffix="_"$currentDate
logFileName="nc-backup-log"
logFileEnd=".log"
logDir="/vault/logs/"
logFile=$logDir$logFileName$logFileSuffix$logFileEnd

#############################################################################
############################### Preparations ################################
#############################################################################

###### Logfile Writing ######
echo "------------------- Backup log from nc-backup -------------------" >> $logFile
echo "Starting backup from $currentDate at $startTime" >> $logFile
### End Logfile Writing ###

# first check if log directory exists
if [ ! -d "$logDir" ]
then
  mkdir -p $saveDir
fi

# touch logfile
touch -f $logFile

lsOfBakRootDir=$(ls $backupRootDir)
# check if this is the inital backup
if [ -z "$lsOfBakRootDir" ]
then
  echo "No backups found in $backupRootDir, doing initial Backup" >> $logFile
  initialBackup=1
else
  initialBackup=0
fi

# create new backup directory
if [ ! -d "$backupDir" ]
then
  mkdir -p $backupDir
fi

# set nextcloud in maintenance mode
$sshSyntax "sudo sh -c 'cd /var/www/cloud.technat.ch; sudo -u www-data php occ maintenance:mode --on'" >> $logFile

#############################################################################
################################# Functions #################################
#############################################################################

# simple FullBackup function
FullBackup() {
  src=$1
  dest=$2
  rsync -e "ssh -p $sshPort -i $sshKey" -avp "$sshUser@$sshIP:$src" $dest >> $logFile
}

# simple InkrementalBackup function
InkrementalBackup() {
  src=$1
  dest=$2
  compareDest=$3
  rsync -e "ssh -p $sshPort -i $sshKey" -avp --link-dest=$compareDest "$sshUser@$sshIP:$src" $dest >> $logFile
}

#############################################################################
################################ Main Script ################################
#############################################################################

#--------------------------------- Daily ---------------------------------
# run daily incremental backup of config dirs, data dir and a full backup of database (dump)

# check if this is the inital backup
if [ $initialBackup -eq 1 ]
then
  FullBackup $webserverPath $backupDir
  FullBackup $phpPath $backupDir
  FullBackup $ncPath $backupDir
  FullBackup $ncDataPath $backupDir
else
  InkrementalBackup $webserverPath $backupDir $lastBackupDir$webserverFolder
  InkrementalBackup $phpPath $backupDir $lastBackupDir$phpFolder
  InkrementalBackup $ncPath $backupDir $lastBackupDir$ncFolder
  # datadir only inkremental if not sunday
  if [ ! $dayNr -eq 7 ]
  then
    InkrementalBackup $ncDataPath $backupDir $lastBackupDir$ncDataFolder
  fi
fi

# database dump (happens every day, no matter if inital backup or daily one)
# create db dump
$sshSyntax "sudo mysqldump -u root $dbName > $dbDumpFile"
if [ $? -eq 0 ]
then
  # collect dump from nc-server
  FullBackup $dbDumpFile $backupDir
else
  echo "MySQLDump failed, please take a look!" >> $logFile
fi
# remove dump form nc-server
$sshSyntax "sudo rm $dbDumpFile"


#--------------------------------- Weekly ---------------------------------
# run weekly full backups of data dir

# check if we have sunday and we did not an initial backup
if [ $dayNr -eq 7 ] && [ $initialBackup -eq 0 ]
then
  FullBackup $ncDataPath $backupDir
fi

#############################################################################
################################## Cleanup ##################################
#############################################################################

# if a folder exists that is one older than the last fullbackup, you can compress and then delete it
if [ -d $folderOlderThanLastFull ]
then
  # compress backupDir into a backupfile according to the name
    tar -cvf $backupFile $folderOlderThanLastFull
    rm -R $folderOlderThanLastFull
fi

# set maintenance mode off
$sshSyntax "sudo sh -c 'cd /var/www/cloud.technat.ch; sudo -u www-data php occ maintenance:mode --off'" >> $logFile

###### Logfile Writing ######
echo "finished backup at $(date +%H:%M)" >> $logFile
### End Logfile Writing ###
