//
//  Device+Extension.swift
//  LocationSimulator
//
//  Created by David Klopp on 06.04.22.
//  Copyright © 2022 David Klopp. All rights reserved.
//

import Foundation
import LocationSpoofer
import CLogger

extension Device {
    /// Get the current iOS Version in major.minor format, without any additional revision number.
    public var majorMinorVersion: String? {
        guard let majorVersion = majorVersion else {
            return nil
        }
        return "\(majorVersion).\(minorVersion)"
    }

    /// Whether this device is iOS 17+ and requires pymobiledevice3 instead of DeveloperDiskImage.
    public var requiresPMD3: Bool {
        return PMD3Helper.deviceRequiresPMD3(self.majorVersion)
    }

    public func enabledDeveloperModeToggleInSettings() {
        // Only real iOS Devices require developer mode
        if let device = self as? IOSDevice {
            device.enabledDeveloperModeToggleInSettings()
        } else if let wrapper = self as? PMD3DeviceWrapper {
            wrapper.wrappedDevice.enabledDeveloperModeToggleInSettings()
        }
    }

    /// Pair a new device by uploading the developer disk image if required.
    /// For iOS 17+ devices with pymobiledevice3, this starts the tunneld service instead.
    /// - Throws:
    ///    * `DeviceError.devDiskImageNotFound`: Required DeveloperDiskImage support file not found
    ///    * `DeviceError.devDiskImageMount`: Error mounting the DeveloperDiskImage file
    ///    * `DeviceError.devMode`: Developer mode is not enabled
    ///    * `DeviceError.permisson`: Permission error while accessing the App Support folder
    ///    * `DeviceError.productInfo`: Could not read the devices product version or name
    public func pair() throws {
        // PMD3DeviceWrapper handles iOS 17+ — start tunneld and skip DDI mounting
        if let wrapper = self as? PMD3DeviceWrapper, wrapper.usesPMD3 {
            logInfo("Device+Extension: iOS 17+ device — starting tunneld for pymobiledevice3")
            if !PMD3Helper.shared.ensureTunneld() {
                throw DeviceError.devDiskImageNotFound(
                    "Failed to start tunneld. Please ensure pymobiledevice3 is installed and try running:\n" +
                    "sudo pymobiledevice3 remote tunneld -d\n\n" +
                    "Then restart LocationSimulator."
                )
            }
            logInfo("Device+Extension: tunneld ready — device can now simulate location")
            return
        }

        // Only real iOS Devices require a pairing if the DeveloperDiskImage is not already mounted
        guard let device = self as? IOSDevice, !device.developerDiskImageIsMounted else { return }

        // For iOS 17+ without pymobiledevice3, warn the user
        if PMD3Helper.deviceRequiresPMD3(device.majorVersion) && !PMD3Helper.shared.isAvailable {
            logError("Device+Extension: iOS 17+ detected but pymobiledevice3 is not installed!")
            throw DeviceError.devDiskImageNotFound(
                "iOS 17+ requires pymobiledevice3. Install it with: python3 -m pip install pymobiledevice3"
            )
        }

        // Make sure the C-backend can read the files
        let fileManager = FileManager.default
        let startAcccess = fileManager.startAccessingSupportDirectory()

        // No matter how we leave the function, stop accessing the support directory
        defer {
            if startAcccess {
                fileManager.stopAccessingSupportDirectory()
            }
        }

        // Make sure we got the product information
        guard let productVersion = device.majorMinorVersion, let productName = device.productName else {
            throw DeviceError.productInfo("Could not read device information!")
        }

        // Read the developer disk images
        let developerDiskImage = DeveloperDiskImage(os: productName, version: productVersion)

        // Make sure the developer disk image exists
        guard let devDiskImage = developerDiskImage.imageFile else {
            throw DeviceError.devDiskImageNotFound("DeveloperDiskImage.dmg not found!")
        }

        do {
            if developerDiskImage.hasDownloadedPersonalizedImageFiles {
                // Upload personalized image
                guard let devDiskTrust = developerDiskImage.trustcacheFile else {
                    throw DeviceError.devDiskImageNotFound("DeveloperDiskImage.dmg.trustcache not found!")
                }

                guard let devDiskManifest = developerDiskImage.buildManifestFile else {
                    throw DeviceError.devDiskImageNotFound("BuildManifest.plist not found!")
                }
                // TODO: Upload the personalized image
            } else if developerDiskImage.hasDownloadedImageFiles {
                // Upload traditional DeveloperDiskImage
                guard let devDiskSig = developerDiskImage.signatureFile else {
                    throw DeviceError.devDiskImageNotFound("DeveloperDiskImage.dmg.signature not found!")
                }

                try device.pair(devImage: devDiskImage, devImageSig: devDiskSig)
            } else {
                throw DeviceError.devDiskImageNotFound("DeveloperDiskImage not found!")
            }
        } catch {
            throw DeviceError.permisson("Wrong file permission!")
        }
    }
}
