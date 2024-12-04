//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

/// Uniquely and stably identifies an item for the all media view
/// (either a MediaGalleryRecord or an AttachmentReference).
public enum MediaGalleryItemId: Equatable, Hashable {
    case v2(AttachmentReferenceId)
}

/// Id for the underlying "resource" of a media item.
///
/// In v2-attachment-land, this is the same as ``MediaGalleryItemId``;
/// the table we use for the all media view is the AttachmentReferences table
/// so there is no separate id.
///
/// In v1-land, this is _different_ than a ``MediaGalleryItemId``;
/// the item id tracks the rowId of the MediaGalleryRecord,
/// this tracks the id of the TSAttachment.
public enum MediaGalleryResourceId: Equatable, Hashable {
    case v2(AttachmentReferenceId)
}

extension TSResourceReference {

    public var mediaGalleryResourceId: MediaGalleryResourceId {
        let attachmentReference = self.concreteType
        return .v2(attachmentReference.referenceId)
    }
}
