#!/bin/bash

# This script will install the latest static nightly build of ffmpeg on Ubuntu 
echo "************************************************"
echo "************************************************"
echo "**** FFMPEG STATIC INSTALL SCRIPT"
echo "**** This script installs latest ffmpeg git master build, from https://johnvansickle.com/ffmpeg/"
echo "**** See: https://github.com/jontybrook/ffmpeg-install-script on which this is based"
echo "**** Author: me@jontyb.co.uk"
echo "**** Original excpt the dns fix has been commented out"
echo "************************************************"
echo "************************************************"
echo "Starting ffmpeg static install script..."

# Check if sudo is required so we can adapt the script accordingly. 
# In docker build contexts, sudo is usually not required nor installed. To support this use case,
# if sudo is not installed, the script will run the commands without sudo.
echo "Checking if sudo is required"
if hash sudo 2>/dev/null; then
    echo "sudo is installed. The script will use sudo where required."
    sudo_required=true
else
    echo "sudo is not installed. The script will run commands without sudo."
    sudo_required=false
fi

# Check that md5sum and wget are installed
echo "Checking that md5sum and wget are installed"
if ! hash md5sum 2>/dev/null; then
    echo "md5sum is not installed. Please install it using 'sudo apt-get install md5sum'"
    echo "The script will now exit"
    exit 1
fi

# Create a temporary directory
temp_dir=$(mktemp -d)

echo "Temporary directory is: $temp_dir"

# Remember pwd so we can cd back to it later
previousWorkingDirectory=$(pwd)

# create and cd into /tmp/ffmpeg-install
echo "Creating and navigating to /tmp/ffmpeg-install directory"
mkdir -p $temp_dir/ffmpeg-install
cd $temp_dir/ffmpeg-install

# Find the architecture of the system
echo "Finding the architecture of the system"
# Get the architecture using uname
arch=$(uname -m)

# Map the uname output to your required format
architecture=""
case $arch in
    x86_64)
        echo "Detected amd64 architecture. The appropriate ffmpeg build will be downloaded"
        architecture="amd64"
        ;;
    i686 | i386)
        echo "Detected i686 architecture. The appropriate ffmpeg build will be downloaded"
        architecture="i686"
        ;;
    armv6l | armv7l)
        echo "Detected armhf architecture. The appropriate ffmpeg build will be downloaded"
        architecture="armhf"
        ;;
    aarch64)
        echo "Detected arm64 architecture. The appropriate ffmpeg build will be downloaded"
        architecture="arm64"
        ;;
    *)
        echo "!!!!!!!!!!!!"
        echo "FFMPEG INSTALL FAILED: Unknown architecture: $arch"
        echo "This script only works on amd64, i686, armhf and arm64 architectures"
        echo "The script will now exit"
        echo "!!!!!!!!!!!!"
        echo "FFMPEG INSTALL FAILED: Unknown architecture: $arch" >&2
        cd $previousWorkingDirectory # cd back to the previous working directory
        exit 1
        ;;
esac

# If --stable is passed as an argument, install the latest release build of ffmpeg
# otherwise install the latest static 'git master' build of ffmpeg
buildVersion="git"
buildDownloadUrlPrefix="https://johnvansickle.com/ffmpeg/builds"
if [[ $1 == "--stable" ]] || [[ $2 == "--stable" ]]; then
    buildVersion="release"
    buildDownloadUrlPrefix="https://johnvansickle.com/ffmpeg/releases"
    echo "Installing the latest stable build of ffmpeg"
fi

# Download the latest static nightly build of ffmpeg
echo "Downloading the latest $buildVersion build of ffmpeg"
if $sudo_required; then
    sudo wget "$buildDownloadUrlPrefix/ffmpeg-$buildVersion-$architecture-static.tar.xz"
else
    wget "$buildDownloadUrlPrefix/ffmpeg-$buildVersion-$architecture-static.tar.xz"
fi

# Download the md5 checksum file
echo "Downloading the md5 checksum file..."
if $sudo_required; then
    sudo wget "$buildDownloadUrlPrefix/ffmpeg-$buildVersion-$architecture-static.tar.xz.md5"
else
    wget "$buildDownloadUrlPrefix/ffmpeg-$buildVersion-$architecture-static.tar.xz.md5"
fi

# Verify the checksum
echo "Verifying the checksum of the downloaded file.."
if ! md5sum -c ffmpeg-$buildVersion-$architecture-static.tar.xz.md5; then
    echo "MD5 checksum verification failed. The downloaded file may be corrupted."
    echo "The script will now exit."
    cd $previousWorkingDirectory # cd back to the previous working directory
    exit 1
fi

# Unpack the build
echo "Unpacking the build.."
tar -xvf $temp_dir/ffmpeg-install/ffmpeg-$buildVersion-$architecture-static.tar.xz -C $temp_dir/ffmpeg-install/

# Find the directory name of the unpacked build (it changes with each nightly build) and cd into it. 
# The format is ffmpeg-git-YYYYMMDD-amd64-static
echo "Navigating to the unpacked build directory"
cd $temp_dir/ffmpeg-install/ffmpeg-*-*/

# Cat out the readme so we can log it during builds that use this script
echo "Displaying the contents of readme.txt"
cat readme.txt

# ! Important note - From readme.txt in version ffmpeg-git-20231128-amd64-static...
#  "A limitation of statically linking glibc is the loss of DNS resolution. Installing
#  nscd through your package manager will fix this."

# Install nscd 
# echo "Installing nscd"
# if $sudo_required; then
#     sudo apt-get install nscd
# else
#     apt-get install nscd
# fi

# Check if FFmpeg is installed using apt
if dpkg -s ffmpeg &>/dev/null; then
    echo "FFmpeg is already installed using apt"
    if [[ $1 == "--force" ]]; then
        echo "Removing ffmpeg..."
        if $sudo_required; then
            sudo apt-get remove ffmpeg
        else
            apt-get remove ffmpeg
        fi
    else
        read -p "Do you want to remove it? (y/n): " answer
        if [[ $answer == "y" ]]; then
            echo "Removing ffmpeg..."
            if $sudo_required; then
                sudo apt-get remove ffmpeg
            else
                apt-get remove ffmpeg
            fi
        fi
    fi
fi

# Check if ffmpeg is installed via some other method
if hash ffmpeg 2>/dev/null; then
    echo "ffmpeg is already installed at $(which ffmpeg)"
    if [[ $1 == "--force" ]]; then
        echo "Removing ffmpeg..."
        if $sudo_required; then
            sudo rm $(which ffmpeg)
        else
            rm $(which ffmpeg)
        fi
    else
        read -p "Do you want to remove it? (y/n): " answer
        if [[ $answer == "y" ]]; then
            echo "Removing ffmpeg..."
            if $sudo_required; then
                sudo rm $(which ffmpeg)
            else
                rm $(which ffmpeg)
            fi
        fi
    fi
fi


# Copy the ffmpeg and ffprobe binaries to /usr/local/bin
echo "Copying ffmpeg and ffprobe binaries to /usr/local/bin"
if $sudo_required; then
    sudo cp ffmpeg ffprobe /usr/local/bin
else
    cp ffmpeg ffprobe /usr/local/bin
fi

# Check if the ffmpeg and ffprobe binaries copied successfully
if hash ffmpeg 2>/dev/null; then
    echo "ffmpeg is now installed at $(which ffmpeg)"
else
    echo "!!!!!!!!!!!!"
    echo "FFMPEG INSTALL FAILED: ffmpeg is not installed"
    echo "The script will now exit"
    echo "!!!!!!!!!!!!"
    echo "FFMPEG INSTALL FAILED: ffmpeg is not installed" >&2
    exit 1
fi

cd $previousWorkingDirectory # cd back to the previous working directory

echo "Cleaning up temproary directory $temp_dir"
rm -rf $temp_dir

# Check the version of ffmpeg
echo "************************************************"
echo "** ffmpeg installation complete"
echo "** You should see the version of ffmpeg installed printed out below (ffmpeg -version)"
echo "************************************************"

ffmpeg -version

echo "************************************************"
echo "** ffmpeg static install script finished"
echo "************************************************"
