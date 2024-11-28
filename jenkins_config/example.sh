#!/bin/bash -x

docker --version
docker compose version
cat /etc/issue

export KDD_IMAGE="24.11"
export KDD_BRANCH="24.11"
export SYNC_REPO="$(pwd)/kohaclone"
export DEBS_OUT="$(pwd)/kohadebs"

cd "$(pwd)/kohaclone"

wget https://raw.githubusercontent.com/openfifth/koha-dpkg-docker/refs/heads/${KDD_BRANCH}/jenkins_config/koha_build_runner.pl \
   -O ../koha_build_runner.pl

perl ../koha_build_runner.pl \
    --initial-docker-cleanup \
    --warmup-timeout 500 \
	--force-cleanup \
	--verbose
