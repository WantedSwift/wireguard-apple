// SPDX-License-Identifier: MIT
// Copyright © 2018-2019 WireGuard LLC. All Rights Reserved.

import Foundation
import Network
import NetworkExtension
import libwg_go

open class WireGuardPacketTunnelProvider: NEPacketTunnelProvider {

    private let dispatchQueue = DispatchQueue(label: "PacketTunnel", qos: .utility)
    private var handle: Int32?
    private var networkMonitor: NWPathMonitor?
    private var packetTunnelSettingsGenerator: PacketTunnelSettingsGenerator?

    open override func startTunnel(options: [String: NSObject]?, completionHandler startTunnelCompletionHandler: @escaping (Error?) -> Void) {
        dispatchQueue.async {
            let activationAttemptId = options?["activationAttemptId"] as? String

            // Obtain protocol configuration
            guard let tunnelProviderProtocol = self.protocolConfiguration as? NETunnelProviderProtocol else {
                let error = PacketTunnelProviderError.missingProtocolConfiguration
                self.handleTunnelError(error)
                startTunnelCompletionHandler(error)
                return
            }

            // Decode tunnel configuration
            let tunnelConfiguration: TunnelConfiguration
            do {
                tunnelConfiguration = try self.getTunnelConfiguration(from: tunnelProviderProtocol)
            } catch {
                startTunnelCompletionHandler(PacketTunnelProviderError.decodeTunnelConfiguration(error))
                return
            }

            // Configure WireGuard logger
            self.configureLogger()
            #if os(macOS)
            wgEnableRoaming(true)
            #endif

            self.logLine(level: .info, message: "Starting tunnel from the " + (activationAttemptId == nil ? "OS directly, rather than the app" : "app"))

            let endpoints = tunnelConfiguration.peers.map { $0.endpoint }
            guard let resolvedEndpoints = DNSResolver.resolveSync(endpoints: endpoints) else {
                let error = PacketTunnelProviderError.dnsResolution
                self.handleTunnelError(error)
                startTunnelCompletionHandler(error)
                return
            }
            assert(endpoints.count == resolvedEndpoints.count)

            self.packetTunnelSettingsGenerator = PacketTunnelSettingsGenerator(tunnelConfiguration: tunnelConfiguration, resolvedEndpoints: resolvedEndpoints)

            self.setTunnelNetworkSettings(self.packetTunnelSettingsGenerator!.generateNetworkSettings()) { error in
                self.dispatchQueue.async {
                    if let error = error {
                        self.logLine(level: .error, message: "Starting tunnel failed with setTunnelNetworkSettings returning \(error.localizedDescription)")

                        let tunnelProviderError = PacketTunnelProviderError.setNetworkSettings(error)
                        self.handleTunnelError(tunnelProviderError)
                        startTunnelCompletionHandler(tunnelProviderError)
                    } else {
                        self.networkMonitor = NWPathMonitor()
                        self.networkMonitor!.pathUpdateHandler = { [weak self] path in
                            self?.pathUpdate(path: path)
                        }
                        self.networkMonitor!.start(queue: self.dispatchQueue)

                        let fileDescriptor = (self.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32) ?? -1
                        if fileDescriptor < 0 {
                            self.logLine(level: .error, message: "Starting tunnel failed: Could not determine file descriptor")

                            let tunnelProviderError = PacketTunnelProviderError.tunnelDeviceFileDescriptor
                            self.handleTunnelError(tunnelProviderError)
                            startTunnelCompletionHandler(tunnelProviderError)
                            return
                        }

                        let ifname = Self.getInterfaceName(fileDescriptor: fileDescriptor)
                        self.logLine(level: .info, message: "Tunnel interface is \(ifname ?? "unknown")")

                        let handle = self.packetTunnelSettingsGenerator!.uapiConfiguration()
                            .withCString { return wgTurnOn($0, fileDescriptor) }
                        if handle < 0 {
                            self.logLine(level: .error, message: "Starting tunnel failed with wgTurnOn returning \(handle)")

                            let tunnelProviderError = PacketTunnelProviderError.startWireGuardBackend
                            self.handleTunnelError(tunnelProviderError)
                            startTunnelCompletionHandler(tunnelProviderError)
                            return
                        }
                        self.handle = handle
                        startTunnelCompletionHandler(nil)
                    }
                }
            }
        }
    }

    open override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        dispatchQueue.async {
            self.networkMonitor?.cancel()
            self.networkMonitor = nil

            self.logLine(level: .info, message: "Stopping tunnel")
            if let handle = self.handle {
                wgTurnOff(handle)
            }

            completionHandler()

            #if os(macOS)
            // HACK: This is a filthy hack to work around Apple bug 32073323 (dup'd by us as 47526107).
            // Remove it when they finally fix this upstream and the fix has been rolled out to
            // sufficient quantities of users.
            exit(0)
            #endif
        }
    }

    open override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        // no-op
    }

    // MARK: - Subclassing

    open func handleTunnelError(_ error: PacketTunnelProviderError) {
        // Implement in subclasses
    }

    open func logLine(level: PacketTunnelLogLevel, message: String) {
        // Implement in subclasses
    }

    open func getTunnelConfiguration(from tunnelProviderProtocol: NETunnelProviderProtocol) throws -> TunnelConfiguration {
        throw SubclassRequirementError.notImplemented
    }

    // MARK: - Public

    public func getWireGuardConfiguration(completionHandler: @escaping (String?) -> Void) {
        dispatchQueue.async {
            guard let handle = self.handle else {
                completionHandler(nil)
                return
            }

            if let settings = wgGetConfig(handle) {
                completionHandler(String(cString: settings))
                free(settings)
            } else {
                completionHandler(nil)
            }
        }
    }

    // MARK: - Private

    private class func getInterfaceName(fileDescriptor: Int32) -> String? {
        var ifnameBytes = [CChar](repeating: 0, count: Int(IF_NAMESIZE))

        return ifnameBytes.withUnsafeMutableBufferPointer { bufferPointer -> String? in
            guard let baseAddress = bufferPointer.baseAddress else { return nil }

            var ifnameSize = socklen_t(bufferPointer.count)
            let result = getsockopt(
                fileDescriptor,
                2 /* SYSPROTO_CONTROL */,
                2 /* UTUN_OPT_IFNAME */,
                baseAddress, &ifnameSize
            )

            if result == 0 {
                return String(cString: baseAddress)
            } else {
                return nil
            }
        }
    }

    private func configureLogger() {
        WireGuardLoggerHelper.shared.setLogHandler { [weak self] (logLevel, message) in
            guard let self = self else { return }

            self.dispatchQueue.async {
                self.logLine(level: logLevel, message: message)
            }
        }
    }

    private func pathUpdate(path: Network.NWPath) {
        guard let handle = handle else { return }

        self.logLine(level: .debug, message: "Network change detected with \(path.status) route and interface order \(path.availableInterfaces)")

        #if os(iOS)
        if let packetTunnelSettingsGenerator = packetTunnelSettingsGenerator {
            _ = packetTunnelSettingsGenerator.endpointUapiConfiguration()
                .withCString { return wgSetConfig(handle, $0) }
        }
        #endif
        wgBumpSockets(handle)
    }
}


/// An error type describing packet tunnel errors.
public enum PacketTunnelProviderError: LocalizedError {
    /// Protocol configuration is not passed along with VPN configuration
    case missingProtocolConfiguration

    /// A failure to decode tunnel configuration
    case decodeTunnelConfiguration(Error)

    /// A failure to resolve endpoints DNS
    case dnsResolution

    /// A failure to set network settings
    case setNetworkSettings(Error)

    /// A failure to obtain the tunnel device file descriptor
    case tunnelDeviceFileDescriptor

    /// A failure to start WireGuard backend
    case startWireGuardBackend

    public var errorDescription: String? {
        switch self {
        case .missingProtocolConfiguration:
            return "Missing protocol configuration"

        case .decodeTunnelConfiguration(let error):
            return "Failure to decode tunnel configuration: \(error.localizedDescription)"

        case .dnsResolution:
            return "Failure to resolve endpoints DNS"

        case .setNetworkSettings(let error):
            return "Failure to set network settings: \(error.localizedDescription)"

        case .tunnelDeviceFileDescriptor:
            return "Failure to obtain tunnel device file descriptor"

        case .startWireGuardBackend:
            return "Failure to start WireGuard backend"
        }
    }
}

/// An error type describing subclassing requirement failures.
public enum SubclassRequirementError: LocalizedError {
    /// A feature is not implemented by the subclass.
    case notImplemented

    public var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "Subclass does not implement the method"
        }
    }
}

/// A enum describing packet tunnel log levels
public enum PacketTunnelLogLevel: Int32 {
    case debug = 0
    case info = 1
    case error = 2
}
