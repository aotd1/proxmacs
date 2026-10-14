import Foundation

/// A downloadable arm64 cloud image. Every entry is a qcow2 with cloud-init, systemd and UEFI boot,
/// which is what Proxmacs provisions (NoCloud seed, guest agent as .deb or .rpm, getty on hvc0).
struct CatalogImage: Sendable, Hashable {
    enum Source: Sendable, Hashable {
        /// A stable "latest" link.
        case url(URL)
        /// A directory listing and a pattern for the file in it, for distributions whose file names carry
        /// a build number (the highest match wins).
        case index(URL, pattern: String)
    }

    var id: String
    var name: String
    var distro: String
    /// Cloud-init user suggested for new VMs (the distribution's own default user name).
    var user: String
    var source: Source
    /// Files older versions kept in the cache, removed along with the image.
    var legacyFiles: [String] = []

    /// The converted, sparse raw disk that new VMs are cloned from.
    var raw: URL { Paths.images.appending(path: "\(id)-arm64.raw") }
    var download: URL { Paths.images.appending(path: "\(id)-arm64.qcow2.download") }
    var page: URL {
        switch source {
        case .url(let url): url
        case .index(let url, _): url
        }
    }
}

enum ImageCatalog {
    static let defaultID = "debian-13"

    static let all: [CatalogImage] = [
        CatalogImage(id: "debian-13", name: "Debian 13 (trixie)", distro: "Debian", user: "debian",
                     source: .url(URL(string: "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-arm64.qcow2")!),
                     legacyFiles: ["debian-13-genericcloud-arm64.qcow2"]),
        CatalogImage(id: "debian-12", name: "Debian 12 (bookworm)", distro: "Debian", user: "debian",
                     source: .url(URL(string: "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-arm64.qcow2")!)),
        CatalogImage(id: "ubuntu-26.04", name: "Ubuntu 26.04 LTS", distro: "Ubuntu", user: "ubuntu",
                     source: .url(URL(string: "https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-arm64.img")!)),
        CatalogImage(id: "ubuntu-24.04", name: "Ubuntu 24.04 LTS", distro: "Ubuntu", user: "ubuntu",
                     source: .url(URL(string: "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img")!)),
        CatalogImage(id: "fedora-44", name: "Fedora 44 Cloud", distro: "Fedora", user: "fedora",
                     source: .index(URL(string: "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/aarch64/images/")!,
                                    pattern: #"Fedora-Cloud-Base-Generic-44-[0-9.]+\.aarch64\.qcow2"#)),
        CatalogImage(id: "rocky-10", name: "Rocky Linux 10", distro: "Rocky Linux", user: "rocky",
                     source: .url(URL(string: "https://dl.rockylinux.org/pub/rocky/10/images/aarch64/Rocky-10-GenericCloud-Base.latest.aarch64.qcow2")!)),
        CatalogImage(id: "rocky-9", name: "Rocky Linux 9", distro: "Rocky Linux", user: "rocky",
                     source: .url(URL(string: "https://dl.rockylinux.org/pub/rocky/9/images/aarch64/Rocky-9-GenericCloud-Base.latest.aarch64.qcow2")!)),
        CatalogImage(id: "almalinux-10", name: "AlmaLinux 10", distro: "AlmaLinux", user: "almalinux",
                     source: .url(URL(string: "https://repo.almalinux.org/almalinux/10/cloud/aarch64/images/AlmaLinux-10-GenericCloud-latest.aarch64.qcow2")!)),
        CatalogImage(id: "almalinux-9", name: "AlmaLinux 9", distro: "AlmaLinux", user: "almalinux",
                     source: .url(URL(string: "https://repo.almalinux.org/almalinux/9/cloud/aarch64/images/AlmaLinux-9-GenericCloud-latest.aarch64.qcow2")!)),
        CatalogImage(id: "centos-stream-10", name: "CentOS Stream 10", distro: "CentOS", user: "cloud-user",
                     source: .url(URL(string: "https://cloud.centos.org/centos/10-stream/aarch64/images/CentOS-Stream-GenericCloud-10-latest.aarch64.qcow2")!)),
    ]

    /// Also accepts "debian13", the id older web UIs send.
    static func find(_ id: String) -> CatalogImage? {
        all.first { $0.id == (id == "debian13" ? defaultID : id) }
    }
}
