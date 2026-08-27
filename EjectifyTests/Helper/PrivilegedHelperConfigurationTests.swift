//
//  PrivilegedHelperConfigurationTests.swift
//  EjectifyTests
//
//  Created by Codex on 27/08/2026.
//

import Security
import Testing

struct PrivilegedHelperConfigurationTests {

    @Test(arguments: [
        PrivilegedHelperConfiguration.appCodeSigningRequirement,
        PrivilegedHelperConfiguration.helperCodeSigningRequirement,
        PrivilegedHelperConfiguration.developerIDCodeSigningRequirement(
            identifier: PrivilegedHelperConfiguration.appBundleIdentifier
        ),
        PrivilegedHelperConfiguration.developerIDCodeSigningRequirement(
            identifier: PrivilegedHelperConfiguration.helperCodeSigningIdentifier
        )
    ])
    func codeSigningRequirementIsValid(_ requirementString: String) {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(
            requirementString as CFString,
            SecCSFlags(),
            &requirement
        )

        #expect(status == errSecSuccess)
        #expect(requirement != nil)
    }

    @Test func requirementsPinExpectedIdentifiersAndTeam() {
        #expect(PrivilegedHelperConfiguration.appCodeSigningRequirement.contains("identifier \"nl.nielsmouthaan.Ejectify\""))
        #expect(PrivilegedHelperConfiguration.helperCodeSigningRequirement.contains("identifier \"EjectifyPrivilegedHelper\""))
        #expect(PrivilegedHelperConfiguration.appCodeSigningRequirement.contains("DNG6HL3Y5G"))
        #expect(PrivilegedHelperConfiguration.helperCodeSigningRequirement.contains("DNG6HL3Y5G"))
    }

    @Test(arguments: [
        PrivilegedHelperConfiguration.appBundleIdentifier,
        PrivilegedHelperConfiguration.helperCodeSigningIdentifier
    ])
    func developerIDRequirementsPinDistributionCertificateType(_ identifier: String) {
        let requirement = PrivilegedHelperConfiguration.developerIDCodeSigningRequirement(identifier: identifier)

        #expect(requirement.contains("certificate 1[field.1.2.840.113635.100.6.2.6] exists"))
        #expect(requirement.contains("certificate leaf[field.1.2.840.113635.100.6.1.13] exists"))
    }
}
