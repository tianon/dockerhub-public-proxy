#!/usr/bin/env perl
use Mojo::Base -strict, -signatures;

use Mojo::UserAgent;

# optional configuration for Docker Hub credentials to help with rate limiting
# WARNING: this will allow unauthenticated access for anyone who can hit the proxy to anything this user has access to, so please use it with care!!
# https://docs.docker.com/docker-hub/download-rate-limit/
# https://github.com/docker/hub-feedback/issues/1907
my @creds = split(/\n/, Mojo::Util::trim($ENV{DOCKERHUB_PUBLIC_PROXY_CREDENTIALS} // ''));

# max_response_size justification: https://github.com/opencontainers/distribution-spec/pull/293#issuecomment-1452780554 (allowing slightly more than registries should, just to be safe)
my $ua = Mojo::UserAgent->new->max_redirects(0)->connect_timeout(20)->inactivity_timeout(20)->max_response_size(5 * 1024 * 1024);
$ua->transactor->name($ENV{DOCKERHUB_PUBLIC_PROXY_USER_AGENT} // 'https://github.com/tianon/dockerhub-public-proxy');

sub _cred {
	state $i = 0;
	return undef unless @creds;
	my $cred = $creds[$i];
	$i = ($i + 1) % @creds;
	return $cred;
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

	my $methodP = lc $method . '_p';
	return $ua->$methodP($url, \%headers)->then(sub {
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
			if (my $cred = _cred) {
				# see description of DOCKERHUB_PUBLIC_PROXY_CREDENTIALS above
				$authUrl->userinfo($cred);
			}
			return $ua->get_p($authUrl->to_unsafe_string)->then(sub {
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

	# we allow exactly two tries for a given request to account for at most one auth round-trip + one retry
	return _registry_req_p(2, $method, $repo, $url, %extHeaders);
}

use Mojolicious::Lite;

any [ 'GET', 'HEAD' ] => '/v2/#org/#repo/*url' => sub ($c) {
	$c->render_later;

	my $repo = $c->param('org') . '/' . $c->param('repo');
	my $url = $c->param('url');

	# ignore request headers (they can cause issues with returning the wrong "Location:" redirects thanks to X-Forwarded-*, for example)
	my %headers = (
		# upgrade useless Accept: header so "curl" is useful OOTB instead of returning a v1 manifest
		# ... and clients that don't accept manifest lists so they don't screw up clients that do (we don't support clients that don't support manifest lists)
		Accept => [
			'application/vnd.docker.distribution.manifest.list.v2+json',
			'application/vnd.docker.distribution.manifest.v2+json',
			'application/vnd.oci.image.index.v1+json',
			'application/vnd.oci.image.manifest.v1+json',
			'application/vnd.oci.image.config.v1+json',
			'*/*',
		],
	);

	my $cacheable = $url =~ m!/sha256:!;
	my $tagRequest = !$cacheable && $url =~ m!^manifests/!;

	return registry_req_p(($tagRequest ? 'HEAD' : $c->req->method), $repo, $url, %headers)->then(sub {
		my $tx = shift;

		$c->res->headers->from_hash({})->from_hash($tx->res->headers->to_hash(1));

		# TODO check for $digest sooner and set $cacheable based on whether the request URL contains the digest returned?

		my $maxAge = 0;
		if ($cacheable) {
			# looks like a content-addressable digest -- literally by definition, that content can't change, so let's tell the client that via cache-control (if the response is something resembling success, anyhow)
			if ($tx->res->code == 200 || $tx->res->code == 301 || $tx->res->code == 308) {
				# 200 = success, 301 = Moved Permanently, 308 = Permanent Redirect
				$maxAge = 365 * 24 * 60 * 60;
				# https://stackoverflow.com/a/25201898/433558
			}
			elsif ($tx->res->code >= 300 && $tx->res->code < 400) {
				# other redirects are likely somewhat less cacheable (temporary), so let's dial it back
				$maxAge = 30 * 60;
			}
		}

		if ($maxAge) {
			$c->res->headers->cache_control('public, max-age=' . $maxAge);
		}
		else {
			# don't cache non-digests
			$c->res->headers->cache_control('no-cache');
		}

		my $digest = $tx->res->headers->header('docker-content-digest');
		if (
			$tx->res->code == 200
			&& !$c->res->headers->content_length
			&& $digest
			&& $digest ne 'sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' # this is the sha256 of the empty string (zero bytes)
		) {
			$c->res->headers->content_length(0); # just in case (because we're adding our own body below)
			return $c->render(status => 500, data => "response (unexpectedly) missing content-length (digest $digest)");
		}

		# it doesn't make any sense to redirect HEAD requests -- they're not very cacheable anyhow, so all that does is double the number of requests-per-request
		if ($tagRequest && $c->req->method ne 'HEAD') {
			# if we converted the request to HEAD, we need to axe the Content-Length header value because we don't have the content that goes with it :D
			$c->res->headers->content_length(0);
			# (and if we're not about to redirect, we're going to error in some way, either our own error or passing along upstream's error, like 404)

			if ($digest) {
				return $c->redirect_to("/v2/$repo/manifests/$digest");
			}
			elsif ($tx->res->code == 200) {
				return $c->render(status => 500, data => 'we converted the request to a HEAD, but we need to generate a redirect and did not get a Docker-Content-Digest header to tell us where to redirect to');
			}
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
get '/v2/' => sub ($c) {
	# this is often used as a "ping" endpoint
	$c->render(json => {});
};
get '/' => sub ($c) {
	return $c->redirect_to('https://github.com/tianon/dockerhub-public-proxy');
};

app->start;
