# dotnetworkqueue-ci
#
# CI build image for blehnen/DotNetWorkQueue. Multi-SDK .NET environment
# (net10.0 primary, net8.0 sidecar for the Dashboard projects) plus the
# Jenkins-agent JVM and the native libs DotNetWorkQueue's tests touch.
#
# Why a project-specific image: the public mcr.microsoft.com/dotnet/sdk
# image carries one SDK and no JDK. DotNetWorkQueue needs both .NET 8 and
# .NET 10 (Dashboard targets net8.0, everything else targets net10.0), the
# JRE for the Jenkins inbound agent, and a libdl.so symlink to work around
# System.Data.SQLite's native loader on glibc >= 2.34. Building this on the
# Jenkins host kept evaporating across reboots — publishing as a real image
# means Jenkins can pull it like any other CI base.
#
# Companion to:
#   blehnen74/jenkins-with-docker         (controller)
#   blehnen74/jenkins-agent-with-docker   (generic build agent + docker CLI)
#
# This image is the *workload* an `agent { docker { image '...' } }`
# Jenkinsfile spins up. It is NOT a Jenkins inbound agent itself — the
# Jenkins controller attaches to it with the JNLP/websocket agent JAR
# the same way it does any other docker-cloud workload.

FROM mcr.microsoft.com/dotnet/sdk:10.0

# .NET 8 SDK, side-by-side with the .NET 10 SDK from the base image.
# `dotnet-install.sh` handles current download URLs and arch detection;
# pinning here would just rot. Channel tracking is fine because this
# image is rebuilt weekly via GitHub Actions, and each rebuild publishes
# a `weekly-YYYYMMDD` snapshot tag for reproducibility.
RUN curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
    && chmod +x /tmp/dotnet-install.sh \
    && /tmp/dotnet-install.sh --channel 8.0 --install-dir /usr/share/dotnet --no-path \
    && rm /tmp/dotnet-install.sh

# Java (Jenkins inbound-agent JVM) + tools the test fixtures need.
# libsqlite3-0 is for System.Data.SQLite's native interop in
# DotNetWorkQueue.Transport.SQLite.Tests.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       openjdk-21-jre-headless \
       git \
       curl \
       openssh-client \
       procps \
       libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/*

# System.Data.SQLite's native loader dlopens "libdl.so". On glibc >= 2.34
# (Debian Bookworm and later, which the dotnet/sdk:10.0 base uses) dlopen
# is in libc itself and the standalone libdl.so is gone. Without this
# symlink, every SQLite test fails with "DllNotFoundException: libdl.so".
RUN multiarch=$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo x86_64-linux-gnu) \
    && if [ ! -e "/usr/lib/${multiarch}/libdl.so" ]; then \
           ln -sf "/lib/${multiarch}/libc.so.6" "/usr/lib/${multiarch}/libdl.so"; \
       fi

# Sanity check — fails the build if either SDK is missing.
RUN dotnet --list-sdks

# Playwright browsers for DotNetWorkQueue.Dashboard.Ui.E2E.Tests, installed
# here while the build is still root. The Jenkins stage used to do this per
# build with `install --with-deps chromium`, which shells out to apt and
# therefore needs root - that stopped working the moment this image gained the
# `USER ubuntu` line below, with "su: Authentication failure".
#
# Baking them in is the better place for it regardless: it drops a ~150 MB
# download and an apt run from every E2E build, and removes a network
# dependency from the pipeline.
#
# PLAYWRIGHT_BROWSERS_PATH puts the browsers outside any user's home, so they
# are readable whichever uid the Docker Cloud plugin spawns the container as.
#
# The version is pinned deliberately, unlike the SDK channels above. Playwright's
# .NET package and its browser builds ship together, so this MUST match
# Microsoft.Playwright in DotNetWorkQueue's Source/Directory.Packages.props.
# A mismatch fails the E2E tests at run time with
# "Executable doesn't exist at /ms-playwright/chromium-XXXX".
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN mkdir -p /tmp/pw && cd /tmp/pw \
    && dotnet new console -f net10.0 -o . \
    && dotnet add package Microsoft.Playwright --version 1.60.0 \
    && dotnet build -c Release \
    && dotnet exec --runtimeconfig "$(ls bin/Release/net10.0/*.runtimeconfig.json)" \
         bin/Release/net10.0/Microsoft.Playwright.dll install --with-deps chromium \
    && cd / && rm -rf /tmp/pw \
    && chmod -R a+rX /ms-playwright

# Sanity check - fails the build if the browsers did not land, rather than
# leaving it to fail per test run three stages into a Jenkins build. The
# headless shell is checked too: the E2E fixture launches with Headless = true,
# so that is the binary it actually runs.
RUN ls -d /ms-playwright/chromium-* > /dev/null \
    && ls -d /ms-playwright/chromium_headless_shell-* > /dev/null

# A read-only NuGet fallback folder, so the sixteen parallel stages of a
# DotNetWorkQueue build do not each pull the same packages from nuget.org.
# That burst is why the Jenkinsfile staggers its stages five seconds apart:
# without the stagger nuget.org rate-limits them and restores fail. This
# removes the cause rather than pacing around it.
#
# A fallback folder rather than a shared global packages folder. Fallback
# folders are read-only by contract, so every container resolves from this one
# with no locking at all; sharing a writable global folder across concurrent
# restores is where NuGet's concurrency caveats live.
#
# Nothing is shared at run time, which is what makes this work for throwaway
# containers: the packages live in an image layer, so each container reads them
# through its own copy-on-write view of the same layer. Separate instances,
# one copy of the bytes on the host.
#
# Going stale is harmless. Anything not found here is fetched from nuget.org
# exactly as before, so a dependency bump between weekly rebuilds costs one
# download, not a broken build. That also means this needs no maintenance when
# DotNetWorkQueue's dependencies change.
#
# The http-cache clear matters: restore keeps a second copy of every .nupkg
# there, which measured 417 MB of pure dead weight in the layer.
#
# Costs about 1.6 GB of image, ~760 MB of which is Microsoft.Playwright. Pulled
# once per host per tag, against a burst of 16 concurrent restores on every
# build.
ENV NUGET_FALLBACK_PACKAGES=/nuget-fallback
RUN git clone --depth 1 https://github.com/blehnen/DotNetWorkQueue.git /tmp/dnwq \
    && dotnet restore /tmp/dnwq/Source/DotNetWorkQueue.sln --packages /nuget-fallback \
    && rm -rf /tmp/dnwq \
    && dotnet nuget locals http-cache --clear \
    && dotnet nuget locals temp --clear \
    && chmod -R a+rX /nuget-fallback

# Sanity check - fails the build if the folder came out empty, rather than
# leaving every agent to quietly fall back to nuget.org and rediscover the
# rate limit. Newtonsoft.Json is a direct dependency of the core library, so
# its absence means the restore did not populate this folder.
RUN ls -d /nuget-fallback/newtonsoft.json > /dev/null

# Jenkins workspace mount point. The Docker Cloud plugin will rebind
# this to a per-build path; permissive mode keeps the JNLP agent happy
# regardless of which uid the controller spawns the container as.
RUN mkdir -p /home/jenkins && chmod 777 /home/jenkins

WORKDIR /home/jenkins

# Run as a non-root user by default. The base image already ships an
# unprivileged "ubuntu" user (uid 1000); reuse it rather than creating one.
# The Docker Cloud plugin may still override the uid when it spawns the
# container (the world-writable workspace above keeps that case working),
# but when it does not pin a uid the agent runs as this user instead of root.
USER ubuntu
