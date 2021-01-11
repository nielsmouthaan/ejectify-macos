//
//  String+Localized.swift
//  Ejectify
//
//  Created by Niels Mouthaan on 11/01/2021.
//

import Foundation

extension String {
    
    var localized: String {
        return NSLocalizedString(self, comment: "")
    }
}
