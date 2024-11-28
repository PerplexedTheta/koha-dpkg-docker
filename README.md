Automated Debian package builder for Koha, based on the work by tcohen

This is designed to run within Jenkins or GitLab CI/CD, as a quick, easy, and reliable way of turning a Koha repository clone into a Debian package of Koha.

## Usage
You will need three things to build a Koha package:
* a valid Koha repository (in this example, it will be at `/home/koha/kohaclone`)
* a valid, empty, output directory (in this example, it will be at `/home/koha/kohadebs`)
* a valid installation of Docker (please see the [Installing Docker correctly](https://gitlab.com/openfifth/koha-debs-docker/-/wikis/Installing%20Docker%20correctly) article for instructions on how to do this)

Make sure you have checked out the branch you would like. To do this (using 24.11 as an example):
```bash
cd /home/koha/kohaclone
git fetch origin ; git checkout -b 24.11.custom --track origin/24.11.x
```

With the correct branch, choose a valid Docker image, and run with:
```bash
docker run \
    --privileged \
    --volume=/home/koha/kohaclone:/kohaclone \
    --volume=/home/koha/kohadebs:/kohadebs \
    ghcr.io/openfifth/koha-dpkg-docker:24.11
```

Remember to keep the Docker mountpoints (the directory after the colon) the same! When the process is complete, you should have a valid set of packages in the `kohadebs` directory.

Congratulations!

## Source code & wiki pages
The source code found under this repository is covered under the GPL v3 licence. Please see the LICENSE file for details.

The wiki is also found on GitLab, under the [GitLab wikis section](https://gitlab.com/openfifth/koha-debs-docker/-/wikis/home) of the repo
