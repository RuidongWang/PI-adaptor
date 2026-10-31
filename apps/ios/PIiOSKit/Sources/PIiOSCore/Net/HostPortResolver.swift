import Foundation

/// Discovers the loopback port a `pi-host` listens on so the client can open the
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
    /// Sources, most-specific first:
    /// 1. a running `pi-host-v2` (apps/host `dist/main.js`) process `--port N`
    ///    — this is the host the v2 RACP client speaks to;
    /// 2. a running legacy `pi-host.js` process `--port N`;
    /// 3. the last `PI_HOST_READY {"…","port":N}` line in the bootstrap log
    ///    (PI-Desktop reads the same line over SSH when a host is started with
    ///    `--port 0`);
    /// 4. the systemd user unit's `ExecStart --port N`.
    public static let probeCommand = """
    { \
    ps -eo args= 2>/dev/null \
    | grep -E 'dist/main\\.js|pi-host-v2' \
    | grep -v grep \
    | grep -oE -- '--port[ =][0-9]{1,5}' \
    | grep -oE '[0-9]{1,5}'; \
    ps -eo args= 2>/dev/null \
    | grep -E 'pi-host\\.js' \
    | grep -v grep \
    | grep -oE -- '--port[ =][0-9]{1,5}' \
    | grep -oE '[0-9]{1,5}'; \
    tail -n 200 "${HOME}/.pi-desktop/pi-host/.bootstrap/pi-host.log" 2>/dev/null \
    | grep -oE 'PI_HOST_READY \\{[^}]*\\}' \
    | tail -n 1 \
    | grep -oE '"port":[0-9]{1,5}' \
    | grep -oE '[0-9]{1,5}'; \
    systemctl --user show pi-host.service -p ExecStart --value 2>/dev/null \
    | grep -oE -- '--port[ =][0-9]{1,5}' \
    | grep -oE '[0-9]{1,5}'; \
    } 2>/dev/null | head -5
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
