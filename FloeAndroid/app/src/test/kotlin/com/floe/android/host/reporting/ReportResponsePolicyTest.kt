package com.floe.android.host.reporting

import org.junit.Assert.*
import org.junit.Test

class ReportResponsePolicyTest {
    @Test fun onlyTheActual409ContractRequiresAnUpdate() {
        assertEquals("client_update_required", ReportResponsePolicy.rejectionCode(409,
            """{"code":"client_update_required","error":"untrusted remote text"}"""))
        assertEquals("http_503", ReportResponsePolicy.rejectionCode(503,
            """{"code":"client_update_required"}"""))
    }
    @Test fun malformedOrOversizedBodiesKeepTheOrdinaryFailure() {
        for (body in listOf("<html>client_update_required</html>", """{"error":"client_update_required"}""",
            """{"code":"client_update_required","extra":"${"x".repeat(8192)}"}"""))
            assertEquals("http_409", ReportResponsePolicy.rejectionCode(409, body))
    }
}
