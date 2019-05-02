#!/usr/bin/env perl
use strict;
use warnings;
use 5.010;
use open ':encoding(utf8)';

use Mojo::UserAgent;

my $ua = Mojo::UserAgent->new->max_redirects(0)->connect_timeout(20)->inactivity_timeout(20)->max_response_size(1024 * 1024);
$ua->transactor->name(join ' ',
	# https://github.com/docker/docker/blob/v1.11.2/dockerversion/useragent.go#L13-L34
	'docker/1.11.2',
	'go/1.6.2',
	'git-commit/v1.11.2',
	'kernel/4.4.11',
	'os/linux',
	'arch/amd64',
	# BOGUS USER AGENTS FOR THE BOGUS USER AGENT THRONE
);

# the number of times to allow a single request to be attempted before considering it a lost cause
my $uaTries = 2;

sub _ua_retry_req_p {
	my $tries = shift;
	my $method = lc(shift);
	my @methodArgs = @_;

	--$tries;
	my $lastTry = $tries < 1;

	return $ua->$method(@methodArgs)->then(sub {
		my $tx = shift;
		if (
			$lastTry
			|| !$tx->error
			|| (
				# if "$tx->res->code" is undefined, that usually is indicative of some kind of timeout (connect/inactivity)
				$tx->res->code
				&& (
					# failure codes we consider to be a "successful" request
					$tx->res->code == 401 # "Unauthorized"
					|| $tx->res->code == 404 # "Not Found"
				)
			)
		) {
			return $tx;
		}
		say {*STDERR} 'UA error response: ' . $tx->error->{message};
		return _ua_retry_req_p($tries, $method, @methodArgs);
	}, sub {
		die @_ if $lastTry;
		say {*STDERR} 'UA error: ' . join ', ', @_;
		return _ua_retry_req_p($tries, $method, @methodArgs);
	});
}
sub ua_retry_req_p {
	my $method = shift . '_p';
	return _ua_retry_req_p($uaTries, $method, @_);
}

sub _registry_req_p {
	my $tries = shift;
	my $method = shift;
	my $repo = shift;
	my $url = shift;
	my %extHeaders = @_;

	--$tries;
	my $lastTry = $tries < 1;

	my %headers = (
		%extHeaders,
	);

	state %tokens;
	if (my $token = $tokens{$repo}) {
		$headers{Authorization} = "Bearer $token";
	}

	return ua_retry_req_p($method => $url => \%headers)->then(sub {
		my $tx = shift;
		if (!$lastTry && $tx->res->code == 401) {
			# "Unauthorized" -- we must need to go fetch a token for this registry request (so let's go do that, then retry the original registry request)
			my $auth = $tx->res->headers->www_authenticate;
			die "unexpected WWW-Authenticate header: $auth" unless $auth =~ m{ ^ Bearer \s+ (\S.*) $ }x;
			my $realm = $1;
			my $authUrl = Mojo::URL->new;
			while ($realm =~ m{
				# key="val",
				([^=]+)
				=
				"([^"]+)"
				,?
			}xg) {
				my ($key, $val) = ($1, $2);
				next if $key eq 'error';
				if ($key eq 'realm') {
					$authUrl->base(Mojo::URL->new($val));
				} else {
					$authUrl->query->append($key => $val);
				}
			}
			$authUrl = $authUrl->to_abs;
			return ua_retry_req_p(get => $authUrl)->then(sub {
				my $tokenTx = shift;
				if (my $error = $tokenTx->error) {
					die "failed to fetch token for $repo: " . ($error->{code} ? $error->{code} . ' -- ' : '') . $error->{message};
				}
				$tokens{$repo} = $tokenTx->res->json->{token};
				return _registry_req_p($tries, $method, $repo, $url, %extHeaders);
			});
		}

		return $tx;
	});
}
sub registry_req_p {
	my $method = shift;
	my $repo = shift;
	my $url = shift;
	my %extHeaders = @_;

	$url = "https://registry-1.docker.io/v2/$repo/$url";

	return _registry_req_p($uaTries, $method, $repo, $url, %extHeaders);
}

use Mojolicious::Lite;

get '/v2/:org/:repo/*url' => sub {
	my $c = shift;

	$c->render_later;

	my $repo = $c->param('org') . '/' . $c->param('repo');
	my $url = $c->param('url');

	my %headers = %{ $c->req->headers->to_hash(1) };
	# delete problematic headers like "Host:" and "Authorization:" (this is for public images only and we don't want to accidentally cache credentials)
	delete @headers{qw(
		Authorization
		Host
	)};
	if (
		'ARRAY' eq ref($headers{Accept})
		&& @{$headers{Accept}} == 1
		&& (
			# upgrade useless Accept: header so "curl" ise useful OOTB instead of returning a v1 manifest
			$headers{Accept}[0] eq '*/*'
			# ... and clients that don't accept manifest lists so they don't screw up clients that do (we don't support clients that don't support manifest lists)
			|| $headers{Accept}[0] eq 'application/vnd.docker.distribution.manifest.v2+json'
		)
	) {
		$headers{Accept} = [
			'application/vnd.docker.distribution.manifest.list.v2+json',
			'application/vnd.docker.distribution.manifest.v2+json',
		];
	}
	return registry_req_p($c->req->method, $repo, $url, %headers)->then(sub {
		my $tx = shift;
		$c->res->headers->from_hash({})->from_hash($tx->res->headers->to_hash(1));
		if ($tx->res->code == 200 && $url =~ m!sha256:!) {
			# looks like a content-addressable digest -- literally by definition, that content can't change, so let's tell the client that via cache-control
			$c->res->headers->cache_control('public, max-age=' . (365 * 24 * 60 * 60))->vary('Accept, User-Agent');
			# https://stackoverflow.com/a/25201898/433558
		}
		else {
			# don't cache non-digests
			$c->res->headers->cache_control('no-cache');
		}
		$c->render(data => $tx->res->body, status => $tx->res->code);
	}, sub {
		$c->reply->exception(@_);
	});
};
#any '/v2/*url' => { url => '' } => sub {
#	my $c = shift;
#	return $c->redirect_to('https://registry-1.docker.io/v2/' . $c->param('url'));
#};
get '/' => sub {
	return shift->redirect_to('https://github.com/tianon/dockerhub-public-proxy');
};

app->start;
