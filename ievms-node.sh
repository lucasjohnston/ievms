#!/usr/bin/env bash

# Caution is a virtue.
set -o nounset
set -o errtrace
set -o errexit
set -o pipefail

# ## Global Variables

# The ievms version.
ievms_version="0.3.3"

# Options passed to each `curl` command.
curl_opts=${CURL_OPTS:-""}

# Reuse Win7 virtual machines for IE versions that are supported.
reuse_win7=${REUSE_WIN7:-"no"}

# Timeout interval to wait between checks for various states.
sleep_wait="5"

# Time to wait for OS to boot before sending other commands.
os_boot_wait="20"

# ## Utilities

# Print a message to the console.
log()  { printf '%s\n' "$*" ; return $? ; }

# Print an error message to the console and bail out of the script.
fail() { log "ERROR: $*\n" ; exit 1 ; }

check_md5() { #1 = path, 2 = md5
    local md5

    case $kernel in
        Darwin) md5=`md5 "${1}" | rev | cut -c-32 | rev` ;;
        Linux) md5=`md5sum "${1}" | cut -c-32` ;;
    esac

    if [ "${md5}" != "${2}" ]
    then
        log "MD5 check failed for ${1} (wanted ${2}, got ${md5})"
        return 1
    fi

    log "MD5 check succeeded for ${1}"
}

# Download a URL to a local file. Accepts a name, URL and file.
download() { # name url path md5
    local attempt=${5:-"0"}
    local max=${6:-"3"}

    let attempt+=1

    if [[ -f "${3}" ]]
    then
        log "Found ${1} at ${3} - skipping download"
        check_md5 "${3}" "${4}" && return 0
        log "Check failed - redownloading ${1}"
        rm -f "${3}"
    fi

    log "Downloading ${1} from ${2} to ${3} (attempt ${attempt} of ${max})"
    curl -O "${2}" || fail "Failed to download ${2} to ${ievms_home}/${3} using 'curl', error code ($?)"
    check_md5 "${3}" "${4}" && return 0

    if [ "${attempt}" == "${max}" ]
    then
        echo "Failed to download ${2} to ${ievms_home}/${3} (attempt ${attempt} of ${max})"
        return 1
    fi

    log "Redownloading ${1}"
    download "${1}" "${2}" "${3}" "${4}" "${attempt}" "${max}"
}

# ## General Setup

# Create the ievms home folder and `cd` into it. The `INSTALL_PATH` env variable
# is used to determine the full path. The home folder is then added to `PATH`.
create_home() {
    local def_ievms_home="${HOME}/.ievms"
    ievms_home=${INSTALL_PATH:-$def_ievms_home}

    mkdir -p "${ievms_home}"
    cd "${ievms_home}"

    PATH="${PATH}:${ievms_home}"

    # Move ovas and zips from a very old installation into place.
    mv -f ./ova/IE*/IE*.{ova,zip} "${ievms_home}/" 2>/dev/null || true
}

# Check for a supported host system (Linux/OS X).
check_system() {
    kernel=`uname -s`
    case $kernel in
        Darwin|Linux) ;;
        *) fail "Sorry, $kernel is not supported." ;;
    esac
}

# Ensure VirtualBox is installed and `VBoxManage` is on the `PATH`.
check_virtualbox() {
    log "Checking for VirtualBox"
    hash VBoxManage 2>&- || fail "VirtualBox command line utilities are not installed, please (re)install! (http://virtualbox.org)"
}

# Determine the VirtualBox version details, querying the download page to ensure
# validity.
check_version() {
    local version=`VBoxManage -v`
    major_minor_release="${version%%[-_r]*}"
    local major_minor="${version%.*}"
    local dl_page=`curl ${curl_opts} -L "http://download.virtualbox.org/virtualbox/" 2>/dev/null`

    if [[ "$version" == *"kernel module is not loaded"* ]]; then
        fail "$version"
    fi

    for (( release="${major_minor_release#*.*.}"; release >= 0; release-- ))
    do
        major_minor_release="${major_minor}.${release}"
        if echo $dl_page | grep "${major_minor_release}/" &>/dev/null
        then
            log "Virtualbox version ${major_minor_release} found."
            break
        else
            log "Virtualbox version ${major_minor_release} not found, skipping."
        fi
    done
}

# Check for the VirtualBox Extension Pack and install if not found.
check_ext_pack() {
    log "Checking for Oracle VM VirtualBox Extension Pack"
    if ! VBoxManage list extpacks | grep "Oracle VM VirtualBox Extension Pack"
    then
        check_version
        local archive="Oracle_VM_VirtualBox_Extension_Pack-${major_minor_release}.vbox-extpack"
        local url="http://download.virtualbox.org/virtualbox/${major_minor_release}/${archive}"
        local md5s="https://www.virtualbox.org/download/hashes/${major_minor_release}/MD5SUMS"
        local md5=`curl ${curl_opts} -L "${md5s}" | grep "${archive}" | cut -c-32`

        download "Oracle VM VirtualBox Extension Pack" "${url}" "${archive}" "${md5}"

        log "Installing Oracle VM VirtualBox Extension Pack from ${ievms_home}/${archive}"
        VBoxManage extpack install "${archive}" || fail "Failed to install Oracle VM VirtualBox Extension Pack from ${ievms_home}/${archive}, error code ($?)"
    fi
}

# Download and install `unar` from Google Code.
install_unar() {
    local url="https://cdn.theunarchiver.com/downloads/unarMac.zip"
    local archive=`basename "${url}"`

    download "unar" "${url}" "${archive}" "91796924b1b21ee586ed904b319bb447"

    unzip "${archive}" || fail "Failed to extract ${ievms_home}/${archive} to ${ievms_home}/, unzip command returned error code $?"

    hash unar 2>&- || fail "Could not find unar in ${ievms_home}"
}

# Check for the `unar` command, downloading and installing it if not found.
check_unar() {
    if [ "${kernel}" == "Darwin" ]
    then
        hash unar 2>&- || install_unar
    else
        hash unar 2>&- || fail "Linux support requires unar (sudo apt-get install for Ubuntu/Debian)"
    fi
}

# Pause execution until the virtual machine with a given name shuts down.
wait_for_shutdown() {
    if [ "${1}" == "IE11 - Win81" ]
    then
        log "Win81 takes some extra time to boot on first run..."
        log "Guest Additions will be attached, but you will have to manually install on first run"
        os_boot_wait="45"
        sleep "${os_boot_wait}"
        VBoxManage controlvm "${1}" acpipowerbutton
    else
        sleep "${os_boot_wait}"
        VBoxManage controlvm "${1}" acpipowerbutton
    fi
    while true ; do
        log "Waiting for ${1} to shutdown..."
        sleep "${sleep_wait}"
        VBoxManage showvminfo "${1}" | grep "State:" | grep -q "powered off" && sleep "${sleep_wait}" && return 0 || true
    done
}

# Attach a dvd image to the virtual machine.
attach() {
    #VirtualBox currently errors when attempting to attach to Win8.1 with 'additions' command passed in, this is a workaround
    if [ "${1}" == "IE11 - Win81" ]
    then
        if [ "${kernel}" == "Darwin" ]
        then
            log "Copying Guest Additions iso to ${ievms_home}"
            cp /Applications/VirtualBox.app/Contents/MacOS/VBoxGuestAdditions.iso "${ievms_home}/"
            log "Attaching ${3}"
            VBoxManage storageattach "${1}" --storagectl "IDE Controller" --port 0 \
                --device 1 --type dvddrive --medium "${ievms_home}/VBoxGuestAdditions.iso"
        fi
        if [ "${kernel}" == "Linux" ]
        then
            log "Copying Guest Additions iso to ${ievms_home}"
            cp /usr/share/virtualbox/VBoxGuestAdditions.iso "${ievms_home}/"
            log "Attaching ${3}"
            VBoxManage storageattach "${1}" --storagectl "IDE Controller" --port 0 \
                --device 1 --type dvddrive --medium "${ievms_home}/VBoxGuestAdditions.iso"
        fi
    else
        log "Attaching ${3}"
        VBoxManage storageattach "${1}" --storagectl "IDE Controller" --port 0 \
            --device 1 --type dvddrive --medium "${2}"
    fi
}

# Eject the dvd image from the virtual machine.
eject() {
    log "Ejecting ${2}"
    VBoxManage modifyvm "${1}" --dvd none
}

# Boot the virtual machine with guest additions in the dvd drive. After running
# `boot_ievms`, the next boot will attempt automatically install guest additions
# if present in the drive. It will shut itself down after installation.
boot_auto_ga() {
    attach "${1}" "additions" "Guest Additions"
    start_vm "${1}"
    wait_for_shutdown "${1}"
}

# Start a virtual machine in headless mode.
start_vm() {
    log "Starting VM ${1}"
    VBoxManage startvm "${1}" --type headless
}

# Build an ievms virtual machine given the IE version desired.
build_ievm() {
    unset archive
    unset unit
    local prefix="IE"
    local version="${1}"
    case $1 in
        8|9|10) os="Win7" ;;
        11)
            if [ "${reuse_win7}" != "yes" ]
            then
                if [ "$1" == "11" ]
                then
                    os="Win81"
                    unit="8"
                fi
            else
                os="Win7"
                archive="IE11.Win7.VirtualBox.zip"
            fi
            ;;
        EDGE)
            prefix="MS"
            version="Edge"
            os="Win10"
            unit="8"
            ;;
        *) fail "Invalid IE version: ${1}" ;;
    esac

    local vm="${prefix}${version} - ${os}"
    local def_archive="${vm/ - /.}.VirtualBox.zip"
    archive=${archive:-$def_archive}
    unit=${unit:-"9"}
    local ova="`basename "${archive/./ - }" .VirtualBox.zip`.ova"

    log "Checking for existing OVA at ${ievms_home}/${ova}"
    local url
    local list_version
    local get_md5
    if [[ ! -f "${ova}" ]]
    then
        case $vm in
            'IE8 - Win7') list_version="0";;
            'IE9 - Win7') list_version="1";;
            'IE10 - Win7') list_version="2";;
            'IE11 - Win7') list_version="3";;
            'IE11 - Win81') list_version="4";;
            'MSEdge - Win10') list_version="5";;
        esac
        # JSON output is different for Edge
        if [ "${list_version}" == "5" ]
        then
            url=$(node -pe "JSON.parse(process.argv[1])["${list_version}"].software[0].files[0].url" "$(curl -s https://developer.microsoft.com/en-us/microsoft-edge/api/tools/vms/)")
            get_md5=$(node -pe "JSON.parse(process.argv[1])[5].software[0].files[0].md5" "$(curl -s https://developer.microsoft.com/en-us/microsoft-edge/api/tools/vms/)")
            log "Grabbing md5 file to parse for md5 string"
            md5=$(curl "${get_md5}" | awk "{print tolower($0)}")
        else
            url=$(node -pe "JSON.parse(process.argv[1])["${list_version}"].software[0].files[1].url" "$(curl -s https://developer.microsoft.com/en-us/microsoft-edge/api/tools/vms/)")
            # md5 url is incorrect on the api itself for every option but Edge
            get_md5=$(node -pe 'JSON.parse(process.argv[1])[5].software[0].files[0].md5.slice(0, 31).concat("vms" + JSON.parse(process.argv[1])[5].software[0].files[0].md5.slice(34,))' "$(curl -s https://developer.microsoft.com/en-us/microsoft-edge/api/tools/vms/)")
            log "Grabbing md5 file to parse for md5 string"
            md5=$(curl "${get_md5}" | awk "{print tolower($0)}")
        fi

        download "OVA ZIP" "${url}" "${archive}" "${md5}"

        log "Extracting OVA from ${ievms_home}/${archive}"
        unar "${archive}" || fail "Failed to extract ${archive} to ${ievms_home}/${ova}, unar command returned error code $?"
    fi

    log "Checking for existing ${vm} VM"
    if ! VBoxManage showvminfo "${vm}" >/dev/null 2>/dev/null
    then
        local disk_path="${vm}-disk1.vmdk"
        log "Creating ${vm} VM (disk: ${disk_path})"
        if [ "${vm}" == "IE11 - Win81" ]
        then
            VBoxManage import "${ova}" --vsys 0 --vmname "${vm}" --unit "${unit}" --disk "${disk_path}"
            VBoxManage modifyvm "IE11 - Win81" --vram "128"
        else
            VBoxManage import "${ova}" --vsys 0 --vmname "${vm}" --unit "${unit}" --disk "${disk_path}"
        fi

        log "Adding shared folder"
        VBoxManage sharedfolder add "${vm}" --automount --name ievms \
            --hostpath "${ievms_home}"

        log "Building ${vm} VM"
        declare -F "build_ievm_ie${1}" && "build_ievm_ie${1}"

        log "Tagging VM with ievms version"
        VBoxManage setextradata "${vm}" "ievms" "{\"version\":\"${ievms_version}\"}"

        log "Creating clean snapshot"
        VBoxManage snapshot "${vm}" take clean --description "The initial VM state"
    fi
}

# Build the IE8 virtual machine, reusing the XP VM if requested (the default).
build_ievm_ie8() {
    boot_auto_ga "IE8 - Win7"
}

# Build the IE9 virtual machine.
build_ievm_ie9() {
    boot_auto_ga "IE9 - Win7"
}

# Build the IE10 virtual machine, reusing the Win7 VM if requested (the default).
build_ievm_ie10() {
    boot_auto_ga "IE10 - Win7"
}

# Build the IE11 virtual machine, reusing the Win7 VM always.
build_ievm_ie11() {
    if [ "${reuse_win7}" != "yes" ]
    then
        boot_auto_ga "IE11 - Win81"
    else
        boot_auto_ga "IE11 - Win7"
    fi
}

# ## Main Entry Point

# Run through all checks to get the host ready for installation.
check_system
create_home
check_virtualbox
check_ext_pack
check_unar

# Install each requested virtual machine sequentially.
all_versions="8 9 10 11 EDGE"
for ver in ${IEVMS_VERSIONS:-$all_versions}
do
    log "Building IE ${ver} VM"
    build_ievm $ver
done

# We made it!
log "Done!"
