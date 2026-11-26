import Foundation

/// The Dockerfile Graft builds locally on first run.
///
/// It is intentionally stored as a Swift string constant so Graft is a single
/// self-contained binary with no bundled image/tarball. The base image is
/// pulled from Docker Hub at build time (Ubuntu 24.04 LTS, multi-arch).
///
/// Legal note: this template only *references* third-party packages resolved
/// by apt at build time. No third-party source or binary is distributed with
/// Graft itself.
public enum BuiltinDockerfile {
    public static let ubuntuDesktop = """
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \\
    LANG=zh_CN.UTF-8 \\
    LANGUAGE=zh_CN:zh \\
    LC_ALL=zh_CN.UTF-8 \\
    TZ=Asia/Shanghai

RUN apt-get -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 -o Acquire::Retries=2 -o Acquire::ForceIPv4=true update \\
    && apt-get -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 -o Acquire::Retries=2 -o Acquire::ForceIPv4=true install -y --no-install-recommends \\
        ca-certificates curl wget gnupg xz-utils unzip \\
        locales fonts-noto-cjk fonts-noto-color-emoji \\
        dbus dbus-x11 procps sudo passwd bash \\
        libx11-xcb1 libxcb-dri3-0 libxcb-xkb1 libxkbcommon-x11-0 \\
        libgbm1 libasound2t64 libnss3 libnspr4 libgtk-3-0 libgtk-4-1 \\
        libxss1 libxtst6 libatk-bridge2.0-0 libatk1.0-0 libcups2 libdrm2 \\
        libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libpango-1.0-0 \\
        libcairo2 libatspi2.0-0 libsecret-1-0 libnotify4 libxshmfence1 \\
        libegl1 libgl1 libglx-mesa0 \\
    && locale-gen zh_CN.UTF-8 en_US.UTF-8 \\
    && update-locale LANG=zh_CN.UTF-8 \\
    && rm -rf /var/lib/apt/lists/*

ARG USER_UID=501
RUN useradd -m -U -u ${USER_UID} -s /bin/bash -G sudo graft \\
    && echo 'graft ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/graft \\
    && mkdir -p /tmp/runtime-graft \\
    && chown graft:graft /tmp/runtime-graft \\
    && chmod 700 /tmp/runtime-graft

USER graft
ENV HOME=/home/graft \\
    XDG_RUNTIME_DIR=/tmp/runtime-graft
WORKDIR /home/graft

CMD ["sleep", "infinity"]
"""
}
