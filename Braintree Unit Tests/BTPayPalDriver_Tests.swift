import XCTest
import Braintree

class BTPayPalDriver_Tests: XCTestCase {

    var mockAPIClient : MockAPIClient = try! MockAPIClient(clientKey: "test_client_key")

    override func setUp() {
        super.setUp()
        mockAPIClient = try! MockAPIClient(clientKey: "test_client_key")
        mockAPIClient.cannedConfigurationResponseBody = BTJSON(value: [
            "paypal": [
                "environment": "offline"
            ] ])
       mockAPIClient.cannedResponseBody = BTJSON(value: [
            "paymentResource": [
                "redirectURL": "fakeURL://"
            ] ])

    }


    // MARK: Authorization



    // MARK: Checkout

    func testCheckout_postsPaymentResource() {

        class StubPayPalOneTouchCore : PayPalOneTouchCore {
            override class func redirectURLsForCallbackURLScheme(callbackURLScheme: String!,
                withReturnURL returnURL: AutoreleasingUnsafeMutablePointer<NSString?>,
                withCancelURL cancelURL: AutoreleasingUnsafeMutablePointer<NSString?>) {
                    cancelURL.memory = "scheme://cancel"
                    returnURL.memory = "scheme://return"
            }
        }

        let payPalDriver = BTPayPalDriver(APIClient: mockAPIClient, returnURLScheme: "test.urlReturnScheme://")
        let request = BTPayPalCheckoutRequest(amount: NSDecimalNumber(string: "1"))!
        request.currencyCode = "GBP"

        payPalDriver.payPalClass = StubPayPalOneTouchCore.self
        payPalDriver.checkoutWithCheckoutRequest(request) { (_, _) -> Void in }


        XCTAssertEqual("v1/paypal_hermes/create_payment_resource", mockAPIClient.lastPOSTPath)
        let lastPostParameters = mockAPIClient.lastPOSTParameters
        XCTAssertEqual(lastPostParameters["amount"] as! String, "1")
        XCTAssertEqual(lastPostParameters["currency_iso_code"] as! String, "GBP")
        XCTAssertEqual(lastPostParameters["return_url"] as! String, "scheme://return")
        XCTAssertEqual(lastPostParameters["cancel_url"] as! String, "scheme://cancel")
        XCTAssertEqual(lastPostParameters["correlation_id"] as! String, "TODO")
    }

    func testCheckout_whenPayPalPaymentCreationSuccessful_performsAppSwitch() {

        class PayPalDriverTestDelegate : NSObject, BTPayPalDriverDelegate {
            var willPerform : XCTestExpectation

            init(willPerform: XCTestExpectation) {
                self.willPerform = willPerform
            }

            @objc func payPalDriverWillPerformAppSwitch(payPalDriver: BTPayPalDriver) {
                self.willPerform.fulfill()
            }
        }

        let payPalDriver = BTPayPalDriver(APIClient: mockAPIClient, returnURLScheme: "test.urlReturnScheme://")
        let dummyRequest = BTPayPalCheckoutRequest(amount: NSDecimalNumber(string: "1"))!

        payPalDriver.requestFactory = PayPalRequestMockFactory()
        let delegate = PayPalDriverTestDelegate(willPerform: self.expectationWithDescription("Will Perform"))
        payPalDriver.delegate = delegate
        payPalDriver.checkoutWithCheckoutRequest(dummyRequest) { (_, _) -> Void in }

        self.waitForExpectationsWithTimeout(2, handler: nil)
    }

    func testCheckout_whenPayPalAppSwitchSuccessful_tokenizesPayPalAccount() {

        let returnURLScheme = "foo://"
        let payPalDriver = BTPayPalDriver(APIClient: mockAPIClient, returnURLScheme: returnURLScheme)
        let returnURL = NSURL(string: "bar://hello/world")!

        let continuationExpectation = self.expectationWithDescription("Continuation called")

        payPalDriver.payPalClass = StubPayPalOneTouchCore.self
        payPalDriver.payPalClass.cannedResult.overrideType = .Success
        payPalDriver.setCheckoutContinuationBlock { (tokenizedCheckout, error) -> Void in
            XCTAssertNotNil(tokenizedCheckout)
            continuationExpectation.fulfill()
        }

        BTPayPalDriver.handleAppSwitchReturnURL(returnURL)

        self.waitForExpectationsWithTimeout(2, handler: nil)
        XCTAssertEqual(mockAPIClient.lastPOSTPath, "/v1/payment_methods/paypal_accounts")
    }

    func testCheckout_whenRemoteConfigurationFails_callsBackWithError() {
        mockAPIClient.cannedConfigurationResponseBody = nil
        mockAPIClient.cannedConfigurationResponseError = NSError(domain: "", code: 0, userInfo: nil)

        let payPalDriver = BTPayPalDriver(APIClient: mockAPIClient, returnURLScheme: "")
        let dummyRequest = BTPayPalCheckoutRequest(amount: NSDecimalNumber(string: "1"))!
        let expectation = self.expectationWithDescription("Checkout fails with error")
        payPalDriver.checkoutWithCheckoutRequest(dummyRequest) { (_, error) -> Void in
            XCTAssertEqual(error!, self.mockAPIClient.cannedConfigurationResponseError!)
            expectation.fulfill()
        }
        self.waitForExpectationsWithTimeout(2, handler: nil)
    }

    func testCheckout_whenPaymentResourceCreationFails_callsBackWithError() {
        mockAPIClient.cannedResponseError = NSError(domain: "", code: 0, userInfo: nil)

        let payPalDriver = BTPayPalDriver(APIClient: mockAPIClient, returnURLScheme: "")
        let dummyRequest = BTPayPalCheckoutRequest(amount: NSDecimalNumber(string: "1"))!
        let expectation = self.expectationWithDescription("Checkout fails with error")
        payPalDriver.checkoutWithCheckoutRequest(dummyRequest) { (_, error) -> Void in
            XCTAssertEqual(error!, self.mockAPIClient.cannedResponseError!)
            expectation.fulfill()
        }
        self.waitForExpectationsWithTimeout(2, handler: nil)
    }

    func testCheckout_whenPayPalAppSwitchCancels_callsBackWithNilResultError() {

        let returnURLScheme = "foo://"
        let mockAPIClient = try! MockAPIClient(clientKey: "test_client_key")
        let payPalDriver = BTPayPalDriver(APIClient: mockAPIClient, returnURLScheme: returnURLScheme)
        let returnURL = NSURL(string: "bar://hello/world")!

        let continuationExpectation = self.expectationWithDescription("Continuation called")

        payPalDriver.payPalClass = StubPayPalOneTouchCore.self
        payPalDriver.payPalClass.cannedResult.overrideType = .Cancel
        payPalDriver.setCheckoutContinuationBlock { (tokenizedCheckout, error) -> Void in
            XCTAssertNil(tokenizedCheckout)
            XCTAssertNil(error)
            continuationExpectation.fulfill()
        }

        BTPayPalDriver.handleAppSwitchReturnURL(returnURL)

        self.waitForExpectationsWithTimeout(2, handler: nil)
    }

    func testCheckout_whenPayPalAppSwitchErrors_callsBackWithError() {

        let returnURLScheme = "foo://"
        let payPalDriver = BTPayPalDriver(APIClient: mockAPIClient, returnURLScheme: returnURLScheme)
        let returnURL = NSURL(string: "bar://hello/world")!

        let continuationExpectation = self.expectationWithDescription("Continuation called")

        payPalDriver.payPalClass = StubPayPalOneTouchCore.self
        payPalDriver.payPalClass.cannedResult.overrideType = .Error
        payPalDriver.payPalClass.cannedResult.overrideError = NSError(domain: "", code: 0, userInfo: nil)

        payPalDriver.setCheckoutContinuationBlock { (tokenizedCheckout, error) -> Void in
            XCTAssertNil(tokenizedCheckout)
            XCTAssertEqual(error, payPalDriver.payPalClass.cannedResult.error!)
            continuationExpectation.fulfill()
        }

        BTPayPalDriver.handleAppSwitchReturnURL(returnURL)

        self.waitForExpectationsWithTimeout(2, handler: nil)
    }

    // MARK: Test Doubles

    class StubPayPalOneTouchCoreResult : PayPalOneTouchCoreResult {
        var overrideError : NSError?
        override var error : NSError? {
            get {
                return overrideError
            }
        }

        var overrideType: PayPalOneTouchResultType
        override var type : PayPalOneTouchResultType {
            get {
                return overrideType
            }
        }

        override init() {
            overrideError = nil
            overrideType = .Success
        }

        override var response : [NSObject : AnyObject] {
            get {
                return [:]
            }
        }
    }

    class StubPayPalOneTouchCore : PayPalOneTouchCore {

        static var cannedResult = StubPayPalOneTouchCoreResult()

        override class func parseResponseURL(url: NSURL!, completionBlock: PayPalOneTouchCompletionBlock!) {
            completionBlock(self.cannedResult)
        }
    }

    class MockPayPalCheckoutRequest : PayPalOneTouchCheckoutRequest {
        var cannedSuccess : Bool
        var cannedTarget : PayPalOneTouchRequestTarget
        var cannedError : NSError?

        override init() {
            cannedError = nil
            cannedTarget = .None
            cannedSuccess = true
        }

        override func performWithCompletionBlock(completionBlock: PayPalOneTouchRequestCompletionBlock!) {
            completionBlock(cannedSuccess, cannedTarget, cannedError)
        }
    }

    class PayPalRequestMockFactory : BTPayPalRequestFactory {
        override func requestWithApprovalURL(approvalURL: NSURL!, clientID: String!, environment: String!, callbackURLScheme: String!) -> PayPalOneTouchCheckoutRequest! {
            return MockPayPalCheckoutRequest()
        }
    }
}
