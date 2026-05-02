# dotnetworkqueue-ci

CI image for [DotNetWorkQueue](https://github.com/blehnen/DotNetWorkQueue). Built and published so my Jenkins on Unraid stops losing the local copy every time the box reboots.

What's in it:

- .NET 10 SDK (the `mcr.microsoft.com/dotnet/sdk:10.0` base)
- .NET 8 SDK alongside it, because the Dashboard projects still target `net8.0`
- OpenJDK 21 JRE, so the Jenkins inbound-agent JAR can launch
- `git`, `curl`, `openssh-client`, `procps`, `libsqlite3-0`
- A `libdl.so` symlink, because System.Data.SQLite's native loader still dlopens it and Bookworm doesn't ship one

It's the *workload* image. The Jenkinsfile says `agent { docker { image '...' } }`, this is the `'...'`. The build agent itself (with the Docker CLI baked in) lives over at [jenkins-agent-with-docker](https://github.com/blehnen/jenkins-agent-with-docker).

## Why bother publishing it

I used to `docker build -t dotnetworkqueue-ci:latest .` straight on Unraid. That was fine until it wasn't: a reboot, a `docker system prune`, a daemon migration, any of those quietly removed the local image. Then Jenkins would try to "pull" it, fall back to Docker Hub, hit a 404, and sit in the queue forever waiting for an executor that was never coming. 

## Tags

```
blehnen74/dotnetworkqueue-ci:weekly             # tracks main
blehnen74/dotnetworkqueue-ci:latest             # alias for :weekly
blehnen74/dotnetworkqueue-ci:weekly-YYYYMMDD    # snapshot of a particular weekly build
blehnen74/dotnetworkqueue-ci:vX.Y.Z             # explicit pin if you tag a release
```

`linux/amd64` only. Unraid box is x86_64 and I don't have an arm64 build node. If you do, change one line in `publish.yml`.

## Wiring it into Jenkins

In the Docker Cloud plugin's Agent Template:

| Field | Value |
|---|---|
| Docker Image | `blehnen74/dotnetworkqueue-ci:weekly` |
| Pull strategy | `Pull once and update latest` |
| Labels | `docker` *(matches `agent { label 'docker' }` in DotNetWorkQueue's Jenkinsfile)* |
| Remote File System Root | `/home/jenkins` |

## Rebuilds

`publish.yml` rebuilds on every push to `main`, on a Monday 06:00 UTC cron (so SDK patches and Debian CVEs land within a week), on `v*` tags, and whenever I run it manually.

The .NET 10 SDK floats with the base image, so the weekly rebuild picks up whatever the latest patch is. The .NET 8 SDK uses `dotnet-install.sh --channel 8.0`, which does the same. If you ever need a pinned 8.x, swap `--channel 8.0` for `--version 8.0.NNN` in the Dockerfile.

## Setting it up the first time

Two repo secrets:

- `DOCKERHUB_USERNAME` — `username`
- `DOCKERHUB_TOKEN` — a Docker Hub access token with Read, Write, and Delete on `target`. Generate one at <https://hub.docker.com/settings/security>.

Once both are set, push to `main` (or fire `workflow_dispatch`) and the first image lands on Docker Hub.
