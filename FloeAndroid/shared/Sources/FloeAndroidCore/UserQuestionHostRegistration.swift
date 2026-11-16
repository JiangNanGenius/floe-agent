// SPDX-License-Identifier: MPL-2.0
//
// Handler registration for the two additive G07.3A interaction surfaces:
//
//   * current-thread visible-message search / bounded reveal window
//     (`conversation.messageSearch`, `conversation.messageWindow`);
//   * durable task questions (`question.pending`, `question.answer`,
//     `question.cancel`).
//
// Both remain ordinary conversationLifecycle commands: the envelope taskID is
// the conversation identity, the native actor revalidates every exact
// message/question/run identity and the reply travels through the existing
// typed value carrier. The App cannot mint a conversation, question, run or
// answer receipt here.
import Foundation
import FloeCore
import FloeAgentRuntime
import FloeModels

/// Narrow App-owned wake signal for the durable question lifecycle.
///
/// The coordinator already emits `.presented` / `.settled` on the EXACT
/// durable registration and settlement boundaries, but the Android install
/// used to create it without an event handler. The Kotlin host therefore had
/// no event from which to re-read `question.pending` when no visible holder
/// owned the conversation (background/scheduled runs, a released surface, or
/// a discovery window that expired while a device approval was open).
///
/// This does not add a second question store, notification, answer path or
/// permission: it only advances the EXISTING main-owned change sequence that
/// the Kotlin host already waits on (`floe_run_foreground_wait_change`). The
/// host reacts by re-reading the authoritative `question.pending` command.
/// Temporary questions never wake it because they have no durable task to
/// reopen and are never notified.
enum UserQuestionLifecycleSignal {
    static func didChange(_ event: UserQuestionEvent) {
        switch event {
        case .presented(let snapshot), .settled(let snapshot):
            guard !snapshot.isEphemeral else { return }
        case .answerAvailable:
            // `.settled` already advanced the sequence for the settlement
            // that made this optional delivery available.
            return
        }
        RunForegroundChange.notifyOwnedWorkChanged()
    }

    /// Root retirement can leave a posted notification for which no live
    /// coordinator remains. Wake the host so it re-reads and withdraws it.
    static func didRetire() {
        RunForegroundChange.notifyOwnedWorkChanged()
    }
}

extension G02InstalledComposition {

    /// Called once from `registerAllDomainHandlers`; appends the exact keys to
    /// `registeredHandlerKeys` so the existing retirement path unregisters
    /// them with the rest of the generation.
    func registerInteractionCommands(gen: AndroidRuntimeBootstrap.Generation) {
        let conversation = conversationDomain
        bindInteraction(
            gen: gen,
            scope: .conversationLifecycle,
            command: "conversation.messageSearch"
        ) { job in
            guard let taskID = G02DomainBinder.taskID(job) else {
                return G02DomainBinder.wireError(
                    "invalidEnvelope", reason: "missingTaskIdentity")
            }
            do {
                let reply = try await conversation.messageSearch(
                    conversationID: taskID,
                    payload: G02DomainBinder.settingsPayload(job))
                return G02DomainBinder.completedWireObject(reply.wireObject())
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bindInteraction(
            gen: gen,
            scope: .conversationLifecycle,
            command: "conversation.messageWindow"
        ) { job in
            guard let taskID = G02DomainBinder.taskID(job) else {
                return G02DomainBinder.wireError(
                    "invalidEnvelope", reason: "missingTaskIdentity")
            }
            do {
                let reply = try await conversation.messageWindow(
                    conversationID: taskID,
                    payload: G02DomainBinder.settingsPayload(job))
                return G02DomainBinder.completedWireObject(reply.wireObject)
            } catch let error as ConversationDomainError {
                return G02DomainBinder.wireError(error.wireCode, reason: error.wireReason)
            } catch let error as FloeError {
                return G02DomainBinder.wireError("notFound", reason: error.reason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }

        let questions = UserQuestionHostAPI.shared
        let epoch = gen.epoch
        bindInteraction(
            gen: gen,
            scope: .conversationLifecycle,
            command: "question.pending"
        ) { job in
            guard let taskID = G02DomainBinder.taskID(job) else {
                return G02DomainBinder.wireError(
                    "invalidEnvelope", reason: "missingTaskIdentity")
            }
            do {
                let reply = try await questions.pending(
                    conversationID: taskID, epoch: epoch,
                    payload: G02DomainBinder.settingsPayload(job))
                return G02DomainBinder.completedWireObject(reply)
            } catch let error as UserQuestionError {
                return G02DomainBinder.wireError(
                    UserQuestionHostWire.errorCode(error), reason: nil)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bindInteraction(
            gen: gen,
            scope: .conversationLifecycle,
            command: "question.answer"
        ) { job in
            guard let taskID = G02DomainBinder.taskID(job) else {
                return G02DomainBinder.wireError(
                    "invalidEnvelope", reason: "missingTaskIdentity")
            }
            do {
                let reply = try await questions.answer(
                    conversationID: taskID, epoch: epoch,
                    payload: G02DomainBinder.settingsPayload(job))
                return G02DomainBinder.completedWireObject(reply)
            } catch let error as UserQuestionError {
                return G02DomainBinder.wireError(
                    UserQuestionHostWire.errorCode(error), reason: nil)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        bindInteraction(
            gen: gen,
            scope: .conversationLifecycle,
            command: "question.cancel"
        ) { job in
            guard let taskID = G02DomainBinder.taskID(job) else {
                return G02DomainBinder.wireError(
                    "invalidEnvelope", reason: "missingTaskIdentity")
            }
            do {
                let reply = try await questions.cancel(
                    conversationID: taskID, epoch: epoch,
                    payload: G02DomainBinder.settingsPayload(job))
                return G02DomainBinder.completedWireObject(reply)
            } catch let error as UserQuestionError {
                return G02DomainBinder.wireError(
                    UserQuestionHostWire.errorCode(error), reason: nil)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
    }

    private func bindInteraction(
        gen: AndroidRuntimeBootstrap.Generation,
        scope: BridgeV3.Scope,
        command: String,
        body: @escaping @Sendable (RuntimeCommandEnvelopeJob) async -> RuntimeCommandResult
    ) {
        G02DomainBinder.registerSubmitHandler(
            scope: scope, command: command, configurationScope: nil)
        let key = BridgeV3.handlerKey(scope: scope, command: command)
        G02DomainBinder.registerProcessor(gen.registry, handlerKey: key, body: body)
        registeredHandlerKeys.append(key)
    }
}
