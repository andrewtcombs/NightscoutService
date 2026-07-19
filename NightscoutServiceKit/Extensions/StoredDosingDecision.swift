//
//  StoredDosingDecision.swift
//  NightscoutServiceKit
//
//  Created by Darin Krauss on 10/17/19.
//  Copyright © 2019 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit
import LoopKit
import NightscoutKit

extension StoredDosingDecision {
    
    var loopStatusIOB: IOBStatus? {
        guard let insulinOnBoard = insulinOnBoard else {
            return nil
        }
        return IOBStatus(timestamp: insulinOnBoard.startDate, iob: insulinOnBoard.value)
    }
    
    var loopStatusCOB: COBStatus? {
        guard let carbsOnBoard = carbsOnBoard else {
            return nil
        }
        return COBStatus(cob: carbsOnBoard.quantity.doubleValue(for: HKUnit.gram()), timestamp: carbsOnBoard.startDate)
    }
    
    var loopStatusPredicted: PredictedBG? {
        guard let predictedGlucose = predictedGlucose, let startDate = predictedGlucose.first?.startDate else {
            return nil
        }
        return PredictedBG(startDate: startDate, values: predictedGlucose.map { $0.quantity })
    }

    var loopStatusAutomaticDoseRecommendation: NightscoutKit.AutomaticDoseRecommendation? {
        guard let automaticDoseRecommendation = automaticDoseRecommendation else {
            return nil
        }
        
        let nightscoutTempBasalAdjustment: TempBasalAdjustment?
        
        if let basalAdjustment = automaticDoseRecommendation.basalAdjustment {
            nightscoutTempBasalAdjustment = TempBasalAdjustment(rate: basalAdjustment.unitsPerHour, duration: basalAdjustment.duration)
        } else {
            nightscoutTempBasalAdjustment = nil
        }
        
        return NightscoutKit.AutomaticDoseRecommendation(
            timestamp: date,
            tempBasalAdjustment: nightscoutTempBasalAdjustment,
            bolusVolume: automaticDoseRecommendation.bolusUnits ?? 0)
    }

    var loopStatusRecommendedBolus: Double? {
        guard let manualBolusRecommendation = manualBolusRecommendation else {
            return nil
        }
        return manualBolusRecommendation.recommendation.amount
    }

    var loopStatusTherapySettings: TherapySettingsStatus? {
        guard let glucoseTargetRange = glucoseTargetRangeSchedule?.value(at: date) else {
            return nil
        }

        let unit = glucoseTargetRangeSchedule?.unit ?? HKUnit.milligramsPerDeciliter
        let lowerTarget = HKQuantity(unit: unit, doubleValue: glucoseTargetRange.minValue)
        let upperTarget = HKQuantity(unit: unit, doubleValue: glucoseTargetRange.maxValue)
        let effectiveTargetRange = CorrectionRange(minValue: lowerTarget, maxValue: upperTarget)

        let activeOverride: ActiveOverrideStatus?
        if let scheduleOverride = scheduleOverride, scheduleOverride.isActive(at: date) {
            activeOverride = ActiveOverrideStatus(
                name: scheduleOverride.nightscoutTelemetryName,
                context: scheduleOverride.nightscoutTelemetryContext,
                startDate: scheduleOverride.startDate,
                endDate: scheduleOverride.duration != .indefinite ? scheduleOverride.actualEndDate : nil,
                duration: scheduleOverride.duration != .indefinite ? scheduleOverride.actualEndDate.timeIntervalSince(date) : nil,
                targetRange: scheduleOverride.settings.targetRange.map { CorrectionRange(minValue: $0.lowerBound, maxValue: $0.upperBound) },
                insulinNeedsScaleFactor: scheduleOverride.settings.insulinNeedsScaleFactor
            )
        } else {
            activeOverride = nil
        }

        return TherapySettingsStatus(effectiveTargetRange: effectiveTargetRange, activeOverride: activeOverride)
    }

    var loopStatusController: NightscoutKit.ControllerStatus? {
        return settings?.dosingEnabled.map { NightscoutKit.ControllerStatus(closedLoop: $0) }
    }

    var loopStatusPumpDelivery: PumpDeliveryStatus? {
        guard let pumpManagerStatus = pumpManagerStatus else {
            return nil
        }

        return PumpDeliveryStatus(
            basalState: pumpManagerStatus.basalDeliveryState?.nightscoutTelemetryStatus,
            suspended: pumpManagerStatus.basalDeliveryState?.isSuspended,
            bolusing: pumpStatusBolusing,
            deliveryIsUncertain: pumpManagerStatus.deliveryIsUncertain
        )
    }
    
    var loopStatusEnacted: LoopEnacted? {
        guard let automaticDoseRecommendation = automaticDoseRecommendation, errors.isEmpty else {
            return nil
        }
        let tempBasal = automaticDoseRecommendation.basalAdjustment
        // NS needs to be updated to support an "enacted" field with no rate. Once that happens, we should not report a fake cancel here, and rate/duration should be nil instead of 0
        return LoopEnacted(rate: tempBasal?.unitsPerHour ?? 0, duration: tempBasal?.duration ?? 0, timestamp: date, received: true, bolusVolume: automaticDoseRecommendation.bolusUnits ?? 0)
    }

    var loopStatusFailureReason: String? {
        return errors.first?.description
    }
    
    var pumpStatusBattery: BatteryStatus? {
        guard let pumpBatteryChargeRemaining = pumpManagerStatus?.pumpBatteryChargeRemaining else {
            return nil
        }
        return BatteryStatus(percent: Int(round(pumpBatteryChargeRemaining * 100)), voltage: nil, status: nil)
    }
    
    var pumpStatusBolusing: Bool {
        guard let pumpManagerStatus = pumpManagerStatus, case .inProgress = pumpManagerStatus.bolusState else {
            return false
        }
        return true
    }
    
    var pumpStatusReservoir: Double? {
        guard let lastReservoirValue = lastReservoirValue, lastReservoirValue.startDate > Date().addingTimeInterval(.minutes(-15)) else {
            return nil
        }
        return lastReservoirValue.unitVolume
    }
    
    var pumpStatus: PumpStatus? {
        guard let pumpManagerStatus = pumpManagerStatus else {
            return nil
        }

        return PumpStatus(
            clock: date,
            pumpID: pumpManagerStatus.device.localIdentifier ?? "Unknown",
            manufacturer: pumpManagerStatus.device.manufacturer,
            model: pumpManagerStatus.device.model,
            iob: nil,
            battery: pumpStatusBattery,
            suspended: pumpManagerStatus.basalDeliveryState?.isSuspended,
            bolusing: pumpStatusBolusing,
            reservoir: pumpStatusReservoir,
            secondsFromGMT: pumpManagerStatus.timeZone.secondsFromGMT(),
            reservoirDisplayOverride: pumpStatusHighlight?.localizedMessage,
            reservoirLevelOverride: pumpStatusHighlight?.reservoirLevelOverride
        )
    }
    
    var overrideStatus: NightscoutKit.OverrideStatus {
        guard let scheduleOverride = scheduleOverride, scheduleOverride.isActive(),
            let glucoseTargetRange = glucoseTargetRangeSchedule?.value(at: date) else
        {
            return NightscoutKit.OverrideStatus(timestamp: date, active: false)
        }
        
        let unit = glucoseTargetRangeSchedule?.unit ?? HKUnit.milligramsPerDeciliter
        let lowerTarget = HKQuantity(unit: unit, doubleValue: glucoseTargetRange.minValue)
        let upperTarget = HKQuantity(unit: unit, doubleValue: glucoseTargetRange.maxValue)
        let currentCorrectionRange = CorrectionRange(minValue: lowerTarget, maxValue: upperTarget)
        let duration = scheduleOverride.duration != .indefinite ? round(scheduleOverride.actualEndDate.timeIntervalSince(date)): nil
        
        return NightscoutKit.OverrideStatus(name: scheduleOverride.context.name,
                                                  timestamp: date,
                                                  active: true,
                                                  currentCorrectionRange: currentCorrectionRange,
                                                  duration: duration,
                                                  multiplier: scheduleOverride.settings.insulinNeedsScaleFactor)
    }
    
    var uploaderStatus: UploaderStatus {
        let uploaderDevice = UIDevice.current
        let battery = uploaderDevice.isBatteryMonitoringEnabled ? Int(uploaderDevice.batteryLevel * 100) : 0
        return UploaderStatus(name: uploaderDevice.name, timestamp: date, battery: battery)
    }
    
    func deviceStatus(automaticDoseDecision: StoredDosingDecision?, activity: ActivityStatus? = nil) -> DeviceStatus {
        return DeviceStatus(device: "loop://\(UIDevice.current.name)",
            timestamp: date,
            pumpStatus: pumpStatus,
            uploaderStatus: uploaderStatus,
            loopStatus: LoopStatus(name: Bundle.main.bundleDisplayName,
                                   version: Bundle.main.fullVersionString,
                                   timestamp: date,
                                   iob: loopStatusIOB,
                                   cob: loopStatusCOB,
                                   predicted: loopStatusPredicted,
                                   automaticDoseRecommendation: loopStatusAutomaticDoseRecommendation,
                                   recommendedBolus: loopStatusRecommendedBolus,
                                   enacted: automaticDoseDecision?.loopStatusEnacted,
                                   failureReason: automaticDoseDecision?.loopStatusFailureReason,
                                   activity: activity,
                                   therapySettings: loopStatusTherapySettings,
                                   controller: loopStatusController,
                                   pumpDelivery: loopStatusPumpDelivery),
            overrideStatus: overrideStatus)
    }
    
}

private extension TemporaryScheduleOverride {
    var nightscoutTelemetryContext: String {
        switch context {
        case .preMeal:
            return "preMeal"
        case .legacyWorkout:
            return "legacyWorkout"
        case .preset:
            return "preset"
        case .custom:
            return "custom"
        }
    }

    var nightscoutTelemetryName: String {
        switch context {
        case .preMeal:
            return "Pre-Meal"
        case .legacyWorkout:
            return "Workout"
        case .preset(let preset):
            return preset.name
        case .custom:
            return "Custom"
        }
    }
}

private extension PumpManagerStatus.BasalDeliveryState {
    var nightscoutTelemetryStatus: BasalDeliveryStateStatus {
        switch self {
        case .active(let at):
            return BasalDeliveryStateStatus(kind: "activeScheduled", startedAt: at)
        case .initiatingTempBasal:
            return BasalDeliveryStateStatus(kind: "initiatingTempBasal")
        case .tempBasal(let dose):
            return BasalDeliveryStateStatus(kind: "tempBasal", startedAt: dose.startDate, rate: dose.unitsPerHour, duration: dose.endDate.timeIntervalSince(dose.startDate))
        case .cancelingTempBasal:
            return BasalDeliveryStateStatus(kind: "cancelingTempBasal")
        case .suspending:
            return BasalDeliveryStateStatus(kind: "suspending")
        case .suspended(let at):
            return BasalDeliveryStateStatus(kind: "suspended", startedAt: at)
        case .resuming:
            return BasalDeliveryStateStatus(kind: "resuming")
        }
    }
}

extension StoredDosingDecision.Issue {
    var description: String {
        var description = id
        if let details = details {
            description += String(describing: details)
        }
        return description
    }
}

extension StoredDosingDecision.StoredDeviceHighlight {
    var reservoirLevelOverride: NightscoutSeverityLevel {
        switch state {
        case .normalPump, .normalCGM:
            return .none
        case .warning:
            return .warn
        case .critical:
            return .urgent
        }
    }
}

