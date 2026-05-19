// SPDX-License-Identifier: MIT
// ReticulumMessenger — NotificationService.swift
// Local notification delivery and haptic feedback for incoming messages.

import Foundation
import UserNotifications
import UIKit

final class NotificationService {

    static let shared = NotificationService()

    private init() {}

    // MARK: - Permission

    func requestPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            return false
        }
    }

    // MARK: - Notifications

    func showMessageNotification(from senderName: String, content: String, conversationHash: String) {
        let notifContent = UNMutableNotificationContent()
        notifContent.title = senderName
        notifContent.body = content
        notifContent.sound = .default
        notifContent.categoryIdentifier = "MESSAGE"
        notifContent.userInfo = ["conversationHash": conversationHash]
        notifContent.threadIdentifier = conversationHash

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: notifContent,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request)
    }

    func clearNotifications(for conversationHash: String) {
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            let matching = notifications.filter {
                $0.request.content.userInfo["conversationHash"] as? String == conversationHash
            }
            let ids = matching.map { $0.request.identifier }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    func updateBadgeCount(_ count: Int) {
        Task {
            try? await UNUserNotificationCenter.current().setBadgeCount(count)
        }
    }

    // MARK: - Haptics

    @MainActor
    func playMessageReceivedHaptic() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    @MainActor
    func playMessageSentHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    @MainActor
    func playConnectionHaptic() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.warning)
    }

    // MARK: - Notification Categories

    func registerCategories() {
        let replyAction = UNTextInputNotificationAction(
            identifier: "REPLY",
            title: "Reply",
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Message"
        )

        let markReadAction = UNNotificationAction(
            identifier: "MARK_READ",
            title: "Mark as Read",
            options: []
        )

        let category = UNNotificationCategory(
            identifier: "MESSAGE",
            actions: [replyAction, markReadAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )

        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}
