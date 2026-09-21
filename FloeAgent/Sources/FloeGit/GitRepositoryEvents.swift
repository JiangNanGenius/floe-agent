// FloeGit — repository-change notification contract.
//
// SPDX-License-Identifier: MPL-2.0
//
// Local Git mutations are actor-serialized inside `LocalGitService`, which is
// the one path every host-side writer uses (agent `git.*` tools, the IDE
// source-control surface, GitHub sync helpers). After a successful mutation it
// posts `floeGitRepositoryDidChange` with the URL the operation ran at, so an
// open source-control view can take a fresh snapshot immediately instead of
// waiting for a manual refresh, a view remount or the next app launch.
//
// The notification carries no claim about which paths changed; consumers
// always re-read status/diff through the service.

import Foundation

public enum GitRepositoryChange {
    /// userInfo key holding the standardized file URL the operation ran at.
    public static let rootKey = "repositoryRoot"
}

public extension Notification.Name {
    /// Posted after a successful local Git mutation (initialize, stage,
    /// unstage, discard, commit, branch switch/create, merge, pull, abort,
    /// clone, fetch, push).
    static let floeGitRepositoryDidChange = Notification.Name("org.floeagent.git.repositoryDidChange")
}
