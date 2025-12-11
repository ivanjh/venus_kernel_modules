ARG VENUS_VERSION
ARG GITHUB_REPOSITORY

FROM ubuntu:22.04 AS sdk
ARG VENUS_VERSION
RUN apt-get update
RUN apt-get --no-install-recommends -y install make git ca-certificates sudo

RUN mkdir /repos
RUN chmod o=+r+w+x /repos
WORKDIR /repos

RUN useradd -ms /bin/bash builduser
RUN adduser builduser sudo
RUN echo '%sudo ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
USER builduser

# Avoid detach of HEAD messages during fetch
RUN git config --global advice.detachedHead "false"

# ssh requires key for public read, so switch github to https
RUN git config --global url.https://github.com/.insteadOf git@github.com:

RUN git clone --depth=1 https://github.com/victronenergy/venus.git -b ${VENUS_VERSION}
WORKDIR /repos/venus

# Update repos to checkout from matching tag in source repos
RUN for conf in $(find configs -name repos.conf); do awk -v branch=${VENUS_VERSION} '{$5=branch}1' ${conf} > ${conf}.patched && mv ${conf} ${conf}.org && mv ${conf}.patched ${conf} ; done

ENV MACHINE=einstein
ENV SHELL=bash
# Use default from Makefile # dunfell/scarthgap (yocto release codename)
# ENV CONFIG=dunfell 
ENV MACHINES="einstein cerbosgx nanopi ekrano raspberrypi2 raspberrypi4 beaglebone ccgx canvu500"
ENV MACHINES_LARGE="einstein cerbosgx nanopi ekrano raspberrypi2 raspberrypi4 beaglebone"

RUN echo "APT::Get::Assume-Yes \"true\";\nAPT::Get::allow \"true\";" | sudo tee -a /etc/apt/apt.conf.d/90_no_prompt > /dev/null
# Include DEBIAN_FRONTEND=noninteractive for apt-get
RUN sed -i -e 's/@sudo /@sudo DEBIAN_FRONTEND=noninteractive /g' Makefile
RUN make prereq

## Patch git-fetch-remote.sh
# Exit on error
RUN sed -i '2i set -e' git-fetch-remote.sh

# Skip set upstream branch (we're fetching from tags)
RUN sed -i -e '/branch -u "origin/d' git-fetch-remote.sh

# Sparse checkout single branch
RUN sed -i -e 's/ --no-checkout/ --no-checkout --depth=1 --single-branch --branch "$5"/' git-fetch-remote.sh
## End  Patch git-fetch-remote.sh

# Fetch repos
RUN make fetch

# Image build checks for it
RUN sudo DEBIAN_FRONTEND=noninteractive apt-get --no-install-recommends -y install cpio

# Avoid "don't use bitbake as root" error
RUN touch build/conf/sanity.conf
RUN make build/conf/bblayers.conf

# bitbake default requires en_US.UTF-8
RUN sudo DEBIAN_FRONTEND=noninteractive apt-get --no-install-recommends -y install language-pack-en

# Enable not already static kernel options as modules
RUN >>"$(find sources/meta-victronenergy/meta-bsp/recipes-kernel/linux -name 'linux-venus*.bb')" echo 'do_configure:append() { \n\
    # Backup config, create all mod config, restore config \n\
    cp .config .config.premod \n\
    oe_runmake allmodconfig \n\
    cp .config .config.postallmod \n\
    cp .config.premod .config \n\
\n\
    # Find all module settings, and skip any already statically included \n\
    grep -v "#" .config.postallmod | grep "=m$" | cut -d "=" -f1 | sort > .desiredModules \n\
    grep -v "#" .config.premod | grep "=y$" | cut -d "=" -f1 | sort > .existingStatic \n\
    comm -23 .desiredModules .existingStatic | sed s/\$/=m/g > .config.nonstaticmod \n\
\n\
    # Append mod enablement at the end, skipping modules with build issues \n\
    <.config.nonstaticmod grep -vE "(CONFIG_SERIAL_8250|CONFIG_UBIFS_FS|CONFIG_EXT2_FS|CONFIG_RPMB)" >> .config \n\
}'

# bitbake requires lz4c pzstd unzstd zstd
RUN sudo DEBIAN_FRONTEND=noninteractive apt-get --no-install-recommends -y install lz4 zstd

# Avoid git "detected dubious ownership in repository" for /repos/venus/build/tmp-glibc/work/x86_64-linux/binutils-cross-arm/2.42/git
RUN git config --global --add safe.directory '*'

RUN /bin/bash -c '. ./sources/openembedded-core/oe-init-build-env build sources/bitbake && bitbake linux-venus'

# Publish
RUN git config --global user.email "build@local"
RUN git config --global user.name "build"

ARG GITHUB_REPOSITORY

RUN --mount=type=secret,id=github_token,env=GITHUB_TOKEN cd /repos/venus/build/tmp-glibc/work/einstein-ve-linux-gnueabi/linux-venus/*-venus-*/deploy-ipks/einstein/ && \
    git init . && \
    git remote add origin https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY} && \
    git add -A && git commit -m "Publish" && \
    git push origin HEAD:${VENUS_VERSION}
