#!/bin/bash -x

## cd to kohaclone
cd ${WORKSPACE}/kohaclone

export SYNC_REPO="${WORKSPACE}/kohaclone"
export DEBS_OUT="${WORKSPACE}/kohadebs"
export KDD_IMAGE="23.11"
export KDD_BRANCH="23.11"
## build kdd
wget -O build.pl https://gitlab.com/openfifth/koha-debs-docker/-/raw/${KDD_BRANCH}/jenkins_config/build.pl
/usr/bin/perl build.pl
