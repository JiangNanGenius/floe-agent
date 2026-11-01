import UIKit

final class CanaryViewController: UIViewController {
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private let startButton = UIButton(type: .system)
    private let footerLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildInterface()
        CanaryCoordinator.shared.attach(viewController: self)
    }

    private func buildInterface() {
        titleLabel.text = "Bridge Canary\n桥接探针"
        titleLabel.numberOfLines = 0
        titleLabel.font = .preferredFont(forTextStyle: .largeTitle)
        titleLabel.adjustsFontForContentSizeCategory = true

        statusLabel.text = "Idle / 待启动"
        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .title2)
        statusLabel.adjustsFontForContentSizeCategory = true

        detailLabel.numberOfLines = 0
        detailLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        detailLabel.textColor = .secondaryLabel

        var configuration = UIButton.Configuration.filled()
        configuration.title = "Start one-shot engine\n启动一次性引擎"
        configuration.titleAlignment = .center
        configuration.cornerStyle = .large
        startButton.configuration = configuration
        startButton.titleLabel?.numberOfLines = 0
        startButton.accessibilityIdentifier = "startButton"
        startButton.addTarget(self, action: #selector(startTapped), for: .touchUpInside)
        startButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true

        footerLabel.text = "No network listener. Commands and results stay in Documents/canary/.\n无网络监听。命令和结果都保存在 Documents/canary/。"
        footerLabel.numberOfLines = 0
        footerLabel.font = .preferredFont(forTextStyle: .footnote)
        footerLabel.textColor = .tertiaryLabel

        let stack = UIStackView(arrangedSubviews: [
            titleLabel,
            statusLabel,
            detailLabel,
            startButton,
            footerLabel,
        ])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 36),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor, constant: -28),
        ])
    }

    @objc private func startTapped() {
        startButton.isEnabled = false
        startButton.configuration?.title = "Starting… / 正在启动…"
        CanaryCoordinator.shared.requestStartFromUI()
    }

    func render(phase: CanaryCoordinator.Phase, detail: String) {
        switch phase {
        case .idle:
            statusLabel.text = "Idle / 待启动"
            statusLabel.textColor = .label
        case .starting:
            statusLabel.text = "Starting once / 正在启动一次"
            statusLabel.textColor = .systemOrange
        case .bootstrapDispatched:
            statusLabel.text = "Bootstrap dispatched / 已派发"
            statusLabel.textColor = .systemBlue
            startButton.isEnabled = false
            startButton.configuration?.title = "Started / 已启动"
        case .bootstrapFailed:
            statusLabel.text = "Bootstrap failed / 启动失败"
            statusLabel.textColor = .systemRed
            startButton.isEnabled = false
            startButton.configuration?.title = "Relaunch to retry / 请重启重试"
        }
        detailLabel.text = detail
    }
}
