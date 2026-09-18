#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
  echo "Usage: build-cygwin.sh SANE_TARBALL XSANE_TARBALL PREFIX CONFIG_DIR" >&2
  exit 64
fi

sane_tar="$1"
xsane_tar="$2"
prefix="$3"
config_source="$4"
work_dir="$(dirname "$sane_tar")/build-1.4.0-0.999"
config_dir="$prefix/etc/sane.d"

mkdir -p "$work_dir"
if [ ! -d "$work_dir/backends-1.4.0" ]; then tar -xzf "$sane_tar" -C "$work_dir"; fi
if [ ! -d "$work_dir/xsane-0.999" ]; then tar -xzf "$xsane_tar" -C "$work_dir"; fi

sane_src="$(find "$work_dir" -maxdepth 1 -type d -name 'backends-1.4.0' -print -quit)"
xsane_src="$(find "$work_dir" -maxdepth 1 -type d -name 'xsane-0.999' -print -quit)"

if [ -z "$sane_src" ] || [ -z "$xsane_src" ]; then
  echo "Expected fixed SANE 1.4.0 and XSane 0.999 source trees were not found." >&2
  exit 65
fi

if [ "$prefix" != /opt/genius-hr7 ]; then
  echo 'Unexpected installation prefix' >&2
  exit 64
fi
cd "$sane_src"
printf '%s\n' '1.4.0' > .tarball-version
if [ ! -f configure ]; then bash ./autogen.sh; fi
# The fork-based Cygwin/WinUSB build stalled in usbDev_PrepareScan on this
# HR7; the pthread build completed an observed scan. Keep the USB reader
# in the same process, and reconfigure older builds that selected fork.
if [ ! -f config.status ] || ! grep -q '^#define USE_PTHREAD ' include/sane/config.h; then
  ./configure \
    --prefix="$prefix" \
    --sysconfdir="$prefix/etc" \
    --with-usb=yes \
    --enable-pthread \
    BACKENDS="plustek"
else
  echo 'Resuming the previously configured SANE USB pthread build.'
fi
# SANE 1.4.0 overrides --enable-pthread when pthread_t is non-integer,
# except on macOS. Cygwin uses pointer handles, supported by the thread
# helper paths used by this Plustek-only build. This is the same override
# used by the locally verified pthread build. Cygwin provides these native
# pthread functions in its runtime, so no extra pthread DLL is required.
if [[ "$(uname -s)" == CYGWIN* ]] && ! grep -q '^#define USE_PTHREAD ' include/sane/config.h; then
  for feature in HAVE_PTHREAD_H HAVE_PTHREAD_CREATE HAVE_PTHREAD_JOIN HAVE_PTHREAD_CANCEL; do
    if ! grep -q "^#define $feature 1$" include/sane/config.h; then
      echo "Required Cygwin thread feature missing: $feature" >&2
      exit 66
    fi
  done
  sed -i 's@^/\* #undef USE_PTHREAD \*/$@#define USE_PTHREAD 1@' include/sane/config.h
fi
if ! grep -q '^#define USE_PTHREAD ' include/sane/config.h; then
  echo 'SANE pthread support is required for this Cygwin/WinUSB package.' >&2
  exit 66
fi

# SANE 1.4.0 selects its legacy Windows SCSI implementation on Cygwin, where
# its HANDLE values do not fit the implementation's int file descriptors. This
# package builds only the USB Plustek backend, so disable that unused SCSI API.
if [[ "$(uname -s)" == CYGWIN* ]]; then
  if grep -q '^#define HAVE_NTDDSCSI_H 1$' include/sane/config.h; then
    sed -i 's/^#define HAVE_NTDDSCSI_H 1$/\/\* #undef HAVE_NTDDSCSI_H \*\//' include/sane/config.h
  fi
  if grep -q '^#define HAVE_NTDDSCSI_H 1$' include/sane/config.h; then
    echo 'Could not disable unused SCSI support for the Cygwin USB-only build.' >&2
    exit 66
  fi
  if grep -q '^#ifdef WIN32$' sanei/sanei_scsi.c; then
    sed -i '1588s/^#ifdef WIN32$/#if defined(WIN32) \&\& !defined(__CYGWIN__)/' sanei/sanei_scsi.c
  fi
  if ! grep -q 'HR7 Cygwin USB-only SCSI guard' sanei/sanei_scsi.c; then
    sed -i '/^#ifndef USE$/i\
/* HR7 Cygwin USB-only SCSI guard */\
#ifdef __CYGWIN__\
# undef USE\
#endif' sanei/sanei_scsi.c
  fi
fi
make
make install

for config_file in dll.conf plustek.conf saned.conf; do
  if [ ! -f "$config_source/$config_file" ]; then
    echo "Required SANE configuration is missing: $config_source/$config_file" >&2
    exit 67
  fi
done
mkdir -p "$config_dir"
install -m 0644 "$config_source/dll.conf" "$config_dir/dll.conf"
install -m 0644 "$config_source/plustek.conf" "$config_dir/plustek.conf"
install -m 0644 "$config_source/saned.conf" "$config_dir/saned.conf"

cd "$xsane_src"
sed -i 's/png_ptr->jmpbuf/png_jmpbuf(png_ptr)/g' src/xsane-save.c
# XSane 0.999 predates C23 and its configure probes use system()/exit()
# without including stdlib.h. Pin the language level so modern GCC accepts
# those legacy probes, and keep the private SANE DLLs on Windows' DLL search
# path while configuring, building, and launching the frontend.
export CFLAGS="${CFLAGS:-} -std=gnu89"
export PATH="$prefix/bin:$prefix/lib:$prefix/lib/sane:$PATH"
export LD_LIBRARY_PATH="$prefix/lib:$prefix/lib/sane${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export SANE_CONFIG_DIR="$config_dir"
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig:$prefix/lib64/pkgconfig"
./configure --prefix="$prefix" --disable-nls
make
make install

cat > "$prefix/bin/launch-xsane.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export PATH="$prefix/bin:$prefix/lib:$prefix/lib/sane:/usr/bin"
export SANE_CONFIG_DIR="$config_dir"
exec "$prefix/bin/xsane"
EOF
chmod 0755 "$prefix/bin/launch-xsane.sh"

"$prefix/bin/scanimage" -V
echo "Build completed: backend plustek only; SANE and saned configuration at $config_dir"
