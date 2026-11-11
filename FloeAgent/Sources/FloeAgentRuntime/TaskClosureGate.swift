import Foundation

/// Terminal presentation policy over the run's existing checklist and ledger.
/// It grants no execution authority, retries no call, and creates no goal.
struct TaskClosureGate: Sendable {
    struct Step: Sendable, Codable { var id:String; var title:String; var status:String }
    struct Receipt: Sendable, Codable {
        var toolName:String
        var callFingerprint:String
        var status:String
        var isSideEffecting:Bool
        var outcomeUnknown:Bool
        /// Successful original/output mutation evidence, separate from the
        /// conservative effect bit used to account for failures and unknowns.
        var supportsMutationClaim:Bool = false
        /// Trusted dispatch evidence from the runtime's own executor
        /// boundary: false means the call provably never executed (policy,
        /// gate, suppression, budget or recovery synthesis), so no external
        /// action could have started. Defaults to true (conservative) for
        /// receipts restored without the flag.
        var wasDispatched:Bool = true
        /// Trusted same-operation identity proving which concrete NEW output
        /// file this receipt's work produced (typed `outputWrite` target
        /// arguments plus resolved target paths). Nil unless the typed
        /// contract proves the concrete output file; the gate then never
        /// treats the receipt as a correctable attempt.
        var operationIdentity:String? = nil
    }
    struct Facts: Sendable, Codable {
        var steps:[Step]
        /// This is the existing bounded ledger, not an exhaustive new proof
        /// store. The model must still account for the full recorded results.
        var receipts:[Receipt]
        var availableToolNames:[String]
        var hasUnsettledSteps:Bool { steps.contains { !["completed","cancelled"].contains($0.status) } }
        var hasExecutableSteps:Bool { steps.contains { ["pending","inProgress"].contains($0.status) } }
        var latestReceipts:[Receipt] {
            var seen = Set<String>()
            return receipts.reversed().filter { seen.insert($0.toolName+"|"+$0.callFingerprint).inserted }.reversed()
        }
        /// Correction/supersession evidence over the latest receipts. A
        /// failed side-effecting receipt may be superseded by exactly one
        /// later successful receipt when EVERY link is proven by runtime
        /// evidence, never by phrase or tool-name similarity:
        ///  * the failure is a trusted pre-execution rejection
        ///    (`wasDispatched == false` — policy/gate/suppression/budget/
        ///    recovery synthesis, so no external action could have started),
        ///    never an unknown-outcome receipt;
        ///  * both receipts carry the same provable output identity (same
        ///    tool AND same concrete output file — a different output,
        ///    project, document or in-place target is independent work and
        ///    never supersedes);
        ///  * the later receipt is a real executed success
        ///    (supportsMutationClaim, dispatched, not unknown).
        /// Pairing is one-to-one and order-preserving: each success absorbs
        /// only the most recent earlier unsuperseded failure of its work
        /// identity, so a second, unanswered failure still blocks. Anything
        /// unproven (dispatched failure, missing identity) stays blocking.
        private static func supersededFailureIndices(in latest:[Receipt]) -> Set<Int> {
            var superseded = Set<Int>()
            for (index, receipt) in latest.enumerated() {
                guard receipt.status == "ok", receipt.isSideEffecting,
                      !receipt.outcomeUnknown, receipt.supportsMutationClaim,
                      receipt.wasDispatched, let identity = receipt.operationIdentity else { continue }
                for prior in stride(from: index - 1, through: 0, by: -1) where !superseded.contains(prior) {
                    let candidate = latest[prior]
                    guard candidate.toolName == receipt.toolName,
                          candidate.isSideEffecting, candidate.status != "ok",
                          !candidate.outcomeUnknown, !candidate.wasDispatched,
                          candidate.operationIdentity == identity else { continue }
                    superseded.insert(prior)
                    break
                }
            }
            return superseded
        }
        var hasNonSuccessfulWork:Bool {
            let latest = latestReceipts
            let superseded = Self.supersededFailureIndices(in: latest)
            return latest.enumerated().contains { index, receipt in
                !superseded.contains(index) && receipt.isSideEffecting && (receipt.status != "ok" || receipt.outcomeUnknown)
            }
        }
        var hasSuccessfulWork:Bool { latestReceipts.contains { $0.supportsMutationClaim && $0.status == "ok" && !$0.outcomeUnknown } }
    }
    enum Directive: Equatable { case allow, reconcileOnce, reportUnfinished }

    func evaluate(answer:String,facts:Facts,corrections:Int,isVerification:Bool) -> Directive {
        let promise = Self.promisesExecution(answer,knownWork:facts.hasUnsettledSteps || facts.hasNonSuccessfulWork,
            tools:facts.availableToolNames)
        let needsAccounting = facts.hasUnsettledSteps || facts.hasNonSuccessfulWork
        guard promise || needsAccounting else { return .allow }
        // A concrete failure, blocker or missing input may legitimately end
        // the run. Never force an automatic retry just because work failed.
        if !promise && Self.acknowledgesUnfinished(answer) { return .allow }
        // Final-answer self review has no tools. It cannot silently promise
        // fresh work or re-open execution after that boundary was sealed.
        if isVerification {
            if promise || (needsAccounting && !Self.acknowledgesUnfinished(answer)) { return .reportUnfinished }
            return .allow
        }
        // One reconciliation may continue real work, fix the progress record,
        // or report a blocker. The existing executor/approvals/loop limits
        // remain the only authority over any proposed tool calls.
        if corrections == 0 { return .reconcileOnce }
        if promise { return .reportUnfinished }
        if needsAccounting && !Self.acknowledgesUnfinished(answer) { return .reportUnfinished }
        return .allow
    }

    static func promisesExecution(_ answer:String,knownWork:Bool,tools:[String]) -> Bool {
        let text = answer.lowercased().replacingOccurrences(of:"(?<=[.!?])\\s+",with:"\n",options:.regularExpression)
        let clauses = text.components(separatedBy:CharacterSet(charactersIn:"\n。！？!?;；，,"))
        let immediate = ["我现在","现在用","现在调用","接下来我","下一步我","我会立即","立即调用","让我","我先","准备调用","准备执行",
            "i'll now","i will now","next i'll","next i will","let me","i'm going to","i am going to","now i'll","now i will"]
        let continuing = ["接下来继续","下一步继续","我会继续","我将继续","我继续","i will continue","i'll continue","i will proceed","i'll proceed"]
        let actions = ["调用","执行","观察","检查","读取","连接","安装","测试","打开","获取","截图","重试",
            "call","run","execute","inspect","observe","read","connect","install","test","open","fetch","capture","retry"]
        let workActions = ["生成","编辑","修改","修正","写入","保存","完成","补齐","分析","计算","切片","导出","验证","generate","edit","write","save","finish","complete"]
        let negative = ["无法继续","不能继续","不会继续","不会再","不再执行","无法调用","不能调用","无法执行","不能执行","will not continue","won't continue","cannot continue","can't continue","unable to continue","cannot execute","can't execute"]
        for clause in clauses {
            guard !negative.contains(where:clause.contains) else { continue }
            let immediatePromise = immediate.contains(where:clause.contains)
            let continuationPromise = knownWork && continuing.contains(where:clause.contains)
            // Chinese task replies often omit "I": the observed terminal
            // answer said "接下来按…修正编辑输入，并继续…". Require owned
            // unfinished work and an actual work verb for this implicit form.
            let implicitNext = knownWork && ["接下来","下一步"].contains(where:clause.contains)
                && !["你可以","您可以","请你","请先","请提供","需要你","等待你","用户"].contains(where:clause.contains)
                && (actions+workActions+["继续"]).contains(where:clause.contains)
            guard immediatePromise || continuationPromise || implicitNext else { continue }
            if implicitNext { return true }
            if continuationPromise || actions.contains(where:clause.contains) { return true }
            if knownWork && workActions.contains(where:clause.contains) { return true }
            if tools.contains(where:{ clause.contains($0.lowercased()) || clause.contains($0.lowercased().replacingOccurrences(of:".",with:"_")) }) { return true }
        }
        return false
    }

    static func acknowledgesUnfinished(_ answer:String) -> Bool {
        let text = answer.lowercased()
        return ["未完成","尚未完成","没有完成","未执行","没有执行","失败","无法","受阻","阻碍","需要你","等待你","等待授权","需要授权","没有权限","权限不足","被拒绝","尚未验证","尚未核验","请先","请提供","请配置",
            "not completed","not complete","unfinished","not executed","failed","blocked","unable to","could not","couldn't","need your","need you","awaiting your","permission denied","authorization required","not verified","unverified"].contains(where:text.contains)
    }
}
