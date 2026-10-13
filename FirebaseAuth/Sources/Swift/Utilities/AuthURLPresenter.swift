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

#if os(iOS) || os(macOS)

  import Foundation
  import WebKit

  #if os(iOS)
    import SafariServices
    import UIKit
  #elseif os(macOS)
    import AppKit
    import AuthenticationServices

    /// Specifies how the OAuth authentication flow is presented on macOS.
    @objc(FIRAuthPresentationMode)
    public enum AuthPresentationMode: Int {
      /// Uses the system authentication session.
      /// This is the recommended option and the default.
      case systemBrowser

      /// Uses an embedded WKWebView in a separate application window.
      /// Embedded web views do not share the browser's authentication state
      /// and may be blocked by some identity providers.
      case embeddedWebView
    }
  #endif

  /// A Class responsible for presenting URL via SFSafariViewController or WKWebView.
  @available(iOS 13, macOS 10.15, *)
  class AuthURLPresenter: NSObject, AuthWebViewControllerDelegate {
    #if os(macOS)
      private var systemPresenter: AuthWebAuthenticationSessionPresenter?
    #endif

    /// Presents an URL to interact with user.
    /// - Parameter url: The URL to present.
    /// - Parameter uiDelegate: The UI delegate to present view controller.
    /// - Parameter completion: A block to be called either synchronously if the presentation fails
    /// to start, or asynchronously in future on an unspecified thread once the presentation
    /// finishes.
    func present(_ url: URL,
                 uiDelegate: AuthUIDelegate?,
                 callbackURLScheme: String? = nil,
                 callbackMatcher: @escaping (URL?) -> Bool,
                 completion: @escaping (URL?, Error?) -> Void) {
      #if os(macOS)
        present(url,
                uiDelegate: uiDelegate,
                callbackURLScheme: callbackURLScheme,
                presentationMode: .systemBrowser,
                callbackMatcher: callbackMatcher,
                completion: completion)
      #else
        kAuthGlobalWorkQueue.async { [self] in
          if self.isPresenting {
            // Unable to start a new presentation on top of another.
            // Invoke the new completion closure and leave the old one as-is
            // to be invoked when the presentation finishes.
            DispatchQueue.main.async {
              completion(nil, AuthErrorUtils.webContextCancelledError(message: nil))
            }
            return
          }
          self.isPresenting = true
          self.callbackMatcher = callbackMatcher
          self.completion = completion
          DispatchQueue.main.async {
            self.uiDelegate = uiDelegate ?? AuthDefaultUIDelegate.defaultUIDelegate()
            #if targetEnvironment(macCatalyst)
              self.webViewController = AuthWebViewController(url: url, delegate: self)
              if let webViewController = self.webViewController {
                let navController = UINavigationController(rootViewController: webViewController)
                navController.modalPresentationStyle = .fullScreen
                if let fakeUIDelegate = self.fakeUIDelegate {
                  fakeUIDelegate.present(navController, animated: true)
                } else {
                  self.uiDelegate?.present(navController, animated: true)
                }
              }
            #else
              self.safariViewController = SFSafariViewController(url: url)
              self.safariViewController?.delegate = self
              if let safariViewController = self.safariViewController {
                if let fakeUIDelegate = self.fakeUIDelegate {
                  fakeUIDelegate.present(safariViewController, animated: true)
                } else {
                  self.uiDelegate?.present(safariViewController, animated: true)
                }
              }
            #endif
          }
        }
      #endif
    }

    #if os(macOS)
      /// Presents an URL using the specified macOS authentication presentation mode.
      /// - Parameter url: The URL to present.
      /// - Parameter uiDelegate: The UI delegate used for presentation.
      /// - Parameter callbackURLScheme: The registered callback URL scheme.
      /// - Parameter presentationMode: The authentication presentation mode.
      /// - Parameter callbackMatcher: Determines whether the callback URL is expected.
      /// - Parameter completion: Called when the presentation finishes.
      func present(_ url: URL,
                   uiDelegate: AuthUIDelegate?,
                   callbackURLScheme: String?,
                   presentationMode: AuthPresentationMode,
                   callbackMatcher: @escaping (URL?) -> Bool,
                   completion: @escaping (URL?, Error?) -> Void) {
        kAuthGlobalWorkQueue.async { [self] in
          if self.isPresenting {
            // Unable to start a new presentation on top of another.
            // Invoke the new completion closure and leave the old one as-is
            // to be invoked when the presentation finishes.
            DispatchQueue.main.async {
              completion(nil, AuthErrorUtils.webContextCancelledError(message: nil))
            }
            return
          }
          self.isPresenting = true
          self.callbackMatcher = callbackMatcher
          self.completion = completion
          DispatchQueue.main.async {
            self.uiDelegate = uiDelegate ?? AuthDefaultUIDelegate.defaultUIDelegate()
            switch presentationMode {
            case .embeddedWebView:
              self.webViewController = AuthWebViewController(url: url, delegate: self)

              if let webViewController = self.webViewController {
                if let presentingDelegate = self.fakeUIDelegate ?? self.uiDelegate {
                  presentingDelegate.present(webViewController)
                } else {
                  kAuthGlobalWorkQueue.async {
                    self.finishPresentation(
                      withURL: nil,
                      error: AuthErrorUtils.webContextCancelledError(
                        message: "No UI delegate available to present the login flow."
                      )
                    )
                  }
                }
              }
            case .systemBrowser:
              guard let callbackURLScheme, !callbackURLScheme.isEmpty else {
                kAuthGlobalWorkQueue.async {
                  self.finishPresentation(
                    withURL: nil,
                    error: AuthErrorUtils.webContextCancelledError(
                      message: "Missing OAuth callback URL scheme."
                    )
                  )
                }
                break
              }

              guard let presentingDelegate = self.fakeUIDelegate ?? self.uiDelegate,
                    let anchor = presentingDelegate.presentationAnchor() else {
                kAuthGlobalWorkQueue.async {
                  self.finishPresentation(
                    withURL: nil,
                    error: AuthErrorUtils.webContextCancelledError(
                      message: "No presentation window available for authentication."
                    )
                  )
                }
                break
              }

              let presenter = AuthWebAuthenticationSessionPresenter()

              // Register the presenter before starting the system session.
              // The registration and the active-flow check are atomic
              // with respect to kAuthGlobalWorkQueue.
              let shouldStart = kAuthGlobalWorkQueue.sync {
                guard self.isPresenting, self.completion != nil else {
                  return false
                }

                self.systemPresenter = presenter
                return true
              }

              guard shouldStart else { break }

              // We are already on the main queue.
              // No additional async dispatch is needed before start().
              presenter.present(
                url,
                callbackURLScheme: callbackURLScheme,
                anchorProvider: { anchor }
              ) { [weak self, weak presenter] callbackURL, error in
                guard let self, let presenter else { return }

                kAuthGlobalWorkQueue.async {
                  guard self.systemPresenter === presenter else {
                    return
                  }

                  if let error {
                    self.finishPresentation(withURL: nil, error: error)
                    return
                  }

                  guard let callbackURL else {
                    self.finishPresentation(
                      withURL: nil,
                      error: AuthErrorUtils.webContextCancelledError(
                        message: "Authentication session returned no callback URL."
                      )
                    )
                    return
                  }

                  if !self.canHandle(url: callbackURL) {
                    self.finishPresentation(
                      withURL: nil,
                      error: AuthErrorUtils.webContextCancelledError(
                        message: "Unexpected OAuth callback URL."
                      )
                    )
                  }
                }
              }
            }
          }
        }
      }

    #endif

    /// Determines if a URL was produced by the currently presented URL.
    /// - Parameter url: The URL to handle.
    /// - Returns: Whether the URL could be handled or not.
    func canHandle(url: URL) -> Bool {
      if isPresenting,
         let callbackMatcher = callbackMatcher,
         callbackMatcher(url) {
        finishPresentation(withURL: url, error: nil)
        return true
      }
      return false
    }

    // MARK: AuthWebViewControllerDelegate

    func webViewControllerDidCancel(_ controller: AuthWebViewController) {
      kAuthGlobalWorkQueue.async {
        if self.webViewController == controller {
          self.finishPresentation(withURL: nil,
                                  error: AuthErrorUtils.webContextCancelledError(message: nil))
        }
      }
    }

    func webViewController(_ controller: AuthWebViewController, canHandle url: URL) -> Bool {
      var result = false
      kAuthGlobalWorkQueue.sync {
        if self.webViewController == controller {
          result = self.canHandle(url: url)
        }
      }
      return result
    }

    func webViewController(_ controller: AuthWebViewController,
                           didFailWithError error: Error) {
      kAuthGlobalWorkQueue.async {
        if self.webViewController == controller {
          self.finishPresentation(withURL: nil, error: error)
        }
      }
    }

    /// Whether or not some web-based content is being presented.
    ///
    /// Accesses to this property are serialized on the global Auth work queue
    /// and thus this variable should not be read or written outside of the work queue.
    private var isPresenting: Bool = false

    /// The callback URL matcher for the current presentation, if one is active.
    private var callbackMatcher: ((URL) -> Bool)?

    #if os(iOS)
      /// The SFSafariViewController used for the current presentation, if any.
      private var safariViewController: SFSafariViewController?
    #endif

    /// The `AuthWebViewController` used for the current presentation, if any.
    private var webViewController: AuthWebViewController?

    /// The UIDelegate used to present the web authentication controller.
    var uiDelegate: AuthUIDelegate?

    /// The completion handler for the current presentation, if one is active.
    ///
    /// Accesses to this variable are serialized on the global Auth work queue
    /// and thus this variable should not be read or written outside of the work queue.
    ///
    /// This variable is also used as a flag to indicate a presentation is active.
    var completion: ((URL?, Error?) -> Void)?

    /// Test-only option to validate the calls to the uiDelegate.
    var fakeUIDelegate: AuthUIDelegate?

    // MARK: Private methods

    private func finishPresentation(withURL url: URL?, error: Error?) {
      guard isPresenting, completion != nil else { return }

      callbackMatcher = nil
      let uiDelegate = self.uiDelegate
      self.uiDelegate = nil
      let completion = self.completion
      self.completion = nil
      #if os(iOS)
        let safariViewController = self.safariViewController
        self.safariViewController = nil
      #endif
      let webViewController = self.webViewController
      self.webViewController = nil

      #if os(macOS)
        let systemPresenter = self.systemPresenter
        self.systemPresenter = nil

        if let webViewController {
          let presentingDelegate = fakeUIDelegate ?? uiDelegate

          DispatchQueue.main.async {
            webViewController.finishAuthFlow()

            if let presentingDelegate {
              presentingDelegate.dismiss {
                kAuthGlobalWorkQueue.async {
                  self.isPresenting = false
                  completion?(url, error)
                }
              }
            } else {
              kAuthGlobalWorkQueue.async {
                self.isPresenting = false
                completion?(url, error)
              }
            }
          }
        } else if let systemPresenter {
          DispatchQueue.main.async {
            systemPresenter.cancel()

            kAuthGlobalWorkQueue.async {
              self.isPresenting = false
              completion?(url, error)
            }
          }
        } else {
          isPresenting = false
          completion?(url, error)
        }
      #else
        if safariViewController != nil || webViewController != nil {
          DispatchQueue.main.async {
            uiDelegate?.dismiss(animated: true) {
              kAuthGlobalWorkQueue.async {
                self.isPresenting = false
                completion?(url, error)
              }
            }
          }
        } else {
          isPresenting = false
          completion?(url, error)
        }
      #endif
    }
  }

  #if os(iOS)
    extension AuthURLPresenter: SFSafariViewControllerDelegate {
      // MARK: SFSafariViewControllerDelegate

      func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        kAuthGlobalWorkQueue.async {
          if controller == self.safariViewController {
            self.safariViewController = nil
            // TODO: Ensure that the SFSafariViewController is actually removed from the screen
            // before invoking finishPresentation
            self.finishPresentation(withURL: nil,
                                    error: AuthErrorUtils.webContextCancelledError(message: nil))
          }
        }
      }
    }
  #endif

#endif // os(iOS) || os(macOS)
