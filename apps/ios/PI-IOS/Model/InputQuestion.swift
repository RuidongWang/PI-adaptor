import Foundation
import PIiOSCore

/// 一张 AskTool 提问卡里的一个问题（`questions[]` 元素形状未在契约中冻结，按只读访问器解析）。
struct InputQuestion: Equatable, Identifiable {
    let id: Int
    /// 问题正文；读不到时给可辨认的占位，不编造内容。
    let prompt: String
    /// 该问题自带的选项标签；为空表示只能跳过（不提供自由文本，避免发服务器不接受的答案）。
    let options: [String]
}

enum InputQuestionParser {
    /// 解析一张提问卡的问题列表。顺序即 `answers` 的下标顺序（AC-11.1）。
    static func questions(from card: RACPInputRequest) -> [InputQuestion] {
        guard let raw = card.payload.value(at: ["questions"])?.arrayValue else { return [] }
        return raw.enumerated().map { index, element in
            let prompt = element.value(at: ["question"])?.stringValue
                ?? element.value(at: ["prompt"])?.stringValue
                ?? element.value(at: ["text"])?.stringValue
                ?? element.value(at: ["title"])?.stringValue
                ?? "问题 \(index + 1)"
            let options = (element.value(at: ["options"])?.arrayValue ?? []).compactMap { option -> String? in
                if let text = option.stringValue { return text }
                return option.value(at: ["label"])?.stringValue ?? option.value(at: ["value"])?.stringValue
            }
            return InputQuestion(id: index, prompt: prompt, options: options)
        }
    }

    /// 组装 `input/respond.answers`：每题一组选中标签，未选的写 `nil`（跳过）。
    static func answers(selections: [Int: Set<String>], questionCount: Int) -> [[String]?] {
        var result: [[String]?] = []
        result.reserveCapacity(questionCount)
        for index in 0..<questionCount {
            if let chosen = selections[index], !chosen.isEmpty {
                result.append(Array(chosen).sorted())
            } else {
                result.append(nil)
            }
        }
        return result
    }
}
