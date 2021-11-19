#!/bin/bash
set -ex

PLATFORM="$1"
if [ "${PLATFORM}" = qemu ]; then
  TIMEOUT="12h"
  BIOS="bios-256k.bin"
elif [ "${PLATFORM}" = qemu_uefi ]; then
  TIMEOUT="14h"
  BIOS="/mnt/host/source/tmp/flatcar_production_qemu_uefi_efi_code.fd"
else
  echo "Unknown platform: \"${PLATFORM}\""
fi

native_arm64() {
  [[ "${NATIVE_ARM64}" == true ]]
}

sudo rm -rf *.tap src/scripts/_kola_temp tmp _kola_temp* _tmp

if native_arm64 ; then
  # for kola reflinking
  sudo rm -rf /var/tmp
  mkdir -p _tmp
  chmod 1777 _tmp
  ln -s "$PWD/_tmp" /var/tmp
  # use arm64 mantle bins
  rm -rf bin
  mv bin.arm64 bin
  # simulate SDK folder structure
  mkdir -p src
  ln -s .. src/scripts
  sudo rm -f chroot
  ln -s / chroot

  enter() {
    "$@"
  }
else
  enter() {
    bin/cork enter --bind-gpg-agent=false -- "$@"
  }
fi

script() {
  enter "/mnt/host/source/src/scripts/$@"
}

# Set up GPG for verifying tags.
export GNUPGHOME="${PWD}/.gnupg"
rm -rf "${GNUPGHOME}"
trap 'rm -rf "${GNUPGHOME}"' EXIT
mkdir --mode=0700 "${GNUPGHOME}"
gpg --import verify.asc
# Sometimes this directory is not created automatically making further private
# key imports fail, let's create it here as a workaround
mkdir -p --mode=0700 "${GNUPGHOME}/private-keys-v1.d/"

# since /flatcar-jenkins/developer/sdk starts with a / we only use one
DOWNLOAD_ROOT_SDK="gs:/${SDK_URL_PATH}"

if native_arm64 ; then
  mkdir -p .repo/
  if [ ! -e .repo/manifests ]; then
    mkdir -p ~/.ssh
    ssh-keyscan -t rsa github.com >> ~/.ssh/known_hosts
    git clone "${MANIFEST_URL}" .repo/manifests
  fi
  git -C .repo/manifests tag -v "${MANIFEST_TAG}"
  git -C .repo/manifests checkout "${MANIFEST_TAG}"
else
  bin/cork create \
      --verify --verify-signature --replace \
      --sdk-url-path "${SDK_URL_PATH}" \
      --json-key "${GOOGLE_APPLICATION_CREDENTIALS}" \
      --manifest-branch "refs/tags/${MANIFEST_TAG}" \
      --manifest-name "${MANIFEST_NAME}" \
      --sdk-url storage.googleapis.com \
      --manifest-url "${MANIFEST_URL}"
fi

source .repo/manifests/version.txt

[ -s verify.asc ] && verify_key=--verify-key=verify.asc || verify_key=

if ! native_arm64; then
  script update_chroot \
      --toolchain_boards="${BOARD}" --dev_builds_sdk="${DOWNLOAD_ROOT_SDK}"
fi

mkdir -p tmp
bin/cork download-image \
    --cache-dir=tmp \
    --json-key="${GOOGLE_APPLICATION_CREDENTIALS}" \
    --platform="${PLATFORM}" \
    --root="${DOWNLOAD_ROOT}/boards/${BOARD}/${FLATCAR_VERSION}" \
    --verify=true $verify_key
enter lbunzip2 -k -f /mnt/host/source/tmp/flatcar_production_image.bin.bz2

# BEGIN MY OWN MANTLE HACK
mkdir -p tmp/mantle
git clone --depth=1 --branch=krnowak/debug-ping https://github.com/flatcar-linux/mantle.git tmp/mantle/repo
pushd tmp/mantle/repo
# So git describe --dirty in mantle's ./build script won't
# complain. There are no annotated tags, because I did a shallow
# clone.
git \
    -c user.name='Foo Bar' \
    -c user.email='foo@example.com' \
    tag -a v99.99.99 -m 'ajwaj'
# Stolen from mantle's Jenkinsfile
docker run --rm -e CGO_ENABLED=0 -e GOARCH=arm64 -e GOCACHE=/usr/src/myapp/cache -u "$(id -u):$(id -g)" -v /etc/passwd:/etc/passwd:ro -v /etc/group:/etc/group:ro -v "$PWD":/usr/src/myapp -w /usr/src/myapp golang:1.16 ./build
mv bin bin.arm64
docker run --rm -e CGO_ENABLED=1 -e GOARCH=amd64 -e GOCACHE=/usr/src/myapp/cache -u "$(id -u):$(id -g)" -v /etc/passwd:/etc/passwd:ro -v /etc/group:/etc/group:ro -v "$PWD":/usr/src/myapp -w /usr/src/myapp golang:1.16 ./build
popd
# Replace mantle binaries with those just built.
rm -rf bin bin.arm64
mv tmp/mantle/repo/bin bin
mv tmp/mantle/repo/bin.arm64 bin.arm64
# END MY OWN MANTLE HACK

# create folder to handle case where arm64 is missing
sudo mkdir -p chroot/usr/lib/kola/{arm64,amd64}
# copy all of the latest mantle binaries into the chroot
sudo cp -t chroot/usr/lib/kola/arm64 bin/arm64/*
sudo cp -t chroot/usr/lib/kola/amd64 bin/amd64/*
sudo cp -t chroot/usr/bin bin/[b-z]*

if [[ "${KOLA_TESTS}" == "" ]]; then
  KOLA_TESTS="*"
fi

rm -f flatcar_test_update.gz
bin/gangue get \
    --json-key="${GOOGLE_APPLICATION_CREDENTIALS}" \
    --verify=true $verify_key \
    "${DOWNLOAD_ROOT}/boards/${BOARD}/${FLATCAR_VERSION}/flatcar_test_update.gz"
mv flatcar_test_update.gz tmp/

if [ "${KOLA_TESTS}" = "*" ] || [ "$(echo "${KOLA_TESTS}" | grep 'cl.update.payload')" != "" ]; then
  # First test to update from the previous release, this is done before running the real kola suite so that the qemu-latest symlink still points to the full run
  rm -f flatcar_production_image.bin.bz2
  curl -fsSLO --retry-delay 1 --retry 60 --retry-connrefused --retry-max-time 60 --connect-timeout 20 "https://${GROUP}.release.flatcar-linux.net/${BOARD}/current/flatcar_production_image.bin.bz2"
  mv flatcar_production_image.bin.bz2 tmp/flatcar_production_image_previous.bin.bz2
  enter lbunzip2 -k -f /mnt/host/source/tmp/flatcar_production_image_previous.bin.bz2
  enter sudo timeout --signal=SIGQUIT "${TIMEOUT}" kola run \
    --board="${BOARD}" \
    --channel="${GROUP}" \
    --parallel="${PARALLEL}" \
    --platform=qemu \
    --qemu-bios="${BIOS}" \
    --qemu-image=/mnt/host/source/tmp/flatcar_production_image_previous.bin \
    --tapfile="/mnt/host/source/${JOB_NAME##*/}_update_from_previous_release.tap" \
    --torcx-manifest=/mnt/host/source/torcx_manifest.json \
    --update-payload=/mnt/host/source/tmp/flatcar_test_update.gz \
    cl.update.payload || true
fi

# Do not expand the kola test patterns globs
set -o noglob
enter sudo timeout --signal=SIGQUIT "${TIMEOUT}" kola run \
    --board="${BOARD}" \
    --channel="${GROUP}" \
    --parallel="${PARALLEL}" \
    --platform=qemu \
    --qemu-bios="${BIOS}" \
    --qemu-image=/mnt/host/source/tmp/flatcar_production_image.bin \
    --tapfile="/mnt/host/source/${JOB_NAME##*/}.tap" \
    --torcx-manifest=/mnt/host/source/torcx_manifest.json \
    ${KOLA_TESTS}
set +o noglob

sudo rm -rf tmp
