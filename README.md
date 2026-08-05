# r-sbx

Run Claude Code in a sbx microVM with R (v 4.6.1). There are two options for packages, one accepts a package list as a .txt and the other accepts a project `renv.lock`

## One-time setup

```bash
sbx login
sbx policy set-default balanced        # sbx policy ls to see what that allows
```
Also run `\login` inside the sbx to authenticate with Anthropic.

## Build Docker image

Docker Desktop must be installed and running to build.

```bash
# mode A: the curated list in deps/packages.txt
DOCKER_BUILDKIT=1 docker build --build-arg MODE=packages -t r-sbx:4.6.1-base .

# mode B: a project lockfile
cp ~/projects/llm-extraction/renv.lock deps/
DOCKER_BUILDKIT=1 docker build --build-arg MODE=lockfile -t r-sbx:4.6.1-extraction .

# hand it to the sandbox runtime (which keeps its own image store)
docker image save r-sbx:4.6.1-base -o t.tar && sbx template load t.tar && rm t.tar
```

*Note: the image name can be updated as needed to enable versioning.*

Initial builds may take tens of minutes, but package will be cached to reduce subsequent build time when updating the package list.

## Run

```bash
cd <PROJECT FOLDER>
sbx run -t r-sbx:4.6.1-base claude
```

See and monitor all sandboxes with `sbx`. Stop sandboxes (`sbx stop`) to free RAM and CPU until resuming active work, delete sandboxes (`sbx rm`) to also delete the file system and permanently remove the sandbox.

## Package vs. lockfile mode

**`MODE=packages`** installs into the sandbox library, so the packages are simply
present in every R session — no renv needed. This is the general-purpose template.

Entries are split by type for efficiency. CRAN names go through
`renv::install()`, because renv's cache holds *built* packages. A rebuild through `renv` links packages instead of recompiling, which is what keeps `packages.txt` edits efficient. `owner/repo` entries go through pak, because renv fails on the GitHub (e.g., DARTH) remotes. Unlike `renv`, pak's cache only holds downloaded files, so those packages must recompile every build.

**`MODE=lockfile`** populates the renv cache instead and discards the library.
A project using renv resolves from the cache, so `renv::restore()` inside the sandbox completes by hard-link instead of rebuilding.

Project libraries are redirected inside the VM, to `/home/agent/renv-libraries`,
via `RENV_PATHS_LIBRARY_ROOT`. Left at the default they'd sit under `renv/library/`
in your bind-mounted project — a different filesystem from the cache, so
`renv::restore()` would copy rather than link and drop several GB into the project
directory. `renv.lock` is what persists in the project.

## Image documentation

```bash
sbx exec <name> cat /opt/r-sbx-manifest.txt
```

Documentation includes R version, platform, snapshot URL, base image, and every installed package with its version and source.

## Notes

- **OpenBLAS**, single-threaded, with reference BLAS retained for reversion.
- Tested on **macOS / Apple Silicon**.
- **Base image tag moves.** Pinning `R_VERSION` and `SNAPSHOT` fixes the R side but
  the OS underneath can still drift. `--build-arg BASE=...@sha256:...` if needed.
- **Per project, copy a `CLAUDE.md` into the repo.** Host `~/.claude` isn't imported, and symlinks don't work across the VM boundary.
- **`renv/library/` will look empty on the host** while the sandbox is running. `renv.lock` still updates, so `renv::snapshot()` inside the sandbox shows up in `git diff` as expected.
