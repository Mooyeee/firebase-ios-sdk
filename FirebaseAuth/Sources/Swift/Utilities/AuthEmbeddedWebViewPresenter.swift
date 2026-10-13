// Copyright 2023 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#if os(macOS)

  import AppKit
  import Foundation

  /// Custom window class for OAuth flow.
  final class AuthWebWindow: NSWindow {
    weak var authViewController: NSViewController?

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
      super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
      setupWindow()
    }

    private func setupWindow() {
      title = "Sign In"
      isReleasedWhenClosed = false
      center()
      level = .normal
      styleMask = [.titled, .closable, .miniaturizable, .resizable]
    }
  }

  /// Presents an embedded OAuth web view in a dedicated macOS window.
  ///
  /// The web view controller observes window-close notifications and handles
  /// user cancellation. A programmatic dismissal must first mark the flow as
  /// finished to prevent the close from being treated as user cancellation.
  @available(macOS 11.0, *)
  final class AuthEmbeddedWebViewPresenter {
    private var authWindow: AuthWebWindow?

    /// Presents the OAuth web view in a new window.
    /// - Parameter viewController: The web view controller to present.
    /// - Parameter completion: The block to execute after the window is shown.
    func present(_ viewController: NSViewController,
                 completion: (() -> Void)? = nil) {
      // Create a new window for the OAuth flow.
      let windowRect = NSRect(x: 0, y: 0, width: 800, height: 600)
      let window = AuthWebWindow(
        contentRect: windowRect,
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
      )

      window.authViewController = viewController
      window.contentViewController = viewController
      authWindow = window
      window.makeKeyAndOrderFront(nil)

      completion?()
    }

    /// Dismisses the OAuth window.
    /// The caller must mark the authentication flow as finished before dismissal.
    /// - Parameter completion: The block to execute after the window is closed.
    func dismiss(completion: (() -> Void)? = nil) {
      authWindow?.authViewController = nil
      authWindow?.close()
      authWindow = nil
      completion?()
    }
  }

#endif // os(macOS)
