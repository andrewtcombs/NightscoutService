//
//  NightscoutService.swift
//  NightscoutServiceKit
//
//  Created by Darin Krauss on 6/20/19.
//  Copyright © 2019 LoopKit Authors. All rights reserved.
//

import os.log
import HealthKit
import LoopKit
import NightscoutKit

public enum NightscoutServiceError: Error {
    case incompatibleTherapySettings
    case missingCredentials
    case missingCommandSource
}


public final class NightscoutService: Service {

    public static let pluginIdentifier = "NightscoutService"

    public static let localizedTitle = LocalizedString("Nightscout", comment: "The title of the Nightscout service")
    
    public let objectIdCacheKeepTime = TimeInterval(24 * 60 * 60)

    public weak var serviceDelegate: ServiceDelegate?
    
    public weak var stateDelegate: StatefulPluggableDelegate?

    public var siteURL: URL?

    public var apiSecret: String?
    
    public var isOnboarded: Bool

    public let otpManager: OTPManager
    
    /// Maps loop syncIdentifiers to Nightscout objectIds
    var objectIdCache: ObjectIdCache {
        get {
            return lockedObjectIdCache.value
        }
        set {
            lockedObjectIdCache.value = newValue
        }
    }
    private let lockedObjectIdCache: Locked<ObjectIdCache>

    private var _uploader: NightscoutClient?

    private var uploader: NightscoutClient? {
        if _uploader == nil {
            guard let siteURL = siteURL, let apiSecret = apiSecret else {
                return nil
            }
            _uploader = NightscoutClient(siteURL: siteURL, apiSecret: apiSecret)
        }
        return _uploader
    }
    
    private let commandSourceV1: RemoteCommandSourceV1

    private let activityAggregator = NightscoutActivityAggregator()

    private let log = OSLog(category: "NightscoutService")

    public init() {
        self.isOnboarded = false
        self.lockedObjectIdCache = Locked(ObjectIdCache())
        self.otpManager = OTPManager(secretStore: KeychainManager())
        self.commandSourceV1 = RemoteCommandSourceV1(otpManager: otpManager)
        self.commandSourceV1.delegate = self
    }

    public required init?(rawState: RawStateValue) {
        self.isOnboarded = rawState["isOnboarded"] as? Bool ?? true   // Backwards compatibility

        if let objectIdCacheRaw = rawState["objectIdCache"] as? ObjectIdCache.RawValue,
            let objectIdCache = ObjectIdCache(rawValue: objectIdCacheRaw)
        {
            self.lockedObjectIdCache = Locked(objectIdCache)
        } else {
            self.lockedObjectIdCache = Locked(ObjectIdCache())
        }
        
        self.otpManager = OTPManager(secretStore: KeychainManager())
        self.commandSourceV1 = RemoteCommandSourceV1(otpManager: otpManager)
        self.commandSourceV1.delegate = self
        
        restoreCredentials()
    }

    public var rawState: RawStateValue {
        return [
            "isOnboarded": isOnboarded,
            "objectIdCache": objectIdCache.rawValue
        ]
    }

    public var lastDosingDecisionForAutomaticDose: StoredDosingDecision?

    public var hasConfiguration: Bool { return siteURL != nil && apiSecret?.isEmpty == false }

    public func verifyConfiguration(completion: @escaping (Error?) -> Void) {
        guard hasConfiguration, let siteURL = siteURL, let apiSecret = apiSecret else {
            completion(NightscoutServiceError.missingCredentials)
            return
        }

        let uploader = NightscoutClient(siteURL: siteURL, apiSecret: apiSecret)
        uploader.checkAuth(completion)
    }

    public func completeCreate() {
        saveCredentials()
    }

    public func completeOnboard() {
        isOnboarded = true

        saveCredentials()
        stateDelegate?.pluginDidUpdateState(self)
    }

    public func completeUpdate() {
        saveCredentials()
        stateDelegate?.pluginDidUpdateState(self)
    }

    public func completeDelete() {
        clearCredentials()
        stateDelegate?.pluginWantsDeletion(self)
    }

    private func saveCredentials() {
        try? KeychainManager().setNightscoutCredentials(siteURL: siteURL, apiSecret: apiSecret)
    }

    public func restoreCredentials() {
        if let credentials = try? KeychainManager().getNightscoutCredentials() {
            self.siteURL = credentials.siteURL
            self.apiSecret = credentials.apiSecret
        }
    }

    public func clearCredentials() {
        siteURL = nil
        apiSecret = nil
        try? KeychainManager().setNightscoutCredentials()
    }
    
}

extension NightscoutService: RemoteDataService {

    public func uploadTemporaryOverrideData(updated: [LoopKit.TemporaryScheduleOverride], deleted: [LoopKit.TemporaryScheduleOverride], completion: @escaping (Result<Bool, Error>) -> Void) {
        guard let uploader = uploader else {
            completion(.success(true))
            return
        }

        let updates = updated.map { OverrideTreatment(override: $0) }

        let deletions = deleted.map { $0.syncIdentifier.uuidString }

        uploader.deleteTreatmentsById(deletions, completionHandler: { (error) in
            if let error = error {
                self.log.error("Overrides deletions failed to delete %{public}@: %{public}@", String(describing: deletions), String(describing: error))
            } else {
                if deletions.count > 0 {
                    self.log.debug("Deleted ids: %@", deletions)
                }
                uploader.upload(updates) { (result) in
                    switch result {
                    case .failure(let error):
                        self.log.error("Failed to upload overrides %{public}@: %{public}@", String(describing: updates.map {$0.dictionaryRepresentation}), String(describing: error))
                        completion(.failure(error))
                    case .success:
                        self.log.debug("Uploaded overrides %@", String(describing: updates.map {$0.dictionaryRepresentation}))
                        completion(.success(true))
                    }
                }
            }
        })
    }


    public var alertDataLimit: Int? { return 1000 }

    public func uploadAlertData(_ stored: [SyncAlertObject], completion: @escaping (Result<Bool, Error>) -> Void) {
        completion(.success(false))
    }

    public var carbDataLimit: Int? { return 1000 }

    public func uploadCarbData(created: [SyncCarbObject], updated: [SyncCarbObject], deleted: [SyncCarbObject], completion: @escaping (Result<Bool, Error>) -> Void) {
        guard hasConfiguration, let uploader = uploader else {
            completion(.success(true))
            return
        }
        
        uploader.createCarbData(created) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let createdObjectIds):
                let createdUploaded = !created.isEmpty
                let syncIdentifiers = created.map { $0.syncIdentifier }
                for (syncIdentifier, objectId) in zip(syncIdentifiers, createdObjectIds) {
                    if let syncIdentifier = syncIdentifier {
                        self.objectIdCache.add(syncIdentifier: syncIdentifier, objectId: objectId)
                    }
                }
                self.stateDelegate?.pluginDidUpdateState(self)
                
                uploader.updateCarbData(updated, usingObjectIdCache: self.objectIdCache) { result in
                    switch result {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let updatedUploaded):
                        uploader.deleteCarbData(deleted, usingObjectIdCache: self.objectIdCache) { result in
                            switch result {
                            case .failure(let error):
                                completion(.failure(error))
                            case .success(let deletedUploaded):
                                self.objectIdCache.purge(before: Date().addingTimeInterval(-self.objectIdCacheKeepTime))
                                self.stateDelegate?.pluginDidUpdateState(self)
                                completion(.success(createdUploaded || updatedUploaded || deletedUploaded))
                            }
                        }
                    }
                }
            }
        }
    }

    public var doseDataLimit: Int? { return 1000 }

    public func uploadDoseData(created: [DoseEntry], deleted: [DoseEntry], completion: @escaping (_ result: Result<Bool, Error>) -> Void) {
        guard hasConfiguration, let uploader = uploader else {
            completion(.success(true))
            return
        }

        uploader.createDoses(created, usingObjectIdCache: self.objectIdCache) { (result) in
            switch (result) {
            case .failure(let error):
                completion(.failure(error))
            case .success(let createdObjectIds):
                let createdUploaded = !created.isEmpty
                let syncIdentifiers = created.map { $0.syncIdentifier }
                for (syncIdentifier, objectId) in zip(syncIdentifiers, createdObjectIds) {
                    if let syncIdentifier = syncIdentifier {
                        self.objectIdCache.add(syncIdentifier: syncIdentifier, objectId: objectId)
                    }
                }
                self.stateDelegate?.pluginDidUpdateState(self)

                uploader.deleteDoses(deleted.filter { !$0.isMutable }, usingObjectIdCache: self.objectIdCache) { result in
                    switch result {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let deletedUploaded):
                        self.objectIdCache.purge(before: Date().addingTimeInterval(-self.objectIdCacheKeepTime))
                        self.stateDelegate?.pluginDidUpdateState(self)
                        completion(.success(createdUploaded || deletedUploaded))
                    }
                }
            }
        }
    }

    public var dosingDecisionDataLimit: Int? { return 50 }  // Each can be up to 20K bytes of serialized JSON, target ~1M or less

    public func uploadDosingDecisionData(_ stored: [StoredDosingDecision], completion: @escaping (Result<Bool, Error>) -> Void) {
        guard hasConfiguration, let uploader = uploader else {
            completion(.success(true))
            return
        }

        var uploadPairs: [(StoredDosingDecision, StoredDosingDecision?)] = []

        for decision in stored {
            switch decision.reason {
            case "loop":
                lastDosingDecisionForAutomaticDose = decision
            case "updateRemoteRecommendation", "normalBolus", "simpleBolus", "watchBolus":
                uploadPairs.append((decision, lastDosingDecisionForAutomaticDose))
            default:
                break
            }
        }

        guard uploadPairs.count > 0 else {
            completion(.success(false))
            return
        }

        activityAggregator.activityStatuses(endingAt: uploadPairs.map { $0.0.date }) { activityStatuses in
            let statuses = zip(uploadPairs, activityStatuses).map { (pair, activityStatus) in
                let (decision, automaticDoseDecision) = pair
                return decision.deviceStatus(automaticDoseDecision: automaticDoseDecision, activity: activityStatus)
            }

            uploader.uploadDeviceStatuses(statuses) { result in
                switch result {
                case .success:
                    self.lastDosingDecisionForAutomaticDose = nil
                default:
                    break
                }
                completion(result)
            }
        }
    }

    public var glucoseDataLimit: Int? { return 1000 }

    public func uploadGlucoseData(_ stored: [StoredGlucoseSample], completion: @escaping (Result<Bool, Error>) -> Void) {
        guard hasConfiguration, let uploader = uploader else {
            completion(.success(true))
            return
        }

        uploader.uploadGlucoseSamples(stored, completion: completion)
    }

    public var pumpEventDataLimit: Int? { return 1000 }

    public func uploadPumpEventData(_ stored: [PersistedPumpEvent], completion: @escaping (Result<Bool, Error>) -> Void) {

        guard hasConfiguration, let uploader = uploader else {
            completion(.success(true))
            return
        }

        let source = "loop://\(UIDevice.current.name)"

        let treatments = stored.compactMap { (event) -> NightscoutTreatment? in
            // ignore doses; we'll get those via uploadDoseData
            guard event.dose == nil else {
                return nil
            }
            return event.treatment(source: source)
        }

        uploader.upload(treatments) { (result) in
            switch result {
            case .failure(let error):
                self.log.error("Failed to upload pump events %{public}@: %{public}@", String(describing: treatments.map {$0.dictionaryRepresentation}), String(describing: error))
                completion(.failure(error))
            case .success:
                self.log.debug("Uploaded overrides %@", String(describing: treatments.map {$0.dictionaryRepresentation}))
                completion(.success(true))
            }
        }

        completion(.success(false))
    }

    public var settingsDataLimit: Int? { return 400 }  // Each can be up to 2.5K bytes of serialized JSON, target ~1M or less

    public func uploadSettingsData(_ stored: [StoredSettings], completion: @escaping (Result<Bool, Error>) -> Void) {
        guard hasConfiguration, let uploader = uploader else {
            completion(.success(true))
            return
        }

        uploader.uploadProfiles(stored.compactMap { $0.profileSet }, completion: completion)
    }
    
    public func fetchStoredTherapySettings(completion: @escaping (Result<(TherapySettings,Date), Error>) -> Void) {
        guard let uploader = uploader else {
            completion(.failure(NightscoutServiceError.missingCredentials))
            return
        }

        uploader.fetchCurrentProfile(completion: { result in
            switch result {
            case .success(let profileSet):
                if let therapySettings = profileSet.therapySettings {
                    completion(.success((therapySettings,profileSet.startDate)))
                } else {
                    completion(.failure(NightscoutServiceError.incompatibleTherapySettings))
                }
                break
            case .failure(let error):
                completion(.failure(error))
            }
        })
    }

    public func uploadCgmEventData(_ stored: [LoopKit.PersistedCgmEvent], completion: @escaping (Result<Bool, Error>) -> Void) {
        guard hasConfiguration, let uploader = uploader else {
            completion(.success(true))
            return
        }

        uploader.uploadCgmEvents(stored, completion: completion)
    }

    
    public func remoteNotificationWasReceived(_ notification: [String: AnyObject]) async throws {
        let commandSource = try commandSource(notification: notification)
        await commandSource.remoteNotificationWasReceived(notification)
    }
    
    private func commandSource(notification: [String: AnyObject]) throws -> RemoteCommandSource {
        return commandSourceV1
    }

}

extension NightscoutService: RemoteCommandSourceV1Delegate {
    
    func commandSourceV1(_: RemoteCommandSourceV1, handleAction action: Action, remoteNotification: RemoteNotification) async throws {
        
        let returnInfo = remoteNotification.getReturnNotificationInfo()
        if returnInfo == nil {
            os_log("No return notification info available, response will not be sent", log: .default, type: .info)
        } else {
            os_log("Return notification info available, will send response after command processing", log: .default, type: .info)
        }
        
        var commandType: RemoteNotificationResponseManager.CommandType = .bolus // Default, will be set in switch
        var success = false
        var message = ""
        
        do {
            switch action {
            case .temporaryScheduleOverride(let overrideCommand):
                commandType = .override
                try await self.serviceDelegate?.enactRemoteOverride(
                    name: overrideCommand.name,
                    durationTime: overrideCommand.durationTime,
                    remoteAddress: overrideCommand.remoteAddress
                )
                success = true
                message = "Override '\(overrideCommand.name)' enacted successfully"
                
            case .cancelTemporaryOverride:
                commandType = .cancelOverride
                try await self.serviceDelegate?.cancelRemoteOverride()
                success = true
                message = "Override cancelled successfully"
                
            case .bolusEntry(let bolusCommand):
                commandType = .bolus
                try await self.serviceDelegate?.deliverRemoteBolus(amountInUnits: bolusCommand.amountInUnits)
                success = true
                message = String(format: "Bolus of %.2f units delivered successfully", bolusCommand.amountInUnits)
                
            case .carbsEntry(let carbCommand):
                commandType = .carbs
                try await self.serviceDelegate?.deliverRemoteCarbs(
                    amountInGrams: carbCommand.amountInGrams,
                    absorptionTime: carbCommand.absorptionTime,
                    foodType: carbCommand.foodType,
                    startDate: carbCommand.startDate
                )
                success = true
                message = String(format: "Carbs entry of %.1f g delivered successfully", carbCommand.amountInGrams)
            }
        } catch {
            message = "Command failed: \(error.localizedDescription)"
            // Send failure response before rethrowing
            if let returnInfo = returnInfo {
                await RemoteNotificationResponseManager.shared.sendResponseNotification(
                    to: returnInfo,
                    commandType: commandType,
                    success: false,
                    message: message
                )
            }
            throw error
        }
        
        // Send success response
        if let returnInfo = returnInfo {
            await RemoteNotificationResponseManager.shared.sendResponseNotification(
                to: returnInfo,
                commandType: commandType,
                success: success,
                message: message
            )
        }
    }
    
    func commandSourceV1(_: RemoteCommandSourceV1, uploadError error: Error, notification: [String: AnyObject]) async throws {
        
        guard let uploader = self.uploader else {throw NightscoutServiceError.missingCredentials}
        var commandDescription = "Loop Remote Action Error"
        if let remoteNotification = try? notification.toRemoteNotification() {
            commandDescription = remoteNotification.toRemoteAction().description
        }
        
        let notificationJSON = try JSONSerialization.data(withJSONObject: notification)
        let notificationJSONString = String(data: notificationJSON, encoding: .utf8) ?? ""
        
        let noteBody = """
        \(error.localizedDescription)
        \(notificationJSONString)
        """

        let treatment = NightscoutTreatment(
            timestamp: Date(),
            enteredBy: commandDescription,
            notes: noteBody,
            eventType: .note
        )
        
        return try await withCheckedThrowingContinuation { continuation in
            uploader.upload([treatment], completionHandler: { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            })
        }
    }
}

private final class NightscoutActivityAggregator {
    private let healthStore: HKHealthStore
    private let window: TimeInterval

    private let stepsType = HKQuantityType.quantityType(forIdentifier: .stepCount)!
    private let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
    private let activeEnergyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!
    private let exerciseTimeType = HKQuantityType.quantityType(forIdentifier: .appleExerciseTime)!
    private let distanceType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)!
    private let workoutType = HKObjectType.workoutType()

    private var readTypes: Set<HKObjectType> {
        return [stepsType, heartRateType, activeEnergyType, exerciseTimeType, distanceType, workoutType]
    }

    init(healthStore: HKHealthStore = HKHealthStore(), window: TimeInterval = .minutes(5)) {
        self.healthStore = healthStore
        self.window = window
    }

    func activityStatuses(endingAt endDates: [Date], completion: @escaping ([ActivityStatus?]) -> Void) {
        guard HKHealthStore.isHealthDataAvailable(), !endDates.isEmpty else {
            completion(Array(repeating: nil, count: endDates.count))
            return
        }

        authorizeIfNeeded { authorized in
            guard authorized else {
                completion(Array(repeating: nil, count: endDates.count))
                return
            }

            var statuses = Array<ActivityStatus?>(repeating: nil, count: endDates.count)
            let group = DispatchGroup()

            for (index, endDate) in endDates.enumerated() {
                group.enter()
                self.activityStatus(endingAt: endDate) { status in
                    statuses[index] = status
                    group.leave()
                }
            }

            group.notify(queue: .global()) {
                completion(statuses)
            }
        }
    }

    private func authorizeIfNeeded(completion: @escaping (Bool) -> Void) {
        healthStore.getRequestStatusForAuthorization(toShare: Set<HKSampleType>(), read: readTypes) { status, _ in
            switch status {
            case .shouldRequest:
                self.healthStore.requestAuthorization(toShare: Set<HKSampleType>(), read: self.readTypes) { success, _ in
                    completion(success)
                }
            case .unnecessary:
                completion(true)
            case .unknown:
                completion(true)
            @unknown default:
                completion(true)
            }
        }
    }

    private func activityStatus(endingAt endDate: Date, completion: @escaping (ActivityStatus?) -> Void) {
        let startDate = endDate.addingTimeInterval(-window)
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictEndDate)
        let group = DispatchGroup()

        var steps: Double?
        var heartRateAvg: Double?
        var heartRateMax: Double?
        var activeEnergyKcal: Double?
        var exerciseMinutes: Double?
        var distanceMeters: Double?
        var workoutActive: Bool?

        group.enter()
        cumulativeSum(for: stepsType, unit: .count(), predicate: predicate) { value in
            steps = value
            group.leave()
        }

        group.enter()
        average(for: heartRateType, unit: HKUnit.count().unitDivided(by: .minute()), predicate: predicate) { value in
            heartRateAvg = value
            group.leave()
        }

        group.enter()
        maximum(for: heartRateType, unit: HKUnit.count().unitDivided(by: .minute()), predicate: predicate) { value in
            heartRateMax = value
            group.leave()
        }

        group.enter()
        cumulativeSum(for: activeEnergyType, unit: .kilocalorie(), predicate: predicate) { value in
            activeEnergyKcal = value
            group.leave()
        }

        group.enter()
        cumulativeSum(for: exerciseTimeType, unit: .minute(), predicate: predicate) { value in
            exerciseMinutes = value
            group.leave()
        }

        group.enter()
        cumulativeSum(for: distanceType, unit: .meter(), predicate: predicate) { value in
            distanceMeters = value
            group.leave()
        }

        group.enter()
        hasActiveWorkout(startDate: startDate, endDate: endDate) { value in
            workoutActive = value
            group.leave()
        }

        group.notify(queue: .global()) {
            if steps == nil,
               heartRateAvg == nil,
               heartRateMax == nil,
               activeEnergyKcal == nil,
               exerciseMinutes == nil,
               distanceMeters == nil,
               workoutActive != true
            {
                completion(nil)
                return
            }

            completion(ActivityStatus(
                windowMinutes: self.window.minutes,
                steps: steps,
                heartRateAvg: heartRateAvg,
                heartRateMax: heartRateMax,
                activeEnergyKcal: activeEnergyKcal,
                exerciseMinutes: exerciseMinutes,
                distanceMeters: distanceMeters,
                workoutActive: workoutActive
            ))
        }
    }

    private func cumulativeSum(for quantityType: HKQuantityType, unit: HKUnit, predicate: NSPredicate, completion: @escaping (Double?) -> Void) {
        let query = HKStatisticsQuery(quantityType: quantityType, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, statistics, _ in
            completion(statistics?.sumQuantity()?.doubleValue(for: unit))
        }
        healthStore.execute(query)
    }

    private func average(for quantityType: HKQuantityType, unit: HKUnit, predicate: NSPredicate, completion: @escaping (Double?) -> Void) {
        let query = HKStatisticsQuery(quantityType: quantityType, quantitySamplePredicate: predicate, options: .discreteAverage) { _, statistics, _ in
            completion(statistics?.averageQuantity()?.doubleValue(for: unit))
        }
        healthStore.execute(query)
    }

    private func maximum(for quantityType: HKQuantityType, unit: HKUnit, predicate: NSPredicate, completion: @escaping (Double?) -> Void) {
        let query = HKStatisticsQuery(quantityType: quantityType, quantitySamplePredicate: predicate, options: .discreteMax) { _, statistics, _ in
            completion(statistics?.maximumQuantity()?.doubleValue(for: unit))
        }
        healthStore.execute(query)
    }

    private func hasActiveWorkout(startDate: Date, endDate: Date, completion: @escaping (Bool?) -> Void) {
        let startsBeforeWindowEnds = NSPredicate(format: "%K < %@", HKPredicateKeyPathStartDate, endDate as NSDate)
        let endsAfterWindowStarts = NSPredicate(format: "%K > %@", HKPredicateKeyPathEndDate, startDate as NSDate)
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [startsBeforeWindowEnds, endsAfterWindowStarts])
        let query = HKSampleQuery(sampleType: workoutType, predicate: predicate, limit: 1, sortDescriptors: nil) { _, samples, error in
            guard error == nil else {
                completion(nil)
                return
            }
            completion(samples?.isEmpty == false)
        }
        healthStore.execute(query)
    }
}

extension KeychainManager {

    func setNightscoutCredentials(siteURL: URL? = nil, apiSecret: String? = nil) throws {
        let credentials: InternetCredentials?

        if let siteURL = siteURL, let apiSecret = apiSecret {
            credentials = InternetCredentials(username: NightscoutAPIAccount, password: apiSecret, url: siteURL)
        } else {
            credentials = nil
        }

        try replaceInternetCredentials(credentials, forAccount: NightscoutAPIAccount)
    }

    func getNightscoutCredentials() throws -> (siteURL: URL, apiSecret: String) {
        let credentials = try getInternetCredentials(account: NightscoutAPIAccount)

        return (siteURL: credentials.url, apiSecret: credentials.password)
    }

}

fileprivate let NightscoutAPIAccount = "NightscoutAPI"
