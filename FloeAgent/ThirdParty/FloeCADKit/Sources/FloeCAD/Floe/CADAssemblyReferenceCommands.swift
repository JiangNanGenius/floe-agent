//
//  CADAssemblyReferenceCommands.swift
//  FloeCADKit
//
//  One-undo document commands used by the E01/E02 part-reference workflow.
//
//  A reference attach/update/make-independent operation must change a staged
//  BODY and the assembly JSON together. Doing that as two `perform` calls
//  would produce two undo steps (and a crash window between them), so the
//  body mutation and the assembly blob swap are authored as ONE
//  `DocumentCommand` here. The command mints the body revision inside `apply`
//  and hands it to the assembly mutation, which is how the persisted
//  `stagedRevision` stays truthful without pre-advancing the document counter.
//
//  This file contains no file I/O and no external-source access. Only the
//  App-owned `CADAssemblyReferenceBridge` can construct a staged body from a
//  user-authorized native document.
//

import Foundation
import CryptoKit

/// Add or replace one staged body and mutate the persisted assembly in the
/// same undo step. `beforeBody == nil` means "append this body"; otherwise the
/// existing body with the same ID is replaced. `mutate` receives the freshly
/// minted `meshRevision` so reference pins can record it.
struct CADAssemblyStagedBodyCommand: DocumentCommand {
    let title: String
    let beforeAssembly: Data?
    let beforeBody: Body?
    let bodyTemplate: Body
    let mutate: (inout CADAssembly, UInt64) -> Void

    func apply(to document: inout DesignDocument) {
        var revision: UInt64
        if let index = document.bodyIndex(of: bodyTemplate.id) {
            var updated = bodyTemplate
            revision = document.nextRevision()
            updated.meshRevision = revision
            document.bodies[index] = updated
        } else {
            var added = bodyTemplate
            revision = document.nextRevision()
            added.meshRevision = revision
            document.bodies.append(added)
        }

        var assembly = (try? CADAssembly.decode(from: beforeAssembly)) ?? CADAssembly()
        mutate(&assembly, revision)
        if let data = try? assembly.encoded() {
            document.assemblyData = data
        }
    }

    func revert(in document: inout DesignDocument) {
        if let beforeBody {
            if let index = document.bodyIndex(of: beforeBody.id) {
                document.bodies[index] = beforeBody
            } else {
                document.bodies.append(beforeBody)
            }
        } else {
            document.bodies.removeAll { $0.id == bodyTemplate.id }
        }
        document.assemblyData = beforeAssembly
    }
}

/// Deterministic digest of the render geometry a staged reference owns.
/// `meshRevision` is deliberately excluded: revisions are session-scoped and
/// are re-minted on document load, so they cannot be persisted as a
/// cross-session content identity. Positions/indices/UVs/placement are stable
/// for identical geometry and change whenever a source update changes the
/// display mesh.
enum CADAssemblyGeometryDigest {
    static func digest(of body: Body) -> String {
        var hasher = SHA256()
        feed(body.transform, into: &hasher)
        feed(body.render.positions, into: &hasher)
        feed(body.render.normals, into: &hasher)
        feed(body.render.indices, into: &hasher)
        if let texcoords = body.render.texcoords {
            feed(texcoords, into: &hasher)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func feed<T>(_ values: [T], into hasher: inout SHA256) {
        var count = UInt64(values.count)
        withUnsafeBytes(of: &count) { hasher.update(bufferPointer: $0) }
        guard !values.isEmpty else { return }
        values.withUnsafeBufferPointer { buffer in
            let raw = UnsafeRawBufferPointer(start: buffer.baseAddress,
                                             count: buffer.count * MemoryLayout<T>.stride)
            hasher.update(bufferPointer: raw)
        }
    }

    private static func feed(_ transform: Transform3D, into hasher: inout SHA256) {
        let values: [Double] = [
            transform.translation.x, transform.translation.y, transform.translation.z,
            transform.rotation.imag.x, transform.rotation.imag.y,
            transform.rotation.imag.z, transform.rotation.real,
            transform.scale,
        ]
        feed(values, into: &hasher)
    }
}
