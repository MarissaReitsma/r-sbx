#!/usr/bin/env bash
# Install project dependencies, in one of two modes, then record what landed.
#
#   install-deps.sh packages   # deps/packages.txt -> site library
#   install-deps.sh lockfile   # deps/renv.lock    -> renv cache
#
# Why they differ: packages mode puts things in the site library so they're
# present in every R session with no renv involvement. Lockfile mode populates
# the renv cache instead, because a project using renv resolves from the cache —
# `renv::restore()` inside the sandbox then completes by hard-link rather than
# rebuilding. Installing a lockfile into the site library would help nobody.
set -euo pipefail

MODE="${1:-packages}"
R_VERSION="${R_VERSION:?set R_VERSION}"
DEPS_DIR="${DEPS_DIR:-/tmp/deps}"

R_ROOT="/opt/R/${R_VERSION}"
SITE_LIB="${R_ROOT}/lib/R/site-library"

# During a Docker build this points at a BuildKit cache mount, so previously
# built packages are linked rather than recompiled. CACHE_OUT is where the cache
# gets persisted into the image (lockfile mode only).
export RENV_PATHS_CACHE="${RENV_PATHS_CACHE:-/opt/renv/cache}"
CACHE_OUT="${CACHE_OUT:-/opt/renv/cache}"
MANIFEST="${MANIFEST:-/opt/r-sbx-manifest.txt}"

mkdir -p "${RENV_PATHS_CACHE}" "${SITE_LIB}"

case "${MODE}" in
  packages)
    src="${DEPS_DIR}/packages.txt"
    [ -f "${src}" ] || { echo "install-deps: missing ${src}" >&2; exit 1; }

    Rscript - "${src}" "${SITE_LIB}" <<'RS'
args <- commandArgs(TRUE)
spec <- args[[1]]; lib <- args[[2]]

lines <- readLines(spec, warn = FALSE)
lines <- trimws(sub("#.*$", "", lines))
pkgs  <- lines[nzchar(lines)]
if (!length(pkgs)) stop("install-deps: packages.txt has no entries")

message("install-deps: ", length(pkgs), " requested -> ", paste(pkgs, collapse = ", "))

# Split by entry type. This is not cosmetic:
#
#   renv's cache holds *built* packages, so a rebuild links instead of
#   recompiling — that's what makes editing packages.txt cheap. pak's cache holds
#   downloaded files, which on a source-only platform saves a fetch and nothing
#   more. So CRAN entries go through renv.
#
#   But renv fails on the DARTH GitHub remotes, and pak handles them without
#   complaint. They're pure R with dependencies already installed by the CRAN
#   step, so pak rebuilding them every time costs seconds, not minutes.
is_remote <- grepl("/", pkgs, fixed = TRUE)
cran      <- pkgs[!is_remote]
remotes   <- pkgs[is_remote]

if (length(cran)) {
  message("install-deps: ", length(cran), " via renv (cached): ",
          paste(cran, collapse = ", "))
  ok <- tryCatch({
    renv::install(cran, library = lib, prompt = FALSE)
    TRUE
  }, error = function(e) {
    message("install-deps: renv::install failed: ", conditionMessage(e))
    FALSE
  })
  # Fallback keeps the build alive, but loses the incremental-rebuild benefit —
  # if you see this line, every subsequent build recompiles the tree.
  if (!ok) {
    message("install-deps: WARNING falling back to pak for CRAN packages; ",
            "rebuilds will not be incremental")
    pak::pkg_install(cran, lib = lib, ask = FALSE)
  }
}

if (length(remotes)) {
  message("install-deps: ", length(remotes), " via pak (remotes): ",
          paste(remotes, collapse = ", "))
  pak::pkg_install(remotes, lib = lib, ask = FALSE)
}

missing <- setdiff(
  vapply(strsplit(sub("@.*$", "", pkgs), "/"), function(p) p[[length(p)]], ""),
  rownames(installed.packages(lib.loc = lib))
)
if (length(missing)) {
  stop("install-deps: not installed: ", paste(missing, collapse = ", "))
}
RS
    ;;

  lockfile)
    src="${DEPS_DIR}/renv.lock"
    [ -f "${src}" ] || { echo "install-deps: missing ${src} (pass MODE=packages, or add a lockfile)" >&2; exit 1; }

    Rscript - "${src}" <<'RS'
lock <- commandArgs(TRUE)[[1]]
message("install-deps: restoring ", lock)
# Into a throwaway library: the point is to populate RENV_PATHS_CACHE, which is
# what the project's own renv::restore() will link against later.
renv::restore(lockfile = lock, library = tempfile(), prompt = FALSE)
RS

    if [ "${RENV_PATHS_CACHE}" != "${CACHE_OUT}" ]; then
      echo "install-deps: copying cache into image (${CACHE_OUT})"
      mkdir -p "${CACHE_OUT}"
      cp -a "${RENV_PATHS_CACHE}/." "${CACHE_OUT}/"
    fi
    ;;

  *)
    echo "install-deps: unknown mode '${MODE}' (expected 'packages' or 'lockfile')" >&2
    exit 1
    ;;
esac

# ------------------------------------------------------------------- manifest
# Unpinned GitHub entries resolve to whatever HEAD was at build time, so record
# the commit. Without this the template is unattributable.
Rscript - "${SITE_LIB}" "${MANIFEST}" "${MODE}" <<'RS'
args <- commandArgs(TRUE)
lib <- args[[1]]; out <- args[[2]]; mode <- args[[3]]

fields <- c("Version", "RemoteType", "RemoteUsername", "RemoteRepo",
            "RemoteRef", "RemoteSha")

describe <- function(p, lib) {
  d <- suppressWarnings(packageDescription(p, lib.loc = lib, fields = fields))
  get1 <- function(k) if (is.na(d[[k]])) NA_character_ else d[[k]]
  src <- if (!is.na(get1("RemoteType")) && !is.na(get1("RemoteRepo"))) {
    sha <- get1("RemoteSha")
    sprintf("%s:%s/%s@%s",
            get1("RemoteType"), get1("RemoteUsername"), get1("RemoteRepo"),
            if (is.na(sha)) "unknown" else substr(sha, 1, 12))
  } else {
    "cran"
  }
  sprintf("%-28s %-14s %s", p, get1("Version"), src)
}

libs <- unique(c(lib, .libPaths()))
pkgs <- sort(unique(unlist(lapply(libs, function(l) rownames(installed.packages(lib.loc = l))))))

header <- c(
  "# r-sbx template manifest",
  sprintf("built              %s", format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")),
  sprintf("mode               %s", mode),
  sprintf("R                  %s", getRversion()),
  sprintf("platform           %s", R.version$platform),
  sprintf("cran snapshot      %s", getOption("repos")[["CRAN"]]),
  sprintf("base image         %s", Sys.getenv("BASE_IMAGE", "unrecorded")),
  sprintf("renv cache         %s", Sys.getenv("RENV_PATHS_CACHE", "unset")),
  "",
  sprintf("%-28s %-14s %s", "package", "version", "source"),
  strrep("-", 70)
)

body <- vapply(pkgs, function(p) {
  hit <- Filter(function(l) p %in% rownames(installed.packages(lib.loc = l)), libs)
  describe(p, hit[[1]])
}, "")

writeLines(c(header, body), out)
message("install-deps: manifest -> ", out, " (", length(pkgs), " packages)")
RS

chown -R agent:agent "${SITE_LIB}" "${CACHE_OUT}" "${MANIFEST}" 2>/dev/null || true

echo "install-deps: done (mode=${MODE})"