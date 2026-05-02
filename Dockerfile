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

# Jenkins workspace mount point. The Docker Cloud plugin will rebind
# this to a per-build path; permissive mode keeps the JNLP agent happy
# regardless of which uid the controller spawns the container as.
RUN mkdir -p /home/jenkins && chmod 777 /home/jenkins
WORKDIR /home/jenkins
