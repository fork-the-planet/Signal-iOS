//
// Copyright 2022 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
public import SignalServiceKit
public import SignalUI

public class PrivateStoryAddRecipientsSettingsViewController: BaseMemberViewController {
    let thread: TSPrivateStoryThread
    var recipientSet: OrderedSet<PickedRecipient> = []

    public override var hasUnsavedChanges: Bool { !recipientSet.orderedMembers.isEmpty }

    public init(thread: TSPrivateStoryThread) {
        self.thread = thread
        super.init()

        memberViewDelegate = self
    }

    // MARK: - View Lifecycle

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateBarButtons()
    }

    private func updateBarButtons() {
        navigationItem.rightBarButtonItem = .systemItem(.save) { [weak self] in
            self?.updatePressed()
        }
        navigationItem.rightBarButtonItem?.isEnabled = hasUnsavedChanges

        title = OWSLocalizedString(
            "PRIVATE_STORY_SETTINGS_ADD_VIEWER_BUTTON",
            comment: "Button to add a new viewer on the 'private story settings' view"
        )
    }

    // MARK: - Actions

    private func updatePressed() {
        AssertIsOnMainThread()

        ModalActivityIndicatorViewController.presentAsInvisible(fromViewController: self) { modal in
            SSKEnvironment.shared.databaseStorageRef.asyncWrite { transaction in
                self.thread.updateWithStoryViewMode(
                    .explicit,
                    addresses: self.thread.addresses + self.recipientSet.orderedMembers.compactMap { $0.address },
                    updateStorageService: true,
                    transaction: transaction
                )
            } completion: {
                self.navigationController?.popViewController(animated: true) { modal.dismiss(animated: false) }
            }
        }
    }
}

// MARK: -

extension PrivateStoryAddRecipientsSettingsViewController: MemberViewDelegate {
    public var memberViewRecipientSet: OrderedSet<PickedRecipient> { recipientSet }

    public var memberViewHasUnsavedChanges: Bool { hasUnsavedChanges }

    public func memberViewRemoveRecipient(_ recipient: PickedRecipient) {
        recipientSet.remove(recipient)
        updateBarButtons()
    }

    public func memberViewAddRecipient(_ recipient: PickedRecipient) -> Bool {
        recipientSet.append(recipient)
        updateBarButtons()
        return true
    }

    public func memberViewShouldShowMemberCount() -> Bool { false }

    public func memberViewShouldAllowBlockedSelection() -> Bool { false }

    public func memberViewMemberCountForDisplay() -> Int { recipientSet.count }

    public func memberViewIsPreExistingMember(_ recipient: PickedRecipient, transaction: DBReadTransaction) -> Bool {
        guard let address = recipient.address else { return false }
        return thread.addresses.contains(address)
    }

    public func memberViewCustomIconNameForPickedMember(_ recipient: PickedRecipient) -> String? { nil }

    public func memberViewCustomIconColorForPickedMember(_ recipient: PickedRecipient) -> UIColor? { nil }

    public func memberViewDismiss() {
        navigationController?.popViewController(animated: true)
    }
}
