# Redemption canister, hermetic reproducible builder.
#
# WHAT IS PINNED, AND WHY
# -----------------------
# moc's code generation and its `motoko:stable-types` section are both version-sensitive,
# so the toolchain is pinned. dfx is a build input beyond moc: it generates the
# management-canister Candid that Motoko sources import, and that file has changed shape
# between releases.
#
# The DIRECTORY is not pinned by necessity here, and that is a measured claim rather than
# an assumption. moc derives the numeric disambiguator in `Entry__449410820` from the path
# of the file DEFINING the stable type, as moc is given it. Every stable type in this
# canister is defined in `src/Types.mo`; none comes from a package. With a relative entry
# source the module is byte-identical from three different directories, and absolute vs
# relative `--package` paths make no difference at all. Passing the source ABSOLUTELY does
# change it. See docker/build.sh for the three measurements.
#
# That is narrower than the widely-held rule ("absolute paths are baked in, pin the mount
# point"), which is correct for canisters whose stable types come from dependencies. It
# stops applying the moment every stable type is local and referenced relatively, which is
# the case here. WORKDIR is
# still set, so the door stays shut if a stable type is ever imported from a package.
#
# BUILD THE IMAGE
#   docker build -t redemption-builder -f docker/Dockerfile .
#
# REPRODUCE THE MODULE
#   docker run --rm -v "$PWD":/menese-redemption -w /menese-redemption \
#     redemption-builder ./docker/build.sh
#
FROM debian:bookworm-20250630-slim

ARG DFX_VERSION=0.32.0
ARG MOPS_VERSION=1.6.0
ARG NODE_MAJOR=20

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/root \
    PATH=/root/.local/share/dfx/bin:/root/.local/bin:$PATH \
    DFX_WARNING=-mainnet_plaintext_identity \
    SOURCE_DATE_EPOCH=0

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git python3 xz-utils \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/*

RUN DFXVM_INIT_YES=true sh -ci "$(curl -fsSL https://internetcomputer.org/install.sh)" \
 && dfxvm install "${DFX_VERSION}" \
 && dfxvm default  "${DFX_VERSION}"

RUN npm install -g "ic-mops@${MOPS_VERSION}"

# The canonical build path. It is baked into the module hash and must not be changed.
WORKDIR /menese-redemption
