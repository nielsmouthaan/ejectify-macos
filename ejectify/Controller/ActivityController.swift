//
//  ActivityController.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 24/11/2020.
//

import AppKit
import OSLog

class ActivityController {
    private let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "nl.nielsmouthaan.Ejectify", category: "ActivityController")
    
    private var unmountedVolumes: [ExternalVolume] = []
    
    init() {
        startMonitoring()
    }
    
    func startMonitoring() {
        
        // Stop observing first
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default.removeObserver(self)
        
        // Start observing based on preference
        switch Preference.unmountWhen {
        case .screensaverStarted:
            DistributedNotificationCenter.default.addObserver(self, selector: #selector(unmountVolumes), name: NSNotification.Name(rawValue: "com.apple.screensaver.didstart"), object: nil)
            DistributedNotificationCenter.default.addObserver(self, selector: #selector(mountVolumes), name: NSNotification.Name(rawValue: "com.apple.screensaver.didstop"), object: nil)
            break
        case .screenIsLocked:
            DistributedNotificationCenter.default.addObserver(self, selector: #selector(unmountVolumes), name: NSNotification.Name(rawValue: "com.apple.screenIsLocked"), object: nil)
            DistributedNotificationCenter.default.addObserver(self, selector: #selector(mountVolumes), name: NSNotification.Name(rawValue: "com.apple.screenIsUnlocked"), object: nil)
            break
        case .screensStartedSleeping:
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(unmountVolumes), name: NSWorkspace.screensDidSleepNotification, object: nil)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(mountVolumes), name: NSWorkspace.screensDidWakeNotification, object: nil)
            break
        case .systemStartsSleeping:
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(unmountVolumes), name: NSWorkspace.willSleepNotification, object: nil)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(mountVolumes), name: NSWorkspace.didWakeNotification, object: nil)
        }
    }
    
    @objc func unmountVolumes() {
        unmountedVolumes = ExternalVolume.mountedVolumes().filter{ $0.enabled }
        os_log("Unmount trigger received. %{public}@ enabled volumes queued.", log: self.log, type: .default, String(self.unmountedVolumes.count))
        unmountedVolumes.forEach { (volume) in
            volume.unmount(force: Preference.forceUnmount)
        }
    }
    
    @objc func mountVolumes() {
        let delay = Preference.mountAfterDelay ? 5 : 0
        os_log("Mount trigger received. %{public}@ volumes queued. Delay: %{public}@s.", log: self.log, type: .default, String(self.unmountedVolumes.count), String(delay))
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay)) {
            self.unmountedVolumes.forEach { (volume) in
                volume.mount()
            }
            os_log("Mount pass finished. Clearing queued volumes.", log: self.log, type: .default)
            self.unmountedVolumes = []
        }
    }
}
