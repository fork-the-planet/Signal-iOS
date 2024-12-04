//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

extension TSResourceStream {

    public func asStickerMetadata(
        stickerInfo: StickerInfo,
        stickerType: StickerType,
        emojiString: String?
    ) -> (any StickerMetadata)? {
        let attachment = self.concreteStreamType
        return EncryptedStickerMetadata.from(
            attachment: attachment,
            stickerInfo: stickerInfo,
            stickerType: stickerType,
            emojiString: emojiString
        )
    }
}
