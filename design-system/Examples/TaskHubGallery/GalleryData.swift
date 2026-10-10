//
//  GalleryData.swift
//  TaskHubGallery
//
//  Created by Yuki Obuchi on 2026/10/10.
//

import Foundation
import TaskHubDesignSystem

struct GalleryTask: Identifiable, Sendable {
    let summary: HubTaskSummary
    let body: String
    let approach: String
    let attachments: [HubAttachment]
    let history: [HubHistoryEntry]
    var id: String { summary.id }

    var searchableText: String {
        ([summary.id, summary.title, summary.lane.name, summary.assignee ?? "", body, approach]
         + attachments.map { "\($0.fileName) \($0.description ?? "")" }
         + history.map { "\($0.actor) \($0.message)" }).joined(separator: " ")
    }
}

struct GalleryDecision: Identifiable, Sendable {
    var summary: HubDecisionSummary
    let attachments: [HubAttachment]
    var history: [HubHistoryEntry]
    var id: String { summary.id }

    var searchableText: String {
        ([summary.id, summary.title, summary.taskID, summary.lane.name, summary.reason, summary.reply ?? ""]
         + summary.options
         + attachments.map { "\($0.fileName) \($0.description ?? "")" }
         + history.map { "\($0.actor) \($0.message)" }).joined(separator: " ")
    }
}

enum GalleryData {
    // A fixed reference keeps deadline examples stable between launches.
    static let now = Date(timeIntervalSince1970: 1_791_590_400)
    static let design = HubLane(id: "design", name: "デザイン基盤")
    static let client = HubLane(id: "client", name: "ネイティブアプリ")
    static let lanes = [design, client]
    static let sampleReply = "案A：状態名とアイコンを併記する方針で進めてください。"
    static let longTitle = "日本語の長いタイトルでも省略せず、担当者・期限・レーンと判断に必要な情報を大きな文字で確認できるようにする"

    static let attachment = HubAttachment(
        id: "attachment-review", fileName: "アクセシビリティ確認結果_ダークモードと文字サイズ最大.png",
        description: "VoiceOverの読み上げ順と、色だけに依存しない状態表示を比較したサンプル画像。ファイル本体は含みません。",
        registeredBy: "UI確認エージェント", registeredAt: now.addingTimeInterval(-3_600), systemImage: "photo"
    )
    static let report = HubAttachment(
        id: "attachment-report", fileName: "検証記録_2026-10-10.txt",
        description: "狭い画面幅での折り返しとキーボード操作の検証記録。表示専用のメタデータです。",
        registeredBy: "Yuki", registeredAt: now.addingTimeInterval(-1_800)
    )
    static let initialHistory = [
        HubHistoryEntry(
            id: "history-start", actor: "実装エージェント", timestamp: now.addingTimeInterval(-7_200),
            message: "依頼を記録してから作業を開始。macOSとiOSで同じ表示モデルを使用する方針を追記しました。"
        ),
        HubHistoryEntry(
            id: "history-review", actor: "UI確認エージェント", timestamp: now.addingTimeInterval(-3_600),
            message: "ユーザー確認待ちへ更新。長い日本語・文字サイズ拡大・ダークモードの確認結果を追記しました。",
            evidence: "画面上の状態名とアイコンを確認。添付は架空の検証データです。", attachments: [attachment]
        )
    ]

    static let tasks: [GalleryTask] = [
        GalleryTask(
            summary: HubTaskSummary(
                id: "T-101", title: "共通コンポーネントのアクセシビリティを確認する", status: .needsReview,
                lane: design, priority: .high, assignee: "UI確認エージェント",
                dueDate: now.addingTimeInterval(-86_400), updatedBy: "実装エージェント", updatedAt: now,
                subtaskCount: 4, completedSubtaskCount: 3
            ),
            body: "色だけに頼らず、状態名・アイコン・期限を読み取れるか確認します。判断に必要な本文や長い添付ファイル名も、狭い画面と大きな文字で最後まで読めるようにします。",
            approach: "VoiceOver、キーボード操作、ライト／ダーク、文字サイズ拡大を順番に確認します。",
            attachments: [attachment, report], history: initialHistory
        ),
        GalleryTask(
            summary: HubTaskSummary(
                id: "T-102", title: "オフライン時の変更履歴を表示する", status: .inProgress,
                lane: client, assignee: "クライアント担当", dueDate: now.addingTimeInterval(10_800),
                updatedBy: "クライアント担当", updatedAt: now, subtaskCount: 3, completedSubtaskCount: 1
            ),
            body: "通信できない場合も、最終同期日時と保存済みのタスクを表示します。このギャラリーは通信せず、表示状態だけを切り替えます。",
            approach: "同期バナーと再試行操作をアプリ所有の状態で再現します。", attachments: [], history: initialHistory
        ),
        GalleryTask(
            summary: HubTaskSummary(
                id: "T-103", title: longTitle, status: .notStarted, lane: design, priority: .urgent,
                updatedBy: "日本語とアクセシビリティの確認を担当するエージェント", updatedAt: now
            ),
            body: "未割当・期限なし・長い日本語を組み合わせた境界値サンプルです。内容は読み取り専用で、検索やレーン選択はアプリが管理します。",
            approach: "文字サイズを最大にしても横方向の切り捨てが発生しないことを確認します。", attachments: [report], history: []
        ),
        GalleryTask(
            summary: HubTaskSummary(
                id: "T-104", title: "元タスクを再開する条件を整理する", status: .blocked,
                lane: client, priority: .high, assignee: "連携エージェント", dueDate: now.addingTimeInterval(172_800),
                updatedBy: "連携エージェント", updatedAt: now
            ),
            body: "ユーザー裁定が反映されるまで作業を停止しています。判断の根拠は履歴に追記します。",
            approach: "裁定の回答と元タスクIDの対応を確認します。", attachments: [], history: initialHistory
        ),
        GalleryTask(
            summary: HubTaskSummary(
                id: "T-105", title: "期限表示の確認を完了する", status: .completed, lane: design, priority: .low,
                assignee: "検証エージェント", dueDate: now.addingTimeInterval(-172_800),
                updatedBy: "Yuki", updatedAt: now, subtaskCount: 2, completedSubtaskCount: 2,
                evidence: "期限なし・期限切れ・完了済みの表示をサンプルデータで確認しました。"
            ),
            body: "完了時に根拠を残す例です。過去の期限でも、完了したタスクとして区別して表示します。",
            approach: "結果は上書きせず履歴へ追記します。", attachments: [report], history: initialHistory
        ),
        GalleryTask(
            summary: HubTaskSummary(
                id: "T-106", title: "次の改善候補を保留する", status: .onHold,
                lane: client, priority: .low, updatedBy: "Yuki", updatedAt: now
            ),
            body: "今すぐ着手しないタスクも削除せず残します。", approach: "次回の見直しで優先度を確認します。",
            attachments: [], history: []
        )
    ]

    static let decisions: [GalleryDecision] = [
        GalleryDecision(
            summary: HubDecisionSummary(
                id: "D-201", title: "状態表示を色だけに依存させない方針を決めてください", taskID: "T-101", lane: design,
                options: ["案A：状態名とアイコンを併記する", "案B：状態名だけを表示する", "追加の比較結果を待つ"],
                reason: "色覚の違いやダークモードでも、未着手・進行中・確認待ちを確実に識別できるようにするためです。元タスクの再開には方針の回答が必要です。",
                dueDate: now.addingTimeInterval(10_800), registeredBy: "UI確認エージェント", registeredAt: now
            ),
            attachments: [attachment], history: initialHistory
        ),
        GalleryDecision(
            summary: HubDecisionSummary(
                id: "D-202", title: "オフライン時に最終同期日時を表示してよいですか", taskID: "T-102", lane: client,
                status: .answered, options: ["表示する", "表示しない"], reason: "保存済みデータの鮮度を確認できるようにします。",
                registeredBy: "クライアント担当", registeredAt: now, reply: "最終同期日時を表示してください。"
            ),
            attachments: [], history: initialHistory
        ),
        GalleryDecision(
            summary: HubDecisionSummary(
                id: "D-203", title: "完了済みタスクの期限表示を確認してください", taskID: "T-105", lane: design,
                status: .applied, options: [], reason: "完了後は期限切れの警告を強調しない表示にしました。",
                dueDate: now.addingTimeInterval(-86_400), registeredBy: "検証エージェント", registeredAt: now,
                reply: "確認しました。この表示を採用してください。"
            ),
            attachments: [report], history: initialHistory
        )
    ]
}
