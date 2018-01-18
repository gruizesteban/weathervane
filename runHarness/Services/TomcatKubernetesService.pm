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
package TomcatKubernetesService;

use Moose;
use MooseX::Storage;

use POSIX;
use Services::KubernetesService;
use Parameters qw(getParamValue);
use StatsParsers::ParseGC qw( parseGCLog );
use Log::Log4perl qw(get_logger);

use namespace::autoclean;

with Storage( 'format' => 'JSON', 'io' => 'File' );

extends 'KubernetesService';

has '+name' => ( default => 'Tomcat', );

has '+version' => ( default => '8', );

has '+description' => ( default => 'The Apache Tomcat Servlet Container', );

has 'mongosDocker' => (
	is      => 'rw',
	isa     => 'Str',
	default => "",
);

override 'initialize' => sub {
	my ($self) = @_;

	super();
};

sub configure {
	my ( $self, $dblog, $serviceType, $users, $numShards, $numReplicas ) = @_;
	my $logger = get_logger("Weathervane::Services::TomcatKubernetesService");
	$logger->debug("Configure Tomcat kubernetes");
	print $dblog "Configure Tomcat Kubernetes\n";

	my $namespace = $self->namespace;	
	my $configDir        = $self->getParamValue('configDir');

	my $serviceParamsHashRef =
	  $self->appInstance->getServiceConfigParameters( $self, $self->getParamValue('serviceType') );

	my $numCpus            = 2;
	if ($self->getParamValue('dockerCpus')) {
		$numCpus = $self->getParamValue('dockerCpus');
	}
	my $threads            = $self->getParamValue('appServerThreads') * $numCpus;
	my $connections        = $self->getParamValue('appServerJdbcConnections') * $numCpus;
	my $tomcatCatalinaBase = $self->getParamValue('tomcatCatalinaBase');
	my $maxIdle = ceil($self->getParamValue('appServerJdbcConnections') / 2);
	my $nodeNum = $self->getParamValue('instanceNum');
	my $maxConnections =
	  ceil( $self->getParamValue('frontendConnectionMultiplier') *
		  $users /
		  ( $self->appInstance->getNumActiveOfServiceType('appServer') * 1.0 ) );
	if ( $maxConnections < 100 ) {
		$maxConnections = 100;
	}

	my $completeJVMOpts .= $self->getParamValue('appServerJvmOpts');
	$completeJVMOpts .= " " . $serviceParamsHashRef->{"jvmOpts"};
	if ( $self->getParamValue('appServerEnableJprofiler') ) {
		$completeJVMOpts .=
		  " -agentpath:/opt/jprofiler8/bin/linux-x64/libjprofilerti.so=port=8849,nowait -XX:MaxPermSize=400m";
	}

	if ( $self->getParamValue('logLevel') >= 3 ) {
		$completeJVMOpts .= " -XX:+PrintGCDetails -XX:+PrintGCTimeStamps -Xloggc:$tomcatCatalinaBase/logs/gc.log ";
	}
	$completeJVMOpts .= " -DnodeNumber=$nodeNum ";
	

	open( FILEIN,  "$configDir/kubernetes/tomcat.yaml" ) or die "$configDir/kubernetes/tomcat.yaml: $!\n";
	open( FILEOUT, ">/tmp/tomcat-$namespace.yaml" )             or die "Can't open file /tmp/tomcat-$namespace.yaml: $!\n";
	
	while ( my $inline = <FILEIN> ) {

		if ( $inline =~ /TOMCAT_JVMOPTS/ ) {
			print FILEOUT "  TOMCAT_JVMOPTS: \"$completeJVMOpts\"\n";
		}
		elsif ( $inline =~ /TOMCAT_THREADS/ ) {
			print FILEOUT "  TOMCAT_THREADS: $threads\n";
		}
		elsif ( $inline =~ /TOMCAT_JDBC_CONNECTIONS/ ) {
			print FILEOUT "  TOMCAT_JDBC_CONNECTIONS: $connections\n";
		}
		elsif ( $inline =~ /TOMCAT_JDBC_MAXIDLE/ ) {
			print FILEOUT "  TOMCAT_JDBC_MAXIDLE: $maxIdle\n";
		}
		elsif ( $inline =~ /TOMCAT_CONNECTIONS/ ) {
			print FILEOUT "  TOMCAT_CONNECTIONS: $maxConnections\n";
		}
		else {
			print FILEOUT $inline;
		}

	}
	
	close FILEIN;
	close FILEOUT;

}

sub isUp {
	my ( $self, $applog ) = @_;
	my $hostname = $self->getIpAddr();
	my $port     = $self->portMap->{"http"};

	my $response = `curl -s http://$hostname:$port/auction/healthCheck`;
	print $applog "curl -s http://$hostname:$port/auction/healthCheck\n";
	print $applog "$response\n";

	if ( $response =~ /alive/ ) {
		return 1;
	}
	else {
		return 0;
	}
}

sub isRunning {
	my ( $self, $fileout ) = @_;
	my $name = $self->getParamValue('dockerName');

	return $self->host->dockerIsRunning( $fileout, $name );

}

sub getLogFiles {
	my ( $self, $destinationPath ) = @_;
	my $logger = get_logger("Weathervane::Services::TomcatDockerService");
	$logger->debug("getLogFiles");

	my $tomcatCatalinaBase = $self->getParamValue('tomcatCatalinaBase');
	my $name               = $self->getParamValue('dockerName');
	my $hostname           = $self->host->hostName;

	my $logpath = "$destinationPath/$name";
	if ( !( -e $logpath ) ) {
		`mkdir -p $logpath`;
	}

	my $logName = "$logpath/TomcatDockerLogs-$hostname-$name.log";

	my $applog;
	open( $applog, ">$logName" )
	  || die "Error opening /$logName:$!";

	print $applog $self->host->dockerGetLogs( $applog, $name );

	close $applog;

}

sub cleanLogFiles {
	my ( $self, $destinationPath ) = @_;
	my $logger = get_logger("Weathervane::Services::TomcatDockerService");
	$logger->debug("cleanLogFiles");
}

sub parseLogFiles {
	my ($self) = @_;

}

sub getConfigFiles {
	my ( $self, $destinationPath ) = @_;
	my $tomcatCatalinaBase = $self->getParamValue('tomcatCatalinaBase');
	my $name               = $self->getParamValue('dockerName');
	my $hostname           = $self->host->hostName;

	my $logpath = "$destinationPath/$name";
	if ( !( -e $logpath ) ) {
		`mkdir -p $logpath`;
	}

	my $logName = "$logpath/GetConfigFilesTomcatDocker-$hostname-$name.log";

	my $applog;
	open( $applog, ">$logName" )
	  || die "Error opening /$logName:$!";

	$self->host->dockerScpFileFrom( $applog, $name, "$tomcatCatalinaBase/conf/*",        "$logpath/." );
	$self->host->dockerScpFileFrom( $applog, $name, "$tomcatCatalinaBase/bin/setenv.sh", "$logpath/." );
	close $applog;

}

sub getConfigSummary {
	my ($self) = @_;
	tie( my %csv, 'Tie::IxHash' );
	$csv{"tomcatThreads"}     = $self->getParamValue('appServerThreads');
	$csv{"tomcatConnections"} = $self->getParamValue('appServerJdbcConnections');
	$csv{"tomcatJvmOpts"}     = $self->getParamValue('appServerJvmOpts');
	return \%csv;
}

sub getStatsSummary {
	my ( $self, $statsLogPath, $users ) = @_;
	tie( my %csv, 'Tie::IxHash' );

	my $weathervaneHome = $self->getParamValue('weathervaneHome');
	my $gcviewerDir     = $self->getParamValue('gcviewerDir');
	if ( !( $gcviewerDir =~ /^\// ) ) {
		$gcviewerDir = $weathervaneHome . "/" . $gcviewerDir;
	}

	# Only parseGc if gcviewer is present
	if ( -f "$gcviewerDir/gcviewer-1.34-SNAPSHOT.jar" ) {

		open( HOSTCSVFILE, ">>$statsLogPath/tomcat_gc_summary.csv" )
		  or die "Can't open $statsLogPath/tomcat_gc_summary.csv : $! \n";
		my $addedHeaders = 0;

		tie( my %accumulatedCsv, 'Tie::IxHash' );
		my $serviceType = $self->getParamValue('serviceType');
		my $servicesRef = $self->appInstance->getActiveServicesByType($serviceType);
		my $numServices = $#{$servicesRef} + 1;
		my $csvHashRef;
		foreach my $service (@$servicesRef) {
			my $name    = $service->getParamValue('dockerName');
			my $logPath = $statsLogPath . "/" . $service->host->hostName . "/$name";
			$csvHashRef = ParseGC::parseGCLog( $logPath, "", $gcviewerDir );

			if ( !$addedHeaders ) {
				print HOSTCSVFILE "Hostname,IP Addr";
				foreach my $key ( keys %$csvHashRef ) {
					print HOSTCSVFILE ",$key";
				}
				print HOSTCSVFILE "\n";

				$addedHeaders = 1;
			}

			print HOSTCSVFILE $service->host->hostName . "," . $service->host->ipAddr;
			foreach my $key ( keys %$csvHashRef ) {
				print HOSTCSVFILE "," . $csvHashRef->{$key};
				if ( $csvHashRef->{$key} eq "na" ) {
					next;
				}
				if ( !( exists $accumulatedCsv{"tomcat_$key"} ) ) {
					$accumulatedCsv{"tomcat_$key"} = $csvHashRef->{$key};
				}
				else {
					$accumulatedCsv{"tomcat_$key"} += $csvHashRef->{$key};
				}
			}
			print HOSTCSVFILE "\n";

		}

		# Now turn the total into averages
		foreach my $key ( keys %$csvHashRef ) {
			if ( exists $accumulatedCsv{"tomcat_$key"} ) {
				$accumulatedCsv{"tomcat_$key"} /= $numServices;
			}
		}

		# Now add the key/value pairs to the returned csv
		@csv{ keys %accumulatedCsv } = values %accumulatedCsv;

		close HOSTCSVFILE;
	}
	return \%csv;
}

__PACKAGE__->meta->make_immutable;

1;
