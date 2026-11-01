import Foundation

/// Discovers the loopback port PI-adaptor listens on so the client can open the
/// SSH `direct-tcpip` tunnel without asking the user to configure a host port.
///
/// The probe runs over SSH and prints one candidate port per line; the resolver
/// picks the first value that is a valid TCP port. Ordering is defined by the
/// command (running process first, then the systemd user unit), so an
/// already-running Host wins over a stale unit definition.
public enum HostPortResolver {
    /// Port used when nothing can be discovered and the record has no port.
    public static let fallbackPort = 44271

    /// Shell one-liner executed over the SSH `exec` channel. It must not require
    /// a TTY, must not touch stdin, and must exit 0 even when nothing is found.
    ///
    /// The default probe intentionally ignores the legacy `pi-host` process and
    /// unit. Otherwise a failed PI-adaptor installation could silently connect
    /// to the old service and appear successful.
    public static let probeCommand = """
    { \
    ps -eo args= 2>/dev/null \
    | grep -E '\\.pi-adaptor/current/dist/main\\.js|pi-adaptor' \
    | grep -v grep \
    | grep -oE -- '--port[ =][0-9]{1,5}' \
    | grep -oE '[0-9]{1,5}'; \
    systemctl --user show pi-adaptor.service -p ExecStart --value 2>/dev/null \
    | grep -oE -- '--port[ =][0-9]{1,5}' \
    | grep -oE '[0-9]{1,5}'; \
    } 2>/dev/null | head -2
    """

    /// Explicit compatibility probe. It must never be used by the default
    /// installer or to prove that a PI-adaptor install succeeded.
    public static let legacyProbeCommand = """
    { \
    ps -eo args= 2>/dev/null \
    | grep -E 'pi-host\\.js' \
    | grep -v grep \
    | grep -oE -- '--port[ =][0-9]{1,5}' \
    | grep -oE '[0-9]{1,5}'; \
    systemctl --user show pi-host.service -p ExecStart --value 2>/dev/null \
    | grep -oE -- '--port[ =][0-9]{1,5}' \
    | grep -oE '[0-9]{1,5}'; \
    } 2>/dev/null | head -2
    """

    /// Parse the probe output into a usable port, or `nil` when none is valid.
    public static func resolve(stdout: String) -> Int? {
        for rawLine in stdout.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let port = Int(line), (1...65_535).contains(port) else { continue }
            return port
        }
        return nil
    }
}
