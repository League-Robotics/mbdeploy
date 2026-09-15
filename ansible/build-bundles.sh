#!/usr/bin/env bash
# Build the offline wheel bundles the deploy.yml playbook installs from.
#
# The fleet nodes have no internet access, so every dependency is downloaded
# here (a machine WITH internet) into bundles/<arch>/ and copied over by the
# mbdeploy role. Two architectures exist on the fleet:
#
#   aarch64 — Pi 3B / Zero 2 W. Everything has a prebuilt manylinux wheel
#             on PyPI; nothing compiles on the target.
#   armv6l  — Pi Zero W. Compiled deps come from piwheels; zeroconf has no
#             armv6l wheel anywhere (piwheels stopped at 0.39.4, and a Docker
#             arm/v6 cross-build mis-tags as armv7l), so it is carried as an
#             sdist plus the build toolchain, and compiles on the target.
#
# Both bundles target cp313 (Python 3.13, Debian/Raspbian trixie). Bump
# PYVER when the fleet OS moves.
set -euo pipefail
cd "$(dirname "$0")"

PYVER=313
PIWHEELS=https://www.piwheels.org/simple
DEPS=('pyocd>=0.44.1' 'pyserial>=3.5' 'intelhex>=2.3.0')  # zeroconf handled per-arch

echo "== Building the mbdeploy wheel =="
rm -rf ../dist bundles
uv build --wheel --project ..

echo "== aarch64 bundle (PyPI manylinux wheels) =="
mkdir -p bundles/aarch64
python3 -m pip download "${DEPS[@]}" 'zeroconf>=0.150.0' \
    --only-binary=:all: \
    --platform manylinux_2_17_aarch64 --platform manylinux2014_aarch64 \
    --platform manylinux_2_28_aarch64 --platform manylinux_2_34_aarch64 \
    --python-version $PYVER --implementation cp \
    --abi cp$PYVER --abi abi3 --abi none \
    -d bundles/aarch64

echo "== armv6l bundle (piwheels + zeroconf sdist) =="
mkdir -p bundles/armv6l
python3 -m pip download "${DEPS[@]}" \
    --only-binary=:all: \
    --platform linux_armv6l \
    --python-version $PYVER --implementation cp --abi cp$PYVER \
    --extra-index-url $PIWHEELS \
    -d bundles/armv6l
python3 -m pip download 'zeroconf>=0.150.0' --no-deps --no-binary :all: \
    -d bundles/armv6l
python3 -m pip download Cython setuptools poetry-core wheel \
    --only-binary=:all: \
    --platform linux_armv6l \
    --python-version $PYVER --implementation cp --abi cp$PYVER \
    --extra-index-url $PIWHEELS \
    -d bundles/armv6l

cp ../dist/mbdeploy-*.whl bundles/aarch64/
cp ../dist/mbdeploy-*.whl bundles/armv6l/

echo "== Done =="
du -sh bundles/*
