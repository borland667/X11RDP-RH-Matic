#!/bin/sh
# vim:ts=2:sw=2:sts=0

if [ $UID -eq 0 ] ; then
	echo "${0}:  Never run this utility as root."
	echo
	echo "This utility builds RPMs. Building RPM's as root is seriously dangerous."
	echo "This script will gain root privileges via sudo on demand, then type your password."
	exit 1
fi

if ! hash sudo ; then
	echo "${0}: sudo not found."
	echo
	echo 'This utility requires sudo to gain root privileges on demand.'
	echo 'run `yum -y install sudo` in root privileges before run this utility.'
	exit 1
fi

LINE="----------------------------------------------------------------------"

PATH=/bin:/sbin:/usr/bin:/usr/sbin

# xrdp repository
GH_ACCOUNT=neutrinolabs
GH_PROJECT=xrdp
GH_BRANCH=master
GH_URL=https://github.com/${GH_ACCOUNT}/${GH_PROJECT}.git

WRKDIR=$(mktemp --directory)
YUM_LOG=${WRKDIR}/yum.log
BUILD_LOG=${WRKDIR}/build.log
RPMS_DIR=$(rpm --eval %{_rpmdir}/%{_arch})


# variables for this utility
TARGETS="xrdp"
META_DEPENDS="dialog rpm-build rpmdevtools"
FETCH_DEPENDS="ca-certificates git wget"
EXTRA_SOURCE="xrdp.init xrdp.sysconfig xrdp.logrotate xrdp-pam-auth.patch buildx_patch.diff"
XRDP_BUILD_DEPENDS="autoconf automake libtool openssl-devel pam-devel libX11-devel libXfixes-devel libXrandr-devel fuse-devel which"
XRDP_CONFIGURE_ARGS="--enable-fuse"

# xorg driver
XORG_DRIVER_DEPENDS=$(<SPECS/xorg-x11-drv-rdp.spec.in grep Requires: | grep -v %% | awk '{ print $2 }')


error_exit() {
	echo
	echo 'Oops, something going wrong. exitting...'
	exit 1
}

install_depends() {
	for f in $@; do
		echo -n "Checking for ${f}... "
		check_if_installed $f
		if [ $? -eq 0 ]; then
			echo "yes"
			if [ $f = "wget" ]; then
				echo -n "Updating ${f}... "
				sudo yum -y update $f >> $YUM_LOG || error_exit
				echo "done"
			fi
		else
			echo "no"
			echo -n "Installing $f... "
			sudo yum -y install $f >> $YUM_LOG && echo "done" || error_exit
		fi
		sleep 0.1
	done
}

check_if_installed() {
	if [ "$(repoquery --all --installed --qf="%{name}" "$1")" = "$1" ]; then
		return 0
	else
		return 1
	fi
}

calculate_version_num()
{
	echo -n 'Calculating RPM version number... '
	GH_COMMIT=$(git ls-remote --heads $GH_URL | grep $GH_BRANCH | head -c7)
	README=https://raw.github.com/${GH_ACCOUNT}/${GH_PROJECT}/${GH_BRANCH}/readme.txt
	TMPFILE=$(mktemp)
	wget --quiet -O $TMPFILE $README  || error_exit
	VERSION=$(grep xrdp $TMPFILE | head -1 | cut -d " " -f2)
	if [ "$(echo $VERSION | cut -c1)" != 'v' ]; then
		VERSION=${VERSION}.git${GH_COMMIT}
	fi
	rm -f $TMPFILE
	echo $VERSION
}

generate_spec()
{
	calculate_version_num
	calc_cpu_cores
	echo -n 'Generating RPM spec files... '

	#read # DEBUG
	#echo SPECS/*.spec.in #DEBUG

	# replace common variables in spec templates
	for f in SPECS/*.spec.in
	do
		sed \
		-e "s/%%XRDPVER%%/${VERSION}/g" \
		-e "s/%%XRDPBRANCH%%/${GH_BRANCH}/g" \
		-e "s/%%GH_ACCOUNT%%/${GH_ACCOUNT}/g" \
		-e "s/%%GH_PROJECT%%/${GH_PROJECT}/g" \
		-e "s/%%GH_COMMIT%%/${GH_COMMIT}/g" \
		< $f > $(echo $f | sed 's|.in$||') || error_exit
	done

	sed -i.bak \
	-e "s/%%BUILDREQUIRES%%/${XORG_DRIVER_BUILD_DEPENDS}/" \
	SPECS/xorg-x11-drv-rdp.spec || error_exit

	sed -i.bak \
	-e "s/%%BUILDREQUIRES%%/${XRDP_BUILD_DEPENDS}/g" \
	-e "s/%%CONFIGURE_ARGS%%/${XRDP_CONFIGURE_ARGS}/g" \
	SPECS/xrdp.spec ||  error_exit

	echo 'done'
}

fetch() {
	DISTDIR=$(rpm --eval '%{_sourcedir}')
	DISTFILE=${GH_ACCOUNT}-${GH_PROJECT}-${GH_COMMIT}.tar.gz
	echo -n 'Fetching source code... '
	if [ ! -f ${DISTDIR}/${DISTFILE} ]; then
		wget \
			--quiet \
			--output-document=${DISTDIR}/${DISTFILE} \
			https://codeload.github.com/${GH_ACCOUNT}/${GH_PROJECT}/legacy.tar.gz/${GH_COMMIT} && \
		echo 'done'
	else
		echo 'already exists'
	fi
}

rpmdev_setuptree()
{
	echo -n 'Setting up rpmbuild tree... '
	rpmdev-setuptree && \
	echo 'done'
}

build_rpm()
{
	echo 'Building RPMs started, please be patient... '
	for f in $EXTRA_SOURCE; do
		cp SOURCES/${f} $DISTDIR
	done

	for f in $TARGETS; do
		echo -n "Building ${f}..."
		if [ "$f" = "xrdp" ]; then
			QA_RPATHS=$[0x0001] rpmbuild -ba SPECS/${f}.spec >> $BUILD_LOG 2>&1 || error_exit
		else
			rpmbuild -ba SPECS/${f}.spec >> $BUILD_LOG 2>&1 || error_exit
		fi
		echo 'done'
	done
}

parse_commandline_args()
{
	# If first switch = --help, display the help/usage message then exit.
	if [ "$1" = "--help" ]
	then
		clear
		echo "usage: $0 OPTIONS
OPTIONS
-------
  --help             : show this help.
  --branch <branch>  : use one of the available xrdp branches listed above...
                       Examples:
                       --branch v0.8    - use the 0.8 branch.
                       --branch master  - use the master branch. <-- Default if no --branch switch used.
                       --branch devel   - use the devel branch (Bleeding Edge - may not work properly!)
                       Branches beginning with \"v\" are stable releases.
                       The master branch changes when xrdp authors merge changes from the devel branch.
  --nocpuoptimize    : do not change X11rdp build script to utilize more than 1 of your CPU cores.
  --cleanup          : remove X11rdp / xrdp source code after installation. (Default is to keep it).
  --noinstall        : do not install anything, just build the packages
  --withjpeg         : include jpeg module
  --with-xorg-driver : build and install xorg-driver"
		get_branches
		exit
	fi

	while [ $# -gt 0 ]; do
	case "$1" in
	--branch)
		get_branches
		if [ $(expr "$BRANCHES" : ".*${2}.*") -ne 0 ]; then
			GH_BRANCH=$2
		else
			echo "**** Error detected in branch selection. Argument after --branch was : $2 ."
			echo "**** Available branches : "$BRANCHES
			exit 1
		fi
		echo "Using branch ==>> $GH_BRANCH <<=="
		if [ $GH_BRANCH = 'devel' ]; then
			echo "Note : using the bleeding-edge version may result in problems :)"
		fi
		echo $LINE
		shift
		;;

	--noinstall)
		NOINSTALL=1
		shift
		;;

	--with-xorg-driver)
		TARGETS="$TARGETS xorg-x11-drv-rdp"
		shift
		;;

	--withjpeg)
		CONFIGURE_ARGS="$CONFIGURE_ARGS --enable-jpeg"
		XRDP_BUILD_DEPENDS="$XRDP_BUILD_DEPENDS libjpeg-devel"
		shift
		;;
	esac
	shift
	done
}

get_branches()
{
	echo $LINE
	echo "Obtaining list of available branches..."
	echo $LINE
	BRANCHES=$(git ls-remote --heads $GH_URL | cut -f2 | cut -d "/" -f 3)
	echo $BRANCHES
	echo $LINE
}

calc_cpu_cores()
{
	Cores=`grep -c ^processor /proc/cpuinfo`
	jobs=$(expr $Cores \* 2)
	makeCommand="make -j $jobs"
}

remove_installed_xrdp()
{
	[ "$NOINSTALL" = "1" ] && return

	# uninstall xrdp first if installed
	for f in $TARGETS ; do
		echo -n "Removing installed $f... "
			check_if_installed $f
			if [ $? -eq 0 ]; then
				sudo yum -y remove $f >>  $YUM_LOG || error_exit
			fi
		echo "done"
	done
}

install_built_xrdp()
{
	[ "$NOINSTALL" = "1" ] && return

	RPM_VERSION_SUFFIX=$(rpm --eval -${VERSION}+${GH_BRANCH}-1%{?dist}.%{_arch}.rpm)

	for f in $TARGETS ; do
		echo -n "Installing built $f... "
		sudo yum -y localinstall \
			${RPMS_DIR}/${f}${RPM_VERSION_SUFFIX} \
			>> $YUM_LOG && echo "done" || error_exit
	done
}

#
#  main routines
#

parse_commandline_args $@

# first of all, check if yum-utils installed
echo 'First of all, checking for necessary programs to run this script... '
echo -n 'Checking for yum-utils... '
if hash repoquery; then
	echo 'yes'
else
	echo 'no'
	echo -n 'Installing yum-utils... '
	sudo yum -y install yum-utils >> $YUM_LOG && echo "done" || exit 1
fi

install_depends $META_DEPENDS $FETCH_DEPENDS
rpmdev_setuptree
generate_spec
fetch
install_depends $XRDP_BUILD_DEPENDS $X11RDP_BUILD_DEPENDS $XORG_DRIVER_DEPENDS
build_rpm
remove_installed_xrdp
install_built_xrdp
