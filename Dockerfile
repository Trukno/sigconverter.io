# Copy uv binary from the correct platform
FROM --platform=linux/amd64 ghcr.io/astral-sh/uv:latest AS uv-binary

FROM --platform=linux/amd64 python:3.11.4-slim-bookworm

# install dependencies
RUN apt-get update
RUN apt-get install -y git curl jq
COPY --from=uv-binary /uv /bin/uv

# define work directory
WORKDIR /app/
COPY . /app

# install backend
RUN cd backend && ./setup-sigma-versions.sh

# Drop the C development headers now that the venvs are built.
#
# This is a CVE-reporting fix, not just hygiene. linux-libc-dev ships 985
# kernel header files under /usr/include, and trivy matches that package
# against essentially every Linux kernel CVE ever published: 8,872 of this
# image's 9,135 findings -- 97% -- came from that one package. The resulting
# VulnerabilityReport was 59.3 MB uncompressed against Kubernetes' 3 MiB object
# limit, so the operator could never store it and the image had NO vulnerability
# report at all. It was invisible to CVE reporting rather than visibly failing.
#
# Those CVEs are also inapplicable: a container uses the host kernel, so kernel
# headers in the image describe nothing it runs.
#
# libc6-dev comes from the python:*-slim base (not from the apt-get above) and
# is what pulls linux-libc-dev in. Purging it removes exactly seven packages,
# all -dev/header: libc6-dev, libc-dev-bin, libcrypt-dev, libnsl-dev,
# libtirpc-dev, linux-libc-dev, rpcsvc-proto. Verified by simulating the purge
# inside the running pod first -- nothing at runtime needs them, since the venvs
# are already compiled by this point. Must stay AFTER setup-sigma-versions.sh,
# which does need a compiler for native wheels.
RUN apt-get purge -y --auto-remove libc6-dev linux-libc-dev \
 && rm -rf /var/lib/apt/lists/*

# launch front- and backend
EXPOSE 8000
ENTRYPOINT ["./entrypoint.sh"]
