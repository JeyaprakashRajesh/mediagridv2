import UIKit
import Social
import UniformTypeIdentifiers

class ShareViewController: UIViewController {
    private let blurCard = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let cancelButton = UIButton(type: .system)

    private var host: String = ""
    private var token: String = ""
    private var pcName: String = "PC"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        loadCredentials()
        setupUI()
        processInput()
    }

    private func loadCredentials() {
        let group = UserDefaults(suiteName: "group.com.jeyaprakash.mediagrid")
        host = group?.string(forKey: "mg.host") ?? UserDefaults.standard.string(forKey: "mg.host") ?? ""
        token = group?.string(forKey: "mg.token") ?? UserDefaults.standard.string(forKey: "mg.token") ?? ""
        pcName = group?.string(forKey: "mg.pcName") ?? UserDefaults.standard.string(forKey: "mg.pcName") ?? "PC"
    }

    private func setupUI() {
        blurCard.translatesAutoresizingMaskIntoConstraints = false
        blurCard.layer.cornerRadius = 24
        blurCard.layer.masksToBounds = true
        view.addSubview(blurCard)

        let contentView = blurCard.contentView

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = UIImage(systemName: "desktopcomputer")
        iconView.tintColor = .systemTeal
        iconView.contentMode = .scaleAspectFit

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Copying to \(pcName)…"
        titleLabel.font = .systemFont(ofSize: 17, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.text = "Connecting…"
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        subtitleLabel.textAlignment = .center
        subtitleLabel.lineBreakMode = .byTruncatingMiddle

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = .white
        spinner.startAnimating()

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.setTitleColor(UIColor.white.withAlphaComponent(0.8), for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        cancelButton.addTarget(self, action: #selector(cancelShare), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [iconView, titleLabel, subtitleLabel, spinner, cancelButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            blurCard.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            blurCard.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            blurCard.widthAnchor.constraint(equalToConstant: 260),

            stack.topAnchor.constraint(equalTo: contentView.topAnchor, spacing: 24),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),

            iconView.heightAnchor.constraint(equalToConstant: 36),
            iconView.widthAnchor.constraint(equalToConstant: 36)
        ])
    }

    private func processInput() {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let providers = item.attachments, !providers.isEmpty else {
            finishWithError("Nothing to share")
            return
        }

        if host.isEmpty || token.isEmpty {
            openMainAppOrError("Please open MediaGrid to sign in first")
            return
        }

        // Try extracting URL / Web Link
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                p.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] item, _ in
                    if let url = item as? URL {
                        self?.sendText(url.absoluteString, label: url.host ?? url.absoluteString)
                    }
                }
                return
            }
        }

        // Try extracting Plain Text
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                p.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] item, _ in
                    if let text = item as? String {
                        self?.sendText(text, label: String(text.prefix(40)))
                    }
                }
                return
            }
        }

        // Try extracting File / Image / Media
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.data.identifier) ||
               p.hasItemConformingToTypeIdentifier(UTType.image.identifier) ||
               p.hasItemConformingToTypeIdentifier(UTType.item.identifier) {
                p.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { [weak self] url, _ in
                    if let url {
                        self?.sendFile(url: url)
                    } else {
                        // Fallback: loadItem
                        p.loadItem(forTypeIdentifier: UTType.item.identifier, options: nil) { [weak self] item, _ in
                            if let fileURL = item as? URL {
                                self?.sendFile(url: fileURL)
                            } else if let img = item as? UIImage, let data = img.jpegData(compressionQuality: 0.95) {
                                self?.sendData(data, name: "IMG_\(Int(Date().timeIntervalSince1970)).jpg")
                            } else {
                                self?.finishWithError("Couldn't read file")
                            }
                        }
                    }
                }
                return
            }
        }

        finishWithError("Unsupported content")
    }

    private func sendText(_ text: String, label: String) {
        DispatchQueue.main.async {
            self.subtitleLabel.text = label
        }

        guard let url = URL(string: "http://\(host)/api/shared/text") else {
            finishWithError("Invalid PC address")
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 8
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])

        URLSession.shared.dataTask(with: req) { [weak self] _, resp, err in
            DispatchQueue.main.async {
                if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    self?.finishSuccess("Copied to PC clipboard!")
                } else {
                    self?.finishWithError(err?.localizedDescription ?? "PC unreachable")
                }
            }
        }.resume()
    }

    private func sendFile(url: URL) {
        DispatchQueue.main.async {
            self.subtitleLabel.text = url.lastPathComponent
        }

        let name = url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "file"
        guard let targetURL = URL(string: "http://\(host)/api/shared/file?name=\(name)&t=\(token)") else {
            finishWithError("Invalid PC address")
            return
        }

        var req = URLRequest(url: targetURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300

        URLSession.shared.uploadTask(with: req, fromFile: url) { [weak self] _, resp, err in
            DispatchQueue.main.async {
                if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    self?.finishSuccess("Copied to PC Inbox!")
                } else {
                    self?.finishWithError(err?.localizedDescription ?? "PC unreachable")
                }
            }
        }.resume()
    }

    private func sendData(_ data: Data, name: String) {
        DispatchQueue.main.async {
            self.subtitleLabel.text = name
        }

        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "file"
        guard let targetURL = URL(string: "http://\(host)/api/shared/file?name=\(encodedName)&t=\(token)") else {
            finishWithError("Invalid PC address")
            return
        }

        var req = URLRequest(url: targetURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300

        URLSession.shared.uploadTask(with: req, from: data) { [weak self] _, resp, err in
            DispatchQueue.main.async {
                if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    self?.finishSuccess("Copied to PC Inbox!")
                } else {
                    self?.finishWithError(err?.localizedDescription ?? "PC unreachable")
                }
            }
        }.resume()
    }

    private func finishSuccess(_ msg: String) {
        spinner.stopAnimating()
        iconView.image = UIImage(systemName: "checkmark.circle.fill")
        iconView.tintColor = .systemGreen
        titleLabel.text = "Copied to PC"
        subtitleLabel.text = msg
        cancelButton.isHidden = true

        let feedback = UINotificationFeedbackGenerator()
        feedback.notificationOccurred(.success)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }

    private func finishWithError(_ msg: String) {
        spinner.stopAnimating()
        iconView.image = UIImage(systemName: "exclamationmark.circle.fill")
        iconView.tintColor = .systemRed
        titleLabel.text = "Transfer failed"
        subtitleLabel.text = msg

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            self.extensionContext?.cancelRequest(withError: NSError(domain: "MediaGridShare", code: 1, userInfo: [NSLocalizedDescriptionKey: msg]))
        }
    }

    private func openMainAppOrError(_ msg: String) {
        finishWithError(msg)
    }

    @objc private func cancelShare() {
        extensionContext?.cancelRequest(withError: NSError(domain: "MediaGridShare", code: 0, userInfo: nil))
    }
}
