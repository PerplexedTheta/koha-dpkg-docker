#!/usr/bin/env bash

## vars
SCRIPT_PATH="$(realpath "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)" # get current script dir portibly

if [[ ${SUDO_USER} ]]; then
	REAL_USER="${SUDO_USER}" # or use sudo user
else
	REAL_USER="$(id -un)" # fallback to root
fi
REAL_GROUP="$(id -gn ${REAL_USER})" # fallback to real_user group

if [[ ! -f "${SCRIPT_DIR}/.env" ]]; then
	echo -ne "E: No env file present! Please create one. See the wiki for details\n"
	exit 1
fi
. ${SCRIPT_DIR}/.env
printenv

KERNEL="$(uname -s)"
if [[ "${KERNEL}" != "Linux" ]]; then
	echo "E: Unsupported system kernel: ${KERNEL}"
	exit 1
fi

ARCH="$(arch)"
PLATFORM="linux/${ARCH}"
if [[ "${ARCH}" == "x86_64" ]]; then
	export ARCH="amd64"
	export PLATFORM="linux/amd64"
elif [[ "${ARCH}" == "aarch64" ]]; then
	export ARCH="arm64v8"
	export PLATFORM="linux/arm64/v8"
else
	echo "E: Unsupported CPU architecture: ${ARCH}"
	exit 1
fi

if [[ "$(docker system info | grep 'io.containerd.snapshotter.v1')" == "" ]]; then
	echo "E: Docker must be set to use containerd-snapshotter. Please see https://docs.docker.com/engine/storage/containerd/#enable-containerd-image-store-on-docker-engine"
	exit 1
fi


##
##
## bienvenido
echo -ne "I: Welcome!\n"
echo -ne "I: This script will generate a base.tgz using pbuilder, and from there generate a docker image from the Dockerfile.\n"
echo -ne "I: Please ensure docker and pbuilder are properly installed, and your .env is correctly configured, before continuing.\n"


##
##
## check keyring is present
if [[ ! -f "${KEYRING}" ]]; then
	echo -ne "E: ${KEYRING} is missing. Please install it!\n"
	exit 1
fi


##
##
## prep env
echo -ne "I: Creating temp directory\n"
mkdir -vp /tmp/koha-dpkg-docker
cd /tmp/koha-dpkg-docker && pwd


##
##
## start pbuilder stuff -- create base
echo -ne "I: Cleaning pbuilder\n"
pbuilder clean
rm -vf /var/cache/pbuilder/base.tgz.tmp
rm -vf /var/cache/pbuilder/base.tgz
echo -ne "I: Creating blank image\n"
pbuilder create --distribution "${DISTRIBUTION}" --mirror "${MIRROR}/" --debootstrapopts "--components=main" --debootstrapopts "--keyring=${KEYRING}"

## seed and execute additional deps
echo -ne "I: Seeing apt control script\n"
cat <<EOF | tee /tmp/koha-dpkg-docker/apt_control.sh
#!/usr/bin/env bash
  echo "I: Running $0"
  echo "" > /etc/apt/sources.list ; \
  rm -fv /etc/apt/sources.list.d/* ; \
  echo "deb ${MIRROR} ${DISTRIBUTION} main contrib non-free non-free-firmware" > /etc/apt/sources.list.d/${FAMILY}.list ; \
  echo "deb ${MIRROR} ${DISTRIBUTION}-updates main contrib non-free non-free-firmware" >> /etc/apt/sources.list.d/${FAMILY}.list ; \
  echo "deb ${MIRROR_SEC} ${DISTRIBUTION_SEC} main contrib non-free non-free-firmware" >> /etc/apt/sources.list.d/${FAMILY_SEC}.list ; \
  apt clean ; apt update ; apt upgrade -y ; apt full-upgrade -y \ ;
  apt install apt-file -y ; \
  apt clean ; apt update ; \
  apt-file update
EOF
chmod -v 0755 /tmp/koha-dpkg-docker/apt_control.sh

echo -ne "I: Seeding pbuilder script\n"
cat <<EOF | tee /tmp/koha-dpkg-docker/pbuilder_control.sh
#!/usr/bin/env bash
  echo "I: Running $0"
  apt clean ; apt update ; \
  apt install curl wget ca-certificates gnupg -y ; \
  wget -qO - ${REPO}/gpg.asc | gpg --dearmor | tee /usr/share/keyrings/koha.gpg >/dev/null ; \
  echo "deb [signed-by=/usr/share/keyrings/koha.gpg] ${REPO}/ ${SUITE} main" | tee /etc/apt/sources.list.d/koha.list ; \
  wget -qO - https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor | tee /usr/share/keyrings/nodesource.gpg >/dev/null ; \
  echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] http://deb.nodesource.com/node_18.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list ; \
  echo "Package: nodejs\nPin: version 18.*\nPin-Priority: 999" | tee /etc/apt/preferences.d/nodejs ; \
  wget -qO - https://dl.yarnpkg.com/${FAMILY}/pubkey.gpg | gpg --dearmor | tee /usr/share/keyrings/yarn.gpg >/dev/null ; \
  echo "deb [signed-by=/usr/share/keyrings/yarn.gpg] http://dl.yarnpkg.com/${FAMILY}/ stable main" | tee /etc/apt/sources.list.d/yarn.list ; \
  echo "Package: yarn\nPin: version 1.*\nPin-Priority: 999" | tee /etc/apt/preferences.d/yarn ; \
  apt clean ; apt update ; \
  apt install koha-perldeps docbook-xsl-ns -y
EOF
chmod -v 0755 /tmp/koha-dpkg-docker/pbuilder_control.sh

## run seeded file
echo -ne "I: Running apt_control seed script atop pbuilder\n"
pbuilder --execute --save-after-exec -- /tmp/koha-dpkg-docker/apt_control.sh
echo -ne "I: Running pbuilder_control seed script atop pbuilder\n"
pbuilder --execute --save-after-exec -- /tmp/koha-dpkg-docker/pbuilder_control.sh
mv -v /var/cache/pbuilder/base.tgz /tmp/koha-dpkg-docker/base.tgz


##
##
## start dockerfile stuff -- create base
echo -ne "I: Seeding build.sh for Docker image\n"
cat <<EOF | tee /tmp/koha-dpkg-docker/build.sh
#!/usr/bin/env bash

echo "I: Running $0"

## update now
/usr/bin/apt clean; apt update
/usr/bin/apt upgrade -y

## cd to workdir, run update.sh
cd /kohaclone

## run update.sh inside pbuilder env
echo -ne '#!/usr/bin/env bash\\n\\napt clean ; apt update\napt upgrade -y\napt full-upgrade -y' | tee /tmp/apt_upgrade.sh
/usr/bin/chmod -v 0755 /tmp/apt_upgrade.sh
/usr/sbin/pbuilder --execute --save-after-exec -- /tmp/apt_upgrade.sh

## determine version
EPOCH="\$(date +%s)"
TIMESTAMP="\$(date -d @\${EPOCH} -Iseconds)"
if [[ -z "\${VERSION}" ]]; then
	VERSION="\$(cat ./Koha.pm | grep "VERSION = \"" | cut -b13-20)"
fi
if [[ -z "\${REV}" ]]; then
	REV="\${EPOCH}"
fi
if [[ -z "\${DISTRIBUTION}" ]]; then
	DISTRIBUTION="\$(bash -c 'lsb_release -cs')"
fi
if [[ -z "\${PKG_ARCH}" ]]; then
	PKG_ARCH="all"
fi
PKG_VERSION="\${VERSION}-\${REV}"

## prep koha-manifest.json
GIT_BRANCH="\$(git rev-parse --abbrev-ref HEAD)"
if [[ -z "\${GIT_ORIGIN}" ]]; then
	GIT_ORIGIN="PTFS Europe"
fi
if [[ -z "\${GIT_LABEL_PREFIX}" ]]; then
  GIT_LABEL_PREFIX="Koha"
fi
GIT_SUITE="\${GIT_BRANCH}"
GIT_ARCHIVE="\${GIT_BRANCH}"
GIT_LABEL="\${GIT_LABEL_PREFIX} \${GIT_SUITE}"
MANIFEST="{\"timestamp\":\"\${TIMESTAMP}\",\"origin\":\"\${GIT_ORIGIN}\",\"label\":\"\${GIT_LABEL}\",\"archive\":\"\${GIT_ARCHIVE}\",\"suite\":\"\${GIT_SUITE}\",\"package-arch\":\"\${PKG_ARCH}\",\"package-version\":\"\${PKG_VERSION}\",\"artefacts\":[\${ARTEFACTS}]}"
MANIFEST="\$(echo "\${MANIFEST}" | jq '.')"

## prep repo
/usr/bin/git clean -f
/usr/bin/git checkout -- .

## prep env
export PERL5LIB="/kohaclone:/kohaclone/lib"
export PERL_MM_USE_DEFAULT=1
export KOHA_CONF=""
export KOHA_HOME="/kohaclone"

## prep git
/usr/bin/git config --global user.email "root@localhost.localnet"
/usr/bin/git config --global user.name  "root"
/usr/bin/cat .gitignore | /usr/bin/xargs rm -rvf {} \\;
/usr/bin/git reset --hard HEAD

## prep control
./debian/update-control
/usr/bin/git add -f debian/control
/usr/bin/git commit --no-verify -m "LOCAL: Updated debian/control file: \${PKG_VERSION}"

## prep koha
/usr/bin/perl Makefile.PL
/usr/bin/make all

## ingest variously build files
/usr/bin/git add -f api\\/*
/usr/bin/git add -f koha-tmpl\\/*
/usr/bin/git add -f t\\/*
/usr/bin/git commit --no-verify -m "LOCAL: Updated js / css: \${PKG_VERSION}"

## ingest any changes to po-files
/usr/bin/git add -f misc/translator\\/*
/usr/bin/git commit --no-verify -m "LOCAL: Updated translations: \${PKG_VERSION}"

## build dpkg
/usr/bin/dch --force-distribution -D "\${DISTRIBUTION}" -v "\${PKG_VERSION}" "Building git snapshot." || exit 1
/usr/bin/dch -r "Building git snapshot." || exit 1
/usr/bin/git archive --format="tar" --prefix="koha-\${VERSION}/" HEAD | gzip > ../koha_\${VERSION}.orig.tar.gz || exit 1
/usr/bin/pdebuild -- --basetgz "/var/cache/pbuilder/base.tgz" --buildresult "/kohadebs" || exit 1

## tidy-up
/usr/bin/git clean -f
/usr/bin/git checkout -- .

## populate artefacts
for FILENAME in /kohadebs/*.deb; do
	FILENAME="\$(basename "\${FILENAME}")"
	MANIFEST="\$(echo "\${MANIFEST}" | jq --arg filename "\$FILENAME" '.artefacts += [\$filename]')"
done

## mv tmp manifest to dest
echo "\${MANIFEST}" | tee "/kohadebs/koha-debs-manifest.json"

exit 0
EOF
chmod -v 0755 /tmp/koha-dpkg-docker/build.sh

## prepare Dockerfile
echo -ne "I: Seeding Dockerfile for image construction\n"
cat <<EOF | tee /tmp/koha-dpkg-docker/Dockerfile
ARG ARCH=
FROM ${ARCH}/${FAMILY}:${DISTRIBUTION}
ENV BRANCH=${BRANCH}
ENV KDD_BRANCH=${BRANCH}
ENV KDD_REGISTRY=${KDD_REGISTRY}
ENV FAMILY=${FAMILY}
ENV FAMILY_SEC=${FAMILY_SEC}
ENV MIRROR=${MIRROR}
ENV MIRROR_SEC=${MIRROR_SEC}
ENV DISTRIBUTION=${DISTRIBUTION}
ENV DISTRIBUTION_SEC=${DISTRIBUTION-SEC}
ENV KEYRING=${KEYRING}
ENV SUITE=${SUITE}
ENV REPO=${REPO}
ENV DEBIAN_FRONTEND=${DEBIAN_FRONTEND}
ENV EMAIL=${EMAIL}
ENV DEB_BUILD_OPTIONS=${DEB_BUILD_OPTIONS}
WORKDIR /
VOLUME ["/kohaclone", "/kohadebs"]
RUN \
    echo "I: Running $0" ; \
    rm -fv /etc/apt/sources.list.d/* ; \
    echo "deb ${MIRROR} ${DISTRIBUTION} main contrib non-free non-free-firmware" > /etc/apt/sources.list.d/${FAMILY}.list ; \
    echo "deb ${MIRROR} ${DISTRIBUTION}-updates main contrib non-free non-free-firmware" >> /etc/apt/sources.list.d/${FAMILY}.list ; \
    echo "deb ${MIRROR_SEC} ${DISTRIBUTION_SEC} main contrib non-free non-free-firmware" >> /etc/apt/sources.list.d/${FAMILY_SEC}.list ; \
    apt clean ; apt update ; apt upgrade -y ; apt full-upgrade -y ; \
    apt install curl wget gnupg ca-certificates -y ; \
    wget -qO - ${REPO}/gpg.asc | gpg --dearmor | tee /usr/share/keyrings/koha.gpg >/dev/null ; \
    echo "deb [signed-by=/usr/share/keyrings/koha.gpg] ${REPO}/ ${SUITE} main" | tee /etc/apt/sources.list.d/koha.list ; \
    wget -qO - https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor | tee /usr/share/keyrings/nodesource.gpg >/dev/null ; \
    echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] http://deb.nodesource.com/node_18.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list ; \
    echo "Package: nodejs\nPin: version 18.*\nPin-Priority: 999" | tee /etc/apt/preferences.d/nodejs ; \
    wget -qO - https://dl.yarnpkg.com/${FAMILY}/pubkey.gpg | gpg --dearmor | tee /usr/share/keyrings/yarn.gpg >/dev/null ; \
    echo "deb [signed-by=/usr/share/keyrings/yarn.gpg] http://dl.yarnpkg.com/${FAMILY}/ stable main" | tee /etc/apt/sources.list.d/yarn.list ; \
    echo "Package: yarn\nPin: version 1.*\nPin-Priority: 999" | tee /etc/apt/preferences.d/yarn ; \
    apt clean ; apt update ; apt upgrade -y ; \
    apt install build-essential git file -y ; \
    apt install devscripts pbuilder dh-make fakeroot bash-completion apt-file ${FAMILY}-archive-keyring -y ; \
    apt install nodejs yarn -y ; \
    apt install libmodern-perl-perl libmodule-cpanfile-perl libparallel-forkmanager-perl libsys-cpu-perl -y ; \
    apt install jq -y ; \
    git config --global --add safe.directory /kohaclone ; \
    npm set strict-ssl false -g ; \
    npm install -g gulp-cli@latest ; \
    yarn config set strict-ssl false -g ; \
    apt clean ; apt update ; apt upgrade -y ; \
    apt-file update ; \
    pbuilder clean
COPY base.tgz /var/cache/pbuilder/
COPY build.sh /
CMD ["/bin/sh","-c","/build.sh"]
EOF


##
##
## job run
cd /tmp/koha-dpkg-docker/
echo -ne "I: Building Docker image for k.d.d building"
cat Dockerfile | docker buildx build \
  --push \
  --build-arg ARCH=${ARCH} \
  --platform ${PLATFORM} \
  --tag ${KDD_REGISTRY}:${KDD_BRANCH}-${ARCH} \
  --file - \
  .

##
##
## job done
echo -ne "I: Removing disused temp files\n"
rm -vf /tmp/koha-dpkg-docker/base.tgz
rm -vf /tmp/koha-dpkg-docker/apt_control.sh
rm -vf /tmp/koha-dpkg-docker/pbuilder_control.sh
rm -vf /tmp/koha-dpkg-docker/build.sh
rm -vf /tmp/koha-dpkg-docker/Dockerfile
rm -vrf /tmp/koha-dpkg-docker/
echo -ne "Done!\n"
exit 0
