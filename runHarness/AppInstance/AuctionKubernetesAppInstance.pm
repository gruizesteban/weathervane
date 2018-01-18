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
		
}

override 'redeploy' => sub {
	my ( $self, $logfile ) = @_;
	my $logger = get_logger("Weathervane::AppInstance::AuctionAppInstance");
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
