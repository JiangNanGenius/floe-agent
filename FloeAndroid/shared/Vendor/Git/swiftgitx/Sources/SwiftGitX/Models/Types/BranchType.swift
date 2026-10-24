import libgit2

public enum BranchType: LibGit2RawRepresentable {
    case all
    case local
    case remote

    init(raw: git_branch_t) {
        switch raw {
        case GIT_BRANCH_ALL:
            self = .all
        case GIT_BRANCH_LOCAL:
            self = .local
        case GIT_BRANCH_REMOTE:
            self = .remote
        default:
            self = .all
        }
    }

    var raw: git_branch_t {
        switch self {
        case .all:
            GIT_BRANCH_ALL
        case .local:
            GIT_BRANCH_LOCAL
        case .remote:
            GIT_BRANCH_REMOTE
        }
    }
}
