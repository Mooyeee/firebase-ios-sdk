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
  import AuthenticationServices
  import Foundation

  /// Internal abstraction used to test authentication-session lifecycle without showing UI.
  @available(macOS 10.15, *)
  protocol AuthSystemAuthenticationSession: AnyObject {
    var presentationContextProvider: ASWebAuthenticationPresentationContextProviding? { get set }
    var prefersEphemeralWebBrowserSession: Bool { get set }
    func start() -> Bool
    func cancel()
  }

  @available(macOS 10.15, *)
  extension ASWebAuthenticationSession: AuthSystemAuthenticationSession {}

  /// Presents an OAuth authorization URL using the system authentication session.
  ///
  /// This presenter is an internal macOS implementation detail. Call its methods on
  /// the main thread. The caller is responsible for validating the returned URL
  /// against the active OAuth request before accepting it.
  @available(macOS 10.15, *)
  final class AuthWebAuthenticationSessionPresenter: NSObject,
    ASWebAuthenticationPresentationContextProviding {
    typealias Completion = (URL?, Error?) -> Void
    typealias SessionFactory = (URL, String?, @escaping Completion)
      -> AuthSystemAuthenticationSession

    private var session: AuthSystemAuthenticationSession?
    private var completion: Completion?
    private var anchorProvider: (() -> ASPresentationAnchor)?
    private let sessionFactory: SessionFactory
    private(set) var isActive = false

    override convenience init() {
      self.init(sessionFactory: { url, scheme, completion in
        ASWebAuthenticationSession(
          url: url,
          callbackURLScheme: scheme,
          completionHandler: completion
        )
      })
    }

    /// Allows unit tests to supply a fake system authentication session.
    init(sessionFactory: @escaping SessionFactory) {
      self.sessionFactory = sessionFactory
      super.init()
    }

    /// Starts a system-browser OAuth authorization flow.
    /// - Parameter url: The authorization URL to open.
    /// - Parameter callbackURLScheme: The registered callback URL scheme for this flow.
    /// - Parameter anchorProvider: Supplies the window anchoring the system dialog.
    /// - Parameter completion: Called once with the callback URL or an error.
    func present(_ url: URL,
                 callbackURLScheme: String,
                 anchorProvider: @escaping () -> ASPresentationAnchor,
                 completion: @escaping Completion) {
      assert(Thread.isMainThread)

      guard session == nil else {
        completion(nil, NSError(
          domain: "FirebaseAuth.AuthWebAuthenticationSessionPresenter",
          code: 1,
          userInfo: [
            NSLocalizedDescriptionKey: "An authentication session is already active or could not be started.",
          ]
        ))
        return
      }

      self.completion = completion
      self.anchorProvider = anchorProvider

      let session = sessionFactory(url, callbackURLScheme) { [weak self] callbackURL, error in
        DispatchQueue.main.async {
          self?.finish(withURL: callbackURL, error: error)
        }
      }
      session.presentationContextProvider = self
      session.prefersEphemeralWebBrowserSession = false
      self.session = session

      isActive = session.start()
      if !isActive {
        finish(
          withURL: nil,
          error: NSError(
            domain: "FirebaseAuth.AuthWebAuthenticationSessionPresenter",
            code: 1,
            userInfo: [
              NSLocalizedDescriptionKey:
                "An authentication session is already active or could not be started.",
            ]
          )
        )
      }
    }

    /// Cancels the active system authentication session.
    /// - Parameter completion: Called once the cancellation request has been issued.
    func cancel(completion: (() -> Void)? = nil) {
      assert(Thread.isMainThread)

      guard isActive, let session else {
        completion?()
        return
      }

      isActive = false

      // Clear the callback before cancelling the session.
      self.completion = nil
      anchorProvider = nil
      self.session = nil

      session.cancel()
      completion?()
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
      assert(Thread.isMainThread)

      guard let anchorProvider else {
        preconditionFailure("Missing authentication presentation anchor provider.")
      }

      return anchorProvider()
    }

    // MARK: - Private Methods

    private func finish(withURL url: URL?, error: Error?) {
      assert(Thread.isMainThread)
      guard let completion else { return }

      isActive = false
      self.completion = nil
      anchorProvider = nil
      session = nil

      completion(url, error)
    }
  }

#endif // os(macOS)
