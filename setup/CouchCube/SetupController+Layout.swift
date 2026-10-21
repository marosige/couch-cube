import AppKit
import CoreBluetooth
import EventKit
import GameController
import IOBluetooth
import IOKit.hid
import QuartzCore
import UniformTypeIdentifiers


extension SetupController {
    func text(_ value: String, size: CGFloat = 13, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.font = .systemFont(ofSize: size)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        return field
    }

    func pin(_ view: NSView, to host: NSView) {
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
    }

    func separator() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    func statusIndicator(_ title: String, color: NSColor, pulsing: Bool = false) -> NSView {
        let dot = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)!)
        dot.contentTintColor = color
        dot.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        if pulsing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            dot.wantsLayer = true
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.25
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            dot.layer?.add(pulse, forKey: "checking")
        }
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        let result = row([dot, label])
        result.setHuggingPriority(.required, for: .horizontal)
        result.spacing = 5
        result.setAccessibilityLabel(title)
        return result
    }

    func addSectionHeading(_ title: String, to rows: NSStackView) {
        let heading = text(title, size: 12, secondary: true)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        let container = NSView()
        heading.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(heading)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            heading.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            heading.topAnchor.constraint(equalTo: container.topAnchor, constant: rows.arrangedSubviews.isEmpty ? 4 : 18),
            heading.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6)
        ])
        rows.addArrangedSubview(container)
        container.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }

    func hero(_ title: String, subtitle: String) -> NSStackView {
        let image = NSImageView(image: NSImage(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("Console.icns"))!)
        image.imageScaling = .scaleProportionallyUpOrDown
        image.widthAnchor.constraint(equalToConstant: 88).isActive = true
        image.heightAnchor.constraint(equalToConstant: 88).isActive = true
        let images = row([NSView(), image, NSView()])
        images.arrangedSubviews[0].widthAnchor.constraint(equalTo: images.arrangedSubviews[2].widthAnchor).isActive = true
        let heading = text(title, size: 28)
        heading.font = .systemFont(ofSize: 28, weight: .bold)
        heading.alignment = .center
        let caption = text(subtitle, size: 14, secondary: true)
        caption.alignment = .center
        let result = column([images, heading, caption])
        result.spacing = 16
        return result
    }

    func column(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.distribution = .fill
        for view in views {
            if view is NSButton && !(view is StorageChoiceButton) {
                view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
            } else {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        return stack
    }

    func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        return stack
    }

    func card(_ title: String, subtitle: String?, views: [NSView], inset: CGFloat = 16) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 0.5
        box.borderColor = .separatorColor
        box.cornerRadius = 12
        box.fillColor = .quaternaryLabelColor
        box.titlePosition = .noTitle
        box.contentViewMargins = .zero
        let heading = text(title, size: 13)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        var contents: [NSView] = title.isEmpty ? [] : [heading]
        if let subtitle = subtitle { contents.append(text(subtitle, size: 12, secondary: true)) }
        contents += views
        let stack = column(contents)
        for view in contents where !(view is NSButton) {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.contentView!.topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: box.contentView!.bottomAnchor, constant: -inset),
            stack.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor, constant: -inset)
        ])
        return box
    }

    func headerIconButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let control = NSButton(title: "", target: self, action: action)
        control.image = symbol.isEmpty ? nil : NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        control.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        control.bezelStyle = .inline
        control.isBordered = false
        control.contentTintColor = .secondaryLabelColor
        control.toolTip = label
        control.setAccessibilityLabel(label)
        control.widthAnchor.constraint(equalToConstant: 24).isActive = true
        control.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return control
    }

    func cardHeader(_ title: String, buttons: [NSView]) -> NSStackView {
        let heading = text(title, size: 13)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = row([heading, NSView()] + buttons)
        header.distribution = .fill
        header.spacing = 10
        for view in buttons { view.setContentHuggingPriority(.required, for: .horizontal) }
        return header
    }
}
