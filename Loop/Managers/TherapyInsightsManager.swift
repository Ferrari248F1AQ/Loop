//
//  TherapyInsightsManager.swift
//  Loop
//
//  Bridges Loop's data stores to the TherapyRegression engine.
//  Pod-agnostic — reads from GlucoseStore, DoseStore, and CarbStore.
//

import Foundation
import LoopKit
import LoopKitUI
import HealthKit

class TherapyInsightsManager {

    private let glucoseStore: GlucoseStore
    private let doseStore: DoseStore
    private let carbStore: CarbStore
    private let therapySettingsProvider: () -> TherapySettings
    weak var therapySettingsDelegate: TherapySettingsViewModelDelegate?

    init(glucoseStore: GlucoseStore,
         doseStore: DoseStore,
         carbStore: CarbStore,
         therapySettings: @escaping () -> TherapySettings) {
        self.glucoseStore = glucoseStore
        self.doseStore = doseStore
        self.carbStore = carbStore
        self.therapySettingsProvider = therapySettings
    }

    func generateReport(completion: @escaping (RegressionReport) -> Void) {
        let windowDays = TherapyRegression.defaultWindowDays
        let start = Date().addingTimeInterval(-Double(windowDays) * 86400)
        let settings = therapySettingsProvider()

        let group = DispatchGroup()
        var glucoseSamples: [RegressionGlucoseSample] = []
        var insulinDeliveries: [RegressionInsulinDelivery] = []
        var carbEntries: [RegressionCarbEntry] = []

        group.enter()
        glucoseStore.getGlucoseSamples(start: start, end: nil) { result in
            if case .success(let samples) = result {
                glucoseSamples = samples.map { sample in
                    RegressionGlucoseSample(
                        date: sample.startDate,
                        mgdl: sample.quantity.doubleValue(for: .milligramsPerDeciliter)
                    )
                }
            }
            group.leave()
        }

        group.enter()
        doseStore.getNormalizedDoseEntries(start: start, end: nil) { result in
            if case .success(let doses) = result {
                insulinDeliveries = doses.map { dose in
                    RegressionInsulinDelivery(
                        startDate: dose.startDate,
                        endDate: dose.endDate,
                        units: dose.deliveredUnits ?? dose.programmedUnits,
                        isBasal: dose.type == .basal || dose.type == .tempBasal,
                        isAutomatic: dose.automatic ?? false
                    )
                }
            }
            group.leave()
        }

        group.enter()
        carbStore.getCarbEntries(start: start, end: nil) { result in
            if case .success(let entries) = result {
                carbEntries = entries.map { entry in
                    RegressionCarbEntry(
                        date: entry.startDate,
                        grams: entry.quantity.doubleValue(for: .gram()),
                        absorptionTime: entry.absorptionTime ?? 10800
                    )
                }
            }
            group.leave()
        }

        group.notify(queue: .main) {
            let basalSchedule = settings.basalRateSchedule?.items.map {
                (startTime: $0.startTime, rate: $0.value)
            } ?? [(startTime: 0, rate: 1.0)]

            let isfSchedule = settings.insulinSensitivitySchedule?.items.map {
                (startTime: $0.startTime, mgdlPerUnit: $0.value.doubleValue(for: .milligramsPerDeciliter))
            } ?? [(startTime: 0, mgdlPerUnit: 50.0)]

            let icrSchedule = settings.carbRatioSchedule?.items.map {
                (startTime: $0.startTime, gramsPerUnit: $0.value)
            } ?? [(startTime: 0, gramsPerUnit: 10.0)]

            let report = TherapyRegression.analyze(
                glucose: glucoseSamples,
                insulin: insulinDeliveries,
                carbs: carbEntries,
                currentBasalSchedule: basalSchedule,
                currentISFSchedule: isfSchedule,
                currentICRSchedule: icrSchedule
            )

            completion(report)
        }
    }

    // MARK: - Apply suggestions

    func applyBasalSuggestion(_ suggestion: BasalSuggestion) {
        var settings = therapySettingsProvider()
        guard var items = settings.basalRateSchedule?.items else { return }

        for i in items.indices {
            if items[i].startTime >= suggestion.startTime && items[i].startTime < suggestion.endTime {
                items[i] = RepeatingScheduleValue(startTime: items[i].startTime, value: suggestion.suggestedRate)
            }
        }

        therapySettingsDelegate?.syncBasalRateSchedule(items: items) { [weak self] result in
            if case .success(let newSchedule) = result {
                settings.basalRateSchedule = newSchedule
                self?.therapySettingsDelegate?.saveCompletion(therapySettings: settings)
            }
        }
    }

    func applyISFSuggestion(_ suggestion: ISFSuggestion) {
        var settings = therapySettingsProvider()
        guard let schedule = settings.insulinSensitivitySchedule else { return }
        var items = schedule.items

        for i in items.indices {
            if items[i].startTime >= suggestion.startTime && items[i].startTime < suggestion.endTime {
                let newQuantity = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: suggestion.suggestedISF)
                items[i] = RepeatingScheduleValue(startTime: items[i].startTime, value: newQuantity.doubleValue(for: schedule.unit))
            }
        }

        if let newSchedule = InsulinSensitivitySchedule(unit: schedule.unit, dailyItems: items, timeZone: schedule.timeZone) {
            settings.insulinSensitivitySchedule = newSchedule
            therapySettingsDelegate?.saveCompletion(therapySettings: settings)
        }
    }

    func applyICRSuggestion(_ suggestion: ICRSuggestion) {
        var settings = therapySettingsProvider()
        guard let schedule = settings.carbRatioSchedule else { return }
        var items = schedule.items

        for i in items.indices {
            if items[i].startTime >= suggestion.startTime && items[i].startTime < suggestion.endTime {
                items[i] = RepeatingScheduleValue(startTime: items[i].startTime, value: suggestion.suggestedICR)
            }
        }

        if let newSchedule = CarbRatioSchedule(unit: schedule.unit, dailyItems: items, timeZone: schedule.timeZone) {
            settings.carbRatioSchedule = newSchedule
            therapySettingsDelegate?.saveCompletion(therapySettings: settings)
        }
    }

    func applyAllSuggestions(from report: RegressionReport) {
        var settings = therapySettingsProvider()

        // Apply basal
        if let basalSchedule = settings.basalRateSchedule {
            var items = basalSchedule.items
            for suggestion in report.basalSuggestions {
                for i in items.indices {
                    if items[i].startTime >= suggestion.startTime && items[i].startTime < suggestion.endTime {
                        items[i] = RepeatingScheduleValue(startTime: items[i].startTime, value: suggestion.suggestedRate)
                    }
                }
            }
            therapySettingsDelegate?.syncBasalRateSchedule(items: items) { [weak self] result in
                if case .success(let newSchedule) = result {
                    settings.basalRateSchedule = newSchedule
                }
                self?.applyISFAndICR(to: &settings, from: report)
            }
        } else {
            applyISFAndICR(to: &settings, from: report)
        }
    }

    private func applyISFAndICR(to settings: inout TherapySettings, from report: RegressionReport) {
        // Apply ISF
        if let schedule = settings.insulinSensitivitySchedule {
            var items = schedule.items
            for suggestion in report.isfSuggestions {
                for i in items.indices {
                    if items[i].startTime >= suggestion.startTime && items[i].startTime < suggestion.endTime {
                        let newQuantity = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: suggestion.suggestedISF)
                        items[i] = RepeatingScheduleValue(startTime: items[i].startTime, value: newQuantity.doubleValue(for: schedule.unit))
                    }
                }
            }
            if let newSchedule = InsulinSensitivitySchedule(unit: schedule.unit, dailyItems: items, timeZone: schedule.timeZone) {
                settings.insulinSensitivitySchedule = newSchedule
            }
        }

        // Apply ICR
        if let schedule = settings.carbRatioSchedule {
            var items = schedule.items
            for suggestion in report.icrSuggestions {
                for i in items.indices {
                    if items[i].startTime >= suggestion.startTime && items[i].startTime < suggestion.endTime {
                        items[i] = RepeatingScheduleValue(startTime: items[i].startTime, value: suggestion.suggestedICR)
                    }
                }
            }
            if let newSchedule = CarbRatioSchedule(unit: schedule.unit, dailyItems: items, timeZone: schedule.timeZone) {
                settings.carbRatioSchedule = newSchedule
            }
        }

        therapySettingsDelegate?.saveCompletion(therapySettings: settings)
    }
}
