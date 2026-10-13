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
  import XCTest
  @testable import FirebaseAuth

  @available(macOS 10.15, *)
  final class AuthWebAuthenticationSessionPresenterTests: XCTestCase {
    private final class FakeSession: AuthSystemAuthenticationSession {
      weak var presentationContextProvider: ASWebAuthenticationPresentationContextProviding?
      var prefersEphemeralWebBrowserSession = true
      var shouldStart = true
      var startCount = 0
      var cancelCount = 0
      var callback: ((URL?, Error?) -> Void)?

      func start() -> Bool {
        startCount += 1
        return shouldStart
      }

      func cancel() {
        cancelCount += 1
      }

      func complete(_ url: URL? = nil, error: Error? = nil) {
        callback?(url, error)
      }
    }

    private let authorizationURL = URL(string: "https://example.com/authorize")!
    private let redirectURL = URL(string: "myapp://callback?code=abc")!

    private func makePresenter(_ fake: FakeSession,
                               onCreate: ((URL, String?) -> Void)? = nil)
      -> AuthWebAuthenticationSessionPresenter {
      AuthWebAuthenticationSessionPresenter(sessionFactory: { url, scheme, callback in
        onCreate?(url, scheme)
        fake.callback = callback
        return fake
      })
    }

    private func start(_ presenter: AuthWebAuthenticationSessionPresenter,
                       completion: @escaping (URL?, Error?) -> Void) {
      presenter.present(
        authorizationURL,
        callbackURLScheme: "myapp",
        anchorProvider: { NSWindow() },
        completion: completion
      )
    }

    func testStartsWithExpectedConfiguration() {
      let fake = FakeSession()
      var receivedURL: URL?
      var receivedScheme: String?
      let presenter = makePresenter(fake) { url, scheme in
        receivedURL = url
        receivedScheme = scheme
      }

      start(presenter) { _, _ in }

      XCTAssertEqual(receivedURL, authorizationURL)
      XCTAssertEqual(receivedScheme, "myapp")
      XCTAssertEqual(fake.startCount, 1)
      XCTAssertTrue(presenter.isActive)
      XCTAssertFalse(fake.prefersEphemeralWebBrowserSession)
      XCTAssertTrue(fake.presentationContextProvider === presenter)
      presenter.cancel()
    }

    func testSuccessfulCallbackIsDeliveredOnlyOnce() {
      let fake = FakeSession()
      let presenter = makePresenter(fake)
      let finished = expectation(description: "callback delivered")
      var count = 0

      start(presenter) { url, error in
        count += 1
        XCTAssertEqual(url, self.redirectURL)
        XCTAssertNil(error)
        finished.fulfill()
      }
      fake.complete(redirectURL)
      wait(for: [finished], timeout: 2)
      fake.complete(redirectURL)
      XCTAssertEqual(count, 1)
      XCTAssertFalse(presenter.isActive)
      XCTAssertEqual(fake.cancelCount, 0)
    }

    func testUserCancellationPropagatesError() {
      let fake = FakeSession()
      let presenter = makePresenter(fake)
      let finished = expectation(description: "cancellation delivered")
      let error = NSError(domain: ASWebAuthenticationSessionErrorDomain,
                          code: ASWebAuthenticationSessionError.Code.canceledLogin.rawValue)

      start(presenter) { url, receivedError in
        XCTAssertNil(url)
        XCTAssertEqual((receivedError as NSError?)?.domain, error.domain)
        XCTAssertEqual((receivedError as NSError?)?.code, error.code)
        finished.fulfill()
      }
      fake.complete(error: error)
      wait(for: [finished], timeout: 2)
      XCTAssertFalse(presenter.isActive)
    }

    func testProgrammaticCancellationSuppressesCallback() {
      let fake = FakeSession()
      let presenter = makePresenter(fake)
      var callbackCount = 0
      var cancellationCompletionCount = 0

      start(presenter) { _, _ in callbackCount += 1 }
      presenter.cancel { cancellationCompletionCount += 1 }
      presenter.cancel { cancellationCompletionCount += 1 }
      fake.complete(error: NSError(domain: ASWebAuthenticationSessionErrorDomain,
                                   code: ASWebAuthenticationSessionError.Code.canceledLogin.rawValue))
      let drained = expectation(description: "late callback drained")
      DispatchQueue.main.async { drained.fulfill() }
      wait(for: [drained], timeout: 2)

      XCTAssertEqual(fake.cancelCount, 1)
      XCTAssertEqual(cancellationCompletionCount, 2)
      XCTAssertEqual(callbackCount, 0)
      XCTAssertFalse(presenter.isActive)
    }

    func testStartFailureReportsErrorAndResetsState() {
      let fake = FakeSession()
      fake.shouldStart = false
      let presenter = makePresenter(fake)
      var callbackCount = 0

      start(presenter) { url, error in
        callbackCount += 1
        XCTAssertNil(url)
        XCTAssertNotNil(error)
      }

      XCTAssertEqual(callbackCount, 1)
      XCTAssertFalse(presenter.isActive)
      XCTAssertEqual(fake.startCount, 1)
      XCTAssertEqual(fake.cancelCount, 0)
    }

    func testSecondPresentationIsRejectedWithoutReplacingActiveSession() {
      let fake = FakeSession()
      let presenter = makePresenter(fake)
      var rejectionCount = 0

      start(presenter) { _, _ in }
      start(presenter) { url, error in
        rejectionCount += 1
        XCTAssertNil(url)
        XCTAssertNotNil(error)
      }

      XCTAssertEqual(fake.startCount, 1)
      XCTAssertEqual(rejectionCount, 1)
      XCTAssertTrue(presenter.isActive)
      presenter.cancel()
    }
  }

#endif // os(macOS)
