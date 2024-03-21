//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalCoreKit

public protocol CallRecordMissedCallManager {
    /// The number of unread missed calls.
    func countUnreadMissedCalls(tx: DBReadTransaction) -> UInt

    /// Marks all unread calls at and before the given timestamp as read.
    ///
    /// - Parameter beforeTimestamp
    /// A timestamp at and before which to mark calls as read. If this value is
    /// `nil`, all calls are marked as read.
    /// - Parameter sendSyncMessage
    /// Whether a sync message should be sent as part of this operation. No sync
    /// message is sent regardless of this value if no calls are actually marked
    /// as read. The sync message will be of type
    /// ``OutgoingCallLogEventSyncMessage/CallLogEvent/EventType/markedAsRead``.
    func markUnreadCallsAsRead(
        beforeTimestamp: UInt64?,
        sendSyncMessage: Bool,
        tx: DBWriteTransaction
    )

    /// Marks the given call and all unread calls before it in the same
    /// conversation as the given call as read.
    ///
    /// - Parameter beforeCallRecord
    /// The call identifying the conversation and timestamp at and before which
    /// to mark unread calls as read.
    /// - Parameter sendSyncMessage
    /// Whether a sync message should be sent as part of this operation. No sync
    /// message is sent regardless of this value if no calls are actually marked
    /// as read. The sync message will be of type
    /// ``OutgoingCallLogEventSyncMessage/CallLogEvent/EventType/markedAsReadInConversation``.
    func markUnreadCallsInConversationAsRead(
        beforeCallRecord: CallRecord,
        sendSyncMessage: Bool,
        tx: DBWriteTransaction
    )
}

class CallRecordMissedCallManagerImpl: CallRecordMissedCallManager {
    private let callRecordConversationIdAdapter: CallRecordSyncMessageConversationIdAdapter
    private let callRecordQuerier: CallRecordQuerier
    private let callRecordStore: CallRecordStore
    private let messageSenderJobQueue: MessageSenderJobQueue

    init(
        callRecordConversationIdAdapter: CallRecordSyncMessageConversationIdAdapter,
        callRecordQuerier: CallRecordQuerier,
        callRecordStore: CallRecordStore,
        messageSenderJobQueue: MessageSenderJobQueue
    ) {
        self.callRecordConversationIdAdapter = callRecordConversationIdAdapter
        self.callRecordStore = callRecordStore
        self.callRecordQuerier = callRecordQuerier
        self.messageSenderJobQueue = messageSenderJobQueue
    }

    // MARK: -

    func countUnreadMissedCalls(tx: DBReadTransaction) -> UInt {
        var unreadMissedCallCount: UInt = 0

        for missedCallStatus in CallRecord.CallStatus.missedCalls {
            guard let unreadMissedCallCursor = callRecordQuerier.fetchCursorForUnread(
                callStatus: missedCallStatus,
                ordering: .descending,
                tx: tx
            ) else { continue }

            do {
                while let _ = try unreadMissedCallCursor.next() {
                    unreadMissedCallCount += 1
                }
            } catch {
                owsFailDebug("Unexpectedly failed to iterate CallRecord cursor!")
                continue
            }
        }

        return unreadMissedCallCount
    }

    func markUnreadCallsAsRead(
        beforeTimestamp: UInt64?,
        sendSyncMessage: Bool,
        tx: DBWriteTransaction
    ) {
        let markedAsReadCount = _markUnreadCallsAsRead(
            beforeTimestamp: beforeTimestamp,
            threadRowId: nil,
            tx: tx
        )

        guard markedAsReadCount > 0 else { return }

        CallRecordLogger.shared.info("Marked \(markedAsReadCount) calls as read.")

        if sendSyncMessage {
            /// When doing a bulk mark-as-read, we want to use our absolute
            /// most-recent call as the anchor for the sync message.
            let mostRecentCall: CallRecord? = try? callRecordQuerier.fetchCursor(
                ordering: .descending, tx: tx
            )?.next()

            guard let mostRecentCall else {
                owsFailDebug("Unexpectedly failed to get most-recent call after marking calls as read!")
                return
            }

            sendMarkedCallsAsReadSyncMessage(
                callRecord: mostRecentCall,
                eventType: .markedAsRead,
                tx: tx
            )
        }
    }

    func markUnreadCallsInConversationAsRead(
        beforeCallRecord: CallRecord,
        sendSyncMessage: Bool,
        tx: DBWriteTransaction
    ) {
        let markedAsReadCount = _markUnreadCallsAsRead(
            beforeTimestamp: beforeCallRecord.callBeganTimestamp,
            threadRowId: beforeCallRecord.threadRowId,
            tx: tx
        )

        guard markedAsReadCount > 0 else { return }

        CallRecordLogger.shared.info("Marked \(markedAsReadCount) calls as read.")

        if sendSyncMessage {
            sendMarkedCallsAsReadSyncMessage(
                callRecord: beforeCallRecord,
                eventType: .markedAsReadInConversation,
                tx: tx
            )
        }
    }

    /// Mark calls before or at the given timestamp as read, optionally
    /// considering only calls with the given thread row ID.
    private func _markUnreadCallsAsRead(
        beforeTimestamp: UInt64?,
        threadRowId: Int64?,
        tx: DBWriteTransaction
    ) -> UInt {
        var markedAsReadCount: UInt = 0

        let fetchCursorOrdering: CallRecordQuerier.FetchOrdering = {
            if let beforeTimestamp {
                /// Adjust the timestamp forward one second to catch calls at
                /// this exact timestamp. That's relevant because when we send
                /// this sync message, we do so with the timestamp of an actual
                /// call – and because we (try to) sync call timestamps across
                /// devices, our copy of the call likely has the exact same
                /// timestamp. Without adjusting, we'll skip that call!
                return .descendingBefore(timestamp: beforeTimestamp + 1)
            }

            return .descending
        }()

        for callStatus in CallRecord.CallStatus.allCases {
            let unreadCallCursor: CallRecordCursor? = {
                if let threadRowId {
                    return callRecordQuerier.fetchCursorForUnread(
                        threadRowId: threadRowId,
                        callStatus: callStatus,
                        ordering: fetchCursorOrdering,
                        tx: tx
                    )
                } else {
                    return callRecordQuerier.fetchCursorForUnread(
                        callStatus: callStatus,
                        ordering: fetchCursorOrdering,
                        tx: tx
                    )
                }
            }()

            guard let unreadCallCursor else { continue }

            do {
                let markedAsReadCountBefore = markedAsReadCount

                while let unreadCallRecord = try unreadCallCursor.next() {
                    markedAsReadCount += 1

                    callRecordStore.markAsRead(
                        callRecord: unreadCallRecord, tx: tx
                    )
                }

                owsAssertDebug(
                    markedAsReadCount == markedAsReadCountBefore || callStatus.isMissedCall,
                    "Unexpectedly had \(markedAsReadCount - markedAsReadCountBefore) unread calls that were not missed!"
                )
            } catch {
                owsFailDebug("Unexpectedly failed to iterate CallRecord cursor!")
                continue
            }
        }

        return markedAsReadCount
    }

    /// Send a "marked calls as read" sync message with the given event type, so
    /// our other devices can also mark the calls as read.
    ///
    /// - Parameter callRecord
    /// A call record whose timestamp and other parameters will populate the
    /// sync message.
    /// - Parameter eventType
    /// The type of sync message to send.
    private func sendMarkedCallsAsReadSyncMessage(
        callRecord: CallRecord,
        eventType: OutgoingCallLogEventSyncMessage.CallLogEvent.EventType,
        tx: DBWriteTransaction
    ) {
        typealias ConversationId = OutgoingCallLogEventSyncMessage.CallLogEvent.ConversationId
        guard let conversationId: ConversationId = callRecordConversationIdAdapter.getConversationId(
            callRecord: callRecord, tx: tx
        ) else { return }

        let sdsTx = SDSDB.shimOnlyBridge(tx)

        guard let localThread = TSContactThread.getOrCreateLocalThread(transaction: sdsTx) else {
            return
        }

        let outgoingCallLogEventSyncMessage = OutgoingCallLogEventSyncMessage(
            callLogEvent: OutgoingCallLogEventSyncMessage.CallLogEvent(
                eventType: eventType,
                callId: callRecord.callId,
                conversationId: conversationId,
                timestamp: callRecord.callBeganTimestamp
            ),
            thread: localThread,
            tx: sdsTx
        )

        messageSenderJobQueue.add(
            message: outgoingCallLogEventSyncMessage.asPreparer,
            transaction: sdsTx
        )
    }
}
