#!/bin/sh -x
set -e

rm -rf out~
git submodule foreach 'git clean -fdx && git reset --hard'
rm -rf ceph-object-corpus
rm -rf ceph-erasure-code-corpus
rm -rf src/gmock
rm -rf src/leveldb
rm -rf src/libs3
rm -rf src/mongoose
rm -rf src/civetweb
rm -rf src/rocksdb
rm -rf src/erasure-code/jerasure/gf-complete
rm -rf src/erasure-code/jerasure/jerasure
rm -rf .git/modules/
git clean -fdx && git reset --hard
/srv/git/bin/git submodule sync
/srv/autobuild-ceph/use-mirror.sh
/srv/git/bin/git submodule update --init
git clean -fdx

DIST=`lsb_release -sc`

echo --START-IGNORE-WARNINGS
[ ! -x install-deps.sh ] || ./install-deps.sh
[ ! -x autogen.sh ] || ./autogen.sh || exit 1
autoconf || true
echo --STOP-IGNORE-WARNINGS
[ -z "$CEPH_EXTRA_CONFIGURE_ARGS" ] && CEPH_EXTRA_CONFIGURE_ARGS=--with-tcmalloc
[ ! -x configure ] || CFLAGS="-fno-omit-frame-pointer -g -O2" CXXFLAGS="-fno-omit-frame-pointer -g -O2" ./configure --with-debug --with-radosgw --with-fuse --with-libatomic-ops --with-gtk2 --with-profiler --enable-cephfs-java $CEPH_EXTRA_CONFIGURE_ARGS || exit 2

if [ ! -e Makefile ]; then
    echo "$0: no Makefile, aborting." 1>&2
    exit 3
fi

# Actually build the project

# clear out any $@ potentially passed in
set --

# enable ccache if it is installed
export CCACHE_DIR="$PWD/../../ccache"
if command -v ccache >/dev/null; then
  if [ ! -e "$CCACHE_DIR" ]; then
    echo "$0: have ccache but cache directory does not exist: $CCACHE_DIR" 1>&2
  else
    set -- CC='ccache gcc' CXX='ccache g++'
  fi
else
  echo "$0: no ccache found, compiles will be slower." 1>&2
fi

# build the debs
mkdir -p out~
rm -rf out~/* || true
GNUPGHOME="/srv/gnupg" ionice -c3 nice -n20 timeout 2h /srv/ceph-build/build_snapshot_native.sh out~ $DIST

VER=`cat out~/version`
echo "VER is $VER"

REV="$(git rev-parse HEAD)"
OUTDIR="../out/output/sha1/$REV"
OUTDIR_TMP="${OUTDIR}.tmp"
install -d -m0755 -- "$OUTDIR_TMP"
printf '%s\n' "$REV" >"$OUTDIR_TMP/sha1"
printf '%s\n' "$VER" >"$OUTDIR_TMP/version"
printf '%s\n' "ceph" >"$OUTDIR_TMP/name"

mkdir -p $OUTDIR_TMP/conf
/srv/ceph-build/gen_reprepro_conf.sh $OUTDIR_TMP 03C3951A

for f in out~/*.changes
do
    GNUPGHOME="/srv/gnupg" reprepro --ask-passphrase -b $OUTDIR_TMP -C main --ignore=undefinedtarget --ignore=wrongdistribution include $DIST $f
done

if [ "$DIST" = "precise" ]; then
    echo "$0: trying to include backports from /srv/extras-backports..."
    GNUPGHOME="/srv/gnupg" reprepro --ask-passphrase -b $OUTDIR_TMP -C main --ignore=undefinedtarget --ignore=wrongdistribution includedeb $DIST /srv/extras-backports/* || true
fi


rm -rf out~

# we're successful, the files are ok to be published; try to be as
# atomic as possible about replacing potentially existing OUTDIR
if [ -e "$OUTDIR" ]; then
    rm -rf -- "$OUTDIR.old"
    mv -- "$OUTDIR" "$OUTDIR.old"
fi
mv -- "$OUTDIR_TMP" "$OUTDIR"
rm -rf -- "$OUTDIR.old"

# rebuild combined debian repo output
(
    cd ../out/output
    rm -rf combined
    GNUPGHOME="/srv/gnupg" /srv/ceph-build/merge_repos.sh combined sha1/*
)

exit 0
