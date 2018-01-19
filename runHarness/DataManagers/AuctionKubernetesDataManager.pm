# Copyright (c) 2017 VMware, Inc. All Rights Reserved.
# 
# Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
# Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
# Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
# 
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
# INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
# WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
# THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
package AuctionKubernetesDataManager;

use Moose;
use MooseX::Storage;
use MooseX::ClassAttribute;

use DataManagers::DataManager;
use Parameters qw(getParamValue);
use WeathervaneTypes;
use List::Util qw[min max];
use POSIX;
use Try::Tiny;
use Log::Log4perl qw(get_logger);

with Storage( 'format' => 'JSON', 'io' => 'File' );

use namespace::autoclean;

extends 'DataManager';

has '+name' => ( default => 'Weathervane', );

# default scale factors
my $defaultUsersScaleFactor           = 5;
my $defaultUsersPerAuctionScaleFactor = 15.0;

override 'initialize' => sub {
	my ($self) = @_;
	my $weathervaneHome = $self->getParamValue('weathervaneHome');
	my $configDir  = $self->getParamValue('configDir');
	if ( !( $configDir =~ /^\// ) ) {
		$configDir = $weathervaneHome . "/" . $configDir;
	}
	$self->setParamValue('configDir', $configDir);

	super();

};

sub startAuctionKubernetesDataManagerContainer {
	my ( $self, $users, $applog ) = @_;
	my $logger         = get_logger("Weathervane::DataManager::AuctionKubernetesDataManager");

	my $namespace = $self->appInstance->namespace;
	my $configDir = $self->getParamValue('configDir');
	my $maxDuration = $self->getParamValue('maxDuration');
	my $totalTime =
	  $self->getParamValue('rampUp') + $self->getParamValue('steadyState') + $self->getParamValue('rampDown');

	my $nosqlServersRef = $self->appInstance->getActiveServicesByType('nosqlServer');
	my $nosqlServerRef = $nosqlServersRef->[0];
	my $numNosqlShards = $nosqlServerRef->numNosqlShards;
	my $numNosqlReplicas = $nosqlServerRef->numNosqlReplicas;
	my $springProfilesActive = $self->appInstance->getSpringProfilesActive();

	open( FILEIN,  "$configDir/kubernetes/auctionDataManager.yaml" ) or die "$configDir/kubernetes/auctionDataManager.yaml: $!\n";
	open( FILEOUT, ">/tmp/auctionDataManager-$namespace.yaml" )             or die "Can't open file /tmp/auctionDataManager-$namespace.yaml: $!\n";
	
	while ( my $inline = <FILEIN> ) {

		if ( $inline =~ /USERS/ ) {
			print FILEOUT "USERS: $users\n";
		}
		elsif ( $inline =~ /MAXUSERS/ ) {
			print FILEOUT "  MAXUSERS: " . $self->getParamValue('maxUsers') . "\n";
		}
		elsif ( $inline =~ /USERSPERAUCTIONSCALEFACTOR/ ) {
			print FILEOUT "  USERSPERAUCTIONSCALEFACTOR: " . $self->getParamValue('usersPerAuctionScaleFactor') . "\n";
		}
		elsif ( $inline =~ /WORKLOADNUM/ ) {
			print FILEOUT "  WORKLOADNUM: $workloadNum\n";
		}
		elsif ( $inline =~ /APPINSTANCENUM/ ) {
			print FILEOUT "  APPINSTANCENUM: $appInstanceNum\n";
		}
		elsif ( $inline =~ /NUMNOSQLSHARDS/ ) {
			print FILEOUT "  NUMNOSQLSHARDS: $numNosqlShards\n";
		}
		elsif ( $inline =~ /NUMNOSQLREPLICAS/ ) {
			print FILEOUT "  NUMNOSQLREPLICAS: $numNosqlReplicas\n";
		}
		elsif ( $inline =~ /SPRINGPROFILESACTIVE/ ) {
			print FILEOUT "  SPRINGPROFILESACTIVE: $springProfilesActive\n";
		}
		elsif ( $inline =~ /MAXDURATION/ ) {
			print FILEOUT "  MAXDURATION: " . max( $maxDuration, $totalTime ) . "\n";
		}
		elsif ( $inline =~ /(\s+)imagePullPolicy/ ) {
			print FILEOUT "${1}imagePullPolicy: " . $self->appInstance->imagePullPolicy . "\n";
		}
		else {
			print FILEOUT $inline;
		}

	}
	
	close FILEIN;
	close FILEOUT;	

	my $cluster = $self->host;
	$cluster->kubernetesApply("/tmp/auctionDataManager-${namespace}.yaml", $namespace);
	
}

sub stopAuctionKubernetesDataManagerContainer {
	my ( $self, $applog ) = @_;
	my $logger         = get_logger("Weathervane::DataManager::AuctionKubernetesDataManager");
	my $cluster = $self->host;
	
	$cluster->kubernetesDelete("configMap", "$auctionDataManager-config", $self->appInstance->namespace);
	$cluster->kubernetesDelete("deployment", "auctionDataManager", $self->appInstance->namespace);

}

sub prepareData {
	my ( $self, $users, $logPath ) = @_;
	my $console_logger = get_logger("Console");
	my $logger         = get_logger("Weathervane::DataManager::AuctionKubernetesDataManager");
	my $workloadNum    = $self->getParamValue('workloadNum');
	my $appInstanceNum = $self->getParamValue('appInstanceNum');
	my $name        = $self->getParamValue('dockerName');
	my $reloadDb       = $self->getParamValue('reloadDb');
	my $appInstance    = $self->appInstance;
	my $retVal         = 0;

	my $logName = "$logPath/PrepareData_W${workloadNum}I${appInstanceNum}.log";
	my $logHandle;
	open( $logHandle, ">$logName" ) or do {
		$console_logger->error("Error opening $logName:$!");
		return 0;
	};

	$console_logger->info(
		"Configuring and starting data services for appInstance $appInstanceNum of workload $workloadNum.\n" );
	$logger->debug("prepareData users = $users, logPath = $logPath");
	print $logHandle "prepareData users = $users, logPath = $logPath\n";

	# Start the data services
	if ($reloadDb) {
		# Avoid an extra stop/start cycle for the data services since we know
		# we are reloading the data
		$appInstance->clearDataServicesBeforeStart($logPath);
	}
	$appInstance->startServices("data", $logPath);
	# Make sure that the services know their external port numbers
	$self->appInstance->setExternalPortNumbers();
	sleep(10);

	# Make sure that all of the data services are up
	$logger->debug(
		"Checking that all data services are up for appInstance $appInstanceNum of workload $workloadNum." );
	my $allUp = $appInstance->isUpDataServices($logPath);
	if ( !$allUp ) {
		$console_logger->error(
			"Couldn't bring up all data services for appInstance $appInstanceNum of workload $workloadNum." );
		return 0;
	}
	$logger->debug( "All data services are up for appInstance $appInstanceNum of workload $workloadNum." );

	$self->startAuctionKubernetesDataManagerContainer ($users, $logHandle);
		
	my $loadedData = 0;
	if ($reloadDb) {
		$appInstance->clearDataServicesAfterStart($logPath);

		# Have been asked to reload the data
		$retVal = $self->loadData( $users, $logPath );
		if ( !$retVal ) { return 0; }
		$loadedData = 1;

		# Clear reloadDb so we don't reload on each run of a series
		$self->setParamValue( 'reloadDb', 0 );
	}
	else {
		if ( !$self->isDataLoaded( $users, $logPath ) ) {
			if ( $self->getParamValue('loadDb') ) {
				$console_logger->info(
					    "Data is not loaded for $users users for appInstance "
					  . "$appInstanceNum of workload $workloadNum. Loading data." );

				# Load the data
				$appInstance->stopServices("data", $logPath);
				$appInstance->clearDataServicesBeforeStart($logPath);
				$appInstance->startServices("data", $logPath);

				$logger->debug( "All data services configured and started for appInstance "
					  . "$appInstanceNum of workload $workloadNum.  Checking if they are up." );

				# Make sure that all of the data services are up
				my $allUp = $appInstance->isUpDataServices($logPath);
				if ( !$allUp ) {
					$console_logger->error( "Couldn't bring up all data services for appInstance "
						  . "$appInstanceNum of workload $workloadNum." );
					return 0;
				}

				$logger->debug( "Clear data services after start for appInstance "
					  . "$appInstanceNum of workload $workloadNum.  Checking if they are up." );
				$appInstance->clearDataServicesAfterStart($logPath);

				$retVal = $self->loadData( $users, $logPath );
				if ( !$retVal ) { return 0; }
				$loadedData = 1;

			}
			else {
				$console_logger->error( "Data not loaded for $users users for appInstance "
					  . "$appInstanceNum of workload $workloadNum. To load data, run again with loadDb=true.  Exiting.\n"
				);
				return 0;

			}
		}
		else {
			$console_logger->info( "Data is already loaded for appInstance "
				  . "$appInstanceNum of workload $workloadNum.  Preparing data for current run." );

			# cleanup the databases from any previous run
			$self->cleanData( $users, $logHandle );

		}
	}

	# If the imageStore type is filesystem, then clean added images from the filesystem
	if ( $self->getParamValue('imageStoreType') eq "filesystem" ) {

		my $fileServersRef    = $self->appInstance->getActiveServicesByType('fileServer');
		my $imageStoreDataDir = $self->getParamValue('imageStoreDir');
		foreach my $fileServer (@$fileServersRef) {
			my $sshConnectString = $fileServer->host->sshConnectString;
			`$sshConnectString \"find $imageStoreDataDir -name '*added*' -delete 2>&1\"`;
		}

	}

	print $logHandle "Exec-ing perl /prepareData.pl  in container $name\n";
	$logger->debug("Exec-ing perl /prepareData.pl  in container $name");
	my $cluster  = $self->host;	
	$cluster->kubernetesExecOne("auctiondatamanager", "perl /prepareData.pl", $self->appInstance->namespace);
	if ($?) {
		$console_logger->error( "Data preparation process failed.  Check PrepareData.log for more information." );
		return 0;
	}

#	my $nosqlServersRef = $self->appInstance->getActiveServicesByType('nosqlServer');
#	my $nosqlServerRef = $nosqlServersRef->[0];
#	if (   ( $nosqlServerRef->numNosqlReplicas > 0 )
#		&& ( $nosqlServerRef->numNosqlShards == 0 ) )
#	{
#		$console_logger->info("Waiting for MongoDB Replicas to finish synchronizing.");
#		waitForMongodbReplicaSync( $self, $logHandle );
#	}

	# stop the auctiondatamanager container
	$self->stopAuctionKubernetesDataManagerContainer ($logHandle);

	# stop the data services. They must be started in the main process
	# so that the port numbers are available
	$appInstance->stopServices("data", $logPath);

	close $logHandle;
}

sub pretouchData {
	my ( $self, $logPath ) = @_;
	my $console_logger = get_logger("Console");
	my $logger         = get_logger("Weathervane::DataManager::AuctionKubernetesDataManager");
	my $workloadNum    = $self->getParamValue('workloadNum');
	my $appInstanceNum = $self->getParamValue('appInstanceNum');
	my $name        = $self->getParamValue('dockerName');
	my $retVal         = 0;
	$logger->debug( "pretouchData for workload ", $workloadNum );

	my $logName = "$logPath/PretouchData_W${workloadNum}I${appInstanceNum}.log";
	my $logHandle;
	open( $logHandle, ">$logName" ) or do {
		$console_logger->error("Error opening $logName:$!");
		return 0;
	};

	my $nosqlServersRef = $self->appInstance->getActiveServicesByType('nosqlServer');

	my @pids            = ();
	if ( $self->getParamValue('mongodbTouch') ) {
		my $nosqlService = $nosqlServersRef->[0];
		if ($nosqlService->host->getParamValue('vicHost')) {
			# mongoDb takes longer to start on VIC
			sleep 240;
		}

		foreach $nosqlService (@$nosqlServersRef) {

			my $hostname = $nosqlService->getIpAddr();
			my $port     = $nosqlService->portMap->{'mongod'};
			my $cmdString;
			my $cmdout;
			my $pid;
			if ( $self->getParamValue('mongodbTouchFull') ) {
				$pid = fork();
				if ( !defined $pid ) {
					$console_logger->error("Couldn't fork a process: $!");
					exit(-1);
				}
				elsif ( $pid == 0 ) {
					print $logHandle "Touching imageFull collection to preload data and indexes\n";
					$cmdString =
"mongo --port $port --host $hostname --eval 'db.imageFull.find({'imageid' : {\$gt : 0}}, {'image' : 0}).count()' auctionFullImages";
					$cmdout = `$cmdString`;
					print $logHandle "$cmdString\n";
					print $logHandle $cmdout;

					$cmdString =
"mongo --port $port --host $hostname --eval 'db.imageFull.find({'_id' : {\$ne : 0}}, {'image' : 0}).count()' auctionFullImages";
					$cmdout = `$cmdString`;
					print $logHandle "$cmdString\n";
					print $logHandle $cmdout;
					exit;
				}
				else {
					push @pids, $pid;
				}
			}

			if ( $self->getParamValue('mongodbTouchPreview') ) {
				$pid = fork();
				if ( !defined $pid ) {
					$console_logger->error("Couldn't fork a process: $!");
					exit(-1);
				}
				elsif ( $pid == 0 ) {
					print $logHandle "Touching imagePreview collection to preload data and indexes\n";
					$cmdString =
"mongo --port $port --host $hostname --eval 'db.imagePreview.find({'imageid' : {\$gt : 0}}, {'image' : 0}).count()' auctionPreviewImages";
					$cmdout = `$cmdString`;
					print $logHandle "$cmdString\n";
					print $logHandle $cmdout;
					exit;
				}
				else {
					push @pids, $pid;
				}

				$pid = fork();
				if ( !defined $pid ) {
					$console_logger->error("Couldn't fork a process: $!");
					exit(-1);
				}
				elsif ( $pid == 0 ) {
					$cmdString =
"mongo --port $port --host $hostname --eval 'db.imagePreview.find({'_id' : {\$ne : 0}}, {'image' : 0}).count()' auctionPreviewImages";
					$cmdout = `$cmdString`;
					print $logHandle "$cmdString\n";
					print $logHandle $cmdout;
					exit;
				}
				else {
					push @pids, $pid;
				}
			}
			$pid = fork();
			if ( !defined $pid ) {
				$console_logger->error("Couldn't fork a process: $!");
				exit(-1);
			}
			elsif ( $pid == 0 ) {
				print $logHandle "Touching imageThumbnail collection to preload data and indexes\n";
				$cmdString =
"mongo --port $port --host $hostname --eval 'db.imageThumbnail.find({'imageid' : {\$gt : 0}}, {'image' : 0}).count()' auctionThumbnailImages";
				$cmdout = `$cmdString`;
				print $logHandle "$cmdString\n";
				print $logHandle $cmdout;

				exit;
			}
			else {
				push @pids, $pid;
			}

			$pid = fork();
			if ( !defined $pid ) {
				$console_logger->error("Couldn't fork a process: $!");
				exit(-1);
			}
			elsif ( $pid == 0 ) {
				$cmdString =
"mongo --port $port --host $hostname --eval 'db.imageThumbnail.find({'_id' : {\$ne : 0}}, {'image' : 0}).count()' auctionThumbnailImages";
				$cmdout = `$cmdString`;
				print $logHandle "$cmdString\n";
				print $logHandle $cmdout;
				exit;
			}
			else {
				push @pids, $pid;
			}

			$pid = fork();
			if ( !defined $pid ) {
				$console_logger->error("Couldn't fork a process: $!");
				exit(-1);
			}
			elsif ( $pid == 0 ) {
				print $logHandle "Touching imageInfo collection to preload data and indexes\n";
				$cmdString =
"mongo --port $port --host $hostname --eval 'db.imageInfo.find({'filepath' : {\$ne : \"\"}}).count()' imageInfo";
				$cmdout = `$cmdString`;
				print $logHandle "$cmdString\n";
				print $logHandle $cmdout;

				exit;
			}
			else {
				push @pids, $pid;
			}

			$pid = fork();
			if ( !defined $pid ) {
				$console_logger->error("Couldn't fork a process: $!");
				exit(-1);
			}
			elsif ( $pid == 0 ) {
				$cmdString =
"mongo --port $port --host $hostname --eval 'db.imageInfo.find({'_id' : {\$ne : 0}}).count()' imageInfo";
				$cmdout = `$cmdString`;
				print $logHandle "$cmdString\n";
				print $logHandle $cmdout;
				exit;
			}
			else {
				push @pids, $pid;
			}

			$pid = fork();
			if ( !defined $pid ) {
				$console_logger->error("Couldn't fork a process: $!");
				exit(-1);
			}
			elsif ( $pid == 0 ) {
				print $logHandle "Touching attendanceRecord collection to preload data and indexes\n";
				$cmdString =
"mongo --port $port --host $hostname --eval 'db.attendanceRecord.find({'_id' : {\$ne : 0}}).count()' attendanceRecord";
				$cmdout = `$cmdString`;
				print $logHandle "$cmdString\n";
				print $logHandle $cmdout;
				exit;
			}
			else {
				push @pids, $pid;
			}

			$pid = fork();
			if ( !defined $pid ) {
				$console_logger->error("Couldn't fork a process: $!");
				exit(-1);
			}
			elsif ( $pid == 0 ) {
				$cmdString =
"mongo --port $port --host $hostname --eval 'db.attendanceRecord.find({'userId' : {\$gt : 0}, 'timestamp' : {\$gt:ISODate(\"2000-01-01\")}}).count()' attendanceRecord";
				$cmdout = `$cmdString`;
				print $logHandle "$cmdString\n";
				print $logHandle $cmdout;

				exit;
			}
			else {
				push @pids, $pid;
			}

			$pid = fork();
			if ( !defined $pid ) {
				$console_logger->error("Couldn't fork a process: $!");
				exit(-1);
			}
			elsif ( $pid == 0 ) {
				$cmdString =
"mongo --port $port --host $hostname --eval 'db.attendanceRecord.find({'userId' : {\$gt : 0}, '_id' : {\$ne: 0 }}).count()' attendanceRecord";
				$cmdout = `$cmdString`;
				print $logHandle "$cmdString\n";
				print $logHandle $cmdout;
				exit;
			}
			else {
				push @pids, $pid;
			}

			$pid = fork();
			if ( !defined $pid ) {
				$console_logger->error("Couldn't fork a process: $!");
				exit(-1);
			}
			elsif ( $pid == 0 ) {
				$cmdString =
"mongo --port $port --host $hostname --eval 'db.attendanceRecord.find({'userId' : {\$gt : 0}, 'auctionId' : {\$gt: 0 }, 'state' :{\$ne : \"\"} }).count()' attendanceRecord";
				$cmdout = `$cmdString`;
				print $logHandle "$cmdString\n";
				print $logHandle $cmdout;
				exit;
			}
			else {
				push @pids, $pid;
			}

			$pid = fork();
			if ( !defined $pid ) {
				$console_logger->error("Couldn't fork a process: $!");
				exit(-1);
			}
			elsif ( $pid == 0 ) {
				$cmdString =
"mongo --port $port --host $hostname --eval 'db.attendanceRecord.find({'auctionId' : {\$gt : 0}}).count()' attendanceRecord";
				$cmdout = `$cmdString`;
				print $logHandle "$cmdString\n";
				print $logHandle $cmdout;
				exit;
			}
			else {
				push @pids, $pid;
			}

			$pid = fork();
			if ( !defined $pid ) {
				$console_logger->error("Couldn't fork a process: $!");
				exit(-1);
			}
			elsif ( $pid == 0 ) {
				print $logHandle "Touching bid collection to preload data and indexes\n";
				$cmdString =
				  "mongo --port $port --host $hostname --eval 'db.bid.find({'_id' : {\$ne : 0}}).count()' bid";
				$cmdout = `$cmdString`;
				print $logHandle "$cmdString\n";
				print $logHandle $cmdout;
				exit;
			}
			else {
				push @pids, $pid;
			}

			$pid = fork();
			if ( !defined $pid ) {
				$console_logger->error("Couldn't fork a process: $!");
				exit(-1);
			}
			elsif ( $pid == 0 ) {
				$cmdString =
"mongo --port $port --host $hostname --eval 'db.bid.find({'bidderId' : {\$gt : 0}, 'bidTime' : {\$gt:ISODate(\"2000-01-01\")}}).count()' bid";
				$cmdout = `$cmdString`;
				print $logHandle "$cmdString\n";
				print $logHandle $cmdout;
				exit;
			}
			else {
				push @pids, $pid;
			}

			$pid = fork();
			if ( !defined $pid ) {
				$console_logger->error("Couldn't fork a process: $!");
				exit(-1);
			}
			elsif ( $pid == 0 ) {
				$cmdString =
"mongo --port $port --host $hostname --eval 'db.bid.find({'bidderId' : {\$gt : 0}, '_id' : {\$ne: 0 }}).count()' bid";
				$cmdout = `$cmdString`;
				print $logHandle "$cmdString\n";
				print $logHandle $cmdout;
				exit;
			}
			else {
				push @pids, $pid;
			}

			$pid = fork();
			if ( !defined $pid ) {
				$console_logger->error("Couldn't fork a process: $!");
				exit(-1);
			}
			elsif ( $pid == 0 ) {
				$cmdString =
				  "mongo --port $port --host $hostname --eval 'db.bid.find({'itemid' : {\$gt : 0}}).count()' bid";
				$cmdout = `$cmdString`;
				print $logHandle "$cmdString\n";
				print $logHandle $cmdout;
				exit;
			}
			else {
				push @pids, $pid;
			}

		}

	}

	foreach my $pid (@pids) {
		waitpid $pid, 0;
	}

	$logger->debug( "pretouchData complete for workload ", $workloadNum );

	close $logHandle;
}

sub loadData {
	my ( $self, $users, $logPath ) = @_;
	my $console_logger   = get_logger("Console");
	my $logger           = get_logger("Weathervane::DataManager::AuctionKubernetesDataManager");
	my $hostname    = $self->host->hostName;
	my $name        = $self->getParamValue('dockerName');

	my $workloadNum    = $self->getParamValue('workloadNum');
	my $appInstanceNum = $self->getParamValue('appInstanceNum');
	my $logName          = "$logPath/loadData-W${workloadNum}I${appInstanceNum}-$hostname.log";
	my $appInstance      = $self->appInstance;
	my $sshConnectString = $self->host->sshConnectString;

	$logger->debug("loadData for workload $workloadNum, appInstance $appInstanceNum");

	my $applog;
	open( $applog, ">$logName" )
	  or do {
		$console_logger->error("Error opening $logName:$!");
		return 0;
	  };

	my $maxUsers = $self->getParamValue('maxUsers');	
	if ( $users > $maxUsers ) {
		$maxUsers = $users;
	}

	$console_logger->info(
		"Workload $workloadNum, appInstance $appInstanceNum: Loading data for a maximum of $maxUsers users" );

	$logger->debug("Exec-ing perl /loadData.pl in container $name");
	print $applog "Exec-ing perl /loadData.pl in container $name\n";
	my $dockerHostString  = $self->host->dockerHostString;
	
	open my $pipe, "$dockerHostString docker exec $name perl /loadData.pl  |"   or die "Couldn't execute program: $!";
 	while ( defined( my $line = <$pipe> )  ) {
		chomp($line);
		if ($line =~ /Loading/) {
  			print "$line\n";			
		} 
   	}
   	close $pipe;	
	close $applog;
	
	my $nosqlServersRef = $self->appInstance->getActiveServicesByType('nosqlServer');
	my $nosqlServerRef = $nosqlServersRef->[0];
	if (   ( $nosqlServerRef->numNosqlReplicas > 0 )
		&& ( $nosqlServerRef->numNosqlShards == 0 ) )
	{
		$console_logger->info("Waiting for MongoDB Replicas to finish synchronizing.");
		waitForMongodbReplicaSync( $self, $applog );
	}

	close $applog;

	# Now make sure that the data is really loaded properly
	my $isDataLoaded = 0;
	try {
		$isDataLoaded = $self->isDataLoaded( $users, $logPath );
	};

	if ( !$isDataLoaded ) {
		$console_logger->error(
			"Data is still not loaded properly.  Check the logs of the data services for errors.\n" );
		return 0;
	}
	return 1;
}

sub isDataLoaded {
	my ( $self, $users, $logPath ) = @_;
	my $console_logger = get_logger("Console");
	my $logger         = get_logger("Weathervane::DataManager::AuctionKubernetesDataManager");

	my $workloadNum    = $self->getParamValue('workloadNum');
	my $appInstanceNum = $self->getParamValue('appInstanceNum');
	$logger->debug("isDataLoaded for workload $workloadNum, appInstance $appInstanceNum");

	my $hostname = $self->host->hostName;
	my $name        = $self->getParamValue('dockerName');

	my $logName = "$logPath/isDataLoaded-W${workloadNum}I${appInstanceNum}-$hostname.log";
	my $applog;
	open( $applog, ">$logName" )
	  || die "Error opening /$logName:$!";

	print $applog "Exec-ing perl /isDataLoaded.pl  in container $name\n";
	$logger->debug("Exec-ing perl /isDataLoaded.pl  in container $name");
	my $dockerHostString  = $self->host->dockerHostString;	
	my $cmdOut = `$dockerHostString docker exec $name perl /isDataLoaded.pl`;
	print $applog "Output: $cmdOut, \$? = $?\n";
	$logger->debug("Output: $cmdOut, \$? = $?");
	close $applog;
	if ($?) {
		$logger->debug( "Data is not loaded for workload $workloadNum, appInstance $appInstanceNum. \$cmdOut = $cmdOut" );
		return 0;
	}
	else {
		$logger->debug( "Data is loaded for workload $workloadNum, appInstance $appInstanceNum. \$cmdOut = $cmdOut" );
		return 1;
	}


}


sub cleanData {
	my ( $self, $users, $logHandle ) = @_;
	my $console_logger = get_logger("Console");
	my $logger         = get_logger("Weathervane::DataManager::AuctionKubernetesDataManager");
	my $workloadNum    = $self->getParamValue('workloadNum');
	my $appInstanceNum = $self->getParamValue('appInstanceNum');
	my $name        = $self->getParamValue('dockerName');

	my $appInstance = $self->appInstance;
	my $retVal      = 0;


	$console_logger->info(
		"Cleaning and compacting storage on all data services.  This can take a long time after large runs." );
	$logger->debug("cleanData.  user = $users");

	# If the imageStore type is filesystem, then clean added images from the filesystem
	if ( $self->getParamValue('imageStoreType') eq "filesystem" ) {
		$logger->debug("cleanData. Deleting added images from fileserver");

		my $fileServersRef    = $self->appInstance->getActiveServicesByType('fileServer');
		my $imageStoreDataDir = $self->getParamValue('imageStoreDir');
		foreach my $fileServer (@$fileServersRef) {
			$logger->debug(
				"cleanData. Deleting added images for workload ",
				$workloadNum, " appInstance ",
				$appInstanceNum, " on host ", $fileServer->getIpAddr()
			);
			my $sshConnectString = $fileServer->host->sshConnectString;
			`$sshConnectString \"find $imageStoreDataDir -name '*added*' -delete 2>&1\"`;
		}

	}

	$logger->debug(
		"cleanData. Cleaning up data services for appInstance " . "$appInstanceNum of workload $workloadNum." );
	print $logHandle "Cleaning up data services for appInstance " . "$appInstanceNum of workload $workloadNum.\n";

	print $logHandle "Exec-ing perl /cleanData.pl  in container $name\n";
	$logger->debug("Exec-ing perl /cleanData.pl  in container $name");
	my $dockerHostString  = $self->host->dockerHostString;	
	my $cmdOut = `$dockerHostString docker exec $name perl /cleanData.pl`;
	print $logHandle "Output: $cmdOut, \$? = $?\n";
	$logger->debug("Output: $cmdOut, \$? = $?");

	if ($?) {
		$console_logger->error(
			"Data cleaning process failed.  Check CleanData_W${workloadNum}I${appInstanceNum}.log for more information."
		);
		return 0;
	}

	my $nosqlServersRef = $self->appInstance->getActiveServicesByType('nosqlServer');
	my $nosqlService = $nosqlServersRef->[0];
	if (   ( $nosqlService->numNosqlReplicas > 0 )
		&& ( $nosqlService->numNosqlShards == 0 ) )
	{
		$console_logger->info("Waiting for MongoDB Replicas to finish synchronizing.");
		waitForMongodbReplicaSync( $self, $logHandle );
	}

	if ( $self->getParamValue('mongodbCompact') ) {

		# Compact all mongodb collections
		foreach my $nosqlService (@$nosqlServersRef) {
			my $hostname         = $nosqlService->getIpAddr();
			my $port             = $nosqlService->portMap->{'mongod'};
			print $logHandle "Compacting MongoDB collections on $hostname\n";
			$logger->debug(
				"cleanData. Compacting MongoDB collections on $hostname for workload ",
				$workloadNum, " appInstance ",
				$appInstanceNum
			);

			$logger->debug(
				"cleanData. Compacting attendanceRecord collection on $hostname for workload ",
				$workloadNum, " appInstance ",
				$appInstanceNum
			);
			my $cmdString =
"mongo --port $port --host $hostname --eval 'printjson(db.runCommand({ compact: \"attendanceRecord\" }))' attendanceRecord";
			print $logHandle "$cmdString\n";
			my $cmdout = `$cmdString`;
			print $logHandle $cmdout;

			$logger->debug(
				"cleanData. Compacting bid collection on $hostname for workload ",
				$workloadNum, " appInstance ",
				$appInstanceNum
			);
			$cmdString =
			  "mongo --port $port --host $hostname --eval 'printjson(db.runCommand({ compact: \"bid\" }))' bid";
			print $logHandle "$cmdString\n";
			$cmdout = `$cmdString`;
			print $logHandle $cmdout;

			$logger->debug(
				"cleanData. Compacting imageInfo collection on $hostname for workload ",
				$workloadNum, " appInstance ",
				$appInstanceNum
			);
			$cmdString =
"mongo --port $port --host $hostname --eval 'printjson(db.runCommand({ compact: \"imageInfo\" }))' imageInfo";
			print $logHandle "$cmdString\n";
			$cmdout = `$cmdString`;
			print $logHandle $cmdout;

			$logger->debug(
				"cleanData. Compacting imageFull collection on $hostname for workload ",
				$workloadNum, " appInstance ",
				$appInstanceNum
			);
			$cmdString =
"mongo --port $port --host $hostname --eval 'printjson(db.runCommand({ compact: \"imageFull\" }))' auctionFullImages";
			print $logHandle "$cmdString\n";
			$cmdout = `$cmdString`;
			print $logHandle $cmdout;

			$logger->debug(
				"cleanData. Compacting imagePreview collection on $hostname for workload ",
				$workloadNum, " appInstance ",
				$appInstanceNum
			);
			$cmdString =
"mongo --port $port --host $hostname --eval 'printjson(db.runCommand({ compact: \"imagePreview\" }))' auctionPreviewImages";
			print $logHandle "$cmdString\n";
			$cmdout = `$cmdString`;
			print $logHandle $cmdout;

			$logger->debug(
				"cleanData. Compacting imageThumbnail collection on $hostname for workload ",
				$workloadNum, " appInstance ",
				$appInstanceNum
			);
			$cmdString =
"mongo --port $port --host $hostname --eval 'printjson(db.runCommand({ compact: \"imageThumbnail\" }))' auctionThumbnailImages";
			print $logHandle "$cmdString\n";
			$cmdout = `$cmdString`;
			print $logHandle $cmdout;

			$logger->debug(
				"cleanData. Getting du -hsc /mnt/mongoData on $hostname for workload ",
				$workloadNum, " appInstance ",
				$appInstanceNum
			);

		}
	}
}

__PACKAGE__->meta->make_immutable;

1;
