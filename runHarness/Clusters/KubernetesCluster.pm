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
package KubernetesCluster;

use Moose;
use MooseX::Storage;
use ComputeResources::Cluster;
use VirtualInfrastructures::VirtualInfrastructure;
use WeathervaneTypes;
use Log::Log4perl qw(get_logger);

use namespace::autoclean;

with Storage( 'format' => 'JSON', 'io' => 'File' );

extends 'Cluster';

override 'initialize' => sub {
	my ( $self, $paramHashRef ) = @_;
		
	super();
};

override 'registerService' => sub {
	my ( $self, $serviceRef ) = @_;
	my $console_logger = get_logger("Console");
	my $logger         = get_logger("Weathervane::Clusters::KubernetesCluster");
	my $servicesRef    = $self->servicesRef;

	my $dockerName = $serviceRef->getDockerName();
	$logger->debug( "Registering service $dockerName with cluster ",
		$self->clusterName );

	if ( $serviceRef->useDocker() ) {
			$console_logger->error( "Service $dockerName running on cluster ",
				$self->clusterName, " should not have useDocker set to true." );
			exit(-1);
	}

	push @$servicesRef, $serviceRef;

};

sub kubernetesSetContext {
	my ( $self ) = @_;
	my $logger         = get_logger("Weathervane::Clusters::KubernetesCluster");
#	my $contextName = $self->clusterName;
#	$logger->debug("kubernetesSetContext set context to $contextName");
#	my $cmd = "kubectl config use-context $contextName 2>&1";
#	my $outString = `$cmd`;
#	$logger->debug("Command: $cmd");
#	$logger->debug("Output: $outString");
}

sub kubernetesDeleteAll {
	my ( $self, $resourceType, $namespace ) = @_;
	my $logger         = get_logger("Weathervane::Clusters::KubernetesCluster");
	$logger->debug("kubernetesDelete deleteAll of type $resourceType in namespace $namespace");
	$self->kubernetesSetContext();
	my $cmd;
	my $outString;
	$cmd = "kubectl delete $resourceType --all --namespace=$namespace 2>&1";
	$outString = `$cmd`;
	$logger->debug("Command: $cmd");
	$logger->debug("Output: $outString");
	
}

sub kubernetesDeleteAllWithLabel {
	my ( $self, $selector, $namespace ) = @_;
	my $logger         = get_logger("Weathervane::Clusters::KubernetesCluster");
	$logger->debug("kubernetesDelete deleteAllWithLabel of type $resourceType in namespace $namespace");
	$self->kubernetesSetContext();
	my $cmd;
	my $outString;
	$cmd = "kubectl delete all --all --selector=$selector --namespace=$namespace 2>&1";
	$outString = `$cmd`;
	$logger->debug("Command: $cmd");
	$logger->debug("Output: $outString");
	
}

sub kubernetesDelete {
	my ( $self, $resourceType, $resourceName, $namespace ) = @_;
	my $logger         = get_logger("Weathervane::Clusters::KubernetesCluster");
	$logger->debug("kubernetesDelete delete $resourceName of type $resourceType in namespace $namespace");
	$self->kubernetesSetContext();
	my $cmd;
	my $outString;
	$cmd = "kubectl delete $resourceType $resourceName --namespace=$namespace 2>&1";
	$outString = `$cmd`;
	$logger->debug("Command: $cmd");
	$logger->debug("Output: $outString");
	
}

# Does a kubectl exec in the first pod where the impl label matches  
# serviceImplName.  It does the exec in the container with the same name.
sub kubernetesExecOne {
	my ( $self, $serviceTypeImpl, $commandString, $namespace ) = @_;
	my $logger         = get_logger("Weathervane::Clusters::KubernetesCluster");
	my $console_logger = get_logger("Console");
	$logger->debug("kubernetesExecOne exec $commandString for serviceTypeImpl $serviceTypeImpl, namespace $namespace");
	$self->kubernetesSetContext();

	# Get the list of pods
	my $cmd;
	my $outString;	
	$cmd = "kubectl get pod --selector=impl=$serviceTypeImpl --no-headers --namespace=$namespace 2>&1";
	$outString = `$cmd`;
	$logger->debug("Command: $cmd");
	$logger->debug("Output: $outString");
	my @lines = split /\n/, $outString;
	if ($#lines < 0) {
		$console_logger->error("kubernetesExecOne: There are no pods with label $serviceTypeImpl in namespace $namespace");
		exit(-1);
	}
	
	# Get the name of the first pod
	$lines[0] =~ /^\s*([a-zA-Z0-9\-]+)/;
	my $podName = $1;
	
	$cmd = "kubectl exec -c $serviceTypeImpl --namespace=$namespace $podName -- $commandString 2>&1";
	$outString = `$cmd`;
	$logger->debug("Command: $cmd");
	$logger->debug("Output: $outString");
	
	return $outString;
	
}

# Does a kubectl exec in all p[ods] where the impl label matches  
# serviceImplName.  It does the exec in the container with the same name.
sub kubernetesExecAll {
	my ( $self, $serviceTypeImpl, $commandString, $namespace ) = @_;
	my $logger         = get_logger("Weathervane::Clusters::KubernetesCluster");
	my $console_logger = get_logger("Console");
	$logger->debug("kubernetesExecAll exec $commandString for serviceTypeImpl $serviceTypeImpl, namespace $namespace");
	$self->kubernetesSetContext();

	# Get the list of pods
	my $cmd;
	my $outString;	
	$cmd = "kubectl get pod --selector=impl=$serviceTypeImpl --no-headers --namespace=$namespace 2>&1";
	$outString = `$cmd`;
	$logger->debug("Command: $cmd");
	$logger->debug("Output: $outString");
	my @lines = split /\n/, $outString;
	if ($#lines < 0) {
		$console_logger->error("kubernetesExecOne: There are no pods with label $serviceTypeImpl in namespace $namespace");
		exit(-1);
	}
	
	foreach my $line (@lines) { 
		$line =~ /^\s*([a-zA-Z0-9\-]+)/;
		my $podName = $1;
	
		$cmd = "kubectl exec -c $serviceTypeImpl --namespace=$namespace $podName -- $commandString 2>&1";
		$outString = `$cmd`;
		$logger->debug("Command: $cmd");
		$logger->debug("Output: $outString");
	}
}

sub kubernetesApply {
	my ( $self, $fileName, $namespace ) = @_;
	my $logger         = get_logger("Weathervane::Clusters::KubernetesCluster");
	$logger->debug("kubernetesApply apply file $fileName in namespace $namespace");
	$self->kubernetesSetContext();
	my $cmd;
	my $outString;
	$cmd = "kubectl apply -f $fileName --namespace=$namespace 2>&1";
	$outString = `$cmd`;
	$logger->debug("Command: $cmd");
	$logger->debug("Output: $outString");
}

sub kubernetesAreAllPodRunning {
	my ( $self, $podLabelString, $namespace ) = @_;
	my $logger         = get_logger("Weathervane::Clusters::KubernetesCluster");
	$logger->debug("kubernetesAreAllPodRunning podLabelString $podLabelString, namespace $namespace");
	$self->kubernetesSetContext();
	my $cmd;
	my $outString;
	$cmd = "kubectl get pod --selector=$podLabelString --no-headers --namespace=$namespace 2>&1";
	$outString = `$cmd`;
	$logger->debug("Command: $cmd");
	$logger->debug("Output: $outString");

	my @lines = split /\n/, $outString;
	if ($#lines < 0) {
		$logger->debug("kubernetesAreAllPodRunning: There are no pods with label $podLabelString in namespace $namespace");
		return 0;
	}
	
	foreach my $line (@lines) { 
		$line =~ /^\s*[a-zA-Z0-9\-]+\s+\d+\/\d+\s+([a-zA-Z]+)\s+/;
		my $status = $1;
		if ($status ne "Running") {
			$logger->debug("kubernetesAreAllPodRunning: Found a non-running pod: $line");
			return 0;
		}	
	}
	$logger->debug("kubernetesAreAllPodRunning: All pods are running");
	return 1;
}

__PACKAGE__->meta->make_immutable;

1;
