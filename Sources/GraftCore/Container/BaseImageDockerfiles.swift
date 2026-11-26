import Foundation

public extension BuiltinDockerfile {
    static let debianDesktop = """
FROM debian:12-slim

ENV DEBIAN_FRONTEND=noninteractive \\
    LANG=zh_CN.UTF-8 \\
    LANGUAGE=zh_CN:zh \\
    LC_ALL=zh_CN.UTF-8 \\
    TZ=Asia/Shanghai

RUN apt-get -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 -o Acquire::Retries=2 -o Acquire::ForceIPv4=true update \\
    && apt-get -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 -o Acquire::Retries=2 -o Acquire::ForceIPv4=true install -y --no-install-recommends \\
        ca-certificates curl wget gnupg xz-utils unzip tzdata \\
        locales fonts-noto-cjk fonts-noto-color-emoji \\
        adwaita-icon-theme hicolor-icon-theme librsvg2-common \\
        dbus dbus-x11 procps sudo bash passwd \\
        libx11-xcb1 libxcb-dri3-0 libxcb-xkb1 libxkbcommon-x11-0 \\
        libgbm1 libasound2 libnss3 libnspr4 libgtk-3-0 libgtk-4-1 \\
        libxss1 libxtst6 libatk-bridge2.0-0 libatk1.0-0 libcups2 libdrm2 \\
        libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libpango-1.0-0 \\
        libcairo2 libatspi2.0-0 libsecret-1-0 libnotify4 libxshmfence1 \\
        libegl1 libgl1 libglx-mesa0 xdg-utils \\
    && sed -i 's/^# *\\(zh_CN.UTF-8\\)/\\1/' /etc/locale.gen \\
    && sed -i 's/^# *\\(en_US.UTF-8\\)/\\1/' /etc/locale.gen \\
    && locale-gen \\
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

    static let archLinux = """
FROM archlinux:latest

ENV LANG=zh_CN.UTF-8 \\
    LC_ALL=zh_CN.UTF-8 \\
    TZ=Asia/Shanghai

RUN pacman -Syu --noconfirm --needed \\
        ca-certificates curl wget gnupg xz unzip tzdata \\
        noto-fonts-cjk noto-fonts-emoji \\
        adwaita-icon-theme hicolor-icon-theme librsvg \\
        dbus procps-ng sudo bash shadow \\
        libx11 libxcb libxkbcommon libxkbcommon-x11 mesa alsa-lib nss nspr \\
        gtk3 gtk4 libxss libxtst at-spi2-core libcups libdrm \\
        libxcomposite libxdamage libxfixes libxrandr pango cairo \\
        libsecret libnotify libxshmfence xdg-utils \\
    && sed -i 's/^# *\\(zh_CN.UTF-8\\)/\\1/' /etc/locale.gen \\
    && locale-gen \\
    && rm -rf /var/cache/pacman/pkg/*

ARG USER_UID=501
RUN useradd -m -U -u ${USER_UID} -s /bin/bash graft \\
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

    static let alpineLinux = """
FROM alpine:3.20

ENV LANG=C.UTF-8 \\
    LC_ALL=C.UTF-8 \\
    TZ=Asia/Shanghai

RUN . /etc/os-release \\
    && REPO="https://dl-cdn.alpinelinux.org/alpine/v${VERSION_ID%.*}/community" \\
    && (grep -qxF "$REPO" /etc/apk/repositories || echo "$REPO" >> /etc/apk/repositories) \\
    && apk add --no-cache \\
        bash ca-certificates curl wget gnupg xz unzip tzdata \\
        font-noto-cjk font-noto-emoji \\
        adwaita-icon-theme hicolor-icon-theme librsvg \\
        dbus procps-ng sudo \\
        libx11 libxcb libxkbcommon libxkbcommon-x11 \\
        mesa mesa-gbm mesa-egl mesa-gl alsa-lib nss \\
        gtk+3.0 gtk4.0 libxscrnsaver libxtst at-spi2-core \\
        cups-libs libdrm libxcomposite libxdamage libxfixes libxrandr \\
        pango cairo libsecret libnotify libxshmfence xkeyboard-config font-dejavu \\
        xdg-utils \\
    && rm -rf /var/cache/apk/*

ARG USER_UID=501
RUN addgroup -g ${USER_UID} graft \\
    && adduser -D -u ${USER_UID} -G graft -s /bin/bash graft \\
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

    static let rockyLinux = """
FROM rockylinux/rockylinux:9

RUN dnf install -y --setopt=install_weak_deps=False \\
        ca-certificates wget xz unzip tzdata glibc-langpack-zh \\
        google-noto-sans-cjk-ttc-fonts dbus-daemon procps-ng sudo shadow-utils \\
        adwaita-icon-theme hicolor-icon-theme librsvg2 \\
        gtk3 libX11-xcb libXScrnSaver libXtst mesa-libgbm mesa-libGL \\
        alsa-lib nss libsecret libnotify xdg-utils \\
        dnf-plugins-core \\
    && dnf config-manager --set-enabled crb \\
    && dnf clean all \\
    && rm -rf /var/cache/dnf

ARG USER_UID=501
RUN useradd -m -U -u ${USER_UID} -s /bin/bash graft \\
    && echo 'graft ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/graft \\
    && chmod 0440 /etc/sudoers.d/graft \\
    && install -d -m 700 -o graft -g graft /tmp/runtime-graft

USER graft
ENV HOME=/home/graft \\
    XDG_RUNTIME_DIR=/tmp/runtime-graft \\
    LANG=zh_CN.UTF-8 \\
    LC_ALL=zh_CN.UTF-8 \\
    TZ=Asia/Shanghai
WORKDIR /home/graft

CMD ["sleep", "infinity"]
"""

    static func template(for baseImage: BaseImage) -> String {
        switch baseImage {
        case .ubuntu: return ubuntuDesktop
        case .debian: return debianDesktop
        case .arch: return archLinux
        case .alpine: return alpineLinux
                case .rocky: return rockyLinux
        }
    }

    /// Returns the Dockerfile with its `FROM` line rewritten to the configured
    /// registry mirror. Graft's local image tag is unaffected.
    static func template(for baseImage: BaseImage, registryMirror: String) -> String {
        let source = template(for: baseImage)
        let reference = DockerRegistry.reference(prefix: registryMirror, image: baseImage.baseImageReference)
        guard reference != baseImage.baseImageReference else { return source }

        var lines = source.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { $0.hasPrefix("FROM ") }) {
            lines[index] = "FROM \(reference)"
        }
        return lines.joined(separator: "\n")
    }
}
