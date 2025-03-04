#!/usr/bin/env bash

echo "Running build.sh"

set -e
export DEBIAN_FRONTEND=noninteractive

# Install dependencies
sudo apt-get update && \
    sudo apt-get install -y \
        gpg \
        debmake \
        debhelper \
        devscripts \
        equivs \
        distro-info-data \
        distro-info \
        software-properties-common

# Import GPG private key
echo "::group::Importing GPG private key..."
GPG_KEY_ID=$(echo "$GPG_PRIVATE_KEY" | gpg --import-options show-only --import | sed -n '2s/^\s*//p')
echo "GPG_KEY_ID: $GPG_KEY_ID"
echo "$GPG_PRIVATE_KEY" | gpg --batch --passphrase "$GPG_PASSPHRASE" --import

# Check GPG key expiration
echo "Checking GPG expirations..."
if [[ $(gpg --list-keys | grep expired) ]]; then
    echo "GPG key has expired. Please update your GPG key." >&2
    exit 1
fi
echo "::endgroup::"

# Add extra PPAs
echo "::group::Adding PPA..."
if [[ -n "$EXTRA_PPA" ]]; then
    for ppa in $EXTRA_PPA; do
        echo "Adding PPA: $ppa"
        sudo add-apt-repository -y ppa:$ppa
    done
fi
sudo apt-get update
echo "::endgroup::"

# Determine series
if [[ -z "$SERIES" ]]; then
    SERIES=$(distro-info --supported)
fi

# Add extra series
if [[ -n "$EXTRA_SERIES" ]]; then
    SERIES="$EXTRA_SERIES $SERIES"
fi

# Create workspace directory
mkdir -p /tmp/workspace/source

# Extract original source tarball if provided
if [[ -n "$TARBALL" ]]; then
    echo "::group::Extracting original source tarball..."
    echo "Tarball path: $TARBALL"
    tar -xf "$TARBALL" -C /tmp/workspace/source
    echo "::endgroup::"
fi

# Copy Debian directory if provided
if [[ -n "$DEBIAN_DIR" ]]; then
    echo "::group::Copying Debian directory..."
    cp -rv "$DEBIAN_DIR" /tmp/workspace/debian
    echo "::endgroup::"
fi

# Build and publish packages for each series
for s in $SERIES; do
    ubuntu_version=$(distro-info --series "$s" -r | cut -d' ' -f1)

    echo "::group::Building deb for: $ubuntu_version ($s)"

    # Copy workspace to temporary directory
    cp -rv /tmp/workspace /tmp/"$s" && cd /tmp/"$s"/source

    # Extract source package
    tar -xf ./*

    # Safely capture the extracted directory name
    extracted_dir=$(find . -maxdepth 1 -type d -name "*" -print0 | head -z -n 1 | xargs -0 -n 1 basename)

    # Change to extracted directory
    cd "$extracted_dir"

    # Run debmake
    echo "Making non-native package..."
    debmake "$DEBMAKE_ARGUMENTS"

    # Copy Debian directory if provided
    if [[ -n "$DEBIAN_DIR" ]]; then
        cp -rv /tmp/"$s"/debian/* debian/
    fi

    # Extract package information
    package=$(dpkg-parsechangelog --show-field Source)
    pkg_version=$(dpkg-parsechangelog --show-field Version | cut -d- -f1)
    changes="New upstream release"

    # Create changelog
    rm -rf debian/changelog
    dch --create \
        --distribution "$s" \
        --package "$package" \
        --newversion "$pkg_version-ppa$REVISION~ubuntu$ubuntu_version" \
        "$changes"

    # Install build dependencies
    sudo mk-build-deps \
        --install \
        --remove \
        --tool='apt-get -o Debug::pkgProblemResolver=yes --no-install-recommends --yes' \
        debian/control

    # Build package
    debuild -S -sa \
        -k"$GPG_KEY_ID" \
        -p"gpg --batch --passphrase '$GPG_PASSPHRASE' --pinentry-mode loopback"

    # Upload package
    dput ppa:"$REPOSITORY" ../*.changes

    echo "Uploaded $package to $REPOSITORY"

    echo "::endgroup::"
done