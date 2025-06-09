FROM perl:5.40-slim-bookworm

RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		ca-certificates \
		wget \
	; \
	rm -rf /var/lib/apt/lists/*

# secure by default ♥ (thanks to sri!)
ENV PERL_CPANM_OPT --verbose --mirror https://cpan.metacpan.org
# TODO find a way to make --mirror-only / SSL work with backpan too :(
#RUN cpanm Digest::SHA Module::Signature
# TODO find a way to make --verify work with backpan as well :'(
#ENV PERL_CPANM_OPT $PERL_CPANM_OPT --verify

# reinstall cpanm itself, for good measure
RUN cpanm App::cpanminus

RUN set -eux; \
	savedAptMark="$(apt-mark showmanual)"; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		gcc \
		libc-dev \
		libssl-dev \
		zlib1g-dev \
	; \
	rm -rf /var/lib/apt/lists/*; \
	cpanm \
		EV \
		IO::Socket::IP \
		IO::Socket::Socks \
		Net::DNS::Native \
	; \
# the tests for IO::Socket::SSL like to hang... :(
	cpanm --notest IO::Socket::SSL; \
	apt-mark auto '.*' > /dev/null; \
	apt-mark manual $savedAptMark > /dev/null; \
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false

# https://metacpan.org/pod/release/SRI/Mojolicious-7.94/lib/Mojo/IOLoop.pm#DESCRIPTION
ENV LIBEV_FLAGS 4
# epoll (Linux)

# https://github.com/mojolicious/mojo/tags
# https://github.com/mojolicious/mojo/blob/main/Changes
RUN cpanm Mojolicious@9.40

EXPOSE 3000
COPY dockerhub-public-proxy.pl /usr/local/bin/
CMD ["dockerhub-public-proxy.pl", "daemon"]
