//
//  ActivityController.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 24/11/2020.
//

import AppKit

class ActivityController {
    
    private var unmountedVolumes: [Volume] = []
    
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
        unmountedVolumes = Volume.mountedVolumes().filter{ $0.enabled }
        unmountedVolumes.forEach { (volume) in
            volume.unmount(force: Preference.forceUnmount)
        }
    }
    
    @objc func mountVolumes() {
        DispatchQueue.main.asyncAfter(deadline: .now() + (Preference.mountAfterDelay ? 5 : 0)) {
            self.unmountedVolumes.forEach { (volume) in
                volume.mount()
            }
            self.unmountedVolumes = []
        }
    }
}
