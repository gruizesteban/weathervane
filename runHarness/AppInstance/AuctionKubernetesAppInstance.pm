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
package AuctionKubernetesAppInstance;

use Moose;
use MooseX::Storage;
use MooseX::ClassAttribute;
use POSIX;
use Tie::IxHash;
use Log::Log4perl qw(get_logger);
use AppInstance::AuctionAppInstance;
use ComputeResources::Cluster;

with Storage( 'format' => 'JSON', 'io' => 'File' );

use namespace::autoclean;

use WeathervaneTypes;

extends 'AuctionAppInstance';

has 'namespace' => (
	is  => 'rw',
	isa => 'Str',
);

has 'host' => (
	is  => 'rw',
	isa => 'Cluster',
);

has 'imagePullPolicy' => (
	is      => 'rw',
	isa     => 'Str',
	default => "IfNotPresent",
);

override 'initialize' => sub {
	my ($self) = @_;
	
	$self->namespace("auctionw" . $self->getParamValue('workloadNum') . "i" . $self->getParamValue('appInstanceNum'));

	if ($self->getParamValue('redeploy')) {
	    $self->imagePullPolicy('Always');
	}
	
	super();

};

sub setHost {
	my ($self, $host) = @_;
	
	$self->host($host);

	my $namespace = $self->namespace;
	
	# Create the namespace and the namespace-wide resources
	my $configDir        = $self->getParamValue('configDir');
	open( FILEIN,  "$configDir/kubernetes/namespace.yaml" ) or die "$configDir/kubernetes/namespace.yaml: $!\n";
	open( FILEOUT, ">/tmp/namespace-$namespace.yaml" )             or die "Can't open file /tmp/namespace-$namespace.yaml: $!\n";
	
	while ( my $inline = <FILEIN> ) {
		if ( $inline =~ /\s\sname:/ ) {
			print FILEOUT "  name: $namespace\n";
		}
		else {
			print FILEOUT $inline;
		}
	}
	close FILEIN;
	close FILEOUT;
	$host->kubernetesApply("/tmp/namespace-$namespace.yaml", $self->namespace);
	
	# Create the tls secret for the ingress controller
	$logger->debug("Create tls secret for namespace ", $self->namespace);
	my $cmd = "kubectl create secret tls tls-secret --key $configDir/host/centos7/tls/private/weathervane.key --cert $configDir/host/centos7/tls/private/weathervane.crt --namespace=$namespace 2>&1"; 
	my $outString = `$cmd`;
	$logger->debug("Command: $cmd");
	$logger->debug("Output: $outString");
	
	# Create the ingress controller in the namespace
	$host->kubernetesApply("$configDir/kubernetes/ingressControllerNginx.yaml", $self->namespace);
	
	# Create the service for the ingress controller
	$host->kubernetesApply("$configDir/kubernetes/ingressControllerNginxService.yaml", $self->namespace);
	
	# Create the ingress for the appInstance
	$host->kubernetesApply("$configDir/kubernetes/auctionIngress.yaml", $self->namespace);
		
}

sub cleanup {
	my ( $self, $cleanupLogDir ) = @_;
	my $logger = get_logger("Weathervane::AppInstance::AppInstance");
	
	my $cluster = $self->host;
	$cluster->kubernetesDeleteAllWithLabel("type=appInstance", $self->namespace);

}

override 'getWwwIpAddrsRef' => sub {
	my ($self) = @_;
	my $cluster = $self->host;
	
	my $wwwIpAddrsRef = [];
	
	# Get the IP address of the nginx-ingress in this appInstance's namespace
	my $ipAddr = $host->kubernetesGetIngressIp("type=appInstance", $self->namespace);
	
	# Get the nodePort numbers for the ingress-controller-nginx service
	my $httpPort = $host->kubernetesGetNodePortForPortNumber("type=appInstance", 80, $self->namespace);
	my $httpsPort = $host->kubernetesGetNodePortForPortNumber("type=appInstance", 443, $self->namespace);
	
	push @$wwwIpAddrsRef, [$ipAddr, $httpPort, $httpsPort];					
	return $wwwIpAddrsRef;
};

override 'getServiceConfigParameters' => sub {
	my ( $self, $service, $serviceType ) = @_;
	my %serviceParameters = ();

	my $users = $self->users;

	if ( $serviceType eq "appServer" ) {

		# For the app Servers, Auction needs to provide JVM options
		my $jvmOpts = "";

		# This variable is a holder for all spring profiles that are active
		my $springProfilesActive = $self->getSpringProfilesActive();
		$jvmOpts .= " -Dspring.profiles.active=$springProfilesActive ";

		# Determine the sizes for the various application caches
		# if the number of auctions wasn't explicitly set, determine based on
		# the usersPerAuctionScaleFactor
		my $auctions = $self->getParamValue('auctions');
		if ( !$auctions ) {
			$auctions = ceil( $users / $self->getParamValue('usersPerAuctionScaleFactor') );
		}
		my $numAppServers                  = $self->getNumActiveOfServiceType('appServer');
		my $numWebServers                  = $self->getNumActiveOfServiceType('webServer');
		my $authTokenCacheSize             = 2 * $users;
		my $activeAuctionCacheSize         = 2 * $auctions;
		my $itemsForAuctionCacheSize       = 2 * $auctions;
		my $itemCacheSize                  = 20 * $auctions;
		my $auctionRepresentationCacheSize = 2 * $auctions;
		my $imageInfoCacheSize             = 100 * $auctions;

		my $itemThumbnailImageCacheSize =
		  $self->getParamValue('appServerThumbnailImageCacheSizeMultiplier') * $auctions;
		my $itemPreviewImageCacheSize = $self->getParamValue('appServerPreviewImageCacheSizeMultiplier') * $auctions;
		my $itemFullImageCacheSize    = $self->getParamValue('appServerFullImageCacheSizeMultiplier') * $auctions;
		$jvmOpts .= " -DAUTHTOKENCACHESIZE=$authTokenCacheSize -DACTIVEAUCTIONCACHESIZE=$activeAuctionCacheSize ";
		$jvmOpts .= " -DAUCTIONREPRESENTATIONCACHESIZE=$auctionRepresentationCacheSize ";
		$jvmOpts .= " -DIMAGEINFOCACHESIZE=$imageInfoCacheSize -DITEMSFORAUCTIONCACHESIZE=$itemsForAuctionCacheSize ";
		$jvmOpts .= " -DITEMCACHESIZE=$itemCacheSize ";

		my $appServerCacheImpl = $self->getParamValue('appServerCacheImpl');
		if ( $appServerCacheImpl eq 'ignite' ) {

			$jvmOpts .= " -DAUTHTOKENCACHEMODE=" . $self->getParamValue('igniteAuthTokenCacheMode') . " ";
	
			my $copyOnRead = "false";
			if ( $self->getParamValue('igniteCopyOnRead') ) {
				$copyOnRead = "true";
			}
			$jvmOpts .= " -DIGNITECOPYONREAD=$copyOnRead ";

			my $appServersRef = $self->getActiveServicesByType('appServer');
			my $app1Hostname  = $appServersRef->[0]->getIpAddr();
			$jvmOpts .= " -DIGNITEAPP1HOSTNAME=$app1Hostname ";
		}
		my $zookeeperConnectionString = "zookeeper-0.zookeeper:2181,zookeeper-1.zookeeper:2181,zookeeper-2.zookeeper:2181";
		$jvmOpts .= " -DZOOKEEPERCONNECTIONSTRING=$zookeeperConnectionString ";

		if ( $numWebServers > 1 ) {

			# Don't need to cache images in app server if there is a web
			# server since the web server caches.
			$itemThumbnailImageCacheSize = $auctions;
			$itemPreviewImageCacheSize   = 1;
			$itemFullImageCacheSize      = 1;
		}
		else {
			if ( $itemPreviewImageCacheSize == 0 ) {
				$itemPreviewImageCacheSize = 1;
			}

			if ( $itemFullImageCacheSize == 0 ) {
				$itemFullImageCacheSize = 1;
			}
		}
		$jvmOpts .= " -DITEMTHUMBNAILIMAGECACHESIZE=$itemThumbnailImageCacheSize ";
		$jvmOpts .= " -DITEMPREVIEWIMAGECACHESIZE=$itemPreviewImageCacheSize ";
		$jvmOpts .= " -DITEMFULLIMAGECACHESIZE=$itemFullImageCacheSize ";

		if ( $service->getParamValue('randomizeImages') ) {
			$jvmOpts .= " -DRANDOMIZEIMAGES=true ";
		}
		else {
			$jvmOpts .= " -DRANDOMIZEIMAGES=false ";
		}

		my $numCpus;
		if ( $service->getParamValue('dockerCpus')) {
			$numCpus = $service->getParamValue('dockerCpus');
		}
		else {
			$numCpus = 2;
		}
		
		my $highBidQueueConcurrency = $service->getParamValue('highBidQueueConcurrency');
		if (!$highBidQueueConcurrency) {
			$highBidQueueConcurrency = $numCpus;
		}
		my $newBidQueueConcurrency = $service->getParamValue('newBidQueueConcurrency');
		if (!$newBidQueueConcurrency) {
			$newBidQueueConcurrency = $numCpus;
		}		
		$jvmOpts .= " -DHIGHBIDQUEUECONCURRENCY=$highBidQueueConcurrency ";
		$jvmOpts .= " -DNEWBIDQUEUECONCURRENCY=$newBidQueueConcurrency ";

		# Turn on imageWriters in the application
		if ( $service->getParamValue('useImageWriterThreads') ) {
			if ( $service->getParamValue('imageWriterThreads') ) {

				# value was set, overriding the default
				$jvmOpts .= " -DIMAGEWRITERTHREADS=" . $service->getParamValue('imageWriterThreads') . " ";
			}
			else {

				my $iwThreads = floor( $numCpus / 2.0 );
				if ( $iwThreads < 1 ) {
					$iwThreads = 1;
				}
				$jvmOpts .= " -DIMAGEWRITERTHREADS=" . $iwThreads . " ";

			}

			$jvmOpts .= " -DUSEIMAGEWRITERTHREADS=true ";
		}
		else {
			$jvmOpts .= " -DUSEIMAGEWRITERTHREADS=false ";
		}

		$jvmOpts .= " -DNUMCLIENTUPDATETHREADS=" . $service->getParamValue('numClientUpdateThreads') . " ";
		$jvmOpts .= " -DNUMAUCTIONEERTHREADS=" . $service->getParamValue('numAuctioneerThreads') . " ";

		$jvmOpts .= " -DRABBITMQ_HOST=rabbitmq -DRABBITMQ_PORT=5672 ";

		$jvmOpts .= " -DMONGODB_HOST=mongodb -DMONGODB_PORT=27017 ";

		$jvmOpts .= " -DDBHOSTNAME=postgresql -DDBPORT=5432 ";

		if ( !( $jvmOpts =~ /CompileThreshold/ ) ) {
			$jvmOpts .= " -XX:CompileThreshold=2000 ";
		}

		$serviceParameters{"jvmOpts"} = $jvmOpts;
	}

	return \%serviceParameters;
};

override 'redeploy' => sub {
	my ( $self, $logfile ) = @_;
	my $logger = get_logger("Weathervane::AppInstance::AuctionKubernetesAppInstance");
	$logger->debug(
		"redeploy for workload ", $self->getParamValue('workloadNum'),
		", appInstance ",         $self->getParamValue('appInstanceNum')
	);

	$self->imagePullPolicy("Always");
};

override 'startStatsCollection' => sub {
	my ( $self ) = @_;

};

override 'stopStatsCollection' => sub {
	my ( $self ) = @_;

};

override 'getStatsFiles' => sub {
	my ( $self ) = @_;

};

override 'cleanStatsFiles' => sub {
	my ( $self ) = @_;

};

__PACKAGE__->meta->make_immutable;

1;
