// SPDX-License-Identifier: GPL-3.0-or-later
import UIKit

final class WelcomeViewController: UIViewController {
    var onDone: (() -> Void)?
    private let isPad: Bool

    init(isPad: Bool) {
        self.isPad = isPad
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = isPad ? .formSheet : .pageSheet
        sheetPresentationController?.detents = [.large()]
        sheetPresentationController?.prefersGrabberVisible = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let content = UIStackView()
        content.axis = .vertical; content.spacing = 18
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)

        let icon = UIImageView(image: UIImage(systemName: "car.side.fill"))
        icon.tintColor = .systemBlue
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
        content.addArrangedSubview(icon)

        let title = label(isPad ? "Make this iPad your CarPlay display" : "CarPlay on the screen you choose", style: .largeTitle, color: .label)
        title.font = .preferredFont(forTextStyle: .largeTitle).withWeight(.bold)
        content.addArrangedSubview(title)
        content.addArrangedSubview(label(isPad
            ? "This iPad receives the picture, touch input and audio from your iPhone."
            : "Use this iPhone as a display, send CarPlay to an iPad, or open a local browser display in your car.",
            style: .body, color: .secondaryLabel))

        if isPad {
            content.addArrangedSubview(step("1", "Start the display", "Connect this iPad to Wi-Fi, then tap Start CarPlay display."))
            content.addArrangedSubview(step("2", "Connect from your iPhone", "Open TDS Car Kit on the iPhone, choose Send to an iPad and select this display."))
            content.addArrangedSubview(step("3", "Use CarPlay", "Accept the iPhone prompt. The iPad shows CarPlay and plays audio through its speakers."))
        } else {
            content.addArrangedSubview(step("1", "Choose a role", "The three choices on the next screen tell you where CarPlay will appear."))
            content.addArrangedSubview(step("2", "Connect both screens", "If you use an iPad or a car browser, keep both devices on the same reachable Wi-Fi network."))
            content.addArrangedSubview(step("3", "Start and keep the app open", "For a car browser, enable browser standby in Setup and tap Connect CarPlay in the browser. Accept the iPhone prompt, then use the chosen screen for touch input."))
        }

        let why = UIStackView()
        why.axis = .vertical; why.spacing = 8
        why.isLayoutMarginsRelativeArrangement = true
        why.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18)
        why.backgroundColor = .secondarySystemGroupedBackground
        why.layer.cornerRadius = 18
        why.addArrangedSubview(label(isPad ? "About Wi-Fi" : "Why do we ask for a Wi-Fi password?", style: .headline, color: .label))
        why.addArrangedSubview(label(isPad
            ? "The iPad receiver normally needs no Wi-Fi password in TDS Car Kit. It just needs to be on the same network as the iPhone."
            : "The CarPlay accessory handshake needs the network name and password so iOS can establish the connection. TDS Car Kit does not change your Wi-Fi settings. The password is saved in this iPhone’s Keychain, never in diagnostics, and can be forgotten in Setup. An open network needs no password.",
            style: .subheadline, color: .secondaryLabel))
        content.addArrangedSubview(why)

        let done = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = "Get started"
        config.cornerStyle = .large
        config.contentInsets = NSDirectionalEdgeInsets(top: 18, leading: 24, bottom: 18, trailing: 24)
        done.configuration = config
        done.addTarget(self, action: #selector(finish), for: .touchUpInside)
        done.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(done)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 28),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: done.topAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            content.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            done.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            done.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            done.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
    }

    private func label(_ text: String, style: UIFont.TextStyle, color: UIColor) -> UILabel {
        let view = UILabel()
        view.text = text; view.numberOfLines = 0
        view.font = .preferredFont(forTextStyle: style)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = color
        return view
    }
    private func step(_ number: String, _ title: String, _ detail: String) -> UIView {
        let badge = label(number, style: .headline, color: .white)
        badge.textAlignment = .center; badge.backgroundColor = .systemBlue
        badge.layer.cornerRadius = 18; badge.clipsToBounds = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([badge.widthAnchor.constraint(equalToConstant: 36), badge.heightAnchor.constraint(equalToConstant: 36)])
        let copy = UIStackView(arrangedSubviews: [label(title, style: .headline, color: .label),
                                                   label(detail, style: .subheadline, color: .secondaryLabel)])
        copy.axis = .vertical; copy.spacing = 4
        let row = UIStackView(arrangedSubviews: [badge, copy])
        row.alignment = .top; row.spacing = 14
        return row
    }
    @objc private func finish() { onDone?(); dismiss(animated: true) }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
