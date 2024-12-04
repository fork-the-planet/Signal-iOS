//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

public protocol SignalTSResourceCloner {

    func cloneAsSignalAttachment(
        attachment: ReferencedTSResourceStream
    ) throws -> SignalAttachment
}

public class SignalTSResourceClonerImpl: SignalTSResourceCloner {

    private let attachmentCloner: SignalAttachmentCloner

    public init(
        attachmentCloner: SignalAttachmentCloner
    ) {
        self.attachmentCloner = attachmentCloner
    }

    public func cloneAsSignalAttachment(
        attachment: ReferencedTSResourceStream
    ) throws -> SignalAttachment {
        return try attachmentCloner.cloneAsSignalAttachment(
            attachment: .init(
                reference: attachment.reference.concreteType,
                attachmentStream: attachment.attachmentStream.concreteStreamType
            )
        )
    }
}

#if TESTABLE_BUILD

public class SignalTSResourceClonerMock: SignalTSResourceCloner {

    public init() {}

    public func cloneAsSignalAttachment(
        attachment: ReferencedTSResourceStream
    ) throws -> SignalAttachment {
        throw OWSAssertionError("Unimplemented")
    }
}

#endif
