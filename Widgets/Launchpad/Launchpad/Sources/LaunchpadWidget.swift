//
//  LaunchpadWidget.swift
//  Launchpad
//
//  Created by Luis on 20/11/2026.
//  Copyright © 2026 Luis. All rights reserved.
//

import AppKit
import PockKit

/// A Pock widget that puts Launchpad on the Touch Bar as a single button.
///
/// Launchpad is a system app and there is nothing to embed in it, so the button
/// only asks the workspace to open it, in the same way the system monitor items
/// open Activity Monitor or the storage settings.
///
/// The button answers both ways of pressing it: a finger on the bar, which the
/// widget tracks itself so the highlight appears while the finger is down, and
/// the mouse, which Pock reports to the widget through
/// `PKScreenEdgeMouseDelegate` rather than to any view.
public final class LaunchpadWidget: NSObject, PKWidget {

	// MARK: PKWidget

	public static var identifier: String = "Launchpad"

	public var customizationLabel: String = "Launchpad"

	public var view: NSView!

	// MARK: Data

	/// The app itself, not a URL scheme: Launchpad has no registered scheme, and
	/// opening the bundle is what lets the workspace bring an already open
	/// Launchpad back to the front instead of starting a second one.
	private static let applicationPath = "/System/Applications/Launchpad.app"

	/// The highlight behind the icon while it is pressed.
	///
	/// The same colour and shape the Dock widget paints for its own tiles:
	/// `NSColor.darkGray` behind the icon, filling the tile, corner radius 6.
	/// An opaque grey rather than a translucent white, so the two items cannot
	/// differ by whatever is behind them.
	private static let plateColor = NSColor.darkGray

	private let container = NSView(frame: .zero)

	private let plate = NSView(frame: .zero)

	private var button: PKButton!

	private var hidePlateWorkItem: DispatchWorkItem?

	// MARK: Init

	public override init() {
		super.init()
		setUpView()
	}

	// MARK: Set up

	private func setUpView() {
		container.wantsLayer = true

		plate.wantsLayer = true
		plate.translatesAutoresizingMaskIntoConstraints = false
		plate.layer?.backgroundColor = Self.plateColor.cgColor
		plate.layer?.cornerRadius = 6
		plate.isHidden = true

		/// `PKButton` draws a rounded bezel behind whatever it holds, which is a
		/// background that never goes away; the plate above replaces it.
		button = PKButton(title: "Launchpad", target: nil, action: nil)
		button.isBordered = false
		/// The button comes with an autoresizing mask, which would win over the
		/// constraints below and leave it at zero width.
		button.translatesAutoresizingMaskIntoConstraints = false
		button.image = Self.icon
		button.imagePosition = .imageOnly
		button.contentTintColor = .white

		/// `PKButton` recognises a click, which is reported only once the finger
		/// has lifted: nothing can be shown while the finger is still down, and an
		/// action here would open Launchpad a second time after the press gesture
		/// below already did. A press gesture reports every state change, which is
		/// what the Dock widget highlights with.
		for gesture in button.gestureRecognizers {
			button.removeGestureRecognizer(gesture)
		}
		let press = NSPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
		press.allowedTouchTypes = .direct
		/// Without this, a quick tap is over before the gesture begins and nothing
		/// happens at all.
		press.minimumPressDuration = 0
		button.addGestureRecognizer(press)

		container.addSubview(plate)
		container.addSubview(button, positioned: .above, relativeTo: plate)
		NSLayoutConstraint.activate([
			/// 40 × 30: the tile width the Dock widget gives each of its items, which
			/// makes the plate the same size as the background of the app next to it.
			container.widthAnchor.constraint(equalToConstant: 40),
			container.heightAnchor.constraint(equalToConstant: 30),

			/// The plate fills the cell, which is how the Dock widget pins its own
			/// (`edgesToSuperview`) — the bar is exactly 30 pt tall.
			plate.leadingAnchor.constraint(equalTo: container.leadingAnchor),
			plate.trailingAnchor.constraint(equalTo: container.trailingAnchor),
			plate.topAnchor.constraint(equalTo: container.topAnchor),
			plate.bottomAnchor.constraint(equalTo: container.bottomAnchor),

			button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
			button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
		])
		view = container
	}

	/// The nine tiles Launchpad is made of, in the same flat white as the other
	/// items on the bar.
	///
	/// The app's own icon was tried first: its light plate turns grey against the
	/// dark Touch Bar, which reads as a different style from its neighbours.
	private static var icon: NSImage? {
		guard let image = NSImage(systemSymbolName: "square.grid.3x3.fill",
								  accessibilityDescription: "Launchpad") else {
			return nil
		}
		/// 19 pt, which renders the glyph about as wide as the 24 pt icons the Dock
		/// widget draws in its tiles.
		let configuration = NSImage.SymbolConfiguration(pointSize: 19, weight: .regular)
		let sized = image.withSymbolConfiguration(configuration) ?? image
		sized.isTemplate = true
		return sized
	}

	// MARK: Action

	/// The finger path: the plate follows the press, and Launchpad opens when the
	/// finger leaves the bar.
	@objc internal func handlePress(_ gesture: NSPressGestureRecognizer) {
		switch gesture.state {
		case .began, .changed:
			setPlate(true)
		case .ended:
			setPlate(false)
			openLaunchpad()
		case .cancelled, .failed:
			setPlate(false)
		default:
			break
		}
	}

	private func openLaunchpad() {
		NSWorkspace.shared.open(URL(fileURLWithPath: Self.applicationPath))
	}

	private func setPlate(_ visible: Bool) {
		hidePlateWorkItem?.cancel()
		hidePlateWorkItem = nil
		plate.isHidden = !visible
	}

	/// Shows the plate for a moment, which is what a press looks like when only
	/// the click is reported: mouse support never says when the button came up.
	private func flashPlate() {
		setPlate(true)
		let work = DispatchWorkItem { [weak self] in
			self?.plate.isHidden = true
		}
		hidePlateWorkItem = work
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
	}
}

// MARK: Mouse support

/// Pock's mouse support watches a thin strip along the bottom edge of the screen
/// and forwards what happens there to the widgets, in the strip's own
/// coordinates, instead of sending events to their views. The Dock widget is
/// notified the same way.
extension LaunchpadWidget: PKScreenEdgeMouseDelegate {

	public func screenEdgeController(_ controller: PKScreenEdgeController, mouseEnteredAtLocation location: NSPoint, in view: NSView) {
		highlight(location, in: view)
	}

	public func screenEdgeController(_ controller: PKScreenEdgeController, mouseMovedAtLocation location: NSPoint, in view: NSView) {
		highlight(location, in: view)
	}

	public func screenEdgeController(_ controller: PKScreenEdgeController, mouseExitedAtLocation location: NSPoint, in view: NSView) {
		setPlate(false)
	}

	public func screenEdgeController(_ controller: PKScreenEdgeController, mouseClickAtLocation location: NSPoint, in view: NSView) {
		guard isOverItem(location, in: view) else {
			return
		}
		flashPlate()
		openLaunchpad()
	}

	private func highlight(_ location: NSPoint, in view: NSView) {
		setPlate(isOverItem(location, in: view))
	}

	/// Whether the pointer is over this item.
	///
	/// Only the horizontal position is compared: the strip is 10 pt tall while the
	/// bar is 30 pt, so the reported `y` says nothing about the item.
	private func isOverItem(_ location: NSPoint, in parentView: NSView) -> Bool {
		let frame = container.convert(container.bounds, to: parentView)
		guard frame.width > 0 else {
			return false
		}
		return location.x >= frame.minX - 2 && location.x <= frame.maxX + 2
	}
}
