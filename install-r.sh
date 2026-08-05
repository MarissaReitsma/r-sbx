#!/usr/bin/env bash
# Install a pinned R and the base R packages. This is the slow, stable half of
# the build — it only reruns when R_VERSION or apt.txt changes.
#
# Also runnable standalone inside a sandbox, if you'd rather snapshot than build:
#   sbx exec -u root <sandbox> env R_VERSION=4.6.1 SNAPSHOT=2026-08-01 \
#     DEPS_DIR=/path/to/deps bash /path/to/install-r.sh
set -euo pipefail

R_VERSION="${R_VERSION:?set R_VERSION}"
SNAPSHOT="${SNAPSHOT:?set SNAPSHOT (a Posit Package Manager date, YYYY-MM-DD)}"
DEPS_DIR="${DEPS_DIR:-/tmp/deps}"

export DEBIAN_FRONTEND=noninteractive

R_ROOT="/opt/R/${R_VERSION}"
R_HOME_DIR="${R_ROOT}/lib/R"
SITE_LIB="${R_HOME_DIR}/site-library"

# ---------------------------------------------------------------- system libs
apt-get update
apt-get install -y --no-install-recommends \
  build-essential \
  gfortran \
  ca-certificates \
  curl \
  libopenblas-dev \
  locales

# Generate a UTF-8 locale. Without this R runs in the C locale, where string
# collation is bytewise and UTF-8 handling in text fields is fragile — which
# shows up as mangled accented characters and locale-dependent sort order.
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8 2>/dev/null || true

# apt.txt exists because pak's system-requirements lookup may not recognise a
# non-LTS Ubuntu. Anything it misses goes in there.
if [ -f "${DEPS_DIR}/apt.txt" ]; then
  extra="$(sed -e 's/#.*$//' -e '/^[[:space:]]*$/d' "${DEPS_DIR}/apt.txt" | tr '\n' ' ')"
  if [ -n "${extra// /}" ]; then
    echo "install-r: apt.txt -> ${extra}"
    # shellcheck disable=SC2086
    apt-get install -y --no-install-recommends ${extra}
  fi
fi

# ------------------------------------------------------------------------- R
# Posit's distro-agnostic build (glibc >= 2.34). The sandbox base images sit on
# a non-LTS Ubuntu that CRAN's apt repo doesn't publish for; this covers both
# amd64 and arm64 without depending on the distro codename.
arch="$(dpkg --print-architecture)"
deb="r-${R_VERSION}_1_${arch}.deb"
curl -fsSLO "https://cdn.posit.co/r/manylinux_2_34/pkgs/${deb}"
apt-get install -y --no-install-recommends "./${deb}"
rm -f "${deb}"

ln -sf "${R_ROOT}/bin/R"       /usr/local/bin/R
ln -sf "${R_ROOT}/bin/Rscript" /usr/local/bin/Rscript

# ------------------------------------------------------------------------ BLAS
# This R ships its own reference BLAS as libRblas.so, so `update-alternatives`
# on the system BLAS has no effect — the supported route for these builds is to
# repoint libRblas.so itself. Reference BLAS is slow for the repeated matrix
# multiplication in cohort-model traces.
#
# To revert: restore libRblas.so.reference over the symlink.
triplet="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || gcc -dumpmachine)"
openblas="/usr/lib/${triplet}/openblas-pthread/libopenblas.so"
if [ -e "${openblas}" ]; then
  ( cd "${R_HOME_DIR}/lib" \
    && cp -a libRblas.so libRblas.so.reference \
    && ln -sf "${openblas}" libRblas.so )
  echo "install-r: BLAS -> ${openblas}"
else
  echo "install-r: OpenBLAS not found at ${openblas}, keeping reference BLAS" >&2
fi

# ------------------------------------------------------------- site-wide config
# Pinned snapshot, parallel installs, and the user-agent header that lets Posit
# Package Manager serve Linux binaries where it has them (it likely won't for
# this distro/arch, but it costs nothing to ask).
cat > "${R_HOME_DIR}/etc/Rprofile.site" <<EOF
options(repos = c(CRAN = "https://packagemanager.posit.co/cran/${SNAPSHOT}"))
options(Ncpus = max(1L, parallel::detectCores()))
options(HTTPUserAgent = sprintf(
  "R/%s R (%s)",
  getRversion(),
  paste(getRversion(), R.version["platform"], R.version["arch"], R.version["os"])
))
EOF

# Renviron.site rather than a shell profile: R picks this up however it was
# launched, which matters because `sbx exec` runs commands without a login shell.
# The ${VAR-default} form leaves an externally-set value alone, so the build can
# redirect the cache to a BuildKit mount.
cat >> "${R_HOME_DIR}/etc/Renviron.site" <<'EOF'
LANG=${LANG-en_US.UTF-8}
OPENBLAS_NUM_THREADS=${OPENBLAS_NUM_THREADS-1}
RENV_PATHS_CACHE=${RENV_PATHS_CACHE-/opt/renv/cache}
RENV_PATHS_LIBRARY_ROOT=${RENV_PATHS_LIBRARY_ROOT-/home/agent/renv-libraries}
EOF

# Project libraries live inside the VM, not under the bind-mounted project.
# Two reasons: hard links only work within a filesystem, so a library on the
# host mount forces renv::restore() to copy from the cache instead of linking —
# several GB landing in your project directory. And the library is disposable
# anyway; renv.lock is the artifact worth keeping.
mkdir -p /opt/renv/cache /home/agent/renv-libraries "${SITE_LIB}"
chown -R agent:agent /home/agent/renv-libraries

# --------------------------------------------------------------- base packages
# renv, so the agent can record what it installs and restore lockfiles.
Rscript -e "install.packages('renv', lib = '${SITE_LIB}')"

# pak, for the agent to resolve system dependencies mid-session. Prefer r-lib's
# prebuilt binary; fall back to source if there's no build for this platform.
Rscript - "${SITE_LIB}" <<'RS'
lib <- commandArgs(TRUE)[[1]]
from_binary <- tryCatch({
  repo <- sprintf(
    "https://r-lib.github.io/p/pak/stable/%s/%s/%s",
    .Platform$pkgType, R.version$os, R.version$arch
  )
  install.packages("pak", lib = lib, repos = repo)
  requireNamespace("pak", lib.loc = lib, quietly = TRUE)
}, error = function(e) FALSE, warning = function(w) FALSE)

if (!isTRUE(from_binary)) {
  message("install-r: no pak binary for this platform, building from source")
  install.packages("pak", lib = lib)
}
if (!requireNamespace("pak", lib.loc = lib, quietly = TRUE)) {
  stop("install-r: pak failed to install")
}
RS

# languageserver, so an attached editor works. Cheap, and harmless if unused.
Rscript -e "install.packages('languageserver', lib = '${SITE_LIB}')"

chown -R agent:agent /opt/renv "${SITE_LIB}"

apt-get clean
rm -rf /var/lib/apt/lists/*

"${R_ROOT}/bin/R" --version | head -n 1
echo "install-r: done (site library ${SITE_LIB})"