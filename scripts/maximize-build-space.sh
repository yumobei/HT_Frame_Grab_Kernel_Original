#!/usr/bin/env bash
# ============================================================================
# Maximize the GitHub Actions runner's build space.
#
# Creates an LVM volume group from the free space of the root filesystem and
# /mnt, then mounts one large ext4 volume over $GITHUB_WORKSPACE.  This is the
# same mechanism used by the reference Action-Build workflow; it is vendored
# here so the clean build does not clone a third-party build repository.
#
# The caller must copy this script to /tmp before running it: once the new
# volume is mounted over $GITHUB_WORKSPACE, the original path disappears.
#
# Environment (all optional):
#   ROOT_RESERVE_MB   default 8192
#   TEMP_RESERVE_MB   default 2048
#   SWAP_SIZE_MB      default 4096; 0 = do not create an LVM swap LV
#   BUILD_MOUNT_PATH  default $GITHUB_WORKSPACE
#   MOUNT_OWNERSHIP   default runner:runner
#   PV_LOOP_PATH      default /pv.img
#   TMP_PV_LOOP_PATH  default /mnt/tmp-pv.img
#   REMOVE_DOTNET / REMOVE_ANDROID / REMOVE_HASKELL / REMOVE_CODEQL
#                     default false; "true" removes the preinstalled SDKs
#
# Console messages are ASCII/English on purpose.
# ============================================================================
set -euo pipefail

ROOT_RESERVE_MB="${ROOT_RESERVE_MB:-8192}"
TEMP_RESERVE_MB="${TEMP_RESERVE_MB:-2048}"
SWAP_SIZE_MB="${SWAP_SIZE_MB:-4096}"
BUILD_MOUNT_PATH="${BUILD_MOUNT_PATH:-$GITHUB_WORKSPACE}"
MOUNT_OWNERSHIP="${MOUNT_OWNERSHIP:-runner:runner}"
PV_LOOP_PATH="${PV_LOOP_PATH:-/pv.img}"
TMP_PV_LOOP_PATH="${TMP_PV_LOOP_PATH:-/mnt/tmp-pv.img}"

REMOVE_DOTNET="${REMOVE_DOTNET:-false}"
REMOVE_ANDROID="${REMOVE_ANDROID:-false}"
REMOVE_HASKELL="${REMOVE_HASKELL:-false}"
REMOVE_CODEQL="${REMOVE_CODEQL:-false}"
REMOVE_DOCKER_IMAGES="${REMOVE_DOCKER_IMAGES:-false}"

VG_NAME=buildvg

echo "maximize-build-space:"
echo "  root reserve:  ${ROOT_RESERVE_MB} MiB"
echo "  temp reserve:  ${TEMP_RESERVE_MB} MiB"
echo "  swap LV:       ${SWAP_SIZE_MB} MiB"
echo "  mount path:    ${BUILD_MOUNT_PATH}"
echo "  root PV loop:  ${PV_LOOP_PATH}"
echo "  temp PV loop:  ${TMP_PV_LOOP_PATH}"
echo "  removing: dotnet=${REMOVE_DOTNET} android=${REMOVE_ANDROID} haskell=${REMOVE_HASKELL} codeql=${REMOVE_CODEQL} docker=${REMOVE_DOCKER_IMAGES}"
echo

WORKSPACE_OWNER="$(stat -c '%U:%G' "${GITHUB_WORKSPACE}")"

echo "space before:"
sudo df -h
echo

sudo mkdir -p "${BUILD_MOUNT_PATH}"

echo "removing preinstalled SDKs..."
if [[ "${REMOVE_DOTNET}" == "true" ]]; then
  sudo rm -rf /usr/share/dotnet
fi
if [[ "${REMOVE_ANDROID}" == "true" ]]; then
  sudo rm -rf /usr/local/lib/android
fi
if [[ "${REMOVE_HASKELL}" == "true" ]]; then
  sudo rm -rf /opt/ghc
fi
if [[ "${REMOVE_CODEQL}" == "true" ]]; then
  sudo rm -rf /opt/hostedtoolcache/CodeQL
fi
if [[ "${REMOVE_DOCKER_IMAGES}" == "true" ]]; then
  sudo docker image prune --all --force
fi
echo "... done"
echo

echo "disabling and removing the old swap file..."
sudo swapoff -a
sudo rm -f /mnt/swapfile

echo "creating root-filesystem LVM PV..."
ROOT_RESERVE_KB=$((ROOT_RESERVE_MB * 1024))
ROOT_FREE_KB=$(df --block-size=1024 --output=avail / | tail -1)
ROOT_LVM_SIZE_BYTES=$(( (ROOT_FREE_KB - ROOT_RESERVE_KB) * 1024 ))
if (( ROOT_LVM_SIZE_BYTES <= 0 )); then
  echo "maximize-build-space: ERROR: not enough free space on /" >&2
  exit 1
fi
sudo touch "${PV_LOOP_PATH}"
sudo fallocate -z -l "${ROOT_LVM_SIZE_BYTES}" "${PV_LOOP_PATH}"
ROOT_LOOP_DEV=$(sudo losetup --find --show "${PV_LOOP_PATH}")
sudo pvcreate -f "${ROOT_LOOP_DEV}"

echo "creating /mnt LVM PV..."
TEMP_RESERVE_KB=$((TEMP_RESERVE_MB * 1024))
TEMP_FREE_KB=$(df --block-size=1024 --output=avail /mnt | tail -1)
TEMP_LVM_SIZE_BYTES=$(( (TEMP_FREE_KB - TEMP_RESERVE_KB) * 1024 ))
if (( TEMP_LVM_SIZE_BYTES <= 0 )); then
  echo "maximize-build-space: ERROR: not enough free space on /mnt" >&2
  exit 1
fi
sudo touch "${TMP_PV_LOOP_PATH}"
sudo fallocate -z -l "${TEMP_LVM_SIZE_BYTES}" "${TMP_PV_LOOP_PATH}"
TMP_LOOP_DEV=$(sudo losetup --find --show "${TMP_PV_LOOP_PATH}")
sudo pvcreate -f "${TMP_LOOP_DEV}"

echo "creating volume group ${VG_NAME}..."
sudo vgcreate "${VG_NAME}" "${TMP_LOOP_DEV}" "${ROOT_LOOP_DEV}"

if (( SWAP_SIZE_MB > 0 )); then
  echo "creating ${SWAP_SIZE_MB} MiB swap LV..."
  sudo lvcreate -L "${SWAP_SIZE_MB}M" -n swap "${VG_NAME}"
  sudo mkswap "/dev/mapper/${VG_NAME}-swap"
  sudo swapon "/dev/mapper/${VG_NAME}-swap"
else
  echo "skipping LVM swap LV (SWAP_SIZE_MB=0)"
fi

echo "creating and mounting the build volume at ${BUILD_MOUNT_PATH}..."
sudo lvcreate -l 100%FREE -n buildlv "${VG_NAME}"
sudo mkfs.ext4 -Enodiscard -m0 "/dev/mapper/${VG_NAME}-buildlv"
sudo mount "/dev/mapper/${VG_NAME}-buildlv" "${BUILD_MOUNT_PATH}"
sudo chown -R "${MOUNT_OWNERSHIP}" "${BUILD_MOUNT_PATH}"

if [[ ! -d "${GITHUB_WORKSPACE}" ]]; then
  sudo mkdir -p "${GITHUB_WORKSPACE}"
  sudo chown -R "${WORKSPACE_OWNER}" "${GITHUB_WORKSPACE}"
fi

echo
echo "space after:"
sudo df -h
