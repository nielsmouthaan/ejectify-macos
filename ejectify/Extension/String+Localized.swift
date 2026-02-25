//
//  String+Localized.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 11/01/2021.
//

import Foundation

extension String {
    
    /// Looks up the receiver in localization tables and returns the localized value.
    var localized: String {
        NSLocalizedString(self, comment: "")
    }
}
