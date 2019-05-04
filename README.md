# Docker Hub "Public" Proxy

A simple no-auth-round-trip-necessary proxy for public Docker Hub resources (especially image repository manifests and blobs).

The goal is to be able to put this behind something that will cache aggressively (like Cloudflare, for example).

If the URL we're proxying includes `sha256:`, it's likely a content-addressable digest (either pulling a manifest by digest or pulling a content blob), and the `sha256:xxx` portion is explicitly a hash of the requested content and thus is explicitly infinitely cacheable by definition (literally cannot change or else the digest would have to change too).

We also do a small amount of `Accept:` header munging such that `curl` is usable out-of-the-box without explicitly setting the `Accept:` header (we only support clients that accept manifest lists -- if your client doesn't, YMMV while using this and don't be surprised if things break).  This is also important because Cloudflare (and likely others) don't support `Vary:` headers for varying cache (first come, first served, only cached).

We set a strict limit on the size of request we're willing to proxy because we don't want to be proxying the actual blob data and Docker Hub does a redirect for those anyhow (which can't pass along an `Authorization:` header, so we're safe there from a no-auth-token perspective too).
