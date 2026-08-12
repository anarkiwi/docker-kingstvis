# Releasing

The pinned upstream release is the two `ARG` lines at the top of `Dockerfile`:

    ARG KINGSTVIS_VERSION=3.6.6
    ARG KINGSTVIS_SHA256=3fefb141...

`KINGSTVIS_VERSION` is the single source of truth for the image release version, and names
the tarball at `https://www.qdkingst.com/kfs/KingstVIS_v${KINGSTVIS_VERSION}.tar.gz`, which
is verified against its `SHA256` at build time. Older versions stay on that path, so a pin
keeps building after upstream moves on.

## Workflows

| Workflow | Trigger | Action |
| --- | --- | --- |
| `ci` | pull request, push to main | hadolint, shellcheck, actionlint, build, `tests/smoke.sh` |
| `release` | push to main touching `Dockerfile` or `entrypoint.sh`, manual | build, smoke test, push images, create GitHub release |
| `upstream-bump` | daily 04:41 UTC, manual | open a PR bumping the pin to the current KingstVIS release |

Upstream publishes no API, release feed or checksum — just a download page. `upstream-bump`
resolves the version from the redirect `https://www.qdkingst.com/download/vis_linux` lands
on, which is the versioned tarball, and only when that differs from the pin does it
download the tarball to hash it. It builds and smoke tests the new pin before opening the
PR, because pull requests opened with `GITHUB_TOKEN` do not start workflow runs; the PR
body links the run that tested it.

Because the checksum is computed from whatever is being served rather than compared against
a published one, it pins what upstream served on the day. Review the PR as you would any
other supply chain change.

Dependabot covers the Debian base image and the actions used here; it cannot track a vendor
download page, which is what `upstream-bump` exists for.

Merging a bump PR publishes `X.Y.Z` and `latest`, and creates the matching GitHub release.
Re-running `release` for an existing version refreshes the images (for example after a base
image update or an `entrypoint.sh` change) and leaves the existing GitHub release alone.

## Secrets and variables

| Name | Kind | Required | Purpose |
| --- | --- | --- | --- |
| `GITHUB_TOKEN` | built in | yes | GHCR push, release creation |
| `DOCKERHUB_USERNAME` | secret | no | Docker Hub push |
| `DOCKERHUB_TOKEN` | secret | no | Docker Hub access token; absent disables Docker Hub push |
| `DOCKERHUB_IMAGE` | variable | no | Docker Hub repository, default `anarkiwi/kingstvis` |

No personal access token is needed. Until `DOCKERHUB_TOKEN` is set, `release` pushes to GHCR
only and skips the Docker Hub login and tags.

## Manual release

Edit the `ARG` lines and merge to main, or run the `release` workflow by hand
(`workflow_dispatch`) to rebuild the currently pinned version. To pin a version by hand:

    curl -fsSL -o vis.tar.gz https://www.qdkingst.com/kfs/KingstVIS_v3.6.6.tar.gz
    sha256sum vis.tar.gz

## Testing without an analyzer

`tests/smoke.sh` never touches the host's USB tree: every container it starts gets
`--tmpfs /dev/bus/usb:mode=0777`, so the result does not depend on what is plugged into the
build machine. It also asserts the two failure modes that would otherwise show up as a
segfault or a silent half start — a missing USB bus and an unwritable data directory.
Hardware paths beyond enumeration are not covered; test those with an analyzer attached.
