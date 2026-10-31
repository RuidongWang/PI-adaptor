import XCTest

@testable import PIiOSCore

/// 契约 §4.8（4.8.1 ~ 4.8.5）；spec AC-05.4 / AC-05.5 / AC-05.6。
final class ModelGroupingTests: XCTestCase {
    // MARK: - 4.8.1 分组规则（AC-05.4）

    func testAC05_4_groupsByProviderIdAndHidesEmptyProviders() {
        let groups = groupModelsByProvider(Fixture.providers)
        XCTAssertEqual(groups.count, 4, "空 models 的 provider 不渲染：\(Fixture.signature(groups))")
        XCTAssertFalse(groups.contains { $0.providerId == "prv_empty_333333" })
        XCTAssertEqual(
            groups.map(\.providerId),
            ["prv_alpha_111111", "prv_dupname_444444", "prv_beta_222222", nil] as [String?]
        )
    }

    func testAC05_4_defaultGroupFirstThenNameOrder() {
        let groups = groupModelsByProvider(Fixture.providers)
        XCTAssertEqual(
            groups.map(\.name),
            ["Alpha · 111111", "Alpha · 444444", "Beta", unconfirmedProviderGroupName],
            "含默认模型的组置顶，其余按 name 升序，未确认组最后"
        )
        XCTAssertTrue(groups[0].isDefaultGroup)
        XCTAssertFalse(groups[1].isDefaultGroup)
        XCTAssertTrue(groups.last?.isUnconfirmed ?? false)
    }

    func testAC05_4_disambiguatesDuplicateProviderNamesWithProviderIdSuffix() {
        let groups = groupModelsByProvider(Fixture.providers)
        let alphaGroups = groups.filter { $0.providerId?.hasPrefix("prv_alpha") == true || $0.providerId?.hasPrefix("prv_dupname") == true }
        XCTAssertEqual(alphaGroups.count, 2)
        for group in alphaGroups {
            let suffix = String((group.providerId ?? "").suffix(6))
            XCTAssertTrue(group.name.hasSuffix(" · \(suffix)"), "同名 provider 需追加 providerId 末 6 位：\(group.name)")
        }
    }

    func testAC05_4_keepsDeclarationOrderInsideGroup() {
        let groups = groupModelsByProvider(Fixture.providers)
        let alpha = groups.first { $0.providerId == "prv_alpha_111111" }
        XCTAssertEqual(alpha?.models.map(\.modelId), ["gpt-4o", "gpt-4o-mini"], "组内顺序 == 导入时 models[] 声明顺序")
        let beta = groups.first { $0.providerId == "prv_beta_222222" }
        XCTAssertEqual(beta?.models.map(\.modelId), ["gpt-4o", "claude-3-5"], "不按字母或能力重排")
    }

    func testAC05_4_emptyInputProducesNoGroups() {
        XCTAssertEqual(groupModelsByProvider([]), [])
        XCTAssertEqual(groupModelsByProvider([ProviderRecord(providerId: "p", name: "P", models: [])]), [])
    }

    // MARK: - 4.8.3 去重（AC-05.5）

    func testAC05_5_keepsFirstDuplicateModelIdInsideProviderWithDiagnostic() {
        let result = groupModelsByProviderDetailed(Fixture.providers)
        let alpha = result.groups.first { $0.providerId == "prv_alpha_111111" }
        XCTAssertEqual(alpha?.models.count, 2)
        XCTAssertEqual(alpha?.models.first?.modelId, "gpt-4o")
        XCTAssertTrue(alpha?.models.first === Fixture.firstAlphaModel, "保留首次出现的那条（原对象）")

        XCTAssertEqual(result.diagnostics.count, 1)
        let diagnostic = result.diagnostics.first
        XCTAssertEqual(diagnostic?.kind, .duplicateModel)
        XCTAssertEqual(diagnostic?.kind.rawValue, "duplicate-model")
        XCTAssertEqual(diagnostic?.providerId, "prv_alpha_111111")
        XCTAssertEqual(diagnostic?.modelId, "gpt-4o")
    }

    func testAC05_5_keepsSameModelIdAcrossProviders() {
        let groups = groupModelsByProvider(Fixture.providers)
        let occurrences = groups.flatMap(\.models).filter { $0.modelId == "gpt-4o" }
        XCTAssertEqual(occurrences.count, 2, "跨组不去重：同一 modelId 在两个 provider 下都保留")
        XCTAssertEqual(Set(occurrences.compactMap(\.providerId)), Set(["prv_alpha_111111", "prv_beta_222222"]))
        XCTAssertFalse(occurrences[0] === occurrences[1])
    }

    // MARK: - 4.8.5 四条不变量（AC-05.6）

    func testAC05_6_completenessInvariant() {
        let groups = groupModelsByProvider(Fixture.providers)
        let flattened = fixtureMultiset(flatten(groups))
        let expected = fixtureMultiset(deduplicatedByPair(Fixture.allModels))
        XCTAssertEqual(flattened, expected, "flatten(groups) 的 (providerId, modelId) 多重集 == 原数组去重后的多重集")
    }

    func testAC05_6_idempotenceInvariant() {
        let groups = groupModelsByProvider(Fixture.providers)
        let regrouped = groupModelsByProvider(
            groups.map { ProviderRecord(providerId: $0.providerId, name: $0.name, models: $0.models) }
        )
        XCTAssertEqual(Fixture.signature(regrouped), Fixture.signature(groups))
    }

    func testAC05_6_stabilityInvariant() {
        let first = groupModelsByProvider(Fixture.providers)
        let second = groupModelsByProvider(Fixture.providers)
        XCTAssertEqual(Fixture.signature(first), Fixture.signature(second))
        XCTAssertEqual(first.flatMap { $0.models.map(\.modelId) }, second.flatMap { $0.models.map(\.modelId) })
    }

    func testAC05_6_referenceIdentityInvariant() {
        let groups = groupModelsByProvider(Fixture.providers)
        for group in groups {
            for model in group.models {
                let originals = Fixture.allModels.filter { $0.providerId == model.providerId && $0.modelId == model.modelId }
                XCTAssertTrue(
                    originals.contains { $0 === model },
                    "分组结果里的 models 必须是原对象引用：\(model.modelId)"
                )
            }
        }
        XCTAssertTrue(flatten(groups).contains { $0 === Fixture.firstAlphaModel })
    }

    // MARK: - 审查返工（fix 1 / 2 / 11 / 12）

    func testFix1_unconfirmedBucketsDoNotDedupeAcrossRecords() {
        let first = ModelRecord(providerId: nil, modelId: "gpt-4o", alias: "first")
        let second = ModelRecord(providerId: nil, modelId: "gpt-4o", alias: "second")
        let confirmed = ModelRecord(providerId: "prv_a_111111", modelId: "gpt-4o")
        let providers = [
            ProviderRecord(providerId: "prv_a_111111", name: "A", models: [confirmed]),
            ProviderRecord(providerId: nil, name: "残留甲", models: [first]),
            ProviderRecord(providerId: nil, name: "残留乙", models: [second]),
        ]

        let result = groupModelsByProviderDetailed(providers)
        let unconfirmed = result.groups.filter(\.isUnconfirmed)

        XCTAssertEqual(unconfirmed.count, 2, "未确认记录必须各自成桶：\(Fixture.signature(result.groups))")
        XCTAssertEqual(unconfirmed.map { $0.models.map(\.modelId) }, [["gpt-4o"], ["gpt-4o"]])
        XCTAssertTrue(unconfirmed.allSatisfy { $0.name.hasPrefix(unconfirmedProviderGroupName) })
        XCTAssertEqual(
            Set(unconfirmed.map(\.name)).count,
            2,
            "多条残留的组标题必须可区分，否则面板上是两个同名组：\(unconfirmed.map(\.name))"
        )
        XCTAssertEqual(result.diagnostics, [], "跨「未确认」记录不得判 duplicate-model")
        XCTAssertTrue(unconfirmed[0].models.first === first)
        XCTAssertTrue(unconfirmed[1].models.first === second)
        // 未确认桶仍固定排在最后。
        XCTAssertEqual(result.groups.map(\.isUnconfirmed), [false, true, true])
    }

    func testFix2_disambiguationIsIdempotentWhenLiteralNameCollidesWithSuffix() {
        let providers = [
            ProviderRecord(
                providerId: "prv_x_aaa111",
                name: "X",
                models: [ModelRecord(providerId: "prv_x_aaa111", modelId: "m1")]
            ),
            ProviderRecord(
                providerId: "prv_y_bbb222",
                name: "X",
                models: [ModelRecord(providerId: "prv_y_bbb222", modelId: "m2")]
            ),
            // 名称字面量正好是「X · aaa111」：只做一轮消歧会产出两个同名标题。
            ProviderRecord(
                providerId: "prv_z_ccc333",
                name: "X · aaa111",
                models: [ModelRecord(providerId: "prv_z_ccc333", modelId: "m3")]
            ),
        ]

        let groups = groupModelsByProvider(providers)
        let regrouped = groupModelsByProvider(
            groups.map { ProviderRecord(providerId: $0.providerId, name: $0.name, models: $0.models) }
        )

        XCTAssertEqual(Fixture.signature(regrouped), Fixture.signature(groups), "同名消歧必须对最终标题集合取不动点")
        XCTAssertEqual(Set(groups.map(\.name)).count, 3, "三个 provider 的标题应互不相同：\(groups.map(\.name))")
    }

    func testFix11_unconfirmedRecordNameDoesNotInflateProviderNameCounts() {
        let providers = [
            ProviderRecord(
                providerId: "prv_real_555555",
                name: "Shared",
                models: [ModelRecord(providerId: "prv_real_555555", modelId: "m1")]
            ),
            // 未确认记录的名称撞上正常 provider 的名称：不该让正常 provider 被加后缀。
            ProviderRecord(providerId: nil, name: "Shared", models: [ModelRecord(providerId: nil, modelId: "m2")]),
        ]

        let groups = groupModelsByProvider(providers)
        let confirmed = groups.first { $0.providerId == "prv_real_555555" }

        XCTAssertEqual(confirmed?.name, "Shared", "同名计数只统计会渲染成 provider 名的组")
        XCTAssertTrue(groups.contains { $0.isUnconfirmed && $0.name == unconfirmedProviderGroupName })
    }

    func testFix12_emptyProviderNameFallsBackToStableTitle() {
        let single = groupModelsByProvider([
            ProviderRecord(
                providerId: "prv_nan_666666",
                name: "",
                models: [ModelRecord(providerId: "prv_nan_666666", modelId: "m1")]
            )
        ])
        XCTAssertEqual(single.map(\.name), [unnamedProviderGroupName], "空名称不能渲染成空标题")

        let pair = groupModelsByProvider([
            ProviderRecord(
                providerId: "prv_nan_666666",
                name: "",
                models: [ModelRecord(providerId: "prv_nan_666666", modelId: "m1")]
            ),
            ProviderRecord(
                providerId: "prv_nan_777777",
                name: "   ",
                models: [ModelRecord(providerId: "prv_nan_777777", modelId: "m2")]
            ),
        ])
        XCTAssertEqual(
            Set(pair.map(\.name)).count, 2,
            "回退标题也要按 providerId 消歧：\(pair.map(\.name))"
        )
        XCTAssertTrue(pair.allSatisfy { $0.name.hasPrefix(unnamedProviderGroupName) })
    }

    // MARK: - fixture

    private func fixtureMultiset(_ models: [ModelRecord]) -> [String] {
        models.map { "\($0.providerId ?? "nil")/\($0.modelId)" }
            .reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            .map { "\($0.key)x\($0.value)" }
            .sorted()
    }

    /// 契约 §4.8.5 不变量 1 的对照物：`x` 按 `(providerId, modelId)` 去重后的多重集。
    private func deduplicatedByPair(_ models: [ModelRecord]) -> [ModelRecord] {
        var seen = Set<String>()
        var result: [ModelRecord] = []
        for model in models {
            let key = "\(model.providerId ?? "nil")/\(model.modelId)"
            if seen.insert(key).inserted {
                result.append(model)
            }
        }
        return result
    }

    private enum Fixture {
        static let firstAlphaModel = ModelRecord(
            providerId: "prv_alpha_111111",
            modelId: "gpt-4o",
            alias: "GPT-4o",
            contextWindow: 128_000,
            maxTokens: 4_096,
            thinkingLevels: ["off", "low"]
        )
        static let defaultAlphaModel = ModelRecord(
            providerId: "prv_alpha_111111",
            modelId: "gpt-4o-mini",
            contextWindow: 128_000,
            maxTokens: 16_384,
            thinkingLevels: ["off", "medium"],
            isDefault: true
        )
        /// 同 provider 内重复 modelId（应被去重并上报诊断）。
        static let duplicateAlphaModel = ModelRecord(
            providerId: "prv_alpha_111111",
            modelId: "gpt-4o",
            contextWindow: 64_000,
            maxTokens: 2_048
        )
        /// 跨 provider 同名 modelId（必须保留）。
        static let betaModelSameId = ModelRecord(
            providerId: "prv_beta_222222",
            modelId: "gpt-4o",
            contextWindow: 32_000,
            maxTokens: 1_024
        )
        static let betaModel = ModelRecord(
            providerId: "prv_beta_222222",
            modelId: "claude-3-5",
            contextWindow: 200_000,
            maxTokens: 8_192
        )
        /// 无 providerId 的残留记录（归「未确认」组）。
        static let unconfirmedModel = ModelRecord(providerId: nil, modelId: "ghost-model")

        static let providers: [ProviderRecord] = [
            ProviderRecord(providerId: "prv_beta_222222", name: "Beta", models: [betaModelSameId, betaModel]),
            ProviderRecord(providerId: nil, name: "Residue", models: [unconfirmedModel]),
            ProviderRecord(
                providerId: "prv_alpha_111111",
                name: "Alpha",
                models: [firstAlphaModel, duplicateAlphaModel, defaultAlphaModel]
            ),
            ProviderRecord(providerId: "prv_empty_333333", name: "Empty", models: []),
            ProviderRecord(providerId: "prv_dupname_444444", name: "Alpha", models: [dupNameModel]),
        ]

        static let dupNameModel = ModelRecord(providerId: "prv_dupname_444444", modelId: "dup-name-model")

        static let allModels: [ModelRecord] = [
            firstAlphaModel, defaultAlphaModel, duplicateAlphaModel, betaModelSameId, betaModel,
            unconfirmedModel, dupNameModel,
        ]

        static func signature(_ groups: [ProviderModelGroup]) -> [String] {
            groups.map { group in
                let id = group.providerId ?? "nil"
                return "\(id)|\(group.name)|\(group.isDefaultGroup)|\(group.models.map(\.modelId).joined(separator: ","))"
            }
        }
    }
}
