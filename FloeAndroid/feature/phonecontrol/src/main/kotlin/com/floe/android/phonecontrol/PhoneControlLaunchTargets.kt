// SPDX-License-Identifier: MPL-2.0
package com.floe.android.phonecontrol

/** Read-only discovery using the same scope and protected-package policy as launch. */
object PhoneControlLaunchTargets {
    fun allowed(principal: PhoneControlPrincipal, grant: PhoneControlGrant): Set<String>? {
        if (PhoneControlPolicy.principalDenial(principal) != null ||
            PhoneControlPolicy.grantDenial(principal, grant) != null) return null
        val effective = PhoneControlPolicy.effectivePackages(principal, grant)
        return effective.filter { PhoneControlPolicy.launchDenial(it, effective) == null }.toSet()
    }
}
