//
//  PMD3DeviceWrapper.swift
//  LocationSimulator
//
//  A wrapper around IOSDevice that uses pymobiledevice3 for location simulation
//  on iOS 17+ devices, while keeping the original device discovery mechanism.
//

import Foundation
import CoreLocation
import LocationSpoofer
import CLogger

/// Wraps an existing IOSDevice to use pymobiledevice3 for location operations on iOS 17+.
/// For iOS 16 and below, delegates to the original device implementation.
public class PMD3DeviceWrapper: Device {
    /// The wrapped original iOS device
    public let wrappedDevice: IOSDevice

    /// Whether this device uses pymobiledevice3 for location simulation
    public let usesPMD3: Bool

    // MARK: - Device Protocol Conformance

    public var udid: String { return wrappedDevice.udid }
    public var name: String { return wrappedDevice.name }
    public var version: String? { return wrappedDevice.version }
    public var productName: String? { return wrappedDevice.productName }
    public var connectionType: ConnectionType { return wrappedDevice.connectionType }
    public var majorVersion: Int? { return wrappedDevice.majorVersion }
    public var minorVersion: Int { return wrappedDevice.minorVersion }

    // Static device methods delegate to IOSDevice
    public static var availableDevices: [Device] {
        return IOSDevice.availableDevices
    }

    public static var isGeneratingDeviceNotifications: Bool {
        return IOSDevice.isGeneratingDeviceNotifications
    }

    @discardableResult
    public static func startGeneratingDeviceNotifications() -> Bool {
        return IOSDevice.startGeneratingDeviceNotifications()
    }

    @discardableResult
    public static func stopGeneratingDeviceNotifications() -> Bool {
        return IOSDevice.stopGeneratingDeviceNotifications()
    }

    // MARK: - Init

    public init(wrapping device: IOSDevice) {
        self.wrappedDevice = device
        self.usesPMD3 = PMD3Helper.deviceRequiresPMD3(device.majorVersion) && PMD3Helper.shared.isAvailable
        if self.usesPMD3 {
            logInfo("PMD3DeviceWrapper: iOS \(device.version ?? "?") detected — using pymobiledevice3 backend")
        }
    }

    // MARK: - Location Simulation

    /// Set the device location. Uses pymobiledevice3 for iOS 17+, original method for older versions.
    @discardableResult
    public func simulateLocation(_ location: CLLocationCoordinate2D) -> Bool {
        if usesPMD3 {
            return PMD3Helper.shared.simulateLocation(location, udid: self.udid)
        } else {
            return wrappedDevice.simulateLocation(location)
        }
    }

    /// Disable location simulation. Uses pymobiledevice3 for iOS 17+, original method for older versions.
    @discardableResult
    public func disableSimulation() -> Bool {
        if usesPMD3 {
            return PMD3Helper.shared.disableSimulation(udid: self.udid)
        } else {
            return wrappedDevice.disableSimulation()
        }
    }

    // MARK: - Description

    public var description: String {
        let backend = usesPMD3 ? "pymobiledevice3" : "libimobiledevice"
        return "PMD3DeviceWrapper(\(wrappedDevice.name), iOS \(version ?? "?"), backend: \(backend))"
    }
}
