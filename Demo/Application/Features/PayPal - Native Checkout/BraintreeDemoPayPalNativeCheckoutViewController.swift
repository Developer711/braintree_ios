import Foundation
import UIKit
import BraintreePayPalNativeCheckout

class BraintreeDemoPayPalNativeCheckoutViewController: BraintreeDemoPaymentButtonBaseViewController {
    lazy var payPalNativeCheckoutClient = BTPayPalNativeCheckoutClient(apiClient: apiClient)

    override func createPaymentButton() -> UIView! {
        let payPalCheckoutButton = UIButton(type: .system)
        payPalCheckoutButton.setTitle("One Time Checkout", for: .normal)
        payPalCheckoutButton.setTitleColor(.blue, for: .normal)
        payPalCheckoutButton.setTitleColor(.lightGray, for: .highlighted)
        payPalCheckoutButton.setTitleColor(.lightGray, for: .disabled)
        payPalCheckoutButton.addTarget(self, action: #selector(tappedPayPalCheckout), for: .touchUpInside)
        payPalCheckoutButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let payPalVaultButton = UIButton(type: .system)
        payPalVaultButton.setTitle("Vault Checkout", for: .normal)
        payPalVaultButton.setTitleColor(.blue, for: .normal)
        payPalVaultButton.setTitleColor(.lightGray, for: .highlighted)
        payPalVaultButton.setTitleColor(.lightGray, for: .disabled)
        payPalVaultButton.addTarget(self, action: #selector(tappedPayPalVault), for: .touchUpInside)
        payPalVaultButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stackView = UIStackView(arrangedSubviews: [payPalCheckoutButton, payPalVaultButton])
        stackView.axis = .vertical
        stackView.spacing = 5

        return stackView
    }
    
    @objc func tappedPayPalCheckout(_ sender: UIButton) {
        progressBlock("Tapped PayPal - Native Checkout using BTPayPalNativeCheckout")
        sender.setTitle("Processing...", for: .disabled)
        sender.isEnabled = false

        let request = BTPayPalNativeCheckoutRequest(amount: "4.30")
        let btPatchRequest = BTPayPalNativeCheckoutPatchRequest()
        let btShippingName = BTPayPalNativeCheckoutPatchRequest.BTShippingName(fullName: "test")
        let btOrderAddress = BTPayPalNativeCheckoutPatchRequest.BTOrderAddress(countryCode: "US")
        let btShippingOptions = BTPayPalNativeCheckoutPatchRequest.BTShippingOptions(
            id: "1",
            label: "Shipping",
            selected: true,
            shippingType: .shipping,
            currencyCode: .usd,
            value: "1.23"
        )

        request.isShippingAddressEditable = true
        request.isShippingAddressRequired = true
        request.onShippingChange = { change, action in
            action.patch(request: btPatchRequest.patchRequest) { _, _ in }
            btPatchRequest.patchRequest.add(shippingAddress: btOrderAddress.createOrderAddress())
            btPatchRequest.patchRequest.add(shippingOptions: [btShippingOptions.createShippingMethod()])
            btPatchRequest.patchRequest.add(shippingName: btShippingName.createShippingName())
        }

        payPalNativeCheckoutClient.tokenizePayPalAccount(with: request) { nonce, error in
            sender.isEnabled = true
            
            guard let nonce = nonce else {
                self.progressBlock(error?.localizedDescription)
                return
            }
            self.nonceStringCompletionBlock(nonce.nonce)
        }
    }

    @objc func tappedPayPalVault(_ sender: UIButton) {
        progressBlock("Tapped PayPal - Vault using BTPayPalNativeCheckout")
        sender.setTitle("Processing...", for: .disabled)
        sender.isEnabled = false

        let request = BTPayPalNativeVaultRequest()
        request.activeWindow = self.view.window

        payPalNativeCheckoutClient.tokenizePayPalAccount(with: request) { nonce, error in
            sender.isEnabled = true

            guard let nonce = nonce else {
                self.progressBlock(error?.localizedDescription)
                return
            }
            self.nonceStringCompletionBlock(nonce.nonce)
        }
    }
}
