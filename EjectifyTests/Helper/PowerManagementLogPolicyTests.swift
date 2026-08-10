//
//  PowerManagementLogPolicyTests.swift
//  EjectifyTests
//

import Testing

struct PowerManagementLogPolicyTests {

    @Test(
        "Includes messages that identify Ejectify",
        .bug("https://github.com/nielsmouthaan/ejectify-macos/issues/140"),
        arguments: [
            "Ejectify timed out while acknowledging sleep",
            "Power client nl.nielsmouthaan.Ejectify acknowledged sleep",
            "eJeCtIfY delayed sleep"
        ]
    )
    func includesEjectifyMessages(message: String) {
        #expect(PowerManagementLogPolicy.includes(message: message))
    }

    @Test(
        "Excludes generic power-management messages",
        .bug("https://github.com/nielsmouthaan/ejectify-macos/issues/140"),
        arguments: [
            "Client Acks delayed by 30000 ms",
            "ExternalMedia assertion created",
            "System Sleep initiated",
            "System Wake completed"
        ]
    )
    func excludesGenericMessages(message: String) {
        #expect(PowerManagementLogPolicy.includes(message: message) == false)
    }
}
