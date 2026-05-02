# dotnetworkqueue-ci

Multi-SDK .NET CI image for [`blehnen/DotNetWorkQueue`](https://github.com/blehnen/DotNetWorkQueue).

Bakes in:

- .NET 10 SDK (from `mcr.microsoft.com/dotnet/sdk:10.0`)
- .NET 8 SDK side-by-side (DotNetWorkQueue's Dashboard projects target `net8.0`)
- OpenJDK 21 JRE (the Jenkins inbound-agent JNLP loader)
- `git`, `curl`, `openssh-client`, `procps`, `libsqlite3-0`
- `libdl.so` symlink workaround for System.Data.SQLite on glibc ≥ 2.34

Companion to [`blehnen/jenkins-with-docker`](https://github.com/blehnen/jenkins-with-docker)
(controller) and [`blehnen/jenkins-agent-with-docker`](https://github.com/blehnen/jenkins-agent-with-docker)
(generic build agent + Docker CLI). This image is the **workload**
that `agent { docker { image '...' } }` Jenkinsfiles spin up — not a
Jenkins inbound agent itself.

## Why this exists

DotNetWorkQueue's Jenkins build needs a multi-SDK environment plus a
Java runtime plus a SQLite native loader workaround. The public
`mcr.microsoft.com/dotnet/sdk` image carries one SDK and no JDK. We were
hand-building this image directly on the Unraid host with
`docker build -t dotnetworkqueue-ci:latest .` and the local image kept
disappearing across host reboots — Jenkins would then fall back to
pulling from Docker Hub, hit a 404, and queue the build forever.

Publishing means Jenkins can use a normal pull strategy
("Pull once and update latest") and no longer cares whether the host
has a stashed copy.

## Image

```
blehnen74/dotnetworkqueue-ci:weekly             # tracks main, current SDKs
blehnen74/dotnetworkqueue-ci:latest             # alias for :weekly
blehnen74/dotnetworkqueue-ci:weekly-YYYYMMDD    # weekly rebuild snapshot
blehnen74/dotnetworkqueue-ci:vX.Y.Z             # tagged pin (optional)
```

`linux/amd64` only. The consuming Jenkins host is x86_64 — adding
`linux/arm64` is a one-line `platforms:` change in `publish.yml` if a
future build node ever needs it.

## Usage in Jenkins

In the Docker Cloud plugin's Agent Template:

| Field | Value |
|---|---|
| Docker Image | `blehnen74/dotnetworkqueue-ci:weekly` |
| Pull strategy | `Pull once and update latest` |
| Labels | `docker` *(matches `agent { label 'docker' }` in DotNetWorkQueue's Jenkinsfile)* |
| Remote File System Root | `/home/jenkins` |

The image does **not** ship a Docker CLI. If a future Jenkinsfile stage
needs to call `docker build` from inside the container, either:
- swap to `blehnen74/jenkins-agent-with-docker` for that stage, or
- add `docker-ce-cli` to this image's Dockerfile and rebuild.

## Build cadence

`publish.yml` runs:

- on every push to `main` (rebuild on Dockerfile change)
- weekly on Monday 06:00 UTC (picks up SDK patches + Debian CVEs)
- on `v*` tags (a stable pin for anyone who doesn't want auto-updates)
- on demand via `workflow_dispatch`

## Updating SDKs

The .NET 10 SDK floats with the `mcr.microsoft.com/dotnet/sdk:10.0`
base image; weekly rebuilds pull whatever the latest patch is.

The .NET 8 SDK is installed via `dotnet-install.sh --channel 8.0` so
it tracks the latest 8.0.x at rebuild time. To pin a specific version,
swap `--channel 8.0` for `--version 8.0.NNN` in the Dockerfile.

To bump the .NET 10 base or change the JDK major, edit the `FROM` line
or the `openjdk-21-jre-headless` package and push to `main`. Tag a
`vX.Y.Z` release if you want the pinned version published alongside.

## First-time secrets setup

The publish workflow needs two repository secrets:

- `DOCKERHUB_USERNAME` — your Docker Hub login (`blehnen74`)
- `DOCKERHUB_TOKEN` — a Docker Hub access token with **Read, Write, Delete**
  on `blehnen74/dotnetworkqueue-ci`. Create at
  <https://hub.docker.com/settings/security>.

Once both are set, push to `main` (or run `workflow_dispatch`) to
publish the first image.
