#if os(macOS)
import AppKit
import Foundation

extension KeyboardShortcuts {
	nonisolated public enum EventType: Sendable, Equatable {
		case keyDown
		case keyUp
	}

	/**
	Listen to the keyboard shortcut with the given name being pressed.

	You can register multiple listeners.

	You can safely call this even if the user has not yet set a keyboard shortcut. It will just be inactive until they do.

	Ending the async sequence will stop the listener. For example, in the below example, the listener will stop when the view disappears.

	```swift
	import SwiftUI
	import KeyboardShortcuts

	struct ContentView: View {
		@State private var isUnicornMode = false

		var body: some View {
			Text(isUnicornMode ? "🦄" : "🐴")
				.task {
					for await event in KeyboardShortcuts.events(for: .toggleUnicornMode) where event == .keyUp {
						isUnicornMode.toggle()
					}
				}
		}
	}
	```

	- Note: This method is not affected by `.removeAllHandlers()`.
	*/
	public static func events(for name: Name) -> AsyncStream<KeyboardShortcuts.EventType> {
		AsyncStream { continuation in
			let id = UUID()

			streamKeyDownHandlers[name, default: [:]][id] = {
				continuation.yield(.keyDown)
			}

			streamKeyUpHandlers[name, default: [:]][id] = {
				continuation.yield(.keyUp)
			}

			registerIfNeeded(for: name)

			continuation.onTermination = { _ in
				Task { @MainActor in
					removeStreamHandlerEntry(id, for: name, in: &streamKeyDownHandlers)
					removeStreamHandlerEntry(id, for: name, in: &streamKeyUpHandlers)

					unregisterIfNeeded(for: name, excludingCurrentName: false)
				}
			}
		}
	}

	/**
	Listen to hard-coded keyboard shortcut events.

	Use this for shortcuts you define in code instead of storing in ``Name``.

	Ending the async sequence will stop the listener.

	```swift
	import KeyboardShortcuts

	let shortcut = KeyboardShortcuts.Shortcut(.a, modifiers: [.command])

	Task {
		for await eventType in KeyboardShortcuts.events(for: shortcut) where eventType == .keyUp {
			// Do something.
		}
	}
	```

	- Important: In apps distributed to users, prefer user-customizable shortcuts when possible.
	- Note: This method is not affected by `.removeAllHandlers()`.
	*/
	public static func events(for shortcut: Shortcut) -> AsyncStream<KeyboardShortcuts.EventType> {
		AsyncStream { continuation in
			let id = UUID()

			streamShortcutKeyDownHandlers[shortcut, default: [:]][id] = {
				continuation.yield(.keyDown)
			}

			streamShortcutKeyUpHandlers[shortcut, default: [:]][id] = {
				continuation.yield(.keyUp)
			}

			registerIfNeeded(for: shortcut)

			continuation.onTermination = { _ in
				Task { @MainActor in
					removeStreamHandlerEntry(id, for: shortcut, in: &streamShortcutKeyDownHandlers)
					removeStreamHandlerEntry(id, for: shortcut, in: &streamShortcutKeyUpHandlers)

					unregisterIfNeeded(for: shortcut)
				}
			}
		}
	}

	/**
	Listen to keyboard shortcut events with the given name and type.

	You can register multiple listeners.

	You can safely call this even if the user has not yet set a keyboard shortcut. It will just be inactive until they do.

	Ending the async sequence will stop the listener. For example, in the below example, the listener will stop when the view disappears.

	```swift
	import SwiftUI
	import KeyboardShortcuts

	struct ContentView: View {
		@State private var isUnicornMode = false

		var body: some View {
			Text(isUnicornMode ? "🦄" : "🐴")
				.task {
					for await event in KeyboardShortcuts.events(for: .toggleUnicornMode) where event == .keyUp {
						isUnicornMode.toggle()
					}
				}
		}
	}
	```

	- Note: This method is not affected by `.removeAllHandlers()`.
	*/
	public static func events(_ type: EventType, for name: Name) -> AsyncFilterSequence<AsyncStream<EventType>> {
		events(for: name).filter { $0 == type }
	}

	/**
	Listen to hard-coded keyboard shortcut events with the given type.

	Ending the async sequence will stop the listener.

	- Important: In apps distributed to users, prefer user-customizable shortcuts when possible.
	- Note: This method is not affected by `.removeAllHandlers()`.
	*/
	public static func events(_ type: EventType, for shortcut: Shortcut) -> AsyncFilterSequence<AsyncStream<EventType>> {
		events(for: shortcut).filter { $0 == type }
	}

	/**
	Listen to a keyboard shortcut and emit immediately on key down, then repeat while the key is held.

	This follows the system key repeat settings (`NSEvent.keyRepeatDelay` and `NSEvent.keyRepeatInterval`).

	Ending the async sequence will stop the listener.

	```swift
	import KeyboardShortcuts

	Task {
		for await _ in KeyboardShortcuts.repeatingKeyDownEvents(for: .moveSelectionDown) {
			// Move selection down.
		}
	}
	```

	- Note: This method is not affected by `.removeAllHandlers()`.
	*/
	@available(macOS 13, *)
	public static func repeatingKeyDownEvents(for name: Name) -> AsyncStream<Void> {
		@MainActor
		final class RepeatState {
			// Snapshot the shortcut that initiated the current hold.
			// If the name is rebound while held, we stop repeating for the old binding.
			var heldShortcut: Shortcut?
		}

		let repeatState = RepeatState()

		return repeatingKeyDownEvents(
			from: events(for: name),
			didReceiveKeyDown: {
				repeatState.heldShortcut = getShortcut(for: name)
			},
			shouldContinueRepeating: {
				guard
					!isPaused,
					isEnabled(for: name),
					let heldShortcut = repeatState.heldShortcut
				else {
					return false
				}

				return getShortcut(for: name) == heldShortcut
			}
		)
	}

	/**
	Listen to a hard-coded keyboard shortcut and emit immediately on key down, then repeat while the key is held.

	This follows the system key repeat settings (`NSEvent.keyRepeatDelay` and `NSEvent.keyRepeatInterval`).

	Ending the async sequence will stop the listener.

	```swift
	import KeyboardShortcuts

	let shortcut = KeyboardShortcuts.Shortcut(.a, modifiers: [.command])

	Task {
		for await _ in KeyboardShortcuts.repeatingKeyDownEvents(for: shortcut) {
			// Do something repeatedly.
		}
	}
	```

	- Important: In apps distributed to users, prefer user-customizable shortcuts when possible.
	- Note: This method is not affected by `.removeAllHandlers()`.
	*/
	@available(macOS 13, *)
	public static func repeatingKeyDownEvents(for shortcut: Shortcut) -> AsyncStream<Void> {
		repeatingKeyDownEvents(
			from: events(for: shortcut),
			shouldContinueRepeating: { // swiftlint:disable:this trailing_closure
				!isPaused
					&& isEnabled
					&& hotKeys[shortcut] != nil
			}
		)
	}

	/**
	Creates a stream that emits immediately on `keyDown` and then repeats until `keyUp`.

	This is internal to support deterministic testing with custom timings.
	*/
	@available(macOS 13, *)
	static func repeatingKeyDownEvents(
		from events: AsyncStream<EventType>,
		repeatDelay: Duration = .seconds(NSEvent.keyRepeatDelay),
		repeatInterval: Duration = .seconds(NSEvent.keyRepeatInterval),
		didReceiveKeyDown: @escaping @Sendable @MainActor () -> Void = {},
		shouldContinueRepeating: @escaping @Sendable @MainActor () -> Bool = { true }
	) -> AsyncStream<Void> {
		// Keep only the latest pending emission if the consumer falls behind.
		AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
			let repeatingTaskController = RepeatingTaskController()

			let eventsTask = Task {
				for await event in events {
					switch event {
					case .keyDown:
						await MainActor.run(body: didReceiveKeyDown)

						continuation.yield()
						await repeatingTaskController.start(
							repeatDelay: repeatDelay,
							repeatInterval: repeatInterval,
							shouldContinueRepeating: shouldContinueRepeating
						) {
							continuation.yield()
						}
					case .keyUp:
						await repeatingTaskController.stop()
					}
				}

				// Source ended without key-up (for example due to unregister/disable); stop repeating.
				await repeatingTaskController.stop()
				continuation.finish()
			}

			continuation.onTermination = { _ in
				eventsTask.cancel()

				Task {
					await repeatingTaskController.stop()
				}
			}
		}
	}

	@available(macOS 13, *)
	private actor RepeatingTaskController {
		private var task: Task<Void, Never>?

		func start(
			repeatDelay: Duration,
			repeatInterval: Duration,
			shouldContinueRepeating: @escaping @Sendable @MainActor () -> Bool,
			action: @Sendable @escaping () -> Void
		) {
			stop()

			task = Task {
				do {
					try await Task.sleep(for: repeatDelay)
				} catch {
					return
				}

				while !Task.isCancelled {
					guard await shouldContinueRepeating() else {
						// Active-state changed (pause/disable/rebind/unregister), so stop repeating.
						return
					}

					guard !Task.isCancelled else {
						return
					}

					action()

					do {
						try await Task.sleep(for: repeatInterval)
					} catch {
						return
					}
				}
			}
		}

		func stop() {
			task?.cancel()
			task = nil
		}
	}
}

extension Notification.Name {
	static let shortcutByNameDidChange = Self("KeyboardShortcuts_shortcutByNameDidChange")
}
#endif
