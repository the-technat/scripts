#!/usr/bin/bash
<<Header
Script:   nc-backup.sh
Date:     05.06.2020
Author:   Technat
Version:  1.1
History   User    Date        Change
          technat 05.06.2020  Initial Version 1.0
          technat 15.04.2021  refine script, make ready for productive use
Description: a backup script for nextcloud that saves all important config directorys, databases and data directories using rsync to a remote server over ssh
Cronjob: 0 22 */1 * * /vault/scripts/nc-backup.sh
Dependency: rsync, openssh, nailutils
Syntax: Variables -> camelCase / Functions -> PascalCase
Credits: Some aspects of the script are inspired by https://codeberg.org/DecaTec/Nextcloud-Backup-Restore

© Technat

Header

#############################################################################
################################# Variables #################################
#############################################################################

### General
currentDate=$(date +%Y-%m-%d)
yesterday=$(date --date="yesterday" +%Y-%m-%d)
backupStartTime=$(date +%H:%M)
dayOfTheWeek=$(date +%u)
backupHost=$(uname -n)

### NC server settings
# please specify paths without ending /
sshIP="192.168.63.50"
sshPort="26127"
sshUser="nc-backup"
sshKey="/home/technat/.ssh/cloud_id_rsa"
# sshSyntax="ssh -oStrictHostKeyChecking=no -i $sshKey -p $sshPort $sshUser@$sshIP"
sshSyntax="ssh -i $sshKey -p $sshPort $sshUser@$sshIP"
dbName="ncdb"
apacheConfigPath="/etc/apache2"
apacheConfigDir=$(echo $apacheConfigPath | egrep -o "/[a-zA-Z0-9\.\-\_]{1,}/?$")
phpConfigPath="/etc/php"
phpConfigDir=$(echo $phpConfigPath | egrep -o "/[a-zA-Z0-9\.\-\_]{1,}/?$")
ncPath="/var/www/cloud.technat.ch"
ncDir=$(echo $ncPath | egrep -o "/[a-zA-Z0-9\.\-\_]{1,}/?$")
ncDataPath="/nc-data/nc"
ncDataDir=$(echo $ncDataPath | egrep -o "/[a-zA-Z0-9\.\-\_]{1,}/?$")
dbDumpFile="/tmp/"$dbName"_"$currentDate".sql"
occPath=$ncPath"/occ"

# backup vars
backupRootPath="/home/technat/cloud.technat.ch/"
backupName="nc-backup_"
backupDir=$backupRootPath$backupName$currentDate
lastBackupDir=$backupRootPath$backupName$yesterday

# backup rotation
compressOlderThan=8 #compress folders older than 8 days (has to be a number bigger than your last full backup you use to compare)
olderThanDate=$(date --date="$compressOlderThan days ago" +%Y-%m-%d) # holds the date from where on older backups can be rotated
backupFile=$backupRootPath"nc-backup_"$olderThanDate".bz2" # name of archived backup files
folderOlderThanLastFull=$backupRootPath$backupName$olderThanDate # assume the name of the backup to rotate

# logFile Settings
logFileSuffix="_"$currentDate
logFileName="nc-backup-log"
logFileEnd=".log"
logDir="/home/technat/cloud.technat.ch/logs/"
logFile=$logDir$logFileName$logFileSuffix$logFileEnd

#############################################################################
############################### Preparations ################################
#############################################################################

###### Logfile Writing ######
echo "------------------- Backup log from nc-backup ($backupHost) -------------------" >> $logFile
echo "Starting backup from $currentDate at $backupStartTime" >> $logFile
### End Logfile Writing ###

# first check if log directory exists
if [ ! -d "$logDir" ]
then
  mkdir -p $logDir
fi

# touch logfile
touch -f $logFile

# an empty backup root directory means that this script runs the first time
# the initial backup will always be a full backup
lsOfBakRootDir=$(ls $backupRootPath | grep $backupName)
# check if this is the inital backup
if [ -z "$lsOfBakRootDir" ]
then
  echo "No backups found in $backupRootPath, doing initial Backup" >> $logFile
  initialBackup=1
else
  initialBackup=0
fi

# create todays backup directory
if [ ! -d "$backupDir" ]
then
  mkdir -p $backupDir
fi

# set nextcloud in maintenance mode
$sshSyntax "sudo sh -c 'sudo -u www-data php $occPath maintenance:mode --on'" >> $logFile
# $sshSyntax "sudo systemctl stop apache2" >> $logFile
#############################################################################
################################# Functions #################################
#############################################################################

# simple FullBackup function
# directory indexing takes a lot of time, so fullBackups are not done via rsync but rather using zip and scp
FullBackup() {
  src=$1
  dest=$2
  lastFolder=$(echo $src | egrep -o '[^/]{1,}$')
  zipName=$zipName".zip"
  # rsync -e "ssh -p $sshPort -i $sshKey" -avp "$sshUser@$sshIP:$src" $dest >> $logFile
  $sshSyntax "zip -r $zipName $src" $logFile
  scp -P $sshPort -i $sshKey $sshUser@$sshIP:$zipName $dest >> $logFile
  unzip $dest$zipName
  $sshSyntax "rm -rf $zipName" >> $logFile
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

# Normal Daily / Weekly Mode
if [ $initialBackup -eq 0 ]
then
	#--------------------------------- Daily ---------------------------------
	# run daily incremental backup of config and data dirs
	if [ ! $dayOfTheWeek -eq 7 ]
	then
	    InkrementalBackup $apacheConfigPath $backupDir $lastBackupDir$apacheConfigDir
	    InkrementalBackup $phpConfigPath $backupDir $lastBackupDir$phpConfigDir
	    InkrementalBackup $ncPath $backupDir $lastBackupDir$ncDir
	    InkrementalBackup $ncDataPath $backupDir $lastBackupDir$ncDataDir
	fi

	#--------------------------------- Weekly ---------------------------------
	# run weekly full backup of config and data dirs
	if [ $dayOfTheWeek -eq 7 ] 
	then
	    FullBackup $apacheConfigPath $backupDir
	    FullBackup $phpConfigPath $backupDir
	    FullBackup $ncPath $backupDir
	    FullBackup $ncDataPath $backupDir
	fi

	#--------------------------------- Database ---------------------------------
	# database dump (happens every day as full backup)
	$sshSyntax "sudo mysqldump -u root $dbName --result-file $dbDumpFile" >> $logFile
	if [ $? -eq 0 ]
	then
	  # collect dump from nc-server
	  FullBackup $dbDumpFile $backupDir
	else
	  echo "MySQLDump failed, please take a look!" >> $logFile
	fi
	# remove dump form nc-server
	$sshSyntax "sudo rm $dbDumpFile"
fi

# Initial Backup Mode
if [ $initialBackup -eq 1 ]
then
	# Initial Backup means we save everything 
	FullBackup $apacheConfigPath $backupDir
	FullBackup $phpConfigPath $backupDir
	FullBackup $ncPath $backupDir
	FullBackup $ncDataPath $backupDir
fi

#############################################################################
################################## Cleanup ##################################
#############################################################################

# if a folder exists that is one older than the last fullbackup, you can compress and then delete it
if [ -d $folderOlderThanLastFull ] 
then
    #compress backupDir into a backupfile according to the name
    tar -cvf $backupFile $folderOlderThanLastFull
    rm -R $folderOlderThanLastFull
fi

# set maintenance mode off
$sshSyntax "sudo systemctl start apache2" >> $logFile
$sshSyntax "sudo sh -c 'sudo -u www-data php $occPath maintenance:mode --off'" >> $logFile

###### Logfile Writing ######
echo "finished backup at $(date +%H:%M)" >> $logFile
### End Logfile Writing ###
