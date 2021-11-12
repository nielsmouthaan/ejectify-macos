//
//  DADissenter+Log.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 12/11/2021.
//

import Foundation
import OSLog

extension DADissenter {
    
    func log() {
        let status = DADissenterGetStatus(self);
        var statusString: String?
        if let statusCFString = DADissenterGetStatusString(self) {
            statusString = statusCFString as NSString as String
        }
        os_log("Dissenter status: %{public}@ | %{public}@ | %{public}@", status.description, status.message, statusString ?? "Unknown")
    }
}
