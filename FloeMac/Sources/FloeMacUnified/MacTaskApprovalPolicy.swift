// SPDX-License-Identifier: MPL-2.0

import FloeMacSelfCore
import FloeModels
import FloeSecurity

/// Adapts a configured Mac model to the reviewer used by the iPad workbench.
enum MacTaskApprovalPolicy {
    static func make(mode: TaskApprovalMode, reviewer: FloeMacSelfProviderBinding?,
                     primaryIsOnDevice: Bool, isOffline: Bool) -> any ApprovalPolicy {
        let backend = reviewer.flatMap { binding -> ApprovalModelBackend? in
            guard binding.provider.isEnabled, binding.model.isEnabled, binding.model.supportsApprovalSurface,
                  binding.model.providerID == binding.provider.id else { return nil }
            return ApprovalModelBackend(adapter: binding.adapter, provider: binding.provider,
                                       model: binding.model, credentials: binding.credentials)
        }
        return TaskApprovalPolicyFactory.make(mode: mode, primaryIsOnDevice: primaryIsOnDevice,
                                              isOffline: isOffline, reviewer: backend)
    }
}
