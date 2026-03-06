//
//  SystemPowerMessageBridge.h
//  Ejectify
//
//  Created by Codex on 03/03/2026.
//

#ifndef SystemPowerMessageBridge_h
#define SystemPowerMessageBridge_h

#include <stdint.h>
#include <IOKit/IOMessage.h>

/// Returns IOMessage.h constant `kIOMessageSystemWillSleep`.
static inline uint32_t EjectifyIOMessageSystemWillSleep(void) {
    return kIOMessageSystemWillSleep;
}

#endif /* SystemPowerMessageBridge_h */
