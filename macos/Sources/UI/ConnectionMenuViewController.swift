import Cocoa

/// Sheet presented when the user clicks "+" on an empty workspace tile.
/// Uses tabs to separate mutually exclusive connection modes:
///   Local | SSH | Devcontainer
/// Common options (name, ext-*, env vars) are shared below the tabs.
final class ConnectionMenuViewController: NSViewController {

    var onConnect: ((WorkspaceManager.ConnectionConfig) -> Void)?

    // MARK: - Common controls

    private let nameField = NSTextField()
    private let nvimPathField = NSTextField()
    private let tabView = NSTabView()
    private let extCmdlineCheck = NSButton(checkboxWithTitle: "ext-cmdline", target: nil, action: nil)
    private let extPopupCheck = NSButton(checkboxWithTitle: "ext-popupmenu", target: nil, action: nil)
    private let extMessagesCheck = NSButton(checkboxWithTitle: "ext-messages", target: nil, action: nil)
    private let extTablineCheck = NSButton(checkboxWithTitle: "ext-tabline", target: nil, action: nil)
    private let envVarsTextView = NSTextView()

    // MARK: - SSH controls

    private let sshHostField = NSTextField()
    private let sshPortField = NSTextField()
    private let sshIdentityField = NSTextField()

    // MARK: - Devcontainer controls

    private let devcontainerWorkspaceField = NSTextField()
    private let devcontainerConfigField = NSTextField()
    private let devcontainerRebuildCheck = NSButton(checkboxWithTitle: "Rebuild on start", target: nil, action: nil)

    // MARK: - Layout

    private let sheetWidth: CGFloat = 440
    private let margin: CGFloat = 20
    private let fieldHeight: CGFloat = 24
    private let labelHeight: CGFloat = 16
    private let spacing: CGFloat = 6

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: sheetWidth, height: 500))
        self.view = container

        let fieldWidth = sheetWidth - margin * 2
        var y: CGFloat = 470

        // -- Name --
        y = addLabel("Name", to: container, at: y)
        y = addField(nameField, placeholder: "My Workspace", to: container, at: y, width: fieldWidth)

        // -- Nvim Path --
        y = addLabel("Nvim Path (empty = default)", to: container, at: y)
        y = addField(nvimPathField, placeholder: "/usr/local/bin/nvim", to: container, at: y, width: fieldWidth)

        // -- Connection Mode Tabs --
        y -= 4
        let tabHeight: CGFloat = 140
        tabView.frame = NSRect(x: margin, y: y - tabHeight, width: fieldWidth, height: tabHeight)
        tabView.tabViewType = .topTabsBezelBorder

        // Tab 1: Local
        let localTab = NSTabViewItem(identifier: "local")
        localTab.label = "Local"
        let localView = NSView(frame: NSRect(x: 0, y: 0, width: fieldWidth - 20, height: tabHeight - 30))
        let localLabel = NSTextField(labelWithString: "No additional configuration needed.\nNvim will run locally.")
        localLabel.font = NSFont.systemFont(ofSize: 12)
        localLabel.textColor = .secondaryLabelColor
        localLabel.frame = NSRect(x: 10, y: tabHeight - 80, width: fieldWidth - 40, height: 36)
        localView.addSubview(localLabel)
        localTab.view = localView
        tabView.addTabViewItem(localTab)

        // Tab 2: SSH
        let sshTab = NSTabViewItem(identifier: "ssh")
        sshTab.label = "SSH"
        let sshView = NSView(frame: NSRect(x: 0, y: 0, width: fieldWidth - 20, height: tabHeight - 30))
        layoutSSHTab(in: sshView, width: fieldWidth - 40)
        sshTab.view = sshView
        tabView.addTabViewItem(sshTab)

        // Tab 3: Devcontainer
        let dcTab = NSTabViewItem(identifier: "devcontainer")
        dcTab.label = "Devcontainer"
        let dcView = NSView(frame: NSRect(x: 0, y: 0, width: fieldWidth - 20, height: tabHeight - 30))
        layoutDevcontainerTab(in: dcView, width: fieldWidth - 40)
        dcTab.view = dcView
        tabView.addTabViewItem(dcTab)

        container.addSubview(tabView)
        y -= tabHeight + 8

        // -- Options --
        y = addLabel("Options", to: container, at: y)
        let checkRow1 = NSStackView(views: [extCmdlineCheck, extPopupCheck])
        checkRow1.orientation = .horizontal
        checkRow1.spacing = 16
        checkRow1.frame = NSRect(x: margin, y: y - 18, width: fieldWidth, height: 18)
        container.addSubview(checkRow1)
        y -= 24

        let checkRow2 = NSStackView(views: [extMessagesCheck, extTablineCheck])
        checkRow2.orientation = .horizontal
        checkRow2.spacing = 16
        checkRow2.frame = NSRect(x: margin, y: y - 18, width: fieldWidth, height: 18)
        container.addSubview(checkRow2)
        y -= 24

        // Apply defaults from global config
        let appConfig = ZonvieConfig.shared
        extCmdlineCheck.state = appConfig.cmdline.external ? .on : .off
        extPopupCheck.state = appConfig.popup.external ? .on : .off
        extMessagesCheck.state = appConfig.messages.external ? .on : .off
        extTablineCheck.state = appConfig.tabline.external ? .on : .off

        // -- Environment Variables --
        y = addLabel("Environment Variables (KEY=VALUE per line)", to: container, at: y)

        let scrollView = NSScrollView(frame: NSRect(x: margin, y: y - 64, width: fieldWidth, height: 64))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        envVarsTextView.isEditable = true
        envVarsTextView.isRichText = false
        envVarsTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        envVarsTextView.minSize = NSSize(width: 0, height: 64)
        envVarsTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        envVarsTextView.isVerticallyResizable = true
        envVarsTextView.isHorizontallyResizable = false
        envVarsTextView.textContainer?.widthTracksTextView = true
        scrollView.documentView = envVarsTextView
        container.addSubview(scrollView)

        // -- Buttons --
        let connectButton = NSButton(title: "Connect", target: self, action: #selector(connectAction))
        connectButton.keyEquivalent = "\r"
        connectButton.bezelStyle = .rounded
        connectButton.frame = NSRect(x: sheetWidth - margin - 90, y: 12, width: 90, height: 30)
        container.addSubview(connectButton)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelAction))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.bezelStyle = .rounded
        cancelButton.frame = NSRect(x: sheetWidth - margin - 90 - 8 - 80, y: 12, width: 80, height: 30)
        container.addSubview(cancelButton)
    }

    // MARK: - Tab layouts

    private func layoutSSHTab(in parent: NSView, width: CGFloat) {
        let x: CGFloat = 10
        var y = parent.bounds.height - 10

        let hostLabel = NSTextField(labelWithString: "Host:")
        hostLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        hostLabel.frame = NSRect(x: x, y: y - labelHeight, width: 40, height: labelHeight)
        parent.addSubview(hostLabel)

        sshHostField.placeholderString = "user@host"
        sshHostField.font = NSFont.systemFont(ofSize: 13)
        sshHostField.frame = NSRect(x: x + 44, y: y - fieldHeight + 2, width: width - 54, height: fieldHeight)
        parent.addSubview(sshHostField)
        y -= 32

        let portLabel = NSTextField(labelWithString: "Port:")
        portLabel.font = NSFont.systemFont(ofSize: 12)
        portLabel.frame = NSRect(x: x, y: y - labelHeight, width: 35, height: labelHeight)
        parent.addSubview(portLabel)

        sshPortField.placeholderString = "22"
        sshPortField.font = NSFont.systemFont(ofSize: 13)
        sshPortField.frame = NSRect(x: x + 38, y: y - fieldHeight + 2, width: 60, height: fieldHeight)
        parent.addSubview(sshPortField)

        let idLabel = NSTextField(labelWithString: "Identity:")
        idLabel.font = NSFont.systemFont(ofSize: 12)
        idLabel.frame = NSRect(x: x + 110, y: y - labelHeight, width: 55, height: labelHeight)
        parent.addSubview(idLabel)

        sshIdentityField.placeholderString = "~/.ssh/id_rsa"
        sshIdentityField.font = NSFont.systemFont(ofSize: 13)
        sshIdentityField.frame = NSRect(x: x + 168, y: y - fieldHeight + 2, width: width - 178, height: fieldHeight)
        parent.addSubview(sshIdentityField)
    }

    private func layoutDevcontainerTab(in parent: NSView, width: CGFloat) {
        let x: CGFloat = 10
        var y = parent.bounds.height - 10

        let wsLabel = NSTextField(labelWithString: "Workspace:")
        wsLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        wsLabel.frame = NSRect(x: x, y: y - labelHeight, width: 80, height: labelHeight)
        parent.addSubview(wsLabel)

        devcontainerWorkspaceField.placeholderString = "/path/to/project"
        devcontainerWorkspaceField.font = NSFont.systemFont(ofSize: 13)
        devcontainerWorkspaceField.frame = NSRect(x: x + 84, y: y - fieldHeight + 2, width: width - 94, height: fieldHeight)
        parent.addSubview(devcontainerWorkspaceField)
        y -= 32

        let cfgLabel = NSTextField(labelWithString: "Config:")
        cfgLabel.font = NSFont.systemFont(ofSize: 12)
        cfgLabel.frame = NSRect(x: x, y: y - labelHeight, width: 50, height: labelHeight)
        parent.addSubview(cfgLabel)

        devcontainerConfigField.placeholderString = ".devcontainer/devcontainer.json"
        devcontainerConfigField.font = NSFont.systemFont(ofSize: 13)
        devcontainerConfigField.frame = NSRect(x: x + 54, y: y - fieldHeight + 2, width: width - 64, height: fieldHeight)
        parent.addSubview(devcontainerConfigField)
        y -= 30

        devcontainerRebuildCheck.frame = NSRect(x: x, y: y - 18, width: 200, height: 18)
        parent.addSubview(devcontainerRebuildCheck)
    }

    // MARK: - Helpers

    @discardableResult
    private func addLabel(_ text: String, to parent: NSView, at y: CGFloat) -> CGFloat {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.frame = NSRect(x: margin, y: y - labelHeight, width: sheetWidth - margin * 2, height: labelHeight)
        parent.addSubview(label)
        return y - labelHeight - spacing
    }

    @discardableResult
    private func addField(_ field: NSTextField, placeholder: String, to parent: NSView, at y: CGFloat, width: CGFloat) -> CGFloat {
        field.placeholderString = placeholder
        field.font = NSFont.systemFont(ofSize: 13)
        field.frame = NSRect(x: margin, y: y - fieldHeight, width: width, height: fieldHeight)
        parent.addSubview(field)
        return y - fieldHeight - spacing
    }

    // MARK: - Actions

    @objc private func connectAction() {
        var config = WorkspaceManager.ConnectionConfig()
        config.name = nameField.stringValue
        config.nvimPath = nvimPathField.stringValue
        config.extCmdline = extCmdlineCheck.state == .on
        config.extPopupmenu = extPopupCheck.state == .on
        config.extMessages = extMessagesCheck.state == .on
        config.extTabline = extTablineCheck.state == .on
        config.envVars = envVarsTextView.string

        // Fill connection-specific fields based on selected tab
        let selectedId = tabView.selectedTabViewItem?.identifier as? String ?? "local"
        switch selectedId {
        case "ssh":
            config.sshHost = sshHostField.stringValue
            config.sshPort = sshPortField.stringValue
            config.sshIdentity = sshIdentityField.stringValue
        case "devcontainer":
            config.devcontainerWorkspace = devcontainerWorkspaceField.stringValue
            config.devcontainerConfig = devcontainerConfigField.stringValue
        default:
            break // local — no extra fields
        }

        dismiss(self)
        onConnect?(config)
    }

    @objc private func cancelAction() {
        dismiss(self)
    }
}
