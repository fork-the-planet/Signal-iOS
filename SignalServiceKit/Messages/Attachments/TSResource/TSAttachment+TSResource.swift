//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

extension TSAttachment: TSResource {

    public var resourceId: TSResourceId {
        return .legacy(uniqueId: self.uniqueId)
    }

    public var resourceBlurHash: String? {
        return blurHash
    }

    public var transitCdnNumber: UInt32? {
        return cdnNumber
    }

    public var transitCdnKey: String? {
        return cdnKey
    }

    public var transitUploadTimestamp: UInt64? {
        return uploadTimestamp
    }

    public var unenecryptedResourceByteCount: UInt32? {
        return byteCount
    }

    public var resourceEncryptionKey: Data? {
        return encryptionKey
    }

    public var encryptedResourceByteCount: UInt32? {
        // Unavailable for legacy attachments
        return nil
    }

    public var encryptedResourceSha256Digest: Data? {
        return (self as? TSAttachmentPointer)?.digest
    }

    public var isUploadedToTransitTier: Bool {
        (self as? TSAttachmentStream)?.isUploaded ?? false
    }

    public var mimeType: String {
        return contentType
    }

    public var concreteType: ConcreteTSResource {
        return .legacy(self)
    }

    public func asResourceStream() -> TSResourceStream? {
        let stream = self as? TSAttachmentStream
        guard stream?.originalFilePath != nil else {
            // Not _really_ a stream without a file.
            return nil
        }
        return stream
    }

    public func attachmentType(forContainingMessage: TSMessage, tx: DBReadTransaction) -> TSAttachmentType {
        return attachmentType
    }

    public func transitTierDownloadState(tx: DBReadTransaction) -> TSAttachmentPointerState? {
        return (self as? TSAttachmentPointer)?.state
    }

    public func caption(forContainingMessage: TSMessage, tx: DBReadTransaction) -> String? {
        return caption
    }
}

extension TSAttachmentStream: TSResourceStream {

    public func fileURLForDeletion() throws -> URL {
        // We guard that this is non-nil on the cast above.
        let filePath = self.originalFilePath!
        return URL(fileURLWithPath: filePath)
    }

    public func decryptedLongText() -> String? {
        guard let fileUrl = self.originalMediaURL else {
            return nil
        }

        guard let data = try? Data(contentsOf: fileUrl) else {
            return nil
        }

        guard let text = String(data: data, encoding: .utf8) else {
            owsFailDebug("Can't parse oversize text data.")
            return nil
        }
        return text
    }

    public func decryptedRawDataSync() throws -> Data {
        guard let originalFilePath else {
            throw OWSAssertionError("Missing file path!")
        }
        return try NSData(contentsOfFile: originalFilePath) as Data
    }

    public func decryptedRawData() async throws -> Data {
        return try decryptedRawDataSync()
    }

    public func decryptedImage() async throws -> UIImage {
        // TSAttachments keep the file decrypted on disk.
        guard let originalImage = self.originalImage else {
            throw OWSAssertionError("Not a valid image!")
        }
        return originalImage
    }

    public var concreteStreamType: ConcreteTSResourceStream {
        return .legacy(self)
    }

    public var cachedContentType: TSResourceContentType? {

        if isAudioMimeType {
            // Historically we did not cache this value. Rely on the mime type.
            return .audio(duration: audioDurationMetadata())
        }

        let cachedValueTypes: [(NSNumber?, () -> TSResourceContentType)] = [
            (self.isValidVideoCached, {
                .video(duration: self.videoDuration?.doubleValue, pixelSize: self.mediaPixelSizeMetadata())
            }),
            (self.isAnimatedCached, { .animatedImage(pixelSize: self.mediaPixelSizeMetadata()) }),
            (self.isValidImageCached, { .image(pixelSize: self.mediaPixelSizeMetadata()) })
        ]

        for (numberValue, typeFn) in cachedValueTypes {
            if numberValue?.boolValue == true {
                return typeFn()
            }
        }

        // If we got this far no cached value was true.
        // But if they're all non-nil, we can return .file.
        // Otherwise we haven't checked (and cached) all the types
        // and we must return nil.
        if cachedValueTypes.allSatisfy({ numberValue, _ in numberValue != nil }) {
            return .file
        }

        return nil
    }

    public func computeContentType() -> TSResourceContentType {
        if let cachedContentType {
            return cachedContentType
        }

        // If the cache lookup fails, switch to the hard fetches.
        if isVideoMimeType && isValidVideo {
            return .video(duration: self.videoDuration?.doubleValue, pixelSize: mediaPixelSizeMetadata())
        } else if getAnimatedMimeType() == .animated && isAnimatedContent {
            return .animatedImage(pixelSize: mediaPixelSizeMetadata())
        } else if isImageMimeType && isValidImage {
            return .image(pixelSize: mediaPixelSizeMetadata())
        } else if getAnimatedMimeType() == .maybeAnimated && isAnimatedContent {
            return .image(pixelSize: mediaPixelSizeMetadata())
        }
        // We did not previously have utilities for determining
        // "valid" audio content. Rely on the cached value's
        // usage of the mime type check to catch that content type.

        return .file
    }

    public func computeIsValidVisualMedia() -> Bool {
        return self.isValidVisualMedia
    }

    private func mediaPixelSizeMetadata() -> TSResourceContentType.Metadata<CGSize> {
        let attachment = self
        return .init(
            getCached: { [attachment] in
                if
                    let cachedImageWidth = attachment.cachedImageWidth,
                    let cachedImageHeight = attachment.cachedImageHeight,
                    cachedImageWidth.floatValue > 0,
                    cachedImageHeight.floatValue > 0
                {
                    return .init(
                        width: CGFloat(cachedImageWidth.floatValue),
                        height: CGFloat(cachedImageHeight.floatValue)
                    )
                } else {
                    return nil
                }
            },
            compute: { [attachment] in
                return attachment.imageSizePixels
            }
        )
    }

    private func audioDurationMetadata() -> TSResourceContentType.Metadata<TimeInterval> {
        let attachment = self
        return .init(
            getCached: { [attachment] in
                return attachment.cachedAudioDurationSeconds?.doubleValue
            },
            compute: { [attachment] in
                return attachment.audioDurationSeconds()
            }
        )
    }

    // MARK: - Thumbnails

    public func thumbnailImage(quality: AttachmentThumbnailQuality) async -> UIImage? {
        return await withCheckedContinuation { continuation in
            self.thumbnailImage(
                quality: quality.tsQuality,
                success: { image in
                    continuation.resume(returning: image)
                },
                failure: {
                    continuation.resume(returning: nil)
                }
            )
        }
    }

    public func thumbnailImageSync(quality: AttachmentThumbnailQuality) -> UIImage? {
        return self.thumbnailImageSync(quality: quality.tsQuality)
    }
}

extension TSAttachment {

    var asResourcePointer: TSResourcePointer? {
        guard self.cdnKey.isEmpty.negated, self.cdnNumber > 0 else {
            return nil
        }
        return TSResourcePointer(resource: self, cdnNumber: self.cdnNumber, cdnKey: self.cdnKey)
    }
}
